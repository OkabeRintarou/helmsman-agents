defmodule Helmsman.DependencyFixtures do
  @moduledoc """
  Test helpers for `add-dependency-dispatch`: `dispatch_fixture/0` (alice,
  her project, the managed agent `keel/dev`) with a prerequisite `bos1`
  and a dependent `web2` (`web2 depends_on bos1`), runs with gated
  triggers and the deferred runs of a task.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Links, Repo}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @doc """
  `dispatch_fixture/1` plus the tasks `bos1` (prerequisite, `new`) and
  `web2` (dependent, `new`, unassigned) with `web2 depends_on bos1`.
  """
  def dependency_fixture(agent_attrs \\ %{}) do
    ctx = dispatch_fixture(agent_attrs)
    bos1 = task_fixture(ctx.alice_scope, ctx.project.key)
    web2 = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, web2.ident, bos1.ident, "depends_on")
    Map.merge(ctx, %{bos1: bos1, web2: web2})
  end

  @doc "Sets the status of a task directly (no history, no steps)."
  def put_status!(%{id: id}, status) do
    Repo.update_all(from(t in Task, where: t.id == ^id), set: [status: status])
    :ok
  end

  @doc "Sets the assignee of a task directly."
  def put_assignee!(%{id: id}, agent_id) do
    Repo.update_all(from(t in Task, where: t.id == ^id), set: [assignee_id: agent_id])
    :ok
  end

  @doc """
  A run of `ctx.agent` on `task` in `status` whose triggers are `kinds`
  (strings, by alice; `"retry_auto"` is an automatic retry marker).
  """
  def run_with!(ctx, task, status, kinds, attrs \\ %{}) do
    triggers =
      Enum.map(kinds, fn
        "retry_auto" -> %{"kind" => "retry", "auto" => true, "at" => now()}
        "unblocked" -> %{"kind" => "unblocked", "prerequisites" => [], "at" => now()}
        kind -> trigger(kind, ctx.workspace, ctx.alice, ctx.agent)
      end)

    run_fixture(
      ctx.agent,
      Map.merge(%{task_id: task.id, status: status, triggers: triggers}, attrs)
    )
  end

  @doc "The runs of `task` in `status`, oldest first."
  def runs_in(task, status),
    do:
      Repo.all(
        from(r in Run, where: r.task_id == ^task.id and r.status == ^status, order_by: r.id)
      )

  @doc "The status of the run."
  def run_status(%Run{id: id}),
    do: Repo.one!(from(r in Run, where: r.id == ^id, select: r.status))

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
