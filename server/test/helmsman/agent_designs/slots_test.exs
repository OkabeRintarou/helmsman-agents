defmodule Helmsman.AgentDesigns.SlotsTest do
  # add-edit-design-conversations 1.2: agent-design 「对话的种类与槽位」 and
  # the MODIFIED 「开始创建对话」 (decision 3).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{AgentDesign, Kinds}
  alias Helmsman.Runs.Run

  setup do
    ctx = design_fixture()
    target = Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{name: "fe-dev"})
    Map.put(ctx, :target, agent_actor(ctx.workspace, target.name))
  end

  defp open_count(ctx),
    do:
      Repo.aggregate(
        from(d in AgentDesign, where: d.user_id == ^ctx.alice.id and d.status == :open),
        :count
      )

  describe "the kinds" do
    test "slots and tools" do
      assert Kinds.slot(:agent) == :create
      assert Kinds.slot(:squad) == :create
      assert Kinds.slot(:agent_edit) == :edit
      assert Kinds.slot(:squad_edit) == :edit
      assert Kinds.tools(:agent) == ~w(get_design propose_agent withdraw_agent)
      assert Kinds.tools(:squad) == ~w(get_design propose_agent withdraw_agent propose_squad)
      assert Kinds.tools(:agent_edit) == ~w(get_design propose_agent)
      assert Kinds.tools(:squad_edit) == ~w(get_design propose_agent withdraw_agent propose_squad)
    end
  end

  describe "starting a creation conversation" do
    test "an agent conversation: open, the user message, a queued design run", ctx do
      assert {:ok, view} =
               AgentDesigns.start(ctx.alice_scope, %{
                 helper: "helper",
                 message: "Build a frontend agent with Tailwind"
               })

      assert %{kind: :agent, status: :open, draft: %{"agents" => []}} = view
      assert [%{role: :user, content: "Build a frontend agent with Tailwind"}] = view.messages
      run = Repo.get!(Run, view.current_run.id)
      assert run.status == :queued and is_nil(run.task_id) and run.agent_id == ctx.helper.id
      assert [%{"kind" => "design"}] = run.triggers
      assert design!(view.id).slot == :create
    end

    test "a squad conversation: the empty squad part", ctx do
      view = start_squad_design!(ctx)
      assert view.kind == :squad
      assert %{"name" => nil, "leader" => nil, "members" => []} = view.draft["squad"]
    end

    test "an open creation conversation: design_open with its ID, nothing new", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      runs = Repo.aggregate(Run, :count)

      assert {:error, {:design_open, ^id}} =
               AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "again"})

      assert {:error, {:design_open, ^id}} =
               AgentDesigns.start(ctx.alice_scope, %{
                 helper: "helper",
                 message: "again",
                 kind: "squad"
               })

      assert open_count(ctx) == 1
      assert Repo.aggregate(Run, :count) == runs
    end

    test "an edit conversation does not keep a creation conversation from starting", ctx do
      assert {:ok, edit} = start_kind(ctx.alice_scope, :agent_edit, ctx.target)

      assert {:ok, create} =
               AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "x"})

      assert design!(edit.id).status == :open and design!(create.id).status == :open
      assert open_count(ctx) == 2
    end

    test "edit kinds and unknown kinds are refused by start/2 with a kind error", ctx do
      for kind <- ["agent_edit", "squad_edit", "tasks", "team"] do
        assert {:error, %Ecto.Changeset{errors: [kind: _]}} =
                 AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "x", kind: kind})
      end

      assert open_count(ctx) == 0
    end

    test "the helper cannot be dispatched: no conversation", ctx do
      {_bob, bob_scope} = member_scope_fixture(ctx.workspace)

      Helmsman.AgentsFixtures.managed_agent_fixture(bob_scope, %{
        name: "bob-helper",
        runtime_id: nil,
        access: "owner_only"
      })

      assert {:error, :unauthorized} =
               AgentDesigns.start(ctx.alice_scope, %{helper: "bob-helper", message: "x"})

      assert open_count(ctx) == 0
    end

    test "a run token cannot start a conversation", ctx do
      %{id: id} = start_design!(ctx.alice_scope)
      {scope, _token} = design_run_scope!(ctx, id)
      assert {:error, :forbidden} = AgentDesigns.start(scope, %{helper: "helper", message: "x"})
    end
  end

  describe "three slots" do
    test "one per slot; a second in the edit slot gets that conversation's ID", ctx do
      %{id: _squad} = start_squad_design!(ctx)
      assert {:ok, %{id: edit}} = start_kind(ctx.alice_scope, :agent_edit, ctx.target)

      assert {:error, {:design_open, ^edit}} =
               start_kind(ctx.alice_scope, :squad_edit, ctx.target)

      assert open_count(ctx) == 2
    end

    test "current/2 by slot; current/1 is the create slot", ctx do
      assert {:ok, nil} = AgentDesigns.current(ctx.alice_scope, :edit)
      %{id: create} = start_design!(ctx.alice_scope)
      assert {:ok, nil} = AgentDesigns.current(ctx.alice_scope, :edit)
      {:ok, %{id: edit}} = start_kind(ctx.alice_scope, :agent_edit, ctx.target)

      assert {:ok, %{id: ^create}} = AgentDesigns.current(ctx.alice_scope)
      assert {:ok, %{id: ^create}} = AgentDesigns.current(ctx.alice_scope, :create)

      assert {:ok, %{id: ^edit, kind: :agent_edit, target: %{name: "fe-dev"}}} =
               AgentDesigns.current(ctx.alice_scope, :edit)
    end

    test "the creation view has no target; the edit view has its target and baseline", ctx do
      {:ok, create} = AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "x"})
      assert %{target: nil, baseline: nil, changes: [], applied: nil} = create
      {:ok, edit} = start_kind(ctx.alice_scope, :agent_edit, ctx.target)
      assert %{target: %{id: id, kind: :agent}, baseline: %{"agent" => _}} = edit
      assert id == ctx.target.id
    end
  end
end

defmodule Helmsman.AgentDesigns.SlotsRaceTest do
  # add-edit-design-conversations 1.2: two starts in one slot at once, on
  # connections of their own: one conversation.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.AgentDesigns.AgentDesign
  alias Helmsman.{CommittedData, Repo}

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = design_fixture()
        Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{name: "fe-dev"})
        Map.put(ctx, :target, agent_actor(ctx.workspace, "fe-dev"))
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  test "both past the slot check: one edit conversation, the other design_open", ctx do
    parent = self()

    tasks =
      for kind <- [:agent_edit, :squad_edit] do
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            Process.put(:helmsman_test_hook, fn
              :design_start_checked ->
                send(parent, {:paused, self()})

                receive do
                  :go -> :ok
                end

              _other ->
                :ok
            end)

            start_kind(ctx.alice_scope, kind, ctx.target)
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:paused, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [{:ok, %{id: id}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, {:design_open, id}} in results

    assert CommittedData.unboxed(fn ->
             Repo.aggregate(from(d in AgentDesign, where: d.user_id == ^ctx.alice.id), :count)
           end) == 1
  end
end
