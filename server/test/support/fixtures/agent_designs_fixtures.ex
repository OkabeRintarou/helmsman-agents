defmodule Helmsman.AgentDesignsFixtures do
  @moduledoc """
  Test helpers for creation conversations (add-agent-conversation): alice
  (owner) with her online Claude runtime (models fable, opus, sonnet) and
  her managed agent `helper` bound to it.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage}
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.Run

  @doc """
  `%{alice, workspace, alice_scope, daemon, runtime, helper}`; `helper_attrs`
  go to the helper agent.
  """
  def design_fixture(helper_attrs \\ %{}) do
    alice = user_fixture()
    workspace = workspace_fixture(alice)
    alice_scope = workspace_scope_fixture(alice, workspace)
    {daemon, _token} = daemon_fixture(alice, %{workspace_ids: [workspace.id], name: "alice-mbp"})

    runtime =
      runtime_fixture(workspace, daemon, %{
        models: ["fable", "opus", "sonnet"],
        efforts: ["low", "medium", "high"]
      })

    managed_agent_fixture(
      alice_scope,
      Map.merge(%{name: "helper", runtime_id: runtime.id, provider: "claude"}, helper_attrs)
    )

    %{
      alice: alice,
      workspace: workspace,
      alice_scope: alice_scope,
      daemon: daemon,
      runtime: runtime,
      helper: agent_actor(workspace, "helper")
    }
  end

  @doc """
  Starts a `squad` conversation of `scope` (add-squads decision 12); its
  first turn settled, so the user may edit the draft. The view.
  """
  def start_squad_design!(ctx, message \\ "Build a web squad") do
    {:ok, view} =
      AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: message, kind: "squad"})

    view
  end

  @doc "Starts a conversation of `scope` with `helper` and `message`; the view."
  def start_design!(scope, message \\ "Help me create a frontend agent", helper \\ "helper") do
    {:ok, view} = AgentDesigns.start(scope, %{helper: helper, message: message})
    view
  end

  @doc """
  Opens a conversation of any `kind` through the shared start
  (`AgentDesigns.start_conversation/4`): an edit kind targets `target` (an
  actor) with an empty baseline. `{:ok, view}` or the error.
  """
  def start_kind(scope, kind, target \\ nil, message \\ "Change it", helper \\ "helper") do
    AgentDesigns.start_conversation(scope, kind, %{helper: helper, message: message}, fn _ ->
      if target,
        do:
          {:ok, %{"agents" => []},
           [target_actor_id: target.id, baseline: %{"agent" => %{"name" => target.name}}]},
        else: {:ok, %{"agents" => []}, []}
    end)
  end

  @doc """
  `add-edit-design-conversations`: `design_fixture/1` with a helper every
  member may trigger, plus alice's `fe-dev` (on her runtime: sonnet, high,
  instructions of two lines), carol (admin), bob (member), dan (viewer)
  and the squad `web-team` led by alice's `web-lead` with the members
  `fe-dev` (「前端」) and bob. Scopes are `<name>_scope`.
  """
  def edit_fixture do
    ctx = design_fixture(%{access: "workspace"})
    {carol, carol_scope} = member_scope_fixture(ctx.workspace, :admin)
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {dan, dan_scope} = member_scope_fixture(ctx.workspace, :viewer)

    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
      name: "fe-dev",
      runtime_id: ctx.runtime.id,
      model: "sonnet",
      effort: "high",
      description: "Builds the web UI",
      instructions: "You build the web UI.\nUse Tailwind."
    })

    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
      name: "web-lead",
      runtime_id: ctx.runtime.id,
      access: "workspace"
    })

    bob_actor = human_actor(ctx.workspace, bob)

    Helmsman.SquadsFixtures.squad_fixture(ctx.alice_scope, %{
      name: "web-team",
      leader: "web-lead",
      description: "The web squad",
      instructions: "Ship the web app.",
      members: [%{name: "fe-dev", role_note: "前端"}, %{name: bob_actor.name, role_note: ""}]
    })

    Map.merge(ctx, %{
      carol: carol,
      carol_scope: carol_scope,
      bob: bob,
      bob_name: bob_actor.name,
      bob_scope: bob_scope,
      dan: dan,
      dan_scope: dan_scope,
      fe_dev: agent_actor(ctx.workspace, "fe-dev"),
      squad: agent_actor(ctx.workspace, "web-team")
    })
  end

  @doc "Starts an edit conversation of `scope` on `target`; the view."
  def start_edit!(scope, target, message \\ "Change it", helper \\ "helper") do
    {:ok, view} =
      AgentDesigns.start_edit(scope, %{target: target, helper: helper, message: message})

    view
  end

  @doc "The conversation row `id`."
  def design!(id), do: Repo.get!(AgentDesign, id)

  @doc "The current run of the conversation `id`."
  def current_run!(id), do: Repo.get!(Run, design!(id).current_run_id)

  @doc "The messages of the conversation `id`, in order."
  def messages!(id),
    do: Repo.all(from(m in AgentDesignMessage, where: m.design_id == ^id, order_by: m.seq))

  @doc "The design runs of the conversation `id` (by its user messages), oldest first."
  def design_runs!(id) do
    ids = for %{role: :user, run_id: run_id} <- messages!(id), do: run_id
    Repo.all(from(r in Run, where: r.id in ^ids, order_by: r.id))
  end

  @doc "Moves the current run of `id` to `running` on alice's daemon (claimed, started)."
  def run_turn!(ctx, id) do
    run = current_run!(id)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [status: :running, daemon_id: ctx.daemon.id, claimed_at: DateTime.utc_now()]
    )

    Repo.get!(Run, run.id)
  end

  @doc """
  Ends the run `run` (`status`, with `changes`) through the lifecycle's
  single exit and settles it as the job would.
  """
  def end_and_settle!(%Run{} = run, status, changes \\ []) do
    {:ok, _} =
      Helmsman.Tx.run(fn ->
        run = Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))
        {:ok, Runs.Lifecycle.end!(run, status, changes)}
      end)

    AgentDesigns.settle(run.id)
  end

  @doc "A run-token scope of a design run of `id` (its current run, set `running`)."
  def design_run_scope!(ctx, id) do
    run = run_turn!(ctx, id)
    run_scope_fixture(run)
  end
end
