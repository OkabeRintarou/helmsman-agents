defmodule Helmsman.Policy do
  @moduledoc """
  The single authorization check for domain operations.

  Every domain function checks `authorize/3` before any side effect. Each
  action has its own clause; unknown actions are refused. Agents inherit
  their owner's role but can never perform management actions. A run
  scope (`via: :run`) is further limited by its run's capabilities, and
  `:write_task` limits its writes to the run's own task.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @type action :: atom()

  # Every management action, listed once. Later changes reference this list
  # instead of redefining it.
  @management_actions [
    # members and invitations
    :manage_members,
    :manage_invitations,
    :create_invitation,
    :revoke_invitation,
    :change_member_role,
    :remove_member,
    :leave_workspace,
    # agent configuration, tokens, runtimes
    :manage_agents,
    :manage_tokens,
    :create_token,
    :list_own_tokens,
    :revoke_own_token,
    :list_all_tokens,
    :revoke_any_token,
    :manage_runtimes,
    :configure_agent,
    :administer_agent,
    :list_all_runtimes,
    :disable_runtime,
    # squads and autopilots (automation)
    :manage_squads,
    :manage_autopilots,
    # GitHub connection
    :manage_github,
    # the instance's GitHub App (instance administrators)
    :manage_github_app,
    # import and export
    :import_workspace,
    :export_workspace,
    # workspace settings
    :change_workspace_slug,
    :update_workspace,
    # the user's own provider accounts (no workspace)
    :manage_provider_accounts,
    # creation conversations and confirming their drafts
    # (`add-agent-conversation` decision 6)
    :design_agents
  ]

  # Actions with an authorization clause below.
  @actions [
    :view_agents,
    :manage_agents,
    :configure_agent,
    :administer_agent,
    :manage_runtimes,
    :list_all_runtimes,
    :disable_runtime,
    :view_workspace,
    :update_workspace,
    :change_workspace_slug,
    :rename_own_actor,
    :view_members,
    :manage_members,
    :manage_invitations,
    :create_invitation,
    :revoke_invitation,
    :change_member_role,
    :remove_member,
    :leave_workspace,
    :create_token,
    :list_own_tokens,
    :revoke_own_token,
    :list_all_tokens,
    :revoke_any_token,
    :identify,
    :read_tasks,
    :create_project,
    :update_project,
    :archive_project,
    :create_task,
    :update_task,
    :transition_task,
    :add_feedback,
    :revise_feedback,
    :manage_github,
    :manage_github_app,
    :manage_provider_accounts,
    :merge_pull_request,
    :run_agent,
    :view_runs,
    :view_run_events,
    :cancel_run,
    :retry_run,
    :write_task,
    :link_tasks,
    :design_agents,
    :design
  ]

  # The capability a run token needs for each action it may attempt; any
  # other action is refused (designs/13 §2.3).
  @run_capability %{
    view_workspace: "read",
    view_members: "read",
    read_tasks: "read",
    view_agents: "read",
    view_runs: "read",
    view_run_events: "read",
    identify: "read",
    create_task: "create_tasks",
    update_task: "write_task",
    transition_task: "write_task",
    add_feedback: "write_task",
    revise_feedback: "write_task",
    write_task: "write_task",
    link_tasks: "write_task",
    design: "design"
  }

  @role_rank %{owner: 4, admin: 3, member: 2, viewer: 1}

  @doc "Management actions, which agents may never perform."
  @spec management_actions() :: [action()]
  def management_actions, do: @management_actions

  @doc "Actions that have an authorization rule."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  Checks whether `scope` may perform `action` on `resource`.
  """
  @spec authorize(Scope.t(), action(), term()) :: :ok | {:error, :forbidden}
  def authorize(scope, action, resource \\ nil)

  def authorize(%Scope{actor: %Actor{kind: :agent}}, action, _resource)
      when action in @management_actions,
      do: {:error, :forbidden}

  # People only (designs/15 §6): no agent identity, whatever the
  # credential, though not a management action.
  def authorize(%Scope{actor: %Actor{kind: kind}}, :merge_pull_request, _resource)
      when kind != :human,
      do: {:error, :forbidden}

  # A run token can only do what its run's capabilities allow (designs/13
  # §2.3); then the owner's role decides, as for any agent.
  def authorize(%Scope{via: :run} = scope, action, resource) do
    with :ok <- run_gate(scope, action), do: check(scope, action, resource)
  end

  def authorize(scope, action, resource), do: check(scope, action, resource)

  defp run_gate(%Scope{run: %Run{capabilities: caps}}, action) do
    allow_if(Map.has_key?(@run_capability, action) and @run_capability[action] in caps)
  end

  defp run_gate(_scope, _action), do: {:error, :forbidden}

  defp check(%Scope{} = scope, :view_workspace, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  defp check(%Scope{} = scope, :update_workspace, _resource),
    do: allow_if(role_at_least?(scope, :admin))

  defp check(%Scope{} = scope, :change_workspace_slug, _resource),
    do: allow_if(role_at_least?(scope, :owner))

  # Viewers too may rename their own human identity.
  defp check(%Scope{} = scope, :rename_own_actor, %Actor{} = actor),
    do: allow_if(role_at_least?(scope, :viewer) and own_human?(scope, actor))

  ## Members and invitations

  defp check(%Scope{} = scope, :view_members, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  # Coarse checks before the rows a member operation depends on are locked;
  # the operation then authorizes the precise action below.
  defp check(%Scope{} = scope, action, _resource)
       when action in [:manage_members, :manage_invitations],
       do: allow_if(role_at_least?(scope, :admin))

  # `role`: the role the invitation grants. Never above the inviter's own.
  defp check(%Scope{} = scope, action, role)
       when action in [:create_invitation, :revoke_invitation],
       do: allow_if(role_at_least?(scope, :admin) and not_above_own?(scope, role))

  # Only owners touch the owner role; changing one's own role may only
  # lower it.
  defp check(%Scope{} = scope, :change_member_role, %{from: from, to: to, self?: self?})
       when is_map_key(@role_rank, from) and is_map_key(@role_rank, to) and is_boolean(self?) do
    allow_if(
      role_at_least?(scope, :admin) and
        (scope.role == :owner or (from != :owner and to != :owner)) and
        (not self? or @role_rank[to] <= @role_rank[from])
    )
  end

  # `role`: the target's current role. Leaving is `:leave_workspace`.
  defp check(%Scope{} = scope, :remove_member, role) when is_map_key(@role_rank, role),
    do: allow_if(role_at_least?(scope, :admin) and (scope.role == :owner or role != :owner))

  defp check(%Scope{} = scope, :leave_workspace, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  ## API tokens (agents never: all are management actions)

  defp check(%Scope{} = scope, :create_token, _resource),
    do: allow_if(role_at_least?(scope, :member))

  # Viewers too: a demoted user must still be able to see and revoke the
  # credentials they issued.
  defp check(%Scope{} = scope, :list_own_tokens, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  defp check(%Scope{} = scope, :revoke_own_token, %ApiToken{} = token),
    do: allow_if(role_at_least?(scope, :viewer) and own_token?(scope, token))

  defp check(%Scope{} = scope, :list_all_tokens, _resource),
    do: allow_if(role_at_least?(scope, :admin))

  defp check(%Scope{} = scope, :revoke_any_token, %ApiToken{} = token),
    do: allow_if(role_at_least?(scope, :admin) and in_workspace?(scope, token))

  defp check(%Scope{} = scope, :view_agents, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  defp check(%Scope{} = scope, action, _resource)
       when action in [:manage_agents, :manage_runtimes],
       do: allow_if(role_at_least?(scope, :member))

  defp check(%Scope{} = scope, :list_all_runtimes, _resource),
    do: allow_if(role_at_least?(scope, :admin))

  defp check(%Scope{} = scope, :configure_agent, %Actor{kind: :agent} = actor),
    do:
      allow_if(
        in_workspace?(scope, actor) and role_at_least?(scope, :member) and
          same_user?(scope, actor)
      )

  defp check(%Scope{} = scope, :administer_agent, %Actor{kind: :agent} = actor),
    do:
      allow_if(
        in_workspace?(scope, actor) and
          (role_at_least?(scope, :admin) or
             (role_at_least?(scope, :member) and same_user?(scope, actor)))
      )

  defp check(%Scope{} = scope, :disable_runtime, %{user_id: owner_id}),
    do:
      allow_if(
        role_at_least?(scope, :admin) or
          (role_at_least?(scope, :member) and scope.user.id == owner_id)
      )

  ## Agent identity

  # Not a management action: the one agents may perform (designs/03 §4).
  defp check(%Scope{} = scope, :identify, _resource),
    do: allow_if(role_at_least?(scope, :member))

  ## Projects and tasks (not management actions: agents act with their
  ## owner's role, designs/08 §3)

  defp check(%Scope{} = scope, :read_tasks, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  defp check(%Scope{} = scope, action, _resource)
       when action in [:create_project, :update_project, :archive_project],
       do: allow_if(role_at_least?(scope, :admin))

  defp check(%Scope{} = scope, action, _resource)
       when action in [:create_task, :update_task, :transition_task],
       do: allow_if(role_at_least?(scope, :member))

  # Task links: `{from, to}` once both task rows are locked. A run may
  # only link its own task to another (designs/13 §2.3).
  defp check(
         %Scope{via: :run, run: %Run{} = run} = scope,
         :link_tasks,
         {%Task{} = a, %Task{} = b}
       ),
       do: allow_if(role_at_least?(scope, :member) and run.task_id in [a.id, b.id])

  defp check(%Scope{} = scope, :link_tasks, _resource),
    do: allow_if(role_at_least?(scope, :member))

  ## Feedback (not management actions)

  defp check(%Scope{} = scope, :add_feedback, _resource),
    do: allow_if(role_at_least?(scope, :member))

  # `author`: the identity that wrote the record. Its author, or another
  # identity of the same user (their human identity, their agents); never
  # a record the system wrote (designs/06).
  defp check(%Scope{} = scope, :revise_feedback, %Actor{} = author),
    do: allow_if(role_at_least?(scope, :member) and may_revise?(scope, author))

  ## GitHub (management actions: agents never)

  # Connecting / disconnecting the installation, binding projects to
  # repositories and their merge settings (designs/15 §6).
  defp check(%Scope{} = scope, :manage_github, _resource),
    do: allow_if(role_at_least?(scope, :admin))

  # Re-verify, merge now, retry a task's pull request (designs/15 §6;
  # skipping the independence check also needs the owner role, checked by
  # `Helmsman.GitHub.PullRequests`).
  defp check(%Scope{} = scope, :merge_pull_request, _resource),
    do: allow_if(role_at_least?(scope, :member))

  # Instance-wide: the GitHub App itself. Needs no workspace.
  defp check(%Scope{user: %User{instance_admin: true}}, :manage_github_app, _resource),
    do: :ok

  ## Provider accounts (`add-provider-accounts` decision 3)

  # Only the user's own web session: never an API token (even a person's),
  # a run or an agent. Needs no workspace; the operation then touches only
  # `scope.user`'s accounts.
  defp check(
         %Scope{user: %User{}, via: via, token: nil, run: nil, actor: actor},
         :manage_provider_accounts,
         _resource
       )
       when via in [nil, :web],
       do: allow_if(is_nil(actor) or actor.kind == :human)

  ## Creation conversations (`add-agent-conversation` decisions 6, 7)

  # Only a person's own web session, member and above: never an API
  # token, a run or an agent.
  defp check(
         %Scope{user: %User{}, via: via, token: nil, run: nil, actor: actor} = scope,
         :design_agents,
         _resource
       )
       when via in [nil, :web],
       do: allow_if((is_nil(actor) or actor.kind == :human) and role_at_least?(scope, :member))

  # The draft tools: a run with the `design` capability (the run gate
  # checked it). Whether the run is still the turn of an open conversation
  # is checked by `Helmsman.AgentDesigns`.
  defp check(%Scope{via: :run, run: %Run{capabilities: caps}}, :design, _resource),
    do: allow_if("design" in caps)

  ## Runs (not management actions)

  defp check(%Scope{} = scope, :run_agent, _resource),
    do: allow_if(role_at_least?(scope, :member))

  defp check(%Scope{} = scope, :view_runs, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  defp check(%Scope{} = scope, :view_run_events, _resource),
    do: allow_if(role_at_least?(scope, :member))

  # `%{initiator_id, agent_owner_id}`: the run's authorization source and
  # its agent's owner (designs/02 §4). A run token never gets here (no
  # capability allows it).
  defp check(%Scope{} = scope, action, %{initiator_id: initiator_id, agent_owner_id: owner_id})
       when action in [:cancel_run, :retry_run] do
    user_id = scope.user && scope.user.id

    allow_if(
      role_at_least?(scope, :admin) or
        (role_at_least?(scope, :member) and not is_nil(user_id) and
           user_id in [initiator_id, owner_id])
    )
  end

  # The coarse action (`:update_task`, ...) checked the role already; a run
  # may only write its own task.
  defp check(%Scope{via: :run, run: %Run{} = run}, :write_task, %Task{id: id}),
    do: allow_if("write_task" in run.capabilities and run.task_id == id)

  defp check(%Scope{}, :write_task, %Task{}), do: :ok

  defp check(_scope, _action, _resource), do: {:error, :forbidden}

  defp may_revise?(_scope, %Actor{kind: :system}), do: false

  defp may_revise?(%Scope{workspace: %{id: ws_id}} = scope, %Actor{workspace_id: ws_id} = author),
    do: own_actor?(scope, author) or same_user?(scope, author)

  defp may_revise?(_scope, _author), do: false

  defp own_actor?(%Scope{actor: %Actor{id: id}}, %Actor{id: id}) when is_integer(id), do: true
  defp own_actor?(_scope, _author), do: false

  defp same_user?(%Scope{user: %{id: id}}, %Actor{kind: :human, user_id: id}) when is_integer(id),
    do: true

  defp same_user?(%Scope{user: %{id: id}}, %Actor{kind: :agent, owner_id: id})
       when is_integer(id),
       do: true

  defp same_user?(_scope, _author), do: false

  defp not_above_own?(%Scope{role: own}, role)
       when is_map_key(@role_rank, own) and is_map_key(@role_rank, role),
       do: @role_rank[role] <= @role_rank[own]

  defp not_above_own?(_scope, _role), do: false

  defp own_human?(%Scope{actor: %Actor{kind: :human, id: id}, workspace: ws}, actor) do
    actor.kind == :human and actor.id == id and actor.workspace_id == ws.id
  end

  defp own_human?(_scope, _actor), do: false

  defp own_token?(%Scope{user: %{id: user_id}} = scope, %ApiToken{user_id: user_id} = token),
    do: in_workspace?(scope, token)

  defp own_token?(_scope, _token), do: false

  defp in_workspace?(%Scope{workspace: %{id: id}}, %{workspace_id: id}), do: true
  defp in_workspace?(_scope, _resource), do: false

  defp role_at_least?(%Scope{role: role}, min) when is_map_key(@role_rank, role),
    do: @role_rank[role] >= @role_rank[min]

  defp role_at_least?(_scope, _min), do: false

  defp allow_if(true), do: :ok
  defp allow_if(false), do: {:error, :forbidden}
end
