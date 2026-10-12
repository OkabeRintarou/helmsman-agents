defmodule Helmsman.Runs.TaskGrantsTest do
  # add-continuation-triggers 1.4: the requester grant (decision 5).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs.TaskGrant
  alias Helmsman.Tasks

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/lead", access: "workspace"})
    lead = agent_actor(ctx.workspace, "keel/lead")
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, lead: lead})
  end

  defp grants(task_id),
    do: Repo.all(from(g in TaskGrant, where: g.task_id == ^task_id, order_by: g.kind))

  test "a task created in a run: a requested grant that survives reassignment (scenario)",
       ctx do
    run =
      run_fixture(ctx.lead, %{
        status: :running,
        capabilities: ["read", "create_tasks"],
        root_initiator_user_id: ctx.bob.id,
        causal_agent_ids: [ctx.agent.id, ctx.lead.id]
      })

    {scope, _token} = run_scope_fixture(run)
    {:ok, task} = Tasks.create(scope, ctx.project.key, %{title: "BOS-9"})

    assert [%TaskGrant{kind: :requested} = grant] = grants(task.id)
    assert grant.agent_id == ctx.lead.id
    assert grant.root_initiator_user_id == ctx.bob.id
    assert grant.causal_agent_ids == [ctx.agent.id, ctx.lead.id]
    assert grant.granted_by_id == ctx.lead.id

    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})
    assert [%TaskGrant{kind: :assign}, %TaskGrant{kind: :requested}] = grants(task.id)

    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: ctx.bob_scope.actor.name})
    assert [%TaskGrant{kind: :requested}] = grants(task.id)
  end

  test "a person's task and an external agent's task have none", ctx do
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "T"})
    assert grants(task.id) == []

    ext = agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
    scope = %{ctx.alice_scope | actor: ext, via: :mcp}
    {:ok, task} = Tasks.create(scope, ctx.project.key, %{title: "T"})
    assert task.created_by.name == "keel/ext"
    assert grants(task.id) == []
  end
end
