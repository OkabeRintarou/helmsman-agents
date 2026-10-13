defmodule Helmsman.AgentDesignsTest do
  # add-agent-conversation 3.1, 3.6: starting, turns, changing the helper,
  # reading (decisions 4, 6, 11).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage}
  alias Helmsman.{Agents, Events, Runs}
  alias Helmsman.Runs.Run

  setup do
    design_fixture()
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "starting a conversation" do
    test "an open conversation with the message and a queued design run (scenario)", ctx do
      assert %{id: id, status: :open, kind: :agent} =
               start_design!(ctx.alice_scope, "帮我建一个前端开发 Agent，用 Tailwind")

      assert [%AgentDesignMessage{role: :user, content: "帮我建一个前端开发 Agent，用 Tailwind"}] =
               messages!(id)

      run = current_run!(id)
      assert run.agent_id == ctx.helper.id and run.status == :queued
      assert run.task_id == nil and run.lane == :work
      assert run.root_initiator_user_id == ctx.alice.id

      assert [%{"kind" => "design", "design_id" => ^id, "initiator_user_id" => uid}] =
               run.triggers

      assert uid == ctx.alice.id
      assert run.priority == 3
      assert run.capabilities == ["read", "design"]
      assert design!(id).user_messages == 1
    end

    test "with an open conversation already: design_open and its ID (scenario)", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      runs = count(Run)

      assert AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "again"}) ==
               {:error, {:design_open, id}}

      assert count(AgentDesign) == 1 and count(Run) == runs
    end

    test "a helper the user may not trigger: unauthorized, nothing written (scenario)", ctx do
      {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
      managed_agent_fixture(bob_scope, %{name: "bob-helper"})
      runs = count(Run)

      assert AgentDesigns.start(ctx.alice_scope, %{helper: "bob-helper", message: "hi"}) ==
               {:error, :unauthorized}

      assert count(AgentDesign) == 0 and count(AgentDesignMessage) == 0 and count(Run) == runs
    end

    test "an external agent: not_managed; an unknown one: not_found", ctx do
      Repo.insert!(%Actor{
        workspace_id: ctx.workspace.id,
        kind: :agent,
        owner_id: ctx.alice.id,
        name: "ext"
      })

      assert AgentDesigns.start(ctx.alice_scope, %{helper: "ext", message: "hi"}) ==
               {:error, :not_managed}

      assert AgentDesigns.start(ctx.alice_scope, %{helper: "nobody", message: "hi"}) ==
               {:error, :not_found}

      assert count(AgentDesign) == 0
    end

    test "a run token, an hm_ token and a viewer are forbidden (scenario)", ctx do
      run = run_fixture(ctx.helper, %{status: :running, capabilities: ["read", "design"]})
      {run_scope, _token} = run_scope_fixture(run)
      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
      mcp = %{ctx.alice_scope | via: :mcp}

      for scope <- [run_scope, viewer_scope, mcp] do
        assert AgentDesigns.start(scope, %{helper: "helper", message: "hi"}) ==
                 {:error, :forbidden}
      end

      assert count(AgentDesign) == 0
    end

    test "a message must be 1 byte to 8 KB: a changeset on :message", ctx do
      for text <- ["", "   ", String.duplicate("a", 8193), nil] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: text})

        assert Keyword.has_key?(cs.errors, :message)
      end

      assert {:ok, _} =
               AgentDesigns.start(ctx.alice_scope, %{
                 helper: "helper",
                 message: String.duplicate("a", 8192)
               })
    end
  end

  describe "a turn" do
    setup ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      Events.subscribe(AgentDesigns.topic(id))
      %{id: id}
    end

    test "the second turn after the first was settled (scenario)", ctx do
      first = current_run!(ctx.id)
      end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: "Which model?")
      assert_receive {:agent_design, _}

      assert {:ok, %{current_run: %{id: run_id, status: :queued}}} =
               AgentDesigns.send(ctx.alice_scope, ctx.id, "改用 sonnet，推理强度 high")

      assert run_id != first.id
      assert [_, _] = design_runs!(ctx.id)
      assert_receive {:agent_design, id} when id == ctx.id
      assert %{role: :user, run_id: ^run_id} = List.last(messages!(ctx.id))
    end

    test "while the turn runs: turn_running, nothing written (scenario)", ctx do
      run_turn!(ctx, ctx.id)
      before = {count(AgentDesignMessage), count(Run)}

      assert AgentDesigns.send(ctx.alice_scope, ctx.id, "more") == {:error, :turn_running}
      assert {count(AgentDesignMessage), count(Run)} == before
      refute_receive {:agent_design, _}
    end

    test "after 40 user messages: turn_limit (scenario)", ctx do
      end_and_settle!(current_run!(ctx.id), :cancelled)
      Repo.update_all(from(d in AgentDesign, where: d.id == ^ctx.id), set: [user_messages: 40])
      assert AgentDesigns.send(ctx.alice_scope, ctx.id, "more") == {:error, :turn_limit}
    end

    test "a disabled helper: agent_disabled; another helper works (scenario)", ctx do
      end_and_settle!(current_run!(ctx.id), :cancelled)
      {:ok, _} = Agents.disable(ctx.alice_scope, "helper")
      before = count(AgentDesignMessage)

      assert AgentDesigns.send(ctx.alice_scope, ctx.id, "more") == {:error, :agent_disabled}
      assert count(AgentDesignMessage) == before

      managed_agent_fixture(ctx.alice_scope, %{name: "helper2", runtime_id: ctx.runtime.id})
      assert {:ok, _} = AgentDesigns.change_helper(ctx.alice_scope, ctx.id, "helper2")

      assert {:ok, %{helper: %{name: "helper2"}}} =
               AgentDesigns.send(ctx.alice_scope, ctx.id, "go")
    end

    test "a closed conversation: design_closed", ctx do
      {:ok, _} = AgentDesigns.discard(ctx.alice_scope, ctx.id)
      assert AgentDesigns.send(ctx.alice_scope, ctx.id, "more") == {:error, :design_closed}
    end
  end

  describe "changing the helper" do
    test "the next turn belongs to the new helper; history and draft stay (scenario)", ctx do
      {daemon, _} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
      codex = runtime_fixture(ctx.workspace, daemon, %{provider: "codex"})

      managed_agent_fixture(ctx.alice_scope, %{
        name: "codex-helper",
        provider: "codex",
        runtime_id: codex.id
      })

      %{id: id} = start_design!(ctx.alice_scope)

      assert AgentDesigns.change_helper(ctx.alice_scope, id, "codex-helper") ==
               {:error, :turn_running}

      end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "Hello")

      assert {:ok, %{helper: %{name: "codex-helper", provider: "codex"}}} =
               AgentDesigns.change_helper(ctx.alice_scope, id, "codex-helper")

      assert %{role: :system, code: "helper_changed", detail: "codex-helper"} =
               List.last(messages!(id))

      assert {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "go on")
      assert current_run!(id).agent_id == Repo.get_by!(Actor, name: "codex-helper").id
      assert length(messages!(id)) == 4
    end

    test "a helper that cannot be dispatched: its reason", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      end_and_settle!(current_run!(id), :cancelled)
      managed_agent_fixture(ctx.alice_scope, %{name: "unbound", runtime_id: nil})

      assert AgentDesigns.change_helper(ctx.alice_scope, id, "unbound") == {:error, :no_runtime}
    end
  end

  describe "reading" do
    test "the owner reading alice's conversation gets not_found (scenario)", ctx do
      {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
      %{id: id} = start_design!(ctx.alice_scope)

      for role <- [:owner, :admin] do
        {_user, scope} = member_scope_fixture(ctx.workspace, role)
        assert AgentDesigns.get(scope, id) == {:error, :not_found}
      end

      assert AgentDesigns.get(bob_scope, id) == {:error, :not_found}
      assert AgentDesigns.current(bob_scope) == {:ok, nil}
      assert {:ok, %{id: ^id}} = AgentDesigns.current(ctx.alice_scope)
      assert {:ok, %{id: ^id}} = AgentDesigns.get(ctx.alice_scope, Integer.to_string(id))
    end

    test "the view's fields (decision 4)", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      {:ok, view} = AgentDesigns.get(ctx.alice_scope, id)

      assert view |> Map.keys() |> Enum.sort() ==
               Enum.sort(
                 ~w(id kind status helper messages current_run draft draft_version pending_edits
                    user_messages usage created_agents inserted_at last_activity_at)a
               )

      assert view.helper == %{
               name: "helper",
               provider: "claude",
               owner: %{user_id: ctx.alice.id, name: ctx.alice.display_name},
               dispatchability: :ok
             }

      assert [%{seq: 1, role: :user, edits: [], code: nil, run_id: run_id}] = view.messages
      assert view.current_run == %{id: run_id, status: :queued}
      assert view.draft == %{"agents" => []}
      assert view.usage == %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cost: 0}
    end

    test "usage: the sum of the design runs (scenario)", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      usage = fn n -> %{"input_tokens" => n, "output_tokens" => 10, "cost_usd" => 0.5} end
      end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "a", usage: usage.(1000))
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "more")
      end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "b", usage: usage.(2000))

      {:ok, view} = AgentDesigns.get(ctx.alice_scope, id)
      assert %{input_tokens: 3000, output_tokens: 20, cost: 1.0} = view.usage

      {:ok, runs} = Runs.list_for_agent(ctx.alice_scope, "helper")
      design_runs = Enum.filter(runs, &match?([%{kind: "design"}], &1.triggers))
      assert length(design_runs) == 2
      assert Enum.all?(design_runs, &(&1.initiator.id == ctx.alice.id))

      assert Enum.all?(design_runs, fn run ->
               [%{by: %{name: name, kind: "human"}} = trigger] = run.triggers
               name == ctx.alice_scope.actor.name and not Map.has_key?(trigger, :design_id)
             end)
    end

    test "helpers: the agents the user may trigger, with their dispatchability", ctx do
      {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
      managed_agent_fixture(bob_scope, %{name: "bob-private"})
      managed_agent_fixture(bob_scope, %{name: "bob-shared", access: "workspace"})
      managed_agent_fixture(ctx.alice_scope, %{name: "unbound", runtime_id: nil})

      assert {:ok, helpers} = AgentDesigns.helpers(ctx.alice_scope)
      by_name = Map.new(helpers, &{&1.name, &1})
      assert Map.keys(by_name) |> Enum.sort() == ["bob-shared", "helper", "unbound"]
      assert by_name["helper"].dispatchability == :ok
      assert by_name["unbound"].dispatchability == {:skipped, :no_runtime}
      assert by_name["bob-shared"].owner.user_id == bob_scope.user.id

      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
      assert AgentDesigns.helpers(viewer_scope) == {:error, :forbidden}
    end
  end
end
