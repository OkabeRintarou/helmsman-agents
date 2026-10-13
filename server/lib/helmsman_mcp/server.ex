defmodule HelmsmanMCP.Server do
  @moduledoc """
  The MCP server (designs/08 §1): the only module that talks to anubis.

  Each MCP session is an anubis session process. Every request's
  `conn.assigns` are merged into `frame.assigns`, but a request queued
  behind a running tool call gets the frame that call returns, with the
  earlier request's assigns. Tool calls therefore never read
  `frame.assigns`: `HelmsmanMCP.RequestScope` rebuilds the scope from the
  request's own headers (`frame.context.headers`). `initialize` is handled
  synchronously, so its `frame.assigns.current_scope` is its own.

  The session is registered in `HelmsmanMCP.Sessions` and tracked online
  in `server_instructions/1`, not in `init/2` (design decision 15): anubis
  2.1 calls `init/2` only on `notifications/initialized`, which already
  carries the session ID and would be refused by
  `HelmsmanWeb.Plugs.MCPSessionGuard`; `server_instructions/1` runs in the
  session process while it answers `initialize`. For the same reason the
  tools come from `server_tools/2`. Resources and prompts have no such
  callback: `init/2` registers them (`HelmsmanMCP.Resources`,
  `HelmsmanMCP.Prompts`), and reading them takes the read path of tools
  (`HelmsmanMCP.Pipeline.read/5`). Before upgrading anubis, run
  `test/helmsman_web/mcp_endpoint_test.exs`, which covers the whole
  handshake over HTTP.
  """

  @version Mix.Project.config()[:version]

  use Anubis.Server,
    name: "helmsman",
    version: @version,
    capabilities: [:tools, :resources, :prompts],
    protocol_versions: ~w(2025-11-25 2025-06-18 2025-03-26)

  require Logger

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Registry
  alias Anubis.Server.Response
  alias Anubis.Server.Supervisor, as: AnubisSupervisor
  alias Helmsman.Accounts.Scope

  alias HelmsmanMCP.{
    ErrorText,
    Online,
    Pipeline,
    Prompts,
    RequestScope,
    Resources,
    Sessions,
    Tools
  }

  @instructions """
  Helmsman tracks tasks for humans and agents. Before writing anything, call \
  identify(name, project, worktree) to set the agent identity your writes are \
  recorded as (a team/role name such as keel/dev); if the API token has a \
  default agent you may skip it, and whoami shows the current identity. \
  Sessions do not survive a server restart: after reconnecting, call identify again. \
  Rules: read the resource helmsman://workflow. To start on a task, use the prompt \
  work_on_task.\
  """

  @impl Anubis.Server
  def server_instructions, do: @instructions

  @impl Anubis.Server
  def server_instructions(%Frame{} = frame) do
    register(frame)
    @instructions
  end

  @impl Anubis.Server
  def init(_client_info, frame), do: {:ok, register_components(frame)}

  defp register_components(frame) do
    frame =
      Enum.reduce(Resources.list(), frame, fn resource, frame ->
        Frame.register_resource(frame, resource.uri, component_opts(resource))
      end)

    frame =
      Enum.reduce(Resources.templates(), frame, fn template, frame ->
        Frame.register_resource_template(frame, template.uri_template, component_opts(template))
      end)

    Enum.reduce(Prompts.list(), frame, fn prompt, frame ->
      Frame.register_prompt(frame, prompt.name,
        title: prompt.title,
        description: prompt.description,
        arguments: prompt.arguments
      )
    end)
  end

  defp component_opts(component),
    do: Map.to_list(Map.take(component, [:name, :title, :description, :mime_type]))

  @impl Anubis.Server
  def server_tools(tools, %Frame{} = frame) do
    registered =
      Enum.reduce(Tools.all(), Frame.new(), fn tool, frame ->
        Frame.register_tool(frame, tool.name(),
          description: tool.description(),
          input_schema: tool.input_schema()
        )
      end)

    all = tools ++ Enum.sort_by(Map.values(registered.tools), & &1.name)
    required = Tools.required_capabilities()

    case run_capabilities(frame.context) do
      :all ->
        all

      caps ->
        all
        |> Enum.reject(&(Map.has_key?(required, &1.name) and required[&1.name] not in caps))
        |> squad_tools(frame.context)
    end
  end

  # `add-squads` decision 12: `propose_squad` only in squad conversations.
  defp squad_tools(tools, context) do
    if Enum.any?(tools, &(&1.name == "propose_squad")) and not squad_design?(context),
      do: Enum.reject(tools, &(&1.name == "propose_squad")),
      else: tools
  end

  defp squad_design?(context) do
    case request_scope(context) do
      {:ok, %Scope{via: :run, run: run}} -> Helmsman.AgentDesigns.squad_run?(run)
      _other -> false
    end
  end

  # `add-agent-conversation` decision 7: the draft tools are listed only
  # for a design run's token (resolved from the request's own headers);
  # `add-squads` decision 8: `delegate` only for a run with that
  # capability. anubis also looks a called tool up here: a call keeps every
  # tool, so that calling a restricted tool without the capability gets
  # its error text rather than "tool not found".
  # `HelmsmanWeb.Plugs.MCPMethod` puts the JSON-RPC method in the
  # `x-helmsman-rpc-method` header.
  defp run_capabilities(%{headers: %{"x-helmsman-rpc-method" => "tools/call"}}), do: :all

  defp run_capabilities(context) do
    case request_scope(context) do
      {:ok, %Scope{via: :run, run: run}} -> run.capabilities
      _other -> []
    end
  end

  @impl Anubis.Server
  def handle_tool_call(name, args, %Frame{context: context} = frame) do
    result =
      case request_scope(context) do
        {:ok, scope} -> Pipeline.call_tool(name, args, scope, context.session_id)
        {:error, :unauthorized} -> {:error, ErrorText.unauthorized()}
        {:error, {:internal, error, stacktrace}} -> {:error, log_failure(name, error, stacktrace)}
      end

    response =
      case result do
        {:ok, text} -> Response.text(Response.tool(), text)
        {:error, text} -> Response.tool() |> Response.text(text) |> Map.put(:isError, true)
      end

    {:reply, response, frame}
  end

  @impl Anubis.Server
  def handle_resource_read(uri, %Frame{context: context} = frame) do
    case read(context, uri, Resources.args(uri), &Resources.read(uri, &1)) do
      {:ok, text} ->
        {:reply, Response.text(Response.resource(), text), frame}

      {:error, :not_found, text} ->
        {:error, Error.resource(:not_found, %{uri: uri, message: text}), frame}

      {:error, _reason, text} ->
        {:error, Error.execution(text), frame}
    end
  end

  @impl Anubis.Server
  def handle_prompt_get(name, args, %Frame{context: context} = frame) do
    case read(context, name, args, &Prompts.get(name, &1)) do
      {:ok, text} ->
        {:reply, Response.user_message(Response.prompt(), text), frame}

      {:error, :not_found, text} ->
        {:error, Error.protocol(:invalid_params, %{message: text}), frame}

      {:error, _reason, text} ->
        {:error, Error.execution(text), frame}
    end
  end

  defp read(context, name, args, fun) do
    case request_scope(context) do
      {:ok, scope} ->
        Pipeline.read(name, args, scope, context.session_id, fun)

      {:error, :unauthorized} ->
        {:error, :unauthorized, ErrorText.unauthorized()}

      {:error, {:internal, error, stacktrace}} ->
        {:error, :internal, log_failure(name, error, stacktrace)}
    end
  end

  # The headers carry the token (decision 16): a failure is logged without
  # the arguments of the stack frames, and never reaches anubis's logging.
  defp request_scope(context) do
    RequestScope.fetch(context.headers || %{}, context.session_id)
  rescue
    error -> {:error, {:internal, error, strip_args(__STACKTRACE__)}}
  end

  defp log_failure(tool, error, stacktrace) do
    ref = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    Logger.error(
      "MCP request #{tool} failed to authenticate (ref #{ref}): " <>
        Exception.format(:error, error, stacktrace)
    )

    ErrorText.internal(ref)
  end

  defp strip_args(stacktrace) do
    Enum.map(stacktrace, fn
      {module, fun, args, location} when is_list(args) -> {module, fun, length(args), location}
      entry -> entry
    end)
  end

  @impl Anubis.Server
  def terminate(_reason, %Frame{context: %{session_id: session_id}}) when is_binary(session_id),
    do: Sessions.delete(session_id, self())

  def terminate(_reason, _frame), do: :ok

  # Idempotent: a repeated `initialize` of the session keeps its entry and
  # identity and refreshes the online entry.
  defp register(%Frame{context: context, assigns: assigns}) do
    session_id = context.session_id

    with %Scope{} = scope <- assigns[:current_scope],
         true <- session_process?(session_id, context.session_pid) do
      case Sessions.lookup(session_id) do
        %{pid: pid} when pid == self() -> :ok
        _other -> :ok = Sessions.register(session_id, scope, self())
      end

      Online.track(session_id, scope, context.client_info || %{})
    else
      _ ->
        Logger.error(
          "MCP session #{inspect(session_id)} not registered: initialize did not run " <>
            "in its session process with an authenticated scope"
        )
    end
  end

  defp session_process?(session_id, session_pid) when is_binary(session_id) do
    registry_mod = AnubisSupervisor.get_session_config(__MODULE__).registry_mod

    session_pid == self() and
      registry_mod.lookup_session(Registry.registry_name(__MODULE__), session_id) == {:ok, self()}
  end

  defp session_process?(_session_id, _session_pid), do: false
end
