defmodule HelmsmanWeb.API.FiltersController do
  @moduledoc """
  `/filters`: saved BQL queries over REST (`add-rest-api` decisions 6, 7
  and 12): `list_filters`, `save_filter` (create, or change with an
  optional `lock_version` checked under the filter's lock),
  `delete_filter`, running one (`query_tasks` with `filter_id`) and one
  filter (`Helmsman.Filters.get/2`).

  The filter tools are read tools in MCP (a filter belongs to the user,
  not to a writing identity); REST keeps that and only takes their
  arguments from the JSON body.
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.Filters
  alias HelmsmanMCP.Tools.{DeleteFilter, ListFilters, QueryTasks, SaveFilter}
  alias HelmsmanWeb.API.Params
  alias OpenApiSpex.Schema

  tool_action(:index, ListFilters, response: Schemas.FilterList, tag: "query")

  tool_action(:create, SaveFilter,
    drop: [:filter_id],
    body: true,
    status: 201,
    response: Schemas.Filter,
    tag: "query"
  )

  tool_action(:update, SaveFilter,
    path: [filter_id: {:integer, "id"}],
    body: true,
    response: Schemas.Filter,
    tag: "query"
  )

  tool_action(:delete, DeleteFilter,
    path: [filter_id: {:integer, "id"}],
    body: true,
    response: Schemas.Deleted,
    tag: "query"
  )

  tool_action(:run, QueryTasks,
    path: [filter_id: {:integer, "id"}],
    drop: [:bql],
    response: Schemas.QueryResult,
    tag: "query"
  )

  def show(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "get_filter", fn ->
      with {:ok, id} <- ToolAction.positive_id(id),
           {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
           {:ok, filter} <- Filters.get(scope, id) do
        ToolAction.data(conn, 200, ListFilters.present(filter))
      end
    end)
  end

  @doc false
  def operation(:show) do
    Operations.manual(
      id: "get_filter",
      summary: "get_filter",
      description: "One saved filter you can see, as list_filters shows it (with lock_version).",
      tag: "query",
      params: [{:id, :path, %Schema{type: :integer, minimum: 1}, "Filter ID."}],
      response: Schemas.Filter
    )
  end
end
