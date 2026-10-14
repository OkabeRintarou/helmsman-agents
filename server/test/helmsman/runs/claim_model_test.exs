defmodule Helmsman.Runs.ClaimModelTest do
  # add-run-model 2.1: the claim records the model it sends
  # (run-lifecycle「领取时记下模型」).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, Runs}
  alias Helmsman.Runs.Run

  setup do
    ctx = dispatch_fixture()

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/sonnet",
      runtime_id: profile(ctx.agent).runtime_id,
      model: "claude-sonnet-4-5"
    })

    Map.merge(ctx, %{
      daemon: daemon_of(ctx.agent),
      sonnet: agent_actor(ctx.workspace, "keel/sonnet")
    })
  end

  defp claim(ctx), do: Runs.claim(daemon_ctx(ctx.daemon), "http://localhost")
  defp reload(run), do: Repo.get!(Run, run.id)

  test "记下所用模型: the model sent, kept after the agent changes (scenario)", ctx do
    run = run_fixture(ctx.sonnet)
    assert reload(run).model == nil
    assert [%{model: nil}] = Runs.summaries([reload(run)])

    assert {:ok, [spec]} = claim(ctx)
    assert spec.run_id == run.id
    assert spec.agent.model == "claude-sonnet-4-5"
    assert reload(run).model == "claude-sonnet-4-5"

    {:ok, _} = Agents.update(ctx.alice_scope, "keel/sonnet", %{model: "claude-opus-4-1"})

    assert reload(run).model == "claude-sonnet-4-5"
    assert {:ok, %{model: "claude-sonnet-4-5"}} = Runs.get(ctx.alice_scope, run.id)
    assert [%{model: "claude-sonnet-4-5"}] = Runs.summaries([reload(run)])
  end

  test "CLI 缺省: an agent without a model records nil (scenario)", ctx do
    run = run_fixture(ctx.agent)
    assert {:ok, [%{agent: %{model: nil}}]} = claim(ctx)
    assert %Run{status: :claimed, model: nil} = reload(run)
  end
end
