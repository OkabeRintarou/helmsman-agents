defmodule HelmsmanMCP.RequestScope do
  @moduledoc """
  The scope a tool call runs with, read again from the request's own
  `Authorization` header when the call runs (code review R1).

  anubis merges each request's `conn.assigns` into the session frame, but a
  request queued behind a running tool gets the frame that tool returns,
  with the earlier request's assigns; only the transport context (headers)
  is the queued request's own. So the token is checked again here: revoked,
  expired or no longer a member gives `{:error, :unauthorized}`, as do a
  token without the `mcp` scope or other than the one the session is bound
  to. Run tokens (`hmr_`) are checked the same way
  (`Helmsman.Runs.RunTokens.scope/2`): a run that ended while the call
  was queued gives `{:error, :unauthorized}`. The rate limit and the last
  use were already handled by `HelmsmanWeb.Plugs.BearerAuth` for the
  request.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.ApiTokens
  alias Helmsman.Runs.RunTokens
  alias HelmsmanMCP.Sessions

  @doc """
  Returns the current scope of the request with `headers` (lower-case
  names) in `session_id`.
  """
  @spec fetch(%{optional(String.t()) => String.t()}, String.t() | nil) ::
          {:ok, Scope.t()} | {:error, :unauthorized}
  def fetch(headers, session_id) when is_map(headers) do
    with {:ok, token} <- bearer(headers["authorization"]),
         {:ok, scope} <- authenticate(token),
         %{credential: credential} <- Sessions.lookup(session_id),
         true <- credential == Scope.credential(scope) do
      {:ok, scope}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # An `hm_` token needs the `mcp` scope; a run token (`hmr_`) its run.
  defp authenticate("hmr_" <> _ = token), do: RunTokens.scope(token)

  defp authenticate("hm_" <> _ = token) do
    with {:ok, found} <- ApiTokens.authenticate(token, "mcp") do
      {:ok,
       %Scope{
         user: found.user,
         workspace: found.workspace,
         role: found.role,
         actor: nil,
         via: :mcp,
         run: nil,
         token: found.token
       }}
    end
  end

  defp authenticate(_token), do: {:error, :unauthorized}

  defp bearer(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}
      _other -> nil
    end
  end

  defp bearer(_header), do: nil
end
