defmodule Helmsman.TaskSpecs.Lock do
  @moduledoc """
  The transactions of spec writes (`add-spec-workflow` decision 13), both
  inside `Helmsman.Workspaces.write_transaction/5` (workspace maintenance
  lock shared, the membership row `FOR SHARE`, the coarse `:write_spec`
  check):

    * `write/3` — a write that triggers nothing: task row `FOR UPDATE`
      (a run only on its own task), then the spec row `FOR UPDATE`;
    * `dispatching/4` — a write that may trigger runs, or whose
      permission depends on who coordinates (`coordinated/3`): guess, lock
      the targets and, when the task's assignee is a squad, the squad's
      rows (`Helmsman.Dispatch.Targets.with_locked/4`), then the project
      row `FOR SHARE` (its finalize mode), the task and spec rows, and
      check the plan again under the locks before writing anything
      (`Helmsman.TaskSpecs.Dispatch.plan/3`). A leader or mode changed
      meanwhile is thus either committed before (and seen) or waits for
      this write (designs/01 §4: actor rows → squad rows → profiles →
      project row → task row → spec row).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Dispatch.Targets
  alias Helmsman.{Policy, Repo, Tasks, Workspaces}
  alias Helmsman.Projects.Project
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.TaskSpecs.{Dispatch, Spec, Store}

  @type fun3 :: (Scope.t(), Task.t(), Spec.t() | nil -> {:ok, term()} | {:error, term()})

  @doc "See the module documentation."
  @spec write(Scope.t(), String.t(), fun3()) :: {:ok, term()} | {:error, term()}
  def write(%Scope{} = scope, ident, fun) do
    with {:ok, ident} <- parse(ident) do
      Workspaces.write_transaction(scope, :write_spec, nil, &locked(&1, ident, fun))
    end
  end

  defp locked(scope, ident, fun) do
    with {:ok, task} <- lock_task(scope, ident), do: fun.(scope, task, Store.lock(task))
  end

  @doc "A write by a coordinator that triggers nothing: `dispatching/4` without targets."
  @spec coordinated(Scope.t(), String.t(), fun3()) :: {:ok, term()} | {:error, term()}
  def coordinated(scope, ident, fun), do: dispatching(scope, ident, {:coordinate, nil}, fun)

  @doc "See the module documentation."
  @spec dispatching(Scope.t(), String.t(), Dispatch.op(), fun3()) ::
          {:ok, term()} | {:error, term()}
  def dispatching(%Scope{} = scope, ident, op, fun) do
    with {:ok, ident} <- parse(ident) do
      Workspaces.write_transaction(
        scope,
        :write_spec,
        nil,
        &dispatching_locked(&1, ident, op, fun)
      )
    end
  end

  defp dispatching_locked(scope, ident, op, fun) do
    workspace_id = scope.workspace.id

    guess = fn ->
      {task, spec} = read(workspace_id, ident)
      test_hook({:spec_guessed, elem(op, 0)})
      Dispatch.plan(op, task, spec)
    end

    lock = fn ->
      lock_project(workspace_id, ident)
      with {:ok, task} <- lock_task(scope, ident), do: {:ok, {task, Store.lock(task)}}
    end

    targets = fn {task, spec} -> {Dispatch.plan(op, task, spec), nil} end

    with {:ok, {task, spec}, nil} <- Targets.with_locked(workspace_id, guess, lock, targets),
         do: fun.(scope, task, spec)
  end

  defp parse(ident) when is_binary(ident) do
    case Ident.parse(ident) do
      {:ok, ident, _key, _seq} -> {:ok, ident}
      _error -> {:error, :not_found}
    end
  end

  defp parse(_ident), do: {:error, :not_found}

  defp lock_task(scope, ident) do
    with {:ok, task} <- Tasks.lock(scope, ident),
         :ok <- Policy.authorize(scope, :write_task, task),
         do: {:ok, task}
  end

  # A task never changes project: its key is in its ID.
  defp lock_project(workspace_id, ident) do
    Repo.all(
      from(p in Project,
        join: t in Task,
        on: t.project_id == p.id,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        lock: "FOR SHARE OF p0",
        select: p.id
      )
    )
  end

  # The task and spec as they are now, without locks (the guess).
  defp read(workspace_id, ident) do
    case Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      nil -> {nil, nil}
      task -> {task, Repo.get_by(Spec, task_id: task.id)}
    end
  end

  # Concurrency tests change rows after the guess read the task and spec,
  # before any lock: compiled in the test environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end
