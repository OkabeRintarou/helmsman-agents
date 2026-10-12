defmodule Helmsman.GitHub.TokensTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.GitHub
  alias Helmsman.GitHub.Tokens

  # Answers token requests with an increasing token valid one hour from the
  # request's injected time, and reports each request body to the test.
  defp stub_tokens(expires_at) do
    test = self()
    counter = :counters.new(1, [])

    stub_github(fn conn ->
      "/app/installations/" <> rest = conn.request_path
      [id, "access_tokens"] = String.split(rest, "/")
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test, {:token_request, String.to_integer(id), json_body(conn)})

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => "ghs_#{n}", "expires_at" => DateTime.to_iso8601(expires_at)})
    end)
  end

  test "caches a token for the same installation" do
    now = DateTime.utc_now()
    stub_tokens(DateTime.add(now, 3600))
    id = unique_github_id()

    assert {:ok, %{token: "ghs_1"}} = Tokens.get(id, now: now)
    assert {:ok, %{token: "ghs_1"}} = Tokens.get(id, now: DateTime.add(now, 600))
    assert_received {:token_request, ^id, %{}}
    refute_received {:token_request, _, _}
  end

  test "renews a token with 4 minutes left" do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 3600)
    stub_tokens(expires_at)
    id = unique_github_id()

    assert {:ok, %{token: "ghs_1"}} = Tokens.get(id, now: now)
    assert {:ok, %{token: "ghs_2"}} = Tokens.get(id, now: DateTime.add(expires_at, -240))
  end

  test "different narrowings are cached separately" do
    now = DateTime.utc_now()
    stub_tokens(DateTime.add(now, 3600))
    id = unique_github_id()

    assert {:ok, %{token: "ghs_1"}} = Tokens.get(id, now: now)
    assert {:ok, %{token: "ghs_2"}} = Tokens.get(id, now: now, repository_ids: [5])

    assert {:ok, %{token: "ghs_3"}} =
             Tokens.get(id, now: now, repository_ids: [5], permissions: %{"contents" => "write"})

    assert {:ok, %{token: "ghs_2"}} = Tokens.get(id, now: now, repository_ids: [5])
  end

  test "purge/1 forces a new token" do
    now = DateTime.utc_now()
    stub_tokens(DateTime.add(now, 3600))
    id = unique_github_id()

    assert {:ok, %{token: "ghs_1"}} = Tokens.get(id, now: now)
    assert :ok = Tokens.purge(id)
    assert {:ok, %{token: "ghs_2"}} = Tokens.get(id, now: now)
  end

  describe "concurrent requests for one key" do
    # Holds every token request until the test sends :go to its process;
    # reports `{:requested, pid}`.
    defp stub_held_tokens(expires_at) do
      test = self()

      stub_github(fn conn ->
        send(test, {:requested, self()})

        receive do
          :go -> :ok
        end

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "token" => "ghs_#{System.unique_integer([:positive])}",
          "expires_at" => DateTime.to_iso8601(expires_at)
        })
      end)
    end

    # Waits until `count` callers wait on the in-flight request of `key`.
    defp await_waiters(key, count) do
      case :sys.get_state(Tokens) do
        %{^key => %{waiters: waiters}} when length(waiters) >= count -> :ok
        _ -> await_waiters(key, count)
      end
    end

    defp start_get(id, now), do: Task.async(fn -> Tokens.get(id, now: now) end)

    test "two misses issue one request and share its token" do
      now = DateTime.utc_now()
      stub_held_tokens(DateTime.add(now, 3600))
      id = unique_github_id()

      first = start_get(id, now)
      assert_receive {:requested, fetcher}
      second = start_get(id, now)
      await_waiters({id, nil, nil}, 1)

      send(fetcher, :go)
      assert {:ok, token} = Task.await(first)
      assert Task.await(second) == {:ok, token}
      refute_received {:requested, _}
    end

    test "two renewals of an expiring token issue one request" do
      now = DateTime.utc_now()
      id = unique_github_id()
      stub_held_tokens(DateTime.add(now, 3600))

      warm = start_get(id, now)
      assert_receive {:requested, fetcher}
      send(fetcher, :go)
      assert {:ok, old} = Task.await(warm)

      later = DateTime.add(old.expires_at, -240)
      first = start_get(id, later)
      assert_receive {:requested, fetcher}
      second = start_get(id, later)
      await_waiters({id, nil, nil}, 1)

      send(fetcher, :go)
      assert {:ok, renewed} = Task.await(first)
      assert renewed.token != old.token
      assert Task.await(second) == {:ok, renewed}
      refute_received {:requested, _}
    end

    test "different narrowings do not wait for each other" do
      now = DateTime.utc_now()
      stub_held_tokens(DateTime.add(now, 3600))
      id = unique_github_id()

      plain = start_get(id, now)
      narrowed = Task.async(fn -> Tokens.get(id, now: now, repository_ids: [1]) end)
      assert_receive {:requested, a}
      assert_receive {:requested, b}

      send(a, :go)
      send(b, :go)
      assert {:ok, %{token: t1}} = Task.await(plain)
      assert {:ok, %{token: t2}} = Task.await(narrowed)
      assert t1 != t2
    end

    test "a waiter takes over when the fetching caller dies" do
      now = DateTime.utc_now()
      stub_held_tokens(DateTime.add(now, 3600))
      id = unique_github_id()

      doomed = Task.async(fn -> Tokens.get(id, now: now) end)
      assert_receive {:requested, fetcher}
      waiter = start_get(id, now)
      await_waiters({id, nil, nil}, 1)

      Process.unlink(doomed.pid)
      Process.exit(doomed.pid, :kill)
      assert_receive {:requested, new_fetcher}
      assert new_fetcher != fetcher
      send(new_fetcher, :go)
      assert {:ok, %{token: _}} = Task.await(waiter)
    end

    test "a token fetched across purge/1 is returned but not cached" do
      now = DateTime.utc_now()
      stub_held_tokens(DateTime.add(now, 3600))
      id = unique_github_id()

      first = start_get(id, now)
      assert_receive {:requested, fetcher}
      :ok = Tokens.purge(id)
      send(fetcher, :go)
      assert {:ok, %{token: purged}} = Task.await(first)

      second = start_get(id, now)
      assert_receive {:requested, fetcher}
      send(fetcher, :go)
      assert {:ok, %{token: fresh}} = Task.await(second)
      assert fresh != purged
    end
  end

  describe "push_token/1" do
    setup do
      owner = user_fixture()
      workspace = workspace_fixture(owner)
      installation = installation_fixture(workspace)
      repository = repository_fixture(installation, %{owner: "acme", name: "web"})
      %{installation: installation, repository: repository}
    end

    test "narrows to the repository and contents: write", %{
      installation: installation,
      repository: repository
    } do
      stub_tokens(DateTime.add(DateTime.utc_now(), 3600))

      assert {:ok, %{token: "ghs_1", expires_at: %DateTime{}}} = GitHub.push_token(repository)

      installation_id = installation.installation_id
      github_id = repository.github_id

      assert_received {:token_request, ^installation_id, body}
      assert body == %{"repository_ids" => [github_id], "permissions" => %{"contents" => "write"}}
    end

    test "a disconnected installation → error without calling GitHub", %{
      installation: installation,
      repository: repository
    } do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)

      Repo.update!(
        Ecto.Changeset.change(installation, disconnected_at: DateTime.utc_now(:second))
      )

      assert GitHub.push_token(repository) == {:error, :repository_unavailable}
    end

    test "a suspended installation or an archived repository → error", %{
      installation: installation,
      repository: repository
    } do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)

      archived = Repo.update!(Ecto.Changeset.change(repository, archived: true))
      assert GitHub.push_token(archived) == {:error, :repository_unavailable}

      Repo.update!(Ecto.Changeset.change(repository, archived: false))
      Repo.update!(Ecto.Changeset.change(installation, suspended_at: DateTime.utc_now(:second)))
      assert GitHub.push_token(repository) == {:error, :repository_unavailable}
    end

    test "a repository removed from the installation → error", %{repository: repository} do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)
      Repo.update!(Ecto.Changeset.change(repository, removed_at: DateTime.utc_now(:second)))
      assert GitHub.push_token(repository) == {:error, :repository_unavailable}
    end
  end
end
