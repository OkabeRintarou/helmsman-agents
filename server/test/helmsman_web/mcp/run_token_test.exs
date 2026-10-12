defmodule HelmsmanWeb.MCP.RunTokenTest do
  # The anubis session processes and their tool tasks are not children of
  # the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback.Entry
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias HelmsmanWeb.MCPClient
  alias HelmsmanWeb.Plugs.BearerAuth

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{task: task, other: other})
  end

  defp run_token(ctx, caps \\ ["read", "write_task"]) do
    run =
      run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :running, capabilities: caps})

    {_scope, token} = run_scope_fixture(run)
    {run, token}
  end

  defp set_status(run, status),
    do: Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: status])

  describe "identity in a run" do
    test "the author argument is ignored", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)

      assert {:ok, %{"author" => %{"name" => "keel/dev"}}} =
               MCPClient.call_tool(token, sid, "add_feedback", %{
                 task_id: ctx.task.ident,
                 content: "done",
                 author: ctx.alice_scope.actor.name
               })
    end

    test "identify changes nothing; whoami says run", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)
      count = Repo.aggregate(Actor, :count)

      assert {:ok, %{"name" => "keel/dev", "source" => "run"}} =
               MCPClient.call_tool(token, sid, "identify", %{name: "other/agent"})

      assert {:ok, %{"actor" => %{"name" => "keel/dev"}, "source" => "run"}} =
               MCPClient.call_tool(token, sid, "whoami")

      assert Repo.aggregate(Actor, :count) == count
    end

    test "a disabled agent cannot write but still reads", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)
      Repo.update!(Ecto.Changeset.change(ctx.agent, disabled_at: DateTime.utc_now(:second)))

      assert {:error, text} =
               MCPClient.call_tool(token, sid, "add_feedback", %{
                 task_id: ctx.task.ident,
                 content: "x"
               })

      assert text =~ "keel/dev is disabled"

      assert {:ok, %{"id" => _}} =
               MCPClient.call_tool(token, sid, "get_task", %{task_id: ctx.task.ident})
    end
  end

  describe "capabilities" do
    test "another task: forbidden, the text names the task and the capabilities", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)

      assert {:error, text} =
               MCPClient.call_tool(token, sid, "transition_task", %{
                 task_id: ctx.other.ident,
                 to: "DONE"
               })

      assert text =~ "This run can only read the workspace and change #{ctx.task.ident}"
      assert text =~ "(capabilities: read, write_task)"
      assert Repo.get!(Helmsman.Tasks.Task, ctx.other.id).status == :new
    end

    test "without create_tasks: create_task is forbidden; run_agent always", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)

      assert {:error, text} =
               MCPClient.call_tool(token, sid, "create_task", %{
                 project_key: ctx.project.key,
                 title: "New"
               })

      assert text =~ "This run can only read"

      assert {:error, _} =
               MCPClient.call_tool(token, sid, "run_agent", %{
                 agent: "keel/dev",
                 instructions: "x"
               })
    end

    test "with create_tasks: the agent creates a task it then cannot change", ctx do
      {_run, token} = run_token(ctx, ["read", "write_task", "create_tasks"])
      sid = MCPClient.handshake(token)

      assert {:ok, %{"id" => id, "created_by" => %{"name" => "keel/dev"}}} =
               MCPClient.call_tool(token, sid, "create_task", %{
                 project_key: ctx.project.key,
                 title: "New"
               })

      assert {:error, text} =
               MCPClient.call_tool(token, sid, "update_task", %{task_id: id, title: "Edited"})

      assert text =~ "This run can only read the workspace and change #{ctx.task.ident}"
    end
  end

  describe "validity" do
    test "cancelling: still valid; ended: 401", ctx do
      {run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)

      set_status(run, :cancelling)

      assert {:ok, _} =
               MCPClient.call_tool(token, sid, "get_task", %{task_id: ctx.task.ident})

      set_status(run, :succeeded)
      assert MCPClient.rpc(token, sid, "tools/list").status == 401
      assert MCPClient.rpc(token, nil, "initialize", %{}).status == 401
    end

    test "the REST pipeline refuses run tokens", ctx do
      {_run, token} = run_token(ctx)

      conn =
        Plug.Test.conn(:get, "/api/tasks")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> BearerAuth.call(BearerAuth.init(scope: "api:read", via: :api))

      assert conn.halted
      assert conn.status == 401
    end

    test "the session is bound to the run: an hm_ token of the same user gets 404", ctx do
      {_run, token} = run_token(ctx)
      sid = MCPClient.handshake(token)

      %{token: hm_token} =
        api_token_fixture(workspace_scope_fixture(ctx.alice, ctx.workspace), %{scopes: ["mcp"]})

      assert MCPClient.rpc(hm_token, sid, "tools/list").status == 404

      {_other_run, other_token} = run_token(%{ctx | task: ctx.other})
      assert MCPClient.rpc(other_token, sid, "tools/list").status == 404
      assert MCPClient.rpc(token, sid, "tools/list").status == 200
    end
  end

  test "feedback written in a run names it", ctx do
    {run, token} = run_token(ctx)
    sid = MCPClient.handshake(token)

    {:ok, _} =
      MCPClient.call_tool(token, sid, "add_feedback", %{task_id: ctx.task.ident, content: "x"})

    assert [%Entry{source_run_id: id}] =
             Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id))

    assert id == run.id
  end
end
