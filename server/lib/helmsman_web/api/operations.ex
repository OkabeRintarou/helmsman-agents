defmodule HelmsmanWeb.API.Operations do
  @moduledoc """
  The OpenAPI operations of the REST endpoints (`add-rest-api` decision 8).

  An endpoint backed by an MCP tool gets its parameters from the tool's
  `input_schema/0` (through anubis' JSON Schema conversion): arguments
  mapped from the path become path parameters, the others query
  parameters (`GET`, read tools) or the JSON request body (write tools);
  the description is the tool's. Response schemas come from
  `HelmsmanWeb.API.Schemas`; every error status refers to `Error`.
  """

  alias Anubis.Server.Component.Schema, as: ToolSchema
  alias HelmsmanWeb.API.Schemas
  alias OpenApiSpex.{MediaType, Operation, Parameter, RequestBody, Response, Schema}

  @read_errors [400, 401, 403, 404, 422, 429, 500]
  @write_errors [400, 401, 403, 404, 409, 413, 415, 422, 429, 500]

  @error_descriptions %{
    400 => "Invalid parameters or JSON (invalid_params, invalid_json).",
    401 => "Missing, invalid, revoked or expired token (unauthorized).",
    403 => "Missing scope or not allowed (insufficient_scope, forbidden, agent_disabled).",
    404 => "Not found (not_found).",
    409 => "Conflict with the current state (invalid_transition, blocked, stale, ...).",
    413 => "Request body too large (payload_too_large).",
    415 => "Request body is not JSON (unsupported_media_type).",
    422 => "Invalid field values (validation_failed, invalid_status, ...).",
    429 => "Rate limited (rate_limited); see Retry-After.",
    500 => "Internal error (internal); detail.ref is in the server log."
  }

  @doc """
  The operation of an endpoint backed by `tool`, with the `ToolAction`
  options `opts` (`:path`, `:drop`, `:status`), `:response` (a schema
  module) and `:body` (`true`: the arguments come in a JSON body although
  the tool reads, as `save_filter` does).
  """
  @spec tool(module(), keyword()) :: Operation.t()
  def tool(tool, opts) do
    json = ToolSchema.to_json_schema(tool.input_schema())
    properties = Map.get(json, "properties", %{})
    required = Map.get(json, "required", [])
    path_specs = Keyword.get(opts, :path, [])
    path_names = Enum.map(path_specs, fn {arg, _spec} -> Atom.to_string(arg) end)
    dropped = path_names ++ Enum.map(Keyword.get(opts, :drop, []), &Atom.to_string/1)
    rest = Map.drop(properties, dropped)
    rest_required = required -- dropped
    mode = if opts[:body], do: :write, else: tool.mode()

    params =
      workspace_params() ++
        Enum.flat_map(path_specs, &path_params(&1, properties)) ++
        if(mode == :read, do: query_params(rest, rest_required), else: [])

    %Operation{
      operationId: tool.name(),
      summary: tool.name(),
      description:
        tool.description() <>
          "\n\nSame as the MCP tool `#{tool.name()}`: same arguments and result.",
      tags: List.wrap(opts[:tag]),
      parameters: params,
      requestBody: if(mode == :write, do: request_body(rest, rest_required)),
      responses:
        success(Keyword.get(opts, :status, 200), opts[:response])
        |> Map.merge(errors(if mode == :read, do: @read_errors, else: @write_errors))
    }
  end

  @doc """
  The operation of an endpoint without a tool.

  ## Options

    * `:id`, `:summary`, `:description`, `:tag`
    * `:params` - `[{name, :path | :query, schema, description}]` (atom names) after
      the workspace parameters (`public: true`: none)
    * `:body` - the request body schema
    * `:status` / `:response` - the success status and schema
    * `:write` - `true` for a write (more error statuses)
    * `:public` - `true`: no authentication (`security: []`)
    * `:content_type` - the success content type (default JSON)
  """
  @spec manual(keyword()) :: Operation.t()
  def manual(opts) do
    public? = Keyword.get(opts, :public, false)

    params =
      if(public?, do: [], else: workspace_params()) ++
        Enum.map(Keyword.get(opts, :params, []), &param/1)

    error_statuses =
      cond do
        public? -> [400, 429, 500]
        opts[:write] -> @write_errors
        true -> @read_errors
      end

    %Operation{
      operationId: Keyword.fetch!(opts, :id),
      summary: Keyword.fetch!(opts, :summary),
      description: opts[:description],
      tags: List.wrap(opts[:tag]),
      parameters: params,
      requestBody: opts[:body] && body(opts[:body], false),
      security: if(public?, do: []),
      responses:
        success(Keyword.get(opts, :status, 200), opts[:response], opts[:content_type])
        |> Map.merge(errors(error_statuses))
    }
  end

  @doc "Converts a JSON Schema map (anubis' output) to an `OpenApiSpex.Schema`."
  @spec to_schema(map()) :: Schema.t()
  def to_schema(%{"oneOf" => schemas} = json),
    do: %Schema{oneOf: Enum.map(schemas, &to_schema/1), description: json["description"]}

  def to_schema(%{"type" => "array"} = json) do
    %Schema{
      type: :array,
      items: to_schema(Map.get(json, "items", %{})),
      description: json["description"]
    }
  end

  def to_schema(%{"type" => "object"} = json) do
    %Schema{
      type: :object,
      properties: Map.new(Map.get(json, "properties", %{}), fn {k, v} -> {k, to_schema(v)} end),
      required: json["required"],
      description: json["description"]
    }
  end

  def to_schema(%{"type" => type} = json) when type in ~w(string integer boolean number),
    do: %Schema{type: String.to_existing_atom(type), description: json["description"]}

  def to_schema(json) when is_map(json), do: %Schema{description: json["description"]}

  ## Parameters

  defp workspace_params do
    [
      param({"slug", :path, %Schema{type: :string}, "The token's workspace slug."}),
      %Parameter{
        name: :"X-Helmsman-Actor",
        in: :header,
        required: false,
        description:
          "Act as this agent of yours (default: the token's default agent, else your " <>
            "human identity).",
        schema: %Schema{type: :string}
      }
    ]
  end

  defp param({name, location, schema, description}) do
    %Parameter{
      name: to_atom(name),
      in: location,
      required: location == :path,
      description: description,
      schema: schema
    }
  end

  defp path_params({_arg, {:feedback_id, id, seq}}, _properties) do
    [
      param({id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."}),
      param({seq, :path, %Schema{type: :integer}, "Feedback number in the task (BOS-12#3: 3)."})
    ]
  end

  defp path_params({arg, {:integer, name}}, properties) do
    json = Map.get(properties, Atom.to_string(arg), %{})
    [param({name, :path, %Schema{type: :integer, minimum: 1}, json["description"]})]
  end

  defp path_params({arg, name}, properties) when is_binary(name) do
    json = Map.get(properties, Atom.to_string(arg), %{})
    [param({name, :path, to_schema(json), json["description"]})]
  end

  defp query_params(properties, required) do
    properties
    |> Enum.sort_by(fn {name, _json} -> name end)
    |> Enum.map(fn {name, json} ->
      %Parameter{
        name: to_atom(name),
        in: :query,
        required: name in required,
        description: query_description(json),
        schema: to_schema(json),
        style: :form,
        explode: false
      }
    end)
  end

  defp query_description(%{"type" => "array"} = json),
    do: "#{json["description"]} (comma separated, or repeated as name[]=)"

  defp query_description(%{"oneOf" => _} = json),
    do: "#{json["description"]} (comma separated, or repeated as name[]=)"

  defp query_description(json), do: json["description"]

  defp request_body(properties, required) do
    schema = %Schema{
      type: :object,
      properties: Map.new(properties, fn {name, json} -> {name, to_schema(json)} end),
      required: if(required == [], do: nil, else: required)
    }

    body(schema, required != [])
  end

  defp body(schema, required?) do
    %RequestBody{
      required: required?,
      content: %{"application/json" => %MediaType{schema: schema}}
    }
  end

  ## Responses

  defp success(status, schema, content_type \\ nil)

  defp success(status, schema, nil) do
    data = %Schema{type: :object, properties: %{data: schema}, required: [:data]}

    %{
      status => %Response{
        description: "Success: the result in data.",
        content: %{"application/json" => %MediaType{schema: data}}
      }
    }
  end

  defp success(status, schema, content_type) do
    %{
      status => %Response{
        description: "Success.",
        content: %{content_type => %MediaType{schema: schema}}
      }
    }
  end

  defp errors(statuses) do
    Map.new(statuses, fn status ->
      {status,
       %Response{
         description: @error_descriptions[status],
         content: %{"application/json" => %MediaType{schema: Schemas.Error}}
       }}
    end)
  end

  defp to_atom(name) when is_atom(name), do: name
  # Names of tool arguments and path parameters: atoms of the code.
  defp to_atom(name) when is_binary(name), do: String.to_existing_atom(name)
end
