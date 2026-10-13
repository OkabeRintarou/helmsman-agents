defmodule HelmsmanWeb.API.ErrorMapperTest do
  # add-rest-api decision 5: one case per row of the error table.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias HelmsmanWeb.ErrorMapper

  defp changeset do
    {%{}, %{title: :string}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:title, "should be at most %{count} character(s)", count: 200)
  end

  @rows [
    {{:invalid_params, %{"limit" => ["must be an integer"]}}, 400, "invalid_params",
     %{fields: %{"limit" => ["must be an integer"]}}},
    {:invalid_json, 400, "invalid_json", %{}},
    {:unauthorized, 401, "unauthorized", %{}},
    {{:insufficient_scope, ["api:write"]}, 403, "insufficient_scope", %{required: ["api:write"]}},
    {:forbidden, 403, "forbidden", %{}},
    {{:forbidden, {:cancels_other_task, "BOS-2", "BOS-1"}}, 403, "forbidden",
     %{replaced: "BOS-2", own: "BOS-1"}},
    {{:agent_disabled, "keel/dev"}, 403, "agent_disabled", %{actor: "keel/dev"}},
    {{:cannot_invoke, "keel/dev"}, 403, "cannot_invoke", %{agent: "keel/dev"}},
    {:not_found, 404, "not_found", %{}},
    {{:not_found, "BOS-9"}, 404, "not_found", %{id: "BOS-9"}},
    {{:invalid_transition, :done, :cancelled, [:verified, :rejected]}, 409, "invalid_transition",
     %{from: "DONE", to: "CANCELLED", allowed: ["VERIFIED", "REJECTED"]}},
    {{:blocked, ["BOS-1"]}, 409, "blocked", %{blockers: ["BOS-1"]}},
    {{:replaced, ["BOS-3"]}, 409, "replaced", %{replaced_by: ["BOS-3"]}},
    {{:self_verify_requires_tests, "keel/dev"}, 409, "self_verify_requires_tests",
     %{actor: "keel/dev"}},
    {{:cycle, ["BOS-1", "BOS-2", "BOS-1"]}, 409, "cycle", %{path: ["BOS-1", "BOS-2", "BOS-1"]}},
    {{:superseded, "BOS-1#4"}, 409, "superseded", %{latest: "BOS-1#4"}},
    {:stale, 409, "stale", %{}},
    {:busy, 409, "busy", %{}},
    {:project_archived, 409, "project_archived", %{}},
    {:name_taken, 409, "name_taken", %{}},
    {{:run_active, %{id: 881, agent: "keel/dev"}}, 409, "run_active",
     %{run_id: 881, agent: "keel/dev"}},
    {:already_finished, 409, "already_finished", %{}},
    {{:already_retried, 882}, 409, "already_retried", %{run_id: 882}},
    {:task_closed, 409, "task_closed", %{}},
    {:not_ended, 409, "not_ended", %{}},
    {:not_retryable, 409, "not_retryable", %{}},
    {:agent_disabled, 409, "agent_disabled", %{}},
    {:agent_archived, 409, "agent_archived", %{}},
    {:no_runtime, 409, "no_runtime", %{}},
    {:runtime_disabled, 409, "runtime_disabled", %{}},
    {:rate_limited, 409, "run_rate_limited", %{}},
    {{:not_dispatched, :unauthorized}, 409, "not_dispatched", %{reason: "unauthorized"}},
    {{:invalid_status, "DONEE", [:new, :done]}, 422, "invalid_status",
     %{value: "DONEE", valid: ["NEW", "DONE"]}},
    {{:invalid_type, "blocks"}, 422, "invalid_type", %{value: "blocks"}},
    {:self_link, 422, "self_link", %{}},
    {{:invalid_commits, ["xyz"]}, 422, "invalid_commits", %{reason: ["xyz"]}},
    {{:invalid_tests, :not_an_object}, 422, "invalid_tests", %{reason: "not_an_object"}},
    {{:invalid_comment, :too_long}, 422, "invalid_comment", %{reason: "too_long"}},
    {{:invalid_feedback, :not_an_object}, 422, "invalid_feedback", %{reason: "not_an_object"}},
    {{:invalid_instructions, :too_long}, 422, "invalid_instructions", %{reason: "too_long"}},
    {{:invalid_query, :too_long}, 422, "invalid_query", %{reason: "too_long"}},
    {{:invalid_kind, "squad"}, 422, "invalid_kind", %{}},
    {{:invalid, :kind}, 422, "invalid_kind", %{}},
    {:not_managed, 422, "not_managed", %{}},
    {:instructions_required, 422, "instructions_required", %{}},
    {:is_squad, 422, "is_squad", %{}},
    {{:invalid_bql, %{message: "unexpected end", position: 7}}, 422, "invalid_bql",
     %{message: "unexpected end", position: 7}},
    {:query_timeout, 422, "query_timeout", %{}},
    {:bql_or_filter, 400, "invalid_params", %{fields: %{bql: ["pass either bql or filter_id"]}}},
    {{:invalid, :limit}, 400, "invalid_params", %{fields: %{limit: ["out of range"]}}},
    {:payload_too_large, 413, "payload_too_large", %{}},
    {:unsupported_media_type, 415, "unsupported_media_type", %{}}
  ]

  for {reason, status, code, detail} <- @rows do
    test "#{inspect(reason)} is #{status} #{code}" do
      assert {unquote(status), body} = ErrorMapper.to_response(unquote(Macro.escape(reason)))
      assert body.error == unquote(code)
      assert body.detail == unquote(Macro.escape(detail))
      assert body.message != "Error."
    end
  end

  test "a changeset is 422 validation_failed with the interpolated errors by field" do
    assert {422, %{error: "validation_failed", detail: detail}} =
             ErrorMapper.to_response(changeset())

    assert detail == %{fields: %{title: ["should be at most 200 character(s)"]}}
  end

  test "no domain error reason is a 500" do
    for {label, reason, _tool} <- Helmsman.DomainErrorReasons.all() do
      {status, body} = ErrorMapper.to_response(reason)
      assert status in 400..499, "#{label} is #{status}"
      assert Jason.encode!(body)
      assert body.message != "Error.", "#{label} has no message"
    end
  end

  test "an unknown reason is a 500 with only a reference, logged with the reason" do
    log =
      capture_log(fn ->
        assert {500, body} = ErrorMapper.to_response({:surprise, "secret detail"})
        assert body.error == "internal"
        assert %{ref: ref} = body.detail
        assert map_size(body.detail) == 1
        assert ref =~ ~r/\A[0-9a-f]{8}\z/
        refute Jason.encode!(body) =~ "secret"
        send(self(), {:ref, ref})
      end)

    assert_received {:ref, ref}
    assert log =~ ref
    assert log =~ "secret detail"
  end

  test "every code has its own message" do
    codes = Enum.map(@rows, fn {_reason, _status, code, _detail} -> code end)
    for code <- codes, do: refute(ErrorMapper.message(code) == "Error.", code)
  end
end
