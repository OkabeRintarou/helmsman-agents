defmodule HelmsmanWeb.AgentDesignHelpers do
  @moduledoc """
  Shared setup of the agent design page tests (add-agent-conversation-ui D15): a
  workspace of alice (owner) with her managed `helper`, bob (member) and vic (viewer),
  on the real `Helmsman.AgentDesigns`. The AI side writes the draft with the run token
  of the current turn (`propose!/2`); turns end through the run lifecycle and are
  settled as the job does (`Helmsman.AgentDesignsFixtures.end_and_settle!/3`).
  """
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.RunsFixtures, only: [daemon_of: 1, run_scope_fixture: 1]

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, AgentDesignsFixtures, Events, Repo}
  alias Helmsman.AgentDesigns.{AgentDesign, Draft}
  alias Helmsman.Runs.Run

  @endpoint HelmsmanWeb.Endpoint

  def design_setup(%{conn: conn}) do
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Keel #{System.unique_integer([:positive])}"})
    bob = user_fixture(%{display_name: "bob"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, bob, :member)
    member_fixture(ws, vic, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)
    bob_scope = workspace_scope_fixture(bob, ws)
    helper = managed_agent_fixture(alice_scope, %{name: "helper"})

    %{
      conn: conn,
      ws: ws,
      alice: alice,
      bob: bob,
      vic: vic,
      alice_scope: alice_scope,
      bob_scope: bob_scope,
      helper: helper,
      path: "/w/#{ws.slug}/agent-design"
    }
  end

  def open_page(ctx, user \\ nil) do
    conn = HelmsmanWeb.ConnCase.log_in_user(build_conn(), user || ctx.alice)
    {:ok, view, html} = live(conn, ctx.path)
    {view, html}
  end

  @doc "Starts alice's conversation: the view."
  def start!(ctx, message \\ "帮我建一个前端开发 Agent", scope \\ nil) do
    {:ok, view} =
      AgentDesigns.start(scope || ctx.alice_scope, %{helper: "helper", message: message})

    view
  end

  @doc "The conversation row."
  def design!(id), do: AgentDesignsFixtures.design!(id)

  @doc "The current turn's run, `running` on the helper's daemon."
  def running_turn!(id) do
    run = AgentDesignsFixtures.current_run!(id)

    if run.status == :running do
      run
    else
      helper = Repo.get!(Actor, design!(id).helper_agent_id)

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [status: :running, daemon_id: daemon_of(helper).id, claimed_at: DateTime.utc_now()]
      )

      Repo.get!(Run, run.id)
    end
  end

  @doc "The helper proposes (adds or patches) a draft agent during the current turn."
  def propose!(design_id, attrs) do
    {scope, _token} = run_scope(running_turn!(design_id))

    attrs =
      if Map.has_key?(attrs, "name") and
           Enum.any?(
             Draft.agents(design!(design_id).draft),
             &(&1["name"] == attrs["name"])
           ),
         do: attrs,
         else: Map.merge(%{"provider" => "claude", "instructions" => "做前端开发。"}, attrs)

    {:ok, _} = AgentDesigns.propose_agent(scope, attrs)
    :ok
  end

  # One run token per run: the scope is kept for the test process.
  defp run_scope(run) do
    key = {__MODULE__, :run_scope, run.id}

    case Process.get(key) do
      nil -> run |> run_scope_fixture() |> tap(&Process.put(key, &1))
      scope -> scope
    end
  end

  @doc "The current turn ends with the reply `text` (and `usage`) and is settled."
  def reply!(design_id, text, usage \\ nil) do
    changes = [summary: text] ++ if(usage, do: [usage: usage], else: [])
    end_turn!(design_id, :succeeded, changes)
  end

  @doc "The current turn ends with `status` (`changes` to the run) and is settled."
  def end_turn!(design_id, status, changes \\ []) do
    AgentDesignsFixtures.end_and_settle!(
      AgentDesignsFixtures.current_run!(design_id),
      status,
      changes
    )
  end

  @doc "The conversation had no activity for 8 days and expires."
  def expire!(design_id) do
    old = DateTime.add(DateTime.utc_now(), -8, :day)

    Repo.update_all(from(d in AgentDesign, where: d.id == ^design_id),
      set: [last_activity_at: old]
    )

    AgentDesigns.expire()
  end

  @doc "The conversation is gone (deleted) and its subscribers told."
  def delete!(design_id) do
    Repo.delete_all(from(d in AgentDesign, where: d.id == ^design_id))
    Events.broadcast(AgentDesigns.topic(design_id), {:agent_design, design_id})
  end

  @doc """
  Writes the draft agents directly (data the domain no longer accepts, e.g. a runtime
  disabled or not the user's since), and tells the subscribers.
  """
  def put_draft!(design_id, agents) do
    design = design!(design_id)

    Repo.update_all(from(d in AgentDesign, where: d.id == ^design_id),
      set: [draft: %{"agents" => agents}, draft_version: design.draft_version + 1]
    )

    Events.broadcast(AgentDesigns.topic(design_id), {:agent_design, design_id})
  end

  def state(view), do: view.pid |> :sys.get_state() |> inspect(limit: :infinity)

  @doc "The draft version of the conversation now."
  def version(design_id), do: design!(design_id).draft_version

  @doc "The draft agent `name` now (nil when absent)."
  def entry(design_id, name),
    do: Enum.find(design!(design_id).draft["agents"] || [], &(&1["name"] == name))

  @doc "How many user messages the conversation has."
  def user_messages(design_id),
    do: Enum.count(AgentDesignsFixtures.messages!(design_id), &(&1.role == :user))
end
