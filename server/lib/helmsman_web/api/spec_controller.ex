defmodule HelmsmanWeb.API.SpecController do
  @moduledoc """
  `/tasks/:id/spec…`: task specs over REST (`add-spec-workflow` decision
  21, rest-api 「规格端点」). The endpoints with an MCP tool run it
  (`HelmsmanWeb.API.ToolAction`); the audit events, `reject` (people
  only), and the OpenSpec directory export and import are REST only.

  `POST /tasks/:id/spec/import` takes a `tar.gz` or `zip` body: the
  endpoint does not parse it (`HelmsmanWeb.API.BodyParser`) and the
  route's pipeline has no JSON check; authentication, scope, workspace,
  identity, parameters and permission are checked before the body is
  read, then at most 2 MB of it.
  """

  use HelmsmanWeb.API.Controller

  import Plug.Conn

  alias Helmsman.TaskSpecs
  alias HelmsmanMCP.SpecPresent

  alias HelmsmanMCP.Tools.{
    CancelSpecReview,
    DiffSpec,
    FinalizeSpec,
    GetSpec,
    ListSpecReviews,
    ReplySpecIssue,
    RequestSpecReview,
    RuleSpecIssue,
    SubmitSpecReview,
    SubmitSpecVersion,
    UpdateSpec
  }

  alias HelmsmanWeb.API.Params
  alias OpenApiSpex.{MediaType, RequestBody, Schema}
  alias Plug.Conn.Utils

  @task [task_id: "id"]
  @media %{"gzip" => "application/gzip", "zip" => "application/zip"}

  tool_action(:show, GetSpec, path: @task, response: Schemas.SpecDetail, tag: "specs")
  tool_action(:diff, DiffSpec, path: @task, response: Schemas.SpecDiff, tag: "specs")
  tool_action(:reviews, ListSpecReviews, path: @task, response: Schemas.SpecReviews, tag: "specs")

  tool_action(:create_review, SubmitSpecReview,
    path: @task,
    status: 201,
    response: Schemas.SpecReviewResult,
    tag: "specs"
  )

  tool_action(:reply, ReplySpecIssue,
    path: [task_id: "id", issue: "issue"],
    status: 201,
    response: Schemas.SpecNoteResult,
    tag: "specs"
  )

  tool_action(:rule, RuleSpecIssue,
    path: [task_id: "id", issue: "issue"],
    status: 201,
    response: Schemas.SpecNoteResult,
    tag: "specs"
  )

  tool_action(:request_reviews, RequestSpecReview,
    path: @task,
    status: 201,
    response: Schemas.SpecRequests,
    tag: "specs"
  )

  tool_action(:cancel_request, CancelSpecReview,
    path: [task_id: "id", reviewer: "reviewer"],
    response: Schemas.SpecCancelResult,
    tag: "specs"
  )

  tool_action(:finalize, FinalizeSpec, path: @task, response: Schemas.SpecDecision, tag: "specs")

  @doc "`PATCH /tasks/:id/spec` (`update_spec`): 201 when it creates the spec."
  def update(conn, %{"id" => ident}) do
    ToolAction.guarded(conn, "update_spec", fn ->
      with {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
           {:ok, existing} <- TaskSpecs.summary(scope, ident) do
        ToolAction.run(conn, UpdateSpec, path: @task, status: if(existing, do: 200, else: 201))
      end
    end)
  end

  @doc "`POST /tasks/:id/spec/versions` (`submit_spec_version`): 201, a dry run 200."
  def create_version(conn, _params) do
    status = if match?(%{"dry_run" => true}, conn.body_params), do: 200, else: 201
    ToolAction.run(conn, SubmitSpecVersion, path: @task, status: status)
  end

  @doc "`GET /tasks/:id/spec/events`: the audit events."
  def events(conn, %{"id" => ident}) do
    read(conn, "list_spec_events", fn scope ->
      with {:ok, events} <- TaskSpecs.events(scope, ident), do: {:ok, SpecPresent.events(events)}
    end)
  end

  @doc "`POST /tasks/:id/spec/reject`: a person sends the proposal back."
  def reject(conn, %{"id" => ident}) do
    ToolAction.guarded(conn, "reject_spec", fn ->
      with {:ok, body} <- Params.body(conn),
           {:ok, attrs} <- reject_attrs(body),
           {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, result} <-
             ToolAction.write(
               conn.assigns.current_scope,
               requested,
               &TaskSpecs.reject(&1, ident, attrs)
             ) do
        ToolAction.data(conn, 200, %{
          spec: SpecPresent.summary(result.spec),
          dispatch: result.dispatch
        })
      end
    end)
  end

  defp reject_attrs(body) do
    case {body["reason"], Map.get(body, "wake", true)} do
      {reason, wake} when is_binary(reason) and is_boolean(wake) ->
        {:ok, %{reason: reason, wake: wake}}

      _other ->
        {:error,
         {:invalid_params, %{"body" => ["reason (a string) is required; wake is a boolean"]}}}
    end
  end

  @doc "`GET /me/specs`: the specs waiting for the current user."
  def attention(conn, _params) do
    read(conn, "list_my_specs", fn scope ->
      with {:ok, attention} <- TaskSpecs.attention(scope),
           do: {:ok, SpecPresent.attention(attention)}
    end)
  end

  defp read(conn, name, fun) do
    ToolAction.guarded(conn, name, fn ->
      with {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
           {:ok, value} <- fun.(scope) do
        ToolAction.data(conn, 200, value)
      end
    end)
  end

  ## Export

  @doc "`GET /tasks/:id/spec/export`: the OpenSpec change directory as an attachment."
  def export(conn, %{"id" => ident}) do
    ToolAction.guarded(conn, "export_spec", fn ->
      with {:ok, opts} <- export_options(conn.query_params),
           {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, _source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested),
           {:ok, archive} <- TaskSpecs.export_archive(scope, ident, opts) do
        conn
        |> put_resp_content_type(archive.content_type, nil)
        |> put_resp_header("content-disposition", ~s[attachment; filename="#{archive.filename}"])
        |> send_resp(200, archive.body)
      end
    end)
  end

  defp export_options(params) do
    with {:ok, version} <- optional_integer(params, "version", 1),
         {:ok, format} <- one_of(params, "format", ["tar.gz", "zip"], "tar.gz"),
         {:ok, reviews} <- one_of(params, "reviews", ["true", "false"], "false") do
      {:ok, [version: version, format: format, reviews: reviews == "true"]}
    end
  end

  ## Import

  @doc """
  `POST /tasks/:id/spec/import`: the body (a `tar.gz` or `zip`) as a new
  version, 201 (a dry run 200).
  """
  def import(conn, %{"id" => ident}) do
    ToolAction.guarded(conn, "import_spec", fn -> import_checked(conn, ident) end)
  end

  defp import_checked(conn, ident) do
    scope = conn.assigns.current_scope

    with {:ok, opts} <- import_options(fetch_query_params(conn).query_params),
         {:ok, requested} <- Params.requested_actor(conn, nil),
         {:ok, :allowed} <- ToolAction.write(scope, requested, &may_import(&1, ident)),
         :ok <- media(conn),
         :ok <- length_header(conn),
         {:ok, body, conn} <- body(conn),
         {:ok, result} <-
           ToolAction.write(scope, requested, &TaskSpecs.import_archive(&1, ident, body, opts)) do
      status = if opts[:dry_run], do: 200, else: 201
      ToolAction.data(conn, status, SpecPresent.import_result(result))
    end
  end

  defp import_options(params) do
    with {:ok, base} <- required_integer(params, "base_version"),
         {:ok, dry_run} <- one_of(params, "dry_run", ["true", "false"], "false"),
         {:ok, note} <- optional_string(params, "note") do
      {:ok, [base_version: base, note: note, dry_run: dry_run == "true"]}
    end
  end

  # The permission to submit a version, before any byte of the body.
  defp may_import(scope, ident) do
    case TaskSpecs.permissions(scope, ident) do
      {:ok, %{write: true}} -> {:ok, :allowed}
      {:ok, _permissions} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp media(conn) do
    with [value] <- get_req_header(conn, "content-type"),
         {:ok, "application", type, _params} when is_map_key(@media, type) <-
           Utils.media_type(value) do
      :ok
    else
      _other -> {:error, :unsupported_media_type}
    end
  end

  defp length_header(conn) do
    case get_req_header(conn, "content-length") do
      [] -> :ok
      [value] -> content_length(Integer.parse(value))
      _many -> {:error, {:invalid_params, %{"content-length" => ["must be a single value"]}}}
    end
  end

  defp content_length({size, ""}) when size >= 0 do
    if size > TaskSpecs.archive_max_bytes(), do: {:error, :payload_too_large}, else: :ok
  end

  defp content_length(_invalid),
    do: {:error, {:invalid_params, %{"content-length" => ["must be an integer"]}}}

  defp body(conn) do
    case read_body(conn, length: TaskSpecs.archive_max_bytes(), read_length: 64 * 1024) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :payload_too_large}
      {:error, _reason} -> {:error, {:invalid_params, %{"body" => ["upload interrupted"]}}}
    end
  end

  ## Query parameters

  defp required_integer(params, name) do
    case optional_integer(params, name, 0) do
      {:ok, nil} -> {:error, {:invalid_params, %{name => ["is required"]}}}
      result -> result
    end
  end

  defp optional_integer(params, name, min) do
    case params[name] do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= min -> {:ok, n}
          _other -> {:error, {:invalid_params, %{name => ["must be an integer >= #{min}"]}}}
        end

      _other ->
        {:error, {:invalid_params, %{name => ["must be an integer >= #{min}"]}}}
    end
  end

  defp optional_string(params, name) do
    case params[name] do
      value when is_binary(value) or is_nil(value) -> {:ok, value}
      _other -> {:error, {:invalid_params, %{name => ["must be a string"]}}}
    end
  end

  defp one_of(params, name, values, default) do
    value = params[name] || default

    if value in values,
      do: {:ok, value},
      else: {:error, {:invalid_params, %{name => ["must be one of: #{Enum.join(values, ", ")}"]}}}
  end

  ## OpenAPI

  @doc false
  def operation(:update) do
    op = Operations.tool(UpdateSpec, path: @task, response: Schemas.Spec, tag: "specs")
    %{op | description: op.description <> "\n\n201 (same body) when it creates the spec."}
  end

  def operation(:create_version) do
    op =
      Operations.tool(SubmitSpecVersion,
        path: @task,
        status: 201,
        response: Schemas.SpecVersionResult,
        tag: "specs"
      )

    %{op | description: op.description <> "\n\n200 (same body) for a dry run."}
  end

  def operation(:events) do
    Operations.manual(
      id: "list_spec_events",
      summary: "list_spec_events",
      description: "The audit events of a task's spec, oldest first.",
      tag: "specs",
      params: [{:id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."}],
      response: Schemas.SpecEvents
    )
  end

  def operation(:reject) do
    Operations.manual(
      id: "reject_spec",
      summary: "reject_spec",
      description:
        "Send a spec's proposal back to draft (people only: an agent identity gets 403). " <>
          "wake (default true) wakes the assignee with the decision.",
      tag: "specs",
      write: true,
      params: [{:id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."}],
      body: %Schema{
        type: :object,
        properties: %{
          reason: %Schema{type: :string, description: "Why (at most 4 KB)."},
          wake: %Schema{type: :boolean, description: "Wake the assignee (default true)."}
        },
        required: [:reason]
      },
      response: Schemas.SpecDecision
    )
  end

  def operation(:attention) do
    Operations.manual(
      id: "list_my_specs",
      summary: "list_my_specs",
      description:
        "Specs waiting for you: proposals to approve and review requests for your human " <>
          "identity.",
      tag: "specs",
      response: Schemas.SpecAttention
    )
  end

  def operation(:export) do
    Operations.manual(
      id: "export_spec",
      summary: "export_spec",
      description:
        "A version of a task's spec as an OpenSpec change directory (<change_id>/ with " <>
          ".openspec.yaml, the files and, with reviews, reviews/spec-review-<n>.md), as the " <>
          "attachment <change_id>-v<n>.tar.gz or .zip. openspec validate reads it.",
      tag: "specs",
      params: [
        {:id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."},
        {:version, :query, %Schema{type: :integer, minimum: 1}, "Default the latest."},
        {:format, :query, %Schema{type: :string, enum: ["tar.gz", "zip"], default: "tar.gz"},
         "Archive format."},
        {:reviews, :query, %Schema{type: :boolean, default: false}, "Include the reviews."}
      ],
      content_type: "application/gzip",
      response: %Schema{type: :string, format: :binary}
    )
    |> then(fn op ->
      zip = %MediaType{schema: %Schema{type: :string, format: :binary}}
      update_in(op.responses[200].content, &Map.put(&1, "application/zip", zip))
    end)
  end

  def operation(:import) do
    op =
      Operations.manual(
        id: "import_spec",
        summary: "import_spec",
        description:
          "Submit an OpenSpec change directory (tar.gz or zip, at most 2 MB, 200 entries and " <>
            "1 MB of files) as a new version replacing every file of base_version. The common " <>
            "directory prefix (e.g. openspec/changes/<id>/) is removed; .openspec.yaml and " <>
            "reviews/ are ignored, other paths come back as warnings. Before the first " <>
            "version a free directory name becomes the change_id. Authentication, workspace, " <>
            "identity, parameters and permission are checked before the body is read. A " <>
            "dry run answers 200.",
        tag: "specs",
        write: true,
        status: 201,
        params: [
          {:id, :path, %Schema{type: :string}, "Task ID (e.g. BOS-12)."},
          {:base_version, :query, %Schema{type: :integer, minimum: 0},
           "The latest version (0 when there is none); required."},
          {:note, :query, %Schema{type: :string}, "What changed (at most 4 KB)."},
          {:dry_run, :query, %Schema{type: :boolean, default: false},
           "Only check and compare (200)."}
        ],
        response: Schemas.SpecVersionResult
      )

    binary = %MediaType{schema: %Schema{type: :string, format: :binary}}

    %{
      op
      | requestBody: %RequestBody{
          required: true,
          content: %{"application/gzip" => binary, "application/zip" => binary}
        }
    }
  end
end
