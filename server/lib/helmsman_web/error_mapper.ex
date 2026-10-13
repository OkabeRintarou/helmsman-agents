defmodule HelmsmanWeb.ErrorMapper do
  @moduledoc """
  The REST error body and status of a domain error (`add-rest-api`
  decision 5, designs/11 §2): `{"error": code, "message": text,
  "detail": {...}}`.

  `error` codes are the stable interface; messages are English sentences
  for script authors and may change. A reason without a clause is an
  internal error: 500 `internal` with only a reference in `detail`; the
  log has the reference and the reason.

  `test/support/domain_error_reasons.ex` lists a sample of every domain
  error the REST endpoints can return; the tests check that none of them
  is a 500 here, nor `:error` in `HelmsmanMCP.ErrorText`.
  """

  require Logger

  import Plug.Conn

  alias HelmsmanMCP.Present

  @type body :: %{error: String.t(), message: String.t(), detail: map()}
  @type response :: {100..599, body()}

  @doc """
  Maps a domain error `reason` to `{status, body}`. An unknown reason is
  logged with a new reference and answered as 500 `internal`.
  """
  @spec to_response(term()) :: response()
  def to_response(reason) do
    case map(reason) do
      {status, code, detail} -> {status, body(code, detail)}
      :error -> internal("unexpected error: " <> inspect(reason))
    end
  end

  @doc """
  An internal error: logs `details` with a new 8-character reference and
  returns the 500 response, whose `detail` holds only the reference.
  """
  @spec internal(String.t()) :: response()
  def internal(details) when is_binary(details) do
    ref = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Logger.error("REST request failed (ref #{ref}): " <> details)
    {500, body("internal", %{ref: ref})}
  end

  @doc "The error body of `code` with its message."
  @spec body(String.t(), map()) :: body()
  def body(code, detail \\ %{}) when is_binary(code) and is_map(detail),
    do: %{error: code, message: message(code), detail: detail}

  @doc "Sends the error `response` as JSON and halts `conn`."
  @spec send_error(Plug.Conn.t(), response()) :: Plug.Conn.t()
  def send_error(conn, {status, body}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  ## Reasons

  # Request errors raised by the REST layer itself.
  defp map({:invalid_params, fields}) when is_map(fields),
    do: {400, "invalid_params", %{fields: fields}}

  defp map(:invalid_json), do: {400, "invalid_json", %{}}
  defp map(:invalid_params), do: {400, "invalid_params", %{fields: %{}}}
  defp map(:unauthorized), do: {401, "unauthorized", %{}}

  defp map({:insufficient_scope, required}),
    do: {403, "insufficient_scope", %{required: required}}

  defp map(:payload_too_large), do: {413, "payload_too_large", %{}}
  defp map(:unsupported_media_type), do: {415, "unsupported_media_type", %{}}

  # 403
  defp map(:forbidden), do: {403, "forbidden", %{}}

  defp map({:forbidden, {:cancels_other_task, replaced, own}}),
    do: {403, "forbidden", %{replaced: replaced, own: own}}

  defp map({:agent_disabled, name}), do: {403, "agent_disabled", %{actor: name}}
  defp map({:cannot_invoke, agent}), do: {403, "cannot_invoke", %{agent: agent}}
  defp map(reason) when reason in [:no_identity, :no_actor], do: {403, "no_identity", %{}}
  defp map({:design, :not_design_run}), do: {403, "forbidden", %{}}

  # 404
  defp map(:not_found), do: {404, "not_found", %{}}
  defp map({:not_found, ident}) when is_binary(ident), do: {404, "not_found", %{id: ident}}

  # 409
  defp map({:invalid_transition, from, to, allowed}) do
    {409, "invalid_transition",
     %{
       from: Present.status(from),
       to: Present.status(to),
       allowed: Enum.map(allowed, &Present.status/1)
     }}
  end

  defp map({:blocked, blockers}), do: {409, "blocked", %{blockers: blockers}}
  defp map({:replaced, replacers}), do: {409, "replaced", %{replaced_by: replacers}}

  defp map({:self_verify_requires_tests, name}),
    do: {409, "self_verify_requires_tests", %{actor: name}}

  defp map({:cycle, detail}) when is_map(detail), do: {409, "cycle", detail}
  defp map({:cycle, path}), do: {409, "cycle", %{path: path}}
  defp map({:superseded, latest_id}), do: {409, "superseded", %{latest: latest_id}}

  defp map({:run_active, %{id: id, agent: agent}}),
    do: {409, "run_active", %{run_id: id, agent: agent}}

  defp map({:already_retried, id}), do: {409, "already_retried", %{run_id: id}}
  defp map(:rate_limited), do: {409, "run_rate_limited", %{}}
  defp map({:not_dispatched, reason}), do: {409, "not_dispatched", %{reason: json_reason(reason)}}

  defp map(reason)
       when reason in [
              :stale,
              :busy,
              :project_archived,
              :name_taken,
              :already_finished,
              :task_closed,
              :not_ended,
              :not_retryable,
              :agent_disabled,
              :agent_archived,
              :no_runtime,
              :runtime_disabled,
              :run_ended,
              :draft_full
            ],
       do: {409, Atom.to_string(reason), %{}}

  # Reasons of the tools REST does not expose (design runs, `delegate`),
  # mapped so that every reason `HelmsmanMCP.ErrorText` knows has a code.
  defp map({:design, reason}) when reason in [:turn_ended, :not_squad],
    do: {409, Atom.to_string(reason), %{}}

  defp map({:referenced_by_squad, name}), do: {409, "referenced_by_squad", %{name: name}}
  defp map({:not_in_draft, name}), do: {409, "not_in_draft", %{name: name}}
  defp map({:delegate, :task_closed, ident}), do: {409, "task_closed", %{id: ident}}

  defp map({:delegate, reason, _detail})
       when reason in [:not_squad_task, :squad_disabled, :not_leader, :not_member, :person_member],
       do: {409, Atom.to_string(reason), %{}}

  defp map({:delegate_not_dispatched, %{reason: reason}}),
    do: {409, "not_dispatched", %{reason: json_reason(reason)}}

  # 422
  defp map({:validation_failed, fields}) when is_map(fields),
    do: {422, "validation_failed", %{fields: fields}}

  defp map(%Ecto.Changeset{} = changeset),
    do: {422, "validation_failed", %{fields: changeset_fields(changeset)}}

  defp map({:invalid_squad, %Ecto.Changeset{} = changeset}), do: map(changeset)
  defp map({:invalid_agent, _name, %Ecto.Changeset{} = changeset}), do: map(changeset)

  defp map({:invalid_status, input, valid}) do
    {422, "invalid_status",
     %{value: json_reason(input), valid: Enum.map(valid, &Present.status/1)}}
  end

  defp map({:invalid_type, input}), do: {422, "invalid_type", %{value: json_reason(input)}}
  defp map(:self_link), do: {422, "self_link", %{}}

  defp map({code, reason})
       when code in [
              :invalid_commits,
              :invalid_tests,
              :invalid_comment,
              :invalid_feedback,
              :invalid_instructions,
              :invalid_query
            ],
       do: {422, Atom.to_string(code), %{reason: json_reason(reason)}}

  defp map({:invalid_kind, _kind}), do: {422, "invalid_kind", %{}}
  defp map({:invalid, :kind}), do: {422, "invalid_kind", %{}}

  defp map(reason) when reason in [:not_managed, :instructions_required, :is_squad],
    do: {422, Atom.to_string(reason), %{}}

  # `add-bql-filters`: the query language and `query_tasks`' arguments.
  defp map(:bql_or_filter),
    do: {400, "invalid_params", %{fields: %{bql: ["pass either bql or filter_id"]}}}

  defp map({:invalid, field}) when field in [:limit, :offset],
    do: {400, "invalid_params", %{fields: %{field => ["out of range"]}}}

  # `add-bql-filters`: the query language.
  defp map({:invalid_bql, %{message: message, position: position}}),
    do: {422, "invalid_bql", %{message: message, position: position}}

  defp map(:query_timeout), do: {422, "query_timeout", %{}}

  # Workspace backup operations (add-export-import decision 16).
  defp map({:invalid_import, errors}), do: {422, "invalid_import", %{errors: errors}}
  defp map(:confirmation_required), do: {422, "confirmation_required", %{}}
  defp map(:too_large), do: {413, "too_large", %{}}
  defp map(:storage_unavailable), do: {503, "storage_unavailable", %{}}
  defp map({:replace_blocked, reasons}), do: {409, "replace_blocked", %{reasons: reasons}}

  defp map({code, detail}) when code in [:diverged, :actor_kind_conflict] and is_map(detail),
    do: {409, Atom.to_string(code), detail}

  defp map(_reason), do: :error

  ## Details

  @doc """
  The errors of `changeset` by field, with their options interpolated
  (`%{title: ["can't be blank"]}`).
  """
  @spec changeset_fields(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def changeset_fields(%Ecto.Changeset{} = changeset),
    do: Ecto.Changeset.traverse_errors(changeset, &interpolate/1)

  defp interpolate({message, opts}),
    do: Regex.replace(~r/%\{(\w+)\}/, message, fn _match, key -> option(opts, key) end)

  defp option(opts, key) do
    case Enum.find(opts, fn {name, _value} -> Atom.to_string(name) == key end) do
      {_name, value} -> to_string_safe(value)
      nil -> key
    end
  end

  defp to_string_safe(value) when is_binary(value) or is_atom(value) or is_number(value),
    do: to_string(value)

  defp to_string_safe(value), do: inspect(value)

  # A reason as JSON: atoms and strings as strings, lists and tuples of them
  # element by element, anything else inspected.
  defp json_reason(nil), do: nil
  defp json_reason(value) when is_boolean(value), do: value
  defp json_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp json_reason(value) when is_binary(value) or is_number(value), do: value
  defp json_reason(list) when is_list(list), do: Enum.map(list, &json_reason/1)

  defp json_reason(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&json_reason/1)

  defp json_reason(other), do: inspect(other)

  ## Messages

  @messages %{
    "invalid_params" => "The request parameters are invalid; see detail.fields.",
    "invalid_json" => "The request body is not valid JSON.",
    "bad_request" => "The request is invalid.",
    "unauthorized" =>
      "A valid API token is required (Authorization: Bearer hm_...); it may be revoked, " <>
        "expired, or you are no longer a member of the workspace.",
    "insufficient_scope" => "The API token does not have the scope this request needs.",
    "forbidden" => "Your role or identity does not allow this.",
    "agent_disabled" => "The agent is disabled.",
    "cannot_invoke" => "You may not trigger this agent.",
    "no_identity" => "There is no identity to act as.",
    "not_found" => "Not found.",
    "not_acceptable" => "This endpoint only serves JSON.",
    "invalid_transition" => "The task cannot move to this status from its current one.",
    "blocked" => "The task is blocked by tasks that are not finished yet.",
    "replaced" => "The task was replaced by another task.",
    "self_verify_requires_tests" =>
      "The assignee cannot verify their own task without passing tests.",
    "cycle" => "The dependency would create a cycle.",
    "superseded" => "This feedback was already revised; revise the current version.",
    "stale" => "The resource was changed by someone else since you read it (lock_version).",
    "busy" => "Too many concurrent changes; try again.",
    "project_archived" => "The project is archived.",
    "name_taken" => "The name is already taken.",
    "run_active" => "A run is still active on the task.",
    "already_finished" => "The run has already ended.",
    "already_retried" => "The run was already retried by another run.",
    "task_closed" => "The task is verified or cancelled.",
    "not_ended" => "Only a failed or cancelled run can be retried.",
    "not_retryable" => "This run cannot be retried.",
    "agent_archived" => "The agent is archived.",
    "no_runtime" => "The agent is not bound to a runtime.",
    "runtime_disabled" => "The agent's runtime is disabled.",
    "run_rate_limited" => "Too many runs were started on this task recently; try again later.",
    "not_dispatched" => "The agent was not started; see detail.reason.",
    "run_ended" => "The run has ended.",
    "draft_full" => "The draft is full.",
    "turn_ended" => "The design turn has ended.",
    "not_squad" => "This is not a squad conversation.",
    "referenced_by_squad" => "The agent is part of the draft's squad.",
    "not_in_draft" => "The agent is not in the draft.",
    "not_squad_task" => "The task is not assigned to the squad.",
    "squad_disabled" => "The squad is disabled.",
    "not_leader" => "You do not lead the squad.",
    "not_member" => "The agent is not a member of the squad.",
    "person_member" => "A person cannot be delegated a run.",
    "validation_failed" => "Some fields are invalid; see detail.fields.",
    "invalid_status" => "Unknown status.",
    "invalid_type" => "Unknown link type; use depends_on or replaces.",
    "self_link" => "A task cannot be linked to itself.",
    "invalid_commits" => "Invalid commit hashes: each must be 7-64 hexadecimal characters.",
    "invalid_tests" => "Invalid tests: pass {command, passed, summary}.",
    "invalid_comment" => "Invalid comment (a string of at most 10000 characters).",
    "invalid_feedback" => "Invalid feedback: pass {kind, content}.",
    "invalid_instructions" => "Invalid instructions (a string of at most 8 KB).",
    "invalid_query" => "Invalid search query (a string of at most 200 characters).",
    "invalid_kind" => "Unknown kind.",
    "not_managed" => "Only managed agents can be started.",
    "instructions_required" => "Instructions are required without a task.",
    "is_squad" => "This identity is a squad; assign the task to it or mention it instead.",
    "invalid_bql" => "The BQL query is invalid; see detail.message and detail.position.",
    "query_timeout" => "The query took too long; narrow it down.",
    "payload_too_large" => "The request body is too large.",
    "unsupported_media_type" => "Request bodies must be JSON (content-type: application/json).",
    "rate_limited" => "Too many requests; retry after the time in the Retry-After header.",
    "internal" =>
      "Internal error. Try again later; if it keeps happening, report the reference in " <>
        "detail.ref.",
    "invalid_import" => "The snapshot is invalid; see detail.errors.",
    "diverged" => "The local and imported task histories have diverged.",
    "actor_kind_conflict" => "The actor name has a different kind; use rename.",
    "replace_blocked" => "Active runs or open pull requests prevent replacement.",
    "confirmation_required" => "Confirm replacement with the workspace slug.",
    "too_large" => "The snapshot exceeds the configured import size limit.",
    "storage_unavailable" => "Backup storage is unavailable."
  }

  @doc "The English message of an error `code`."
  @spec message(String.t()) :: String.t()
  def message(code), do: Map.get(@messages, code, "Error.")
end
