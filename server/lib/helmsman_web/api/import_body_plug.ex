defmodule HelmsmanWeb.API.ImportBodyPlug do
  @moduledoc "Authenticates and validates snapshot uploads before reading or creating a file."
  @behaviour Plug
  import Plug.Conn
  alias Helmsman.Actors.Actor
  alias Helmsman.Backup
  alias Helmsman.Backup.Files
  alias HelmsmanWeb.API.{BackupAccess, BackupController, ToolAction, WorkspaceSlug}
  alias HelmsmanWeb.Plugs.BearerAuth
  alias OpenApiSpex.{MediaType, PathItem, RequestBody, Schema}
  alias Plug.Conn.{InvalidQueryError, Utils}

  def init(opts), do: opts
  def routes, do: [{:post, "/api/v1/w/:slug/imports"}]

  def call(
        %Plug.Conn{method: "POST", path_info: ["api", "v1", "w", slug, "imports"]} = conn,
        _opts
      ) do
    conn = %{conn | path_params: %{"slug" => slug}}
    conn = BearerAuth.call(conn, BearerAuth.init(scope: "api:write", via: :api))
    conn = if conn.halted, do: conn, else: WorkspaceSlug.call(conn, [])

    if conn.halted,
      do: conn,
      else: ToolAction.guarded(conn, "import_workspace", fn -> handle(conn) end)
  end

  def call(conn, _opts), do: conn

  defp handle(conn) do
    with {:ok, scope} <- BackupAccess.scope(conn),
         {:ok, opts} <- options(conn),
         :ok <- confirm(scope, opts),
         {:ok, opts} <- Backup.options(scope, opts),
         false <- Backup.busy?(scope.workspace.id),
         :ok <- Files.ready(),
         :ok <- media(conn),
         :ok <- length_header(conn),
         {:ok, file} <- Files.create(:imports, scope.workspace.id) do
      upload(conn, scope, opts, file)
    else
      true -> {:error, :busy}
      error -> error
    end
  end

  defp options(conn) do
    params = fetch_query_params(conn).query_params
    mode = params["mode"] || "merge"
    source = params["source"] || "helmsman"
    dry_run = params["dry_run"] || "false"
    rename = params["rename"] || %{}

    if valid_options?(mode, source, dry_run, rename) do
      {:ok,
       [
         mode: String.to_existing_atom(mode),
         source: String.to_existing_atom(source),
         dry_run: dry_run == "true",
         rename: rename,
         confirm: params["confirm"]
       ]}
    else
      invalid_query()
    end
  rescue
    InvalidQueryError -> invalid_query()
  end

  defp invalid_query,
    do: {:error, {:invalid_params, %{query: ["invalid mode, source, dry_run or rename"]}}}

  defp valid_options?(mode, source, dry_run, rename),
    do:
      mode in ["merge", "replace"] and source in ["helmsman", "bosun"] and
        dry_run in ["true", "false"] and valid_rename?(rename)

  defp valid_rename?(rename) when is_map(rename), do: Enum.all?(rename, &valid_rename_pair?/1)
  defp valid_rename?(_rename), do: false

  defp valid_rename_pair?({old, new}) when is_binary(old) and is_binary(new),
    do:
      Actor.valid_name?(old) and Actor.valid_name?(new) and
        old == "helmsman" == (new == "helmsman")

  defp valid_rename_pair?(_pair), do: false

  defp confirm(scope, opts) do
    if opts[:mode] == :replace and opts[:confirm] != scope.workspace.slug,
      do: {:error, :confirmation_required},
      else: :ok
  end

  defp media(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        case Utils.media_type(value) do
          {:ok, "application", type, _} when type in ["json", "gzip"] -> :ok
          _ -> {:error, :unsupported_media_type}
        end

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  defp length_header(conn) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> check_length(size)
          _ -> {:error, {:invalid_params, %{content_length: ["must be a nonnegative integer"]}}}
        end

      _ ->
        {:error, {:invalid_params, %{content_length: ["must be a single value"]}}}
    end
  end

  defp check_length(size), do: if(size > limit(), do: {:error, :too_large}, else: :ok)

  defp limit, do: Application.fetch_env!(:helmsman, :import_max_bytes)

  defp upload(conn, scope, opts, file) do
    case stream(conn, file.io, 0) do
      {:ok, conn} ->
        :ok = File.close(file.io)
        enqueue(conn, scope, file.path, opts)

      {:error, reason, conn} ->
        ToolAction.error(conn, reason)
    end
  after
    File.close(file.io)
    File.rm(file.path)
  end

  defp enqueue(conn, scope, path, opts) do
    case Backup.start_import(scope, path, opts) do
      {:ok, record} ->
        conn |> ToolAction.data(202, BackupController.import_record(record)) |> halt()

      {:error, reason} ->
        ToolAction.error(conn, reason)
    end
  end

  defp stream(conn, io, size) do
    case read_body(conn, length: 64 * 1024, read_length: 64 * 1024) do
      {status, chunk, next} when status in [:ok, :more] ->
        write_chunk(next, io, size, chunk, status)

      {:error, _reason} ->
        {:error, {:invalid_params, %{body: ["upload interrupted"]}}, conn}
    end
  end

  defp write_chunk(conn, io, size, chunk, status) do
    next = size + byte_size(chunk)

    if next > limit() do
      {:error, :too_large, conn}
    else
      case :file.write(io, chunk) do
        :ok when status == :ok -> {:ok, conn}
        :ok -> stream(conn, io, next)
        {:error, _reason} -> {:error, :storage_unavailable, conn}
      end
    end
  end

  def paths do
    operation =
      BackupAccess.operation(
        id: "import_workspace",
        summary: "import_workspace",
        tag: "backups",
        write: true,
        status: 202,
        response: HelmsmanWeb.API.Schemas.ImportRecord,
        errors: [503],
        description:
          "Admin merge or owner replace as your human identity. The default agent is ignored. Authentication, workspace, identity, parameters, confirmation, role, concurrency, storage and media checks run before any upload bytes are read. JSON or gzip, at most the configured import_max_bytes (default 300 MB); uploads are processed asynchronously and then deleted.",
        params: [
          {:mode, :query, %Schema{type: :string, enum: ["merge", "replace"], default: "merge"},
           "Import mode."},
          {:dry_run, :query, %Schema{type: :boolean, default: false},
           "Execute then roll back domain changes."},
          {:source, :query,
           %Schema{type: :string, enum: ["helmsman", "bosun"], default: "helmsman"},
           "Snapshot source."},
          {:confirm, :query, %Schema{type: :string}, "Required workspace slug for replace."},
          {:rename, :query, %Schema{type: :object, additionalProperties: %Schema{type: :string}},
           "Identity mappings encoded as rename[old]=new."}
        ]
      )

    request = %RequestBody{
      required: true,
      content: %{
        "application/json" => %MediaType{
          schema: %Schema{
            type: :object,
            description: "Complete helmsman-export v1 or bosun-export v2 snapshot."
          }
        },
        "application/gzip" => %MediaType{schema: %Schema{type: :string, format: :binary}}
      }
    }

    %{"/api/v1/w/{slug}/imports" => %PathItem{post: %{operation | requestBody: request}}}
  end
end
