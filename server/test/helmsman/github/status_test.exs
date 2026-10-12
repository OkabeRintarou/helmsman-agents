defmodule Helmsman.GitHub.StatusTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.GitHub

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    installation = installation_fixture(workspace, %{account_login: "acme"})
    web = repository_fixture(installation, %{owner: "acme", name: "web", private: true})
    repository_fixture(installation, %{owner: "acme", name: "old", archived: true})

    repository_fixture(installation, %{
      owner: "acme",
      name: "gone",
      removed_at: DateTime.utc_now(:second)
    })

    %{
      workspace: workspace,
      scope: workspace_scope_fixture(owner, workspace),
      web: web
    }
  end

  defp scope_with_role(workspace, role) do
    user = user_fixture()
    member_fixture(workspace, user, role)
    workspace_scope_fixture(user, workspace)
  end

  test "a viewer reads the installation account and the repositories", %{workspace: ws} do
    assert {:ok, status} = GitHub.status(scope_with_role(ws, :viewer))

    assert status.configured?

    assert status.installation == %{
             account_login: "acme",
             account_type: "Organization",
             suspended?: false,
             disconnected?: false
           }

    assert [
             %{full_name: "acme/old", available: false},
             %{full_name: "acme/web", available: true, private: true, default_branch: "main"}
           ] = status.repositories
  end

  test "a workspace without installation", %{} do
    owner = user_fixture()
    ws = workspace_fixture(owner)

    assert {:ok, %{installation: nil, repositories: []}} =
             GitHub.status(workspace_scope_fixture(owner, ws))
  end

  test "a member listing branches → forbidden", %{workspace: ws, web: web} do
    stub_github(fn _conn -> flunk("GitHub must not be called") end)
    assert GitHub.list_branches(scope_with_role(ws, :member), web.id) == {:error, :forbidden}
  end

  test "an admin lists branches", %{scope: scope, web: web} do
    stub_github(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", _} ->
          token_response(conn)

        {"GET", "/repos/acme/web/branches"} ->
          Req.Test.json(conn, [%{"name" => "main"}, %{"name" => "develop"}])
      end
    end)

    assert GitHub.list_branches(scope, web.id) == {:ok, ["main", "develop"]}
  end

  test "app_overview holds no secret" do
    admin = user_fixture() |> Ecto.Changeset.change(instance_admin: true) |> Repo.update!()

    assert {:ok, overview} = GitHub.app_overview(Scope.for_user(admin))
    assert overview.configured? and overview.source == :env

    assert Map.keys(overview) |> Enum.sort() ==
             Enum.sort([:configured?, :source, :app_id, :name, :slug, :html_url, :owner_login])

    refute inspect(overview) =~ "secret"
    assert GitHub.app_overview(Scope.for_user(user_fixture())) == {:error, :forbidden}
  end
end
