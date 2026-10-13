defmodule Helmsman.Actors.ClaimsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.SquadsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.ApiTokensFixtures
  alias Helmsman.{Actors, Feedback, Tasks}
  alias Helmsman.Actors.Actor

  setup do
    ctx = squads_fixture()
    source = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})
    Map.put(ctx, :source, source)
  end

  test "claim merges task references, feedback mentions and conflicting squad members", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^task.id),
      set: [created_by_id: ctx.source.id, assignee_id: ctx.source.id]
    )

    {:ok, feedback} = Feedback.add(ctx.alice_scope, task.ident, %{content: "synthetic history"})
    bob = ctx.bob_scope.actor

    Repo.update_all(from(f in Feedback.Entry, where: f.id == ^feedback.id),
      set: [author_id: ctx.source.id, mentions: [ctx.source.id, bob.id, ctx.source.id]]
    )

    squad = Repo.one!(from(s in Helmsman.Squads.Squad, where: s.id == ^ctx.squad.id))

    Repo.query!(
      "INSERT INTO squad_members(workspace_id,squad_id,actor_id,role_note,position,inserted_at) VALUES($1,$2,$3,'old role',20,now())",
      [ctx.workspace.id, squad.id, ctx.source.id]
    )

    old =
      Repo.one!(
        from(m in Helmsman.Squads.Member,
          where: m.squad_id == ^squad.id and m.actor_id == ^bob.id
        )
      )

    assert {:ok, claim} = Actors.request_claim(ctx.bob_scope, ctx.source.name)
    assert {:ok, _} = Actors.decide_claim(ctx.alice_scope, claim.id, :approve)
    assert Repo.get!(Tasks.Task, task.id).created_by_id == bob.id
    assert Repo.get!(Tasks.Task, task.id).assignee_id == bob.id
    feedback = Repo.get!(Feedback.Entry, feedback.id)
    assert feedback.author_id == bob.id
    assert feedback.mentions == [bob.id]

    kept =
      Repo.one!(
        from(m in Helmsman.Squads.Member,
          where: m.squad_id == ^squad.id and m.actor_id == ^bob.id
        )
      )

    assert kept.role_note == old.role_note and kept.position == old.position
    assert Repo.get!(Helmsman.Squads.Squad, squad.id).lock_version == squad.lock_version + 1
    refute Repo.get(Actor, ctx.source.id)
  end

  test "claim_for retains source-only squad membership and all other claims cease pending", ctx do
    squad = Repo.one!(from(s in Helmsman.Squads.Squad, where: s.id == ^ctx.squad.id))

    Repo.query!(
      "INSERT INTO squad_members(workspace_id,squad_id,actor_id,role_note,position,inserted_at) VALUES($1,$2,$3,'historical role',20,now())",
      [ctx.workspace.id, squad.id, ctx.source.id]
    )

    {:ok, _} = Actors.request_claim(ctx.bob_scope, ctx.source.name)
    {:ok, _} = Actors.request_claim(ctx.carol_scope, ctx.source.name)
    assert {:ok, _} = Actors.claim_for(ctx.alice_scope, ctx.source.name, ctx.carol.id)

    kept =
      Repo.one!(
        from(m in Helmsman.Squads.Member,
          where: m.squad_id == ^squad.id and m.actor_id == ^ctx.carol_scope.actor.id
        )
      )

    assert kept.role_note == "historical role" and kept.position == 20

    assert Repo.aggregate(
             from(c in Actors.Claim,
               where: c.actor_id == ^ctx.source.id and c.status == :pending
             ),
             :count
           ) == 0
  end

  test "only requester cancels; members cannot decide; already claimed is hidden", ctx do
    assert {:ok, claim} = Actors.request_claim(ctx.bob_scope, ctx.source.name)
    assert {:error, :not_found} = Actors.cancel_claim(ctx.carol_scope, claim.id)
    assert {:error, :forbidden} = Actors.decide_claim(ctx.bob_scope, claim.id, :approve)
    assert {:ok, %{status: :cancelled}} = Actors.cancel_claim(ctx.bob_scope, claim.id)
    assert {:error, :not_found} = Actors.request_claim(ctx.bob_scope, ctx.alice_scope.actor.name)
    assert {:ok, claim} = Actors.request_claim(ctx.bob_scope, ctx.source.name)
    assert {:ok, %{status: :rejected}} = Actors.decide_claim(ctx.alice_scope, claim.id, :reject)
  end

  test "removed requester fails without changing identity", ctx do
    {:ok, claim} = Actors.request_claim(ctx.bob_scope, ctx.source.name)

    Repo.delete_all(
      from(m in Helmsman.Workspaces.Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.bob.id
      )
    )

    assert {:error, :not_found} = Actors.decide_claim(ctx.alice_scope, claim.id, :approve)
    assert Repo.get(Actor, ctx.source.id)
    assert Repo.get!(Actors.Claim, claim.id).status == :pending
  end

  test "pending claim listing respects roles, workspace and current human membership", ctx do
    {:ok, bob_claim} = Actors.request_claim(ctx.bob_scope, ctx.source.name)
    {:ok, carol_claim} = Actors.request_claim(ctx.carol_scope, ctx.source.name)
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    {_admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)
    {:ok, viewer_claim} = Actors.request_claim(viewer_scope, ctx.source.name)

    assert {:ok, claims} = Actors.list_claims(ctx.alice_scope)
    assert Enum.map(claims, & &1.id) == [bob_claim.id, carol_claim.id, viewer_claim.id]

    assert hd(claims) == %{
             id: bob_claim.id,
             actor: ctx.source.name,
             user_id: ctx.bob.id,
             user_name: ctx.bob_scope.actor.name,
             inserted_at: bob_claim.inserted_at
           }

    assert {:ok, ^claims} = Actors.list_claims(admin_scope)
    assert {:ok, [own]} = Actors.list_claims(ctx.bob_scope)
    assert own.id == bob_claim.id
    assert {:ok, [own]} = Actors.list_claims(viewer_scope)
    assert own.id == viewer_claim.id
    assert {:error, :forbidden} = Actors.list_claims(%{ctx.alice_scope | actor: ctx.agent})
    assert {:error, :forbidden} = Actors.list_claims(%{ctx.alice_scope | via: :run})

    other = Helmsman.WorkspacesFixtures.workspace_fixture(ctx.alice)
    other_scope = Helmsman.WorkspacesFixtures.workspace_scope_fixture(ctx.alice, other)
    assert {:ok, []} = Actors.list_claims(other_scope)

    {:ok, _} = Actors.cancel_claim(viewer_scope, viewer_claim.id)

    Repo.delete_all(
      from(m in Helmsman.Workspaces.Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
      )
    )

    assert {:ok, [remaining]} = Actors.list_claims(ctx.alice_scope)
    assert remaining.id == bob_claim.id
  end

  test "external transfer clears the previous owner's token default; managed and viewer refused",
       ctx do
    {:ok, external} = Actors.identify(ctx.alice_scope, %{name: "bob/external"})
    %{api_token: token} = api_token_fixture(ctx.alice_scope, %{default_agent_id: external.id})
    assert token.default_agent_id == external.id

    assert {:ok, %{owner_id: owner}} =
             Actors.transfer_agent(ctx.alice_scope, external.name, ctx.bob.id)

    assert owner == ctx.bob.id
    assert is_nil(Repo.get!(Helmsman.ApiTokens.ApiToken, token.id).default_agent_id)

    old_scope = token_scope_fixture(ctx.alice, ctx.workspace, :api, token)
    new_scope = token_scope_fixture(ctx.bob, ctx.workspace, :api)
    assert {:error, :forbidden} = Actors.resolve_writer(old_scope, requested: external.name)
    assert {:error, :forbidden} = Actors.resolve_writer(old_scope, [])
    assert {:ok, %{owner_id: ^owner}} = Actors.resolve_writer(new_scope, requested: external.name)

    assert {:error, :forbidden} =
             Actors.transfer_agent(ctx.bob_scope, external.name, ctx.alice.id)

    assert {:error, :managed_agent} =
             Actors.transfer_agent(ctx.alice_scope, ctx.agent.name, ctx.bob.id)

    {viewer, _} = member_scope_fixture(ctx.workspace, :viewer)
    assert {:error, :forbidden} = Actors.transfer_agent(ctx.alice_scope, external.name, viewer.id)
  end

  test "each declared actor array replaces and stably deduplicates references", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, feedback} = Feedback.add(ctx.alice_scope, task.ident, %{content: "array fixture"})
    event = Repo.one!(from(e in Tasks.TaskEvent, where: e.task_id == ^task.id))
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :succeeded})

    grant =
      Repo.insert!(%Helmsman.Runs.TaskGrant{
        workspace_id: ctx.workspace.id,
        task_id: task.id,
        agent_id: ctx.agent.id,
        granted_by_id: ctx.source.id,
        root_initiator_user_id: ctx.alice.id,
        kind: :requested,
        inserted_at: DateTime.utc_now()
      })

    design =
      Repo.insert!(%Helmsman.AgentDesigns.AgentDesign{
        workspace_id: ctx.workspace.id,
        user_id: ctx.alice.id,
        helper_agent_id: ctx.agent.id,
        last_activity_at: DateTime.utc_now()
      })

    bob = ctx.bob_scope.actor
    refs = [ctx.source.id, ctx.agent.id, bob.id, ctx.source.id, ctx.agent.id]

    rows = %{
      "feedback" => feedback.id,
      "task_events" => event.id,
      "runs" => run.id,
      "task_grants" => grant.id,
      "agent_designs" => design.id
    }

    for {table, col} <- Actors.Claims.array_columns() do
      Repo.query!("UPDATE #{table} SET #{col}=$2 WHERE id=$1", [Map.fetch!(rows, table), refs])
    end

    assert {:ok, _} = Actors.claim_for(ctx.alice_scope, ctx.source.name, ctx.bob.id)

    for {table, col} <- Actors.Claims.array_columns() do
      assert Repo.query!("SELECT #{col} FROM #{table} WHERE id=$1", [Map.fetch!(rows, table)]).rows ==
               [[[bob.id, ctx.agent.id]]],
             "#{table}.#{col}"
    end

    assert Repo.get!(Helmsman.Runs.TaskGrant, grant.id).granted_by_id == bob.id
    assert {:ok, result} = Tasks.get(ctx.bob_scope, task.ident)
    assert Enum.any?(result.feedback, &(&1.author.name == ctx.alice_scope.actor.name))
  end
end
