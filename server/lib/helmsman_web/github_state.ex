defmodule HelmsmanWeb.GitHubState do
  @moduledoc """
  The `state` tokens of the GitHub flows (add-github-ui D2): a `Phoenix.Token` valid
  10 minutes, bound to the user, and for installations also to the workspace. Shared by
  `HelmsmanWeb.GitHubController` and the LiveViews that start the flows.
  """

  alias HelmsmanWeb.Endpoint

  @manifest_salt "github-manifest"
  @install_salt "github-install"
  @max_age 600

  @doc "A state for the App manifest flow of `user_id`."
  @spec sign_manifest(integer()) :: String.t()
  def sign_manifest(user_id), do: Phoenix.Token.sign(Endpoint, @manifest_salt, %{u: user_id})

  @doc "Whether `state` is a manifest state issued to `user_id` in the last 10 minutes."
  @spec verify_manifest(term(), integer()) :: :ok | :error
  def verify_manifest(state, user_id) when is_binary(state) do
    case Phoenix.Token.verify(Endpoint, @manifest_salt, state, max_age: @max_age) do
      {:ok, %{u: ^user_id}} -> :ok
      _ -> :error
    end
  end

  def verify_manifest(_state, _user_id), do: :error

  @doc "A state for installing the App into `workspace_id` by `user_id`."
  @spec sign_install(integer(), integer()) :: String.t()
  def sign_install(workspace_id, user_id),
    do: Phoenix.Token.sign(Endpoint, @install_salt, %{w: workspace_id, u: user_id})

  @doc "The workspace of an installation state issued to `user_id` in the last 10 minutes."
  @spec verify_install(term(), integer()) :: {:ok, integer()} | :error
  def verify_install(state, user_id) when is_binary(state) do
    case Phoenix.Token.verify(Endpoint, @install_salt, state, max_age: @max_age) do
      {:ok, %{w: workspace_id, u: ^user_id}} -> {:ok, workspace_id}
      _ -> :error
    end
  end

  def verify_install(_state, _user_id), do: :error
end
