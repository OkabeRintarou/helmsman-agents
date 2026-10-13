defmodule HelmsmanWeb.AgentLive.RunsTest do
  @moduledoc """
  Spec web-agents Agent 列表页（运行开始、最近运行）and Agent 详情页「运行」「用量」 on real
  runs (tasks 4.7; design D3, D4, D8a).
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.{Repo, Runs, Tx}
  alias Helmsman.Runs.Run
  alias HelmsmanWeb.AgentLive.Index

  @t0 ~U[2026-10-01 08:00:00.000000Z]

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    slug = ctx.workspace.slug

    Map.merge(ctx, %{
      conn: conn,
      index: "/w/#{slug}/agents",
      show: "/w/#{slug}/agents/keel/dev"
    })
  end

  defp open(ctx, path), do: live(log_in_user(ctx.conn, ctx.alice), path)

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # A finished run created at `at(n)`.
  defp finished_run(ctx, n, attrs \\ %{}) do
    run_fixture(
      ctx.agent,
      Map.merge(
        %{
          status: :succeeded,
          inserted_at: at(n),
          claimed_at: at(n),
          started_at: at(n),
          finished_at: at(n + 30)
        },
        attrs
      )
    )
  end

  defp history_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#agent-run-rows > tr[id^=run-row-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn id -> id |> String.replace_prefix("run-row-", "") |> String.to_integer() end)
  end

  defp notify(run_id), do: Tx.run(fn -> {:ok, Runs.notify_run(Repo.get!(Run, run_id))} end)

  describe "the list" do
    test "a run starting: 忙碌（1）, one fewer queued, and 最近运行", ctx do
      first = run_fixture(ctx.agent)
      run_fixture(ctx.agent, %{inserted_at: DateTime.add(DateTime.utc_now(), 1)})
      {:ok, view, _html} = open(ctx, ctx.index)
      row = "#agent-#{Index.dom_key("keel/dev")}"

      assert has_element?(view, "#{row} [data-queued]", "2")
      assert has_element?(view, "#agent-#{Index.dom_key("keel/dev")}-last-run")

      # The daemon takes one run at a time.
      Repo.update!(Ecto.Changeset.change(daemon_of(ctx.agent), max_concurrency: 1))
      assert claim!(ctx.agent) == [first.id]
      start!(ctx.agent, first.id)

      eventually(fn ->
        has_element?(view, ~s(#{row} [data-agent-status="busy"]), "忙碌（1）")
      end)

      assert has_element?(view, "#{row} [data-queued]", "1")
    end
  end

  describe "the 运行 tab" do
    test "an early queued run shows above 120 finished ones; history pages by 50", ctx do
      queued = run_fixture(ctx.agent, %{inserted_at: at(0)})
      for n <- 1..120, do: finished_run(ctx, n * 60)

      {:ok, view, _html} = open(ctx, ctx.show)
      assert has_element?(view, ~s(#run-card-#{queued.id} [data-run-status="queued"]))
      assert has_element?(view, "#agent-runs-history [data-total]", "120")
      assert length(history_ids(view)) == 50

      view |> element("#agent-run-rows-more") |> render_click()
      assert length(history_ids(view)) == 100
      view |> element("#agent-run-rows-more") |> render_click()
      assert length(history_ids(view)) == 120
      refute has_element?(view, "#agent-run-rows-more")
    end

    test "an old run that ends later takes its place in the history", ctx do
      old = running_run!(ctx.agent, %{inserted_at: at(30)})
      finished = for n <- 1..120, do: finished_run(ctx, n * 60)

      {:ok, view, _html} = open(ctx, ctx.show)
      view |> element("#agent-run-rows-more") |> render_click()
      shown = history_ids(view)
      assert length(shown) == 100

      finish!(ctx.agent, old.id)

      eventually(fn -> has_element?(view, "#agent-runs-history [data-total]", "121") end)
      assert Enum.take(history_ids(view), 100) == shown
      refute has_element?(view, "#run-card-#{old.id}")

      view |> element("#agent-run-rows-more") |> render_click()
      ids = history_ids(view)
      expected = Enum.map(Enum.reverse(finished), & &1.id) ++ [old.id]
      assert ids == expected
    end

    test "more than 50 queued: 还有 n 条排队中, and a raised priority is re-read", ctx do
      queued = for n <- 1..60, do: run_fixture(ctx.agent, %{inserted_at: at(n), priority: 1})

      {:ok, view, _html} = open(ctx, ctx.show)
      assert has_element?(view, "#agent-runs-more-pending", "还有 10 条排队中")
      last = List.last(queued)
      refute has_element?(view, "#run-card-#{last.id}")

      # A merge raises the priority of an unshown run: it moves to the front, no duplicate.
      set_run!(last.id, priority: 3)
      notify(last.id)
      eventually(fn -> has_element?(view, "#run-card-#{last.id}") end)
      assert has_element?(view, "#agent-runs-more-pending", "还有 10 条排队中")

      view |> element("#agent-runs-more-pending") |> render_click()
      refute has_element?(view, "#agent-runs-more-pending")
      for run <- queued, do: assert(has_element?(view, "#run-card-#{run.id}"))
    end

    test "a running card; when it ends it becomes the first history row", ctx do
      finished_run(ctx, 0)
      run = running_run!(ctx.agent)

      {:ok, view, _html} = open(ctx, ctx.show)
      assert has_element?(view, ~s(#run-card-#{run.id} [data-run-status="running"]))

      finish!(ctx.agent, run.id, :failed, %{failure_reason: :provider_quota})
      eventually(fn -> not has_element?(view, "#run-card-#{run.id}") end)
      assert hd(history_ids(view)) == run.id
    end
  end

  describe "the 用量 tab" do
    test "bars per day and totals; no cost when every cost is nil", ctx do
      today = DateTime.utc_now()

      finished_run(ctx, 0, %{
        finished_at: today,
        usage: %{"input_tokens" => 1200, "output_tokens" => 340, "cost_usd" => nil}
      })

      finished_run(ctx, 1, %{
        status: :failed,
        failure_reason: :provider_quota,
        finished_at: today,
        usage: %{"input_tokens" => 1_000_000, "output_tokens" => 0, "cost_usd" => nil}
      })

      {:ok, view, _html} = open(ctx, ctx.show <> "?tab=usage")
      assert has_element?(view, "#agent-usage-bars [data-usage-day]")
      assert has_element?(view, "#agent-usage-bars rect.fill-success")
      assert has_element?(view, "#agent-usage-bars rect.fill-danger")
      assert has_element?(view, "#agent-usage-runs", "2")
      assert has_element?(view, "#agent-usage-input", "1,001,200")
      assert has_element?(view, "#agent-usage-output", "340")
      refute has_element?(view, "#agent-usage-cost")
    end

    test "the cost when known, and the empty state", ctx do
      {:ok, view, _html} = open(ctx, ctx.show <> "?tab=usage")
      assert has_element?(view, "#agent-usage-empty", "近 30 天没有运行")

      finished_run(ctx, 0, %{
        finished_at: DateTime.utc_now(),
        usage: %{"input_tokens" => 10, "output_tokens" => 5, "cost_usd" => 0.125}
      })

      {:ok, view, _html} = open(ctx, ctx.show <> "?tab=usage")
      assert has_element?(view, "#agent-usage-cost", "$0.13")
    end
  end
end
