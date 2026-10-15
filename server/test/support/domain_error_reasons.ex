defmodule Helmsman.DomainErrorReasons do
  @moduledoc """
  A sample of every error reason the domain returns to MCP and REST
  (`add-rest-api` decision 5): at least one per clause of
  `HelmsmanMCP.ErrorText.format/2`, and every error listed in the `@doc`
  of the domain functions REST calls directly (`Helmsman.Runs.get/2`,
  `Helmsman.Runs.list_events/3`, `Helmsman.Runs.Retry.retry/2`,
  `Helmsman.Feedback.get/2`, `Helmsman.Filters.get/2`,
  `Helmsman.Autopilots.run_now/3`: a changeset, `:forbidden`,
  `:not_found`, `:busy`).

  `HelmsmanMCP.ErrorTextTest` checks that each has a text and
  `HelmsmanWeb.API.ErrorMapperTest` that none is a 500. A new domain error
  belongs here.

  An entry may name the tool whose error text it has (`{label, reason,
  tool}`); otherwise any tool.

  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "`[{label, reason, tool}]`, `tool` the name of the MCP tool or nil."
  def all do
    Enum.map(reasons(), fn
      {label, reason} -> {label, reason, nil}
      {label, reason, tool} -> {label, reason, tool}
    end)
  end

  defp reasons do
    changeset =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:title, "can't be blank", validation: :required)

    [
      # REST-only workspace backup domain errors (add-export-import 6.3).
      {"backup params", :invalid_params},
      {"invalid import", {:invalid_import, [%{path: "tasks[0].title", message: "invalid"}]}},
      {"backup diverged", {:diverged, %{path: "tasks[0]", message: "history differs"}}},
      {"backup actor kind",
       {:actor_kind_conflict, %{path: "actors[0]", message: "kind differs"}}},
      {"backup cycle", {:cycle, %{path: "links", message: "cycle"}}},
      {"backup blocked", {:replace_blocked, [%{task: "BOS-1", reason: "active_run"}]}},
      {"backup confirmation", :confirmation_required},
      {"backup size", :too_large},
      {"backup storage", :storage_unavailable},
      # Permissions and identities.
      {"forbidden", :forbidden},
      {"forbidden cancels other task", {:forbidden, {:cancels_other_task, "BOS-2", "BOS-1"}}},
      {"writer disabled", {:agent_disabled, "keel/dev"}},
      {"no identity", :no_identity},
      {"no actor", :no_actor},
      {"name taken", :name_taken},
      {"run ended", :run_ended},
      # Not found.
      {"not found", :not_found},
      {"task not found", {:not_found, "BOS-999"}},
      # Task state.
      {"invalid transition", {:invalid_transition, :done, :cancelled, [:verified, :rejected]}},
      {"blocked", {:blocked, ["BOS-1"]}},
      {"replaced by one", {:replaced, ["BOS-3"]}},
      {"replaced by many", {:replaced, ["BOS-3", "BOS-4"]}},
      {"self verify", {:self_verify_requires_tests, "keel/dev"}},
      {"self verify, no name", {:self_verify_requires_tests, nil}},
      {"cycle", {:cycle, ["BOS-1", "BOS-2", "BOS-1"]}},
      {"superseded", {:superseded, "BOS-1#4"}},
      {"stale", :stale},
      {"busy", :busy},
      {"project archived", :project_archived},
      {"run active", {:run_active, %{id: 881, agent: "keel/dev"}}},
      # Input.
      {"changeset", changeset},
      {"invalid status", {:invalid_status, "DONEE", [:new, :in_progress, :done]}},
      {"invalid link type", {:invalid_type, "blocks"}},
      {"self link", :self_link},
      {"invalid commits", {:invalid_commits, ["xyz"]}},
      {"invalid tests", {:invalid_tests, {:passed, "yes"}}},
      {"invalid tests object", {:invalid_tests, :not_an_object}},
      {"comment too long", {:invalid_comment, :too_long}},
      {"comment not a string", {:invalid_comment, :not_a_string}},
      {"invalid feedback", {:invalid_feedback, :not_an_object}},
      {"invalid agent kind", {:invalid_kind, "squad"}},
      {"invalid task kind", {:invalid, :kind}},
      {"query too long", {:invalid_query, :too_long}},
      {"query not a string", {:invalid_query, :not_a_string}},
      # BQL and saved filters (`add-bql-filters`; `Filters.get/2`:
      # :forbidden, :not_found).
      {"invalid BQL", {:invalid_bql, %{message: "unexpected end of input", position: 7}}},
      {"unknown BQL field", {:invalid_bql, %{message: "unknown field colour", position: 0}}},
      {"query timeout", :query_timeout},
      {"bql or filter", :bql_or_filter},
      {"query limit", {:invalid, :limit}, "query_tasks"},
      {"query offset", {:invalid, :offset}, "query_tasks"},
      {"stale filter", :stale, "save_filter"},
      # Starting and stopping runs.
      {"agent disabled (target)", :agent_disabled},
      {"not managed", :not_managed},
      {"is squad", :is_squad},
      {"instructions required", :instructions_required},
      {"instructions too long", {:invalid_instructions, :too_long}},
      {"instructions not a string", {:invalid_instructions, :not_a_string}},
      {"already finished", :already_finished},
      {"already retried", {:already_retried, 882}},
      {"task closed", :task_closed},
      {"not dispatched", {:not_dispatched, :unauthorized}},
      {"not dispatched, rate limited", {:not_dispatched, :rate_limited}},
      # Runs.Retry.retry/2.
      {"retry: not ended", :not_ended},
      {"retry: not retryable", :not_retryable},
      {"retry: agent archived", :agent_archived},
      {"retry: no runtime", :no_runtime},
      {"retry: runtime disabled", :runtime_disabled},
      {"retry: rate limited", :rate_limited},
      # Design runs and squads (tools REST does not expose).
      {"not a design run", {:design, :not_design_run}},
      {"design turn ended", {:design, :turn_ended}},
      {"not a squad design", {:design, :not_squad}},
      {"referenced by squad", {:referenced_by_squad, "web/dev"}},
      {"invalid squad", {:invalid_squad, changeset}},
      {"draft full", :draft_full},
      {"invalid agent", {:invalid_agent, "web/dev", changeset}},
      {"not in draft", {:not_in_draft, "web/dev"}},
      {"delegate: task closed", {:delegate, :task_closed, "BOS-1"}},
      {"delegate: not squad task", {:delegate, :not_squad_task, "web"}},
      {"delegate: squad disabled", {:delegate, :squad_disabled, "web"}},
      {"delegate: not leader", {:delegate, :not_leader, "web"}},
      {"delegate: not member", {:delegate, :not_member, {"web", ["web/dev"]}}},
      {"delegate: person member", {:delegate, :person_member, "bob"}},
      {"delegate not dispatched, unauthorized",
       {:delegate_not_dispatched, %{reason: :unauthorized, initiator: "alice", member: "web/dev"}}},
      {"delegate not dispatched",
       {:delegate_not_dispatched, %{reason: :no_runtime, member: "web/dev"}}},
      # Task specs (add-spec-workflow decisions 20, 21).
      {"spec not found", {:spec, :not_found, "BOS-1"}},
      {"spec stale version", {:spec, :stale_version, 3}},
      {"spec closed", {:spec, :closed, :finalized}},
      {"spec not closed", {:spec, :not_closed, :draft}},
      {"spec no changes", {:spec, :no_changes}},
      {"spec no version", {:spec, :no_version}},
      {"spec pending approval", {:spec, :pending_approval}},
      {"spec no proposal", {:spec, :no_proposal}},
      {"spec invalid",
       {:spec, :invalid, [%{file: "tasks.md", line: nil, rule: "missing_tasks", message: "x"}]}},
      {"spec unresolved issues", {:spec, :unresolved_issues, ["R2.1"]}},
      {"spec reviews pending", {:spec, :reviews_pending, ["keel/review"]}},
      {"spec not coordinator, squad",
       {:spec, :not_coordinator, %{task: "BOS-1", assignee: "web-team", kind: :squad}}},
      {"spec not coordinator, agent",
       {:spec, :not_coordinator, %{task: "BOS-1", assignee: "keel/dev", kind: :agent}}},
      {"spec not coordinator",
       {:spec, :not_coordinator, %{task: "BOS-1", assignee: nil, kind: nil}}},
      {"spec review pending",
       {:spec, :review_pending,
        %{reviewer: "keel/review", request: 3, requested_by: "alice", version: 2}}},
      {"spec own version", {:spec, :own_version, "keel/fe"}},
      {"spec invalid reviewer", {:spec, :invalid_reviewer, "web-team"}},
      {"spec issue resolved", {:spec, :issue_resolved, "R2.1", :upheld}},
      {"spec issue not found", {:spec, :issue_not_found, "R9.1"}},
      {"spec request not found", {:spec, :request_not_found, "keel/review"}},
      {"spec version not found", {:spec, :version_not_found, 9}},
      {"spec invalid files", {:spec, :invalid_files, [%{path: "x.md", message: "not allowed"}]}},
      {"spec invalid issues", {:spec, :invalid_issues, [%{index: 1, message: "bad severity"}]}},
      {"spec invalid params", {:spec, :invalid_params, %{field: :note, message: "is too long"}}},
      {"spec invalid archive", {:spec, :invalid_archive, "the archive has no spec file"}},
      {"spec review from a run", :forbidden, "request_spec_review"}
    ]
  end
end
