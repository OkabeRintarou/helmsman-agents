defmodule HelmsmanDaemon.Workspace do
  @moduledoc "Persistent scratch directories, repository worktrees and private run cleanup."
  alias HelmsmanDaemon.Paths

  def prepare(%{repo: repo} = spec, run_dir) when not is_nil(repo) do
    case prepare_git(spec, run_dir) do
      {:ok, workspace} -> {:ok, workspace.path}
      error -> error
    end
  end

  def prepare(%{task: nil}, run_dir), do: {:ok, Paths.private_dir!(Path.join(run_dir, "scratch"))}

  def prepare(spec, _run_dir) do
    path =
      Path.join([
        Paths.home(),
        "scratch",
        Paths.component!(spec.workspace.slug),
        Paths.component!(spec.task.ident)
      ])

    {:ok, Paths.private_dir!(path)}
  rescue
    _ -> {:error, {:workspace_prepare, "Invalid scratch workspace path"}}
  end

  @doc "Prepare a repository context, including events and the remote push baseline."
  defdelegate prepare_git(spec, run_dir, opts \\ []),
    to: HelmsmanDaemon.GitWorkspace,
    as: :prepare

  def cleanup(run_id) do
    run_dir = Paths.run(run_id)

    case File.ls(run_dir) do
      {:ok, files} -> Enum.each(files -- ["raw.log"], &File.rm_rf!(Path.join(run_dir, &1)))
      {:error, :enoent} -> :ok
    end

    if File.ls(run_dir) == {:ok, []}, do: File.rmdir(run_dir)
    :ok
  end
end
