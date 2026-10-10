defmodule Helmsman.WorkspacesFixtures do
  @moduledoc """
  Test helpers for workspaces, memberships and workspace scopes.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors
  alias Helmsman.Invitations
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Membership

  def unique_workspace_slug, do: "ws#{System.unique_integer([:positive])}"

  def workspace_fixture(owner, attrs \\ %{}) do
    slug = unique_workspace_slug()
    attrs = Enum.into(attrs, %{slug: slug, name: "Workspace #{slug}"})
    {:ok, workspace} = Workspaces.create(owner, attrs)
    workspace
  end

  @doc "Adds `user` to `workspace` with `role` (and their human identity)."
  def member_fixture(workspace, user, role) do
    {:ok, membership} =
      Tx.run(fn ->
        membership =
          Repo.insert!(%Membership{workspace_id: workspace.id, user_id: user.id, role: role})

        {:ok, _actor} = Actors.ensure_human(workspace, user)
        {:ok, membership}
      end)

    membership
  end

  @doc "Returns the scope of `user` in `workspace`, as the browser builds it."
  def workspace_scope_fixture(user, workspace) do
    {:ok, %{workspace: ws, membership: m, actor: a}} =
      Workspaces.fetch_for_user(user, workspace.slug)

    %{Scope.put_workspace(Scope.for_user(user), ws, m, a) | via: :web}
  end

  @doc "The invitation link the tests pass to `Helmsman.Invitations.create/3`."
  def invite_url(token), do: "http://localhost/invite/#{token}"

  @doc """
  Creates an invitation as `scope` (a member invitation by default) and
  returns `%{invitation: invitation, token: token}`.
  """
  def invitation_fixture(scope, attrs \\ %{}) do
    {:ok, created} = Invitations.create(scope, Enum.into(attrs, %{role: :member}), &invite_url/1)
    created
  end
end
