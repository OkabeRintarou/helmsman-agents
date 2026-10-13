defmodule HelmsmanWeb.API.ParamsTest do
  # add-rest-api decision 4.
  use ExUnit.Case, async: true

  import Plug.Test

  alias HelmsmanMCP.Tools.{AddFeedback, CreateTask, ListMyTasks, ListTasks, TransitionTask}
  alias HelmsmanWeb.API.Params

  defp get_conn(query, headers \\ []) do
    :get |> conn("/x?" <> query) |> with_headers(headers)
  end

  defp body_conn(body, headers \\ []) do
    :post |> conn("/x", "") |> Map.put(:body_params, body) |> with_headers(headers)
  end

  defp with_headers(conn, headers),
    do: Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

  defp args(conn, tool, path \\ %{"project_key" => "BOS"}), do: Params.tool_args(conn, tool, path)

  @query_cases [
    {"integer", "limit=10", %{"limit" => 10}},
    {"negative integer", "offset=-1", %{"offset" => -1}},
    {"comma list", "status=NEW,IN_PROGRESS", %{"status" => ["NEW", "IN_PROGRESS"]}},
    {"single value of a string-or-list", "status=NEW", %{"status" => ["NEW"]}},
    {"key[] list", "status[]=NEW&status[]=DONE", %{"status" => ["NEW", "DONE"]}},
    {"string", "label=bug&query=login", %{"label" => "bug", "query" => "login"}},
    {"empty string", "assignee=", %{"assignee" => ""}},
    {"undeclared parameters are dropped", "color=red&limit=1", %{"limit" => 1}}
  ]

  for {label, query, expected} <- @query_cases do
    test "query: #{label}" do
      assert {:ok, args, nil} = args(get_conn(unquote(query)), ListTasks)
      assert args == Map.put(unquote(Macro.escape(expected)), "project_key", "BOS")
    end
  end

  @bad_queries [
    {"integer as text", "limit=ten", "limit"},
    {"float", "limit=1.5", "limit"},
    {"integer list for a string", "label[]=a&label[]=b", "label"}
  ]

  for {label, query, field} <- @bad_queries do
    test "query: #{label} is invalid_params" do
      assert {:error, {:invalid_params, fields}} = args(get_conn(unquote(query)), ListTasks)
      assert Map.keys(fields) == [unquote(field)]
    end
  end

  test "query: booleans are true or false" do
    alias HelmsmanMCP.Tools.ListProjects

    assert {:ok, %{"include_archived" => true}, nil} =
             Params.tool_args(get_conn("include_archived=true"), ListProjects, %{})

    assert {:ok, %{"include_archived" => false}, nil} =
             Params.tool_args(get_conn("include_archived=false"), ListProjects, %{})

    assert {:error, {:invalid_params, %{"include_archived" => [_]}}} =
             Params.tool_args(get_conn("include_archived=yes"), ListProjects, %{})
  end

  test "a missing required argument is invalid_params" do
    assert {:error, {:invalid_params, %{"project_key" => [_]}}} =
             Params.tool_args(get_conn(""), ListTasks, %{})

    assert {:error, {:invalid_params, %{"title" => [_]}}} = args(body_conn(%{}), CreateTask)
  end

  test "body: wrong types, nested objects included, are invalid_params with dotted paths" do
    body = %{"to" => "DONE", "tests" => %{"passed" => "yes"}, "commits" => "abc"}

    assert {:error, {:invalid_params, fields}} =
             Params.tool_args(body_conn(body), TransitionTask, %{"task_id" => "BOS-1"})

    assert Map.keys(fields) |> Enum.sort() == ["commits", "tests.passed"]
  end

  test "body: null is kept (it clears a field) and undeclared keys are dropped" do
    body = %{"title" => "x", "description" => nil, "junk" => 1}

    assert {:ok, args, nil} = args(body_conn(body), CreateTask)
    assert args == %{"project_key" => "BOS", "title" => "x", "description" => nil}
  end

  test "path parameters replace the query string and the body" do
    assert {:ok, %{"project_key" => "BOS"}, nil} =
             args(get_conn("project_key=OTHER"), ListTasks)

    assert {:ok, %{"project_key" => "BOS"}, nil} =
             args(body_conn(%{"title" => "x", "project_key" => "OTHER"}), CreateTask)
  end

  test "path parameters and dropped arguments are removed before conversion" do
    alias HelmsmanMCP.Tools.QueryTasks

    conn = get_conn("filter_id[]=bad&limit=3")

    assert {:ok, %{"filter_id" => 7, "limit" => 3}, nil} =
             Params.tool_args(conn, QueryTasks, %{"filter_id" => 7})

    assert {:ok, %{"bql" => "", "limit" => 3}, nil} =
             Params.tool_args(get_conn("bql=&filter_id[]=bad&limit=3"), QueryTasks, %{}, [
               "filter_id"
             ])

    assert {:error, {:invalid_params, %{"limit" => _}}} =
             Params.tool_args(get_conn("bql=&filter_id=1&limit=x"), QueryTasks, %{}, ["filter_id"])

    body = body_conn(%{"title" => "x", "project_key" => 42})
    assert {:ok, %{"project_key" => "BOS"}, nil} = args(body, CreateTask)
  end

  test "a JSON body that is not an object is invalid_params" do
    assert {:error, {:invalid_params, %{"body" => [_]}}} =
             args(body_conn(%{"_json" => [1, 2]}), CreateTask)
  end

  describe "the requested identity" do
    test "comes from the header, or the body's actor or author" do
      header = [{"x-helmsman-actor", "keel/dev"}]

      assert {:ok, args, "keel/dev"} = args(body_conn(%{"title" => "x"}, header), CreateTask)
      refute Map.has_key?(args, "actor")

      assert {:ok, args, "keel/dev"} =
               args(body_conn(%{"title" => "x", "actor" => "keel/dev"}), CreateTask)

      refute Map.has_key?(args, "actor")

      assert {:ok, args, "keel/dev"} =
               Params.tool_args(
                 body_conn(%{"content" => "hi", "author" => "keel/dev"}),
                 AddFeedback,
                 %{"task_id" => "BOS-1"}
               )

      refute Map.has_key?(args, "author")
    end

    test "the same name in the header and the body is fine" do
      conn =
        body_conn(%{"title" => "x", "actor" => "keel/dev"}, [{"x-helmsman-actor", "keel/dev"}])

      assert {:ok, _args, "keel/dev"} = args(conn, CreateTask)
    end

    test "different names in the header and the body are invalid_params on actor" do
      conn =
        body_conn(%{"title" => "x", "actor" => "keel/review"}, [{"x-helmsman-actor", "keel/dev"}])

      assert {:error, {:invalid_params, %{"actor" => [_]}}} = args(conn, CreateTask)
    end

    test "reads take the header only" do
      conn = get_conn("actor=keel/review", [{"x-helmsman-actor", "keel/dev"}])
      assert {:ok, %{}, "keel/dev"} = Params.tool_args(conn, ListMyTasks, %{})
      assert {:ok, %{}, nil} = Params.tool_args(get_conn("actor=keel/dev"), ListMyTasks, %{})
    end

    test "a blank header is no header" do
      conn = get_conn("", [{"x-helmsman-actor", "  "}])
      assert {:ok, %{}, nil} = Params.tool_args(conn, ListMyTasks, %{})
    end
  end
end
