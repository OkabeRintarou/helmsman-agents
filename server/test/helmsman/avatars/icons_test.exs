defmodule Helmsman.Avatars.IconsTest do
  # update-actor-icons 3.1–3.2: actor-avatars「内置图标头像」and「头像的存储与
  # 替换」(D1–D3): the icon whitelist, who may set an icon (the table of
  # `put/3`), the two forms replacing each other in one row, the CHECKs,
  # reading and notifications.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.AvatarsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Actors, Agents, Avatars, Events, Squads, Tx}
  alias Helmsman.Actors.Actor
  alias Helmsman.Avatars.{Avatar, Icons}

  setup do
    ctx = squads_fixture()
    managed_agent_fixture(ctx.bob_scope, %{name: "bob/dev"})
    {_dave, dave_scope} = member_scope_fixture(ctx.workspace, :admin)
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    Map.merge(ctx, %{dave_scope: dave_scope, viewer_scope: viewer_scope})
  end

  defp look(scope, name),
    do: Map.take(Actors.appearance(scope)[name], [:avatar_key, :avatar_icon])

  defp count, do: Repo.aggregate(Avatar, :count)

  defp subscribe(ctx) do
    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))
    Events.subscribe(Events.topic(:user, ctx.alice.id))
  end

  describe "the whitelist" do
    test "49 sorted, distinct keys of the icon format" do
      keys = Icons.keys()
      assert length(keys) == 49
      assert keys == Enum.sort(Enum.uniq(keys))
      assert Enum.all?(keys, &(&1 =~ ~r/\A[a-z0-9]{1,32}\z/))
      assert Icons.valid?("githubcopilot") and Icons.valid?("claude")
      refute Icons.valid?("copilot") or Icons.valid?("foo") or Icons.valid?(nil)
    end
  end

  describe "built-in icon avatars" do
    test "choosing an icon: saved, the workspace is told once", ctx do
      subscribe(ctx)

      assert {:ok, %{icon: "zai"}} =
               Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")

      assert look(ctx.alice_scope, "keel/dev") == %{avatar_key: nil, avatar_icon: "zai"}
      assert_receive {:avatars_changed}
      refute_receive {:avatars_changed}, 50
      refute_received {:user_avatar_changed}
    end

    test "an icon not in the list: unknown_icon, nothing changes, nothing is broadcast", ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "openai")
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))
      subscribe(ctx)

      for icon <- ["foo", "copilot", "", "ZAI", "../zai", nil, 42] do
        assert Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, icon) ==
                 {:error, :unknown_icon}

        assert Avatars.put_icon(ctx.alice_scope, :me, icon) == {:error, :unknown_icon}
      end

      assert look(ctx.alice_scope, "keel/dev") == %{avatar_key: nil, avatar_icon: "openai"}
      assert Avatars.user_avatar(ctx.alice.id) == {:image, key}
      refute_receive {:avatars_changed}, 50
      refute_received {:user_avatar_changed}
    end

    test "icon, image, icon: one avatar each time; the image key is gone after", ctx do
      me = ctx.alice_scope.actor.name

      assert {:ok, _} = Avatars.put_icon(ctx.alice_scope, :me, "openai")
      assert Avatars.user_avatar(ctx.alice.id) == {:icon, "openai"}
      assert Avatars.user_avatar_key(ctx.alice.id) == nil
      assert look(ctx.alice_scope, me) == %{avatar_key: nil, avatar_icon: "openai"}
      assert count() == 1

      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))
      assert Avatars.user_avatar(ctx.alice.id) == {:image, key}
      assert Avatars.user_avatar_key(ctx.alice.id) == key
      assert look(ctx.alice_scope, me) == %{avatar_key: key, avatar_icon: nil}
      assert count() == 1

      assert {:ok, _} = Avatars.put_icon(ctx.alice_scope, :me, "deepseek")
      assert Avatars.user_avatar(ctx.alice.id) == {:icon, "deepseek"}
      assert look(ctx.alice_scope, me) == %{avatar_key: nil, avatar_icon: "deepseek"}
      assert count() == 1
      assert Avatars.fetch_own(ctx.alice.id, key) == :error
      assert Avatars.fetch_for_workspace(ctx.workspace.id, key) == :error

      assert %Avatar{icon: "deepseek", key: nil, content_type: nil, byte_size: nil, edge: nil} =
               Repo.one!(Avatar)

      assert Repo.one!(from(a in Avatar, select: is_nil(a.data)))
    end

    test "an icon replaces an agent's image; its read key is gone", ctx do
      {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
      assert {:ok, _} = Avatars.fetch_for_workspace(ctx.workspace.id, key)

      assert {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "claude")
      assert Avatars.fetch_for_workspace(ctx.workspace.id, key) == :error
      assert look(ctx.alice_scope, "keel/dev") == %{avatar_key: nil, avatar_icon: "claude"}
      assert count() == 1
    end

    test "removing deletes an icon too, twice succeeds", ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, :me, "zai")
      subscribe(ctx)

      assert Avatars.delete(ctx.alice_scope, {:actor, "keel/dev"}) == :ok
      assert Avatars.delete(ctx.alice_scope, :me) == :ok
      assert_receive {:avatars_changed}
      assert_receive {:user_avatar_changed}
      assert Avatars.delete(ctx.alice_scope, :me) == :ok
      assert Avatars.user_avatar(ctx.alice.id) == nil
      assert look(ctx.alice_scope, "keel/dev") == %{avatar_key: nil, avatar_icon: nil}
      assert count() == 0
    end

    test "a user's icon shows on their human identity in every workspace", ctx do
      other = workspace_fixture(ctx.alice)
      other_scope = workspace_scope_fixture(ctx.alice, other)
      Events.subscribe(Events.topic(:workspace, other.id))
      subscribe(ctx)

      {:ok, _} = Avatars.put_icon(ctx.alice_scope, :me, "kimi")

      assert look(ctx.alice_scope, ctx.alice_scope.actor.name).avatar_icon == "kimi"
      assert look(other_scope, other_scope.actor.name).avatar_icon == "kimi"
      assert look(ctx.alice_scope, "keel/dev").avatar_icon == nil
      assert_receive {:avatars_changed}
      assert_receive {:avatars_changed}
      assert_receive {:user_avatar_changed}
      refute_receive {:avatars_changed}, 50
    end

    test "deleting the identity or the user deletes the icon", ctx do
      old = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :squad, name: "old-team"})
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "old-team"}, "zai")
      user = user_fixture()
      {:ok, _} = Avatars.put_icon(user_scope_fixture(user), :me, "zai")
      assert count() == 2

      Repo.delete!(old)
      Repo.delete!(user)
      assert count() == 0
    end
  end

  # The table of「谁能设置与移除头像」, row by row, with put_icon.
  describe "who may set an icon" do
    test "the owner (member) sets their agent's; another member may not", ctx do
      assert {:ok, _} = Avatars.put_icon(ctx.bob_scope, {:actor, "bob/dev"}, "zai")

      assert Avatars.put_icon(ctx.carol_scope, {:actor, "bob/dev"}, "kimi") ==
               {:error, :forbidden}

      assert Avatars.delete(ctx.carol_scope, {:actor, "bob/dev"}) == {:error, :forbidden}
      assert look(ctx.bob_scope, "bob/dev").avatar_icon == "zai"
    end

    test "admins and the owner role may only remove someone else's agent's", ctx do
      {:ok, _} = Avatars.put_icon(ctx.bob_scope, {:actor, "bob/dev"}, "zai")

      for scope <- [ctx.dave_scope, ctx.alice_scope] do
        assert Avatars.put_icon(scope, {:actor, "bob/dev"}, "kimi") == {:error, :forbidden}
      end

      assert look(ctx.bob_scope, "bob/dev").avatar_icon == "zai"
      assert Avatars.delete(ctx.dave_scope, {:actor, "bob/dev"}) == :ok
      assert look(ctx.bob_scope, "bob/dev").avatar_icon == nil
    end

    test "viewers set their own but no agent's", ctx do
      assert {:ok, _} = Avatars.put_icon(ctx.viewer_scope, :me, "zai")
      viewer_agent = agent_fixture(ctx.workspace, ctx.viewer_scope.user, "viewer/dev")

      assert Avatars.put_icon(ctx.viewer_scope, {:actor, viewer_agent.name}, "zai") ==
               {:error, :forbidden}
    end

    test "a user scope without a workspace sets its own only", ctx do
      scope = user_scope_fixture(ctx.carol)
      assert {:ok, _} = Avatars.put_icon(scope, :me, "zai")
      assert Avatars.user_avatar(ctx.carol.id) == {:icon, "zai"}
      assert Avatars.put_icon(scope, {:actor, "keel/dev"}, "zai") == {:error, :forbidden}
    end

    test "a squad's: the leader's owner and admins; not other members", ctx do
      managed_agent_fixture(ctx.bob_scope, %{name: "bob/lead", access: "workspace"})
      squad_fixture(ctx.bob_scope, %{name: "backend-team", leader: "bob/lead"})
      target = {:actor, "backend-team"}

      assert {:ok, _} = Avatars.put_icon(ctx.bob_scope, target, "zai")
      assert Avatars.put_icon(ctx.carol_scope, target, "kimi") == {:error, :forbidden}
      assert {:ok, _} = Avatars.put_icon(ctx.dave_scope, target, "kimi")

      assert {:ok, _} = Squads.update(ctx.alice_scope, "backend-team", %{leader: "keel/lead"})
      assert Avatars.put_icon(ctx.bob_scope, target, "zai") == {:error, :forbidden}
      assert look(ctx.alice_scope, "backend-team").avatar_icon == "kimi"
    end

    test "a squad with only its identity: admins and above", ctx do
      Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :squad, name: "old-team"})
      assert Avatars.put_icon(ctx.bob_scope, {:actor, "old-team"}, "zai") == {:error, :forbidden}
      assert {:ok, _} = Avatars.put_icon(ctx.dave_scope, {:actor, "old-team"}, "zai")
    end

    test "disabled and archived agents and disabled squads can still change", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
      assert {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      {:ok, _} = Agents.archive(ctx.bob_scope, "bob/dev")
      assert {:ok, _} = Avatars.put_icon(ctx.bob_scope, {:actor, "bob/dev"}, "zai")
      {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
      assert {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "web-team"}, "zai")
    end

    test "the system identity, humans and unclaimed humans cannot have one", ctx do
      robert = Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "robert"})

      for name <- ["helmsman", ctx.alice_scope.actor.name, ctx.bob_scope.actor.name, robert.name] do
        assert Avatars.put_icon(ctx.alice_scope, {:actor, name}, "zai") == {:error, :forbidden}
      end

      assert count() == 0
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
        assert Avatars.put_icon(scope, target, "zai") == {:error, :forbidden}
      end

      assert count() == 0
    end

    test "an unknown name is not found", ctx do
      assert Avatars.put_icon(ctx.alice_scope, {:actor, "nobody/x"}, "zai") ==
               {:error, :not_found}
    end

    test "a refusal broadcasts nothing", ctx do
      subscribe(ctx)
      {:error, :forbidden} = Avatars.put_icon(ctx.carol_scope, {:actor, "bob/dev"}, "zai")
      {:error, :not_found} = Avatars.put_icon(ctx.alice_scope, {:actor, "nobody/x"}, "zai")
      refute_receive {:avatars_changed}, 50
    end
  end

  describe "notifications" do
    test "once per transaction, after the commit; none on rollback", ctx do
      subscribe(ctx)

      {:ok, :done} =
        Tx.run(fn ->
          {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
          {:ok, _} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64))
          {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/lead"}, "kimi")
          refute_received {:avatars_changed}
          {:ok, :done}
        end)

      assert_receive {:avatars_changed}
      refute_receive {:avatars_changed}, 50

      {:error, :rollback} =
        Tx.run(fn ->
          {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "openai")
          {:error, :rollback}
        end)

      refute_receive {:avatars_changed}, 50
      assert look(ctx.alice_scope, "keel/lead").avatar_icon == "kimi"
      assert %{avatar_icon: nil, avatar_key: key} = look(ctx.alice_scope, "keel/dev")
      assert is_binary(key)
    end
  end

  # D1: the table's CHECKs, written directly.
  describe "constraints" do
    defp insert(ctx, fields) do
      {columns, values} = Enum.unzip(fields)
      columns = [:user_id, :inserted_at, :updated_at | columns]
      placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")
      now = DateTime.utc_now()

      Repo.query(
        "INSERT INTO avatars (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
        [ctx.alice.id, now, now | values]
      )
    end

    defp assert_check(result, constraint) do
      assert {:error,
              %Postgrex.Error{postgres: %{code: :check_violation, constraint: ^constraint}}} =
               result
    end

    test "an image and an icon together, or neither, violate avatars_form", ctx do
      data = png(64, 64)

      image = [
        content_type: "image/png",
        data: data,
        key: Avatar.key(data),
        byte_size: byte_size(data),
        edge: 64
      ]

      assert_check(insert(ctx, image ++ [icon: "zai"]), "avatars_form")
      assert_check(insert(ctx, []), "avatars_form")
      assert_check(insert(ctx, icon: "zai", edge: 64), "avatars_form")
      assert_check(insert(ctx, Keyword.delete(image, :edge)), "avatars_form")
      assert_check(insert(ctx, icon: "Zai"), "avatars_icon_format")
      assert {:ok, _} = insert(ctx, icon: "zai")
    end
  end
end
