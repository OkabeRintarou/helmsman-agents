defmodule Helmsman.AgentsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures
  import ExUnit.CaptureLog
  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Events}
  alias Helmsman.Agents.AgentProfile

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    other = user_fixture()
    member_fixture(workspace, other, :admin)
    %{scope: scope, admin: workspace_scope_fixture(other, workspace), workspace: workspace}
  end

  for field <- [:instructions, :description, :custom_args, :capabilities] do
    test "null #{field} returns a scrubbed field error on create and update", ctx do
      field = unquote(field)
      :ok = Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
      attrs = %{name: "null-agent", provider: "claude", env: %{"KEY" => "submitted-secret"}}

      assert {:error, cs} = Agents.create(ctx.scope, Map.put(attrs, field, nil))
      assert cs.errors[field]
      refute contains_secret?(cs, "submitted-secret")
      assert Repo.aggregate(AgentProfile, :count) == 0
      refute_receive {:agents_changed}

      agent = managed_agent_fixture(ctx.scope, %{env: %{"KEY" => "stored-secret"}})
      assert_receive {:agents_changed}
      before = Repo.one!(AgentProfile)

      assert {:error, cs} =
               Agents.update(
                 ctx.scope,
                 agent.name,
                 Map.put(%{env: %{"NEW" => "submitted-secret"}}, field, nil)
               )

      assert cs.errors[field]
      refute contains_secret?(cs, "stored-secret")
      refute contains_secret?(cs, "submitted-secret")
      after_profile = Repo.one!(AgentProfile)
      assert Map.get(after_profile, field) == Map.get(before, field)
      assert after_profile.env == before.env
      refute_receive {:agents_changed}
    end
  end

  test "internal execution config returns redacted decrypted profile and rechecks actor state",
       ctx do
    agent =
      managed_agent_fixture(ctx.scope, %{
        env: %{"KEY" => "execution-secret"},
        extra_mcp_servers: %{"private" => %{"token" => "mcp-secret"}},
        instructions: "Execute this",
        custom_args: ["--verbose"]
      })

    actor = Repo.get_by!(Actor, workspace_id: ctx.workspace.id, name: agent.name)
    assert {:ok, %AgentProfile{} = config} = Agents.execution_config(actor.id)
    assert config.env == %{"KEY" => "execution-secret"}
    assert config.extra_mcp_servers == %{"private" => %{"token" => "mcp-secret"}}
    assert config.instructions == "Execute this"
    assert config.custom_args == ["--verbose"]
    assert config.runtime_id

    assert {config.max_concurrency, config.timeout_minutes, config.idle_timeout_minutes} ==
             {2, 120, 20}

    refute inspect(config) =~ "execution-secret"
    refute inspect(config) =~ "mcp-secret"
    assert {:ok, public} = Agents.get(ctx.scope, agent.name)
    refute contains_secret?(public, "execution-secret")
    refute contains_secret?(public, "mcp-secret")
    assert {:error, :not_found} = Agents.execution_config(actor.id + 1_000_000)
    assert {:error, :not_managed} = Agents.execution_config(ctx.scope.actor)

    external =
      %Actor{workspace_id: ctx.workspace.id, kind: :agent, owner_id: ctx.scope.user.id}
      |> Actor.create_changeset(%{name: "external/execution"})
      |> Repo.insert!()

    assert {:error, :not_managed} = Agents.execution_config(external)
    assert {:ok, _} = Agents.disable(ctx.scope, agent.name)
    assert {:error, :agent_disabled} = Agents.execution_config(actor)
    assert {:ok, _} = Agents.archive(ctx.scope, agent.name)
    assert {:error, :agent_archived} = Agents.execution_config(actor)
  end

  test "atomic creation, viewer and agent restrictions, name collision", ctx do
    assert {:ok, agent} = Agents.create(ctx.scope, %{name: "keel/dev", provider: "claude"})

    assert %{kind: "managed", access: "owner_only", max_concurrency: 2, timeout_minutes: 120} =
             agent

    assert {:error, cs} =
             Agents.create(ctx.scope, %{
               name: "keel/dev",
               provider: "claude",
               env: %{"A" => "creation-secret"}
             })

    assert cs.errors[:name]
    refute contains_secret?(cs, "creation-secret")
    assert Repo.aggregate(AgentProfile, :count) == 1
    viewer = user_fixture()
    member_fixture(ctx.workspace, viewer, :viewer)

    assert {:error, :forbidden} =
             Agents.create(workspace_scope_fixture(viewer, ctx.workspace), %{
               name: "new",
               provider: "claude"
             })

    actor = Repo.one!(from a in Actor, where: a.name == "keel/dev")

    assert {:error, :forbidden} =
             Agents.create(%{ctx.scope | actor: actor}, %{name: "new", provider: "claude"})
  end

  test "sensitive values encrypted; reads expose only names; env is a patch", ctx do
    agent =
      managed_agent_fixture(ctx.scope, %{
        env: %{"A" => "stored-secret", "B" => "delete-me"},
        extra_mcp_servers: %{"tool" => %{"key" => "mcp-secret"}}
      })

    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
    assert {:ok, view} = Agents.get(ctx.scope, agent.name)
    assert view.env_names == ["A", "B"]
    assert view.extra_mcp_server_names == ["tool"]
    refute contains_secret?(view, "stored-secret")
    profile = Repo.one!(AgentProfile)
    refute inspect(profile) =~ "stored-secret"

    %{rows: [[encrypted]]} =
      Repo.query!("SELECT env FROM agent_profiles WHERE id=$1", [profile.id])

    refute :binary.match(encrypted, "stored-secret") != :nomatch

    assert Repo.get!(AgentProfile, profile.id).env == %{
             "A" => "stored-secret",
             "B" => "delete-me"
           }

    assert {:ok, _} =
             Agents.update(ctx.scope, agent.name, %{
               env: %{"B" => nil, "C" => "new-secret"},
               extra_mcp_servers: %{"replacement" => %{}}
             })

    assert_receive {:agents_changed}

    assert Repo.get!(AgentProfile, profile.id).env == %{
             "A" => "stored-secret",
             "C" => "new-secret"
           }

    assert Repo.get!(AgentProfile, profile.id).extra_mcp_servers == %{"replacement" => %{}}
    assert {:ok, _} = Agents.update(ctx.scope, agent.name, %{extra_mcp_servers: nil})
    assert Repo.get!(AgentProfile, profile.id).extra_mcp_servers == nil
  end

  test "failed admin and owner updates scrub entire error structure and logs", ctx do
    agent =
      managed_agent_fixture(ctx.scope, %{
        env: %{"A" => "stored-secret"},
        extra_mcp_servers: %{"tool" => %{"key" => "mcp-secret"}}
      })

    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

    log =
      capture_log(fn ->
        for {scope, attrs} <- [
              {ctx.admin, %{max_concurrency: 99}},
              {ctx.scope, %{env: %{"NEW" => "new-secret", "HELMSMAN_X" => "illegal-secret"}}}
            ] do
          assert {:error, cs} = Agents.update(scope, agent.name, attrs)

          for secret <- ["stored-secret", "mcp-secret", "new-secret", "illegal-secret"] do
            refute contains_secret?(cs, secret)
            refute inspect(cs) =~ secret
          end
        end
      end)

    refute log =~ "secret"
    refute_receive {:agents_changed}
    assert Repo.one!(AgentProfile).env == %{"A" => "stored-secret"}
    attrs = %{env: Map.new(1..64, &{"B#{&1}", "secret"})}
    assert {:error, cs} = Agents.update(ctx.scope, agent.name, attrs)
    assert cs.errors[:env]
    refute contains_secret?(cs, "stored-secret")
  end

  test "admin has only administrative fields, archive is terminal", ctx do
    agent = managed_agent_fixture(ctx.scope)

    assert {:error, :forbidden} =
             Agents.update(ctx.admin, agent.name, %{description: "changed", model: "opus"})

    assert {:error, :forbidden} = Agents.update(ctx.admin, agent.name, %{instructions: "changed"})
    assert {:ok, updated} = Agents.update(ctx.admin, agent.name, %{max_concurrency: 4})
    assert updated.max_concurrency == 4
    assert updated.description == ""
    assert {:ok, _} = Agents.disable(ctx.admin, agent.name)
    assert {:error, :forbidden} = Agents.enable(ctx.admin, agent.name)
    assert {:ok, _} = Agents.enable(ctx.scope, agent.name)
    assert {:ok, archived} = Agents.archive(ctx.admin, agent.name)
    assert archived.archived and archived.disabled
    assert {:error, :agent_archived} = Agents.update(ctx.scope, agent.name, %{description: "new"})
    assert {:error, :agent_archived} = Agents.enable(ctx.scope, agent.name)
  end

  test "external agents appear in list and support disable/enable", ctx do
    external =
      Repo.insert!(
        Actor.create_changeset(
          %Actor{workspace_id: ctx.workspace.id, kind: :agent, owner_id: ctx.scope.user.id},
          %{name: "external"}
        )
      )

    managed_agent_fixture(ctx.scope)
    assert {:ok, entries} = Agents.list(%{ctx.scope | role: :viewer})
    assert length(entries) == 2
    assert Enum.any?(entries, &(&1.kind == "external"))
    assert {:ok, _} = Agents.disable(ctx.scope, external.name)
    assert {:ok, _} = Agents.enable(ctx.scope, external.name)
    assert {:error, :not_managed} = Agents.archive(ctx.scope, external.name)
  end

  test "binding only own workspace, enabled provider and supported model/effort", ctx do
    {daemon, _} = daemon_fixture(ctx.scope.user)

    runtime =
      runtime_fixture(ctx.workspace, daemon, %{models: ["sonnet", "opus"], efforts: ["high"]})

    {other_daemon, _} = daemon_fixture(ctx.admin.user)
    others = runtime_fixture(ctx.workspace, other_daemon)

    disabled =
      runtime_fixture(ctx.workspace, daemon, %{
        provider: "codex",
        disabled_at: DateTime.utc_now(:second)
      })

    agent =
      managed_agent_fixture(ctx.scope, %{runtime_id: runtime.id, model: "sonnet", effort: "high"})

    for attrs <- [
          %{runtime_id: others.id},
          %{provider: "codex"},
          %{runtime_id: disabled.id, provider: "codex"},
          %{model: "unknown"},
          %{effort: "unknown"}
        ] do
      assert {:error, _} = Agents.update(ctx.scope, agent.name, attrs)
    end

    assert {:ok, _} =
             Agents.update(ctx.scope, agent.name, %{
               runtime_id: nil,
               model: "anything",
               effort: "anything"
             })
  end

  test "owner cannot bind other users or cross-workspace runtimes", ctx do
    {daemon, _} = daemon_fixture(ctx.scope.user)
    foreign = workspace_fixture(ctx.scope.user)
    foreign_runtime = runtime_fixture(foreign, daemon)
    agent = managed_agent_fixture(ctx.scope)
    assert {:error, cs} = Agents.update(ctx.scope, agent.name, %{runtime_id: foreign_runtime.id})
    assert cs.errors[:runtime_id]
    {other_daemon, _} = daemon_fixture(ctx.admin.user)
    other_runtime = runtime_fixture(ctx.workspace, other_daemon)
    assert {:error, cs} = Agents.update(ctx.scope, agent.name, %{runtime_id: other_runtime.id})
    assert cs.errors[:runtime_id]
  end

  defp contains_secret?(value, secret) when is_binary(value), do: String.contains?(value, secret)

  defp contains_secret?(value, secret) when is_map(value),
    do:
      Enum.any?(Map.to_list(value), fn {k, v} ->
        contains_secret?(k, secret) or contains_secret?(v, secret)
      end)

  defp contains_secret?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_secret?(&1, secret))

  defp contains_secret?(value, secret) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_secret?(secret)

  defp contains_secret?(_, _), do: false
end
