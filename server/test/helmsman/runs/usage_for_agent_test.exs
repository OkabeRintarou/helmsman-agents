defmodule Helmsman.Runs.UsageForAgentTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, QueryCount, Runs}

  setup do
    ctx = dispatch_fixture()
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    Map.put(ctx, :viewer_scope, viewer_scope)
  end

  defp ended(agent, status, finished_at, usage \\ nil),
    do: run_fixture(agent, %{status: status, finished_at: finished_at, usage: usage})

  defp usage(input, output \\ nil, cost \\ nil),
    do: %{
      "input_tokens" => input,
      "output_tokens" => output,
      "cache_read_tokens" => nil,
      "cache_write_tokens" => nil,
      "cost_usd" => cost
    }

  defp at(date, time) do
    datetime = DateTime.new!(date, time, "Etc/UTC")
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
  end

  test "buckets by UTC day, filling missing days", ctx do
    today = Date.utc_today()
    now = DateTime.utc_now()
    ended(ctx.agent, :succeeded, now, usage(100, 7))
    ended(ctx.agent, :succeeded, now, usage(50))
    ended(ctx.agent, :failed, now)
    # Outside the 7 days, or not ended: not counted.
    ended(ctx.agent, :succeeded, at(Date.add(today, -7), ~T[12:00:00]), usage(1000))
    run_fixture(ctx.agent, %{status: :running})

    {result, queries} =
      QueryCount.count(fn -> Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: 7) end)

    assert {:ok, %{days: days, totals: totals}} = result
    assert queries == 2
    assert Enum.map(days, & &1.date) == Enum.to_list(Date.range(Date.add(today, -6), today))

    assert List.last(days) == %{
             date: today,
             succeeded: 2,
             failed: 1,
             cancelled: 0,
             input_tokens: 150,
             output_tokens: 7,
             cost_usd: nil
           }

    for day <- Enum.drop(days, -1) do
      assert %{succeeded: 0, failed: 0, cancelled: 0, input_tokens: 0, output_tokens: 0} = day
      assert day.cost_usd == nil
    end

    assert totals == %{runs: 3, input_tokens: 150, output_tokens: 7, cost_usd: nil}
  end

  test "an agent without runs gets zeros, not :not_found", ctx do
    assert {:ok, %{days: days, totals: totals}} =
             Runs.usage_for_agent(ctx.viewer_scope, "keel/dev")

    assert length(days) == 30
    assert Enum.all?(days, &(&1.succeeded + &1.failed + &1.cancelled == 0))
    assert totals == %{runs: 0, input_tokens: 0, output_tokens: 0, cost_usd: nil}
  end

  test "finished_at around UTC midnight lands on its own day", ctx do
    today = Date.utc_today()
    ended(ctx.agent, :cancelled, at(Date.add(today, -1), ~T[23:59:59.999999]))
    ended(ctx.agent, :succeeded, at(today, ~T[00:00:00]))

    {:ok, %{days: [yesterday, today_bucket]}} =
      Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: 2)

    assert %{cancelled: 1, succeeded: 0} = yesterday
    assert %{cancelled: 0, succeeded: 1, date: ^today} = today_bucket
  end

  test "the cost is nil only when no run of the day reported one", ctx do
    today = Date.utc_today()
    yesterday = at(Date.add(today, -1), ~T[10:00:00])
    ended(ctx.agent, :succeeded, yesterday, usage(1, 1, nil))
    ended(ctx.agent, :succeeded, yesterday, usage(1, 1, nil))
    ended(ctx.agent, :succeeded, DateTime.utc_now(), usage(1, 1, 0.25))
    ended(ctx.agent, :failed, DateTime.utc_now(), usage(1, 1, nil))
    ended(ctx.agent, :failed, DateTime.utc_now(), usage(1, 1, 0.5))

    {:ok, %{days: [first, last], totals: totals}} =
      Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: 2)

    assert first.cost_usd == nil
    assert last.cost_usd == 0.75
    assert totals.cost_usd == 0.75
    assert totals.runs == 5
  end

  test "an archived agent counts; external and unknown agents are not found", ctx do
    ended(ctx.agent, :succeeded, DateTime.utc_now())
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")

    assert {:ok, %{totals: %{runs: 1}}} =
             Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: 1)

    Repo.insert!(
      Actor.create_changeset(
        %Actor{workspace_id: ctx.workspace.id, owner_id: ctx.alice.id, kind: :agent},
        %{name: "outside/bot"}
      )
    )

    assert {:error, :not_found} = Runs.usage_for_agent(ctx.viewer_scope, "outside/bot")
    assert {:error, :not_found} = Runs.usage_for_agent(ctx.viewer_scope, "nope")
  end

  test "another workspace's agent is not found", ctx do
    other = dispatch_fixture()
    managed_agent_fixture(other.alice_scope, %{name: "other/dev"})
    assert {:error, :not_found} = Runs.usage_for_agent(ctx.viewer_scope, "other/dev")
  end

  test "days must be 1 to 90", ctx do
    for days <- [0, 91, -1, "7", nil] do
      assert {:error, :invalid_days} =
               Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: days)
    end

    assert {:ok, %{days: days}} = Runs.usage_for_agent(ctx.viewer_scope, "keel/dev", days: 90)
    assert length(days) == 90
  end

  test "needs :view_runs", ctx do
    assert {:error, :forbidden} =
             Runs.usage_for_agent(%{ctx.viewer_scope | role: nil}, "keel/dev")
  end
end
