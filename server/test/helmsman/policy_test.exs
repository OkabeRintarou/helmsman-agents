defmodule Helmsman.PolicyTest do
  # add-provider-accounts 3.2: who may manage provider accounts (decision
  # 3), with the scopes the entry points really build.
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Policy
  alias Helmsman.Runs.Run

  setup do
    dispatch_fixture()
  end

  defp authorize(scope), do: Policy.authorize(scope, :manage_provider_accounts)

  test "the user's own web session passes", ctx do
    assert authorize(Scope.for_user(ctx.alice)) == :ok
    assert ctx.alice_scope.via == :web
    assert authorize(ctx.alice_scope) == :ok
  end

  test "an hm_ token of a person, via MCP or REST, is refused", ctx do
    %{api_token: token} = api_token_fixture(ctx.alice_scope)

    for via <- [:mcp, :api] do
      assert authorize(token_scope_fixture(ctx.alice, ctx.workspace, via, token)) ==
               {:error, :forbidden}
    end
  end

  test "an agent identity is refused", ctx do
    assert authorize(%{ctx.alice_scope | actor: ctx.agent}) == {:error, :forbidden}
  end

  test "a run token is refused, whatever its capabilities", ctx do
    run =
      run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "create_tasks"]})

    {scope, _token} = run_scope_fixture(run)
    assert scope.via == :run and scope.user.id == ctx.alice.id
    assert authorize(scope) == {:error, :forbidden}
  end

  test "a scope without a user, or of another entry point, is refused" do
    assert authorize(%Scope{}) == {:error, :forbidden}

    assert authorize(%Scope{user: %Helmsman.Accounts.User{id: 1}, via: :api}) ==
             {:error, :forbidden}
  end

  test "it is a management action" do
    assert :manage_provider_accounts in Policy.management_actions()
  end

  describe ":manage_autopilots (add-autopilots 1.2, decision 4)" do
    test "a run token is refused every autopilot operation, whatever its capabilities", ctx do
      run = run_fixture(ctx.agent, %{status: :running, capabilities: Run.capabilities()})
      {scope, _token} = run_scope_fixture(run)

      for resource <- [
            nil,
            %{op: :manage, may_trigger: true},
            %{op: :disable, may_trigger: true}
          ] do
        assert Policy.authorize(scope, :manage_autopilots, resource) == {:error, :forbidden}
      end

      assert :manage_autopilots in Policy.management_actions()
    end

    test "an hm_ token of a person (REST run now) follows the person", ctx do
      %{api_token: token} = api_token_fixture(ctx.alice_scope)

      scope = %{
        token_scope_fixture(ctx.alice, ctx.workspace, :api, token)
        | actor: ctx.alice_scope.actor
      }

      assert Policy.authorize(scope, :manage_autopilots, %{op: :manage, may_trigger: true}) == :ok

      assert Policy.authorize(%{scope | actor: ctx.agent}, :manage_autopilots, nil) ==
               {:error, :forbidden}
    end
  end

  describe ":merge_pull_request (add-pr-reconcile-merge decision 14)" do
    defp merge(scope), do: Policy.authorize(scope, :merge_pull_request)

    test "people from member up", ctx do
      assert merge(ctx.alice_scope) == :ok

      for {role, expected} <- [
            owner: :ok,
            admin: :ok,
            member: :ok,
            viewer: {:error, :forbidden}
          ] do
        {_user, scope} = member_scope_fixture(ctx.workspace, role)
        assert merge(scope) == expected, "#{role}"
      end
    end

    test "an external agent's hm_ session and a run scope are refused", ctx do
      %{api_token: token} = api_token_fixture(ctx.alice_scope)
      scope = token_scope_fixture(ctx.alice, ctx.workspace, :mcp, token)
      assert merge(%{scope | actor: ctx.alice_scope.actor}) == :ok
      assert merge(%{scope | actor: ctx.agent}) == {:error, :forbidden}

      run =
        run_fixture(ctx.agent, %{status: :running, capabilities: Run.capabilities()})

      {scope, _token} = run_scope_fixture(run)
      assert merge(scope) == {:error, :forbidden}
    end

    test "it is not a management action" do
      refute :merge_pull_request in Policy.management_actions()
    end
  end

  describe ":design_agents and :design (add-agent-conversation 1.2, decisions 6, 7)" do
    defp design_agents(scope), do: Policy.authorize(scope, :design_agents)

    test "a web session of a member, admin or owner passes; a viewer is refused", ctx do
      for {role, expected} <- [
            owner: :ok,
            admin: :ok,
            member: :ok,
            viewer: {:error, :forbidden}
          ] do
        {_user, scope} = member_scope_fixture(ctx.workspace, role)
        assert scope.via == :web
        assert design_agents(scope) == expected, "#{role}"
      end
    end

    test "an hm_ token via MCP, an agent identity and a real run scope are refused", ctx do
      %{api_token: token} = api_token_fixture(ctx.alice_scope)
      mcp = token_scope_fixture(ctx.alice, ctx.workspace, :mcp, token)
      assert design_agents(%{mcp | actor: ctx.alice_scope.actor}) == {:error, :forbidden}
      assert design_agents(%{ctx.alice_scope | actor: ctx.agent}) == {:error, :forbidden}

      for caps <- [["read", "design"], ["read", "write_task", "create_tasks"]] do
        run = run_fixture(ctx.agent, %{status: :running, capabilities: caps})
        {scope, _token} = run_scope_fixture(run)
        assert design_agents(scope) == {:error, :forbidden}
      end

      assert :design_agents in Policy.management_actions()
    end

    test ":design: only a run token with the design capability", ctx do
      design = run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "design"]})
      {design_scope, _token} = run_scope_fixture(design)
      assert Policy.authorize(design_scope, :design) == :ok

      task_run =
        run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "create_tasks"]})

      {task_scope, _token} = run_scope_fixture(task_run)
      assert Policy.authorize(task_scope, :design) == {:error, :forbidden}
      assert Policy.authorize(ctx.alice_scope, :design) == {:error, :forbidden}

      # A design run reads but writes no task and creates none.
      assert Policy.authorize(design_scope, :read_tasks) == :ok
      assert Policy.authorize(design_scope, :create_task) == {:error, :forbidden}
      assert Policy.authorize(design_scope, :update_task) == {:error, :forbidden}
    end
  end

  test "backup and claim permissions cover roles, people, agents and run tokens", ctx do
    actions = [
      :export_workspace,
      :import_merge,
      :import_replace,
      :view_imports,
      :request_claim,
      :decide_claim,
      :transfer_agent
    ]

    %{api_token: token} = api_token_fixture(ctx.alice_scope)

    for role <- [:owner, :admin, :member, :viewer], action <- actions do
      minimum =
        case action do
          :import_replace -> [:owner]
          :request_claim -> [:owner, :admin, :member, :viewer]
          _ -> [:owner, :admin]
        end

      for via <- [:web, :mcp, :api] do
        scope = %{ctx.alice_scope | role: role, via: via, token: if(via != :web, do: token)}

        expected =
          if role in minimum and (action != :request_claim or via == :web),
            do: :ok,
            else: {:error, :forbidden}

        assert Policy.authorize(scope, action) == expected
        assert Policy.authorize(%{scope | actor: ctx.agent}, action) == {:error, :forbidden}
      end
    end

    run = run_fixture(ctx.agent, %{status: :running, capabilities: Run.capabilities()})
    {scope, _} = run_scope_fixture(run)
    for action <- actions, do: assert(Policy.authorize(scope, action) == {:error, :forbidden})
  end

  describe "spec actions (add-spec-workflow 1.5, decision 14)" do
    @roles [:owner, :admin, :member, :viewer]
    @coordinators [:human, {:leader, :squad}, {:assignee_agent, :agent}, :none]

    # A person on the web, an agent identity (an `hm_` credential) and a
    # run token (read, write_task) of an agent, all of user 10.
    defp spec_scope(role, :human),
      do: %Scope{
        user: %Helmsman.Accounts.User{id: 10},
        workspace: %Helmsman.Workspaces.Workspace{id: 1},
        role: role,
        actor: %Helmsman.Actors.Actor{id: 100, workspace_id: 1, kind: :human, user_id: 10},
        via: :web
      }

    defp spec_scope(role, :agent),
      do: %{
        spec_scope(role, :human)
        | actor: %Helmsman.Actors.Actor{id: 200, workspace_id: 1, kind: :agent, owner_id: 10},
          via: :mcp
      }

    defp spec_scope(role, :run),
      do: %{
        spec_scope(role, :agent)
        | via: :run,
          run: %Run{id: 900, task_id: 500, capabilities: ["read", "write_task"]}
      }

    defp result(true), do: :ok
    defp result(false), do: {:error, :forbidden}

    test "the full matrix: person / agent / run token × the four roles" do
      for role <- @roles, kind <- [:human, :agent, :run] do
        scope = spec_scope(role, kind)
        member? = role != :viewer
        admin? = role in [:owner, :admin]
        label = "#{role} #{kind}"

        assert Policy.authorize(scope, :view_spec) == :ok, label
        assert Policy.authorize(scope, :write_spec) == result(member?), label

        for coordinator <- @coordinators do
          assert Policy.authorize(scope, :coordinate_spec, coordinator) ==
                   result(member? and coordinator != :none),
                 "#{label} #{inspect(coordinator)}"

          assert Policy.authorize(scope, :rule_spec_issue, coordinator) ==
                   result(
                     member? and (coordinator == :human or match?({:leader, _}, coordinator))
                   ),
                 "#{label} #{inspect(coordinator)}"
        end

        # People only, even an agent of an owner.
        assert Policy.authorize(scope, :approve_spec) == result(kind == :human and member?), label

        for action <- [:update_project_spec_finalize, :set_leader_spec_finalize] do
          assert Policy.authorize(scope, action) == result(kind == :human and admin?), label
          assert action in Policy.management_actions()
        end
      end
    end

    test "a run writes only its own task's spec" do
      scope = spec_scope(:owner, :run)
      assert Policy.authorize(scope, :write_task, %Helmsman.Tasks.Task{id: 500}) == :ok

      assert Policy.authorize(scope, :write_task, %Helmsman.Tasks.Task{id: 501}) ==
               {:error, :forbidden}

      read_only = %{scope | run: %{scope.run | capabilities: ["read"]}}
      assert Policy.authorize(read_only, :view_spec) == :ok
      assert Policy.authorize(read_only, :write_spec) == {:error, :forbidden}
    end
  end
end
