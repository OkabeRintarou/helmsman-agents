defmodule Helmsman.GitHub.InstallationsTest do
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Events
  alias Helmsman.GitHub
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Installations
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Workers.SyncRepositories
  alias Helmsman.Projects

  @user_token "gho_user_oauth_token_value"

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    %{owner: owner, workspace: workspace, scope: workspace_scope_fixture(owner, workspace)}
  end

  # Stubs the OAuth exchange, the user's installations and the App's view
  # of each installation. `details` maps an installation ID to a function
  # answering its `GET /app/installations/:id`.
  defp stub_connect(user_installations, opts \\ []) do
    details = Keyword.get(opts, :details, %{})
    repos = Keyword.get(opts, :repos, [])
    stub_github(&answer_connect(&1, user_installations, details, repos))
  end

  defp answer_connect(conn, user_installations, details, repos) do
    case {conn.method, conn.request_path} do
      {"POST", "/login/oauth/access_token"} ->
        assert %{"code" => "oauth-code", "client_id" => "Iv1.testclient"} = json_body(conn)
        Req.Test.json(conn, %{"access_token" => @user_token, "token_type" => "bearer"})

      {"GET", "/user/installations"} ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @user_token]

        Req.Test.json(conn, %{
          "total_count" => length(user_installations),
          "installations" => Enum.map(user_installations, &%{"id" => &1})
        })

      {"GET", "/app/installations/" <> id} ->
        id = String.to_integer(id)
        Map.get(details, id, &default_details/2).(conn, id)

      {"POST", "/app/installations/" <> _} ->
        token_response(conn)

      {"GET", "/installation/repositories"} ->
        Req.Test.json(conn, %{"total_count" => length(repos), "repositories" => repos})
    end
  end

  defp default_details(conn, id), do: Req.Test.json(conn, github_installation(id))

  defp subscribe(workspace), do: Events.subscribe(Events.topic(:workspace, workspace.id))

  describe "connect_installation/3" do
    test "links the installation, enqueues a sync and notifies", %{scope: scope, workspace: ws} do
      id = unique_github_id()
      stub_connect([id])
      subscribe(ws)

      assert {:ok, %Installation{installation_id: ^id, account_login: "acme"} = row} =
               GitHub.connect_installation(scope, id, "oauth-code")

      assert row.workspace_id == ws.id
      assert row.account_type == "Organization"
      assert is_nil(row.disconnected_at)
      assert_enqueued(worker: SyncRepositories, args: %{installation_id: id})
      assert_receive {:github_changed}
    end

    test "a forged installation ID is refused", %{scope: scope, workspace: ws} do
      id = unique_github_id()
      stub_connect([id + 1, id + 2])

      assert GitHub.connect_installation(scope, id, "oauth-code") ==
               {:error, :installation_not_accessible}

      refute Repo.exists?(from(i in Installation, where: i.workspace_id == ^ws.id))
      refute_enqueued(worker: SyncRepositories)
    end

    test "an installation of another workspace is refused", %{owner: owner, workspace: a} do
      id = unique_github_id()
      installation_fixture(a, %{installation_id: id})
      b = workspace_fixture(owner)
      stub_connect([id])

      assert GitHub.connect_installation(workspace_scope_fixture(owner, b), id, "oauth-code") ==
               {:error, :installation_taken}

      assert Repo.get_by!(Installation, installation_id: id).workspace_id == a.id
    end

    test "connecting again from the same workspace is an idempotent update", %{scope: scope} do
      id = unique_github_id()
      stub_connect([id])

      assert {:ok, first} = GitHub.connect_installation(scope, id, "oauth-code")
      assert {:ok, second} = GitHub.connect_installation(scope, id, "oauth-code")

      assert first.id == second.id
      assert DateTime.compare(second.fetched_at, first.fetched_at) == :gt
      assert Repo.aggregate(from(i in Installation, where: i.installation_id == ^id), :count) == 1
    end

    test "a second installation while one is connected is refused", %{scope: scope, workspace: ws} do
      installation_fixture(ws)
      id = unique_github_id()
      stub_connect([id])

      assert GitHub.connect_installation(scope, id, "oauth-code") == {:error, :already_connected}
      refute Installations.get_by_github_id(id)
    end

    test "without an OAuth code → oauth_required, no GitHub call", %{scope: scope} do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)
      assert GitHub.connect_installation(scope, 1, nil) == {:error, :oauth_required}
      assert GitHub.connect_installation(scope, 1, "") == {:error, :oauth_required}
    end

    test "members and agents → forbidden, no GitHub call", %{workspace: ws, scope: scope} do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)
      member = user_fixture()
      member_fixture(ws, member, :member)

      assert GitHub.connect_installation(workspace_scope_fixture(member, ws), 1, "c") ==
               {:error, :forbidden}

      agent_scope = %{scope | actor: %{scope.actor | kind: :agent}}
      assert GitHub.connect_installation(agent_scope, 1, "c") == {:error, :forbidden}
    end

    test "the OAuth token never reaches the logs", %{scope: scope} do
      id = unique_github_id()
      stub_connect([id])

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = GitHub.connect_installation(scope, id, "oauth-code")
        end)

      refute log =~ @user_token
    end

    test "a newer refresh applied while the callback fetched → stale, still disconnected", %{
      scope: scope,
      workspace: ws
    } do
      id = unique_github_id()
      installation_fixture(ws, %{installation_id: id})

      # The App's read for the callback answers, then a refresh fetched
      # later (404: the installation was deleted) commits before the
      # callback writes.
      stub_connect([id],
        details: %{
          id => fn conn, id ->
            assert {:ok, :applied} =
                     Installations.apply_refresh(id, :gone, DateTime.add(DateTime.utc_now(), 1))

            Req.Test.json(conn, github_installation(id))
          end
        }
      )

      subscribe(ws)
      assert GitHub.connect_installation(scope, id, "oauth-code") == {:error, :stale}

      row = Installations.get_by_github_id(id)
      assert row.disconnected_at
      # The only notification is the refresh's.
      assert_receive {:github_changed}
      refute_receive {:github_changed}, 50
      refute_enqueued(worker: SyncRepositories)
    end
  end

  describe "apply_details/3" do
    setup %{workspace: ws} do
      applied_at = ~U[2026-10-01 10:00:00.000000Z]

      row =
        installation_fixture(ws, %{
          account_login: "old",
          account_type: "User",
          fetched_at: applied_at
        })

      %{row: row, applied_at: applied_at}
    end

    @details {:ok, %{account_login: "new", account_type: "Organization", suspended_at: nil}}

    for {result, label} <- [{@details, "success"}, {:gone, "gone"}],
        {offset, freshness} <- [{1, :newer}, {0, :equal}, {-1, :older}] do
      @result result
      @offset offset
      @freshness freshness

      test "#{label} fetched #{freshness}", %{row: row, applied_at: applied_at} do
        fetched_at = DateTime.add(applied_at, @offset)

        outcome =
          Helmsman.Tx.run(fn ->
            locked =
              Repo.one!(from(i in Installation, where: i.id == ^row.id, lock: "FOR UPDATE"))

            {:ok, Installations.apply_details(locked, @result, fetched_at)}
          end)

        reloaded = Repo.get!(Installation, row.id)

        case {@freshness, @result} do
          {:newer, {:ok, _}} ->
            assert {:ok, {:ok, %Installation{}}} = outcome
            assert reloaded.account_login == "new"
            assert reloaded.account_type == "Organization"
            assert reloaded.fetched_at == fetched_at
            assert is_nil(reloaded.disconnected_at)

          {:newer, :gone} ->
            assert {:ok, {:ok, %Installation{}}} = outcome
            assert reloaded.disconnected_at
            assert reloaded.account_login == "old"
            assert reloaded.fetched_at == fetched_at

          {_stale, _result} ->
            assert outcome == {:ok, :stale}
            assert reloaded == row
        end
      end
    end
  end

  describe "disconnect_installation/1" do
    test "disconnect and reconnect: repositories come back, bindings stay", %{
      scope: scope,
      workspace: ws
    } do
      id = unique_github_id()
      installation = installation_fixture(ws, %{installation_id: id})
      repository = repository_fixture(installation, %{owner: "acme", name: "web"})
      project = project_fixture(scope, %{key: "BOS"})

      assert {:ok, _} =
               Projects.update_github_settings(scope, "BOS", %{repository_id: repository.id})

      subscribe(ws)

      assert {:ok, %Installation{disconnected_at: %DateTime{}}} =
               GitHub.disconnect_installation(scope)

      assert_receive {:github_changed}
      assert Repo.get!(Repository, repository.id).removed_at
      assert {:ok, bound} = Projects.get(scope, "BOS")
      assert bound.repository_id == repository.id
      assert bound.repository.available == false
      # Removed repositories leave the status list.
      assert {:ok, %{installation: %{disconnected?: true}, repositories: []}} =
               GitHub.status(scope)

      assert GitHub.disconnect_installation(scope) == {:error, :not_found}

      stub_connect([id], repos: [github_repo(repository.github_id, "acme", "web")])

      assert {:ok, %Installation{disconnected_at: nil}} =
               GitHub.connect_installation(scope, id, "oauth-code")

      assert_enqueued(worker: SyncRepositories, args: %{installation_id: id})
      assert :ok = perform_job(SyncRepositories, %{installation_id: id})

      assert {:ok, restored} = Projects.get(scope, "BOS")
      assert restored.id == project.id
      assert restored.repository_id == repository.id
      assert restored.repository.available
      assert is_nil(Repo.get!(Repository, repository.id).removed_at)
    end

    test "members → forbidden", %{workspace: ws} do
      installation_fixture(ws)
      member = user_fixture()
      member_fixture(ws, member, :member)

      assert GitHub.disconnect_installation(workspace_scope_fixture(member, ws)) ==
               {:error, :forbidden}
    end
  end
end
