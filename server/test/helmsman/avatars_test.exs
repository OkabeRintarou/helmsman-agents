defmodule Helmsman.AvatarsTest do
  # add-actor-avatars 7.2: actor-avatars (ownership, file checks, who may
  # set and remove, storage and replacement, notifications) and
  # `Actors.appearance/1`.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.AvatarsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Actors, Agents, Avatars, Events, Squads, Tasks, Tx}
  alias Helmsman.Actors.Actor
  alias Helmsman.Avatars.Avatar

  setup do
    ctx = squads_fixture()
    managed_agent_fixture(ctx.bob_scope, %{name: "bob/dev"})
    {dave, dave_scope} = member_scope_fixture(ctx.workspace, :admin)
    {viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

    Map.merge(ctx, %{
      dave: dave,
      dave_scope: dave_scope,
      viewer: viewer,
      viewer_scope: viewer_scope
    })
  end

  defp key_of(scope, name), do: get_in(Actors.appearance(scope), [name, :avatar_key])
  defp count, do: Repo.aggregate(Avatar, :count)

  describe "ownership" do
    test "a user's avatar shows on their human identity in every workspace", ctx do
      other = workspace_fixture(ctx.alice)
      other_scope = workspace_scope_fixture(ctx.alice, other)

      assert {:ok, %{key: key, content_type: "image/png"}} =
               Avatars.put(ctx.alice_scope, :me, png(64, 64))

      assert key_of(ctx.alice_scope, ctx.alice_scope.actor.name) == key
      assert key_of(other_scope, other_scope.actor.name) == key
      assert Avatars.user_avatar_key(ctx.alice.id) == key
      # Only the human: her agents keep their own (none).
      assert key_of(ctx.alice_scope, "keel/dev") == nil
    end

    test "the system identity, humans and unclaimed humans cannot have one", ctx do
      robert = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})

      for name <- ["helmsman", ctx.alice_scope.actor.name, ctx.bob_scope.actor.name, robert.name] do
        assert Avatars.put(ctx.alice_scope, {:actor, name}, png(64, 64)) == {:error, :forbidden}
        assert Avatars.delete(ctx.alice_scope, {:actor, name}) == {:error, :forbidden}
        assert Avatars.can_manage?(ctx.alice_scope, {:actor, name}) == false
      end

      assert count() == 0
      appearance = Actors.appearance(ctx.alice_scope)
      assert appearance["helmsman"].avatar_key == nil
      assert appearance["robert"].avatar_key == nil
    end

    test "a claimed human's records show the claimer's identity and avatar", ctx do
      robert = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})
      task = task_fixture(ctx.alice_scope, ctx.project.key)

      Repo.update_all(from(t in Tasks.Task, where: t.id == ^task.id),
        set: [created_by_id: robert.id]
      )

      {:ok, %{key: key}} = Avatars.put(ctx.bob_scope, :me, png(64, 64))
      {:ok, claim} = Actors.request_claim(ctx.bob_scope, "robert")
      {:ok, _} = Actors.decide_claim(ctx.alice_scope, claim.id, :approve)

      bob = ctx.bob_scope.actor
      assert Repo.get!(Tasks.Task, task.id).created_by_id == bob.id
      appearance = Actors.appearance(ctx.alice_scope)
      refute Map.has_key?(appearance, "robert")
      assert appearance[bob.name].avatar_key == key
    end
  end

  describe "file checks" do
    test "a rejected file keeps the current avatar and broadcasts nothing", ctx do
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
      Events.subscribe(Events.topic(:user, ctx.alice.id))

      for {data, error} <- [
            {png(300, 200), :not_square},
            {gif(64, 64), :unsupported_type},
            {jpeg(64, 64, 262_145), :too_large},
            {png(64, 64, apng: true), :animated},
            {png(16, 16), :bad_dimensions},
            {"", :invalid_image}
          ] do
        assert Avatars.put(ctx.alice_scope, :me, data) == {:error, error}
        assert Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, data) == {:error, error}
      end

      assert Avatars.user_avatar_key(ctx.alice.id) == key
      assert key_of(ctx.alice_scope, "keel/dev") == nil
      refute_receive {:avatars_changed}, 50
      refute_receive {:user_avatar_changed}, 10
    end

    test "a 256×256 WebP is saved", ctx do
      data = webp(256, 256) <> :binary.copy(<<0>>, 40_000)

      assert {:ok, %{content_type: "image/webp", key: key}} =
               Avatars.put(ctx.alice_scope, :me, data)

      assert {:ok, %{data: ^data, content_type: "image/webp"}} =
               Avatars.fetch_for_workspace(ctx.workspace.id, key)
    end
  end

  describe "who may set and remove" do
    test "the owner (member) sets their agent's avatar; another member may not", ctx do
      assert Avatars.can_manage?(ctx.bob_scope, {:actor, "bob/dev"}) == :set
      assert {:ok, %{key: key}} = Avatars.put(ctx.bob_scope, {:actor, "bob/dev"}, png(64, 64))
      assert Avatars.can_manage?(ctx.carol_scope, {:actor, "bob/dev"}) == false

      assert Avatars.put(ctx.carol_scope, {:actor, "bob/dev"}, png(48, 48)) ==
               {:error, :forbidden}

      assert Avatars.delete(ctx.carol_scope, {:actor, "bob/dev"}) == {:error, :forbidden}
      assert key_of(ctx.bob_scope, "bob/dev") == key
    end

    test "admins may only remove someone else's agent's avatar", ctx do
      {:ok, _} = Avatars.put(ctx.bob_scope, {:actor, "bob/dev"}, png(64, 64))
      assert Avatars.can_manage?(ctx.dave_scope, {:actor, "bob/dev"}) == :remove_only
      # The owner role too.
      assert Avatars.can_manage?(ctx.alice_scope, {:actor, "bob/dev"}) == :remove_only

      assert Avatars.put(ctx.dave_scope, {:actor, "bob/dev"}, png(48, 48)) ==
               {:error, :forbidden}

      assert Avatars.delete(ctx.dave_scope, {:actor, "bob/dev"}) == :ok
      assert key_of(ctx.bob_scope, "bob/dev") == nil
    end

    test "viewers set their own avatar but no agent's", ctx do
      assert Avatars.can_manage?(ctx.viewer_scope, :me) == :set
      assert {:ok, _} = Avatars.put(ctx.viewer_scope, :me, png(64, 64))
      assert Avatars.delete(ctx.viewer_scope, :me) == :ok
      viewer_agent = agent_fixture(ctx.workspace, ctx.viewer, "viewer/dev")
      assert Avatars.can_manage?(ctx.viewer_scope, {:actor, viewer_agent.name}) == false

      assert Avatars.put(ctx.viewer_scope, {:actor, viewer_agent.name}, png(64, 64)) ==
               {:error, :forbidden}
    end

    test "a user scope without a workspace sets its own avatar only", ctx do
      scope = user_scope_fixture(ctx.carol)
      assert {:ok, %{key: key}} = Avatars.put(scope, :me, png(64, 64))
      assert Avatars.user_avatar_key(ctx.carol.id) == key
      assert Avatars.put(scope, {:actor, "keel/dev"}, png(64, 64)) == {:error, :forbidden}
      assert Avatars.can_manage?(scope, {:actor, "keel/dev"}) == false
    end

    test "a squad's: who may manage it (the leader's owner, admins); not other members", ctx do
      managed_agent_fixture(ctx.bob_scope, %{name: "bob/lead", access: "workspace"})

      squad_fixture(ctx.bob_scope, %{name: "backend-team", leader: "bob/lead"})
      target = {:actor, "backend-team"}

      assert Avatars.can_manage?(ctx.bob_scope, target) == :set
      assert {:ok, _} = Avatars.put(ctx.bob_scope, target, png(64, 64))
      assert Avatars.can_manage?(ctx.carol_scope, target) == false
      assert Avatars.put(ctx.carol_scope, target, png(48, 48)) == {:error, :forbidden}
      assert Avatars.delete(ctx.carol_scope, target) == {:error, :forbidden}
      assert Avatars.can_manage?(ctx.dave_scope, target) == :set
      assert {:ok, _} = Avatars.put(ctx.dave_scope, target, png(40, 40))
      assert Avatars.delete(ctx.bob_scope, target) == :ok
    end

    test "after the leader changes, its former owner may not", ctx do
      managed_agent_fixture(ctx.bob_scope, %{name: "bob/lead", access: "workspace"})

      squad_fixture(ctx.bob_scope, %{name: "backend-team", leader: "bob/lead"})
      assert {:ok, _} = Squads.update(ctx.alice_scope, "backend-team", %{leader: "keel/lead"})

      assert Avatars.put(ctx.bob_scope, {:actor, "backend-team"}, png(64, 64)) ==
               {:error, :forbidden}

      assert Avatars.can_manage?(ctx.bob_scope, {:actor, "backend-team"}) == false
    end

    test "a squad with only its identity: admins and above", ctx do
      Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :squad, name: "old-team"})
      target = {:actor, "old-team"}
      assert Avatars.put(ctx.bob_scope, target, png(64, 64)) == {:error, :forbidden}
      assert {:ok, %{key: key}} = Avatars.put(ctx.dave_scope, target, png(64, 64))
      assert key_of(ctx.alice_scope, "old-team") == key
    end

    test "disabled and archived agents and disabled squads can still change", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
      assert {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
      {:ok, _} = Agents.archive(ctx.bob_scope, "bob/dev")
      assert {:ok, _} = Avatars.put(ctx.bob_scope, {:actor, "bob/dev"}, png(64, 64))
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
      assert {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "web-team"}, png(64, 64))
    end

    test "agent identities, run tokens and API tokens are refused", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
      {run_scope, _token} = run_scope_fixture(run)
      agent_scope = %{ctx.alice_scope | actor: ctx.agent}
      api_scope = token_scope_fixture(ctx.alice, ctx.workspace, :api)
      mcp_scope = %{token_scope_fixture(ctx.alice, ctx.workspace, :mcp) | actor: ctx.agent}

      for scope <- [run_scope, agent_scope, api_scope, mcp_scope],
          target <- [:me, {:actor, "keel/dev"}] do
        assert Avatars.put(scope, target, png(64, 64)) == {:error, :forbidden}
        assert Avatars.delete(scope, target) == {:error, :forbidden}
        assert Avatars.can_manage?(scope, target) == false
      end

      assert count() == 0
    end

    test "an unknown name is not found", ctx do
      assert Avatars.put(ctx.alice_scope, {:actor, "nobody/x"}, png(64, 64)) ==
               {:error, :not_found}

      assert Avatars.delete(ctx.alice_scope, {:actor, "nobody/x"}) == {:error, :not_found}
      assert Avatars.can_manage?(ctx.alice_scope, {:actor, "nobody/x"}) == false
    end
  end

  describe "storage and replacement" do
    test "a new avatar replaces the old one and its key", ctx do
      {:ok, %{key: first}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))

      {:ok, %{key: second}} =
        Avatars.put(ctx.alice_scope, :me, png(64, 64, color: {200, 0, 0, 255}))

      assert first != second
      assert count() == 1
      assert Avatars.fetch_for_workspace(ctx.workspace.id, first) == :error
      assert Avatars.fetch_own(ctx.alice.id, first) == :error
      assert {:ok, %{key: ^second}} = Avatars.fetch_own(ctx.alice.id, second)
      assert %Avatar{data: nil, key: ^second, byte_size: size} = Repo.one!(Avatar)
      assert size > 0
    end

    test "removing twice succeeds both times", ctx do
      {:ok, _} = Avatars.put(ctx.alice_scope, :me, png(64, 64))
      assert Avatars.delete(ctx.alice_scope, :me) == :ok
      assert Avatars.delete(ctx.alice_scope, :me) == :ok
      assert key_of(ctx.alice_scope, ctx.alice_scope.actor.name) == nil
      assert Avatars.delete(ctx.alice_scope, {:actor, "keel/dev"}) == :ok
    end

    test "deleting the identity or the user deletes the avatar", ctx do
      old = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :squad, name: "old-team"})
      {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "old-team"}, png(64, 64))
      user = user_fixture()
      {:ok, _} = Avatars.put(user_scope_fixture(user), :me, png(64, 64))
      assert count() == 2

      Repo.delete!(old)
      Repo.delete!(user)
      assert count() == 0
    end

    test "the same bytes on two identities share a key", ctx do
      data = png(64, 64)
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, data)
      {:ok, %{key: ^key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/lead"}, data)
      assert {:ok, %{data: ^data}} = Avatars.fetch_for_workspace(ctx.workspace.id, key)
    end
  end

  describe "reading" do
    test "the workspace reads its agents' and squads' avatars and its humans' users'", ctx do
      {:ok, %{key: agent_key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
      {:ok, %{key: squad_key}} = Avatars.put(ctx.alice_scope, {:actor, "web-team"}, png(40, 40))
      {:ok, %{key: bob_key}} = Avatars.put(ctx.bob_scope, :me, png(48, 48))

      for key <- [agent_key, squad_key, bob_key] do
        assert {:ok, %{key: ^key}} = Avatars.fetch_for_workspace(ctx.workspace.id, key)
      end

      # Another workspace, and a user with no identity in it.
      outsider = user_fixture()
      other = workspace_fixture(outsider)
      {:ok, %{key: outsider_key}} = Avatars.put(user_scope_fixture(outsider), :me, png(56, 56))
      other_scope = workspace_scope_fixture(outsider, other)
      managed_agent_fixture(other_scope, %{name: "other/dev"})
      {:ok, %{key: other_key}} = Avatars.put(other_scope, {:actor, "other/dev"}, png(60, 60))

      assert Avatars.fetch_for_workspace(ctx.workspace.id, outsider_key) == :error
      assert Avatars.fetch_for_workspace(ctx.workspace.id, other_key) == :error
      assert Avatars.fetch_for_workspace(other.id, agent_key) == :error
      assert Avatars.fetch_for_workspace(other.id, bob_key) == :error
      assert Avatars.fetch_own(ctx.alice.id, bob_key) == :error
      assert {:ok, _} = Avatars.fetch_own(ctx.bob.id, bob_key)
    end

    test "malformed keys are refused", ctx do
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))

      for bad <- [String.upcase(key), key <> "0", "", nil, 42, "../" <> key] do
        assert Avatars.fetch_for_workspace(ctx.workspace.id, bad) == :error
        assert Avatars.fetch_own(ctx.alice.id, bad) == :error
      end
    end
  end

  describe "notifications" do
    test "a user's avatar: each of their workspaces once and their user topic once", ctx do
      other = workspace_fixture(ctx.alice)
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
      Events.subscribe(Events.topic(:workspace, other.id))
      Events.subscribe(Events.topic(:user, ctx.alice.id))

      {:ok, _} = Avatars.put(ctx.alice_scope, :me, png(64, 64))

      assert_receive {:avatars_changed}
      assert_receive {:avatars_changed}
      assert_receive {:user_avatar_changed}
      refute_receive {:avatars_changed}, 50
      refute_receive {:user_avatar_changed}, 10
    end

    test "an agent's avatar: the workspace, once per transaction, only after the commit", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
      Events.subscribe(Events.topic(:user, ctx.alice.id))

      {:ok, _} =
        Tx.run(fn ->
          {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
          {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/lead"}, png(64, 64))
          :ok = Avatars.delete(ctx.alice_scope, {:actor, "keel/dev"})
          refute_received {:avatars_changed}
          {:ok, :done}
        end)

      assert_receive {:avatars_changed}
      refute_receive {:avatars_changed}, 50
      refute_received {:user_avatar_changed}
    end

    test "removing nothing broadcasts nothing", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
      assert Avatars.delete(ctx.alice_scope, {:actor, "keel/dev"}) == :ok
      assert Avatars.delete(ctx.alice_scope, :me) == :ok
      refute_receive {:avatars_changed}, 50
    end

    test "a rolled back write broadcasts nothing", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

      {:error, :rollback} =
        Tx.run(fn ->
          {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
          {:error, :rollback}
        end)

      refute_receive {:avatars_changed}, 50
      assert count() == 0
    end
  end

  describe "appearance" do
    test "every identity by name, in one query, without bytes", ctx do
      robert = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})
      external = agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/fe")
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))

      {appearance, queries} =
        Helmsman.QueryCount.count(fn -> Actors.appearance(ctx.alice_scope) end)

      assert queries == 1

      assert %{kind: :agent, provider: :claude, managed?: true, avatar_key: ^key} =
               appearance["keel/dev"]

      assert %{kind: :agent, provider: nil, managed?: false, avatar_key: nil} =
               appearance[external.name]

      assert %{kind: :agent, managed?: true} = appearance["keel/fe"]
      assert %{kind: :squad, provider: nil, managed?: false} = appearance["web-team"]
      assert %{kind: :human, avatar_key: nil} = appearance[robert.name]
      assert %{kind: :system, avatar_key: nil} = appearance["helmsman"]
      assert %{kind: :human} = appearance[ctx.alice_scope.actor.name]
    end

    test "a scope without a workspace or role gets nothing", ctx do
      assert Actors.appearance(user_scope_fixture(ctx.alice)) == %{}
      assert Actors.appearance(%{ctx.alice_scope | role: nil}) == %{}
    end
  end
end
