defmodule HelmsmanMCP.Tools.IdentityToolsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias HelmsmanMCP.{Context, Identity, Pipeline, Sessions}
  alias HelmsmanMCP.Tools.{Identify, ListActors, Whoami}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    %{api_token: token} = api_token_fixture(workspace_scope_fixture(alice, workspace))
    scope = token_scope_fixture(alice, workspace, :mcp, token)
    sid = "identity-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, scope, self())

    %{
      scope: scope,
      sid: sid,
      workspace: workspace,
      alice: alice,
      human: Actors.get_human(workspace.id, alice.id).name
    }
  end

  # The context the pipeline builds for a read tool.
  defp ctx(scope, sid, args \\ %{}) do
    %{actor_id: actor_id, source: source} = Sessions.lookup(sid)
    session = %{id: sid, actor_id: actor_id, source: source}
    scope = %{scope | actor: Identity.current(scope, session)}
    %Context{tool: "test", args: args, scope: scope, session: session}
  end

  defp identify(scope, sid, args), do: Identify.call(args, ctx(scope, sid, args))

  defp actor_count(workspace),
    do: Repo.aggregate(from(a in Actor, where: a.workspace_id == ^workspace.id), :count)

  describe "identify" do
    test "sets the session identity", %{scope: scope, sid: sid} do
      args = %{"name" => "keel/dev", "project" => "KEEL", "worktree" => "wt-1"}

      assert {:ok, result} = identify(scope, sid, args)

      assert result == %{
               name: "keel/dev",
               kind: :agent,
               project: "KEEL",
               worktree: "wt-1",
               source: "identify"
             }

      assert %{source: :identify, actor_id: id} = Sessions.lookup(sid)
      assert %Actor{name: "keel/dev"} = Repo.get!(Actor, id)

      # Writes without an actor argument are recorded as keel/dev.
      assert {:ok, %{"actor" => "keel/dev"}} =
               Pipeline.call_module(__MODULE__.Writer, %{}, scope, sid)
               |> then(fn {:ok, json} -> {:ok, Jason.decode!(json)} end)
    end

    test "a taken name leaves the session identity", %{scope: scope, sid: sid, human: human} do
      {:ok, _} = identify(scope, sid, %{"name" => "keel/dev"})
      before = Sessions.lookup(sid)

      assert identify(scope, sid, %{"name" => human}) == {:error, :name_taken}
      assert Sessions.lookup(sid) == before
    end

    test "only kind=agent", %{scope: scope, sid: sid} do
      assert identify(scope, sid, %{"name" => "keel/dev", "kind" => "human"}) ==
               {:error, {:invalid_kind, "human"}}

      assert %{actor_id: nil, source: nil} = Sessions.lookup(sid)
      assert {:ok, _} = identify(scope, sid, %{"name" => "keel/dev", "kind" => "agent"})
    end
  end

  describe "whoami" do
    test "the default agent", %{scope: scope, sid: sid, workspace: ws, alice: alice} = ctx do
      keel = agent_fixture(ws, alice, "keel/dev")
      scope = %{scope | token: %{scope.token | default_agent_id: keel.id}}

      assert {:ok, result} = Whoami.call(%{}, ctx(scope, sid))

      assert result == %{
               actor: %{
                 name: "keel/dev",
                 kind: :agent,
                 disabled: false,
                 has_avatar: false,
                 avatar_url: nil
               },
               source: "default",
               user: %{name: ctx.human, role: :member},
               workspace: %{slug: ws.slug, name: ws.name}
             }
    end

    test "nothing, and no identity is created", %{scope: scope, sid: sid, workspace: ws} do
      count = actor_count(ws)
      assert {:ok, %{actor: nil, source: "none"}} = Whoami.call(%{}, ctx(scope, sid))
      assert actor_count(ws) == count
    end

    test "a disabled session identity", %{scope: scope, sid: sid} do
      {:ok, _} = identify(scope, sid, %{"name" => "keel/dev"})
      Repo.update_all(where(Actor, name: "keel/dev"), set: [disabled_at: DateTime.utc_now()])

      assert {:ok, %{actor: %{name: "keel/dev", disabled: true}, source: "identify"}} =
               Whoami.call(%{}, ctx(scope, sid))
    end
  end

  describe "list_actors" do
    setup %{workspace: ws, alice: alice} do
      agent_fixture(ws, alice, "keel/dev")
      agent_fixture(workspace_fixture(user_fixture()), alice, "other/dev")
      viewer = user_fixture()
      member_fixture(ws, viewer, :viewer)
      %{viewer: %{workspace_scope_fixture(viewer, ws) | via: :mcp}}
    end

    test "lists the workspace's identities", %{viewer: viewer, human: human} do
      assert {:ok, actors} = ListActors.call(%{}, %Context{tool: "list_actors", scope: viewer})

      assert %{kind: :agent, owner: ^human} = Enum.find(actors, &(&1.name == "keel/dev"))
      assert Enum.find(actors, &(&1.name == human)).kind == :human
      assert Enum.any?(actors, &(&1.kind == :system))
    end

    test "not other workspaces' identities", %{viewer: viewer} do
      assert {:ok, actors} = ListActors.call(%{}, %Context{tool: "list_actors", scope: viewer})
      refute Enum.any?(actors, &(&1.name == "other/dev"))
    end
  end

  defmodule Writer do
    @moduledoc false
    use HelmsmanMCP.Tool, name: "test_writer", description: "Write.", schema: %{}, mode: :write

    @impl HelmsmanMCP.Tool
    def call(_args, ctx), do: {:ok, %{actor: ctx.scope.actor.name}}
  end
end
