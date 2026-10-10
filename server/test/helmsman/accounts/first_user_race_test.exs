defmodule Helmsman.Accounts.FirstUserRaceTest do
  # Registrations run on their own connections outside the SQL sandbox and
  # really commit, so this module must not run concurrently with others.
  use ExUnit.Case, async: false

  @moduletag :db_race

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts
  alias Helmsman.Actors.Actor
  alias Helmsman.Repo
  alias Helmsman.Workspaces.{Membership, Workspace}

  @racers 10

  setup do
    previous_mode = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :registration_race_delay_ms, 200)

    on_exit(fn ->
      Application.put_env(:helmsman, :signup_mode, previous_mode)
      Application.delete_env(:helmsman, :registration_race_delay_ms)
    end)

    # Data cleanup is registered only once the instance is known to be empty,
    # and it deletes only the rows created by this test's racers.
    unboxed(fn -> assert Repo.aggregate(Accounts.User, :count) == 0 end)

    tag = System.unique_integer([:positive])
    on_exit(fn -> unboxed(fn -> delete_racer_data(tag) end) end)

    %{tag: tag}
  end

  for mode <- [:invite, :open] do
    test "exactly one of #{@racers} concurrent first registrations becomes admin (#{mode})",
         %{tag: tag} do
      Application.put_env(:helmsman, :signup_mode, unquote(mode))

      results = race(@racers, tag)

      backend_pids = Enum.map(results, fn {backend_pid, _result} -> backend_pid end)
      assert length(Enum.uniq(backend_pids)) == @racers

      created = for {_pid, {:ok, user}} <- results, do: user
      rejected = for {_pid, {:error, reason}} <- results, do: reason

      assert Enum.count(created, & &1.instance_admin) == 1

      unboxed(fn ->
        assert Repo.aggregate(from_admins(), :count) == 1
        assert Repo.aggregate(from(w in Workspace, where: w.slug == "default"), :count) == 1
      end)

      case unquote(mode) do
        :invite ->
          assert length(created) == 1
          assert rejected == List.duplicate(:signup_closed, @racers - 1)

        :open ->
          assert length(created) == @racers
          assert rejected == []
      end

      unboxed(fn -> delete_racer_data(tag) end)
    end
  end

  # Starts `n` processes that each check out their own connection, wait at a
  # barrier and then register at the same time.
  defp race(n, tag) do
    parent = self()

    tasks = for i <- 1..n, do: Task.async(fn -> unboxed_racer(parent, racer_email(tag, i)) end)

    racers =
      for _ <- 1..n do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(racers, &send(&1, :go))
    Task.await_many(tasks, 30_000)
  end

  defp unboxed_racer(parent, email), do: unboxed(fn -> racer(parent, email) end)

  defp racer(parent, email) do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:ready, self()})

    receive do
      :go -> :ok
    end

    {backend_pid, Accounts.register_user(%{email: email})}
  end

  defp racer_email(tag, i), do: "racer#{i}-#{tag}@race.test"

  defp from_admins do
    from(u in Accounts.User, where: u.instance_admin)
  end

  # Deletes, children first, the racers' users and the workspaces they own
  # (the first user's `default`), leaving every other row alone.
  defp delete_racer_data(tag) do
    emails = for i <- 1..@racers, do: racer_email(tag, i)
    user_ids = Repo.all(from(u in Accounts.User, where: u.email in ^emails, select: u.id))

    workspace_ids =
      Repo.all(
        from(m in Membership,
          where: m.user_id in ^user_ids and m.role == :owner,
          select: m.workspace_id
        )
      )

    Repo.delete_all(from(t in Accounts.UserToken, where: t.user_id in ^user_ids))
    Repo.delete_all(from(m in Membership, where: m.workspace_id in ^workspace_ids))
    Repo.delete_all(from(a in Actor, where: a.workspace_id in ^workspace_ids))
    Repo.delete_all(from(w in Workspace, where: w.id in ^workspace_ids))
    Repo.delete_all(from(u in Accounts.User, where: u.id in ^user_ids))
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
