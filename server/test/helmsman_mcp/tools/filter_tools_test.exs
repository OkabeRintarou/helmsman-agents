defmodule HelmsmanMCP.Tools.FilterToolsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.BQLFixtures
  import HelmsmanMCP.ToolHelpers

  import Helmsman.RunsFixtures,
    only: [dispatch_fixture: 0, run_fixture: 2, run_scope_fixture: 1, member_scope_fixture: 2]

  alias Anubis.Server.Component.Schema
  alias Helmsman.Filters
  alias HelmsmanMCP.Pipeline
  alias HelmsmanMCP.Tools.{DeleteFilter, QueryTasks, SaveFilter}

  setup do
    ctx = bql_fixture()
    Map.put(ctx, :session, mcp_session(ctx.user, ctx.workspace))
  end

  test "optional input schema; validation and create/update/version lifecycle", ctx do
    schema =
      Schema.to_json_schema(SaveFilter.input_schema())

    for tool <- [SaveFilter, QueryTasks, DeleteFilter] do
      validator = Schema.validator(tool.input_schema())
      assert {:ok, _} = validator.(%{filter_id: "123"})
      assert {:ok, _} = validator.(%{filter_id: 123})
    end

    assert schema["required"] in [nil, []]

    assert {:error, "name: can't be blank"} =
             call(ctx.session, "save_filter", %{bql: "status = new"})

    assert {:error, "bql: can't be blank"} = call(ctx.session, "save_filter", %{name: "new"})
    f = call!(ctx.session, "save_filter", %{name: "my new", bql: "status = new"})
    refute f["shared"]

    updated =
      call!(ctx.session, "save_filter", %{
        filter_id: "#{f["id"]}",
        bql: "status = done",
        lock_version: 1
      })

    assert updated["name"] == "my new" and updated["bql"] == "status = done" and
             updated["lock_version"] == 2

    assert {:error,
            "The filter was changed by someone else since you read it. Call list_filters for the latest lock_version, then retry."} =
             call(ctx.session, "save_filter", %{
               filter_id: f["id"],
               name: "stale",
               lock_version: 1
             })

    assert call!(ctx.session, "save_filter", %{filter_id: f["id"]}) == updated
    last = call!(ctx.session, "save_filter", %{filter_id: f["id"], shared: true})
    assert last["shared"] and last["lock_version"] == 3
    assert last["name"] == "my new" and last["bql"] == "status = done"
    assert [^last] = call!(ctx.session, "list_filters")
    assert call!(ctx.session, "delete_filter", %{filter_id: "#{f["id"]}"}) == %{"deleted" => true}
    assert {:error, text} = call(ctx.session, "delete_filter", %{filter_id: f["id"]})
    assert text =~ "Not found"
  end

  test "admin updates shared BQL while invisible private queries return not found", ctx do
    private = call!(ctx.session, "save_filter", %{name: "private", bql: ""})
    shared = call!(ctx.session, "save_filter", %{name: "shared", bql: "", shared: true})
    {admin, _scope} = member_scope_fixture(ctx.workspace, :admin)
    session = mcp_session(admin, ctx.workspace)
    assert [f] = call!(session, "list_filters")
    assert f["id"] == shared["id"]
    assert call!(session, "save_filter", %{filter_id: f["id"], bql: "status = done"})["shared"]
    assert {:error, _} = call(session, "save_filter", %{filter_id: f["id"], shared: false})

    for tool <- ["query_tasks", "save_filter", "delete_filter"],
        do: assert({:error, _text} = call(session, tool, %{filter_id: private["id"]}))
  end

  test "run scopes see shared only and cannot save/delete even when owner is their user" do
    ctx = dispatch_fixture()
    {:ok, _} = Filters.create(ctx.alice_scope, %{name: "private", bql: ""})

    {:ok, shared} =
      Filters.create(ctx.alice_scope, %{name: "shared", bql: "", visibility: :workspace})

    run = run_fixture(ctx.agent, %{status: :running})
    {scope, _} = run_scope_fixture(run)
    assert {:ok, json} = Pipeline.call_tool("list_filters", %{}, scope, nil)
    assert [%{"id" => id, "lock_version" => 1}] = Jason.decode!(json)
    assert id == shared.id

    for {tool, args} <- [
          {"save_filter", %{name: "x", bql: ""}},
          {"delete_filter", %{filter_id: shared.id}}
        ] do
      assert {:error, text} = Pipeline.call_tool(tool, args, scope, nil)
      assert text =~ "This run can only read the workspace"
    end
  end
end
