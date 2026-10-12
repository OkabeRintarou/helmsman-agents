defmodule Helmsman.GitHub.Client do
  @moduledoc """
  Thin Req wrapper around the GitHub REST API (designs/15 §1).

  Requests authenticate as the App (`:app`, an RS256 JWT), with a token
  (`{:token, token}`: installation or user token) or not at all (`:none`).
  Responses are normalized:

    * `2xx` → `{:ok, body}`
    * `404` → `{:error, :not_found}`
    * `403` / `429` with `x-ratelimit-remaining: 0` or `retry-after` →
      `{:error, {:rate_limited, retry_at}}`
    * `5xx` and transport errors → `{:error, {:github_unavailable, reason}}`
    * other statuses → `{:error, {:github_error, status}}`

  Neither Req's debug logging nor any log line here includes request
  headers, so tokens never reach the logs. `api_url` / `web_url` come from
  `config :helmsman, Helmsman.GitHub`; tests stub the transport with
  `config :helmsman, Helmsman.GitHub.Client, req_options: [plug: ...]`.
  """

  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.JWT

  @type auth :: :app | {:token, String.t()} | :none
  @type error ::
          :not_found
          | :github_not_configured
          | {:rate_limited, DateTime.t()}
          | {:github_unavailable, term()}
          | {:github_error, pos_integer()}

  @default_rate_limit_wait 60

  @doc "The REST API base URL."
  @spec api_url() :: String.t()
  def api_url, do: setting(:api_url, "https://api.github.com")

  @doc "The github.com web base URL (OAuth, App pages)."
  @spec web_url() :: String.t()
  def web_url, do: setting(:web_url, "https://github.com")

  defp setting(key, default),
    do: Keyword.get(Application.get_env(:helmsman, Helmsman.GitHub, []), key, default)

  @doc """
  Sends a request and returns the decoded body.

  ## Options

    * `:auth` - see the module documentation (default `:none`)
    * `:json` - a request body encoded as JSON
    * `:params` - query parameters
    * `:base` - `:api` (default) or `:web`
  """
  @spec request(:get | :post | :put | :patch | :delete, String.t(), keyword()) ::
          {:ok, term()} | {:error, error()}
  def request(method, url, opts \\ []) do
    with {:ok, response} <- send_request(method, url, opts) do
      {:ok, response.body}
    end
  end

  @doc """
  GETs every page of a list endpoint by following the `Link: rel="next"`
  header (100 items per page).

  ## Options

    * `:auth`, `:params` - as for `request/3`
    * `:key` - the list's key in an object response (e.g.
      `"repositories"`); without it the body is the list
    * `:max` - stop after this many items
  """
  @spec paginate(String.t(), keyword()) :: {:ok, [term()]} | {:error, error()}
  def paginate(path, opts \\ []) do
    params = Keyword.merge([per_page: 100], Keyword.get(opts, :params, []))
    opts = Keyword.put(opts, :params, params)
    collect(path, opts, [], Keyword.get(opts, :max, :infinity))
  end

  defp collect(url, opts, acc, max) do
    with {:ok, response} <- send_request(:get, url, opts) do
      items = page_items(response.body, opts[:key])
      acc = acc ++ items

      cond do
        max != :infinity and length(acc) >= max -> {:ok, Enum.take(acc, max)}
        next = next_link(response) -> collect(next, Keyword.delete(opts, :params), acc, max)
        true -> {:ok, acc}
      end
    end
  end

  defp page_items(body, nil) when is_list(body), do: body
  defp page_items(%{} = body, key) when is_binary(key), do: Map.get(body, key, [])
  defp page_items(_body, _key), do: []

  defp next_link(response) do
    response
    |> Req.Response.get_header("link")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.find_value(fn part ->
      case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/, part) do
        [_, url] -> url
        nil -> nil
      end
    end)
  end

  defp send_request(method, url, opts) do
    with {:ok, headers} <- auth_headers(Keyword.get(opts, :auth, :none)) do
      base = if Keyword.get(opts, :base, :api) == :web, do: web_url(), else: api_url()

      req_opts =
        [
          method: method,
          url: url,
          base_url: base,
          headers:
            [
              {"accept", accept(opts)},
              {"x-github-api-version", "2022-11-28"},
              {"user-agent", "helmsman"}
            ] ++ headers,
          retry: false
        ]
        |> maybe_put(:json, Keyword.get(opts, :json))
        |> maybe_put(:params, Keyword.get(opts, :params))

      req_opts
      |> Req.new()
      |> Req.merge(req_options())
      |> Req.request()
      |> normalize()
    end
  end

  # The OAuth endpoints on github.com answer JSON only when asked for it.
  defp accept(opts) do
    if Keyword.get(opts, :base, :api) == :web,
      do: "application/json",
      else: "application/vnd.github+json"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp req_options,
    do: Keyword.get(Application.get_env(:helmsman, __MODULE__, []), :req_options, [])

  defp auth_headers(:none), do: {:ok, []}
  defp auth_headers({:token, token}), do: {:ok, [{"authorization", "Bearer " <> token}]}

  defp auth_headers(:app) do
    with {:ok, config} <- AppConfig.current() do
      {:ok, [{"authorization", "Bearer " <> JWT.app_token(config)}]}
    end
  end

  defp normalize({:ok, %Req.Response{status: status} = response}) when status in 200..299,
    do: {:ok, response}

  defp normalize({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

  defp normalize({:ok, %Req.Response{status: status} = response}) when status in [403, 429] do
    case rate_limit_reset(response) do
      nil when status == 429 ->
        {:error, {:rate_limited, DateTime.add(now(), @default_rate_limit_wait)}}

      nil ->
        {:error, {:github_error, status}}

      retry_at ->
        {:error, {:rate_limited, retry_at}}
    end
  end

  defp normalize({:ok, %Req.Response{status: status}}) when status >= 500,
    do: {:error, {:github_unavailable, {:http_status, status}}}

  defp normalize({:ok, %Req.Response{status: status}}), do: {:error, {:github_error, status}}

  defp normalize({:error, %{__exception__: true} = exception}),
    do: {:error, {:github_unavailable, exception_reason(exception)}}

  defp normalize({:error, reason}), do: {:error, {:github_unavailable, reason}}

  defp exception_reason(%Req.TransportError{reason: reason}), do: reason
  defp exception_reason(exception), do: Exception.message(exception)

  defp rate_limit_reset(response) do
    remaining = header(response, "x-ratelimit-remaining")
    retry_after = header(response, "retry-after")

    cond do
      retry_after != nil ->
        case Integer.parse(retry_after) do
          {seconds, _} -> DateTime.add(now(), seconds)
          :error -> DateTime.add(now(), @default_rate_limit_wait)
        end

      remaining == "0" ->
        with reset when is_binary(reset) <- header(response, "x-ratelimit-reset"),
             {epoch, _} <- Integer.parse(reset),
             {:ok, at} <- DateTime.from_unix(epoch) do
          at
        else
          _ -> DateTime.add(now(), @default_rate_limit_wait)
        end

      true ->
        nil
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> String.trim(value)
      [] -> nil
    end
  end

  defp now, do: DateTime.utc_now(:second)
end
