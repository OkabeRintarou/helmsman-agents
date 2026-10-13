defmodule HelmsmanWeb.API.QueryController do
  @moduledoc """
  `GET /query`: a BQL query of the workspace's tasks (`query_tasks`,
  `add-rest-api` decision 6). `currentUser()` is the request's current
  identity (decision 3).
  """

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.QueryTasks

  tool_action(:index, QueryTasks, drop: [:filter_id], response: Schemas.QueryResult, tag: "query")
end
