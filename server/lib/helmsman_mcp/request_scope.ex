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
  to. The rate limit and the last use were already handled by
  `HelmsmanWeb.Plugs.BearerAuth` for the request.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.ApiTokens
  alias HelmsmanMCP.Sessions

  @doc """
  Returns the current scope of the request with `headers` (lower-case
  names) in `session_id`.
  """
  @spec fetch(%{optional(String.t()) => String.t()}, String.t() | nil) ::
          {:ok, Scope.t()} | {:error, :unauthorized}
  def fetch(headers, session_id) when is_map(headers) do
    with {:ok, token} <- bearer(headers["authorization"]),
         {:ok, found} <- authenticate(token),
         %{token_id: token_id} <- Sessions.lookup(session_id),
         true <- token_id == found.token.id do
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
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp bearer(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}
      _other -> nil
    end
  end

  defp bearer(_header), do: nil

  defp authenticate("hm_" <> _ = token), do: ApiTokens.authenticate(token, "mcp")
  defp authenticate(_token), do: {:error, :unauthorized}
end
