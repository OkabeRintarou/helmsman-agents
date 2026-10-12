defmodule HelmsmanMCP.Tools.FeedbackToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")
    task_fixture(owner_scope, "BOS")

    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    agent_fixture(workspace, alice, "keel/qa")
    session = mcp_session(alice, workspace)
    call!(session, "identify", %{name: "keel/dev"})

    bob = user_fixture()
    member_fixture(workspace, bob, :member)
    bob_session = mcp_session(bob, workspace)
    call!(bob_session, "identify", %{name: "bob/dev"})

    %{workspace: workspace, session: session, bob_session: bob_session}
  end

  defp add(session, content, opts \\ %{}),
    do: call!(session, "add_feedback", Map.merge(%{task_id: "BOS-1", content: content}, opts))

  test "a question", %{session: session} do
    assert %{
             "id" => "BOS-1#1",
             "kind" => "question",
             "content" => "Minimum prefix length?",
             "author" => %{"name" => "keel/dev", "kind" => "agent"},
             "status" => "active"
           } = add(session, "Minimum prefix length?", %{kind: "question"})

    assert %{"open_question" => true, "feedback_count" => 1} =
             call!(session, "get_task", %{task_id: "BOS-1"})
  end

  test "comment by default", %{session: session} do
    assert %{"kind" => "comment"} = add(session, "Note")
  end

  test "as another agent of mine (author)", %{session: session} do
    assert %{"author" => %{"name" => "keel/qa"}} = add(session, "QA", %{author: "keel/qa"})
    # The session identity stays.
    assert %{"author" => %{"name" => "keel/dev"}} = add(session, "Dev")
  end

  test "author must be an agent of mine", %{session: session} do
    assert call(session, "add_feedback", %{task_id: "BOS-1", content: "x", author: "bob/dev"}) ==
             {:error,
              "Your role (member) cannot do this. The author argument must name an agent of your own."}
  end

  test "revising", %{session: session} do
    add(session, "v1")

    assert %{"id" => "BOS-1#2", "content" => "v2", "kind" => "review", "supersedes" => "BOS-1#1"} =
             call!(session, "update_feedback", %{
               feedback_id: "bos-1#1",
               content: "v2",
               kind: "review"
             })
  end

  test "revising a superseded record", %{session: session} do
    add(session, "v1")
    add(session, "other")
    call!(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "v2"})
    call!(session, "update_feedback", %{feedback_id: "BOS-1#3", content: "v3"})

    assert call(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "x"}) ==
             {:error,
              "BOS-1#1 was already revised; the current version is BOS-1#4. " <>
                "Revise that one instead."}
  end

  test "revising someone else's record", %{session: session, bob_session: bob_session} do
    add(bob_session, "Bob's")

    assert call(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "x"}) ==
             {:error,
              "You can only revise feedback written by you or your own agents. " <>
                "Add a new feedback instead."}
  end

  test "an unknown record", %{session: session, workspace: ws} do
    assert call(session, "update_feedback", %{feedback_id: "BOS-1#9", content: "x"}) ==
             {:error, "Feedback BOS-1#9 not found in workspace #{ws.slug}."}

    assert call(session, "add_feedback", %{task_id: "BOS-7", content: "x"}) ==
             {:error, "Task BOS-7 not found in workspace #{ws.slug}."}
  end

  test "list_feedback: every record by number", %{session: session} do
    add(session, "v1")
    add(session, "other")
    call!(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "v2"})

    assert %{
             "task_id" => "BOS-1",
             "feedback" => [
               %{"id" => "BOS-1#1", "status" => "superseded", "superseded_by" => "BOS-1#3"},
               %{"id" => "BOS-1#2", "status" => "active"},
               %{"id" => "BOS-1#3", "status" => "active", "content" => "v2"}
             ]
           } = call!(session, "list_feedback", %{task_id: "bos-1"})
  end
end
