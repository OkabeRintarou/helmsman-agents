defmodule HelmsmanDaemon.CredentialsKeychainProtocolTest do
  # Keychain write protocol (add-release-distribution decisions 18 and 19) with
  # an in-memory, fault-injecting keychain; runs on every platform.
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  require Slipstream.Signatures
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  alias HelmsmanDaemon.{Connection, MemoryKeychain}

  @t0 ~U[2026-09-01 00:00:00Z]
  @t1 ~U[2026-10-02 00:00:00Z]

  setup do
    {:ok, kc} = MemoryKeychain.start_link()
    Application.put_env(:helmsman_daemon, :credentials_store, :keychain)
    Application.put_env(:helmsman_daemon, :keychain, {MemoryKeychain, agent: kc})

    on_exit(fn ->
      Application.put_env(:helmsman_daemon, :credentials_store, :file)
      Application.delete_env(:helmsman_daemon, :keychain)
    end)

    old = %{credentials() | token: "hmd_old_generation", issued_at: @t0}
    new = %{old | token: "hmd_new_generation", issued_at: @t1}
    %{kc: kc, old: old, new: new}
  end

  defp file, do: Paths.credentials() |> File.read!() |> Jason.decode!()

  defp account(%{"server_url" => url, "daemon_id" => id, "ref" => ref}), do: "#{url} #{id} #{ref}"
  defp account(_), do: nil

  defp committed_account,
    do:
      account(%{
        "server_url" => file()["server_url"],
        "daemon_id" => file()["daemon_id"],
        "ref" => file()["token_ref"]
      })

  defp pending_account, do: account(file()["pending"])

  defp referenced do
    f = file()
    stale = Enum.map(f["stale_refs"] || [], &account/1)
    Enum.reject([committed_account(), account(f["pending"]) | stale], &is_nil/1)
  end

  # Every keychain item is referenced by the file; the file never holds a token.
  defp assert_invariant(kc) do
    if File.exists?(Paths.credentials()) do
      for account <- Map.keys(MemoryKeychain.items(kc)), do: assert(account in referenced())
      refute File.read!(Paths.credentials()) =~ "hmd_"
    else
      assert MemoryKeychain.items(kc) == %{}
    end
  end

  defp assert_committed(credentials) do
    assert {:ok, read} = Credentials.read()
    assert read.token == credentials.token
    assert read.issued_at == credentials.issued_at
    assert read.daemon_id == credentials.daemon_id
    assert file()["issued_at"] == DateTime.to_iso8601(credentials.issued_at)
    assert MemoryKeychain.items(kc()) |> Map.get(committed_account()) == credentials.token
  end

  defp kc,
    do: Application.get_env(:helmsman_daemon, :keychain) |> elem(1) |> Keyword.fetch!(:agent)

  defp fail_write(event),
    do: [hook: &if(&1 == {:write, event}, do: {:error, :write_failed}, else: :ok)]

  defp crash_after(step), do: [hook: &if(&1 == {:after, step}, do: throw(:crash), else: :ok)]

  defp new_item?(account, old_accounts), do: account not in old_accounts

  defp paused_operation(action) do
    owner = self()

    task =
      Task.async(fn ->
        hook = fn
          {:after, 1} ->
            send(owner, {:paused, self()})
            receive do: (:resume -> :ok)

          _ ->
            :ok
        end

        action.(hook)
      end)

    assert_receive {:paused, pid}
    assert pid == task.pid
    task
  end

  setup %{old: old} = context do
    assert :ok = Credentials.write(old)
    Map.put(context, :old_accounts, Map.keys(MemoryKeychain.items(context.kc)))
  end

  test "a write commits the new generation and deletes the old one", %{kc: kc, old: old, new: new} do
    assert file()["token_store"] == "keychain"
    assert [_] = Map.keys(MemoryKeychain.items(kc))
    assert MemoryKeychain.items(kc)[committed_account()] == old.token

    assert :ok = Credentials.write(new)
    assert_committed(new)
    assert [_] = Map.keys(MemoryKeychain.items(kc))
    assert file()["stale_refs"] == []
    refute Map.has_key?(file(), "pending")
    assert_invariant(kc)
  end

  test "overlapping same-VM writers and recovery retain all generation pointers", %{
    kc: kc,
    new: new
  } do
    writing = paused_operation(fn hook -> Credentials.write(new, hook: hook) end)
    newer = %{new | token: "hmd_newer_generation", issued_at: DateTime.add(new.issued_at, 1)}
    waiting = Task.async(fn -> Credentials.write(newer) end)
    recovering = Task.async(fn -> Credentials.read() end)
    assert Task.yield(waiting, 100) == nil
    assert Task.yield(recovering, 100) == nil
    send(writing.pid, :resume)
    assert Task.await(writing) == :ok
    assert Task.await(waiting) == :ok
    assert {:ok, _} = Task.await(recovering)
    assert_committed(newer)
    assert_invariant(kc)
  end

  test "logout waits for rotation and revokes the generation it then deletes", %{kc: kc, new: new} do
    writing = paused_operation(fn hook -> Credentials.write(new, hook: hook) end)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:revoked, Plug.Conn.get_req_header(conn, HelmsmanProtocol.token_header())})
      Req.Test.json(conn, %{})
    end)

    ExUnit.CaptureIO.capture_io(fn ->
      logout =
        Task.async(fn ->
          HelmsmanDaemon.Login.logout(req_options: [plug: {Req.Test, __MODULE__}])
        end)

      Req.Test.allow(__MODULE__, self(), logout.pid)
      assert Task.yield(logout, 100) == nil
      send(writing.pid, :resume)
      assert Task.await(writing) == :ok
      assert Task.await(logout) == 0
    end)

    assert_received {:revoked, [token]}
    assert token == new.token
    refute File.exists?(Paths.credentials())
    assert_invariant(kc)
  end

  describe "failures at each step leave the old generation committed" do
    test "step 1: writing pending fails", %{kc: kc, old: old, new: new} do
      before = File.read!(Paths.credentials())
      assert {:error, :write_failed} = Credentials.write(new, fail_write(:pending))
      assert File.read!(Paths.credentials()) == before
      assert_committed(old)
      assert_invariant(kc)
    end

    test "step 2: creating the item fails (also when it was created)", %{
      kc: kc,
      old: old,
      new: new,
      old_accounts: old_accounts
    } do
      for result <- [{:error, :interaction_not_allowed}, {:created, {:error, :io}}] do
        MemoryKeychain.fault(kc, :add, result, times: 1)
        assert {:error, {:keychain, _}} = Credentials.write(new)
        refute Map.has_key?(file(), "pending")
        assert_committed(old)
        assert Map.keys(MemoryKeychain.items(kc)) == old_accounts
        assert_invariant(kc)
      end
    end

    test "step 2: created but reading it back fails or differs", %{
      kc: kc,
      old: old,
      new: new,
      old_accounts: old_accounts
    } do
      for result <- [{:error, :locked}, {:error, :not_found}, {:ok, "hmd_something_else"}] do
        MemoryKeychain.fault(kc, :find, result, when: &new_item?(&1, old_accounts), times: 1)
        assert {:error, {:keychain, _}} = Credentials.write(new)
        refute Map.has_key?(file(), "pending")
        assert Map.keys(MemoryKeychain.items(kc)) == old_accounts
        assert_committed(old)
        assert_invariant(kc)
      end
    end

    test "step 2: read back and delete both fail: pending stays for recovery", %{
      kc: kc,
      new: new,
      old_accounts: old_accounts
    } do
      MemoryKeychain.fault(kc, :find, {:error, :locked},
        when: &new_item?(&1, old_accounts),
        times: 1
      )

      MemoryKeychain.fault(kc, :delete, {:error, :locked},
        when: &new_item?(&1, old_accounts),
        times: 1
      )

      assert {:error, {:keychain, :locked}} = Credentials.write(new)
      assert MemoryKeychain.items(kc)[pending_account()] == new.token
      assert_invariant(kc)

      # The server issued this token: the next start promotes it.
      assert_committed(new)
      assert_invariant(kc)
    end

    test "step 3: the commit fails; a retry goes straight to the commit", %{
      kc: kc,
      old: old,
      new: new
    } do
      assert {:error, :write_failed} = Credentials.write(new, fail_write(:commit))
      assert file()["pending"]
      pending = pending_account()
      assert MemoryKeychain.items(kc)[pending] == new.token
      assert file()["issued_at"] == DateTime.to_iso8601(old.issued_at)
      assert MemoryKeychain.items(kc)[committed_account()] == old.token
      assert_invariant(kc)

      adds = Enum.count(MemoryKeychain.log(kc), &match?({:add, _}, &1))
      assert :ok = Credentials.write(new)
      assert Enum.count(MemoryKeychain.log(kc), &match?({:add, _}, &1)) == adds
      assert committed_account() == pending
      assert_committed(new)
      assert_invariant(kc)
    end

    test "step 4: deleting the old item fails; it stays referenced until a later cleanup", %{
      kc: kc,
      new: new,
      old_accounts: [old_account]
    } do
      MemoryKeychain.fault(kc, :delete, {:error, :locked}, when: &(&1 == old_account))
      log = capture_log(fn -> assert :ok = Credentials.write(new) end)
      assert log =~ "old keychain item"
      assert Map.has_key?(MemoryKeychain.items(kc), old_account)
      assert [%{"ref" => _}] = file()["stale_refs"]
      assert_invariant(kc)

      MemoryKeychain.clear_faults(kc)
      assert_committed(new)
      refute Map.has_key?(MemoryKeychain.items(kc), old_account)
      assert file()["stale_refs"] == []
    end
  end

  describe "crash between two steps, then a restart (Credentials.read/0)" do
    test "after step 1: back to the committed old generation", %{kc: kc, old: old, new: new} do
      assert catch_throw(Credentials.write(new, crash_after(1))) == :crash
      assert file()["pending"]
      assert_invariant(kc)
      assert_committed(old)
      refute Map.has_key?(file(), "pending")
      assert_invariant(kc)
    end

    test "after step 2: the new generation is promoted", %{kc: kc, new: new} do
      assert catch_throw(Credentials.write(new, crash_after(2))) == :crash
      assert_invariant(kc)
      assert_committed(new)
      assert [_] = Map.keys(MemoryKeychain.items(kc))
      refute Map.has_key?(file(), "pending")
    end

    test "after step 3: the stale generation is cleaned up", %{
      kc: kc,
      new: new,
      old_accounts: [old_account]
    } do
      assert catch_throw(Credentials.write(new, crash_after(3))) == :crash
      assert Map.has_key?(MemoryKeychain.items(kc), old_account)
      assert_invariant(kc)
      assert_committed(new)
      refute Map.has_key?(MemoryKeychain.items(kc), old_account)
    end
  end

  describe "a pending generation that cannot be read is never deleted" do
    for delete_would <- [:succeed, :fail] do
      test "restart while locked (delete would #{delete_would}), then unlocked", %{
        kc: kc,
        new: new
      } do
        assert catch_throw(Credentials.write(new, crash_after(2))) == :crash
        pending = pending_account()
        before = File.read!(Paths.credentials())

        if unquote(delete_would) == :fail,
          do: MemoryKeychain.fault(kc, :delete, {:error, :locked})

        MemoryKeychain.fault(kc, :find, {:error, :locked}, when: &(&1 == pending))
        assert {:error, {:keychain, :locked}} = Credentials.read()
        assert File.read!(Paths.credentials()) == before
        assert MemoryKeychain.items(kc)[pending] == new.token
        refute Enum.any?(MemoryKeychain.log(kc), &match?({:delete, _}, &1))

        # Two days later (the old token's grace has passed) the keychain is unlocked.
        MemoryKeychain.clear_faults(kc)
        assert_committed(new)
        assert_invariant(kc)
      end

      test "a step 1 retry meets an unreadable pending item (delete would #{delete_would})", %{
        kc: kc,
        new: new
      } do
        assert {:error, :write_failed} = Credentials.write(new, fail_write(:commit))
        pending = pending_account()
        before = File.read!(Paths.credentials())

        if unquote(delete_would) == :fail,
          do: MemoryKeychain.fault(kc, :delete, {:error, :locked})

        MemoryKeychain.fault(kc, :find, {:error, :interaction_not_allowed},
          when: &(&1 == pending)
        )

        assert {:error, {:keychain, :interaction_not_allowed}} = Credentials.write(new)
        assert File.read!(Paths.credentials()) == before
        assert MemoryKeychain.items(kc)[pending] == new.token
        refute Enum.any?(MemoryKeychain.log(kc), &match?({:delete, _}, &1))
      end
    end
  end

  test "a pending item that holds another token is replaced", %{kc: kc, new: new} do
    assert {:error, :write_failed} =
             Credentials.write(%{new | token: "hmd_abandoned"}, fail_write(:commit))

    abandoned = pending_account()
    assert :ok = Credentials.write(new)
    refute Map.has_key?(MemoryKeychain.items(kc), abandoned)
    assert_committed(new)
    assert_invariant(kc)
  end

  test "a missing pending item is dropped at startup", %{kc: kc, old: old, new: new} do
    assert catch_throw(Credentials.write(new, crash_after(2))) == :crash
    Agent.update(kc, fn state -> %{state | items: Map.delete(state.items, pending_account())} end)
    assert_committed(old)
    refute Map.has_key?(file(), "pending")
  end

  test "login --force for another daemon id deletes the previous generation", %{kc: kc, new: new} do
    other = %{new | daemon_id: 77, server_url: "https://other.example.test"}
    assert :ok = Credentials.write(other)
    assert_committed(other)
    assert [account] = Map.keys(MemoryKeychain.items(kc))
    assert account =~ "https://other.example.test 77 "
  end

  test "migration moves a plaintext token into the keychain", %{kc: kc, old: old} do
    File.rm!(Paths.credentials())
    Agent.update(kc, &%{&1 | items: %{}})
    assert :ok = Credentials.write(old, store: :file)
    assert File.read!(Paths.credentials()) =~ old.token

    assert {:ok, %{token: token}} = Credentials.read()
    assert token == old.token
    refute File.read!(Paths.credentials()) =~ "hmd_"
    assert_committed(old)
    assert_invariant(kc)
  end

  test "a failed migration keeps the plaintext token and retries later", %{kc: kc, old: old} do
    File.rm!(Paths.credentials())
    Agent.update(kc, &%{&1 | items: %{}})
    assert :ok = Credentials.write(old, store: :file)
    MemoryKeychain.fault(kc, :add, {:error, :locked}, times: 1)

    log = capture_log(fn -> send(self(), {:read, Credentials.read()}) end)
    assert_received {:read, {:ok, %{token: token}}}
    assert token == old.token
    assert log =~ "keeping it in the credentials file"
    refute log =~ old.token
    assert File.read!(Paths.credentials()) =~ old.token
    assert MemoryKeychain.items(kc) == %{}

    assert {:ok, _} = Credentials.read()
    refute File.read!(Paths.credentials()) =~ "hmd_"
    assert_committed(old)
  end

  test "logout deletes every referenced item; missing items are fine", %{kc: kc, new: new} do
    MemoryKeychain.fault(kc, :delete, {:error, :locked}, times: 1)
    capture_log(fn -> assert :ok = Credentials.write(new) end)

    assert {:error, :write_failed} =
             Credentials.write(%{new | token: "hmd_third"}, fail_write(:commit))

    assert length(referenced()) == 3
    Agent.update(kc, fn state -> %{state | items: Map.delete(state.items, pending_account())} end)

    assert :ok = Credentials.delete()
    refute File.exists?(Paths.credentials())
    assert MemoryKeychain.items(kc) == %{}
  end

  test "logout keeps pointers to items it could not delete", %{kc: kc} do
    MemoryKeychain.fault(kc, :delete, {:error, :locked})
    assert {:error, :keychain} = Credentials.delete()
    assert [_] = file()["stale_refs"]
    refute Credentials.logged_in?()
    assert_invariant(kc)
  end

  test "tokens never reach the logs", %{kc: kc, new: new} do
    log =
      capture_log(fn ->
        MemoryKeychain.fault(kc, :delete, {:error, :locked})
        Credentials.write(new)
        Credentials.read()
        Credentials.delete()
      end)

    refute log =~ "hmd_"
  end

  describe "Connection" do
    setup do
      start_execution()
      :ok
    end

    defp start_connection(opts) do
      start_supervised!(
        {Connection,
         Keyword.merge(
           [
             test_mode?: true,
             stop: fn code -> raise "unexpected daemon exit #{code}" end,
             heartbeat_interval_ms: 100_000,
             rotation_interval_ms: 100_000
           ],
           opts
         )}
      )
    end

    defp join(client) do
      accept_connect(client)

      assert_join(
        "daemon:1",
        _,
        {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
        1_000
      )

      assert_push("daemon:1", "claim", %{}, ref, 1_000)
      reply(client, ref, {:ok, %{"runs" => []}})
    end

    test "recovery after a crash before the commit connects with the new token, no rotate_token",
         %{old: old} do
      due = %{old | issued_at: DateTime.add(DateTime.utc_now(), -31 * 86_400)}
      assert :ok = Credentials.write(due)

      fresh = %{
        due
        | token: "hmd_rotated_by_server",
          issued_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      assert catch_throw(Credentials.write(fresh, crash_after(2))) == :crash

      client = start_connection([])

      assert :sys.get_state(client).channel_config.headers == [
               {HelmsmanProtocol.token_header(), "hmd_rotated_by_server"}
             ]

      join(client)
      send(client, :rotation_check_now)
      refute_push("daemon:1", "rotate_token", _, 200)
      assert {:ok, %{token: "hmd_rotated_by_server"}} = Credentials.read()
    end

    test "a keychain failure while saving a rotated token keeps the old file, uses the new token and retries without rotating again",
         %{kc: kc, old: old} do
      due = %{old | issued_at: DateTime.add(DateTime.utc_now(), -31 * 86_400)}
      assert :ok = Credentials.write(due)
      before = File.read!(Paths.credentials())
      [old_account] = Map.keys(MemoryKeychain.items(kc))
      MemoryKeychain.fault(kc, :find, {:error, :locked}, when: &(&1 != old_account), times: 1)

      client = start_connection(rotation_interval_ms: 50, reconnect_after_ms: [10])
      join(client)
      assert_push("daemon:1", "rotate_token", %{}, ref, 1_000)

      capture_log(fn ->
        reply(client, ref, {:ok, %{"token" => "hmd_rotated_by_server"}})
        eventually(fn -> :sys.get_state(client).assigns.dirty_credentials? end)
      end)

      assert File.read!(Paths.credentials()) == before
      assert Map.keys(MemoryKeychain.items(kc)) == [old_account]
      assert_invariant(kc)

      send(client, Slipstream.Signatures.event(%Slipstream.Events.ChannelClosed{reason: :closed}))

      eventually(fn ->
        :sys.get_state(client).channel_config.headers == [
          {HelmsmanProtocol.token_header(), "hmd_rotated_by_server"}
        ]
      end)

      join(client)
      eventually(fn -> match?({:ok, %{token: "hmd_rotated_by_server"}}, Credentials.read()) end)
      refute_push("daemon:1", "rotate_token", _, 100)
      assert_invariant(kc)
    end
  end
end
