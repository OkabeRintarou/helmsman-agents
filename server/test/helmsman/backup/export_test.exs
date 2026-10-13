defmodule Helmsman.Backup.ExportTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, Repo}
  alias Helmsman.Tasks.Task

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    project = project_fixture(scope)
    path = Path.join(System.tmp_dir!(), "export-memory-#{System.unique_integer([:positive])}.gz")
    on_exit(fn -> File.rm(path) end)
    %{workspace: workspace, scope: scope, project: project, path: path}
  end

  defp insert_tasks(ctx, range) do
    at = DateTime.utc_now()

    rows =
      Enum.map(range, fn seq ->
        %{
          workspace_id: ctx.workspace.id,
          project_id: ctx.project.id,
          seq: seq,
          ident: "#{ctx.project.key}-#{seq}",
          title: "Task #{seq}",
          description: String.duplicate("synthetic backup data ", 100),
          status: :new,
          priority: :medium,
          kind: :task,
          created_by_id: ctx.scope.actor.id,
          inserted_at: at,
          updated_at: at
        }
      end)

    rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Task, &1))
  end

  defp measured(ctx) do
    Process.put(:export_memory, [])

    Process.put(:helmsman_test_hook, fn
      {:export_batch, "tasks", _} ->
        Process.put(:export_memory, [
          {:erlang.process_info(self(), :memory) |> elem(1), :erlang.memory(:processes_used)}
          | Process.get(:export_memory)
        ])

      _ ->
        :ok
    end)

    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    samples = Process.delete(:export_memory)
    Process.delete(:helmsman_test_hook)

    {samples |> Enum.map(&elem(&1, 0)) |> Enum.max(),
     samples |> Enum.map(&elem(&1, 1)) |> Enum.max()}
  end

  test "5000 tasks export in bounded batches without task-count-proportional process growth",
       ctx do
    insert_tasks(ctx, 1..500)
    {small, small_total} = measured(ctx)
    insert_tasks(ctx, 501..5000)
    :erlang.garbage_collect()
    {large, large_total} = measured(ctx)
    # A generous fixed heap allowance accommodates the 500-row cursor batch and GC scheduling.
    assert large - small < 32 * 1024 * 1024
    assert large_total - small_total < 64 * 1024 * 1024

    IO.puts(
      "backup export memory: 500=#{small}, 5000=#{large}, process_total_delta=#{large_total - small_total}"
    )
  end
end
