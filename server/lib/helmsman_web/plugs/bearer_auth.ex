defmodule HelmsmanWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates `Authorization: Bearer <token>` requests to the MCP and
  REST endpoints (designs/03 §2, §5).

      plug HelmsmanWeb.Plugs.BearerAuth, scope: "mcp", via: :mcp
      plug HelmsmanWeb.Plugs.BearerAuth, scope: ["api:read", "api:write"], via: :api

  `:scope` is one scope or a list of which the token needs any one.
  Every request checks the token against the database (revoked, expired,
  user no longer a member → 401 with `WWW-Authenticate: Bearer`; missing
  scope → 403), counts against the token's rate limit (→ 429 with
  `Retry-After`) and records the token's last use at most once a minute.
  With `via: :api` the errors use the REST error body
  (`HelmsmanWeb.ErrorMapper`; missing scope → 403 `insufficient_scope`)
  and every response has `x-ratelimit-limit` / `x-ratelimit-remaining`;
  `via: :mcp` responses are unchanged.
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
  alias HelmsmanWeb.ErrorMapper

  @impl true
  def init(opts) do
    scopes = opts |> Keyword.fetch!(:scope) |> List.wrap()
    via = Keyword.fetch!(opts, :via)

    if scopes == [] or Enum.any?(scopes, &(&1 not in ApiToken.scopes())) do
      raise ArgumentError, "unknown token scope: #{inspect(opts[:scope])}"
    end

    unless via in [:mcp, :api] do
      raise ArgumentError, "via must be :mcp or :api, got: #{inspect(via)}"
    end

    %{scopes: scopes, via: via}
  end

  @impl true
  def call(conn, %{scopes: required_scopes, via: via}) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, scope, quota} <- authenticate(token, required_scopes, via) do
      put_log_metadata(scope)

      conn
      |> put_quota(via, quota)
      |> assign(:current_scope, scope)
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> halt_with(via, 401, "unauthorized", %{})

      {:error, :insufficient_scope} ->
        halt_with(conn, via, 403, "insufficient_scope", %{required: required_scopes})

      {:error, {:rate_limited, retry_after, quota}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_quota(via, quota)
        |> halt_with(via, 429, "rate_limited", %{})
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

  defp authenticate("hmr_" <> _ = token, _required_scopes, :mcp) do
    with {:ok, scope} <- RunTokens.scope(token) do
      case RunTokens.check_rate_limit(scope.run) do
        :ok -> {:ok, scope, nil}
        {:error, {:rate_limited, retry_after}} -> {:error, {:rate_limited, retry_after, nil}}
      end
    end
  end

  defp authenticate("hm_" <> _ = token, required_scopes, via) do
    with {:ok, found} <- ApiTokens.authenticate(token, required_scopes),
         {:ok, quota} <- ApiTokens.hit_rate_limit(found.token) do
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
       }, quota}
    end
  end

  defp authenticate(_token, _required_scopes, _via), do: {:error, :unauthorized}

  # `add-rest-api` decision 10: REST responses show the token's quota.
  defp put_quota(conn, :api, %{limit: limit, remaining: remaining}) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
  end

  defp put_quota(conn, _via, _quota), do: conn

  # The request's log lines name the workspace and the token or run (never
  # the token itself).
  defp put_log_metadata(%Scope{workspace: workspace, token: token, run: run}) do
    Logger.metadata(
      workspace_id: workspace.id,
      token_id: token && token.id,
      run_id: run && run.id
    )
  end

  # MCP keeps its short body; REST uses the error body of
  # `HelmsmanWeb.ErrorMapper` (`add-rest-api` decision 1).
  defp halt_with(conn, :api, status, code, detail),
    do: ErrorMapper.send_error(conn, {status, ErrorMapper.body(code, detail)})

  defp halt_with(conn, :mcp, status, code, _detail) do
    error = if code == "insufficient_scope", do: "forbidden", else: code

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
