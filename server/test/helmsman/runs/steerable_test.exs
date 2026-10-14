defmodule Helmsman.Runs.SteerableTest do
  # add-run-steering 1.7: reading the steering state (decision 10) —
  # run-steering「插话状态的读取与通知」.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, dctx: 1]
  import Helmsman.RunsFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.{Feedback, QueryCount, Runs}
  alias Helmsman.Runs.{Run, Steering}

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, viewer_scope: viewer_scope, task: task})
  end

  defp steerable(scope, ctx) do
    assert {:ok, result} = Runs.steerable(scope, ctx.task.ident)
    result
  end

  test "no running run: nil; a claimed one is not steerable", ctx do
    assert steerable(ctx.alice_scope, ctx) == nil
    run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :claimed})
    assert steerable(ctx.alice_scope, ctx) == nil
  end

  test "the running run, for someone who may steer it", ctx do
    run = running_run!(ctx.agent, %{task_id: ctx.task.id})

    assert steerable(ctx.alice_scope, ctx) == %{
             run_id: run.id,
             agent: "keel/dev",
             live: true,
             allowed: true,
             reason: nil
           }
  end

  test "a viewer sees the run but may not steer (scenario)", ctx do
    run = running_run!(ctx.agent, %{task_id: ctx.task.id})

    assert %{run_id: id, agent: "keel/dev", allowed: false, reason: :forbidden} =
             steerable(ctx.viewer_scope, ctx)

    assert id == run.id
  end

  test "a member who may not trigger the agent: unauthorized", ctx do
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    assert %{allowed: false, reason: :unauthorized} = steerable(ctx.bob_scope, ctx)
  end

  test "an external agent identity: not_a_person", ctx do
    running_run!(ctx.agent, %{task_id: ctx.task.id})
    ext = agent_fixture(ctx.workspace, ctx.alice, "alice/cli")
    scope = %{ctx.alice_scope | actor: ext, via: :mcp}
    assert %{allowed: false, reason: :not_a_person} = steerable(scope, ctx)
  end

  test "a Copilot agent's run is not live", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/cop", provider: "copilot"})
    cop = agent_actor(ctx.workspace, "keel/cop")
    running_run!(cop, %{task_id: ctx.task.id})

    assert %{agent: "keel/cop", live: false, allowed: true} = steerable(ctx.alice_scope, ctx)
    refute :copilot in Steering.live_providers()
  end

  test "an unknown task is not_found", ctx do
    assert {:error, :not_found} = Runs.steerable(ctx.alice_scope, ctx.project.key <> "-999")
  end

  describe "the feedback view" do
    setup ctx do
      Map.put(ctx, :run, running_run!(ctx.agent, %{task_id: ctx.task.id}))
    end

    test "after the receipt (scenario)", ctx do
      {:ok, entry} =
        Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "x", steer_run_id: ctx.run.id})

      :ok = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, entry.id)
      {:ok, entry} = Feedback.get(ctx.alice_scope, Feedback.view(entry).id)
      run_id = ctx.run.id

      assert %{run_id: ^run_id, agent: "keel/dev", sent_at: %DateTime{}, acked_at: %DateTime{}} =
               Feedback.view(entry).steer

      {:ok, [listed]} = Feedback.list(ctx.alice_scope, ctx.task.ident)
      assert Feedback.view(listed).steer == Feedback.view(entry).steer
    end

    test "not steered: nil", ctx do
      {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "plain"})
      assert Feedback.view(entry).steer == nil
    end

    test "listing 50 steered records: one query for the steering, whatever their number",
         ctx do
      {:ok, _} =
        Feedback.add(ctx.alice_scope, ctx.task.ident, %{
          content: "steer 0",
          steer_run_id: ctx.run.id
        })

      {_, one} = QueryCount.count(fn -> Feedback.list(ctx.alice_scope, ctx.task.ident) end)

      for n <- 1..49 do
        {:ok, _} =
          Feedback.add(ctx.alice_scope, ctx.task.ident, %{
            content: "steer #{n}",
            steer_run_id: ctx.run.id
          })
      end

      {{:ok, entries}, many} =
        QueryCount.count(fn -> Feedback.list(ctx.alice_scope, ctx.task.ident) end)

      assert length(entries) == 50
      assert Enum.all?(entries, &(Feedback.view(&1).steer != nil))
      assert many == one
      # task, entries, authors, dispatch agent names, steering (no linked
      # records): the steering is the only query added.
      assert many == 5
    end
  end

  test "MCP get_task output keeps its fields", ctx do
    run = running_run!(ctx.agent, %{task_id: ctx.task.id})

    {:ok, _entry} =
      Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "x", steer_run_id: run.id})

    session = mcp_session(ctx.alice, ctx.workspace)
    call!(session, "identify", %{name: "alice/qa"})
    %{"feedback" => [item]} = call!(session, "get_task", %{task_id: ctx.task.ident})

    assert item |> Map.keys() |> Enum.sort() ==
             ~w(at author content dispatch id kind mentions reply_root reply_to seq status superseded_by supersedes target thread_seq)

    assert [dispatch] = item["dispatch"]
    assert dispatch |> Map.keys() |> Enum.sort() == ~w(agent reason result trigger)
    assert Repo.aggregate(Run, :count) == 2
  end
end
