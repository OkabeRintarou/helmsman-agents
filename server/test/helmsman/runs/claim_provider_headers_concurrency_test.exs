defmodule Helmsman.Runs.ClaimProviderHeadersConcurrencyTest do
  use ExUnit.Case, async: false
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, CommittedData, LockHarness, ProviderAccounts, Repo, Runs}
  alias Helmsman.Runs.Run

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture(%{provider: "codex"})
        account = provider_account_fixture(ctx.alice, %{cli: "codex"})

        assert {:ok, _} =
                 Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: account.id})

        Map.merge(ctx, %{
          account: account,
          daemon: daemon_of(ctx.agent),
          run: run_fixture(ctx.agent)
        })
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  test "a concurrent writer leaves an old connection's candidate queued without waiting", ctx do
    update =
      LockHarness.start(
        fn ->
          ProviderAccounts.update(Scope.for_user(ctx.alice), ctx.account.id, %{
            headers: %{"set" => %{"user" => "HEADER_RACE_SENTINEL"}}
          })
        end,
        pause: :commit
      )

    LockHarness.await_paused(update)

    claim =
      LockHarness.start(fn ->
        Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 4}, "http://localhost")
      end)

    assert {:ok, []} = LockHarness.result(claim)
    LockHarness.continue(update)
    assert {:ok, _} = LockHarness.result(update)

    CommittedData.unboxed(fn ->
      assert Repo.get!(Run, ctx.run.id).status == :queued
      assert {:ok, []} = Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 4}, "http://localhost")
    end)
  end

  test "claim keeps its checked account stable until its transaction commits", ctx do
    claim = fn -> Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 4}, "http://localhost") end

    update = fn ->
      ProviderAccounts.update(Scope.for_user(ctx.alice), ctx.account.id, %{
        headers: %{"set" => %{"user" => "HEADER_RACE_SENTINEL"}}
      })
    end

    {result, updated} = LockHarness.interleave(claim, :commit, update)
    assert {:ok, [%{agent: %{provider_account: %{headers: []}}}]} = result
    assert {:ok, %{headers: ["user"]}} = updated
  end

  test "two patches serialize and preserve independently added headers", ctx do
    update = fn name ->
      fn ->
        ProviderAccounts.update(Scope.for_user(ctx.alice), ctx.account.id, %{
          headers: %{"set" => %{name => "HEADER_RACE_SENTINEL"}}
        })
      end
    end

    {first, second} = LockHarness.interleave(update.("X-First"), :commit, update.("X-Second"))
    assert {:ok, %{headers: ["X-First"]}} = first
    assert {:ok, %{headers: ["X-First", "X-Second"]}} = second
  end
end
