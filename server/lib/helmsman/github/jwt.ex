defmodule Helmsman.GitHub.JWT do
  @moduledoc """
  The App's own token: an RS256 JWT signed with its private key, issued 60
  seconds in the past (clock drift) and valid for 9 minutes (GitHub accepts
  at most 10).
  """

  alias Helmsman.GitHub.AppConfig

  @doc "Signs an App JWT at `now` (Unix seconds)."
  @spec app_token(AppConfig.t(), integer()) :: String.t()
  def app_token(%AppConfig{app_id: app_id, private_key: pem}, now \\ System.system_time(:second)) do
    jwk = JOSE.JWK.from_pem(pem)
    claims = %{"iat" => now - 60, "exp" => now + 540, "iss" => app_id}

    {_meta, token} =
      jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    token
  end
end
