defmodule Helmsman.Agents.ConstraintsTest do
  # Use raw inserts so these assertions exercise PostgreSQL constraints rather
  # than changeset validation.
  use Helmsman.DataCase, async: true

  setup do
    owner_id = insert!("users", user("owner"))
    workspace_id = insert!("workspaces", workspace("alpha"))
    other_workspace_id = insert!("workspaces", workspace("beta"))

    actor_id =
      insert!("actors", %{
        workspace_id: workspace_id,
        kind: "agent",
        name: "managed-agent",
        owner_id: owner_id
      })

    daemon_id =
      insert!("daemons", %{
        user_id: owner_id,
        machine_id: "machine-#{unique_suffix()}",
        name: "Test daemon",
        token_hash: :crypto.strong_rand_bytes(32)
      })

    runtime_id =
      insert!("runtimes", %{
        workspace_id: workspace_id,
        daemon_id: daemon_id,
        provider: "claude"
      })

    other_runtime_id =
      insert!("runtimes", %{
        workspace_id: other_workspace_id,
        daemon_id: daemon_id,
        provider: "claude"
      })

    %{
      actor_id: actor_id,
      daemon_id: daemon_id,
      owner_id: owner_id,
      other_runtime_id: other_runtime_id,
      other_workspace_id: other_workspace_id,
      runtime_id: runtime_id,
      workspace_id: workspace_id
    }
  end

  defp user(label) do
    suffix = unique_suffix()

    %{
      email: "#{label}-#{suffix}@example.test",
      display_name: label
    }
  end

  defp workspace(label) do
    %{slug: "#{label}-#{unique_suffix()}", name: String.capitalize(label)}
  end

  defp unique_suffix, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp insert!(table, row) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(table, [Map.merge(%{inserted_at: now, updated_at: now}, row)],
        returning: [:id]
      )

    id
  end

  # Isolate each expected database error in a savepoint so the sandbox
  # transaction remains usable for the rest of the test.
  defp rejected(table, row) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> insert!(table, row) end)
      end

    error.postgres.constraint
  end

  defp profile(ctx, attrs) do
    Map.merge(
      %{
        workspace_id: ctx.workspace_id,
        actor_id: ctx.actor_id,
        provider: "claude",
        runtime_id: ctx.runtime_id
      },
      attrs
    )
  end

  defp runtime(ctx, attrs) do
    Map.merge(
      %{workspace_id: ctx.workspace_id, daemon_id: ctx.daemon_id, provider: "codex"},
      attrs
    )
  end

  describe "agent_profiles" do
    test "rejects an unknown provider and access value", ctx do
      assert rejected("agent_profiles", profile(ctx, %{provider: "unknown"})) ==
               "agent_profiles_provider_check"

      assert rejected("agent_profiles", profile(ctx, %{access: "everyone"})) ==
               "agent_profiles_access_check"
    end

    test "rejects unsupported capabilities", ctx do
      assert rejected("agent_profiles", profile(ctx, %{capabilities: ["delegate"]})) ==
               "agent_profiles_capabilities_check"
    end

    test "rejects idle timeouts greater than the overall timeout", ctx do
      assert rejected(
               "agent_profiles",
               profile(ctx, %{timeout_minutes: 30, idle_timeout_minutes: 31})
             ) ==
               "agent_profiles_idle_timeout_minutes_check"
    end

    test "rejects an overall timeout above 1200 minutes", ctx do
      assert rejected("agent_profiles", profile(ctx, %{timeout_minutes: 1201})) ==
               "agent_profiles_timeout_minutes_check"
    end

    test "rejects more than 64 custom arguments", ctx do
      assert rejected(
               "agent_profiles",
               profile(ctx, %{custom_args: List.duplicate("--flag", 65)})
             ) ==
               "agent_profiles_custom_args_check"
    end

    test "rejects a runtime from another workspace", ctx do
      assert rejected("agent_profiles", profile(ctx, %{runtime_id: ctx.other_runtime_id})) ==
               "agent_profiles_runtime_workspace_fkey"
    end

    test "allows only one profile per actor", ctx do
      assert insert!("agent_profiles", profile(ctx, %{}))

      assert rejected("agent_profiles", profile(ctx, %{runtime_id: nil})) ==
               "agent_profiles_actor_id_index"
    end
  end

  describe "runtimes" do
    test "rejects an unknown provider and status", ctx do
      assert rejected("runtimes", runtime(ctx, %{provider: "unknown"})) ==
               "runtimes_provider_check"

      assert rejected("runtimes", runtime(ctx, %{status: "starting"})) ==
               "runtimes_status_check"
    end

    test "allows only one runtime per workspace, daemon, and provider", ctx do
      assert rejected("runtimes", runtime(ctx, %{provider: "claude"})) ==
               "runtimes_workspace_id_daemon_id_provider_index"
    end
  end

  describe "device_codes" do
    test "rejects an unknown status", _ctx do
      assert rejected("device_codes", device_code(%{status: "complete"})) ==
               "device_codes_status_check"
    end

    test "allows only one pending or approved code per user code", _ctx do
      assert insert!("device_codes", device_code(%{user_code: "ABCD-EFGH"}))

      assert rejected("device_codes", device_code(%{user_code: "ABCD-EFGH"})) ==
               "device_codes_active_user_code_index"
    end
  end

  defp device_code(attrs) do
    Map.merge(
      %{
        device_code_hash: :crypto.strong_rand_bytes(32),
        user_code: "#{unique_suffix()}",
        machine: %{"name" => "test-machine"},
        protocol_version: 1,
        expires_at: DateTime.add(DateTime.utc_now(:second), 600)
      },
      attrs
    )
  end
end
