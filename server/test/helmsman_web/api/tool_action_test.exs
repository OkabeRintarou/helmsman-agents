defmodule HelmsmanWeb.API.ToolActionTest do
  # add-rest-api decision 2.
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers

  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback.Entry
  alias Helmsman.Repo
  alias HelmsmanMCP.Test.RejectingTool
  alias HelmsmanWeb.API.ToolAction
  alias HelmsmanWeb.Test.{RaisingTool, ReadTool, WriteTool}

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    task_fixture(ctx.scope, "BOS")
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    Map.put(ctx, :keel, keel)
  end

  defp scope(ctx), do: token_scope_fixture(ctx.alice, ctx.workspace, :api, ctx.api_token)

  defp request(ctx, method, tool, opts, body \\ %{}, headers \\ []) do
    conn =
      Plug.Test.conn(method, "/x" <> if(method == :get, do: "?limit=3", else: ""))
      |> Map.put(:body_params, body)
      |> Map.put(:path_params, %{"id" => "BOS-1"})
      |> Plug.Conn.assign(:current_scope, scope(ctx))

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    ToolAction.run(conn, tool, opts)
  end

  defp feedback_count, do: Repo.aggregate(Entry, :count)

  defp session_agents,
    do: Repo.aggregate(from(a in Actor, where: like(a.name, "%/session-%")), :count)

  test "a read tool gets the current identity in scope.actor, outside a transaction", ctx do
    data = request(ctx, :get, ReadTool, []) |> body!(200)

    assert data["data"] == %{
             "actor" => human_name(ctx),
             "args" => %{"limit" => 3},
             "in_tx" => false
           }

    data = request(ctx, :get, ReadTool, [], %{}, [{"x-helmsman-actor", "keel/dev"}]) |> body!(200)
    assert data["data"]["actor"] == "keel/dev"
  end

  test "a write tool runs as the writer and answers with its status", ctx do
    data =
      ctx
      |> request(:post, WriteTool, path: [task_id: "id"], status: 201)
      |> body!(201)

    assert data == %{"data" => %{"actor" => human_name(ctx)}}
    assert feedback_count() == 1
  end

  test "a failed write rolls everything back", ctx do
    before = feedback_count()

    ctx
    |> request(:post, WriteTool, [path: [task_id: "id"]], %{"fail" => true})
    |> error!(409, "stale")

    assert feedback_count() == before
  end

  test "a rejected write commits and answers with its reason", ctx do
    before = feedback_count()

    detail =
      ctx
      |> request(:post, RejectingTool, path: [task_id: "id"])
      |> error!(409, "not_dispatched")

    assert detail == %{"reason" => "rate_limited"}
    assert feedback_count() == before + 1
  end

  test "an exception is a 500 with a reference the log repeats", ctx do
    log =
      capture_log(fn ->
        detail = ctx |> request(:get, RaisingTool, []) |> error!(500, "internal")
        assert [ref] = Map.values(detail)
        assert Map.keys(detail) == ["ref"]
        send(self(), {:ref, ref})
      end)

    assert_received {:ref, ref}
    assert log =~ ref
    assert log =~ "secret failure detail"
  end

  test "never creates a session agent, without a default agent or name", ctx do
    before = session_agents()
    request(ctx, :post, WriteTool, path: [task_id: "id"]) |> body!(200)
    request(ctx, :get, ReadTool, []) |> body!(200)
    assert session_agents() == before
  end

  test "an integer path argument that is not a positive integer is 404", ctx do
    conn =
      Plug.Test.conn(:post, "/x")
      |> Map.put(:body_params, %{})
      |> Map.put(:path_params, %{"id" => "abc"})
      |> Plug.Conn.assign(:current_scope, scope(ctx))
      |> ToolAction.run(HelmsmanMCP.Tools.CancelRun, path: [run_id: "id"])

    error!(conn, 404, "not_found")
  end

  defp human_name(ctx),
    do: Helmsman.Actors.get_human(ctx.workspace.id, ctx.alice.id).name
end
