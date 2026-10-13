defmodule HelmsmanWeb.API.QueryControllerTest do
  # add-rest-api 6.1: /query and /filters. The timeout case changes the BQL
  # configuration with Application.put_env.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.{Filters, Repo}
  alias Helmsman.Filters.SavedFilter

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    agent_fixture(ctx.workspace, ctx.alice, "keel/review")
    human = Helmsman.Actors.get_human(ctx.workspace.id, ctx.alice.id)

    task_fixture(ctx.scope, "BOS", %{title: "Agent's", assignee: "keel/dev"})
    task_fixture(ctx.scope, "BOS", %{title: "Mine", assignee: human.name})
    task_fixture(ctx.scope, "BOS", %{title: "Reviewer's", assignee: "keel/review"})
    task_fixture(ctx.scope, "BOS", %{title: "Nobody's"})

    Map.merge(ctx, %{keel: keel, human: human})
  end

  defp w_query(bql), do: "/query?" <> URI.encode_query(%{"bql" => bql})

  defp titles(conn),
    do: conn |> body!(200) |> get_in(["data", "tasks"]) |> Enum.map(& &1["title"])

  describe "GET /query" do
    test "a BQL query", ctx do
      data = ctx.token |> api_get(w(ctx.slug, w_query("title ~ Mine"))) |> body!(200)
      assert_schema(data["data"], "QueryResult", ctx.spec)
      assert %{"total" => 1, "tasks" => [%{"title" => "Mine"}]} = data["data"]

      data = ctx.token |> api_get(w(ctx.slug, w_query("") <> "&limit=2")) |> body!(200)
      assert %{"total" => 4, "tasks" => [_, _]} = data["data"]
    end

    test "invalid BQL is 422 with its message and position", ctx do
      detail =
        ctx.token |> api_get(w(ctx.slug, w_query("status = "))) |> error!(422, "invalid_bql")

      assert %{"message" => message, "position" => position} = detail
      assert is_binary(message) and is_integer(position)
    end

    test "a filter_id of any type is ignored; a bad limit is still 400", ctx do
      data =
        ctx.token |> api_get(w(ctx.slug, "/query?bql=&filter_id[]=bad")) |> body!(200)

      assert data["data"]["total"] == 4

      ctx.token
      |> api_get(w(ctx.slug, "/query?bql=&filter_id[]=bad&limit=x"))
      |> error!(400, "invalid_params")
    end

    test "without bql: 400; a limit out of range: 400", ctx do
      ctx.token |> api_get(w(ctx.slug, "/query")) |> error!(400, "invalid_params")

      detail =
        ctx.token
        |> api_get(w(ctx.slug, w_query("") <> "&limit=500"))
        |> error!(400, "invalid_params")

      assert Map.keys(detail["fields"]) == ["limit"]
    end

    test "currentUser() is the read identity: default agent, human, X-Helmsman-Actor", ctx do
      bql = "assignee = currentUser()"
      with_default = token_for(ctx.alice, ctx.workspace, %{default_agent_id: ctx.keel.id})

      assert titles(api_get(with_default, w(ctx.slug, w_query(bql)))) == ["Agent's"]
      assert titles(api_get(ctx.token, w(ctx.slug, w_query(bql)))) == ["Mine"]

      header = [{"x-helmsman-actor", "keel/review"}]
      assert titles(api_get(with_default, w(ctx.slug, w_query(bql)), header)) == ["Reviewer's"]
    end

    test "a query that takes too long is 422 query_timeout", ctx do
      old = Application.get_env(:helmsman, Helmsman.BQL)

      on_exit(fn ->
        if old,
          do: Application.put_env(:helmsman, Helmsman.BQL, old),
          else: Application.delete_env(:helmsman, Helmsman.BQL)
      end)

      Application.put_env(:helmsman, Helmsman.BQL, statement_timeout_ms: 1)
      Process.put(:helmsman_bql_query_hook, fn -> Repo.query!("SELECT pg_sleep(0.02)") end)

      ctx.token |> api_get(w(ctx.slug, w_query(""))) |> error!(422, "query_timeout")
    end
  end

  describe "/filters" do
    setup ctx do
      {:ok, filter} = Filters.create(ctx.scope, %{name: "Mine", bql: "title ~ Mine"})
      Map.put(ctx, :filter, filter)
    end

    defp filter_path(ctx, suffix \\ ""), do: w(ctx.slug, "/filters/#{ctx.filter.id}#{suffix}")

    test "list, one, run; each with lock_version", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/filters")) |> body!(200)
      assert_schema(data["data"], "FilterList", ctx.spec)
      assert [%{"id" => id, "name" => "Mine", "lock_version" => 1}] = data["data"]
      assert id == ctx.filter.id

      data = ctx.token |> api_get(filter_path(ctx)) |> body!(200)
      assert_schema(data["data"], "Filter", ctx.spec)
      assert %{"id" => ^id, "lock_version" => 1, "shared" => false} = data["data"]

      data = ctx.token |> api_get(filter_path(ctx, "/run")) |> body!(200)
      assert_schema(data["data"], "QueryResult", ctx.spec)
      assert %{"total" => 1, "tasks" => [%{"title" => "Mine"}]} = data["data"]
    end

    test "run: the path's filter wins over a bad filter_id or a bql in the query", ctx do
      data =
        ctx.token
        |> api_get(filter_path(ctx, "/run?filter_id[]=bad&bql=status%20%3D%20done"))
        |> body!(200)

      assert %{"total" => 1, "tasks" => [%{"title" => "Mine"}]} = data["data"]
    end

    test "POST creates: 201; a filter_id in the body is ignored", ctx do
      data =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/filters"), %{
          name: "Open",
          bql: "status = new",
          shared: true,
          filter_id: ctx.filter.id
        })
        |> body!(201)

      assert_schema(data["data"], "Filter", ctx.spec)
      assert %{"name" => "Open", "shared" => true, "lock_version" => 1} = data["data"]
      assert data["data"]["id"] != ctx.filter.id
      assert {:ok, %{name: "Mine"}} = Filters.get(ctx.scope, ctx.filter.id)
    end

    test "PATCH with the current lock_version: changed, version + 1", ctx do
      data =
        :patch
        |> api_send(ctx.token, filter_path(ctx), %{bql: "status = done", lock_version: 1})
        |> body!(200)

      assert_schema(data["data"], "Filter", ctx.spec)
      assert %{"bql" => "status = done", "lock_version" => 2} = data["data"]
    end

    test "PATCH with an old lock_version: 409 stale, nothing changes", ctx do
      {:ok, _} = Filters.update(ctx.scope, ctx.filter.id, %{name: "Renamed"})
      before = Repo.get!(SavedFilter, ctx.filter.id)

      :patch
      |> api_send(ctx.token, filter_path(ctx), %{
        bql: "status = done",
        name: "Other",
        shared: true,
        lock_version: 1
      })
      |> error!(409, "stale")

      after_ = Repo.get!(SavedFilter, ctx.filter.id)

      assert Map.take(after_, [:name, :bql, :visibility, :lock_version]) ==
               Map.take(before, [:name, :bql, :visibility, :lock_version])
    end

    test "PATCH without lock_version: the last write wins", ctx do
      {:ok, _} = Filters.update(ctx.scope, ctx.filter.id, %{name: "Renamed"})

      data =
        :patch |> api_send(ctx.token, filter_path(ctx), %{name: "Last"}) |> body!(200)

      assert %{"name" => "Last", "lock_version" => 3} = data["data"]
    end

    test "DELETE", ctx do
      data = :delete |> api_send(ctx.token, filter_path(ctx)) |> body!(200)
      assert_schema(data["data"], "Deleted", ctx.spec)
      assert data["data"] == %{"deleted" => true}
      ctx.token |> api_get(filter_path(ctx)) |> error!(404, "not_found")
    end

    test "someone else's private filter is 404; a viewer cannot create one", ctx do
      {_bob, bob} = member_token(ctx.workspace, :member)

      bob |> api_get(filter_path(ctx)) |> error!(404, "not_found")
      bob |> api_get(filter_path(ctx, "/run")) |> error!(404, "not_found")
      :patch |> api_send(bob, filter_path(ctx), %{name: "x"}) |> error!(404, "not_found")
      :delete |> api_send(bob, filter_path(ctx)) |> error!(404, "not_found")

      {_viewer, viewer} = member_token(ctx.workspace, :viewer)
      count = Repo.aggregate(SavedFilter, :count)

      :post
      |> api_send(viewer, w(ctx.slug, "/filters"), %{name: "V", bql: ""})
      |> error!(403, "forbidden")

      assert Repo.aggregate(SavedFilter, :count) == count
    end

    test "a filter ID that is not a positive integer is 404", ctx do
      for id <- ["0", "abc", "-3"] do
        ctx.token |> api_get(w(ctx.slug, "/filters/#{id}")) |> error!(404, "not_found")
        ctx.token |> api_get(w(ctx.slug, "/filters/#{id}/run")) |> error!(404, "not_found")
      end
    end
  end
end
