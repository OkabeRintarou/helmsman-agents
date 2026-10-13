defmodule HelmsmanWeb.API.ProjectsController do
  @moduledoc "`/projects`: the MCP project tools over REST (`add-rest-api` decision 6)."

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.{CreateProject, GetProject, ListProjects, UpdateProject}

  tool_action(:index, ListProjects, response: Schemas.ProjectList, tag: "projects")

  tool_action(:create, CreateProject,
    status: 201,
    response: Schemas.Project,
    tag: "projects"
  )

  tool_action(:show, GetProject, path: [key: "key"], response: Schemas.Project, tag: "projects")

  tool_action(:update, UpdateProject,
    path: [key: "key"],
    response: Schemas.Project,
    tag: "projects"
  )
end
