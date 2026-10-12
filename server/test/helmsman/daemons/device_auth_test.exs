defmodule Helmsman.Daemons.DeviceAuthTest do
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Daemons
  alias Helmsman.Daemons.DeviceCode
  alias Helmsman.Workspaces.Membership
  alias HelmsmanProtocol.DeviceAuth.CodeRequest
  alias HelmsmanProtocol.{Machine, Report}

  describe "device authorization" do
    test "normalizes the user code, approves a workspace, and issues a one-time token" do
      user = user_fixture()
      workspace = workspace_fixture(user)
      scope = user_scope_fixture(user)
      request = code_request("machine-login", "Build host")

      assert {:ok, code} = Daemons.start_device_auth(request)
      assert code.expires_in == 600
      assert code.interval == 5
      assert {:pending, :authorization_pending} = Daemons.exchange_device_code(code.device_code)

      assert {:ok, details} =
               Daemons.get_device_auth(scope, lowercase_without_hyphen(code.user_code))

      assert details.user_code == code.user_code
      assert details.machine["machine_id"] == "machine-login"
      assert details.machine["name"] == "Build host"

      assert {:ok, _} =
               Daemons.approve_device(scope, lowercase_without_hyphen(code.user_code), [
                 workspace.id
               ])

      assert {:ok, response} = Daemons.exchange_device_code(code.device_code)
      assert response.token =~ ~r/^hmd_[a-z2-7]{52}$/
      assert response.daemon_id > 0
      assert [%{id: id, slug: slug}] = response.workspaces
      assert id == workspace.id
      assert slug == workspace.slug
      stored = Repo.get_by!(DeviceCode, user_code: code.user_code)
      daemon = Repo.get!(Helmsman.Daemons.Daemon, response.daemon_id)
      assert stored.status == "used"
      assert stored.device_code_hash == Daemons.hash(code.device_code)
      assert stored.device_code_hash != code.device_code
      assert daemon.token_hash == Daemons.hash(response.token)
      assert daemon.token_hash != response.token

      assert {:error, :expired_token} = Daemons.exchange_device_code(code.device_code)
      assert Repo.get_by!(DeviceCode, user_code: code.user_code).status == "expired"
    end

    test "slows polling inside the interval and increases the next interval" do
      request = code_request("machine-slow-poll", "Slow poll host")

      assert {:ok, code} = Daemons.start_device_auth(request)
      assert {:pending, :authorization_pending} = Daemons.exchange_device_code(code.device_code)
      assert {:pending, :slow_down} = Daemons.exchange_device_code(code.device_code)

      stored = Repo.get_by!(DeviceCode, user_code: code.user_code)
      assert stored.interval == 10
      assert stored.last_polled_at
    end

    test "does not approve a workspace where the user is only a viewer" do
      owner = user_fixture()
      user = user_fixture()
      workspace = workspace_fixture(owner)
      member_fixture(workspace, user, :viewer)
      scope = user_scope_fixture(user)

      assert {:ok, code} =
               Daemons.start_device_auth(code_request("machine-viewer", "Viewer host"))

      assert {:error, {:invalid_workspaces, invalid_ids}} =
               Daemons.approve_device(scope, code.user_code, [workspace.id])

      assert invalid_ids == [workspace.id]

      assert {:pending, :authorization_pending} = Daemons.exchange_device_code(code.device_code)
      assert Repo.get_by!(DeviceCode, user_code: code.user_code).status == "pending"
    end

    test "expires an expired code and returns expired_token" do
      assert {:ok, code} =
               Daemons.start_device_auth(code_request("machine-expired", "Expired host"))

      Repo.update_all(
        from(c in DeviceCode, where: c.user_code == ^code.user_code),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert {:error, :expired_token} = Daemons.exchange_device_code(code.device_code)
      stored = Repo.get_by!(DeviceCode, user_code: code.user_code)
      assert stored.status == "expired"
      assert stored.last_polled_at
    end

    test "initial daemon names trim empty hostnames and truncate long hostnames" do
      user = user_fixture()
      workspace = workspace_fixture(user)
      scope = user_scope_fixture(user)
      long_name = String.duplicate("x", 70)

      for {suffix, host_name, expected_name} <- [
            {"empty", "  \t  ", "daemon"},
            {"long", long_name, String.slice(long_name, 0, 64)}
          ] do
        response =
          authorize(
            scope,
            code_request(
              "machine-name-#{suffix}-#{System.unique_integer([:positive])}",
              host_name
            ),
            [workspace.id]
          )

        assert Repo.get!(Helmsman.Daemons.Daemon, response.daemon_id).name == expected_name
      end
    end

    test "rejects workspace ids outside the advisory-lock id range without raising" do
      user = user_fixture()
      workspace_fixture(user)
      scope = user_scope_fixture(user)

      for invalid_id <- [-1, Integer.pow(2, 48)] do
        assert {:ok, code} =
                 Daemons.start_device_auth(
                   code_request("machine-invalid-workspace-#{invalid_id}", "Invalid id host")
                 )

        assert {:error, {:invalid_workspaces, [^invalid_id]}} =
                 Daemons.approve_device(scope, code.user_code, [invalid_id])

        assert Repo.get_by!(DeviceCode, user_code: code.user_code).status == "pending"
      end
    end

    test "denial returns access_denied" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      assert {:ok, code} =
               Daemons.start_device_auth(code_request("machine-denied", "Denied host"))

      assert {:ok, _} = Daemons.deny_device(scope, code.user_code)
      assert {:error, :access_denied} = Daemons.exchange_device_code(code.device_code)
      assert Repo.get_by!(DeviceCode, user_code: code.user_code).status == "denied"
    end

    test "drops a workspace that becomes viewer-only after approval" do
      user = user_fixture()
      workspace = workspace_fixture(user)
      scope = user_scope_fixture(user)

      assert {:ok, code} =
               Daemons.start_device_auth(code_request("machine-demoted", "Demoted host"))

      assert {:ok, _} = Daemons.approve_device(scope, code.user_code, [workspace.id])

      Repo.update_all(
        from(m in Membership, where: m.workspace_id == ^workspace.id and m.user_id == ^user.id),
        set: [role: :viewer]
      )

      assert {:ok, response} = Daemons.exchange_device_code(code.device_code)
      assert response.workspaces == []

      refute Repo.exists?(
               from(dw in Helmsman.Daemons.DaemonWorkspace,
                 where: dw.daemon_id == ^response.daemon_id and dw.workspace_id == ^workspace.id
               )
             )
    end

    test "reuses a daemon for the same machine and rejects writes from its previous epoch" do
      user = user_fixture()
      workspace = workspace_fixture(user)
      scope = user_scope_fixture(user)
      machine_id = "machine-relogin-#{System.unique_integer([:positive])}"

      first = authorize(scope, code_request(machine_id, "Original name"), [workspace.id])
      first_daemon = Repo.get!(Helmsman.Daemons.Daemon, first.daemon_id)
      first_epoch = first_daemon.auth_epoch
      first_runtime = Helmsman.AgentsFixtures.runtime_fixture(workspace, first_daemon)
      original_last_seen = first_daemon.last_seen_at

      second = authorize(scope, code_request(machine_id, "Replacement name"), [workspace.id])
      second_daemon = Repo.get!(Helmsman.Daemons.Daemon, second.daemon_id)

      assert second.daemon_id == first.daemon_id
      assert second_daemon.name == "Original name"
      assert second_daemon.auth_epoch == first_epoch + 1
      assert second_daemon.token_hash == Daemons.hash(second.token)
      assert {:error, :unauthorized} = Daemons.authenticate(first.token)
      assert {:ok, ^second_daemon} = Daemons.authenticate(second.token)

      report = join_report()
      assert {:error, :reauthorized} = Daemons.register(first.daemon_id, first_epoch, report)
      assert {:error, :reauthorized} = Daemons.rotate_token(first.daemon_id, first_epoch)

      after_stale_writes = Repo.get!(Helmsman.Daemons.Daemon, first.daemon_id)
      assert after_stale_writes.auth_epoch == first_epoch + 1
      assert after_stale_writes.last_seen_at == original_last_seen
      assert Repo.get!(Helmsman.Daemons.Runtime, first_runtime.id).status == "online"
    end

    test "retries a conflicting active user code" do
      {generator, agent} = code_generator(["ABCD-EFGH", "ABCD-EFGH", "JKMN-PQRS"])
      previous = Application.get_env(:helmsman, :daemon_user_code_generator)
      Application.put_env(:helmsman, :daemon_user_code_generator, generator)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:helmsman, :daemon_user_code_generator, previous),
          else: Application.delete_env(:helmsman, :daemon_user_code_generator)

        Agent.stop(agent)
      end)

      assert {:ok, first} =
               Daemons.start_device_auth(code_request("machine-code-a", "First host"))

      assert first.user_code == "ABCD-EFGH"

      assert {:ok, retried} =
               Daemons.start_device_auth(code_request("machine-code-b", "Second host"))

      assert retried.user_code == "JKMN-PQRS"
      assert Agent.get(agent, & &1) == []

      assert Repo.aggregate(
               from(c in DeviceCode, where: c.status == "pending"),
               :count
             ) == 2
    end

    test "rate limits device approvals per user" do
      user = user_fixture()
      workspace = workspace_fixture(user)
      scope = user_scope_fixture(user)
      {limits, previous} = user_device_limit()
      Application.put_env(:helmsman, Helmsman.RateLimit, limits)

      on_exit(fn -> Application.put_env(:helmsman, Helmsman.RateLimit, previous) end)

      assert {:ok, first} =
               Daemons.start_device_auth(code_request("machine-rate-a", "Rate host A"))

      assert {:ok, second} =
               Daemons.start_device_auth(code_request("machine-rate-b", "Rate host B"))

      assert {:ok, _} = Daemons.approve_device(scope, first.user_code, [workspace.id])

      assert {:error, {:rate_limited, retry_after}} =
               Daemons.approve_device(scope, second.user_code, [workspace.id])

      assert retry_after > 0
      assert Repo.get_by!(DeviceCode, user_code: second.user_code).status == "pending"
    end
  end

  defp code_request(machine_id, name) do
    {:ok, machine} =
      Machine.new(%{
        machine_id: machine_id,
        name: name,
        os: "linux",
        arch: "x86_64",
        daemon_version: "1.2.3"
      })

    {:ok, request} = CodeRequest.new(%{protocol: HelmsmanProtocol.version(), machine: machine})
    request
  end

  defp authorize(scope, request, workspace_ids) do
    assert {:ok, code} = Daemons.start_device_auth(request)
    assert {:ok, _} = Daemons.approve_device(scope, code.user_code, workspace_ids)
    assert {:ok, response} = Daemons.exchange_device_code(code.device_code)
    response
  end

  defp join_report do
    {:ok, machine} =
      Machine.new(%{
        machine_id: "old-epoch-report",
        name: "Old epoch",
        os: "linux",
        arch: "x86_64",
        daemon_version: "1.2.3"
      })

    {:ok, report} =
      Report.Join.new(%{
        protocol: HelmsmanProtocol.version(),
        machine: machine,
        clis: [],
        max_concurrency: 2,
        active_runs: []
      })

    report
  end

  defp lowercase_without_hyphen(code), do: code |> String.replace("-", "") |> String.downcase()

  defp code_generator(codes) do
    {:ok, agent} = Agent.start(fn -> codes end)

    generator = fn ->
      Agent.get_and_update(agent, fn
        [code | rest] -> {code, rest}
        [] -> raise "user code generator exhausted"
      end)
    end

    {generator, agent}
  end

  defp user_device_limit do
    previous = Application.fetch_env!(:helmsman, Helmsman.RateLimit)
    limits = Keyword.put(previous, :daemon_device_user, {1, :timer.minutes(1)})
    {limits, previous}
  end
end
