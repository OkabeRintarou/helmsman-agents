defmodule Helmsman.Actors.ClaimsSpecTest do
  # add-spec-workflow: a claim moves the spec records of the unclaimed
  # identity; a pending request both identities have on one version is
  # closed with its audit event, so the rows still equal the replay.
  use Helmsman.DataCase, async: true

  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Actors, TaskSpecs}
  alias Helmsman.Actors.Actor
  alias Helmsman.TaskSpecs.{Event, ReviewRequest, Spec, State}

  setup do
    ctx = specs_fixture()
    source = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})
    spec_fixture(ctx.alice_scope, ctx.task.ident)
    Map.put(ctx, :source, source)
  end

  test "requests of both on one version: the source's is closed with an event", ctx do
    bob = ctx.bob_scope.actor

    {:ok, _} =
      TaskSpecs.request_reviews(ctx.alice_scope, ctx.task.ident, [bob.name, "keel/review"])

    # Request 2 as if made for the unclaimed identity: both pend on v1.
    Repo.update_all(from(r in ReviewRequest, where: r.number == 2),
      set: [reviewer_id: ctx.source.id]
    )

    {:ok, claim} = Actors.request_claim(ctx.bob_scope, "robert")
    assert {:ok, _} = Actors.decide_claim(ctx.alice_scope, claim.id, :approve)

    assert [{1, :requested, b1}, {2, :cancelled, b2}] =
             Repo.all(
               from(r in ReviewRequest,
                 order_by: r.number,
                 select: {r.number, r.status, r.reviewer_id}
               )
             )

    assert {b1, b2} == {bob.id, bob.id}

    spec = Repo.get_by!(Spec, task_id: ctx.task.id)

    events =
      Repo.all(from(e in Event, where: e.spec_id == ^spec.id)) |> Enum.map(&Map.from_struct/1)

    replay = State.replay(events)
    assert replay.spec.status == spec.status
    assert spec.status == :in_review

    assert %{1 => %{status: :requested}, 2 => %{status: :cancelled, close_reason: :withdrawn}} =
             replay.requests

    assert spec.event_seq == length(events)
  end
end
