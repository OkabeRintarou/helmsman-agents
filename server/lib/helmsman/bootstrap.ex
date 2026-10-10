defmodule Helmsman.Bootstrap do
  @moduledoc """
  Command-line bootstrap of a user and a workspace.

  Shared by `mix helmsman.bootstrap` and the release command. It returns a
  login token; building the URL is up to the caller, since the domain must
  not reference the web layer.
  """

  alias Helmsman.Accounts
  alias Helmsman.Accounts.User
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type result :: %{
          user: User.t(),
          workspace: Workspace.t(),
          login_token: String.t(),
          created: [:user | :workspace]
        }

  @doc """
  Ensures a confirmed user with `:email` and a workspace with slug
  `:workspace` (named `:name`, default: the slug) owned by that user.

  Missing records are created; existing ones are left unchanged. A new user
  bypasses the signup mode and becomes the instance administrator on an
  empty instance, without the `default` workspace. Fails with
  `{:error, :not_a_member}` and changes nothing when the workspace exists
  but the user is not a member.
  """
  @spec run(keyword()) ::
          {:ok, result()} | {:error, :not_a_member | Ecto.Changeset.t() | atom()}
  def run(opts) do
    email = Keyword.fetch!(opts, :email)
    slug = Keyword.fetch!(opts, :workspace)
    name = Keyword.get(opts, :name) || slug

    Tx.run(fn -> bootstrap(email, slug, name) end)
  end

  defp bootstrap(email, slug, name) do
    with {:ok, user, user_created} <- ensure_user(email),
         {:ok, workspace, workspace_created} <- ensure_workspace(user, slug, name) do
      created = for {item, true} <- [user: user_created, workspace: workspace_created], do: item

      {:ok,
       %{
         user: user,
         workspace: workspace,
         login_token: Accounts.generate_login_token(user),
         created: created
       }}
    end
  end

  defp ensure_user(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        {:ok, user, false}

      nil ->
        with {:ok, user} <-
               Accounts.register_user(%{email: email},
                 skip_signup_gate: true,
                 skip_default_workspace: true
               ),
             {:ok, user} <- Accounts.confirm_user(user) do
          {:ok, user, true}
        end
    end
  end

  defp ensure_workspace(user, slug, name) do
    case Workspaces.get_by_slug(slug) do
      %Workspace{} = workspace ->
        if Workspaces.get_membership(workspace.id, user.id),
          do: {:ok, workspace, false},
          else: {:error, :not_a_member}

      nil ->
        with {:ok, workspace} <-
               Workspaces.create_in_transaction(user, %{slug: slug, name: name}) do
          {:ok, workspace, true}
        end
    end
  end
end
