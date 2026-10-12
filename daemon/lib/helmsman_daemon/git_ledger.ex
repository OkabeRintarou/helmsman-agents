defmodule HelmsmanDaemon.GitLedger do
  @moduledoc "Atomic worktree inheritance and push acknowledgements, under the worktree lock."
  alias HelmsmanDaemon.{AtomicFile, Paths}

  def path(spec),
    do:
      Path.join([
        Paths.state(),
        "worktrees",
        to_string(spec.workspace.id),
        Paths.component!(spec.task.ident) <> ".json"
      ])

  def read(spec) do
    case File.read(path(spec)) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :enoent} -> %{"inherit" => [], "outbox" => []}
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path(spec)
    end
  end

  def write(spec, %{"inherit" => [], "outbox" => []}) do
    case File.rm(path(spec)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "remove", path: path(spec)
    end
  end

  def write(spec, ledger) do
    Paths.private_dir!(Path.dirname(path(spec)))
    :ok = AtomicFile.write(path(spec), Jason.encode!(ledger))
  end
end
