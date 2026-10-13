defmodule HelmsmanMCP.Tools.DependencyDispatchTest do
  # add-dependency-dispatch 1.11: `blocked_by` in deferred dispatch
  # results and `waiting_for` on the links of get_task (decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.DependencyFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.RunsFixtures

  alias HelmsmanMCP.Context
  alias HelmsmanMCP.Tools.{GetTask, UpdateTask}

  setup do
    ctx = dependency_fixture()
    put_status!(ctx.bos1, :in_progress)
    ctx
  end

  defp call(tool, scope, args),
    do: tool.call(args, %Context{tool: tool.name(), scope: scope, args: args, session: nil})

  defp link(result, ident), do: Enum.find(result.links, &(&1.task == ident))

  test "update_task assigning a blocked task: deferred with blocked_by", ctx do
    args = %{"task_id" => ctx.web2.ident, "assignee" => "keel/dev"}
    assert {:ok, result} = call(UpdateTask, ctx.alice_scope, args)

    assert result.dispatch == [
             %{
               agent: "keel/dev",
               trigger: "assign",
               result: "deferred",
               reason: nil,
               blocked_by: [ctx.bos1.ident]
             }
           ]
  end

  test "get_task: waiting_for on an unsatisfied outgoing depends_on only", ctx do
    installation = installation_fixture(ctx.workspace)
    repo = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repo)
    put_status!(ctx.bos1, :verified)

    run_fixture(ctx.agent, %{
      task_id: ctx.bos1.id,
      status: :succeeded,
      repository_id: repo.id,
      claimed_at: DateTime.utc_now(),
      branch: "b",
      base_sha: String.duplicate("0", 40),
      head_sha: String.duplicate("c", 40),
      push_status: :pushed,
      pushed_at: DateTime.utc_now()
    })

    assert {:ok, result} = call(GetTask, ctx.alice_scope, %{"task_id" => ctx.web2.ident})
    assert %{waiting_for: "merge", direction: "out"} = link(result, ctx.bos1.ident)

    # The incoming end never carries it.
    assert {:ok, result} = call(GetTask, ctx.alice_scope, %{"task_id" => ctx.bos1.ident})
    refute Map.has_key?(link(result, ctx.web2.ident), :waiting_for)

    Repo.update_all(Helmsman.Projects.Project, set: [repository_id: nil])
    assert {:ok, result} = call(GetTask, ctx.alice_scope, %{"task_id" => ctx.web2.ident})
    refute Map.has_key?(link(result, ctx.bos1.ident), :waiting_for)
  end
end
