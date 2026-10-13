defmodule Helmsman.AutopilotsFixtures do
  @moduledoc """
  Test helpers for `add-autopilots`: `autopilot_fixture/2`, a workspace
  with an autopilot (`autopilots_fixture/1`) and helpers to read records.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Autopilots.{Autopilot, Clock, Record}
  alias Helmsman.Repo

  @doc """
  Creates an autopilot as `scope` (`Helmsman.Autopilots.create/2`) and
  returns its view. Defaults: a unique name, `keel/dev`, `create_task` in
  the workspace's first project, the template `Triage {{date}}`, no cron.
  """
  def autopilot_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)

    project =
      Map.get_lazy(attrs, :project, fn ->
        Repo.one(
          from(p in Helmsman.Projects.Project,
            where: p.workspace_id == ^scope.workspace.id,
            order_by: p.id,
            limit: 1,
            select: p.key
          )
        )
      end)

    defaults = %{
      name: "autopilot-#{System.unique_integer([:positive])}",
      agent: "keel/dev",
      project: project,
      mode: "create_task",
      title_template: "Triage {{date}}",
      instructions: "Look at the open tasks."
    }

    {:ok, view} = Autopilots.create(scope, Map.merge(defaults, Map.put(attrs, :project, project)))
    view
  end

  @doc """
  `dispatch_fixture/1` (alice, owner, her project and `keel/dev`, whose
  `access` is `workspace` unless `agent_attrs` say otherwise) with bob
  (member) and carol (admin).
  """
  def autopilots_fixture(agent_attrs \\ %{access: "workspace"}) do
    ctx = dispatch_fixture(agent_attrs)
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {carol, carol_scope} = member_scope_fixture(ctx.workspace, :admin)
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, carol: carol, carol_scope: carol_scope})
  end

  @doc "The autopilot row."
  def autopilot_row(%{id: id}), do: Repo.get!(Autopilot, id)
  def autopilot_row(id) when is_integer(id), do: Repo.get!(Autopilot, id)

  @doc "Every record of the autopilot, oldest first."
  def records_of(%{id: id}),
    do: Repo.all(from(r in Record, where: r.autopilot_id == ^id, order_by: [asc: r.id]))

  @doc "Sets the autopilots clock of the calling process."
  def at(%DateTime{} = now), do: Clock.put(now)
end
