defmodule HelmsmanWeb.API.LinksController do
  @moduledoc "`/tasks/:id/links`: `link_tasks` and `unlink_tasks` over REST."

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.{LinkTasks, UnlinkTasks}

  tool_action(:create, LinkTasks,
    path: [from: "id"],
    response: Schemas.TaskDetail,
    tag: "links"
  )

  tool_action(:delete, UnlinkTasks,
    path: [from: "id", type: "type", to: "to"],
    response: Schemas.TaskDetail,
    tag: "links"
  )
end
