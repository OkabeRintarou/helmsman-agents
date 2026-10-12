defmodule HelmsmanWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates `Authorization: Bearer <token>` requests to the MCP and
  REST endpoints (designs/03 §2, §5).

      plug HelmsmanWeb.Plugs.BearerAuth, scope: "mcp", via: :mcp

  Every request checks the token against the database (revoked, expired,
  user no longer a member → 401 with `WWW-Authenticate: Bearer`; missing
  scope → 403), counts against the token's rate limit (→ 429 with
  `Retry-After`) and records the token's last use at most once a minute.
  On success `conn.assigns.current_scope` holds the user, the workspace,
  the current role, `via` and the token; the actor is resolved per write
  with `Helmsman.Actors.resolve_writer/2`.

  Run tokens (`hmr_`, `Helmsman.Runs.RunTokens`) are accepted on `/mcp`
  only (`via: :mcp`; elsewhere 401): the scope is the run's
  (`via: :run`), the rate limit is the run's own with the same budget,
  and there is no last use to record.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.Accounts.Scope
  alias Helmsman.ApiTokens
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Runs.RunTokens

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    via = Keyword.fetch!(opts, :via)

    unless scope in ApiToken.scopes() do
      raise ArgumentError, "unknown token scope: #{inspect(scope)}"
    end

    unless via in [:mcp, :api] do
      raise ArgumentError, "via must be :mcp or :api, got: #{inspect(via)}"
    end

    %{scope: scope, via: via}
  end

  @impl true
  def call(conn, %{scope: required_scope, via: via}) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, scope} <- authenticate(token, required_scope, via) do
      assign(conn, :current_scope, scope)
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> halt_with(401, "unauthorized")

      {:error, :insufficient_scope} ->
        halt_with(conn, 403, "forbidden")

      {:error, {:rate_limited, retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> halt_with(429, "rate_limited")
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, String.trim(token)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp authenticate("hmr_" <> _ = token, _required_scope, :mcp) do
    with {:ok, scope} <- RunTokens.scope(token),
         :ok <- RunTokens.check_rate_limit(scope.run),
         do: {:ok, scope}
  end

  defp authenticate("hm_" <> _ = token, required_scope, via) do
    with {:ok, found} <- ApiTokens.authenticate(token, required_scope),
         :ok <- ApiTokens.check_rate_limit(found.token) do
      :ok = ApiTokens.touch_last_used(found.token)

      {:ok,
       %Scope{
         user: found.user,
         workspace: found.workspace,
         role: found.role,
         actor: nil,
         via: via,
         run: nil,
         token: found.token
       }}
    end
  end

  defp authenticate(_token, _required_scope, _via), do: {:error, :unauthorized}

  defp halt_with(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
