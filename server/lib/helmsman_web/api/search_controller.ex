defmodule HelmsmanWeb.API.SearchController do
  @moduledoc "`/search`: `search_tasks` over REST."

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.SearchTasks

  tool_action(:index, SearchTasks, response: Schemas.SearchResult, tag: "tasks")
end
