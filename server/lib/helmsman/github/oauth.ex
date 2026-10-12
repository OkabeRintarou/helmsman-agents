defmodule Helmsman.GitHub.OAuth do
  @moduledoc """
  Proof that an installation belongs to the GitHub user completing the
  installation (designs/15 §1): the OAuth `code` from the setup callback is
  exchanged for a user token, which lists the installations the user can
  access. The token lives only inside `user_installation_ids/2` and is
  never stored nor logged.
  """

  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Client

  @doc "Returns the IDs of the installations the user who granted `code` can access."
  @spec user_installation_ids(AppConfig.t(), String.t()) ::
          {:ok, [pos_integer()]} | {:error, :oauth_failed | Client.error()}
  def user_installation_ids(%AppConfig{} = config, code) when is_binary(code) do
    with {:ok, token} <- exchange(config, code),
         {:ok, installations} <-
           Client.paginate("/user/installations", auth: {:token, token}, key: "installations") do
      {:ok, for(%{"id" => id} <- installations, is_integer(id), do: id)}
    end
  end

  defp exchange(config, code) do
    body = %{client_id: config.client_id, client_secret: config.client_secret, code: code}

    case Client.request(:post, "/login/oauth/access_token", base: :web, json: body) do
      {:ok, %{"access_token" => token}} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _error_body} -> {:error, :oauth_failed}
      {:error, {:github_error, _status}} -> {:error, :oauth_failed}
      {:error, :not_found} -> {:error, :oauth_failed}
      {:error, _reason} = error -> error
    end
  end
end
