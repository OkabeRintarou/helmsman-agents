defmodule Helmsman.GitHub.SchemaConstraintsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.GitHub.App

  defp app_row(app_id) do
    now = DateTime.utc_now(:second)

    %{
      app_id: app_id,
      slug: "helmsman-#{app_id}",
      name: "Helmsman #{app_id}",
      html_url: "https://github.com/apps/helmsman",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k",
      webhook_secret: "w",
      inserted_at: now,
      updated_at: now
    }
  end

  setup do
    owner = user_fixture()
    a = workspace_fixture(owner)
    b = workspace_fixture(owner)
    %{a: a, b: b, scope_a: workspace_scope_fixture(owner, a)}
  end

  test "a second github_apps row is refused" do
    assert {1, _} = Repo.insert_all(App, [app_row(1)])

    assert_raise Postgrex.Error, ~r/github_apps_single_row/, fn ->
      Repo.insert_all(App, [app_row(2)])
    end
  end

  test "secrets are stored encrypted" do
    Repo.insert!(%App{
      app_id: 7,
      slug: "s",
      name: "n",
      html_url: "u",
      client_id: "c",
      client_secret: "plain-client-secret",
      private_key: "plain-private-key",
      webhook_secret: "plain-webhook-secret"
    })

    %{rows: [[client_secret, private_key, webhook_secret]]} =
      Repo.query!("SELECT client_secret, private_key, webhook_secret FROM github_apps")

    refute client_secret =~ "plain"
    refute private_key =~ "plain"
    refute webhook_secret =~ "plain"
    assert Repo.one(App).private_key == "plain-private-key"
  end

  test "a repository cannot reference another workspace's installation", %{a: a, b: b} do
    installation = installation_fixture(a)
    now = DateTime.utc_now(:second)

    row = %{
      workspace_id: b.id,
      installation_id: installation.id,
      github_id: 1,
      owner: "acme",
      name: "web",
      default_branch: "main",
      inserted_at: now,
      updated_at: now
    }

    assert_raise Postgrex.Error, ~r/foreign_key_violation|violates foreign key/, fn ->
      Repo.insert_all("repositories", [row])
    end
  end

  test "a project cannot reference another workspace's repository", %{a: a, b: b} do
    repository = a |> installation_fixture() |> repository_fixture()
    now = DateTime.utc_now(:second)

    row = %{
      workspace_id: b.id,
      key: "GH",
      name: "GitHub",
      repository_id: repository.id,
      inserted_at: now,
      updated_at: now
    }

    assert_raise Postgrex.Error, ~r/violates foreign key/, fn ->
      Repo.insert_all("projects", [row])
    end

    assert {1, _} = Repo.insert_all("projects", [%{row | workspace_id: a.id}])
  end

  test "merge_policy 'auto' is refused", %{scope_a: scope} do
    project = project_fixture(scope)

    now = DateTime.utc_now(:second)

    row = %{
      workspace_id: project.workspace_id,
      key: "AUTO",
      name: "Auto",
      merge_policy: "auto",
      inserted_at: now,
      updated_at: now
    }

    assert_raise Postgrex.Error, ~r/projects_merge_policy_check/, fn ->
      Repo.insert_all("projects", [row])
    end
  end
end
