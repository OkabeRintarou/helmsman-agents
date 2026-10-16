defmodule HelmsmanMCP.Tools.OrchestrationToolsTest do
  # improve-squad-leader-orchestration 4.1 / 4.2: start_task and the step
  # fields of get_task over /mcp with run tokens and an hm_ token, and the
  # English text of every orchestration error (decisions 5, 13, 16). The
  # anubis session processes are not children of the test process: the
  # sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query

  import Helmsman.ApiTokensFixtures
  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Links, Repo, Runs, Tasks, Tx}
  alias Helmsman.Runs.Run
  alias HelmsmanMCP.{Context, ErrorText}
  alias HelmsmanWeb.MCPClient

  setup do
    ctx = squads_fixture()
    epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic", title: "Emulator"})
    {:ok, _} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team"})
    step = task_fixture(ctx.alice_scope, ctx.project.key, %{epic: epic.ident})
    Tx.run(fn -> {:ok, Runs.cancel_pending(from(r in Run), :obsolete)} end)
    %{token: token} = api_token_fixture(ctx.alice_scope)
    Map.merge(ctx, %{epic: epic, step: step, token: token})
  end

  defp leader_token(ctx, caps) do
    run =
      run_fixture(ctx.lead, %{
        task_id: ctx.epic.id,
        squad_id: ctx.squad.id,
        status: :running,
        capabilities: caps
      })

    {_scope, token} = run_scope_fixture(run)
    token
  end

  defp session(token), do: {token, MCPClient.handshake(token)}

  defp names({token, sid}) do
    resp = MCPClient.rpc(token, sid, "tools/list")
    200 = resp.status
    Enum.map(Jason.decode!(resp.body)["result"]["tools"], & &1["name"])
  end

  test "start_task is listed only for runs that orchestrate", ctx do
    # A run token lists a restricted tool only with its capability
    # (`HelmsmanMCP.Server.server_tools/2`).
    assert HelmsmanMCP.Tools.required_capabilities()["start_task"] == "orchestrate"

    orchestrating = leader_token(ctx, ~w(read write_task create_tasks delegate orchestrate))
    assert "start_task" in names(session(orchestrating))

    plain = leader_token(ctx, ~w(read write_task create_tasks delegate))
    refute "start_task" in names(session(plain))
    refute "start_task" in names(session(ctx.token))
  end

  describe "a callback run of the leader on a step (the ACC-10 shape)" do
    # `orchestration_fixture/1`: the epic led by web-team, its steps s1
    # (keel/fe), s2 (keel/review) and s3 (unassigned), none started; the
    # leader's run on s1 with the capabilities `Runs.capabilities/4` gives
    # (as `leader_run/3`, keeping the token).
    setup do
      ctx = orchestration_fixture()
      task = Repo.reload!(ctx.s1)

      run =
        run_fixture(ctx.lead, %{
          task_id: task.id,
          status: :running,
          squad_id: ctx.squad.id,
          capabilities: Runs.capabilities(profile(ctx.lead), task, [], ctx.squad.id),
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [ctx.lead.id]
        })

      {_scope, run_token} = run_scope_fixture(run)
      %{token: token} = api_token_fixture(ctx.alice_scope)
      Map.merge(ctx, %{run: run, run_token: run_token, token: token})
    end

    test "its capabilities list start_task", ctx do
      assert "orchestrate" in ctx.run.capabilities
      assert "start_task" in names(session(ctx.run_token))
    end

    test "get_task of the epic: what each step waits for, and what it may orchestrate",
         ctx do
      {:ok, %{"children" => children}} =
        MCPClient.call_tool(ctx.run_token, MCPClient.handshake(ctx.run_token), "get_task", %{
          task_id: ctx.epic.ident
        })

      fields = Enum.map(children, &Map.take(&1, ~w(id waiting_for blocked_by orchestrable)))

      assert fields == [
               %{
                 "id" => ctx.s1.ident,
                 "waiting_for" => "run",
                 "blocked_by" => [],
                 "orchestrable" => true
               },
               %{
                 "id" => ctx.s2.ident,
                 "waiting_for" => "start",
                 "blocked_by" => [],
                 "orchestrable" => true
               },
               %{
                 "id" => ctx.s3.ident,
                 "waiting_for" => "assignment",
                 "blocked_by" => [],
                 "orchestrable" => true
               }
             ]

      {:ok, _} = Links.add(ctx.alice_scope, ctx.s2.ident, ctx.s1.ident, "depends_on")

      {:ok, %{"children" => [_, s2, _]}} =
        MCPClient.call_tool(ctx.token, MCPClient.handshake(ctx.token), "get_task", %{
          task_id: ctx.epic.ident
        })

      # A managed assignee without a run still waits for start: start_task
      # defers its run until the prerequisites are done (decision 13).
      assert %{"waiting_for" => "start", "orchestrable" => nil} = s2
      assert s2["blocked_by"] == [ctx.s1.ident]
    end

    test "start_task starts the step's assignee; refusals in English", ctx do
      sid = MCPClient.handshake(ctx.run_token)

      assert {:ok, %{"result" => "queued", "run" => %{"agent" => "keel/review"}}} =
               MCPClient.call_tool(ctx.run_token, sid, "start_task", %{
                 task_id: ctx.s2.ident,
                 instructions: "PPU first"
               })

      assert {:ok, %{"result" => "already"}} =
               MCPClient.call_tool(ctx.run_token, sid, "start_task", %{task_id: ctx.s2.ident})

      assert {:error, text} =
               MCPClient.call_tool(ctx.run_token, sid, "start_task", %{task_id: ctx.s3.ident})

      assert text ==
               "#{ctx.s3.ident} has no assignee. Assign it with " <>
                 "update_task(task_id, assignee, start: true)."

      assert {:error, text} =
               MCPClient.call_tool(ctx.run_token, sid, "update_task", %{
                 task_id: ctx.s2.ident,
                 title: "PPU only"
               })

      assert text ==
               "When orchestrating #{ctx.s2.ident} you may only change assignee and start. " <>
                 "Put guidance in start_task instructions instead."
    end
  end

  test "start_task for another caller is forbidden", ctx do
    assert {:error, text} =
             MCPClient.call_tool(ctx.token, MCPClient.handshake(ctx.token), "start_task", %{
               task_id: ctx.step.ident
             })

    assert text =~ "cannot do this"
  end

  test "get_task of an epic: each step has waiting_for, blocked_by and orchestrable", ctx do
    {:ok, %{"children" => [step]}} =
      MCPClient.call_tool(ctx.token, MCPClient.handshake(ctx.token), "get_task", %{
        task_id: ctx.epic.ident
      })

    assert step["id"] == ctx.step.ident
    assert Map.has_key?(step, "waiting_for")
    assert step["blocked_by"] == []
    # Not a run token: null.
    assert Map.fetch!(step, "orchestrable") == nil

    token = leader_token(ctx, ~w(read write_task create_tasks delegate))

    {:ok, %{"children" => [step]}} =
      MCPClient.call_tool(token, MCPClient.handshake(token), "get_task", %{
        task_id: ctx.epic.ident
      })

    assert is_boolean(step["orchestrable"])
  end

  test "a forbidden write of an orchestrating run points at orchestration", ctx do
    run =
      run_fixture(ctx.lead, %{
        task_id: ctx.epic.id,
        squad_id: ctx.squad.id,
        status: :running,
        capabilities: ~w(read write_task create_tasks delegate)
      })

    {scope, _token} = run_scope_fixture(run)
    caps = ~w(read write_task create_tasks delegate orchestrate)
    scope = %{scope | run: %{scope.run | capabilities: caps}}
    error_ctx = %Context{tool: "transition_task", args: %{}, scope: scope, session: nil}

    assert ErrorText.format(:forbidden, error_ctx) ==
             {:ok,
              "This run can only read the workspace and change #{ctx.epic.ident} " <>
                "(capabilities: read, write_task, create_tasks, delegate, orchestrate). As the " <>
                "squad's leader it may also orchestrate the tasks of the Orchestration section " <>
                "of its prompt: start_task, update_task with assignee and start, and " <>
                "link_tasks / unlink_tasks with depends_on; not move them or change anything " <>
                "else. Ask a human to do anything else."}

    plain = %{scope.run | capabilities: ~w(read write_task)}
    plain_ctx = %{error_ctx | scope: %{scope | run: plain}}

    assert ErrorText.format(:forbidden, plain_ctx) ==
             {:ok,
              "This run can only read the workspace and change #{ctx.epic.ident} " <>
                "(capabilities: read, write_task). Ask a human to do anything else."}
  end

  # Decision 16.
  test "the English text of each orchestration error", ctx do
    run =
      run_fixture(ctx.lead, %{task_id: ctx.epic.id, squad_id: ctx.squad.id, status: :running})

    {scope, _token} = run_scope_fixture(run)
    error_ctx = %Context{tool: "update_task", args: %{"task_id" => "ACC-12"}, scope: scope}

    texts = [
      {{:orchestration, :outside, "ACC-21", "ACC-10"},
       "ACC-21 is not part of ACC-10, which you lead in this run. You may only orchestrate " <>
         "its steps and the tasks your squad created for it."},
      {{:orchestration, :outside, "ACC-21", nil},
       "ACC-21 is not part of a task you lead in this run. You may only orchestrate the " <>
         "steps of the epic or task your squad owns and the tasks your squad created for it."},
      {{:orchestration, :root, "ACC-10"},
       "ACC-10 is the task you lead; you cannot reassign or start it. Change it from a run " <>
         "on ACC-10, or ask a person."},
      {{:orchestration, :fields, ["assignee", "start"]},
       "When orchestrating ACC-12 you may only change assignee and start. Put guidance in " <>
         "start_task instructions instead."},
      {{:orchestration, :outside_assignee, "ACC-14", "carol"},
       "ACC-14 is assigned to carol, who is not in web-team. Ask a person to reassign it."},
      {{:orchestration, :not_member, "carol/dev", "web-team"},
       "carol/dev is not a member of web-team. Assign the task to a member (see the Squad " <>
         "section) or leave it unassigned."},
      {{:orchestration, :no_assignee, "ACC-13"},
       "ACC-13 has no assignee. Assign it with update_task(task_id, assignee, start: true)."},
      {{:orchestration, :person_assignee, "ACC-15", "bob"},
       "ACC-15 is assigned to bob, a person; Helmsman cannot start people. Write a question " <>
         "if you need bob, or reassign the task."},
      {{:orchestration, :not_managed, "ACC-15", "bob/cli"},
       "ACC-15 is assigned to bob/cli, which Helmsman does not run (not a managed agent). " <>
         "Reassign it to a member agent, or ask a person."},
      {{:orchestration, :link_type},
       "When orchestrating you may only add or remove depends_on links."},
      {{:orchestration, :not_leader, "web-team"},
       "You no longer lead the squad web-team: you cannot delegate. End this run."},
      {{:orchestration, :squad_disabled, "web-team"},
       "The squad web-team is disabled: nothing can be delegated. End this run."}
    ]

    for {reason, text} <- texts do
      assert ErrorText.format(reason, error_ctx) == {:ok, text}, inspect(reason)
    end
  end
end
