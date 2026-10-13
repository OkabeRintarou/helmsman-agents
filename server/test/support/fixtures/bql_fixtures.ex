defmodule Helmsman.BQLFixtures do
  @moduledoc "The independently reconstructed bosun BQL test dataset."
  use Boundary, top_level?: true, check: [in: false, out: false]
  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  alias Helmsman.{Actors, Feedback, Links, Repo}
  alias Helmsman.Actors.Actor
  alias Helmsman.Tasks.Task

  def bql_fixture do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    Repo.update_all(from(a in Actor, where: a.id == ^scope.actor.id), set: [name: "user"])
    scope = %{scope | actor: Repo.get!(Actor, scope.actor.id)}
    {:ok, coxswain} = Actors.identify(scope, %{name: "coxswain"})
    {:ok, keel} = Actors.identify(scope, %{name: "keel"})
    for key <- ["BQ", "OT"], do: project_fixture(scope, key: key)

    bq1 =
      task_fixture(%{scope | actor: coxswain}, "BQ",
        title: "实现 MCP 创建任务",
        labels: ["backend", "mcp"],
        priority: "high"
      )

    bq2 = task_fixture(scope, "BQ", title: "Write docs", labels: ["docs"])
    bq3 = task_fixture(scope, "BQ", title: "Health endpoint", priority: "low")
    ot1 = task_fixture(scope, "OT", title: "Other backend thing", labels: ["Backend"])

    Repo.update_all(from(t in Task, where: t.id == ^bq2.id),
      set: [status: :done, assignee_id: scope.actor.id]
    )

    {:ok, _} =
      Feedback.add(%{scope | actor: keel}, bq3.ident, %{content: "which port?", kind: "question"})

    ot2 = task_fixture(scope, "OT", title: "big goal", kind: "epic")
    {:ok, _} = Helmsman.Tasks.update(scope, bq3.ident, %{epic: ot2.ident})

    %{
      scope: scope,
      user: user,
      workspace: workspace,
      bq1: bq1,
      bq2: bq2,
      bq3: bq3,
      ot1: ot1,
      ot2: ot2,
      keel: keel,
      coxswain: coxswain
    }
  end

  def links(ctx) do
    {:ok, _} = Links.add(ctx.scope, ctx.bq1.ident, ctx.bq2.ident, "depends_on")
    {:ok, _} = Links.add(ctx.scope, ctx.bq1.ident, ctx.ot1.ident, "depends_on")
    {:ok, _} = Links.add(ctx.scope, ctx.ot2.ident, ctx.bq3.ident, "replaces")
    ctx
  end
end
