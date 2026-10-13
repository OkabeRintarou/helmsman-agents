defmodule Helmsman.Migrations.PrReconcileTest do
  # add-pr-reconcile-merge 1.1: the migration runs down and up again and
  # leaves `task_events.verified_sha` (owned by the earlier
  # `add-local-repositories` migration) in place; the table's constraints
  # hold.
  # Everything happens in the sandbox transaction and is rolled back.
  use Helmsman.DataCase, async: false

  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  @version 20_261_023_090_001
  @migration Helmsman.Repo.Migrations.CreateTaskPullRequests
  @migration_file "priv/repo/migrations/20261023090001_create_task_pull_requests.exs"

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_file)
    :ok
  end

  defp column?(table, column) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    n == 1
  end

  defp table?(table) do
    %{rows: [[exists]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table])
    exists
  end

  # Without the migration lock: it would hold the only sandbox connection
  # while the migrator runs the migration in another process.
  defp migrate(direction),
    do:
      :ok =
        apply(Ecto.Migrator, direction, [
          Repo,
          @version,
          @migration,
          [log: false, migration_lock: false]
        ])

  test "down and up again keep verified_sha" do
    assert table?("task_pull_requests") and column?("task_events", "verified_sha")

    migrate(:down)
    refute table?("task_pull_requests")
    assert column?("task_events", "verified_sha")

    migrate(:up)
    assert table?("task_pull_requests") and column?("task_events", "verified_sha")
  end

  describe "constraints" do
    setup do
      ctx = dispatch_fixture()
      installation = installation_fixture(ctx.workspace)
      repository = repository_fixture(installation)
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      Map.merge(ctx, %{repository: repository, task: task})
    end

    defp insert(ctx, extra) do
      {columns, values} =
        Enum.unzip(
          Keyword.merge(
            [
              workspace_id: ctx.workspace.id,
              task_id: ctx.task.id,
              repository_id: ctx.repository.id,
              number: System.unique_integer([:positive]),
              node_id: "PR_x",
              url: "https://github.com/acme/app/pull/1",
              branch: "hm/1/bos-1",
              base_branch: "main",
              state: "open",
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            ],
            extra
          )
        )

      placeholders = Enum.map_join(1..length(values), ",", &"$#{&1}")

      Repo.query(
        "INSERT INTO task_pull_requests (#{Enum.join(columns, ",")}) VALUES (#{placeholders})",
        values
      )
    end

    defp assert_check(result, constraint) do
      assert {:error,
              %Postgrex.Error{postgres: %{code: :check_violation, constraint: ^constraint}}} =
               result
    end

    test "states and merge reasons", ctx do
      assert {:ok, _} = insert(ctx, [])
      assert_check(insert(ctx, state: "gone"), "task_pull_requests_state_check")
      assert_check(insert(ctx, checks_state: "ok"), "task_pull_requests_checks_state_check")
      assert_check(insert(ctx, merge_status: "done"), "task_pull_requests_merge_status_check")
      assert_check(insert(ctx, merge_status: "blocked"), "task_pull_requests_merge_reason_check")

      assert_check(
        insert(ctx, merge_status: "blocked", merge_reason: "bogus"),
        "task_pull_requests_merge_reason_check"
      )

      assert {:ok, _} = insert(ctx, merge_status: "blocked", merge_reason: "not_independent")
      assert {:ok, _} = insert(ctx, merge_status: "merged")

      assert_check(
        insert(ctx, merge_note: String.duplicate("x", 1025)),
        "task_pull_requests_merge_note_size"
      )
    end

    test "a pull request number is unique per repository", ctx do
      assert {:ok, _} = insert(ctx, number: 12)

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               insert(ctx, number: 12)
    end
  end
end
