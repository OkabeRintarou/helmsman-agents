defmodule Helmsman.Backup.Import.ReplaceTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AgentDesignsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.Backup.Import.Replace

  test "design runs and conversations survive; retained retry references are cleared" do
    ctx = design_fixture()
    view = start_design!(ctx.alice_scope)
    design = design!(view.id)
    design_run = current_run!(view.id)
    messages = messages!(view.id)
    project = project_fixture(ctx.alice_scope)
    task = task_fixture(ctx.alice_scope, project.key)
    task_run = run_fixture(ctx.helper, %{task_id: task.id, status: :succeeded})
    retry = run_fixture(ctx.helper, %{task_id: nil, status: :succeeded, retry_of_id: task_run.id})
    assert :ok = Replace.clear(ctx.workspace.id)
    assert design!(view.id) == design
    assert current_run!(view.id) == design_run
    assert messages!(view.id) == messages
    assert Repo.get!(Helmsman.Runs.Run, retry.id).retry_of_id == nil
    refute Repo.get(Helmsman.Runs.Run, task_run.id)
    refute Repo.get(Helmsman.Tasks.Task, task.id)
    assert Repo.get!(Helmsman.Projects.Project, project.id).task_seq == 1
  end

  test "active task runs block replacement with the task identifier" do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    assert {:error, {:replace_blocked, detail}} = Replace.clear(ctx.workspace.id)
    assert %{task: task.ident, reason: "active_run"} in detail
    assert Repo.get(Helmsman.Tasks.Task, task.id)
  end

  test "draft and open PRs block; terminal PR and task execution references are removed" do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    repository = repository_fixture(installation_fixture(ctx.workspace))

    pr =
      Repo.insert!(%Helmsman.GitHub.PullRequest{
        workspace_id: ctx.workspace.id,
        task_id: task.id,
        repository_id: repository.id,
        number: 1,
        node_id: "synthetic-pr",
        url: "https://example.invalid/pull/1",
        branch: "synthetic",
        base_branch: "main",
        state: :draft
      })

    for state <- [:draft, :open] do
      Repo.update!(Ecto.Changeset.change(pr, state: state))
      assert {:error, {:replace_blocked, detail}} = Replace.clear(ctx.workspace.id)
      assert %{task: task.ident, reason: "open_pr"} in detail
    end

    Repo.update!(Ecto.Changeset.change(pr, state: :closed))
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :succeeded})

    Repo.insert_all("run_events", [
      %{run_id: run.id, seq: 1, type: "text", data: %{}, at: DateTime.utc_now()}
    ])

    assert :ok = Replace.clear(ctx.workspace.id)
    refute Repo.get(Helmsman.GitHub.PullRequest, pr.id)
    refute Repo.get(Helmsman.Runs.Run, run.id)
    refute Repo.exists?(from(e in "run_events", where: e.run_id == ^run.id))
  end
end
