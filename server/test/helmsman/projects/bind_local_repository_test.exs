defmodule Helmsman.Projects.BindLocalRepositoryTest do
  # add-local-repositories 2.8: binding with a base branch and unbinding
  # (decision 18).
  use Helmsman.DataCase, async: true

  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Projects}
  alias Helmsman.Projects.Project

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    local = local_repository_fixture(ctx.workspace, daemon, %{default_branch: "trunk"})
    other = local_repository_fixture(ctx.workspace, daemon, %{name: "tools"})
    Map.merge(ctx, %{local: local, other: other})
  end

  defp bind(ctx, id, opts \\ []),
    do: Projects.bind_local_repository(ctx.alice_scope, ctx.project.key, id, opts)

  defp reload(ctx), do: Repo.get!(Project, ctx.project.id)

  test "绑定并设置基础分支 in one write", ctx do
    assert {:ok, project} = bind(ctx, ctx.local.id, base_branch: "develop")
    assert %{local_repository_id: id, base_branch: "develop"} = project
    assert id == ctx.local.id
    assert project.effective_base_branch == "develop"
    assert %{local_repository_id: ^id, base_branch: "develop"} = reload(ctx)
  end

  test "\"\" and nil are the default branch; no option keeps the branch", ctx do
    {:ok, _} = bind(ctx, ctx.local.id, base_branch: "develop")
    assert {:ok, %{base_branch: "develop"}} = bind(ctx, ctx.other.id)

    assert {:ok, %{base_branch: nil, effective_base_branch: "main"}} =
             bind(ctx, ctx.other.id, base_branch: "")

    {:ok, _} = bind(ctx, ctx.other.id, base_branch: "x")
    assert {:ok, %{base_branch: nil}} = bind(ctx, ctx.other.id, base_branch: nil)
  end

  test "the same repository: only the base branch changes", ctx do
    {:ok, _} = bind(ctx, ctx.local.id)
    :ok = Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
    assert {:ok, %{base_branch: "release"}} = bind(ctx, ctx.local.id, base_branch: "release")
    assert reload(ctx).local_repository_id == ctx.local.id
    assert_receive {:projects_changed}

    # Nothing to change: no write, no notification.
    assert {:ok, %{base_branch: "release"}} = bind(ctx, ctx.local.id)
    refute_receive {:projects_changed}
  end

  test "an invalid base branch changes nothing", ctx do
    {:ok, _} = bind(ctx, ctx.local.id, base_branch: "develop")

    for bad <- [String.duplicate("b", 256), 12] do
      assert {:error, %Ecto.Changeset{} = changeset} = bind(ctx, ctx.other.id, base_branch: bad)
      assert %{base_branch: [_]} = errors_on(changeset)
    end

    assert %{local_repository_id: id, base_branch: "develop"} = reload(ctx)
    assert id == ctx.local.id
  end

  test "解绑清空基础分支, whatever the option says", ctx do
    {:ok, _} = bind(ctx, ctx.local.id, base_branch: "develop")
    assert {:ok, %{local_repository_id: nil, base_branch: nil}} = bind(ctx, nil)
    assert %{local_repository_id: nil, base_branch: nil} = reload(ctx)

    {:ok, _} = bind(ctx, ctx.local.id, base_branch: "develop")
    assert {:ok, %{base_branch: nil}} = bind(ctx, nil, base_branch: "keep-me")
    assert reload(ctx).base_branch == nil
  end

  test "rights and errors as in bind_local_repository/3", ctx do
    {_bob, member} = member_scope_fixture(ctx.workspace, :member)

    assert {:error, :forbidden} =
             Projects.bind_local_repository(member, ctx.project.key, ctx.local.id,
               base_branch: "x"
             )

    assert {:error, :not_found} = bind(ctx, -1, base_branch: "x")
    assert %{local_repository_id: nil, base_branch: nil} = reload(ctx)
  end
end
