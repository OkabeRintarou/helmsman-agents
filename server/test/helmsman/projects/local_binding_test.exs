defmodule Helmsman.Projects.LocalBindingTest do
  # add-local-repositories 2.3: binding a project to a local repository
  # (decision 5).
  use Helmsman.DataCase, async: true

  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Projects
  alias Helmsman.Projects.Project

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    local = local_repository_fixture(ctx.workspace, daemon, %{default_branch: "trunk"})
    repository = repository_fixture(installation_fixture(ctx.workspace))
    Map.merge(ctx, %{daemon: daemon, local: local, repository: repository})
  end

  defp key(ctx), do: ctx.project.key
  defp reload(ctx), do: Repo.get!(Project, ctx.project.id)

  test "bound to a GitHub repository: binding a local one is refused (scenario)", ctx do
    bind_repository(ctx.project, ctx.repository)

    assert {:error, :repository_already_bound} =
             Projects.bind_local_repository(ctx.alice_scope, key(ctx), ctx.local.id)

    assert %Project{repository_id: id, local_repository_id: nil} = reload(ctx)
    assert id == ctx.repository.id
  end

  test "a member cannot bind (scenario)", ctx do
    {_bob, scope} = member_scope_fixture(ctx.workspace, :member)

    assert {:error, :forbidden} = Projects.bind_local_repository(scope, key(ctx), ctx.local.id)
    assert reload(ctx).local_repository_id == nil
  end

  test "binding, reading and unbinding", ctx do
    {_carol, admin} = member_scope_fixture(ctx.workspace, :admin)

    assert {:ok, project} = Projects.bind_local_repository(admin, key(ctx), ctx.local.id)
    assert project.local_repository_id == ctx.local.id
    assert project.effective_base_branch == "trunk"
    assert project.repository == nil

    assert %{
             id: id,
             name: "app",
             daemon_name: "test-machine",
             status: "online",
             path: "/home/alice/code/app"
           } = project.local_repository

    assert id == ctx.local.id

    assert {:ok, project} = Projects.bind_local_repository(admin, key(ctx), nil)
    assert project.local_repository_id == nil
    assert project.local_repository == nil
    assert reload(ctx).local_repository_id == nil
  end

  test "the project's base branch wins over the default branch", ctx do
    bind_local(ctx.project, ctx.local, "develop")
    assert {:ok, %{effective_base_branch: "develop"}} = Projects.get(ctx.alice_scope, key(ctx))

    assert {:ok, %{base_branch: "release", effective_base_branch: "release"}} =
             Projects.update_github_settings(ctx.alice_scope, key(ctx), %{base_branch: "release"})

    assert reload(ctx).local_repository_id == ctx.local.id
  end

  test "removed or missing: not found; offline or unavailable: bindable", ctx do
    removed =
      local_repository_fixture(ctx.workspace, ctx.daemon, %{
        name: "old",
        removed_at: DateTime.utc_now(:second)
      })

    other = dispatch_fixture()
    foreign = local_repository_fixture(other.workspace, daemon_of(other.agent))

    for id <- [removed.id, foreign.id, -1] do
      assert {:error, :not_found} =
               Projects.bind_local_repository(ctx.alice_scope, key(ctx), id)
    end

    for {name, status, reason} <- [{"off", "offline", nil}, {"bad", "unavailable", "missing"}] do
      repo =
        local_repository_fixture(ctx.workspace, ctx.daemon, %{
          name: name,
          status: status,
          unavailable_reason: reason
        })

      assert {:ok, %{local_repository: %{status: ^status}}} =
               Projects.bind_local_repository(ctx.alice_scope, key(ctx), repo.id)
    end
  end

  test "bound locally: binding a GitHub repository is refused", ctx do
    bind_local(ctx.project, ctx.local)

    assert {:error, :repository_already_bound} =
             Projects.update_github_settings(ctx.alice_scope, key(ctx), %{
               repository_id: ctx.repository.id
             })

    assert %Project{repository_id: nil, local_repository_id: id} = reload(ctx)
    assert id == ctx.local.id

    # Merge settings alone are still accepted.
    assert {:ok, %{merge_method: "merge"}} =
             Projects.update_github_settings(ctx.alice_scope, key(ctx), %{merge_method: "merge"})
  end

  test "members read the binding without the path", ctx do
    bind_local(ctx.project, ctx.local)
    {_bob, scope} = member_scope_fixture(ctx.workspace, :member)

    assert {:ok, %{local_repository: %{name: "app", path: nil}}} = Projects.get(scope, key(ctx))
    assert {:ok, projects} = Projects.list(scope)

    assert [%{local_repository: %{path: nil}}] =
             Enum.filter(projects, &(&1.id == ctx.project.id))

    assert {:ok, %{local_repository: %{path: "/home/alice/code/app"}}} =
             Projects.get(ctx.alice_scope, key(ctx))
  end
end
