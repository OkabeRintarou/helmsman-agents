defmodule Helmsman.Filters.ConcurrencyTest do
  use ExUnit.Case, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Ecto.Query
  alias Helmsman.{CommittedData, Filters, Repo}
  alias Helmsman.Filters.SavedFilter

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        user = user_fixture()
        workspace = workspace_fixture(user)
        %{user: user, scope: workspace_scope_fixture(user, workspace)}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.user.id]) end)
    ctx
  end

  test "two simultaneous creates cannot exceed the per-owner quota", ctx do
    CommittedData.unboxed(fn ->
      now = DateTime.utc_now()

      rows =
        for n <- 1..99,
            do: %{
              workspace_id: ctx.scope.workspace.id,
              owner_id: ctx.user.id,
              name: "f#{n}",
              bql: "status = new",
              visibility: :private,
              lock_version: 1,
              inserted_at: now,
              updated_at: now
            }

      Repo.insert_all(SavedFilter, rows)
    end)

    parent = self()

    jobs =
      for n <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              CommittedData.unboxed(fn ->
                Filters.create(ctx.scope, %{name: "new#{n}", bql: "status = new"})
              end)
          end
        end)
      end

    for _ <- jobs do
      assert_receive {:ready, pid}
      send(pid, :go)
    end

    results = Enum.map(jobs, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    assert CommittedData.unboxed(fn ->
             Repo.aggregate(
               from(f in SavedFilter, where: f.workspace_id == ^ctx.scope.workspace.id),
               :count
             )
           end) == 100
  end

  test "two writers with one version produce one success and one stale", ctx do
    {:ok, f} =
      CommittedData.unboxed(fn ->
        Filters.create(ctx.scope, %{name: "version", bql: "status = new"})
      end)

    results =
      1..2
      |> Task.async_stream(
        fn n ->
          CommittedData.unboxed(fn ->
            Filters.update(ctx.scope, f.id, %{name: "v#{n}", lock_version: f.lock_version})
          end)
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale} in results

    assert {:ok, %{lock_version: 2}} =
             CommittedData.unboxed(fn -> Filters.get(ctx.scope, f.id) end)
  end

  test "standalone task query runs read-only and restores transaction settings", ctx do
    previous_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(
        Keyword.merge(Repo.config(), name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)
      )

    Repo.put_dynamic_repo(pid)

    try do
      Process.put(:helmsman_bql_query_hook, fn ->
        assert %{rows: [["on"]]} = Repo.query!("SHOW transaction_read_only")
        assert %{rows: [["repeatable read"]]} = Repo.query!("SHOW transaction_isolation")
        assert %{rows: [["5s"]]} = Repo.query!("SHOW statement_timeout")
      end)

      assert {:ok, %{tasks: [], total: 0}} = Helmsman.Tasks.query(ctx.scope, "")
      Process.delete(:helmsman_bql_query_hook)
      assert %{rows: [["off"]]} = Repo.query!("SHOW transaction_read_only")
      assert %{rows: [["0"]]} = Repo.query!("SHOW statement_timeout")
    after
      Process.delete(:helmsman_bql_query_hook)
      Repo.put_dynamic_repo(previous_repo)
      Supervisor.stop(pid)
    end
  end
end
