defmodule Helmsman.RunsFixtures do
  @moduledoc """
  Test helpers for dispatch: a workspace with a managed agent, runs
  inserted in any status and run-token scopes.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, RunTokens}

  @doc """
  alice (owner) with a project and her managed agent `keel/dev` (bound to
  an online runtime, `owner_only` unless `agent_attrs` say otherwise).
  """
  def dispatch_fixture(agent_attrs \\ %{}) do
    alice = user_fixture()
    workspace = workspace_fixture(alice)
    alice_scope = workspace_scope_fixture(alice, workspace)
    project = project_fixture(alice_scope)
    managed_agent_fixture(alice_scope, Map.merge(%{name: "keel/dev"}, agent_attrs))

    %{
      alice: alice,
      workspace: workspace,
      alice_scope: alice_scope,
      project: project,
      agent: agent_actor(workspace, "keel/dev")
    }
  end

  @doc "A member of `workspace` with their scope: `{user, scope}`."
  def member_scope_fixture(workspace, role \\ :member) do
    user = user_fixture()
    member_fixture(workspace, user, role)
    {user, workspace_scope_fixture(user, workspace)}
  end

  @doc "The actor `name` of `workspace`."
  def agent_actor(workspace, name),
    do: Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace.id and a.name == ^name))

  @doc "The profile of the agent actor."
  def profile(%Actor{id: id}), do: Repo.one!(from(p in AgentProfile, where: p.actor_id == ^id))

  @doc """
  Inserts a run of `agent` (an actor with a profile) directly, `queued`
  by default.
  """
  def run_fixture(%Actor{} = agent, attrs \\ %{}) do
    profile = profile(agent)

    Repo.insert!(
      struct!(
        %Run{
          workspace_id: agent.workspace_id,
          agent_id: agent.id,
          runtime_id: profile.runtime_id,
          lane: :work,
          status: :queued,
          triggers: [],
          root_initiator_user_id: agent.owner_id,
          causal_agent_ids: [agent.id],
          capabilities: ["read"],
          priority: 2
        },
        attrs
      )
    )
  end

  @doc """
  The scope of a run token of `run` (which must be `claimed`, `running`
  or `cancelling`), and the token.
  """
  def run_scope_fixture(%Run{} = run) do
    {:ok, token} = RunTokens.issue(run)
    {:ok, scope} = RunTokens.scope(token)
    {scope, token}
  end

  @doc "Every run of the task `task_id`, oldest first."
  def runs_of(task_id),
    do: Repo.all(from(r in Run, where: r.task_id == ^task_id, order_by: [asc: r.id]))
end
