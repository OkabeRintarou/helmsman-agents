defmodule Helmsman.TaskSpecs.ReplayTest do
  # add-spec-workflow 1.3: after any sequence of writes, the spec row and
  # the request rows equal `State.replay/2` of the events, and version rows
  # never change (decision 6).
  use Helmsman.DataCase, async: true
  use ExUnitProperties

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Repo, Tasks, TaskSpecs}
  alias Helmsman.TaskSpecs.{Event, Issue, IssueNote, ReviewRequest, Spec, State, Version}

  @ops [
    :submit,
    :submit_invalid,
    :request_agent,
    :request_person,
    :review_pass,
    :review_p1,
    :accept_issue,
    :lapse,
    :cancel,
    :propose,
    :reject,
    :approve,
    :abandon,
    :reopen
  ]

  setup do
    specs_fixture()
  end

  property "the rows equal the replay of the events", ctx do
    check all(ops <- list_of(member_of(@ops), max_length: 16), max_runs: 40) do
      # Most writes need a version: every sequence starts with one.
      ops = [:submit | ops]
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
      {:ok, task} = Tasks.get(ctx.alice_scope, task.ident)

      scopes = %{
        fe: elem(agent_run_scope(ctx.fe, task), 0),
        review: elem(agent_run_scope(ctx.review, task), 0),
        lead: elem(agent_run_scope(ctx.lead, task, %{squad_id: ctx.squad.id}), 0)
      }

      Enum.reduce(ops, %{}, fn op, versions_seen ->
        run(op, ctx, task, scopes)
        assert_replayed(task)
        assert_versions_unchanged(task, versions_seen)
      end)
    end
  end

  defp latest(task) do
    case Repo.get_by(Spec, task_id: task.id) do
      nil -> 0
      spec -> spec.latest_version
    end
  end

  defp run(:submit, _ctx, task, scopes) do
    n = latest(task)

    TaskSpecs.submit_version(scopes.fe, task.ident, %{
      base_version: n,
      files: spec_files(tag: "v#{n + 1}")
    })
  end

  defp run(:submit_invalid, ctx, task, _scopes) do
    n = latest(task)

    TaskSpecs.submit_version(ctx.alice_scope, task.ident, %{
      base_version: n,
      files: spec_files(tag: "i#{n + 1}", invalid: true)
    })
  end

  defp run(:request_agent, ctx, task, _scopes),
    do: TaskSpecs.request_reviews(ctx.alice_scope, task.ident, ["keel/review"])

  defp run(:request_person, ctx, task, _scopes),
    do:
      TaskSpecs.request_reviews(ctx.alice_scope, task.ident, [
        human_actor(ctx.workspace, ctx.bob).name
      ])

  defp run(:review_pass, _ctx, task, scopes),
    do:
      TaskSpecs.submit_review(scopes.review, task.ident, %{version: latest(task), verdict: "pass"})

  defp run(:review_p1, _ctx, task, scopes) do
    TaskSpecs.submit_review(scopes.review, task.ident, %{
      version: latest(task),
      verdict: "fail",
      issues: [%{severity: "P1", body: "Missing a failure scenario"}]
    })
  end

  defp run(:accept_issue, ctx, task, _scopes) do
    case Repo.one(
           from(i in Issue,
             join: s in Spec,
             on: s.id == i.spec_id,
             join: r in assoc(i, :review),
             where: s.task_id == ^task.id and i.resolution == :open,
             limit: 1,
             select: {r.number, i.number}
           )
         ) do
      nil ->
        :none

      {r, i} ->
        TaskSpecs.add_note(ctx.alice_scope, task.ident, "R#{r}.#{i}", %{resolution: "accepted"})
    end
  end

  defp run(:lapse, ctx, task, _scopes) do
    case Repo.one(
           from(r in ReviewRequest,
             join: s in Spec,
             on: s.id == r.spec_id,
             where: s.task_id == ^task.id and r.status == :requested,
             limit: 1
           )
         ) do
      nil ->
        :none

      request ->
        run =
          run_fixture(ctx.review, %{
            task_id: task.id,
            status: :succeeded,
            lane: :reply,
            triggers: [%{"kind" => "spec_review", "spec_request" => request.number}]
          })

        TaskSpecs.settle_run(run.id)
    end
  end

  defp run(:cancel, ctx, task, _scopes),
    do: TaskSpecs.cancel_request(ctx.alice_scope, task.ident, %{reviewer: "keel/review"})

  defp run(:propose, _ctx, task, scopes),
    do: TaskSpecs.finalize(scopes.lead, task.ident, %{version: latest(task), summary: "Ready"})

  defp run(:reject, ctx, task, _scopes),
    do: TaskSpecs.reject(ctx.alice_scope, task.ident, %{reason: "Not yet", wake: false})

  defp run(:approve, ctx, task, _scopes),
    do: TaskSpecs.finalize(ctx.alice_scope, task.ident, %{version: latest(task), wake: false})

  defp run(:abandon, ctx, task, _scopes),
    do: TaskSpecs.abandon(ctx.alice_scope, task.ident, %{reason: "Dropped"})

  defp run(:reopen, ctx, task, _scopes),
    do: TaskSpecs.reopen(ctx.alice_scope, task.ident, %{reason: "Again"})

  defp assert_replayed(task) do
    case Repo.get_by(Spec, task_id: task.id) do
      nil ->
        :ok

      spec ->
        events =
          Repo.all(from(e in Event, where: e.spec_id == ^spec.id, order_by: e.number))
          |> Enum.map(&Map.from_struct/1)

        notes =
          Repo.all(
            from(n in IssueNote,
              join: i in assoc(n, :issue),
              join: r in assoc(i, :review),
              where: i.spec_id == ^spec.id,
              select: %{
                review: r.number,
                issue: i.number,
                number: n.number,
                resolution: n.resolution
              }
            )
          )

        replay = State.replay(events, notes)
        proposal = replay.spec.proposal

        assert {spec.status, spec.change_id, spec.latest_version, spec.final_version} ==
                 {replay.spec.status, replay.spec.change_id, replay.spec.latest_version,
                  replay.spec.final_version}

        assert {spec.proposal_version, spec.proposal_summary, spec.proposal_by_id} ==
                 {proposal && proposal.version, proposal && proposal.summary,
                  proposal && proposal.by_id}

        requests =
          Repo.all(
            from(r in ReviewRequest,
              left_join: rv in assoc(r, :review),
              where: r.spec_id == ^spec.id,
              select: {r.number, {r.status, r.close_reason, rv.number}}
            )
          )
          |> Map.new()

        assert requests ==
                 Map.new(replay.requests, fn {n, r} ->
                   {n, {r.status, r.close_reason, r.review}}
                 end)

        issues =
          Repo.all(
            from(i in Issue,
              join: r in assoc(i, :review),
              where: i.spec_id == ^spec.id and i.resolution != :open,
              select: {{r.number, i.number}, i.resolution}
            )
          )
          |> Map.new()

        assert issues == replay.issues
    end
  end

  defp assert_versions_unchanged(task, seen) do
    rows =
      Repo.all(
        from(v in Version,
          join: s in Spec,
          on: s.id == v.spec_id,
          where: s.task_id == ^task.id
        )
      )
      |> Map.new(&{&1.id, &1})

    for {id, row} <- seen, do: assert(rows[id] == row)
    rows
  end
end
