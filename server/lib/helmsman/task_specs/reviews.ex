defmodule Helmsman.TaskSpecs.Reviews do
  @moduledoc """
  Review requests, reviews, the discussion of issues and the settlement
  of requests with their runs (`add-spec-workflow` decisions 5, 10, 11,
  13). See `Helmsman.TaskSpecs` for the errors.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Locks, Policy, Repo, Tx}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task
  alias Helmsman.TaskSpecs
  alias Helmsman.TaskSpecs.{Dispatch, Issue, IssueNote, Lock, Read, Review, ReviewRequest, Spec}
  alias Helmsman.TaskSpecs.{Store, Version}

  @max_request_note_bytes 8192
  @max_summary_bytes 16_384
  @max_issue_bytes 8192
  @max_anchor_bytes 200
  @max_issues 100
  @max_notes 100

  import Helmsman.TaskSpecs, only: [param: 2, invalid: 2]

  ## Requests

  @doc """
  Requests reviews of the latest version from `reviewers` (names; people
  with a claimed identity, managed or external agents), as a coordinator
  or a person, never from a run (runs use `delegate`); `attrs`: `note`
  (≤ 8 KB). A reviewer that is a managed agent gets a `spec_review` run
  (`reply` lane) authorized by the requesting user; a reviewer who
  already has a `requested` request on the version gets it back,
  without a new run. Returns `%{requests: [%{reviewer, request,
  existing, dispatch}]}`.
  """
  @spec request_reviews(Scope.t(), String.t(), [String.t()], map()) ::
          {:ok, map()} | {:error, term()}
  def request_reviews(scope, ident, reviewers, attrs \\ %{})

  def request_reviews(%Scope{via: :run}, _ident, _reviewers, _attrs), do: {:error, :forbidden}

  def request_reviews(%Scope{} = scope, ident, reviewers, attrs) when is_map(attrs) do
    note = param(attrs, :note)

    with {:ok, names} <- reviewer_names(reviewers),
         :ok <- optional_text(:note, note, @max_request_note_bytes) do
      Lock.dispatching(scope, ident, {:request_reviews, names}, fn scope, task, spec ->
        # Resolved again under the locks: the agents among them are the
        # locked targets, so a name taken over meanwhile cannot slip in.
        request_locked(scope, task, spec, names, resolve(task.workspace_id, names), note)
      end)
    end
  end

  defp reviewer_names(names) when is_list(names) and names != [] do
    if Enum.all?(names, &is_binary/1),
      do: {:ok, names |> Enum.map(&(&1 |> String.trim() |> String.downcase())) |> Enum.uniq()},
      else: invalid(:reviewers, "must be a list of names")
  end

  defp reviewer_names(_names), do: invalid(:reviewers, "must name at least one reviewer")

  defp resolve(workspace_id, names) do
    Repo.all(from(a in Actor, where: a.workspace_id == ^workspace_id and a.name in ^names))
    |> Map.new(&{&1.name, &1})
  end

  defp request_locked(scope, task, spec, names, actors, note) do
    with {:ok, spec} <- TaskSpecs.require_spec(task, spec),
         {:ok, _coordinator} <- TaskSpecs.coordinator(scope, task, :coordinate_spec),
         :ok <- requestable(spec),
         version = latest_version(spec),
         :ok <- check_reviewers(names, actors, version) do
      existing = pending_by_reviewer(spec.id, version.id)

      {results, ctx} =
        Enum.map_reduce(names, Store.context(task, spec), fn name, ctx ->
          request_one(scope, task, ctx, version, {name, actors[name]}, existing, note)
        end)

      Store.persist(ctx)
      {:ok, %{requests: results}}
    end
  end

  defp request_one(scope, task, ctx, version, {name, actor}, existing, note) do
    case existing[actor.id] do
      %ReviewRequest{number: n} ->
        {%{reviewer: name, request: n, existing: true, dispatch: nil}, ctx}

      nil ->
        {ctx, n} = insert_request(ctx, scope, version, actor, note, nil)
        request = %{request: n, version: version.number, note: note}
        dispatch = Dispatch.review(scope, task, actor, request)
        {%{reviewer: name, request: n, existing: false, dispatch: dispatch}, ctx}
    end
  end

  @doc false
  # Requests need a version and an open spec that is not waiting for approval.
  def requestable(%Spec{status: status}) when status in [:finalized, :abandoned],
    do: {:error, {:spec, :closed, status}}

  def requestable(%Spec{status: :pending_approval}), do: {:error, {:spec, :pending_approval}}
  def requestable(%Spec{latest_version: 0}), do: {:error, {:spec, :no_version}}
  def requestable(%Spec{}), do: :ok

  @doc false
  def latest_version(%Spec{id: id, latest_version: n}),
    do: Repo.one!(from(v in Version, where: v.spec_id == ^id and v.number == ^n))

  defp check_reviewers(names, actors, version) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case check_reviewer(actors[name], version) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:spec, reason, name}}}
      end
    end)
  end

  @doc false
  # A claimed person or an agent, not the author of the version.
  def check_reviewer(%Actor{kind: :human, user_id: nil}, _version),
    do: {:error, :invalid_reviewer}

  def check_reviewer(%Actor{id: id}, %Version{author_id: id}), do: {:error, :own_version}
  def check_reviewer(%Actor{kind: kind}, _version) when kind in [:human, :agent], do: :ok
  def check_reviewer(_actor, _version), do: {:error, :invalid_reviewer}

  @doc false
  # The `requested` requests of a version, by reviewer ID.
  def pending_by_reviewer(spec_id, version_id) do
    Repo.all(
      from(r in ReviewRequest,
        where: r.spec_id == ^spec_id and r.version_id == ^version_id and r.status == :requested
      )
    )
    |> Map.new(&{&1.reviewer_id, &1})
  end

  @doc false
  # Inserts a `requested` request and its `review_requested` event.
  def insert_request(ctx, scope, version, reviewer, note, run_id) do
    n = ctx.spec.request_seq + 1

    Repo.insert!(%ReviewRequest{
      workspace_id: ctx.spec.workspace_id,
      spec_id: ctx.spec.id,
      number: n,
      version_id: version.id,
      reviewer_id: reviewer.id,
      requested_by_id: scope.actor.id,
      request_run_id: run_id,
      note: note || "",
      status: :requested,
      inserted_at: DateTime.utc_now()
    })

    ctx = %{
      ctx
      | spec: %{ctx.spec | request_seq: n},
        attention: ctx.attention or reviewer.kind == :human
    }

    data = %{"request" => n, "reviewer" => reviewer.name}
    {Store.append(ctx, scope, [{"review_requested", version.number, data}]), n}
  end

  @doc """
  Cancels a `requested` request (`withdrawn`): `attrs` has `request` (its
  number) or `reviewer` (a name: the request on the latest version). The
  requester, a coordinator or a person.
  """
  @spec cancel_request(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_request(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    Lock.coordinated(scope, ident, fn scope, task, spec ->
      with {:ok, spec} <- TaskSpecs.require_spec(task, spec),
           {:ok, request} <- find_request(spec, attrs),
           :ok <- may_cancel(scope, task, request) do
        reviewer = Repo.get!(Actor, request.reviewer_id)

        %{Store.context(task, spec) | attention: reviewer.kind == :human}
        |> Store.append(scope, [
          {"review_request_closed", nil,
           TaskSpecs.closed(request.number, "cancelled", "withdrawn")}
        ])
        |> Store.persist()

        {:ok, %{request: request.number, reviewer: reviewer.name, spec: Read.summary_of(task)}}
      end
    end)
  end

  defp find_request(spec, attrs) do
    query = from(r in ReviewRequest, where: r.spec_id == ^spec.id and r.status == :requested)
    ref = param(attrs, :request) || param(attrs, :reviewer)

    case request_query(query, spec, param(attrs, :request), param(attrs, :reviewer)) do
      nil -> invalid(:request, "give the request number or the reviewer's name")
      query -> found(Repo.one(query), ref)
    end
  end

  defp request_query(query, _spec, n, _name) when is_integer(n),
    do: from(r in query, where: r.number == ^n)

  defp request_query(query, spec, nil, name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    from(r in query,
      join: v in assoc(r, :version),
      join: a in Actor,
      on: a.id == r.reviewer_id,
      where: v.number == ^spec.latest_version and a.name == ^name
    )
  end

  defp request_query(_query, _spec, _n, _name), do: nil

  defp found(nil, ref), do: {:error, {:spec, :request_not_found, ref}}
  defp found(request, _ref), do: {:ok, request}

  defp may_cancel(%Scope{actor: %Actor{id: id}}, _task, %ReviewRequest{requested_by_id: id}),
    do: :ok

  defp may_cancel(scope, task, _request) do
    with {:ok, _coordinator} <- TaskSpecs.coordinator(scope, task, :coordinate_spec), do: :ok
  end

  ## Reviews

  @doc """
  Submits a review of the latest version by the caller's identity
  (`attrs`: `version`, `verdict` (`pass` / `fail` / `comment`), `summary`
  (≤ 16 KB), `issues`: at most 100 `%{severity, file, line, anchor, body,
  suggestion}`). Completes the caller's `requested` request on the
  version. A person (not in a run) who completes a request a run made
  wakes the coordinator (`spec_reviewed`). Returns `%{review: n,
  dispatch}`.
  """
  @spec submit_review(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit_review(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    with {:ok, input} <- review_input(attrs) do
      Lock.dispatching(scope, ident, {:submit_review, scope}, fn scope, task, spec ->
        review_locked(scope, task, spec, input)
      end)
    end
  end

  defp review_input(attrs) do
    input = %{
      version: param(attrs, :version),
      verdict: param(attrs, :verdict),
      summary: param(attrs, :summary) || "",
      issues: param(attrs, :issues) || []
    }

    with :ok <- review_params(input),
         {:ok, issues} <- issues_input(input.issues),
         do: {:ok, %{input | verdict: to_atom(input.verdict), issues: issues}}
  end

  @verdicts ~w(pass fail comment) ++ ~w(pass fail comment)a

  defp review_params(%{verdict: verdict}) when verdict not in @verdicts,
    do: invalid(:verdict, "must be pass, fail or comment")

  defp review_params(%{summary: summary})
       when not is_binary(summary) or byte_size(summary) > @max_summary_bytes,
       do: invalid(:summary, "must be a string of at most 16 KB")

  defp review_params(%{issues: issues}) when not is_list(issues),
    do: {:error, {:spec, :invalid_issues, [%{index: nil, message: "issues must be a list"}]}}

  defp review_params(%{issues: issues}) when length(issues) > @max_issues,
    do: {:error, {:spec, :invalid_issues, [%{index: nil, message: "at most 100 issues"}]}}

  defp review_params(_input), do: :ok

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value), do: String.to_existing_atom(value)

  defp issues_input(issues) do
    {parsed, problems} =
      issues
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {issue, i}, problems ->
        case issue_input(issue) do
          {:ok, parsed} -> {parsed, problems}
          {:error, message} -> {nil, [%{index: i, message: message} | problems]}
        end
      end)

    if problems == [],
      do: {:ok, parsed},
      else: {:error, {:spec, :invalid_issues, Enum.reverse(problems)}}
  end

  @severities ~w(P1 P2 P3) ++ ~w(P1 P2 P3)a

  defp issue_input(%{} = issue) do
    fields = %{
      severity: param(issue, :severity),
      file: param(issue, :file),
      line: param(issue, :line),
      anchor: param(issue, :anchor),
      body: param(issue, :body),
      suggestion: param(issue, :suggestion)
    }

    case issue_problem(fields) do
      nil -> {:ok, %{fields | severity: to_atom(fields.severity)}}
      message -> {:error, message}
    end
  end

  defp issue_input(_issue), do: {:error, "an issue must be an object"}

  # The first problem of an issue's fields, or nil.
  defp issue_problem(%{severity: severity}) when severity not in @severities,
    do: "severity must be P1, P2 or P3"

  defp issue_problem(%{body: body})
       when not is_binary(body) or byte_size(body) > @max_issue_bytes,
       do: "body is required, at most 8 KB"

  defp issue_problem(%{suggestion: text})
       when not is_nil(text) and (not is_binary(text) or byte_size(text) > @max_issue_bytes),
       do: "suggestion must be a string of at most 8 KB"

  defp issue_problem(%{anchor: text})
       when not is_nil(text) and (not is_binary(text) or byte_size(text) > @max_anchor_bytes),
       do: "anchor must be a string of at most 200 bytes"

  defp issue_problem(%{file: file}) when not is_nil(file) and not is_binary(file),
    do: "file must be a path"

  defp issue_problem(%{line: line}) when not is_nil(line) and (not is_integer(line) or line < 1),
    do: "line must be a positive integer"

  defp issue_problem(%{line: line, file: nil}) when is_integer(line), do: "a line needs a file"

  defp issue_problem(%{body: body}),
    do: if(String.trim(body) == "", do: "body is required, at most 8 KB")

  defp review_locked(scope, task, spec, input) do
    with {:ok, spec} <- TaskSpecs.require_spec(task, spec),
         :ok <- reviewable(spec, input.version),
         version = latest_version(spec),
         :ok <- not_author(scope, version),
         :ok <- issue_locations(spec, input.issues) do
      ctx = Store.context(task, spec)
      request = pending_by_reviewer(spec.id, version.id)[scope.actor.id]
      wakes? = Dispatch.wakes_on_review?(scope, task, spec)
      n = spec.review_seq + 1
      review = insert_review(scope, spec, version, n, input)

      data =
        %{"review" => n, "reviewer" => scope.actor.name}
        |> then(&if(request, do: Map.put(&1, "request", request.number), else: &1))

      attention = request != nil and scope.actor.kind == :human

      %{ctx | spec: %{ctx.spec | review_seq: n}, attention: attention}
      |> Store.append(scope, [{"review_submitted", version.number, data}])
      |> Store.persist()

      dispatch =
        if wakes? do
          Dispatch.wake(scope, task, :spec_reviewed, %{
            "review" => n,
            "version" => version.number,
            "verdict" => Atom.to_string(input.verdict),
            "counts" => counts(input.issues)
          })
        end

      {:ok, %{review: review.number, dispatch: dispatch}}
    end
  end

  defp reviewable(%Spec{status: status}, _v) when status in [:finalized, :abandoned],
    do: {:error, {:spec, :closed, status}}

  defp reviewable(%Spec{latest_version: 0}, _v), do: {:error, {:spec, :no_version}}
  defp reviewable(%Spec{latest_version: v}, v), do: :ok

  defp reviewable(%Spec{latest_version: latest}, _v),
    do: {:error, {:spec, :stale_version, latest}}

  defp not_author(%Scope{actor: %Actor{id: id, name: name}}, %Version{author_id: id}),
    do: {:error, {:spec, :own_version, name}}

  defp not_author(_scope, _version), do: :ok

  defp issue_locations(spec, issues) do
    files = TaskSpecs.version_files(spec, spec.latest_version)

    problems =
      for {issue, i} <- Enum.with_index(issues, 1),
          message = location_problem(issue, files),
          do: %{index: i, message: message}

    if problems == [], do: :ok, else: {:error, {:spec, :invalid_issues, problems}}
  end

  defp location_problem(%{file: nil}, _files), do: nil

  defp location_problem(%{file: file, line: line}, files) do
    case files do
      %{^file => content} ->
        lines = content |> String.split("\n") |> length()
        if line && line > lines, do: "#{file} has #{lines} lines, not #{line}"

      _none ->
        "#{file} is not a file of this version"
    end
  end

  defp insert_review(scope, spec, version, n, input) do
    now = DateTime.utc_now()

    review =
      Repo.insert!(%Review{
        workspace_id: spec.workspace_id,
        spec_id: spec.id,
        number: n,
        version_id: version.id,
        reviewer_id: scope.actor.id,
        source_run_id: scope.run && scope.run.id,
        verdict: input.verdict,
        summary: input.summary,
        inserted_at: now
      })

    Repo.insert_all(
      Issue,
      for {issue, i} <- Enum.with_index(input.issues, 1) do
        Map.merge(issue, %{
          workspace_id: spec.workspace_id,
          spec_id: spec.id,
          review_id: review.id,
          number: i,
          resolution: :open,
          note_seq: 0,
          updated_at: now
        })
      end
    )

    review
  end

  defp counts(issues) do
    Map.new(~w(P1 P2 P3)a, fn severity ->
      {Atom.to_string(severity), Enum.count(issues, &(&1.severity == severity))}
    end)
  end

  ## Discussion

  @doc """
  Adds a note to the issue `ref` (`"R2.1"`). `attrs`: `resolution` —
  `accepted` / `disputed` (a reply: not by the issue's reviewer;
  `disputed` needs a `body`; `fixed_in_version` only with `accepted`),
  `withdrawn` (the reviewer or another identity of the same user),
  `upheld` / `dismissed` (a ruling: a person or the squad leader in its
  run as the squad; needs a `body`) or nil (a comment); `body` (≤ 8 KB).
  A resolution only changes an `open` or `disputed` issue
  (`issue_resolved`). Returns `%{ref, resolution, note}`.
  """
  @spec add_note(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_note(%Scope{} = scope, ident, ref, attrs) when is_map(attrs) do
    with {:ok, {review_n, issue_n}} <- parse_ref(ref),
         {:ok, input} <- note_input(attrs) do
      Lock.coordinated(scope, ident, fn scope, task, spec ->
        note_locked(scope, task, spec, ref, {review_n, issue_n}, input)
      end)
    end
  end

  @doc false
  def parse_ref(ref) when is_binary(ref) do
    case Regex.run(~r/\AR(\d+)\.(\d+)\z/, String.trim(ref)) do
      [_, r, i] -> {:ok, {String.to_integer(r), String.to_integer(i)}}
      nil -> {:error, {:spec, :issue_not_found, ref}}
    end
  end

  def parse_ref(ref), do: {:error, {:spec, :issue_not_found, inspect(ref)}}

  @resolutions %{
    "accepted" => {:reply, :accepted},
    "disputed" => {:reply, :disputed},
    "withdrawn" => {:withdraw, :withdrawn},
    "upheld" => {:ruling, :upheld},
    "dismissed" => {:ruling, :dismissed}
  }

  defp note_input(attrs) do
    resolution = param(attrs, :resolution)

    resolution =
      if is_atom(resolution) and resolution, do: Atom.to_string(resolution), else: resolution

    {kind, resolution} =
      if is_nil(resolution),
        do: {:comment, nil},
        else: Map.get(@resolutions, resolution, {:invalid, nil})

    input = %{
      kind: kind,
      resolution: resolution,
      body: param(attrs, :body) || "",
      fixed: param(attrs, :fixed_in_version)
    }

    with :ok <- note_params(input), do: {:ok, input}
  end

  defp note_params(%{kind: :invalid}),
    do: invalid(:resolution, "must be accepted, disputed, withdrawn, upheld or dismissed")

  defp note_params(%{body: body}) when not is_binary(body) or byte_size(body) > @max_issue_bytes,
    do: invalid(:body, "must be a string of at most 8 KB")

  defp note_params(%{kind: kind, resolution: resolution, body: body} = input) do
    cond do
      String.trim(body) == "" and (kind in [:comment, :ruling] or resolution == :disputed) ->
        invalid(:body, "is required")

      not fixed_ok?(input) ->
        invalid(:fixed_in_version, "only with accepted, a version number")

      true ->
        :ok
    end
  end

  defp fixed_ok?(%{fixed: nil}), do: true
  defp fixed_ok?(%{fixed: v, resolution: :accepted}) when is_integer(v) and v > 0, do: true
  defp fixed_ok?(_input), do: false

  defp note_locked(scope, task, spec, ref, {review_n, issue_n}, input) do
    with {:ok, spec} <- TaskSpecs.require_spec(task, spec),
         :ok <- reviewable(spec, spec.latest_version) |> closed_only(),
         {:ok, issue, review} <- find_issue(spec, review_n, issue_n, ref),
         :ok <- may_note(scope, task, review, input.kind),
         :ok <- changeable(issue, input, ref),
         :ok <- fixed_version(spec, input.fixed),
         :ok <-
           if(issue.note_seq >= @max_notes,
             do: invalid(:body, "an issue has at most 100 notes"),
             else: :ok
           ) do
      n = issue.note_seq + 1
      now = DateTime.utc_now()

      Repo.insert!(%IssueNote{
        workspace_id: spec.workspace_id,
        issue_id: issue.id,
        number: n,
        author_id: scope.actor.id,
        source_run_id: scope.run && scope.run.id,
        kind: input.kind,
        resolution: input.resolution,
        fixed_in_version: input.fixed,
        body: input.body,
        inserted_at: now
      })

      Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
        set: [resolution: input.resolution || issue.resolution, note_seq: n, updated_at: now]
      )

      Store.persist(Store.context(task, spec))

      {:ok,
       %{
         ref: "R#{review_n}.#{issue_n}",
         resolution: input.resolution || issue.resolution,
         note: n
       }}
    end
  end

  # Only the closed statuses matter to a note (the others are reviewable
  # or need a version, which an issue implies).
  defp closed_only({:error, {:spec, :closed, _}} = error), do: error
  defp closed_only(_result), do: :ok

  defp find_issue(spec, review_n, issue_n, ref) do
    Repo.one(
      from(i in Issue,
        join: r in assoc(i, :review),
        where: i.spec_id == ^spec.id and r.number == ^review_n and i.number == ^issue_n,
        select: {i, r}
      )
    )
    |> case do
      {issue, review} -> {:ok, issue, review}
      nil -> {:error, {:spec, :issue_not_found, ref}}
    end
  end

  defp may_note(%Scope{actor: %Actor{id: id}}, _task, %Review{reviewer_id: id}, :reply),
    do: {:error, :forbidden}

  defp may_note(scope, _task, review, :withdraw),
    do: Policy.authorize(scope, :revise_feedback, Repo.get!(Actor, review.reviewer_id))

  defp may_note(scope, task, _review, :ruling) do
    with {:ok, _coordinator} <- TaskSpecs.coordinator(scope, task, :rule_spec_issue), do: :ok
  end

  defp may_note(_scope, _task, _review, _kind), do: :ok

  defp changeable(_issue, %{resolution: nil}, _ref), do: :ok
  defp changeable(%Issue{resolution: r}, _input, _ref) when r in [:open, :disputed], do: :ok

  defp changeable(%Issue{resolution: r}, _input, ref),
    do: {:error, {:spec, :issue_resolved, ref, r}}

  defp fixed_version(_spec, nil), do: :ok
  defp fixed_version(%Spec{latest_version: latest}, v) when v <= latest + 1, do: :ok
  defp fixed_version(_spec, _v), do: invalid(:fixed_in_version, "no such version")

  defp optional_text(_field, nil, _max), do: :ok

  defp optional_text(field, value, max) do
    if is_binary(value) and byte_size(value) <= max,
      do: :ok,
      else: invalid(field, "must be a string of at most #{div(max, 1024)} KB")
  end

  ## Settling with runs (decision 10)

  @doc """
  Settles the review requests of the ended run `run_id`: each request of
  its `spec_request` triggers that is still `requested` becomes `lapsed`
  (one `review_request_closed` event each). Its own transaction, in the
  order of a task write: workspace maintenance lock (shared), task row,
  spec row; the run row is only read (an ended run's triggers no longer
  change). Idempotent.
  """
  @spec settle_run(pos_integer()) :: :ok
  def settle_run(run_id) when is_integer(run_id) do
    with %Run{task_id: task_id} = run when is_integer(task_id) <- Repo.get(Run, run_id),
         [_ | _] = numbers <- request_numbers(run) do
      {:ok, _} = Tx.run(fn -> settle(run, numbers) end, retry: 1)
    end

    :ok
  end

  @doc false
  def request_numbers(%Run{triggers: triggers}) do
    for %{"spec_request" => n} <- triggers, is_integer(n), uniq: true, do: n
  end

  defp settle(run, numbers) do
    Locks.maint_shared!(run.workspace_id)
    task = Repo.one!(from(t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE"))

    case Store.lock(task) do
      nil ->
        {:ok, :none}

      spec ->
        ctx = Store.context(task, spec)

        lapsed =
          for n <- Enum.sort(numbers), match?(%{status: :requested}, ctx.state.requests[n]), do: n

        if lapsed != [] do
          system = system_actor(run.workspace_id)

          %{ctx | attention: TaskSpecs.human_requests?(ctx, lapsed)}
          |> Store.append(
            {system, run.id},
            Enum.map(
              lapsed,
              &{"review_request_closed", nil,
               %{"request" => &1, "status" => "lapsed", "reason" => nil}}
            )
          )
          |> Store.persist()
        end

        {:ok, lapsed}
    end
  end

  defp system_actor(workspace_id),
    do:
      Repo.one!(
        from(a in Actor,
          where: a.workspace_id == ^workspace_id and a.kind == :system,
          select: a.id
        )
      )
end
