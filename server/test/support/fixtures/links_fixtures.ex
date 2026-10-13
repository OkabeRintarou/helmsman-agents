defmodule Helmsman.LinksFixtures do
  @moduledoc """
  Test helpers for task links: a workspace with alice (member), a viewer,
  alice's external agent `keel/dev` and the projects `BOS` and `WEB`.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  @doc """
  `%{owner, alice, viewer, keel}` (scopes), `workspace`, and the projects
  `bos` and `web`.
  """
  def links_fixture do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    [alice, viewer] =
      for role <- [:member, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        workspace_scope_fixture(user, workspace)
      end

    keel = %{alice | actor: agent_fixture(workspace, alice.user, "keel/dev")}

    %{
      owner: owner_scope,
      alice: alice,
      viewer: viewer,
      keel: keel,
      workspace: workspace,
      bos: project_fixture(owner_scope, key: "BOS", name: "Bosun"),
      web: project_fixture(owner_scope, key: "WEB", name: "Web")
    }
  end

  @doc "Creates `n` tasks in the project `key` as `scope`."
  def tasks!(scope, key, n), do: for(_ <- 1..n, do: task_fixture(scope, key))

  @doc "Sets the status of the task `ident` directly (no history)."
  def set_status!(%{id: id}, status) do
    Repo.update_all(from(t in Task, where: t.id == ^id), set: [status: status])
    :ok
  end

  @doc "The status of the task with `id`, from the database."
  def status_of(%{id: id}), do: Repo.one!(from(t in Task, where: t.id == ^id, select: t.status))
end
