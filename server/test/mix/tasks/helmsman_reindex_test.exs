defmodule Mix.Tasks.Helmsman.ReindexTest do
  # Replaces the global Mix shell.
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Feedback
  alias Helmsman.Tasks.Task
  alias Mix.Tasks.Helmsman.Reindex, as: ReindexTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints the counts of the workspace" do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")

    for _ <- 1..3, do: task_fixture(scope, "BOS")
    for n <- 1..5, do: {:ok, _} = Feedback.add(scope, "BOS-1", %{content: "note #{n}"})
    Repo.update_all(where(Task, workspace_id: ^workspace.id), set: [search: nil])

    ReindexTask.run(["--workspace", workspace.slug])

    assert_received {:mix_shell, :info, [output]}

    assert output ==
             "Reindexed tasks: 3, feedback: 5, cleared: 0, skipped (changed meanwhile): 0"
  end

  test "usage and unknown workspaces exit non-zero" do
    assert catch_exit(ReindexTask.run(["--bogus"])) == {:shutdown, 1}
    assert_received {:mix_shell, :error, ["usage: mix helmsman.reindex [--workspace <slug>]"]}

    assert catch_exit(ReindexTask.run(["--workspace", "nope-x"])) == {:shutdown, 1}
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "no workspace"
  end
end
