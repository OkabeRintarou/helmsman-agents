defmodule HelmsmanMCP.Tools.DispatchToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers, only: [mcp_session: 2]

  alias Helmsman.Events
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.Run
  alias HelmsmanMCP.{Context, Pipeline, Rejected}
  alias HelmsmanMCP.Tools.{ListAgents, ListRuns, RunAgent, UpdateTask}

  setup do
    ctx = dispatch_fixture()
    bob = user_fixture()
    member_fixture(ctx.workspace, bob, :member)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{bob: bob, task: task})
  end

  # The scope of an hm_ token of `user`, writing as their external agent
  # `name`.
  defp external(ctx, user, name) do
    actor = agent_fixture(ctx.workspace, user, name)
    %{token_scope_fixture(user, ctx.workspace, :mcp) | actor: actor}
  end

  defp context(tool, scope, args),
    do: %Context{tool: tool.name(), scope: scope, args: args, session: nil}

  defp call(tool, scope, args), do: tool.call(args, context(tool, scope, args))

  test "an external agent starts a managed agent on its user's behalf", ctx do
    scope = external(ctx, ctx.alice, "alice/cli")
    args = %{"agent" => "keel/dev", "task_id" => ctx.task.ident}

    assert {:ok, %{run: run, merged: false}} = call(RunAgent, scope, args)
    assert %{agent: "keel/dev", status: "QUEUED", task: ident} = run
    assert ident == ctx.task.ident
    assert [%{kind: "manual", by: %{name: "alice/cli", kind: "agent"}}] = run.triggers

    assert [%Run{root_initiator_user_id: root, triggers: [%{"initiator_user_id" => root}]}] =
             runs_of(ctx.task.id)

    assert root == ctx.alice.id

    assert {:ok, %{merged: true}} = call(RunAgent, scope, args)
  end

  test "not dispatched: the tool returns a Rejected for the pipeline", ctx do
    scope = external(ctx, ctx.bob, "bob/cli")
    args = %{"agent" => "keel/dev", "task_id" => ctx.task.ident}

    assert {:ok, %Rejected{reason: {:not_dispatched, :unauthorized}}} =
             call(RunAgent, scope, args)

    assert {:error, :not_managed} =
             call(RunAgent, external(ctx, ctx.alice, "alice/cli"), %{
               "agent" => "bob/cli",
               "instructions" => "x"
             })
  end

  test "assigning without the right to trigger: the edit succeeds, dispatch says why", ctx do
    scope = external(ctx, ctx.bob, "bob/cli")
    args = %{"task_id" => ctx.task.ident, "assignee" => "keel/dev"}

    assert {:ok, result} = call(UpdateTask, scope, args)
    assert result.assignee == %{name: "keel/dev", kind: "agent"}

    assert result.dispatch == [
             %{agent: "keel/dev", trigger: "assign", result: "skipped", reason: "unauthorized"}
           ]

    assert {:ok, result} = call(UpdateTask, scope, %{"task_id" => ctx.task.ident, "title" => "T"})
    refute Map.has_key?(result, :dispatch)
  end

  test "list_agents: managed or external, busy and queued", ctx do
    agent_fixture(ctx.workspace, ctx.alice, "alice/cli")
    run_fixture(ctx.agent, %{status: :running})
    run_fixture(ctx.agent, %{task_id: ctx.task.id})

    assert {:ok, %{agents: agents}} = call(ListAgents, ctx.alice_scope, %{})
    by_name = Map.new(agents, &{&1.name, &1})

    assert %{
             kind: "managed",
             busy: true,
             queued: 1,
             provider: "claude",
             disabled: false,
             wake_on_requested: true
           } = by_name["keel/dev"]

    assert %{kind: "external", busy: false, queued: 0, wake_on_requested: nil} =
             by_name["alice/cli"]
  end

  test "list_runs", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id})
    id = run.id

    assert {:ok, %{runs: [%{id: ^id, status: "QUEUED"}]}} =
             call(ListRuns, ctx.alice_scope, %{"task_id" => ctx.task.ident})
  end

  test "a Rejected write commits, notifies once and answers with an error", ctx do
    session = mcp_session(ctx.alice, ctx.workspace)
    Events.subscribe(Events.topic(:task, ctx.task.id))

    assert {:error, text} =
             Pipeline.call_module(
               HelmsmanMCP.Test.RejectingTool,
               %{"task_id" => ctx.task.ident},
               session.scope,
               session.sid
             )

    assert text =~ "was not started: too many runs"

    assert [%Entry{content: "before the refusal"}] =
             Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

    assert_receive {:feedback_added, _}
    refute_receive {:feedback_added, _}
  end
end
