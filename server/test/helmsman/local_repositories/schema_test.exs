defmodule Helmsman.LocalRepositories.SchemaTest do
  # add-local-repositories 2.1: the CHECK constraints, written straight to
  # the database.
  use Helmsman.DataCase, async: true

  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.LocalRepositories.TaskLocalBranch
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.Run

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    repository = repository_fixture(installation_fixture(ctx.workspace))
    local = local_repository_fixture(ctx.workspace, daemon)
    Map.merge(ctx, %{daemon: daemon, repository: repository, local: local})
  end

  # Inserts raise Ecto.ConstraintError, update_all Postgrex.Error.
  defp violates(constraint, fun) do
    Repo.transact(fn -> {:ok, fun.()} end)
    flunk("expected #{constraint} to be violated")
  rescue
    error in Postgrex.Error -> assert error.postgres.constraint == constraint
    error in Ecto.ConstraintError -> assert error.constraint == constraint
  end

  test "a project binds at most one repository", ctx do
    violates("projects_one_repository_check", fn ->
      Repo.update_all(from(p in Project, where: p.id == ^ctx.project.id),
        set: [repository_id: ctx.repository.id, local_repository_id: ctx.local.id]
      )
    end)

    bind_local(ctx.project, ctx.local)
    assert Repo.get!(Project, ctx.project.id).local_repository_id == ctx.local.id
  end

  test "a run has at most one repository", ctx do
    run = run_fixture(ctx.agent)

    violates("runs_one_repository_check", fn ->
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [repository_id: ctx.repository.id, local_repository_id: ctx.local.id]
      )
    end)

    assert set_local_run(run, local_repository_id: ctx.local.id).local_repository_id ==
             ctx.local.id
  end

  test "status and its reason are checked", ctx do
    violates("local_repositories_status_check", fn ->
      local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "x", status: "gone"})
    end)

    violates("local_repositories_reason_check", fn ->
      local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "y", status: "unavailable"})
    end)

    violates("local_repositories_reason_check", fn ->
      local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "z", unavailable_reason: "why"})
    end)

    assert local_repository_fixture(ctx.workspace, ctx.daemon, %{
             name: "w",
             status: "unavailable",
             unavailable_reason: "not a git repository"
           })
  end

  test "the branch state and its merge fields are checked", ctx do
    task = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)

    insert = fn attrs ->
      Repo.insert!(
        struct!(
          TaskLocalBranch,
          Map.merge(
            %{
              workspace_id: ctx.workspace.id,
              task_id: task.id,
              local_repository_id: ctx.local.id,
              branch: "hm/x",
              head_sha: "abc"
            },
            attrs
          )
        )
      )
    end

    violates("task_local_branches_state_check", fn -> insert.(%{state: "closed"}) end)
    violates("task_local_branches_merged_check", fn -> insert.(%{state: "merged"}) end)
    violates("task_local_branches_merged_check", fn -> insert.(%{merge_note: "squashed"}) end)

    assert insert.(%{state: "merged", merged_at: DateTime.utc_now(:second), merge_note: "ok"})
  end

  test "names are unique per workspace and daemon", ctx do
    error =
      assert_raise Ecto.ConstraintError, fn ->
        local_repository_fixture(ctx.workspace, ctx.daemon)
      end

    assert error.constraint == "local_repositories_workspace_id_daemon_id_name_index"
  end
end
