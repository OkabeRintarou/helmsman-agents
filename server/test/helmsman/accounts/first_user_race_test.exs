defmodule Helmsman.Accounts.FirstUserRaceTest do
  # Registrations run on their own connections outside the SQL sandbox and
  # really commit, so this module must not run concurrently with others.
  use ExUnit.Case, async: false

  @moduletag :db_race

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts
  alias Helmsman.Repo

  @racers 10

  setup do
    previous_mode = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :registration_race_delay_ms, 200)

    unboxed(fn -> assert Repo.aggregate(Accounts.User, :count) == 0 end)

    on_exit(fn ->
      Application.put_env(:helmsman, :signup_mode, previous_mode)
      Application.delete_env(:helmsman, :registration_race_delay_ms)
      unboxed(&delete_committed_users/0)
    end)
  end

  for mode <- [:invite, :open] do
    test "exactly one of #{@racers} concurrent first registrations becomes admin (#{mode})" do
      Application.put_env(:helmsman, :signup_mode, unquote(mode))

      results = race(@racers)

      backend_pids = Enum.map(results, fn {backend_pid, _result} -> backend_pid end)
      assert length(Enum.uniq(backend_pids)) == @racers

      created = for {_pid, {:ok, user}} <- results, do: user
      rejected = for {_pid, {:error, reason}} <- results, do: reason

      assert Enum.count(created, & &1.instance_admin) == 1

      unboxed(fn ->
        assert Repo.aggregate(from_admins(), :count) == 1
      end)

      case unquote(mode) do
        :invite ->
          assert length(created) == 1
          assert rejected == List.duplicate(:signup_closed, @racers - 1)

        :open ->
          assert length(created) == @racers
          assert rejected == []
      end

      unboxed(&delete_committed_users/0)
    end
  end

  # Starts `n` processes that each check out their own connection, wait at a
  # barrier and then register at the same time.
  defp race(n) do
    parent = self()

    tasks = for i <- 1..n, do: Task.async(fn -> unboxed_racer(parent, i) end)

    racers =
      for _ <- 1..n do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(racers, &send(&1, :go))
    Task.await_many(tasks, 30_000)
  end

  defp unboxed_racer(parent, i), do: unboxed(fn -> racer(parent, i) end)

  defp racer(parent, i) do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:ready, self()})

    receive do
      :go -> :ok
    end

    {backend_pid, Accounts.register_user(%{email: "racer#{i}@example.com"})}
  end

  defp from_admins do
    import Ecto.Query
    from(u in Accounts.User, where: u.instance_admin)
  end

  defp delete_committed_users do
    Repo.delete_all(Accounts.UserToken)
    Repo.delete_all(Accounts.User)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
