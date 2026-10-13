defmodule Helmsman.Tasks.TransitionContextTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks.{TaskEvent, TransitionContext, TransitionSteps}

  @no_evidence %{comment: nil, commits: [], tests: nil}
  @passing %{"command" => "mix test", "passed" => true, "summary" => "ok"}
  @failing %{@passing | "passed" => false}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)
    project_fixture(owner_scope, key: "BOS")

    agent = agent_fixture(workspace, owner, "keel/dev")
    agent_scope = %{owner_scope | actor: agent}
    task = task_fixture(owner_scope, "BOS", %{assignee: "keel/dev"})

    %{owner: owner_scope, agent: agent_scope, task: task}
  end

  defp done!(task, actor, tests, at \\ DateTime.utc_now()) do
    event!(task, actor, :in_progress, :done, tests, at)
  end

  defp event!(task, actor, from, to, tests \\ nil, at \\ DateTime.utc_now()) do
    Repo.insert!(%TaskEvent{
      workspace_id: task.workspace_id,
      task_id: task.id,
      from_status: from,
      to_status: to,
      actor_id: actor.id,
      tests: tests,
      inserted_at: at
    })
  end

  defp build(task, scope, to \\ :verified, evidence \\ @no_evidence),
    do: TransitionContext.build(task, scope, to, evidence)

  test "no links, no other run: nothing to report", %{task: task, agent: agent} do
    assert %{blockers: [], replaced_by: [], active_run: nil} = build(task, agent)
  end

  describe "self_verify?" do
    test "the assignee itself verifying", %{task: task, agent: agent} do
      assert %{self_verify?: true, assignee_name: "keel/dev"} = build(task, agent)
    end

    test "not for the owner's human identity", %{task: task, owner: owner} do
      assert %{self_verify?: false, assignee_name: "keel/dev"} = build(task, owner)
    end

    test "only when moving to verified", %{task: task, agent: agent} do
      assert %{self_verify?: false} = build(task, agent, :in_progress)
    end
  end

  describe "has_passing_tests?" do
    test "false without any tests", %{task: task, agent: agent} do
      done!(task, agent.actor, nil)
      assert %{has_passing_tests?: false} = build(task, agent)
    end

    test "this transition's passing tests", %{task: task, agent: agent} do
      assert %{has_passing_tests?: true} =
               build(task, agent, :verified, %{@no_evidence | tests: @passing})

      assert %{has_passing_tests?: false} =
               build(task, agent, :verified, %{@no_evidence | tests: @failing})
    end

    test "the latest done with passing tests", %{task: task, agent: agent} do
      done!(task, agent.actor, @passing)
      assert %{has_passing_tests?: true} = build(task, agent)
    end

    test "an older passing done does not count after a failing one",
         %{task: task, agent: agent} do
      t0 = DateTime.utc_now()
      done!(task, agent.actor, @passing, t0)
      event!(task, agent.actor, :done, :in_progress, nil, DateTime.add(t0, 1))
      done!(task, agent.actor, @failing, DateTime.add(t0, 2))

      assert %{has_passing_tests?: false} = build(task, agent)
    end

    test "an older passing done does not count after one without tests",
         %{task: task, agent: agent} do
      t0 = DateTime.utc_now()
      done!(task, agent.actor, @passing, t0)
      event!(task, agent.actor, :done, :in_progress, nil, DateTime.add(t0, 1))
      done!(task, agent.actor, nil, DateTime.add(t0, 2))

      assert %{has_passing_tests?: false} = build(task, agent)
    end

    test "with equal timestamps the later id wins", %{task: task, agent: agent} do
      at = DateTime.utc_now()
      done!(task, agent.actor, nil, at)
      done!(task, agent.actor, @passing, at)
      assert %{has_passing_tests?: true} = build(task, agent)

      done!(task, agent.actor, @failing, at)
      assert %{has_passing_tests?: false} = build(task, agent)
    end

    test "events of other statuses are ignored", %{task: task, agent: agent} do
      done!(task, agent.actor, @passing)
      event!(task, agent.actor, :done, :in_progress, @failing)
      assert %{has_passing_tests?: true} = build(task, agent)
    end
  end

  describe "TransitionSteps.run/3,4" do
    test "the default steps", %{task: task, agent: agent} do
      event = event!(task, agent.actor, :new, :in_progress)
      assert TransitionSteps.run(task, event, agent) == :ok
    end

    test "runs steps in order and stops at the first error", %{task: task, agent: agent} do
      event = event!(task, agent.actor, :new, :in_progress)
      parent = self()

      step = fn message ->
        fn _task, _event, _scope ->
          send(parent, message)
          :ok
        end
      end

      steps = [step.(:first), fn _, _, _ -> {:error, :boom} end, step.(:third)]

      assert TransitionSteps.run(steps, task, event, agent) == {:error, :boom}
      assert_received :first
      refute_received :third
    end
  end
end
