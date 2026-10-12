defmodule HelmsmanMCP.PresentTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Feedback, Projects, Tasks}
  alias HelmsmanMCP.Present

  @iso ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS", name: "Bosun")
    agent = %{scope | actor: agent_fixture(workspace, owner, "keel/dev")}

    task = task_fixture(scope, "BOS", title: "Fix login", description: "Steps")
    {:ok, _} = Tasks.transition(agent, task.ident, "in progress")
    {:ok, _} = Feedback.add(agent, task.ident, %{kind: "question", content: "Why?"})
    {:ok, _} = Feedback.revise(agent, "BOS-1#1", %{content: "Why not?"})

    {:ok, _} =
      Tasks.transition(agent, task.ident, "done",
        commits: ["a1b2c3d"],
        tests: %{command: "mix test", passed: true, summary: "12 tests"},
        feedback: %{content: "Done"}
      )

    {:ok, task} = Tasks.get(scope, task.ident)
    {:ok, project} = Projects.get(scope, "BOS")
    {:ok, entries} = Feedback.list(scope, "BOS-1")
    %{scope: scope, task: task, project: project, entries: entries, email: owner.email}
  end

  # Every key of `value` with its value, at any depth.
  defp pairs(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [{to_string(key), value} | pairs(value)] end)

  defp pairs(list) when is_list(list), do: Enum.flat_map(list, &pairs/1)
  defp pairs(_value), do: []

  # No database key: an `id` is an external ID string (BOS-1, BOS-1#2).
  defp refute_internal(value, email) do
    for {key, value} <- pairs(value) do
      refute key in ["workspace_id", "email"], key
      refute String.ends_with?(key, "_id"), key
      if key == "id", do: assert(is_binary(value) and value =~ ~r/\A[A-Z][A-Z0-9]+-\d+(#\d+)?\z/)
    end

    refute Jason.encode!(value) =~ email
  end

  test "a project", %{scope: scope, project: project, email: email} do
    view = Present.project(project)

    assert %{key: "BOS", name: "Bosun", archived: false, archived_at: nil, task_count: 1} = view
    assert view.created_at =~ @iso
    refute Map.has_key?(view, :id)
    refute_internal(view, email)

    {:ok, archived} = Projects.archive(scope, "BOS")
    assert %{archived: true, archived_at: at} = Present.project(archived)
    assert at =~ @iso
  end

  test "a task summary", %{task: task, email: email} do
    view = task |> Tasks.summary() |> Present.summary()

    assert %{
             id: "BOS-1",
             project_key: "BOS",
             status: "DONE",
             assignee: %{name: "keel/dev", kind: "agent"},
             created_by: %{kind: "human"},
             commits: ["a1b2c3d"],
             open_question: true
           } = view

    assert view.created_at =~ @iso and view.updated_at =~ @iso
    refute_internal(view, email)
  end

  test "a task detail", %{task: task, email: email} do
    view = task |> Tasks.detail() |> Present.detail()

    assert view.description == "Steps"

    assert [
             %{from: nil, to: "NEW"},
             %{from: "NEW", to: "IN_PROGRESS", actor: %{name: "keel/dev", kind: "agent"}},
             %{
               from: "IN_PROGRESS",
               to: "DONE",
               commits: ["a1b2c3d"],
               tests: %{command: "mix test", passed: true, summary: "12 tests"},
               feedback: "BOS-1#3"
             }
           ] = view.history

    assert Enum.all?(view.history, &(&1.at =~ @iso))

    assert [
             %{id: "BOS-1#1", status: "superseded", superseded_by: "BOS-1#2"},
             %{id: "BOS-1#2", kind: "question", supersedes: "BOS-1#1"},
             %{id: "BOS-1#3", kind: "comment", content: "Done"}
           ] = view.feedback

    assert Enum.all?(view.feedback, &(&1.at =~ @iso))
    refute_internal(view, email)
  end

  test "a feedback record", %{entries: [entry | _], email: email} do
    view = entry |> Feedback.view() |> Present.feedback()

    assert %{id: "BOS-1#1", author: %{name: "keel/dev", kind: "agent"}} = view
    assert view.at =~ @iso
    refute_internal(view, email)
  end

  test "status/1" do
    assert Present.status(:in_progress) == "IN_PROGRESS"
    assert Present.status("cancelled") == "CANCELLED"
    assert Present.status(nil) == nil
  end
end
