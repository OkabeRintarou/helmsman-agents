defmodule HelmsmanWeb.Plugs.TrustedProxies do
  @moduledoc """
  Reverse proxy headers (`add-release-distribution` decision 3), right
  after `Plug.RequestId`.

  Only a request whose peer address is in `HELMSMAN_TRUSTED_PROXIES`
  (`config :helmsman, :trusted_proxies`, a list of CIDRs) gets its client
  address from `X-Forwarded-For` (the `remote_ip` library, with the
  trusted ranges as proxies) and its scheme from `X-Forwarded-Proto`
  (`Plug.RewriteOn`). Without trusted proxies, or from any other peer,
  both headers are ignored, so a client cannot forge its address (rate
  limits use `conn.remote_ip`) or scheme.

  The client is the rightmost `X-Forwarded-For` address outside every
  trusted range, whether public or private (an intranet client next to the
  proxy keeps its own rate limit buckets); only trusted hops are skipped.
  When every hop is trusted, the peer is the client.
  """

  @behaviour Plug

  import Bitwise

  @rewrite_on Plug.RewriteOn.init([:x_forwarded_proto])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    proxies = proxies()

    if trusted?(conn.remote_ip, proxies) do
      %{conn | remote_ip: forwarded_ip(conn.remote_ip, conn.req_headers, proxies)}
      |> Plug.RewriteOn.call(@rewrite_on)
    else
      conn
    end
  end

  @doc """
  The client address of a request from `peer` with `headers`: the address
  in `X-Forwarded-For` when `peer` is a trusted proxy, otherwise `peer`.
  LiveView sockets use it with their `:peer_data` and `:x_headers`.
  """
  @spec client_ip(:inet.ip_address() | nil, [{String.t(), String.t()}]) ::
          :inet.ip_address() | nil
  def client_ip(nil, _headers), do: nil

  def client_ip(peer, headers) do
    proxies = proxies()

    if trusted?(peer, proxies),
      do: forwarded_ip(peer, headers, proxies),
      else: peer
  end

  defp proxies, do: Application.get_env(:helmsman, :trusted_proxies, [])

  defp trusted?(_ip, []), do: false

  defp trusted?(ip, proxies) do
    address = encode(unmap(ip))
    Enum.any?(proxies, &(&1 |> parse!() |> contains?(address)))
  end

  # Not `RemoteIp.from/2`: it also skips every private and loopback address
  # as a proxy, which would let a private client behind a narrow trusted
  # range prepend a forged address.
  defp forwarded_ip(peer, headers, proxies) do
    blocks = Enum.map(proxies, &parse!/1)

    headers
    |> RemoteIp.Headers.take(["x-forwarded-for"])
    |> RemoteIp.Headers.parse()
    |> Enum.map(&unmap/1)
    |> Enum.reverse()
    |> Enum.find(unmap(peer), fn ip ->
      address = encode(ip)
      not Enum.any?(blocks, &contains?(&1, address))
    end)
  end

  # An IPv4 peer on a dual-stack listener is an IPv4-mapped IPv6 address.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp unmap(ip), do: ip

  defp parse!(cidr) do
    {address, prefix} =
      case String.split(cidr, "/", parts: 2) do
        [address, prefix] -> {address, String.to_integer(prefix)}
        [address] -> {address, nil}
      end

    {:ok, ip} = address |> String.to_charlist() |> :inet.parse_strict_address()
    {proto, value, bits} = encode(ip)
    prefix = prefix || bits
    mask = (1 <<< bits) - 1 &&& bnot((1 <<< (bits - prefix)) - 1)
    {proto, value &&& mask, mask}
  end

  defp encode({a, b, c, d}), do: {:v4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d, 32}

  defp encode({_, _, _, _, _, _, _, _} = ip) do
    value = ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc <<< 16 ||| part end)
    {:v6, value, 128}
  end

  defp contains?({proto, net, mask}, {proto, value, _bits}), do: (value &&& mask) == net
  defp contains?(_block, _address), do: false
end
