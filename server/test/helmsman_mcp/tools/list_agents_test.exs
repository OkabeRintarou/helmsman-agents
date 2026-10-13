defmodule HelmsmanMCP.Tools.ListAgentsTest do
  # add-squads 4.3: list_agents lists the squads; a write's dispatch names
  # the squad and the blocking members (run-dispatch "MCP 的派发工具").
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Runs.Run
  alias HelmsmanMCP.{Context, Present}
  alias HelmsmanMCP.Tools.{ListAgents, UpdateTask}

  setup do
    squads_fixture()
  end

  defp call(tool, scope, args),
    do: tool.call(args, %Context{tool: tool.name(), scope: scope, args: args, session: nil})

  test "the squads with their leader and members", ctx do
    assert {:ok, %{agents: agents, squads: [squad]}} = call(ListAgents, ctx.alice_scope, %{})
    assert Enum.any?(agents, &(&1.name == "keel/lead"))
    bob = human_actor(ctx.workspace, ctx.bob).name

    assert %{
             name: "web-team",
             description: "Builds the web app",
             leader: "keel/lead",
             disabled: false,
             busy: false,
             members: [
               %{name: "keel/fe", kind: "agent", role_note: "Writes the frontend"},
               %{name: "keel/review", kind: "agent", role_note: "Reviews"},
               %{name: "keel/qa", kind: "agent", role_note: "Tests"},
               %{name: ^bob, kind: "human", role_note: "Decides product questions"}
             ]
           } = squad

    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.lead, %{task_id: task.id, status: :running, squad_id: ctx.squad.id})
    assert {:ok, %{squads: [%{busy: true}]}} = call(ListAgents, ctx.alice_scope, %{})
  end

  test "assigning a squad over MCP: the squad and the refused members", ctx do
    actor = agent_fixture(ctx.workspace, ctx.bob, "bob/cli")
    scope = %{token_scope_fixture(ctx.bob, ctx.workspace, :mcp) | actor: actor}
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    assert {:ok, result} =
             call(UpdateTask, scope, %{"task_id" => task.ident, "assignee" => "web-team"})

    assert result.dispatch == [
             %{
               agent: "keel/lead",
               squad: "web-team",
               trigger: "assign",
               result: "skipped",
               reason: "unauthorized",
               refused: ["keel/qa"]
             }
           ]
  end

  test "a run summary names the squad it runs as", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.lead, %{task_id: task.id, squad_id: ctx.squad.id})

    summary = Helmsman.Runs.summary(Repo.get!(Run, run.id))
    assert summary.squad == %{id: ctx.squad.id, name: "web-team"}
    assert %{squad: "web-team"} = Present.run(summary)

    plain = Helmsman.Runs.summary(run_fixture(ctx.lead, %{task_id: task.id, lane: :reply}))
    assert plain.squad == nil
    refute Map.has_key?(Present.run(plain), :squad)
  end
end
