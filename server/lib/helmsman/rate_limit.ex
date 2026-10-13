defmodule Helmsman.RateLimit do
  @moduledoc """
  Node-local rate limiting for authentication entry points (ETS backend).

  Limits are read at call time from `config :helmsman, Helmsman.RateLimit`,
  one `{limit, scale_ms}` tuple per bucket:

    * `:magic_link_ip` - magic link requests per client IP
    * `:magic_link_email` - magic link requests per normalized email
    * `:password_ip` - password log in attempts per client IP
    * `:register_ip` - registration submissions per client IP
    * `:autopilot_webhook` - authenticated webhook requests per autopilot
      (`add-autopilots` decision 14)
  """

  use Hammer, backend: :ets

  @type bucket ::
          :magic_link_ip
          | :magic_link_email
          | :password_ip
          | :register_ip
          | :daemon_device_ip
          | :daemon_device_user
          | :autopilot_webhook

  @doc """
  Counts one request against `bucket` for `key`.

  Returns `:ok` while the request is within the configured limit, otherwise
  `{:error, :rate_limited}`.
  """
  @spec check(bucket(), term()) :: :ok | {:error, :rate_limited}
  def check(bucket, key) do
    {limit, scale_ms} = limit_for(bucket)

    case hit({bucket, key}, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @doc """
  Like `check/2`, but a refusal says after how many milliseconds the
  bucket allows a request again.
  """
  @spec check_retry(bucket(), term()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check_retry(bucket, key) do
    {limit, scale_ms} = limit_for(bucket)

    case hit({bucket, key}, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  @doc """
  Formats a client IP (as found in `conn.remote_ip` or LiveView peer data)
  into a rate limit key.
  """
  @spec ip_key(:inet.ip_address() | nil) :: String.t()
  def ip_key(nil), do: "unknown"
  def ip_key(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  defp limit_for(bucket) do
    :helmsman
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(bucket)
  end
end
