defmodule HelmsmanMCP.Tools.TransitionTaskTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Feedback.Entry
  alias Helmsman.Tasks

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")
    task_fixture(owner_scope, "BOS", title: "Fix login")

    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    session = mcp_session(alice, workspace)
    call!(session, "identify", %{name: "keel/dev"})

    reviewer = mcp_session(owner, workspace)
    call!(reviewer, "identify", %{name: "lead/review"})

    %{workspace: workspace, owner_scope: owner_scope, session: session, reviewer: reviewer}
  end

  defp done(session) do
    call!(session, "transition_task", %{task_id: "BOS-1", to: "in progress"})
    call!(session, "transition_task", %{task_id: "BOS-1", to: "done"})
  end

  defp feedback_count, do: Repo.aggregate(Entry, :count)

  test "claim", %{session: session} do
    assert %{"status" => "IN_PROGRESS", "assignee" => %{"name" => "keel/dev", "kind" => "agent"}} =
             call!(session, "transition_task", %{task_id: "bos-1", to: "in progress"})
  end

  test "done with evidence", %{session: session} do
    call!(session, "transition_task", %{task_id: "BOS-1", to: "IN_PROGRESS"})

    assert %{"status" => "DONE", "commits" => ["a1b2c3d"], "history" => history} =
             call!(session, "transition_task", %{
               task_id: "BOS-1",
               to: "DONE",
               comment: "Fixed",
               commits: ["a1b2c3d"],
               tests: %{command: "mix test", passed: true, summary: "12 tests"}
             })

    assert %{
             "from" => "IN_PROGRESS",
             "to" => "DONE",
             "actor" => %{"name" => "keel/dev"},
             "comment" => "Fixed",
             "commits" => ["a1b2c3d"],
             "tests" => %{"command" => "mix test", "passed" => true, "summary" => "12 tests"}
           } = List.last(history)
  end

  test "an invalid transition", %{session: session} do
    done(session)

    assert call(session, "transition_task", %{task_id: "BOS-1", to: "CANCELLED"}) ==
             {:error, "Cannot move BOS-1 from DONE to CANCELLED. Allowed: VERIFIED, IN_PROGRESS."}
  end

  test "the assignee verifies without tests", %{session: session} do
    done(session)

    assert call(session, "transition_task", %{task_id: "BOS-1", to: "VERIFIED"}) ==
             {:error,
              "You (keel/dev) are the assignee. Pass tests={passed: true, ...} " <>
                "or let the requester verify."}

    assert %{"status" => "VERIFIED"} =
             call!(session, "transition_task", %{
               task_id: "BOS-1",
               to: "VERIFIED",
               tests: %{command: "mix test", passed: true, summary: "ok"}
             })
  end

  test "sent back with a reason", %{session: session, reviewer: reviewer} do
    done(session)

    assert %{
             "status" => "IN_PROGRESS",
             "history" => history,
             "feedback" => [
               %{"id" => "BOS-1#1", "kind" => "review", "content" => "Missing tests"} = entry
             ]
           } =
             call!(reviewer, "transition_task", %{
               task_id: "BOS-1",
               to: "IN_PROGRESS",
               feedback: %{kind: "review", content: "Missing tests"}
             })

    assert entry["author"] == %{"name" => "lead/review", "kind" => "agent"}

    assert %{"from" => "DONE", "to" => "IN_PROGRESS", "feedback" => "BOS-1#1"} =
             List.last(history)
  end

  test "an unknown status", %{session: session} do
    assert call(session, "transition_task", %{task_id: "BOS-1", to: "doing"}) ==
             {:error,
              ~s(Unknown status "doing". Use one of: NEW, IN_PROGRESS, DONE, VERIFIED, ) <>
                "REJECTED, CANCELLED."}
  end

  test "a reason with an invalid transition is not saved", %{session: session, owner_scope: scope} do
    before = feedback_count()

    assert {:error, "Cannot move BOS-1 from NEW to DONE." <> _} =
             call(session, "transition_task", %{
               task_id: "BOS-1",
               to: "DONE",
               feedback: %{content: "Done already"}
             })

    assert feedback_count() == before
    assert {:ok, %{feedback_count: 0, feedback_seq: 0}} = Tasks.get(scope, "BOS-1")
  end

  test "invalid evidence", %{session: session} do
    call!(session, "transition_task", %{task_id: "BOS-1", to: "IN_PROGRESS"})

    assert call(session, "transition_task", %{task_id: "BOS-1", to: "DONE", commits: ["xyz"]}) ==
             {:error, "Invalid commit hashes: xyz. Each must be 7-64 hexadecimal characters."}

    assert {:error, "comment is too long (max 10000 characters)." <> _} =
             call(session, "transition_task", %{
               task_id: "BOS-1",
               to: "DONE",
               comment: String.duplicate("a", 10_001)
             })
  end

  test "an unknown task", %{session: session, workspace: ws} do
    assert call(session, "transition_task", %{task_id: "BOS-9", to: "DONE"}) ==
             {:error, "Task BOS-9 not found in workspace #{ws.slug}."}
  end
end
