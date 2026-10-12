defmodule Helmsman.GitHub.LockTest do
  # Background writes, imports and user writes commit on separate
  # connections outside the sandbox.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Events
  alias Helmsman.GitHub
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Workers.SyncRepositories
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Tx

  setup do
    {owner, workspace, installation} =
      CommittedData.unboxed(fn ->
        owner = user_fixture()
        workspace = workspace_fixture(owner)
        {owner, workspace, installation_fixture(workspace)}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    scope = CommittedData.unboxed(fn -> workspace_scope_fixture(owner, workspace) end)
    %{scope: scope, workspace: workspace, installation: installation}
  end

  # Holds the workspace's exclusive maintenance lock (an import) until told
  # to release it.
  defp hold_import_lock(workspace) do
    test = self()

    task =
      Task.async(fn ->
        CommittedData.unboxed(fn -> import_until_released(workspace, test) end)
      end)

    assert_receive :import_locked, 5_000
    task
  end

  defp import_until_released(workspace, test) do
    Tx.run(fn ->
      Locks.maint_exclusive!(workspace.id)
      send(test, :import_locked)

      receive do
        :release -> {:ok, :released}
      end
    end)
  end

  # Runs `fun` on its own connection; reports the backend pid first.
  defp start_unboxed(fun) do
    test = self()

    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(test, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  defp await_blocked(task) do
    pid = task.pid
    assert_receive {:backend, ^pid, backend}, 5_000
    CommittedData.await_lock_wait(backend)
    assert Task.yield(task, 50) == nil
  end

  test "system_write/2 waits for an import, then completes", %{
    workspace: ws,
    installation: installation
  } do
    import_task = hold_import_lock(ws)

    writer =
      start_unboxed(fn ->
        Installations.system_write(installation.installation_id, fn row ->
          {:ok, row.id}
        end)
      end)

    await_blocked(writer)
    send(import_task.pid, :release)
    assert {:ok, :released} = Task.await(import_task)
    assert Task.await(writer) == {:ok, installation.id}
  end

  test "a sync waiting for an import writes after it", %{
    workspace: ws,
    installation: installation
  } do
    stub_github(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", _} ->
          token_response(conn)

        {"GET", "/installation/repositories"} ->
          Req.Test.json(conn, %{"repositories" => [github_repo(1, "acme", "web")]})
      end
    end)

    import_task = hold_import_lock(ws)

    sync =
      start_unboxed(fn ->
        perform_job(SyncRepositories, %{installation_id: installation.installation_id})
      end)

    await_blocked(sync)

    assert [] ==
             CommittedData.unboxed(fn ->
               Repo.all(from(r in Repository, where: r.installation_id == ^installation.id))
             end)

    send(import_task.pid, :release)
    Task.await(import_task)
    assert :ok = Task.await(sync)

    assert [%Repository{name: "web"}] =
             CommittedData.unboxed(fn ->
               Repo.all(from(r in Repository, where: r.installation_id == ^installation.id))
             end)
  end

  test "sync, disconnect and refresh in parallel: no deadlock, one notification per commit", %{
    scope: scope,
    workspace: ws,
    installation: installation
  } do
    Events.subscribe(Events.topic(:workspace, ws.id))
    id = installation.installation_id
    details = {:ok, %{account_login: "acme", account_type: "Organization", suspended_at: nil}}

    for _round <- 1..10 do
      reset(installation)
      test = self()
      now = DateTime.utc_now()

      racers = [
        fn -> Installations.apply_repositories(id, [github_repo(1, "acme", "web")], now) end,
        fn -> Installations.apply_refresh(id, details, now) end,
        fn -> GitHub.disconnect_installation(scope) end
      ]

      tasks =
        for racer <- racers do
          Task.async(fn ->
            CommittedData.unboxed(fn ->
              send(test, {:ready, self()})

              receive do
                :go -> racer.()
              end
            end)
          end)
        end

      for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid, 5_000)
      for task <- tasks, do: send(task.pid, :go)
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      committed =
        Enum.count(results, fn
          {:ok, :applied} -> true
          {:ok, %Installation{}} -> true
          _ -> false
        end)

      # The disconnect always commits.
      assert {:ok, %Installation{}} = List.last(results)
      for _ <- 1..committed, do: assert_receive({:github_changed}, 1_000)
      refute_receive {:github_changed}, 50

      # Whatever the order, the installation ends disconnected with every
      # repository removed.
      CommittedData.unboxed(fn ->
        assert Repo.get!(Installation, installation.id).disconnected_at

        assert Repo.all(
                 from(r in Repository,
                   where: r.installation_id == ^installation.id and is_nil(r.removed_at)
                 )
               ) == []
      end)
    end
  end

  defp reset(installation) do
    CommittedData.unboxed(fn ->
      Repo.update_all(from(i in Installation, where: i.id == ^installation.id),
        set: [
          disconnected_at: nil,
          fetched_at: DateTime.add(DateTime.utc_now(), -3600),
          repos_fetched_at: nil
        ]
      )
    end)
  end
end
