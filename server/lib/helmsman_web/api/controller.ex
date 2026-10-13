defmodule HelmsmanWeb.API.Controller do
  @moduledoc """
  The REST controllers' common code (`add-rest-api` decisions 2 and 8).

      use HelmsmanWeb.API.Controller

      tool_action :index, ListProjects, response: Schemas.ProjectList
      tool_action :create, CreateProject, status: 201, response: Schemas.Project

  `tool_action/3` defines the action running the MCP tool through
  `HelmsmanWeb.API.ToolAction` (options `:path`, `:status`) and its
  OpenAPI operation (`HelmsmanWeb.API.Operations.tool/2`, plus
  `:response` and `:tag`). Other actions define `operation/1` returning
  their `OpenApiSpex.Operation`; `open_api_operation/1` serves both for
  `OpenApiSpex.Paths.from_router/1`.
  """

  alias HelmsmanWeb.API.{Operations, ToolAction}

  defmacro __using__(_opts) do
    quote do
      use HelmsmanWeb, :controller

      import HelmsmanWeb.API.Controller, only: [tool_action: 2, tool_action: 3]

      alias HelmsmanWeb.API.{Operations, Schemas, ToolAction}
      alias HelmsmanWeb.ErrorMapper

      Module.register_attribute(__MODULE__, :api_tool_actions, accumulate: true)
      @before_compile HelmsmanWeb.API.Controller
    end
  end

  @doc "Defines the action `action` running `tool` (see the module doc)."
  defmacro tool_action(action, tool, opts \\ []) do
    quote do
      @api_tool_actions {unquote(action), unquote(tool), unquote(opts)}

      def unquote(action)(conn, _params) do
        {tool, opts} = __api_tool__(unquote(action))
        ToolAction.run(conn, tool, opts)
      end
    end
  end

  defmacro __before_compile__(env) do
    actions = Module.get_attribute(env.module, :api_tool_actions)
    manual? = Module.defines?(env.module, {:operation, 1}, :def)

    quote do
      @doc false
      def __api_tool_actions__, do: unquote(Macro.escape(actions))

      @doc false
      def __api_tool__(action) do
        {^action, tool, opts} = List.keyfind(__api_tool_actions__(), action, 0)
        {tool, Keyword.take(opts, [:path, :drop, :status])}
      end

      @doc false
      def open_api_operation(action) do
        case List.keyfind(__api_tool_actions__(), action, 0) do
          {_action, tool, opts} -> Operations.tool(tool, opts)
          nil -> unquote(if manual?, do: quote(do: operation(action)), else: nil)
        end
      end
    end
  end
end
