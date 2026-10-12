defmodule Helmsman.GitHub.SyncTest do
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.GitHub
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Workers.RefreshInstallation
  alias Helmsman.GitHub.Workers.SyncAll
  alias Helmsman.GitHub.Workers.SyncRepositories

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    installation = installation_fixture(workspace)

    %{
      workspace: workspace,
      scope: workspace_scope_fixture(owner, workspace),
      installation: installation,
      id: installation.installation_id
    }
  end

  # Serves `repos` 100 per page; `before_last_page` runs before the last
  # page is answered.
  defp stub_repos(repos, opts \\ []) do
    before_last_page = Keyword.get(opts, :before_last_page, fn -> :ok end)
    pages = repos |> Enum.chunk_every(100) |> then(&if(&1 == [], do: [[]], else: &1))

    stub_github(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _} ->
          token_response(conn)

        {"GET", "/installation/repositories"} ->
          serve_page(conn, pages, length(repos), before_last_page)
      end
    end)
  end

  defp serve_page(conn, pages, total, before_last_page) do
    conn = Plug.Conn.fetch_query_params(conn)
    page = String.to_integer(conn.query_params["page"] || "1")
    if page == length(pages), do: before_last_page.()

    conn
    |> put_next_link(page, length(pages))
    |> Req.Test.json(%{"total_count" => total, "repositories" => Enum.at(pages, page - 1)})
  end

  defp put_next_link(conn, page, page_count) when page < page_count do
    Plug.Conn.put_resp_header(
      conn,
      "link",
      ~s(<https://api.github.com/installation/repositories?per_page=100&page=#{page + 1}>; rel="next")
    )
  end

  defp put_next_link(conn, _page, _page_count), do: conn

  defp repos(installation),
    do: Repo.all(from(r in Repository, where: r.installation_id == ^installation.id))

  defp subscribe(workspace), do: Events.subscribe(Events.topic(:workspace, workspace.id))

  test "230 repositories over 3 pages", %{
    installation: installation,
    id: id,
    workspace: ws,
    scope: scope
  } do
    stub_repos(for n <- 1..230, do: github_repo(n, "acme", "repo#{n}"))
    subscribe(ws)

    assert :ok = perform_job(SyncRepositories, %{installation_id: id})

    synced = repos(installation)
    assert length(synced) == 230
    assert Enum.all?(synced, &is_nil(&1.removed_at))
    assert {:ok, %{repositories: listed}} = GitHub.status(scope)
    assert length(listed) == 230 and Enum.all?(listed, & &1.available)
    assert_receive {:github_changed}
    refute_receive {:github_changed}, 50
  end

  test "updates by GitHub ID, marks the missing removed and restores the reappeared", %{
    installation: installation,
    id: id
  } do
    kept = repository_fixture(installation, %{github_id: 1, name: "web"})
    gone = repository_fixture(installation, %{github_id: 2, name: "api"})

    stub_repos([
      github_repo(1, "acme", "site", %{"default_branch" => "trunk", "archived" => true}),
      github_repo(3, "acme", "new")
    ])

    assert :ok = perform_job(SyncRepositories, %{installation_id: id})

    kept = Repo.get!(Repository, kept.id)
    assert {kept.name, kept.default_branch, kept.archived} == {"site", "trunk", true}
    assert Repo.get!(Repository, gone.id).removed_at
    assert Repo.get_by!(Repository, github_id: 3, installation_id: installation.id)

    stub_repos([github_repo(1, "acme", "site"), github_repo(2, "acme", "api")])
    assert :ok = perform_job(SyncRepositories, %{installation_id: id})
    assert is_nil(Repo.get!(Repository, gone.id).removed_at)
    assert Repo.get_by!(Repository, github_id: 3, installation_id: installation.id).removed_at
  end

  test "disconnected after fetching: the result is dropped", %{
    installation: installation,
    id: id,
    scope: scope,
    workspace: ws
  } do
    repository = repository_fixture(installation, %{github_id: 1})

    stub_repos([github_repo(1, "acme", "web"), github_repo(2, "acme", "api")],
      before_last_page: fn -> assert {:ok, _} = GitHub.disconnect_installation(scope) end
    )

    subscribe(ws)
    assert :ok = perform_job(SyncRepositories, %{installation_id: id})

    assert [%Repository{id: id, removed_at: %DateTime{}}] = repos(installation)
    assert id == repository.id
    # Only the disconnect's notification.
    assert_receive {:github_changed}
    refute_receive {:github_changed}, 50
  end

  test "an older list applied after a newer one is dropped", %{installation: installation, id: id} do
    t = DateTime.utc_now()
    newer = [github_repo(1, "acme", "renamed")]
    older = [github_repo(1, "acme", "old"), github_repo(2, "acme", "other")]

    assert {:ok, :applied} = Installations.apply_repositories(id, newer, DateTime.add(t, 2))
    assert {:ok, :stale} = Installations.apply_repositories(id, older, DateTime.add(t, 1))

    assert [%Repository{name: "renamed", removed_at: nil}] = repos(installation)
    assert Repo.get!(Installation, installation.id).repos_fetched_at == DateTime.add(t, 2)
  end

  test "three sync requests leave one available job", %{id: id} do
    for _ <- 1..3, do: {:ok, _} = Oban.insert(SyncRepositories.new(%{installation_id: id}))
    assert [_one] = all_enqueued(worker: SyncRepositories, args: %{installation_id: id})
  end

  test "rate limits snooze until the reset time", %{id: id} do
    reset = DateTime.utc_now(:second) |> DateTime.add(120)

    stub_github(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", "#{DateTime.to_unix(reset)}")
      |> Plug.Conn.send_resp(403, "")
    end)

    assert {:snooze, seconds} = perform_job(SyncRepositories, %{installation_id: id})
    assert seconds in 115..120
  end

  test "unknown and disconnected installations end at once", %{installation: installation, id: id} do
    stub_github(fn _conn -> flunk("GitHub must not be called") end)
    assert :ok = perform_job(SyncRepositories, %{installation_id: unique_github_id()})

    Repo.update!(Ecto.Changeset.change(installation, disconnected_at: DateTime.utc_now(:second)))
    assert :ok = perform_job(SyncRepositories, %{installation_id: id})
  end

  test "an installation GitHub no longer knows enqueues a refresh", %{id: id} do
    stub_github(&not_found/1)
    assert :ok = perform_job(SyncRepositories, %{installation_id: id})
    assert_enqueued(worker: RefreshInstallation, args: %{installation_id: id})
  end

  test "SyncAll enqueues every connected installation", %{id: id} do
    owner = user_fixture()
    other = installation_fixture(workspace_fixture(owner))

    disconnected =
      installation_fixture(workspace_fixture(owner), %{disconnected_at: DateTime.utc_now(:second)})

    assert :ok = perform_job(SyncAll, %{})
    assert_enqueued(worker: SyncRepositories, args: %{installation_id: id})
    assert_enqueued(worker: SyncRepositories, args: %{installation_id: other.installation_id})

    refute_enqueued(
      worker: SyncRepositories,
      args: %{installation_id: disconnected.installation_id}
    )
  end
end
