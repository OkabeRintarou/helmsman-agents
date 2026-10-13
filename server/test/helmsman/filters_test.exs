defmodule Helmsman.FiltersTest do
  use Helmsman.DataCase, async: true
  import Helmsman.BQLFixtures

  import Helmsman.RunsFixtures,
    only: [member_scope_fixture: 2, dispatch_fixture: 0, run_fixture: 2, run_scope_fixture: 1]

  alias Helmsman.{Filters, Policy, Tasks, Tx}
  alias Helmsman.Filters.SavedFilter

  setup do
    ctx = bql_fixture()
    {:ok, private} = Filters.create(ctx.scope, %{name: "Private", bql: "status = new"})

    {:ok, shared} =
      Filters.create(ctx.scope, %{name: "Shared", bql: "status = done", visibility: :workspace})

    Map.merge(ctx, %{private: private, shared: shared})
  end

  test "visibility, readable state, case-insensitive unique names and validation", ctx do
    assert {:ok, %{mine: [private, shared], shared: []}} = Filters.list(ctx.scope)
    assert private.valid_bql and shared.valid_bql
    assert {:error, c} = Filters.create(ctx.scope, %{name: "pRIVATE", bql: ""})
    assert errors_on(c).name == ["has already been taken"]

    for attrs <- [
          %{name: "", bql: ""},
          %{name: String.duplicate("文", 81), bql: ""},
          %{name: "foo", bql: String.duplicate("x", 2001)}
        ],
        do: assert({:error, %Ecto.Changeset{}} = Filters.create(ctx.scope, attrs))

    assert {:error, c} = Filters.update(ctx.scope, ctx.shared.id, %{bql: "foo = 1"})
    assert errors_on(c).bql == ["unknown field 'foo' (position 1)"]
    assert {:ok, %{bql: "status = done"}} = Filters.get(ctx.scope, ctx.shared.id)

    Repo.update_all(from(f in SavedFilter, where: f.id == ^ctx.private.id),
      set: [bql: "legacy_unknown = 1"]
    )

    assert {:ok, %{valid_bql: false, bql_error: %{message: "unknown field 'legacy_unknown'"}}} =
             Filters.get(ctx.scope, ctx.private.id)
  end

  test "policy role/resource matrix, including API agent and run scopes", ctx do
    for role <- [:owner, :admin, :member, :viewer] do
      {_user, scope} = member_scope_fixture(ctx.workspace, role)
      own = %{ctx.private | owner_id: scope.user.id}

      for {filter, owned, visible} <- [
            {own, true, true},
            {ctx.private, false, false},
            {ctx.shared, false, true}
          ] do
        assert Policy.authorize(scope, :create_filter) ==
                 if(role == :viewer, do: {:error, :forbidden}, else: :ok)

        for action <- [:update_filter, :delete_filter] do
          expected = role != :viewer and (owned or (visible and role in [:owner, :admin]))

          assert Policy.authorize(scope, action, filter) ==
                   if(expected, do: :ok, else: {:error, :forbidden})
        end

        expected = role != :viewer and owned

        assert Policy.authorize(scope, :change_filter_visibility, filter) ==
                 if(expected, do: :ok, else: {:error, :forbidden})
      end

      assert {:error, :not_found} = Filters.get(scope, ctx.private.id)
      assert {:error, :not_found} = Tasks.query(scope, ctx.private)
      assert {:ok, _} = Filters.get(scope, ctx.shared.id)

      if role != :viewer do
        assert {:error, :not_found} = Filters.update(scope, ctx.private.id, %{name: "leak"})
        assert {:error, :not_found} = Filters.delete(scope, ctx.private.id)
      end
    end

    assert {:ok, _} =
             Filters.create(%{ctx.scope | actor: ctx.keel, via: :mcp}, %{
               name: "Agent-owned-by-user",
               bql: ""
             })

    other = dispatch_fixture()
    run = run_fixture(other.agent, %{status: :running})
    {run_scope, _} = run_scope_fixture(run)

    for role <- [:owner, :admin, :member, :viewer],
        action <- [:create_filter, :update_filter, :delete_filter, :change_filter_visibility],
        filter <- [ctx.private, ctx.shared],
        do:
          assert(
            Policy.authorize(%{run_scope | role: role}, action, filter) == {:error, :forbidden}
          )
  end

  test "admin edits shared query but only owner changes visibility", ctx do
    {_user, admin} = member_scope_fixture(ctx.workspace, :admin)

    assert {:ok, f} =
             Filters.update(admin, ctx.shared.id, %{name: "triage", bql: "status = verified"})

    assert f.visibility == :workspace
    assert {:error, :forbidden} = Filters.update(admin, ctx.shared.id, %{visibility: :private})
    assert {:ok, _} = Filters.delete(admin, ctx.shared.id)

    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    assert {:error, :forbidden} = Filters.create(viewer_scope, %{name: "no", bql: ""})
  end

  test "partial updates, stale versions and no-op changes", ctx do
    f = ctx.private

    assert {:ok, updated} =
             Filters.update(ctx.scope, f.id, %{name: "renamed", lock_version: f.lock_version})

    assert updated.bql == f.bql and updated.visibility == f.visibility
    assert updated.lock_version == f.lock_version + 1

    assert {:error, :stale} =
             Filters.update(ctx.scope, f.id, %{bql: "status = done", lock_version: f.lock_version})

    assert {:ok, latest} = Filters.update(ctx.scope, f.id, %{bql: "status = done"})
    assert latest.lock_version == updated.lock_version + 1
    assert {:ok, unchanged} = Filters.update(ctx.scope, f.id, %{})
    assert unchanged.lock_version == latest.lock_version
    assert {:ok, %{tasks: [_], total: 1}} = Tasks.query(ctx.scope, f)
    assert {:error, :not_found} = Filters.get(ctx.scope, "invalid")
    assert {:ok, _} = Filters.get(ctx.scope, "#{f.id}")
  end

  test "100-filter quota", ctx do
    now = DateTime.utc_now()

    rows =
      for i <- 1..98,
          do: %{
            workspace_id: ctx.workspace.id,
            owner_id: ctx.user.id,
            name: "f#{i}",
            bql: "",
            visibility: :private,
            lock_version: 1,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(SavedFilter, rows)
    assert {:error, c} = Filters.create(ctx.scope, %{name: "over", bql: ""})
    assert errors_on(c).name == ["at most 100 filters per workspace"]
    assert {:ok, _} = Filters.delete(ctx.scope, ctx.private.id)
    assert {:ok, _} = Filters.create(ctx.scope, %{name: "after delete", bql: ""})
  end

  test "commit notifications honor private audiences and rollback", ctx do
    ws = "workspace:#{ctx.workspace.id}:filters"
    private = ws <> ":#{ctx.user.id}"
    Phoenix.PubSub.subscribe(Helmsman.PubSub, ws)
    Phoenix.PubSub.subscribe(Helmsman.PubSub, private)
    assert {:ok, _} = Filters.update(ctx.scope, ctx.private.id, %{name: "p"})
    assert_receive {:filters_changed, :private}
    refute_receive {:filters_changed, :workspace}
    assert {:ok, _} = Filters.update(ctx.scope, ctx.private.id, %{visibility: :workspace})
    assert_receive {:filters_changed, :private}
    assert_receive {:filters_changed, :workspace}
    assert {:ok, _} = Filters.update(ctx.scope, ctx.private.id, %{})
    refute_receive {:filters_changed, _}

    assert {:error, :rollback} =
             Tx.run(fn ->
               {:ok, _} =
                 Filters.create(ctx.scope, %{name: "rolled back", bql: "", visibility: :workspace})

               {:error, :rollback}
             end)

    refute_receive {:filters_changed, _}
  end
end
