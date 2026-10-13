defmodule Helmsman.SquadsFixtures do
  @moduledoc """
  Test helpers for `add-squads`: `squad_fixture/2` and a workspace with a
  squad (`squads_fixture/1`).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Squads

  @doc """
  Creates a squad as `scope` (`Helmsman.Squads.create/2`) and returns its
  view. `attrs`: those of `create/2`; `leader` defaults to a new managed
  agent of the scope's user, `name` to a unique name.
  """
  def squad_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)

    leader =
      Map.get_lazy(attrs, :leader, fn ->
        managed_agent_fixture(scope, %{access: "workspace"}).name
      end)

    {:ok, view} =
      Squads.create(
        scope,
        Map.merge(
          %{name: "squad-#{System.unique_integer([:positive])}", leader: leader, members: []},
          Map.put(attrs, :leader, leader)
        )
      )

    view
  end

  @doc """
  `dispatch_fixture/1` (alice, owner, with her project and `keel/dev`)
  plus, on one runtime of alice's, the managed agents `keel/lead`
  (`workspace`), `keel/fe` and `keel/review` (`workspace`) and `keel/qa`
  (`owner_only`), each with its own model and effort; bob (member) and
  carol (member); and the squad `web-team` led by `keel/lead` with the
  members `keel/fe`, `keel/review`, `keel/qa` and bob, in that order.
  `opts` merge into the squad's attributes.
  """
  def squads_fixture(opts \\ %{}) do
    ctx = dispatch_fixture(%{access: "workspace"})
    runtime_id = profile(ctx.agent).runtime_id
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)

    agent = fn name, access, model, effort ->
      managed_agent_fixture(ctx.alice_scope, %{
        name: name,
        runtime_id: runtime_id,
        access: access,
        model: model,
        effort: effort,
        description: "#{name} works on the web app"
      })

      agent_actor(ctx.workspace, name)
    end

    lead = agent.("keel/lead", "workspace", "opus", "high")
    fe = agent.("keel/fe", "workspace", "sonnet", "high")
    review = agent.("keel/review", "workspace", "opus", "medium")
    qa = agent.("keel/qa", "owner_only", "haiku", "low")

    squad =
      squad_fixture(
        ctx.alice_scope,
        Map.merge(
          %{
            name: "web-team",
            leader: "keel/lead",
            description: "Builds the web app",
            instructions: "Ship small pull requests.",
            members: [
              %{name: "keel/fe", role_note: "Writes the frontend"},
              %{name: "keel/review", role_note: "Reviews"},
              %{name: "keel/qa", role_note: "Tests"},
              %{
                name: human_actor(ctx.workspace, bob).name,
                role_note: "Decides product questions"
              }
            ]
          },
          Map.new(opts)
        )
      )

    Map.merge(ctx, %{
      bob: bob,
      bob_scope: bob_scope,
      carol: carol,
      carol_scope: carol_scope,
      runtime_id: runtime_id,
      lead: lead,
      fe: fe,
      review: review,
      qa: qa,
      squad: squad,
      squad_actor: agent_actor(ctx.workspace, squad.name)
    })
  end
end
