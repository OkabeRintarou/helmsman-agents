defmodule Helmsman.ViewPrefsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  alias Helmsman.{QueryCount, Repo, ViewPrefs}
  alias Helmsman.ViewPrefs.Preference

  setup do
    ctx = dispatch_fixture()
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    Map.put(ctx, :viewer, viewer)
  end

  test "defaults; one upsert; reset defaults; partial updates and isolation", ctx do
    default = %{view: "list", hidden_columns: ["rejected", "cancelled"]}
    assert {:ok, ^default} = ViewPrefs.get(ctx.viewer)

    assert {{:ok, %{view: "board"}}, 2} =
             QueryCount.count(fn -> ViewPrefs.put(ctx.viewer, %{view: "board"}) end)

    assert {:ok, %{hidden_columns: ["new", "done"]}} =
             ViewPrefs.put(ctx.viewer, %{hidden_columns: ["done", "new", "done"]})

    assert {:ok, %{view: "list", hidden_columns: ["new", "done"]}} =
             ViewPrefs.put(ctx.viewer, %{view: "list", workspace_id: -1})

    assert {:ok, ^default} = ViewPrefs.get(ctx.alice_scope)
    assert {:ok, %{hidden_columns: []}} = ViewPrefs.put(ctx.viewer, %{hidden_columns: []})
    assert {:ok, ^default} = ViewPrefs.put(ctx.viewer, %{hidden_columns: default.hidden_columns})
  end

  test "validation and non-session scopes", ctx do
    for attrs <- [
          %{view: "bad"},
          %{hidden_columns: ["bad"]},
          %{hidden_columns: ~w(new in_progress done verified rejected cancelled)},
          %{hidden_columns: nil}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} = ViewPrefs.put(ctx.viewer, attrs)
    end

    for scope <- [
          %{ctx.viewer | via: :api},
          %{ctx.viewer | via: :mcp},
          %{ctx.viewer | token: %{}},
          %{ctx.viewer | user: nil},
          %{ctx.viewer | user: ctx.alice, workspace: %{id: -1}}
        ] do
      assert {:error, :forbidden} = ViewPrefs.put(scope, %{view: "board"})
      assert {:error, :forbidden} = ViewPrefs.get(scope)
    end
  end

  test "user and workspace foreign keys cascade", ctx do
    assert {:ok, _} = ViewPrefs.put(ctx.viewer, %{view: "board"})
    Repo.query!("DELETE FROM actors WHERE user_id = $1", [ctx.viewer.user.id])
    Repo.query!("DELETE FROM memberships WHERE user_id = $1", [ctx.viewer.user.id])
    Repo.delete!(ctx.viewer.user)
    refute Repo.get_by(Preference, user_id: ctx.viewer.user.id)
    assert {:ok, _} = ViewPrefs.put(ctx.alice_scope, %{view: "board"})
    # Workspace has other domain children; assert the database FK's delete rule directly.
    %{rows: rows} =
      Repo.query!(
        "SELECT confdeltype::text FROM pg_constraint WHERE conrelid = 'task_view_prefs'::regclass AND contype = 'f'"
      )

    assert rows == [["c"], ["c"]]
    workspace = Helmsman.WorkspacesFixtures.workspace_fixture(ctx.alice)
    scope = Helmsman.WorkspacesFixtures.workspace_scope_fixture(ctx.alice, workspace)
    assert {:ok, _} = ViewPrefs.put(scope, %{view: "board"})
    Repo.query!("DELETE FROM actors WHERE workspace_id = $1", [workspace.id])
    Repo.query!("DELETE FROM memberships WHERE workspace_id = $1", [workspace.id])
    Repo.delete!(workspace)
    refute Repo.get_by(Preference, workspace_id: workspace.id)
  end
end
