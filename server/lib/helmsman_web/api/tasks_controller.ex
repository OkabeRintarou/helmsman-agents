defmodule HelmsmanWeb.API.TasksController do
  @moduledoc """
  `/projects/:key/tasks` and `/tasks/:id`: the MCP task tools over REST
  (`add-rest-api` decision 6).
  """

  use HelmsmanWeb.API.Controller

  alias HelmsmanMCP.Tools.{
    CreateTask,
    GetTask,
    ListRuns,
    ListTasks,
    TransitionTask,
    UpdateTask
  }

  tool_action(:index, ListTasks,
    path: [project_key: "key"],
    response: Schemas.TaskList,
    tag: "tasks"
  )

  tool_action(:create, CreateTask,
    path: [project_key: "key"],
    status: 201,
    response: Schemas.TaskDetail,
    tag: "tasks"
  )

  tool_action(:show, GetTask, path: [task_id: "id"], response: Schemas.TaskDetail, tag: "tasks")

  tool_action(:update, UpdateTask,
    path: [task_id: "id"],
    response: Schemas.TaskDetail,
    tag: "tasks"
  )

  tool_action(:transition, TransitionTask,
    path: [task_id: "id"],
    response: Schemas.TaskDetail,
    tag: "tasks"
  )

  tool_action(:runs, ListRuns, path: [task_id: "id"], response: Schemas.RunList, tag: "runs")
end
