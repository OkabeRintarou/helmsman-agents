defmodule Helmsman.Actors.Claims do
  @moduledoc "Maintenance-locked identity claims and explicit reference merge rules."
  import Ecto.Query
  alias Helmsman.{Actors, Events, Locks, Policy, Repo, Tx, Workspaces}
  alias Helmsman.Actors.{Actor, Claim}
  alias Helmsman.Workspaces.Membership

  @foreign_columns [
    {"tasks", "created_by_id"},
    {"tasks", "assignee_id"},
    {"task_events", "actor_id"},
    {"feedback", "author_id"},
    {"task_links", "actor_id"},
    {"runs", "cancel_requested_by_id"},
    {"task_grants", "granted_by_id"},
    {"task_local_branches", "merged_by_id"},
    # `add-spec-workflow` decision 2 (pending requests: `merge_review_requests/3`).
    {"task_specs", "created_by_id"},
    {"task_specs", "proposal_by_id"},
    {"task_spec_versions", "author_id"},
    {"task_spec_review_requests", "reviewer_id"},
    {"task_spec_review_requests", "requested_by_id"},
    {"task_spec_reviews", "reviewer_id"},
    {"task_spec_issue_notes", "author_id"},
    {"task_spec_events", "actor_id"}
  ]
  @agent_only [
    {"api_tokens", "default_agent_id"},
    {"agent_profiles", "actor_id"},
    {"runs", "agent_id"},
    {"task_grants", "agent_id"},
    {"squads", "actor_id"},
    {"squads", "leader_agent_id"},
    {"agent_designs", "helper_agent_id"},
    {"autopilots", "agent_id"},
    # Agents' and squads' avatars only: a human's avatar is their user's
    # (`add-actor-avatars` decision 3).
    {"avatars", "actor_id"}
  ]
  @arrays [
    {"feedback", "mentions"},
    {"task_events", "assignee_side_ids"},
    {"runs", "causal_agent_ids"},
    {"task_grants", "causal_agent_ids"},
    {"agent_designs", "created_actor_ids"}
  ]
  def foreign_columns,
    do:
      @foreign_columns ++
        @agent_only ++ [{"squad_members", "actor_id"}, {"actor_claims", "actor_id"}]

  def array_columns, do: @arrays
  def agent_only, do: @agent_only

  def list(scope) do
    all? = Policy.authorize(scope, :decide_claim) == :ok

    with :ok <- if(all?, do: :ok, else: Policy.authorize(scope, :request_claim)) do
      {:ok,
       Repo.all(
         from(c in Claim,
           join: actor in Actor,
           on: actor.id == c.actor_id and actor.workspace_id == c.workspace_id,
           join: m in Membership,
           on: m.workspace_id == c.workspace_id and m.user_id == c.user_id,
           join: human in Actor,
           on:
             human.workspace_id == c.workspace_id and human.user_id == c.user_id and
               human.kind == :human,
           where:
             c.workspace_id == ^scope.workspace.id and c.status == :pending and
               (^all? or c.user_id == ^scope.user.id),
           order_by: [asc: c.inserted_at, asc: c.id],
           select: %{
             id: c.id,
             actor: actor.name,
             user_id: c.user_id,
             user_name: human.name,
             inserted_at: c.inserted_at
           }
         )
       )}
    end
  end

  def request(scope, name) do
    Workspaces.write_transaction(scope, :request_claim, &request_locked(&1, name))
  end

  defp request_locked(scope, name) do
    case unclaimed(scope, name) do
      nil -> {:error, :not_found}
      actor -> insert_request(scope, actor)
    end
  end

  defp insert_request(scope, actor) do
    case Repo.one(
           from(c in Claim,
             where:
               c.actor_id == ^actor.id and c.user_id == ^scope.user.id and c.status == :pending
           )
         ) do
      nil ->
        result =
          Repo.insert(
            Claim.changeset(%Claim{}, %{
              workspace_id: scope.workspace.id,
              actor_id: actor.id,
              user_id: scope.user.id
            })
          )

        notify(scope)
        result

      claim ->
        {:ok, claim}
    end
  end

  def cancel(scope, id) do
    Workspaces.write_transaction(scope, :request_claim, fn scope ->
      case Repo.one(
             from(c in Claim,
               where:
                 c.id == ^id and c.workspace_id == ^scope.workspace.id and
                   c.user_id == ^scope.user.id and c.status == :pending,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          {:error, :not_found}

        claim ->
          notify(scope)
          Repo.update(Ecto.Changeset.change(claim, status: :cancelled))
      end
    end)
  end

  def decide(scope, id, decision) when decision in [:approve, :reject] do
    exclusive(scope, &decide_locked(&1, id, decision))
  end

  defp decide_locked(scope, id, decision) do
    case Repo.one(
           from(c in Claim,
             where:
               c.id == ^id and c.workspace_id == ^scope.workspace.id and c.status == :pending,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :not_found}
      claim -> decide_request(scope, claim, decision)
    end
  end

  defp decide_request(scope, claim, :reject) do
    notify(scope)

    Repo.update(
      Ecto.Changeset.change(claim,
        status: :rejected,
        decided_by_id: scope.user.id,
        decided_at: DateTime.utc_now()
      )
    )
  end

  defp decide_request(scope, claim, :approve) do
    with %Actor{} = actor <-
           Repo.one(
             from(a in Actor,
               where:
                 a.id == ^claim.actor_id and a.workspace_id == ^scope.workspace.id and
                   a.kind == :human and is_nil(a.user_id)
             )
           ),
         {:ok, target} <- target(scope, claim.user_id),
         :ok <- merge(scope, actor, target) do
      {:ok,
       %{claim | status: :approved, decided_by_id: scope.user.id, decided_at: DateTime.utc_now()}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def claim_for(scope, name, user_id) do
    exclusive(scope, fn scope ->
      with %Actor{} = actor <- unclaimed(scope, name),
           {:ok, target} <- target(scope, user_id),
           :ok <- merge(scope, actor, target) do
        {:ok, target}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp exclusive(scope, fun) do
    with :ok <- Policy.authorize(scope, :decide_claim) do
      Tx.run(
        fn ->
          Repo.query!("SET LOCAL lock_timeout = '30s'")
          Locks.maint_exclusive!(scope.workspace.id, timeout: 35_000)
          authorize_decision(scope, fun)
        end,
        timeout: :timer.minutes(30)
      )
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :lock_not_available,
        do: {:error, :busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp authorize_decision(scope, fun) do
    with {:ok, _} <- target(scope, scope.user.id),
         %Membership{} = m <-
           Repo.one(
             from(m in Membership,
               where: m.workspace_id == ^scope.workspace.id and m.user_id == ^scope.user.id
             )
           ),
         :ok <- Policy.authorize(%{scope | role: m.role}, :decide_claim) do
      fun.(%{scope | role: m.role})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp unclaimed(scope, name),
    do:
      Repo.one(
        from(a in Actor,
          where:
            a.workspace_id == ^scope.workspace.id and a.name == ^name and a.kind == :human and
              is_nil(a.user_id),
          lock: "FOR UPDATE"
        )
      )

  defp target(scope, user_id) do
    case Repo.one(
           from(m in Membership,
             where: m.workspace_id == ^scope.workspace.id and m.user_id == ^user_id,
             lock: "FOR SHARE"
           )
         ) do
      nil -> {:error, :not_found}
      _ -> {:ok, Actors.get_human(scope.workspace.id, user_id)}
    end
  end

  defp merge(scope, source, target) do
    wid = scope.workspace.id

    squads =
      Repo.query!(
        "SELECT squad_id FROM squad_members WHERE workspace_id=$1 AND actor_id=$2 ORDER BY squad_id",
        [wid, source.id]
      ).rows
      |> List.flatten()

    Repo.query!(
      "DELETE FROM squad_members old USING squad_members own WHERE old.workspace_id=$1 AND old.actor_id=$2 AND own.squad_id=old.squad_id AND own.actor_id=$3",
      [wid, source.id, target.id]
    )

    Repo.query!("UPDATE squad_members SET actor_id=$3 WHERE workspace_id=$1 AND actor_id=$2", [
      wid,
      source.id,
      target.id
    ])

    Repo.query!(
      "UPDATE squads SET lock_version=lock_version+1 WHERE workspace_id=$1 AND id=ANY($2)",
      [wid, squads]
    )

    merge_review_requests(wid, source.id, target.id)

    for {table, col} <- @foreign_columns do
      Repo.query!("UPDATE #{table} SET #{col}=$3 WHERE workspace_id=$1 AND #{col}=$2", [
        wid,
        source.id,
        target.id
      ])
    end

    for {table, col} <- @arrays do
      Repo.query!(
        "UPDATE #{table} SET #{col}=ARRAY(SELECT value FROM unnest(array_replace(#{col},$2::bigint,$3::bigint)) WITH ORDINALITY u(value,n) GROUP BY value ORDER BY min(n)) WHERE workspace_id=$1 AND $2=ANY(#{col})",
        [wid, source.id, target.id]
      )
    end

    Repo.delete!(source)
    notify(scope)

    Enum.each(squads, &Events.after_commit(Events.topic(:workspace_squads, wid), {:squad, &1}))

    :ok
  end

  # `add-spec-workflow`: at most one `requested` request per version and
  # reviewer. A pending request of the source on a version the target also
  # has one on is closed (`cancelled / withdrawn`) with its audit event, by
  # the system identity, so the spec still equals the replay of its events;
  # the spec's status does not change (the target's request stays).
  defp merge_review_requests(wid, source_id, target_id) do
    Repo.query!(
      """
      WITH dup AS (
        SELECT r.id, r.spec_id, r.number FROM task_spec_review_requests r
        WHERE r.workspace_id = $1 AND r.reviewer_id = $2 AND r.status = 'requested'
          AND EXISTS (SELECT 1 FROM task_spec_review_requests o
                      WHERE o.version_id = r.version_id AND o.reviewer_id = $3
                        AND o.status = 'requested')
      ), numbered AS (
        SELECT dup.*, s.event_seq + row_number() OVER (PARTITION BY dup.spec_id ORDER BY dup.number) AS event_no
        FROM dup JOIN task_specs s ON s.id = dup.spec_id
      ), events AS (
        INSERT INTO task_spec_events (workspace_id, spec_id, number, actor_id, action, data, inserted_at)
        SELECT $1, spec_id, event_no, (SELECT id FROM actors WHERE workspace_id = $1 AND kind = 'system'),
               'review_request_closed',
               jsonb_build_object('request', number, 'status', 'cancelled', 'reason', 'withdrawn'), now()
        FROM numbered RETURNING spec_id
      ), specs AS (
        UPDATE task_specs s SET event_seq = s.event_seq + c.n, lock_version = s.lock_version + 1
        FROM (SELECT spec_id, count(*) AS n FROM events GROUP BY spec_id) c WHERE s.id = c.spec_id
      )
      UPDATE task_spec_review_requests r SET status = 'cancelled', close_reason = 'withdrawn', closed_at = now()
      FROM dup WHERE r.id = dup.id
      """,
      [wid, source_id, target_id]
    )
  end

  defp notify(scope) do
    Events.after_commit("workspace:#{scope.workspace.id}:backup", {:claims_changed})
    Events.after_commit(Events.topic(:workspace, scope.workspace.id), {:actors_changed})
    Events.after_commit(Events.topic(:workspace, scope.workspace.id), {:members_changed})
  end

  def transfer(scope, name, user_id) do
    Workspaces.write_transaction(scope, :transfer_agent, fn scope ->
      with %Membership{role: role} <-
             Repo.one(
               from(m in Membership,
                 where: m.workspace_id == ^scope.workspace.id and m.user_id == ^user_id,
                 lock: "FOR SHARE"
               )
             ),
           true <- role in [:member, :admin, :owner],
           %Actor{} = actor <-
             Repo.one(
               from(a in Actor,
                 where:
                   a.workspace_id == ^scope.workspace.id and a.name == ^name and a.kind == :agent,
                 lock: "FOR UPDATE"
               )
             ),
           false <- Repo.exists?(from(p in "agent_profiles", where: p.actor_id == ^actor.id)) do
        Repo.query!(
          "UPDATE api_tokens SET default_agent_id=NULL WHERE workspace_id=$1 AND default_agent_id=$2 AND user_id<>$3",
          [scope.workspace.id, actor.id, user_id]
        )

        notify(scope)
        Repo.update(Ecto.Changeset.change(actor, owner_id: user_id))
      else
        nil -> {:error, :not_found}
        true -> {:error, :managed_agent}
        false -> {:error, :forbidden}
      end
    end)
  end
end
