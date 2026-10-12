defmodule Helmsman.Projects.GitHubSettingsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.GitHub
  alias Helmsman.Projects

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    installation = installation_fixture(workspace)
    web = repository_fixture(installation, %{owner: "acme", name: "web", default_branch: "main"})
    api = repository_fixture(installation, %{owner: "acme", name: "api", default_branch: "trunk"})
    project_fixture(scope, %{key: "BOS"})
    %{scope: scope, workspace: workspace, installation: installation, web: web, api: api}
  end

  # Branches that exist per repository name; `on_check` runs (once per
  # call) before a branch check is answered, and every check is reported
  # to the test as `{:checked, repo, branch}`.
  defp stub_branches(branches, on_check \\ fn _repo, _branch -> :ok end) do
    test = self()

    stub_github(fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"POST", ["app", "installations", _, "access_tokens"]} ->
          token_response(conn)

        {"GET", ["repos", "acme", repo, "branches", branch]} ->
          branch = URI.decode(branch)
          send(test, {:checked, repo, branch})
          on_check.(repo, branch)
          answer_branch(conn, branch in Map.get(branches, repo, []), branch)
      end
    end)
  end

  defp answer_branch(conn, true, branch), do: Req.Test.json(conn, %{"name" => branch})
  defp answer_branch(conn, false, _branch), do: not_found(conn)

  defp settings(scope) do
    {:ok, project} = Projects.get(scope, "BOS")

    {project.repository_id, project.base_branch, project.merge_policy, project.merge_method,
     project.require_ci, project.delete_branch_after_merge}
  end

  defp subscribe(workspace), do: Events.subscribe(Events.topic(:workspace, workspace.id))

  test "binding a repository without a base branch", %{scope: scope, web: web, workspace: ws} do
    stub_github(fn _conn -> flunk("no branch to check") end)
    subscribe(ws)

    assert {:ok, project} =
             Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})

    assert_receive {:projects_changed}

    assert {:ok, read} = Projects.get(scope, "BOS")

    for p <- [project, read] do
      assert %{owner: "acme", name: "web", full_name: "acme/web", available: true} = p.repository
      assert p.effective_base_branch == "main"
      assert is_nil(p.base_branch)
      assert {p.merge_policy, p.merge_method} == {"on_verified", "squash"}
      assert p.require_ci and p.delete_branch_after_merge
    end
  end

  test "merge settings are validated and saved", %{scope: scope} do
    assert {:ok, %{merge_policy: "manual", merge_method: "rebase", require_ci: false}} =
             Projects.update_github_settings(scope, "BOS", %{
               "merge_policy" => "manual",
               "merge_method" => "rebase",
               "require_ci" => false
             })

    assert {:error, changeset} =
             Projects.update_github_settings(scope, "BOS", %{merge_policy: "auto"})

    assert %{merge_policy: ["is invalid"]} = errors_on(changeset)
  end

  test "another workspace's repository → not_found", %{scope: scope} do
    other = installation_fixture(workspace_fixture(user_fixture()))
    foreign = repository_fixture(other)
    before = settings(scope)

    assert Projects.update_github_settings(scope, "BOS", %{repository_id: foreign.id}) ==
             {:error, :not_found}

    assert settings(scope) == before
  end

  test "a branch missing on GitHub → branch_not_found", %{scope: scope, web: web} do
    stub_branches(%{"web" => ["main"]})
    before = settings(scope)

    assert Projects.update_github_settings(scope, "BOS", %{
             repository_id: web.id,
             base_branch: "develop"
           }) == {:error, {:branch_not_found, "develop"}}

    assert settings(scope) == before

    assert {:ok, %{base_branch: "main", effective_base_branch: "main"}} =
             Projects.update_github_settings(scope, "BOS", %{
               repository_id: web.id,
               base_branch: "main"
             })
  end

  test "a repository removed from the installation → repository_unavailable", %{
    scope: scope,
    web: web
  } do
    Repo.update!(Ecto.Changeset.change(web, removed_at: DateTime.utc_now(:second)))

    assert Projects.update_github_settings(scope, "BOS", %{repository_id: web.id}) ==
             {:error, :repository_unavailable}
  end

  test "rebound during the check: re-checked on the new repository", %{
    scope: scope,
    web: web,
    api: api
  } do
    {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})

    stub_branches(%{"web" => ["develop"], "api" => ["develop"]}, fn
      "web", "develop" ->
        # B rebinds BOS to acme/api before A saves.
        assert {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: api.id})

      _repo, _branch ->
        :ok
    end)

    assert {:ok, project} =
             Projects.update_github_settings(scope, "BOS", %{base_branch: "develop"})

    assert {project.repository_id, project.base_branch} == {api.id, "develop"}
    assert_received {:checked, "web", "develop"}
    assert_received {:checked, "api", "develop"}
  end

  test "rebound during the check to a repository without the branch: not saved", %{
    scope: scope,
    web: web,
    api: api
  } do
    {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})

    stub_branches(%{"web" => ["develop"]}, fn
      "web", "develop" ->
        {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: api.id})

      _repo, _branch ->
        :ok
    end)

    assert Projects.update_github_settings(scope, "BOS", %{base_branch: "develop"}) ==
             {:error, {:branch_not_found, "develop"}}

    assert {:ok, %{repository_id: repository_id, base_branch: nil}} = Projects.get(scope, "BOS")
    assert repository_id == api.id
  end

  test "reverse crossing: base branch changed while the repository is checked", %{
    scope: scope,
    web: web,
    api: api
  } do
    stub_branches(%{"web" => ["main", "develop"], "api" => ["main"]})

    {:ok, _} =
      Projects.update_github_settings(scope, "BOS", %{repository_id: web.id, base_branch: "main"})

    stub_branches(%{"web" => ["main", "develop"], "api" => ["main"]}, fn
      "api", "main" ->
        # B sets the base branch on acme/web while A checks acme/api.
        {:ok, _} = Projects.update_github_settings(scope, "BOS", %{base_branch: "develop"})

      _repo, _branch ->
        :ok
    end)

    # A only rebinds; the pair it would save is now {api, develop},
    # which is checked and refused.
    assert Projects.update_github_settings(scope, "BOS", %{repository_id: api.id}) ==
             {:error, {:branch_not_found, "develop"}}

    assert_received {:checked, "api", "develop"}

    assert {:ok, %{repository_id: repository_id, base_branch: "develop"}} =
             Projects.get(scope, "BOS")

    assert repository_id == web.id
  end

  test "changed twice during the checks → stale", %{scope: scope, web: web, api: api} do
    {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})
    toggle = %{"web" => api.id, "api" => web.id}

    stub_branches(%{"web" => ["develop"], "api" => ["develop"]}, fn repo, _branch ->
      {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: toggle[repo]})
    end)

    assert Projects.update_github_settings(scope, "BOS", %{base_branch: "develop"}) ==
             {:error, :stale}
  end

  test "installation disconnected during the check → unavailable, unchanged, no notification",
       %{scope: scope, web: web, workspace: ws} do
    stub_branches(%{"web" => ["main"]}, fn _repo, _branch ->
      {:ok, _} = GitHub.disconnect_installation(scope)
    end)

    before = settings(scope)
    subscribe(ws)

    assert Projects.update_github_settings(scope, "BOS", %{
             repository_id: web.id,
             base_branch: "main"
           }) ==
             {:error, :repository_unavailable}

    assert settings(scope) == before
    refute_receive {:projects_changed}, 50
  end

  test "unbinding clears the repository and the base branch", %{scope: scope, web: web} do
    stub_branches(%{"web" => ["main"]})

    {:ok, _} =
      Projects.update_github_settings(scope, "BOS", %{repository_id: web.id, base_branch: "main"})

    assert {:ok,
            %{repository_id: nil, base_branch: nil, repository: nil, effective_base_branch: nil}} =
             Projects.update_github_settings(scope, "BOS", %{repository_id: nil})

    assert Projects.update_github_settings(scope, "BOS", %{base_branch: "main"}) ==
             {:error, :repository_required}
  end

  test "archived projects may be changed", %{scope: scope, web: web} do
    {:ok, _} = Projects.archive(scope, "BOS")

    assert {:ok, %{repository_id: id}} =
             Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})

    assert id == web.id
  end

  test "GitHub unreachable → github_unavailable, unchanged", %{scope: scope, web: web} do
    stub_github(&Req.Test.transport_error(&1, :econnrefused))
    before = settings(scope)

    assert {:error, {:github_unavailable, _}} =
             Projects.update_github_settings(scope, "BOS", %{
               repository_id: web.id,
               base_branch: "main"
             })

    assert settings(scope) == before
  end

  test "members and an admin's agent → forbidden", %{scope: scope, workspace: ws, web: web} do
    stub_github(fn _conn -> flunk("GitHub must not be called") end)
    member = user_fixture()
    member_fixture(ws, member, :member)

    assert Projects.update_github_settings(workspace_scope_fixture(member, ws), "BOS", %{
             merge_policy: "manual"
           }) == {:error, :forbidden}

    agent = %{scope | actor: %{scope.actor | kind: :agent}}

    assert Projects.update_github_settings(agent, "BOS", %{repository_id: web.id}) ==
             {:error, :forbidden}
  end
end
