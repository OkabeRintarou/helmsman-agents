defmodule Helmsman.GitHub.HandleWebhookTest do
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Workers.HandleWebhook
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.GitHub.Workers.RefreshInstallation
  alias Helmsman.GitHub.Workers.SyncRepositories
  alias Helmsman.Projects

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    installation = installation_fixture(workspace)
    web = repository_fixture(installation, %{github_id: 101, owner: "acme", name: "web"})
    project_fixture(scope, %{key: "BOS"})
    {:ok, _} = Projects.update_github_settings(scope, "BOS", %{repository_id: web.id})

    %{scope: scope, installation: installation, id: installation.installation_id, web: web}
  end

  # A payload from test/fixtures/github with the installation ID replaced.
  defp payload(name, installation_id) do
    "test/fixtures/github/#{name}.json"
    |> File.read!()
    |> Jason.decode!()
    |> put_in(["installation", "id"], installation_id)
  end

  defp handle(event, name, installation_id) do
    perform_job(HandleWebhook, %{
      delivery_id: "d-#{System.unique_integer([:positive])}",
      event: event,
      payload: payload(name, installation_id)
    })
  end

  # GitHub's current state: the installation (`installation`) and its
  # repositories (`repos`).
  defp stub_github_state(opts) do
    installation =
      Keyword.get(opts, :installation, fn conn, id ->
        Req.Test.json(conn, github_installation(id))
      end)

    repos = Keyword.get(opts, :repos, [])

    stub_github(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/app/installations/" <> id} -> installation.(conn, String.to_integer(id))
        {"POST", "/app/installations/" <> _} -> token_response(conn)
        {"GET", "/installation/repositories"} -> Req.Test.json(conn, %{"repositories" => repos})
      end
    end)
  end

  defp sync(id) do
    assert_enqueued(worker: SyncRepositories, args: %{installation_id: id})
    assert :ok = perform_job(SyncRepositories, %{installation_id: id})
  end

  defp refresh(id) do
    assert_enqueued(worker: RefreshInstallation, args: %{installation_id: id})
    assert :ok = perform_job(RefreshInstallation, %{installation_id: id})
  end

  test "removed from the installation: unavailable after the sync, binding kept", %{
    scope: scope,
    id: id,
    web: web
  } do
    stub_github_state(repos: [github_repo(102, "acme", "api")])

    assert :ok = handle("installation_repositories", "installation_repositories_removed", id)
    refute_enqueued(worker: RefreshInstallation)
    sync(id)

    assert Repo.get!(Repository, web.id).removed_at
    assert {:ok, project} = Projects.get(scope, "BOS")
    assert project.repository_id == web.id
    assert project.repository.available == false
  end

  test "renamed: the name follows GitHub, the ID and the binding stay", %{
    scope: scope,
    id: id,
    web: web
  } do
    stub_github_state(repos: [github_repo(101, "acme", "site")])

    assert :ok = handle("repository", "repository_renamed", id)
    sync(id)

    renamed = Repo.get!(Repository, web.id)
    assert {renamed.name, renamed.github_id} == {"site", 101}
    assert {:ok, %{repository: %{full_name: "acme/site"}}} = Projects.get(scope, "BOS")
  end

  test "edited: the sync brings the new default branch", %{scope: scope, id: id, web: web} do
    stub_github_state(repos: [github_repo(101, "acme", "web", %{"default_branch" => "develop"})])

    assert :ok = handle("repository", "repository_edited", id)
    sync(id)

    assert Repo.get!(Repository, web.id).default_branch == "develop"
    assert {:ok, %{effective_base_branch: "develop"}} = Projects.get(scope, "BOS")
  end

  test "an installation never linked to a workspace is ignored" do
    stub_github(fn _conn -> flunk("GitHub must not be called") end)
    unknown = unique_github_id()

    assert :ok = handle("installation_repositories", "installation_repositories_added", unknown)
    assert :ok = handle("installation", "installation_suspend", unknown)
    refute_enqueued(worker: SyncRepositories)
    refute_enqueued(worker: RefreshInstallation)
    refute Repo.exists?(from(r in Repository, where: r.github_id == 102))
  end

  test "a disconnected installation is ignored", %{installation: installation, id: id} do
    Repo.update!(Ecto.Changeset.change(installation, disconnected_at: DateTime.utc_now(:second)))
    assert :ok = handle("installation_repositories", "installation_repositories_added", id)
    refute_enqueued(worker: SyncRepositories)
  end

  test "unsuspend before suspend: both re-read GitHub; the installation ends active", %{
    scope: scope,
    installation: installation,
    id: id
  } do
    Repo.update!(Ecto.Changeset.change(installation, suspended_at: ~U[2026-10-01 09:00:00Z]))
    # GitHub's current state: suspended, then unsuspended.
    stub_github_state(repos: [github_repo(101, "acme", "web")])

    assert :ok = handle("installation", "installation_unsuspend", id)
    refresh(id)
    sync(id)
    assert is_nil(Repo.get!(Installation, installation.id).suspended_at)

    # The late `suspend` event carries suspended_at, but GitHub says
    # otherwise and wins.
    assert :ok = handle("installation", "installation_suspend", id)
    refresh(id)

    assert is_nil(Repo.get!(Installation, installation.id).suspended_at)
    assert {:ok, %{repository: %{available: true}}} = Projects.get(scope, "BOS")
  end

  test "a suspension read from GitHub makes the repositories unavailable", %{
    scope: scope,
    installation: installation,
    id: id
  } do
    stub_github_state(
      installation: fn conn, id ->
        Req.Test.json(conn, github_installation(id, %{"suspended_at" => "2026-10-02T10:00:00Z"}))
      end
    )

    assert :ok = handle("installation", "installation_suspend", id)
    refresh(id)

    assert Repo.get!(Installation, installation.id).suspended_at == ~U[2026-10-02 10:00:00Z]
    assert {:ok, %{repository: %{available: false}}} = Projects.get(scope, "BOS")
  end

  test "RefreshInstallation on 404 disconnects", %{installation: installation, id: id, web: web} do
    stub_github_state(installation: fn conn, _id -> not_found(conn) end)

    assert :ok = handle("installation", "installation_deleted", id)
    refresh(id)

    assert Repo.get!(Installation, installation.id).disconnected_at
    assert Repo.get!(Repository, web.id).removed_at
  end

  test "a late 404 fetched before the applied details is dropped", %{
    installation: installation,
    id: id
  } do
    applied_at = installation.fetched_at

    assert {:ok, :stale} =
             Installations.apply_refresh(id, :gone, DateTime.add(applied_at, -1))

    row = Repo.get!(Installation, installation.id)
    assert is_nil(row.disconnected_at)
    assert row.fetched_at == applied_at
  end

  test "a refresh fetched before fetched_at is dropped", %{installation: installation, id: id} do
    future = DateTime.add(DateTime.utc_now(), 3600)
    Repo.update!(Ecto.Changeset.change(installation, fetched_at: future))

    stub_github_state(
      installation: fn conn, id ->
        Req.Test.json(conn, github_installation(id, %{"suspended_at" => "2026-10-02T10:00:00Z"}))
      end
    )

    assert :ok = perform_job(RefreshInstallation, %{installation_id: id})
    row = Repo.get!(Installation, installation.id)
    assert is_nil(row.suspended_at)
    assert row.fetched_at == future
  end

  test "the same event handled twice enqueues once and ends the same", %{
    installation: installation,
    id: id
  } do
    stub_github_state([])

    args = %{
      delivery_id: "d-dup",
      event: "installation",
      payload: payload("installation_suspend", id)
    }

    assert :ok = perform_job(HandleWebhook, args)
    assert :ok = perform_job(HandleWebhook, args)
    assert [_one] = all_enqueued(worker: RefreshInstallation, args: %{installation_id: id})

    refresh(id)
    first = Repo.get!(Installation, installation.id)
    refresh(id)
    second = Repo.get!(Installation, installation.id)

    assert {first.suspended_at, first.disconnected_at} ==
             {second.suspended_at, second.disconnected_at}
  end

  test "pull_request events go to PullRequests.handle/2", %{id: id, scope: scope, web: web} do
    stub_github(fn _conn -> flunk("GitHub must not be called") end)
    task = task_fixture(scope, "BOS")

    Repo.insert!(%Helmsman.GitHub.PullRequest{
      workspace_id: task.workspace_id,
      task_id: task.id,
      repository_id: web.id,
      number: 2,
      node_id: "PR_2",
      url: "https://github.com/acme/web/pull/2",
      branch: "hm/bos-12",
      base_branch: "main",
      state: :open
    })

    assert :ok = handle("pull_request", "pull_request_opened", id)
    assert_enqueued(worker: ReconcilePR, args: %{task_id: task.id})
    refute_enqueued(worker: SyncRepositories)
  end
end
