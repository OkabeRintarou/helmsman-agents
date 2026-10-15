defmodule HelmsmanMCP.ResourcesTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.Projects
  alias HelmsmanMCP.{Pipeline, Prompts, Resources}

  @workflow Path.expand("../../../docs/AGENT-WORKFLOW.en.md", __DIR__)

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    project_fixture(owner_scope, key: "KEEL")
    {:ok, _} = Projects.archive(owner_scope, project_fixture(owner_scope, key: "OLD").key)
    task_fixture(owner_scope, "BOS", title: "Fix login", description: "Line 1\n\n**Bold** <b>")

    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    session = mcp_session(alice, workspace)
    call!(session, "identify", %{name: "keel/dev"})

    other_owner = user_fixture()
    other = workspace_fixture(other_owner)
    other_scope = workspace_scope_fixture(other_owner, other)
    project_fixture(other_scope, key: "OTHER")
    task_fixture(other_scope, "OTHER")

    %{session: session}
  end

  defp read(%{scope: scope, sid: sid}, uri),
    do: Pipeline.read("resources/read", Resources.args(uri), scope, sid, &Resources.read(uri, &1))

  defp prompt(%{scope: scope, sid: sid}, args),
    do: Pipeline.read("work_on_task", args, scope, sid, &Prompts.get("work_on_task", &1))

  describe "resources" do
    test "the workflow is the file as it is", %{session: session} do
      assert read(session, "helmsman://workflow") == {:ok, File.read!(@workflow)}
    end

    # add-squads 4.3: the squads section (decision 13).
    test "the workflow has the squads section", %{session: session} do
      assert {:ok, text} = read(session, "helmsman://workflow")
      assert text =~ "## 9. Squads"
      assert text =~ "delegate(task_id, to, instructions)"
      assert text =~ "after delegating, finish your run"
    end

    # add-spec-workflow 2.5: the specs section (decision 23).
    test "the workflow has the specs section", %{session: session} do
      assert {:ok, text} = read(session, "helmsman://workflow")
      assert text =~ "## 10. Specs"

      for word <- ["submit_spec_version", "finalize_spec", "submit_spec_review", "base_version"],
          do: assert(text =~ word)
    end

    test "BQL is the exact English guide", %{session: session} do
      assert read(session, "helmsman://bql") ==
               {:ok, File.read!(Path.expand("../../../docs/BQL.en.md", __DIR__))}

      assert Enum.find(Resources.list(), &(&1.uri == "helmsman://bql")).mime_type ==
               "text/markdown"

      for file <- ["BQL.md", "BQL.en.md"] do
        text = File.read!(Path.expand("../../../docs/#{file}", __DIR__))

        for field <- Helmsman.BQL.fields(),
            name <- [to_string(field.name) | field.aliases],
            do: assert(text =~ name)
      end

      text = File.read!(Path.expand("../../../docs/BQL.en.md", __DIR__))

      for [_, query] <- Regex.scan(~r/```bql\n(.*?)```/s, text),
          do: assert({:ok, _} = Helmsman.BQL.parse(String.trim(query)))
    end

    test "projects have the shape of list_projects", %{session: session} do
      assert {:ok, json} = read(session, "helmsman://projects")
      assert Jason.decode!(json) == call!(session, "list_projects")
      assert json |> Jason.decode!() |> Enum.map(& &1["key"]) == ["BOS", "KEEL"]
    end

    test "a task as Markdown", %{session: session} do
      assert {:ok, text} = read(session, "helmsman://tasks/bos-1")
      [first | _] = String.split(text, "\n")
      assert first =~ "BOS-1" and first =~ "Fix login"
      assert text =~ "- Status: NEW"
      # The description verbatim, not rendered.
      assert text =~ "Line 1\n\n**Bold** <b>"
    end

    test "Feedback prompt list names the replied-to current record and author", %{
      session: session
    } do
      call!(session, "add_feedback", %{task_id: "BOS-1", content: "First"})
      call!(session, "add_feedback", %{task_id: "BOS-1", content: "Reply", reply_to: "BOS-1#1"})
      call!(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "Current"})
      assert {:ok, text} = read(session, "helmsman://tasks/BOS-1")
      assert text =~ "回复 #3 @keel/dev"
      assert {:ok, prompt} = prompt(session, %{"task_id" => "BOS-1"})
      assert prompt =~ "回复 #3 @keel/dev"
    end

    test "history and active feedback only", %{session: session} do
      call!(session, "transition_task", %{task_id: "BOS-1", to: "in progress"})
      call!(session, "add_feedback", %{task_id: "BOS-1", content: "old text", kind: "question"})
      call!(session, "update_feedback", %{feedback_id: "BOS-1#1", content: "new text"})

      call!(session, "transition_task", %{
        task_id: "BOS-1",
        to: "done",
        comment: "Fixed\nfor real",
        commits: ["a1b2c3d"],
        tests: %{command: "mix test", passed: true, summary: "12 tests"},
        feedback: %{content: "Summary"}
      })

      assert {:ok, text} = read(session, "helmsman://tasks/BOS-1")

      assert text =~ "- Assignee: keel/dev (agent)"
      assert text =~ "keel/dev (agent): NEW -> IN_PROGRESS"
      assert text =~ "keel/dev (agent): IN_PROGRESS -> DONE"
      assert text =~ "  - Comment: Fixed\n    for real"
      assert text =~ "  - Commits: a1b2c3d"
      assert text =~ "  - Tests: passed - `mix test` - 12 tests"
      assert text =~ "  - Reason: BOS-1#3"
      assert text =~ "### BOS-1#2 question by keel/dev (agent)"
      assert text =~ "new text"
      refute text =~ "old text"
      refute text =~ "BOS-1#1"
    end

    test "another workspace's task does not exist", %{session: session} do
      assert {:error, :not_found, text} = read(session, "helmsman://tasks/OTHER-1")
      assert text =~ "Task OTHER-1 not found"
      assert {:error, :not_found, _} = read(session, "helmsman://tasks/BOS-9")
      assert {:error, :not_found, _} = read(session, "helmsman://nothing")
    end

    test "list and templates" do
      assert Enum.map(Resources.list(), & &1.uri) == [
               "helmsman://workflow",
               "helmsman://bql",
               "helmsman://projects"
             ]

      assert [%{uri_template: "helmsman://tasks/{id}", mime_type: "text/markdown"}] =
               Resources.templates()
    end
  end

  describe "work_on_task" do
    test "the task, the workflow and the instructions", %{session: session} do
      assert {:ok, text} = prompt(session, %{task_id: "bos-1"})

      {:ok, task_text} = read(session, "helmsman://tasks/BOS-1")
      assert String.starts_with?(text, task_text)
      assert text =~ File.read!(@workflow)
      assert text =~ "Fix login"
      assert text =~ ~s<claim it: transition_task(BOS-1, "IN_PROGRESS")>
      assert text =~ ~s<transition_task(BOS-1, "DONE", commits: [...], tests: {...})>
      assert text =~ "unanswered question, do not start"
    end

    test "an unknown task", %{session: session} do
      assert {:error, :not_found, "Task BOS-9 not found" <> _} =
               prompt(session, %{task_id: "BOS-9"})

      assert {:error, :not_found, _} = prompt(session, %{task_id: "OTHER-1"})
    end
  end

  test "the instructions point to identify, the workflow and work_on_task" do
    text = HelmsmanMCP.Server.server_instructions()

    for word <- ["identify", "helmsman://workflow", "work_on_task"],
        do: assert(text =~ word)
  end
end
