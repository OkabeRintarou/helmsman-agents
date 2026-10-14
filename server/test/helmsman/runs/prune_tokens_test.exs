defmodule Helmsman.Runs.PruneTokensTest do
  # server-release "清理过期数据": run tokens (add-release-distribution decision 8).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.RunsFixtures

  alias Helmsman.Runs.{RunToken, RunTokens}
  alias Helmsman.Runs.Workers.PruneTokens

  setup do
    dispatch_fixture()
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  # A run in `status` with its token (issued `issued_days_ago`).
  defp run_with_token(ctx, status, attrs \\ %{}, issued_days_ago \\ 0) do
    run = run_fixture(ctx.agent, Map.merge(%{status: status}, attrs))
    {:ok, token} = RunTokens.issue(run, now: days_ago(issued_days_ago))
    {run, token}
  end

  defp token_row?(run), do: Repo.exists?(from(t in RunToken, where: t.run_id == ^run.id))

  test "a run that ended 10 days ago loses its token; a running one keeps a valid token (scenario)",
       ctx do
    {ended, _} = run_with_token(ctx, :succeeded, %{finished_at: days_ago(10)})
    {running, token} = run_with_token(ctx, :running)

    assert PruneTokens.prune() == 1

    refute token_row?(ended)
    assert token_row?(running)
    assert {:ok, %{run: %{id: id}}} = RunTokens.authenticate(token)
    assert id == running.id
  end

  test "tokens that expired over 7 days ago go; recent and valid ones stay", ctx do
    # Expires 24 hours after issue: issued 9 days ago → expired 8 days ago.
    {old, _} = run_with_token(ctx, :running, %{}, 9)
    # Expired 6 days ago, run ended 3 days ago: kept until both are 7 days old.
    {recent, _} = run_with_token(ctx, :succeeded, %{finished_at: days_ago(3)}, 7)
    {claimed, token} = run_with_token(ctx, :claimed)

    assert PruneTokens.prune() == 1
    refute token_row?(old)
    assert token_row?(recent)
    assert token_row?(claimed)
    assert {:ok, _found} = RunTokens.authenticate(token)
  end

  test "one execution deletes at most batch × max_batches rows; the next continues", ctx do
    runs = for _ <- 1..7, do: elem(run_with_token(ctx, :failed, %{finished_at: days_ago(8)}), 0)
    {kept, token} = run_with_token(ctx, :running)

    assert PruneTokens.prune(batch: 2, max_batches: 2) == 4
    assert Enum.count(runs, &token_row?/1) == 3

    assert PruneTokens.prune(batch: 2, max_batches: 2) == 3
    refute Enum.any?(runs, &token_row?/1)

    assert PruneTokens.prune(batch: 2, max_batches: 2) == 0
    assert token_row?(kept)
    assert {:ok, _found} = RunTokens.authenticate(token)
  end

  test "the Oban job prunes", ctx do
    {ended, _} = run_with_token(ctx, :cancelled, %{finished_at: days_ago(30)})
    assert :ok = perform_job(PruneTokens, %{})
    refute token_row?(ended)
  end

  test "it is scheduled daily" do
    crontab =
      :helmsman
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {_expr, PruneTokens} = List.keyfind(crontab, PruneTokens, 1)

    assert {_expr, Helmsman.Accounts.Workers.PruneUserTokens} =
             List.keyfind(crontab, Helmsman.Accounts.Workers.PruneUserTokens, 1)
  end
end
