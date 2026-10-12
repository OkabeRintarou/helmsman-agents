defmodule Helmsman.Actors.WithWriterTest do
  # Checks notifications after the outermost commit (tasks 2.3).
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Workspaces.Membership

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    %{api_token: token} = api_token_fixture(workspace_scope_fixture(alice, workspace))

    %{
      owner: owner,
      workspace: workspace,
      alice: alice,
      token: token,
      scope: token_scope_fixture(alice, workspace, :mcp, token),
      human: Actors.get_human(workspace.id, alice.id)
    }
  end

  # A business write that can be found after the call.
  defp probe(name), do: fn scope -> Actors.identify(scope, %{name: name}) end

  defp actor(workspace, name), do: Repo.get_by(Actor, workspace_id: workspace.id, name: name)

  defp session_agents(workspace) do
    Repo.all(
      from(a in Actor, where: a.workspace_id == ^workspace.id and like(a.name, "%/session-%"))
    )
  end

  describe "the four sources" do
    test ":requested", %{scope: scope, workspace: ws, alice: alice} do
      keel = agent_fixture(ws, alice, "keel/dev")

      assert {:ok, %Actor{name: "probe/requested"}, %{actor: %Actor{id: id}, source: :requested}} =
               Actors.with_writer(scope, [requested: "keel/dev"], probe("probe/requested"))

      assert id == keel.id
      assert actor(ws, "probe/requested")
    end

    test ":session", %{scope: scope, workspace: ws, alice: alice} do
      keel = agent_fixture(ws, alice, "keel/dev")

      assert {:ok, _value, %{actor: %Actor{id: id}, source: :session}} =
               Actors.with_writer(scope, [session_actor_id: keel.id], probe("probe/session"))

      assert id == keel.id
      assert actor(ws, "probe/session")
    end

    test ":default", %{scope: scope, workspace: ws, alice: alice} do
      keel = agent_fixture(ws, alice, "keel/dev")
      scope = %{scope | token: %{scope.token | default_agent_id: keel.id}}

      assert {:ok, _value, %{actor: %Actor{id: id}, source: :default}} =
               Actors.with_writer(scope, [], probe("probe/default"))

      assert id == keel.id
      assert actor(ws, "probe/default")
    end

    test ":auto creates the session agent", %{scope: scope, workspace: ws, alice: alice} = ctx do
      assert {:ok, _value, %{actor: auto, source: :auto}} =
               Actors.with_writer(scope, [auto_agent: true], probe("probe/auto"))

      assert auto.name =~ ~r"^#{Regex.escape(ctx.human.name)}/session-[a-z0-9]{6}$"
      assert auto.kind == :agent and auto.owner_id == alice.id
      assert auto.last_seen_at
      assert actor(ws, auto.name)
      assert actor(ws, "probe/auto")
    end

    test "the writer is the actor fun runs as", %{scope: scope} do
      assert {:ok, name, %{actor: auto}} =
               Actors.with_writer(scope, [auto_agent: true], &{:ok, &1.actor.name})

      assert name == auto.name
    end
  end

  describe "failures" do
    test "an error rolls back the write and the session agent", %{scope: scope, workspace: ws} do
      fun = fn scope ->
        {:ok, _} = probe("probe/rollback").(scope)
        {:error, :boom}
      end

      assert Actors.with_writer(scope, [auto_agent: true], fun) == {:error, :boom}
      refute actor(ws, "probe/rollback")
      assert session_agents(ws) == []
    end

    test "any other result raises", %{scope: scope, workspace: ws} do
      assert_raise ArgumentError, ~r/expects the write to return/, fn ->
        Actors.with_writer(scope, [auto_agent: true], fn _scope -> {:ok, 1, 2} end)
      end

      assert session_agents(ws) == []
    end

    test "someone else's agent is forbidden", %{scope: scope, workspace: ws} do
      bob = user_fixture()
      member_fixture(ws, bob, :member)
      agent_fixture(ws, bob, "bob/dev")

      assert Actors.with_writer(scope, [requested: "bob/dev"], probe("probe/x")) ==
               {:error, :forbidden}

      refute actor(ws, "probe/x")
    end

    test "a disabled session identity", %{scope: scope, workspace: ws, alice: alice} do
      keel = agent_fixture(ws, alice, "keel/dev", %{disabled_at: DateTime.utc_now(:second)})

      assert Actors.with_writer(scope, [session_actor_id: keel.id], probe("probe/x")) ==
               {:error, {:agent_disabled, "keel/dev"}}
    end

    test "a viewer may not get a session agent", %{scope: scope, workspace: ws, alice: alice} do
      # Demoted after the token was issued: the current role counts.
      Repo.update_all(
        from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id),
        set: [role: :viewer]
      )

      assert Actors.with_writer(scope, [auto_agent: true], probe("probe/x")) ==
               {:error, :forbidden}

      assert session_agents(ws) == []
    end

    test "a removed user", %{scope: scope, workspace: ws, alice: alice} do
      Repo.delete_all(
        from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id)
      )

      assert Actors.with_writer(scope, [auto_agent: true], probe("probe/x")) ==
               {:error, :not_found}
    end

    test "without auto_agent an MCP write needs an identity", %{scope: scope} do
      assert Actors.with_writer(scope, [], probe("probe/x")) == {:error, :needs_session_agent}
    end
  end

  describe "the session agent name" do
    test "a 60 character human name is cut to stay within 64", ctx do
      long = String.duplicate("a", 59) <> "z"
      ctx.human |> Ecto.Changeset.change(name: long) |> Repo.update!()

      assert {:ok, _value, %{actor: auto}} =
               Actors.with_writer(ctx.scope, [auto_agent: true], &{:ok, &1.actor.id})

      assert String.length(auto.name) <= 64
      assert Actor.valid_name?(auto.name)

      assert auto.name ==
               String.slice(long, 0, 49) <> "/session-" <> String.slice(auto.name, -6, 6)
    end

    test "a taken name is retried with another suffix", ctx do
      agent_fixture(ctx.workspace, ctx.owner, ctx.human.name <> "/session-aaaaaa")
      Process.put(:helmsman_session_agent_suffixes, ["aaaaaa", "bbbbbb"])

      assert {:ok, _value, %{actor: auto}} =
               Actors.with_writer(ctx.scope, [auto_agent: true], &{:ok, &1.actor.id})

      assert auto.name == ctx.human.name <> "/session-bbbbbb"
    end

    test "three taken names give :name_taken", ctx do
      agent_fixture(ctx.workspace, ctx.owner, ctx.human.name <> "/session-aaaaaa")
      Process.put(:helmsman_session_agent_suffixes, ["aaaaaa", "aaaaaa", "aaaaaa"])

      assert Actors.with_writer(ctx.scope, [auto_agent: true], &{:ok, &1.actor.id}) ==
               {:error, :name_taken}
    end
  end

  describe "nested write transactions" do
    setup %{owner: owner, workspace: ws} do
      project = project_fixture(workspace_scope_fixture(owner, ws))
      Events.subscribe(Events.topic(:project, project.id))
      %{project: project}
    end

    test "notifications are sent once, after the outer commit", %{scope: scope, project: project} do
      parent = self()

      fun = fn scope ->
        result = Helmsman.Tasks.create(scope, project.key, %{title: "Nested"})
        refute_received {:task_created, _}
        send(parent, :inside_done)
        result
      end

      assert {:ok, task, %{source: :auto}} = Actors.with_writer(scope, [auto_agent: true], fun)
      assert_received :inside_done
      assert_receive {:task_created, %{id: ident}}
      assert ident == task.ident
      refute_receive {:task_created, _}
    end

    test "an inner error sends nothing", %{scope: scope, project: project, workspace: ws} do
      fun = &Helmsman.Tasks.create(&1, project.key, %{title: ""})

      assert {:error, %Ecto.Changeset{}} = Actors.with_writer(scope, [auto_agent: true], fun)
      refute_receive {:task_created, _}
      assert session_agents(ws) == []
    end
  end
end
