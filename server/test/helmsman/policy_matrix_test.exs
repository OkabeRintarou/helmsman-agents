defmodule Helmsman.PolicyMatrixTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Policy
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace

  @workspace %Workspace{id: 1, slug: "acme", name: "Acme"}
  @user %User{id: 10}
  @human %Actor{id: 100, workspace_id: 1, kind: :human, user_id: 10}
  @agent %Actor{id: 200, workspace_id: 1, kind: :agent, owner_id: 10}

  # Resource builders: `fn scope -> resource end`.
  @none &__MODULE__.no_resource/1
  @own_actor &__MODULE__.own_actor/1
  @other_human &__MODULE__.other_human/1
  @system_actor &__MODULE__.system_actor/1
  @own_token %ApiToken{id: 300, workspace_id: 1, user_id: 10}
  @other_token %ApiToken{id: 301, workspace_id: 1, user_id: 11}
  @foreign_token %ApiToken{id: 302, workspace_id: 2, user_id: 10}
  @task %Task{id: 500, workspace_id: 1}
  @other_task %Task{id: 501, workspace_id: 1}

  def no_resource(_scope), do: nil
  def own_actor(scope), do: scope.actor
  def other_human(_scope), do: %Actor{id: 101, workspace_id: 1, kind: :human, user_id: 11}
  def system_actor(_scope), do: %Actor{id: 102, workspace_id: 1, kind: :system, name: "helmsman"}

  # Feedback authors, relative to the scope's user (id 10).
  @own_human @human
  @own_other_agent %Actor{id: 201, workspace_id: 1, kind: :agent, owner_id: 10}
  @others_agent %Actor{id: 202, workspace_id: 1, kind: :agent, owner_id: 11}
  @foreign_own_human %Actor{id: 103, workspace_id: 2, kind: :human, user_id: 10}

  # Runs for :cancel_run / :retry_run, relative to the scope's user (id 10).
  @initiated_run %{initiator_id: 10, agent_owner_id: 11}
  @own_agent_run %{initiator_id: 11, agent_owner_id: 10}
  @unrelated_run %{initiator_id: 11, agent_owner_id: 12}

  @roles [:owner, :admin, :member, :viewer]
  @rank %{owner: 4, admin: 3, member: 2, viewer: 1}

  # {action, role, actor_kind, resource, expected}; `resource` is a value or
  # a builder `fn scope -> resource end`. Later changes append their rows
  # here.
  @matrix [
            for action <- [
                  :view_agents,
                  :manage_agents,
                  :configure_agent,
                  :administer_agent,
                  :manage_runtimes,
                  :list_all_runtimes,
                  :disable_runtime
                ],
                role <- @roles,
                kind <- [:human, :agent],
                owner_id <- [10, 11] do
              resource =
                case action do
                  action when action in [:configure_agent, :administer_agent] ->
                    %Actor{workspace_id: 1, kind: :agent, owner_id: owner_id}

                  :disable_runtime ->
                    %{user_id: owner_id}

                  _ ->
                    %{user_id: owner_id}
                end

              allowed =
                case action do
                  :view_agents ->
                    true

                  action when action in [:manage_agents, :manage_runtimes] ->
                    kind == :human and role != :viewer

                  :list_all_runtimes ->
                    kind == :human and role in [:owner, :admin]

                  :configure_agent ->
                    kind == :human and role != :viewer and owner_id == 10

                  action when action in [:administer_agent, :disable_runtime] ->
                    kind == :human and
                      (role in [:owner, :admin] or (role == :member and owner_id == 10))
                end

              {action, role, kind, resource, if(allowed, do: :ok, else: :forbidden)}
            end,
            for action <- [:read_filters, :create_filter],
                role <- @roles,
                kind <- [:human, :agent] do
              allowed = action == :read_filters or role != :viewer
              {action, role, kind, @none, if(allowed, do: :ok, else: :forbidden)}
            end,
            for action <- [:update_filter, :delete_filter, :change_filter_visibility],
                role <- @roles,
                kind <- [:human, :agent],
                {owner_id, visibility} <- [{10, :private}, {11, :private}, {11, :workspace}] do
              resource = %{workspace_id: 1, owner_id: owner_id, visibility: visibility}

              allowed =
                role != :viewer and
                  (owner_id == 10 or
                     (action != :change_filter_visibility and visibility == :workspace and
                        role in [:owner, :admin]))

              {action, role, kind, resource, if(allowed, do: :ok, else: :forbidden)}
            end,
            # view_workspace: everyone, humans and agents
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              {:view_workspace, role, kind, @none, :ok}
            end,
            # update_workspace: owner and admin humans; agents never
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {:update_workspace, role, kind, @none, expected}
            end,
            # change_workspace_slug: owner humans only
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              expected = if kind == :human and role == :owner, do: :ok, else: :forbidden
              {:change_workspace_slug, role, kind, @none, expected}
            end,
            # rename_own_actor: every role, only the scope's own human identity
            for role <- [:owner, :admin, :member, :viewer] do
              [
                {:rename_own_actor, role, :human, @own_actor, :ok},
                {:rename_own_actor, role, :human, @other_human, :forbidden},
                {:rename_own_actor, role, :human, @system_actor, :forbidden},
                {:rename_own_actor, role, :agent, @own_actor, :forbidden}
              ]
            end,
            # view_members: everyone, humans and agents
            for role <- @roles, kind <- [:human, :agent] do
              {:view_members, role, kind, @none, :ok}
            end,
            # manage_members, manage_invitations (coarse checks before
            # locking): owner and admin humans
            for action <- [:manage_members, :manage_invitations],
                role <- @roles,
                kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {action, role, kind, @none, expected}
            end,
            # create_invitation, revoke_invitation: owner and admin humans,
            # for an invitation role not above their own
            for action <- [:create_invitation, :revoke_invitation],
                role <- @roles,
                kind <- [:human, :agent],
                target <- @roles do
              expected =
                if kind == :human and role in [:owner, :admin] and @rank[target] <= @rank[role],
                  do: :ok,
                  else: :forbidden

              {action, role, kind, target, expected}
            end,
            for action <- [:create_invitation, :revoke_invitation] do
              {action, :owner, :human, @none, :forbidden}
            end,
            # change_member_role on someone else: owners anything; admins
            # neither to nor from owner
            for role <- @roles, from <- @roles, to <- @roles do
              expected =
                cond do
                  role == :owner -> :ok
                  role == :admin and from != :owner and to != :owner -> :ok
                  true -> :forbidden
                end

              {:change_member_role, role, :human, %{from: from, to: to, self?: false}, expected}
            end,
            # change_member_role on oneself: owners and admins may only lower
            # (or keep) their role
            for role <- @roles, to <- @roles do
              expected =
                if role in [:owner, :admin] and @rank[to] <= @rank[role],
                  do: :ok,
                  else: :forbidden

              {:change_member_role, role, :human, %{from: role, to: to, self?: true}, expected}
            end,
            for role <- @roles do
              {:change_member_role, role, :agent, %{from: :viewer, to: :viewer, self?: false},
               :forbidden}
            end,
            {:change_member_role, :owner, :human, @none, :forbidden},
            # remove_member: owners anyone; admins anyone but owners
            for role <- @roles, kind <- [:human, :agent], target <- @roles do
              expected =
                cond do
                  kind == :agent -> :forbidden
                  role == :owner -> :ok
                  role == :admin and target != :owner -> :ok
                  true -> :forbidden
                end

              {:remove_member, role, kind, target, expected}
            end,
            {:remove_member, :owner, :human, @none, :forbidden},
            # leave_workspace: every human; agents never
            for role <- @roles, kind <- [:human, :agent] do
              {:leave_workspace, role, kind, @none, if(kind == :human, do: :ok, else: :forbidden)}
            end,
            # create_token: member and above; agents never
            for role <- @roles, kind <- [:human, :agent] do
              expected = if kind == :human and role != :viewer, do: :ok, else: :forbidden
              {:create_token, role, kind, @none, expected}
            end,
            # list_own_tokens: every human, viewers included
            for role <- @roles, kind <- [:human, :agent] do
              {:list_own_tokens, role, kind, @none, if(kind == :human, do: :ok, else: :forbidden)}
            end,
            # revoke_own_token: every human (the viewers' one write), only
            # their own token of this workspace
            for role <- @roles, kind <- [:human, :agent] do
              [
                {:revoke_own_token, role, kind, @own_token,
                 if(kind == :human, do: :ok, else: :forbidden)},
                {:revoke_own_token, role, kind, @other_token, :forbidden},
                {:revoke_own_token, role, kind, @foreign_token, :forbidden},
                {:revoke_own_token, role, kind, @none, :forbidden}
              ]
            end,
            # list_all_tokens: owner and admin humans
            for role <- @roles, kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {:list_all_tokens, role, kind, @none, expected}
            end,
            # revoke_any_token: owner and admin humans, tokens of this
            # workspace
            for role <- @roles, kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden

              [
                {:revoke_any_token, role, kind, @other_token, expected},
                {:revoke_any_token, role, kind, @own_token, expected},
                {:revoke_any_token, role, kind, @foreign_token, :forbidden},
                {:revoke_any_token, role, kind, @none, :forbidden}
              ]
            end,
            # identify: member and above, agents too (not a management
            # action); viewers never
            for role <- @roles, kind <- [:human, :agent] do
              {:identify, role, kind, @none, if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # read_tasks: everyone, humans and agents
            for role <- @roles, kind <- [:human, :agent] do
              {:read_tasks, role, kind, @none, :ok}
            end,
            # create/update/archive_project: owner and admin; not management
            # actions, so an admin's agent may too
            for action <- [:create_project, :update_project, :archive_project],
                role <- @roles,
                kind <- [:human, :agent] do
              {action, role, kind, @none, if(role in [:owner, :admin], do: :ok, else: :forbidden)}
            end,
            # create_task, update_task: member and above, agents too
            for action <- [:create_task, :update_task],
                role <- @roles,
                kind <- [:human, :agent] do
              {action, role, kind, @none, if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # transition_task: member and above, agents too (not management)
            for role <- @roles, kind <- [:human, :agent] do
              {:transition_task, role, kind, @none,
               if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # link_tasks: member and above, agents too (not management)
            for role <- @roles, kind <- [:human, :agent] do
              {:link_tasks, role, kind, @none, if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # add_feedback: member and above, agents too
            for role <- @roles, kind <- [:human, :agent] do
              {:add_feedback, role, kind, @none, if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # revise_feedback: member and above, on records of their own
            # identity or another identity of the same user; never the
            # system's, never someone else's (whatever the role)
            for role <- @roles, kind <- [:human, :agent] do
              member? = role != :viewer
              same_user = if member?, do: :ok, else: :forbidden

              [
                {:revise_feedback, role, kind, @own_actor, same_user},
                {:revise_feedback, role, kind, @own_human, same_user},
                {:revise_feedback, role, kind, @agent, same_user},
                {:revise_feedback, role, kind, @own_other_agent, same_user},
                {:revise_feedback, role, kind, @other_human, :forbidden},
                {:revise_feedback, role, kind, @others_agent, :forbidden},
                {:revise_feedback, role, kind, @system_actor, :forbidden},
                {:revise_feedback, role, kind, @foreign_own_human, :forbidden},
                {:revise_feedback, role, kind, @none, :forbidden}
              ]
            end,
            # manage_github: owner and admin humans; agents never
            for role <- @roles, kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {:manage_github, role, kind, @none, expected}
            end,
            # merge_pull_request: member and above, people only
            for role <- @roles, kind <- [:human, :agent] do
              expected = if kind == :human and role != :viewer, do: :ok, else: :forbidden
              {:merge_pull_request, role, kind, @none, expected}
            end,
            # manage_github_app: instance administrators only, whatever the
            # workspace role (see the test below); the matrix user is not one
            for role <- @roles, kind <- [:human, :agent] do
              {:manage_github_app, role, kind, @none, :forbidden}
            end,
            # run_agent: member and above, agents too (an external agent
            # with an hm_ token; run tokens are refused by Dispatch and by
            # the run gate below)
            for role <- @roles, kind <- [:human, :agent] do
              {:run_agent, role, kind, @none, if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # view_runs: everyone
            for role <- @roles, kind <- [:human, :agent] do
              {:view_runs, role, kind, @none, :ok}
            end,
            # view_run_events: member and above
            for role <- @roles, kind <- [:human, :agent] do
              {:view_run_events, role, kind, @none,
               if(role == :viewer, do: :forbidden, else: :ok)}
            end,
            # cancel_run / retry_run: admin and above, or a member who is the
            # run's authorization source or owns its agent
            for action <- [:cancel_run, :retry_run],
                role <- @roles,
                kind <- [:human, :agent],
                {run, related?} <- [
                  {@initiated_run, true},
                  {@own_agent_run, true},
                  {@unrelated_run, false}
                ] do
              expected =
                cond do
                  role in [:owner, :admin] -> :ok
                  role == :member and related? -> :ok
                  true -> :forbidden
                end

              {action, role, kind, run, expected}
            end,
            # write_task outside runs: the coarse action checked the role
            for role <- @roles, kind <- [:human, :agent] do
              {:write_task, role, kind, @task, :ok}
            end,
            # manage_provider_accounts: the user's own web session, whatever
            # the role; never an agent (test/helmsman/policy_test.exs)
            for role <- @roles, kind <- [:human, :agent] do
              {:manage_provider_accounts, role, kind, @none,
               if(kind == :human, do: :ok, else: :forbidden)}
            end,
            # design_agents: a person's own web session, member and above
            # (add-agent-conversation decision 6; tokens and runs in
            # test/helmsman/policy_test.exs)
            for role <- @roles, kind <- [:human, :agent] do
              {:design_agents, role, kind, @none,
               if(kind == :human and role != :viewer, do: :ok, else: :forbidden)}
            end,
            # design: only run scopes with the capability (policy_test.exs)
            for role <- @roles, kind <- [:human, :agent] do
              {:design, role, kind, @none, :forbidden}
            end,
            # manage_squads (add-squads decision 3): the coarse check is member
            # and above; with the leader, admin and above or the leader's owner;
            # agents never
            for role <- @roles, kind <- [:human, :agent], owner_id <- [nil, 10, 11] do
              resource =
                if owner_id, do: %Actor{workspace_id: 1, kind: :agent, owner_id: owner_id}

              allowed =
                kind == :human and
                  (role in [:owner, :admin] or
                     (role == :member and owner_id in [nil, 10]))

              {:manage_squads, role, kind, resource, if(allowed, do: :ok, else: :forbidden)}
            end,
            # delegate: only run scopes with the capability (squads tests)
            for role <- @roles, kind <- [:human, :agent] do
              {:delegate, role, kind, @none, :forbidden}
            end
          ]
          |> List.flatten()

  defp resolve(builder, scope) when is_function(builder, 1), do: builder.(scope)
  defp resolve(resource, _scope), do: resource

  defp scope(role, kind) do
    actor = if kind == :agent, do: @agent, else: @human

    %Scope{user: @user, workspace: @workspace, role: role, actor: actor, via: :web}
  end

  for {action, role, kind, resource, expected} <- @matrix do
    @resource resource
    @tag action: action
    test "#{action} by #{role} #{kind} via #{inspect(resource)} → #{expected}" do
      scope = scope(unquote(role), unquote(kind))
      resource = resolve(@resource, scope)
      expected = if unquote(expected) == :ok, do: :ok, else: {:error, :forbidden}

      assert Policy.authorize(scope, unquote(action), resource) == expected
    end
  end

  test "every action with a rule is covered by the matrix" do
    covered = @matrix |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.new(Policy.actions()) == covered
  end

  test "agents are refused every management action, whatever the role" do
    for action <- Policy.management_actions(), role <- [:owner, :admin, :member, :viewer] do
      assert Policy.authorize(scope(role, :agent), action) == {:error, :forbidden},
             "#{action} by #{role} agent"
    end
  end

  describe "member role changes from the spec" do
    defp change(role, from, to, self?) do
      Policy.authorize(scope(role, :human), :change_member_role, %{
        from: from,
        to: to,
        self?: self?
      })
    end

    test "owner promotes an admin to owner",
      do: assert(change(:owner, :admin, :owner, false) == :ok)

    test "admin demotes an owner",
      do: assert(change(:admin, :owner, :member, false) == {:error, :forbidden})

    test "admin demotes themselves", do: assert(change(:admin, :admin, :member, true) == :ok)

    test "admin makes themselves owner",
      do: assert(change(:admin, :admin, :owner, true) == {:error, :forbidden})

    test "member makes themselves viewer",
      do: assert(change(:member, :member, :viewer, true) == {:error, :forbidden})

    test "owner demotes themselves (the last-owner rule is checked by Members)",
      do: assert(change(:owner, :owner, :admin, true) == :ok)
  end

  test "token actions are management actions; identify is not" do
    management = MapSet.new(Policy.management_actions())

    for action <- [
          :create_token,
          :list_own_tokens,
          :revoke_own_token,
          :list_all_tokens,
          :revoke_any_token
        ] do
      assert action in management
    end

    refute :identify in management
  end

  test "project and task actions are not management actions" do
    management = MapSet.new(Policy.management_actions())

    for action <- [
          :read_tasks,
          :create_project,
          :update_project,
          :archive_project,
          :create_task,
          :update_task,
          :transition_task,
          :add_feedback,
          :revise_feedback,
          :link_tasks
        ] do
      refute action in management
    end
  end

  test "token-authenticated scopes (no actor) follow the role" do
    scope = %Scope{user: @user, workspace: @workspace, role: :member, actor: nil, via: :mcp}
    assert Policy.authorize(scope, :create_token) == :ok
    assert Policy.authorize(scope, :identify) == :ok
    assert Policy.authorize(scope, :revoke_own_token, @own_token) == :ok
    assert Policy.authorize(scope, :revoke_any_token, @other_token) == {:error, :forbidden}
    assert Policy.authorize(%{scope | role: :viewer}, :identify) == {:error, :forbidden}
  end

  test "manage_github_app: instance administrators, without a workspace too; never agents" do
    admin = %User{id: 10, instance_admin: true}

    assert Policy.authorize(%Scope{user: admin}, :manage_github_app) == :ok
    assert Policy.authorize(%{scope(:viewer, :human) | user: admin}, :manage_github_app) == :ok

    assert Policy.authorize(%{scope(:owner, :agent) | user: admin}, :manage_github_app) ==
             {:error, :forbidden}

    assert Policy.authorize(%Scope{user: @user}, :manage_github_app) == {:error, :forbidden}
    assert :manage_github_app in Policy.management_actions()
  end

  test "unknown actions and scopes without a role are refused" do
    assert Policy.authorize(scope(:owner, :human), :launch_rockets) == {:error, :forbidden}
    assert Policy.authorize(%Scope{user: @user}, :view_workspace) == {:error, :forbidden}
  end

  describe "run scopes (designs/13 §2.3)" do
    @read_actions [:view_workspace, :view_members, :read_tasks, :view_agents, :view_runs]

    test "a run token reads run events with read and the owner's role; never stops or retries" do
      for role <- [:owner, :member, :viewer] do
        scope = run_scope(role, ["read", "write_task"], 500)
        expected = if role == :viewer, do: {:error, :forbidden}, else: :ok
        assert Policy.authorize(scope, :view_run_events) == expected

        for action <- [:cancel_run, :retry_run], run <- [@initiated_run, @own_agent_run] do
          assert Policy.authorize(scope, action, run) == {:error, :forbidden}
        end
      end
    end

    @write_actions [:update_task, :transition_task, :add_feedback]
    @refused [
      :run_agent,
      :create_project,
      :update_project,
      :archive_project,
      :rename_own_actor,
      :leave_workspace,
      :create_token,
      :manage_agents,
      :manage_github,
      :merge_pull_request
    ]

    defp run_scope(role, caps, task_id) do
      %Scope{
        user: @user,
        workspace: @workspace,
        role: role,
        actor: @agent,
        via: :run,
        run: %Run{id: 900, task_id: task_id, capabilities: caps}
      }
    end

    test "capabilities × own task / other task / no task, then the owner's role" do
      for role <- [:owner, :member, :viewer],
          caps <- [
            ["read"],
            ["read", "write_task"],
            ["read", "create_tasks"],
            ["read", "write_task", "create_tasks"]
          ],
          task_id <- [500, nil] do
        scope = run_scope(role, caps, task_id)
        member? = role != :viewer
        expect = fn allowed -> if allowed, do: :ok, else: {:error, :forbidden} end

        for action <- @read_actions do
          assert Policy.authorize(scope, action) == :ok, "#{action} #{inspect(caps)}"
        end

        assert Policy.authorize(scope, :identify) == expect.(member?)

        for action <- @write_actions do
          assert Policy.authorize(scope, action) == expect.(member? and "write_task" in caps),
                 "#{action} #{role} #{inspect(caps)}"
        end

        assert Policy.authorize(scope, :revise_feedback, @agent) ==
                 expect.(member? and "write_task" in caps)

        assert Policy.authorize(scope, :create_task) ==
                 expect.(member? and "create_tasks" in caps)

        own = "write_task" in caps and task_id == 500
        assert Policy.authorize(scope, :write_task, @task) == expect.(own)
        assert Policy.authorize(scope, :write_task, @other_task) == {:error, :forbidden}

        assert Policy.authorize(scope, :link_tasks) == expect.(member? and "write_task" in caps)

        # A link needs the run's own task at one end, either end.
        for pair <- [{@task, @other_task}, {@other_task, @task}] do
          assert Policy.authorize(scope, :link_tasks, pair) ==
                   expect.(member? and "write_task" in caps and task_id == 500)
        end

        assert Policy.authorize(scope, :link_tasks, {@other_task, @other_task}) ==
                 {:error, :forbidden}

        for action <- @refused do
          assert Policy.authorize(scope, action) == {:error, :forbidden}, "#{action}"
        end
      end
    end

    test "a run scope without a run is refused everything" do
      scope = %{run_scope(:owner, ["read"], nil) | run: nil}
      assert Policy.authorize(scope, :read_tasks) == {:error, :forbidden}
    end
  end
end
