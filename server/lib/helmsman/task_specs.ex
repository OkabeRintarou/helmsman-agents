defmodule Helmsman.TaskSpecs do
  @moduledoc """
  Task specs (`add-spec-workflow`; designs/17): at most one spec per task,
  in the OpenSpec structure, with append-only versions, reviews, issues
  and their discussion, a finalize gate and an audit trail.

  Every function takes the caller's `%Scope{}` first and returns
  `{:ok, value}` or `{:error, reason}`. Writes run in
  `Helmsman.TaskSpecs.Lock` transactions; the mutable state of a spec
  always equals the replay of its events (`Helmsman.TaskSpecs.State`).

  Errors (besides `:not_found` for the task, `:forbidden`, `:busy` and a
  changeset for `change_id`) are `{:spec, reason, ...}`:

    * `{:spec, :not_found, ident}` — the task has no spec;
    * `{:spec, :stale_version, latest}`, `{:spec, :no_changes}`,
      `{:spec, :closed, status}` (finalized / abandoned),
      `{:spec, :no_version}`, `{:spec, :pending_approval}`,
      `{:spec, :no_proposal}`, `{:spec, :not_closed, status}` (reopen);
    * `{:spec, :invalid_files, [%{path, message}]}`,
      `{:spec, :invalid_issues, [%{index, message}]}`,
      `{:spec, :invalid_params, %{field, message}}`;
    * `{:spec, :invalid, errors}`, `{:spec, :unresolved_issues, refs}`,
      `{:spec, :reviews_pending, names}` (the gate);
    * `{:spec, :not_coordinator, %{task, assignee, kind}}`,
      `{:spec, :invalid_reviewer, name}`, `{:spec, :own_version, name}`,
      `{:spec, :review_pending, %{reviewer, request, requested_by}}`;
    * `{:spec, :issue_not_found, ref}`,
      `{:spec, :issue_resolved, ref, resolution}`.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Policy, Repo}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  alias Helmsman.TaskSpecs.{
    Blob,
    Coordinator,
    Dispatch,
    File,
    Files,
    Gate,
    Lock,
    Read,
    ReviewRequest,
    Reviews,
    Spec,
    Store,
    Validate,
    Version
  }

  @change_id ~r/\A[a-z0-9][a-z0-9-]{1,63}\z/
  @max_versions 200
  @max_note_bytes 4096
  @max_summary_bytes 16_384
  @max_reason_bytes 4096

  ## Reads (Helmsman.TaskSpecs.Read)

  defdelegate summary(scope, ident), to: Read
  defdelegate get(scope, ident, opts \\ []), to: Read
  defdelegate diff(scope, ident, from, to), to: Read
  defdelegate reviews(scope, ident, opts \\ []), to: Read
  defdelegate events(scope, ident), to: Read
  defdelegate permissions(scope, ident), to: Read
  defdelegate attention(scope), to: Read
  defdelegate prompt_context(run, task), to: Read

  ## Reviews (Helmsman.TaskSpecs.Reviews)

  defdelegate request_reviews(scope, ident, reviewers, attrs \\ %{}), to: Reviews

  defdelegate cancel_request(scope, ident, attrs), to: Reviews
  defdelegate submit_review(scope, ident, attrs), to: Reviews
  defdelegate add_note(scope, ident, ref, attrs), to: Reviews
  defdelegate settle_run(run_id), to: Reviews

  @doc """
  The states of the review requests of `run`'s triggers (`%{number =>
  status}`), for the claim check (`Helmsman.Runs.Revalidation`); read
  without locks under the caller's task lock. Empty without such triggers.
  """
  @spec request_states(Run.t()) :: %{pos_integer() => atom()}
  def request_states(%Run{task_id: task_id} = run) when is_integer(task_id) do
    case Reviews.request_numbers(run) do
      [] ->
        %{}

      numbers ->
        Repo.all(
          from(r in ReviewRequest,
            join: s in Spec,
            on: s.id == r.spec_id,
            where: s.task_id == ^task_id and r.number in ^numbers,
            select: {r.number, r.status}
          )
        )
        |> Map.new()
    end
  end

  def request_states(_run), do: %{}

  ## The spec

  @doc """
  Creates the task's empty spec when it has none, or changes its
  `change_id` (`attrs`: `change_id`; nil keeps it, or uses the task ID in
  lower case for a new spec). A taken or malformed `change_id` is a
  changeset error on `change_id`. With `status: "draft"` or
  `"abandoned"` (and a `reason`) it reopens or abandons the spec
  (`reopen/3`, `abandon/3`). Returns the summary.
  """
  @spec update(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    case param(attrs, :status) do
      status when status in ["draft", :draft] ->
        reopen(scope, ident, attrs)

      status when status in ["abandoned", :abandoned] ->
        abandon(scope, ident, attrs)

      nil ->
        update_spec(scope, ident, attrs)

      _other ->
        {:error,
         {:spec, :invalid_params, %{field: :status, message: "must be draft or abandoned"}}}
    end
  end

  defp update_spec(scope, ident, attrs),
    do: Lock.write(scope, ident, &update_locked(&1, &2, &3, param(attrs, :change_id)))

  defp update_locked(scope, task, spec, change_id) do
    with {:ok, ctx} <- change_id_context(scope, task, spec, change_id) do
      if ctx.spec.event_seq != (spec && spec.event_seq), do: Store.persist(ctx)
      {:ok, Read.summary_of(task)}
    end
  end

  # A new spec, a changed `change_id`, or the spec as it is.
  defp change_id_context(scope, task, nil, change_id),
    do: spec_context(scope, task, nil, change_id)

  defp change_id_context(_scope, task, %Spec{change_id: same} = spec, change_id)
       when change_id in [nil, same],
       do: {:ok, Store.context(task, spec)}

  defp change_id_context(scope, task, spec, change_id) do
    with {:ok, change_id} <- check_change_id(task, change_id) do
      data = %{"from" => spec.change_id, "to" => change_id}

      {:ok,
       task |> Store.context(spec) |> Store.append(scope, [{"change_id_changed", nil, data}])}
    end
  end

  defp check_change_id(task, change_id) do
    changeset =
      {%{}, %{change_id: :string}}
      |> Ecto.Changeset.cast(%{change_id: change_id}, [:change_id])
      |> Ecto.Changeset.validate_required([:change_id])
      |> Ecto.Changeset.validate_format(:change_id, @change_id,
        message: "must be 2-64 characters of a-z, 0-9 and '-', starting with a letter or digit"
      )

    taken? =
      changeset.valid? and
        Repo.exists?(
          from(s in Spec,
            where:
              s.workspace_id == ^task.workspace_id and s.change_id == ^change_id and
                s.task_id != ^task.id
          )
        )

    changeset =
      if taken?,
        do: Ecto.Changeset.add_error(changeset, :change_id, "has already been taken"),
        else: changeset

    if changeset.valid?, do: {:ok, change_id}, else: {:error, %{changeset | action: :update}}
  end

  ## Versions

  @doc """
  Submits a version (decision 3). `attrs`: `base_version` (the latest
  version, 0 for none; required), `files` (`[%{path, content}]` or
  `%{path => content}`: the changed and new files), `remove` (paths),
  `note` (≤ 4 KB), `change_id` (only when the spec is created by this
  submission) and `dry_run`.

  The files of `base_version` with the changes applied make the new
  version; the same files as the base → `no_changes`. A dry run returns
  the merged file list and validation result and writes nothing.
  Otherwise the version is inserted (blobs deduplicated by SHA-256),
  requests on older versions are cancelled (`superseded`) and a proposal
  is withdrawn. Returns `%{version: n | nil, files: [%{path, bytes}],
  validation: %{valid, errors}}`.
  """
  @spec submit_version(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit_version(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    with {:ok, input} <- version_input(attrs) do
      Lock.write(scope, ident, fn scope, task, spec -> submit_locked(scope, task, spec, input) end)
    end
  end

  defp version_input(attrs) do
    input = %{
      base: param(attrs, :base_version),
      note: param(attrs, :note) || "",
      remove: param(attrs, :remove) || [],
      change_id: param(attrs, :change_id),
      dry_run: param(attrs, :dry_run) in [true, "true"]
    }

    with {:ok, files} <- files_param(param(attrs, :files) || []),
         :ok <- version_params(input),
         do: {:ok, Map.put(input, :files, files)}
  end

  defp version_params(%{base: base}) when not is_integer(base) or base < 0,
    do: invalid(:base_version, "must be the latest version number (0 when there is none)")

  defp version_params(%{note: note})
       when not is_binary(note) or byte_size(note) > @max_note_bytes,
       do: invalid(:note, "must be a string of at most 4 KB")

  defp version_params(%{remove: remove}) when not is_list(remove),
    do: invalid(:remove, "must be a list of paths")

  defp version_params(_input), do: :ok

  defp files_param(files) when is_map(files) and not is_struct(files), do: {:ok, files}

  defp files_param(files) when is_list(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case file do
        %{} ->
          {:cont, {:ok, Map.put(acc, param(file, :path), param(file, :content))}}

        _other ->
          {:halt, invalid(:files, "must be a list of {path, content}")}
      end
    end)
  end

  defp files_param(_files), do: invalid(:files, "must be a list of {path, content}")

  defp submit_locked(scope, task, spec, input) do
    latest = (spec && spec.latest_version) || 0

    with :ok <- open(spec),
         :ok <- if(input.base == latest, do: :ok, else: {:error, {:spec, :stale_version, latest}}),
         :ok <- version_cap(latest),
         base_files = version_files(spec, latest),
         {:ok, files} <- merge(base_files, input),
         :ok <- if(files == base_files, do: {:error, {:spec, :no_changes}}, else: :ok) do
      validation = Validate.run(files)

      listing =
        for {path, content} <- Enum.sort(files), do: %{path: path, bytes: byte_size(content)}

      result = %{version: nil, files: listing, validation: validation}
      if input.dry_run, do: {:ok, result}, else: write(scope, task, spec, input, files, result)
    end
  end

  defp write(scope, task, spec, input, files, result) do
    with {:ok, ctx} <- spec_context(scope, task, spec, input.change_id) do
      number = ctx.spec.latest_version + 1
      write_version(scope, ctx.spec, number, files, input.note, result.validation)
      ctx |> after_version(scope, number) |> Store.persist()
      {:ok, %{result | version: number}}
    end
  end

  defp open(%Spec{status: status}) when status in [:finalized, :abandoned],
    do: {:error, {:spec, :closed, status}}

  defp open(_spec), do: :ok

  defp version_cap(latest) when latest >= @max_versions,
    do: invalid(:base_version, "a spec has at most #{@max_versions} versions")

  defp version_cap(_latest), do: :ok

  defp merge(base, input) do
    case Files.merge(base, input.files, input.remove) do
      {:ok, files} -> {:ok, files}
      {:error, problems} -> {:error, {:spec, :invalid_files, problems}}
    end
  end

  defp spec_context(scope, task, nil, change_id) do
    with {:ok, change_id} <- check_change_id(task, change_id || String.downcase(task.ident)),
         do: {:ok, Store.create(scope, task, change_id)}
  end

  defp spec_context(_scope, task, spec, _change_id), do: {:ok, Store.context(task, spec)}

  @doc false
  # `%{path => content}` of version `number` (none for 0 or no spec).
  def version_files(nil, _number), do: %{}
  def version_files(_spec, 0), do: %{}

  def version_files(%Spec{id: spec_id}, number) do
    Repo.all(
      from(f in File,
        join: v in Version,
        on: v.id == f.version_id,
        join: b in Blob,
        on: b.id == f.blob_id,
        where: v.spec_id == ^spec_id and v.number == ^number,
        select: {f.path, b.content}
      )
    )
    |> Map.new()
  end

  defp write_version(scope, spec, number, files, note, validation) do
    rows =
      for {_path, content} <- files do
        sha = :crypto.hash(:sha256, content)

        %{
          workspace_id: spec.workspace_id,
          spec_id: spec.id,
          sha256: sha,
          content: content,
          bytes: byte_size(content)
        }
      end

    Repo.insert_all(Blob, rows, on_conflict: :nothing, conflict_target: [:spec_id, :sha256])

    blob_ids =
      Repo.all(
        from(b in Blob,
          where: b.spec_id == ^spec.id and b.sha256 in ^Enum.map(rows, & &1.sha256),
          select: {b.sha256, b.id}
        )
      )
      |> Map.new()

    version =
      Repo.insert!(%Version{
        workspace_id: spec.workspace_id,
        spec_id: spec.id,
        number: number,
        author_id: scope.actor.id,
        source_run_id: scope.run && scope.run.id,
        note: note,
        validation: stored_validation(validation),
        valid: validation.valid,
        inserted_at: DateTime.utc_now()
      })

    Repo.insert_all(
      File,
      for {path, content} <- files do
        %{
          workspace_id: spec.workspace_id,
          version_id: version.id,
          path: path,
          blob_id: blob_ids[:crypto.hash(:sha256, content)]
        }
      end
    )

    number
  end

  defp stored_validation(%{valid: valid, errors: errors}) do
    %{
      "valid" => valid,
      "errors" =>
        Enum.map(errors, fn e ->
          %{"file" => e.file, "line" => e.line, "rule" => e.rule, "message" => e.message}
        end)
    }
  end

  # The events of a new version: the version, the requests it supersedes
  # (by number), the withdrawn proposal.
  defp after_version(ctx, scope, number) do
    superseded =
      for {n, %{status: :requested}} <- Enum.sort(ctx.state.requests),
          do: {"review_request_closed", nil, closed(n, "cancelled", "superseded")}

    withdrawn =
      case ctx.state.proposal do
        nil -> []
        %{version: v} -> [{"proposal_withdrawn", v, %{}}]
      end

    ctx = %{ctx | attention: ctx.attention or human_requests?(ctx, Map.keys(ctx.state.requests))}
    Store.append(ctx, scope, [{"version_submitted", number, %{}}] ++ superseded ++ withdrawn)
  end

  @doc false
  def closed(n, status, reason),
    do: %{"request" => n, "status" => status, "reason" => reason}

  @doc false
  # Whether any of the requests `numbers` asks a person (the to-do list).
  def human_requests?(_ctx, []), do: false

  def human_requests?(ctx, numbers) do
    Repo.exists?(
      from(r in ReviewRequest,
        join: a in Actor,
        on: a.id == r.reviewer_id,
        where: r.spec_id == ^ctx.spec.id and r.number in ^numbers and a.kind == :human
      )
    )
  end

  ## Finalizing (decisions 7, 8)

  @doc """
  Finalizes the latest version (`attrs`: `version`, `summary`, `wake`
  (default true)).

  A person (member and above, not in a run): finalizes it, approving the
  proposal if there is one, and with `wake` wakes the assignee
  (`spec_decided`). An agent coordinator: `summary` (≤ 16 KB) is
  required; in `leader` mode the squad leader in its run as the squad
  finalizes directly, anyone else proposes (`pending_approval`). Others
  → `not_coordinator`. The gate (`Helmsman.TaskSpecs.Gate`) is checked
  first. Returns `%{spec, decision: :approved | :finalized | :proposed,
  dispatch}`.
  """
  @spec finalize(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def finalize(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    summary = param(attrs, :summary)
    wake = wake?(attrs)

    with :ok <- text(:summary, summary, @max_summary_bytes, human?(scope)) do
      op = if human?(scope), do: {:decide, wake}, else: {:decide, false}

      Lock.dispatching(scope, ident, op, fn scope, task, spec ->
        finalize_locked(scope, task, spec, param(attrs, :version), summary, wake)
      end)
    end
  end

  defp finalize_locked(scope, task, spec, version, summary, wake) do
    with {:ok, spec} <- require_spec(task, spec),
         {:ok, coordinator} <- coordinator(scope, task, :coordinate_spec),
         :ok <- Gate.check(gate_snapshot(spec), version),
         {:ok, decision} <- decision(scope, coordinator, task, spec) do
      task
      |> Store.context(spec)
      |> Store.append(scope, [decision_event(decision, version, summary)])
      |> Store.persist()

      dispatch =
        if human?(scope) and wake,
          do:
            decided(scope, task, %{"decision" => Atom.to_string(decision), "version" => version})

      {:ok, %{spec: Read.summary_of(task), decision: decision, dispatch: dispatch}}
    end
  end

  defp decision_event(:proposed, version, summary),
    do: {"finalize_proposed", version, %{"summary" => summary}}

  defp decision_event(decision, version, summary),
    do: {Atom.to_string(decision), version, note(summary)}

  defp decided(scope, task, extra), do: Dispatch.wake(scope, task, :spec_decided, extra)

  # A proposal that waits already cannot be proposed again.
  defp decision(scope, coordinator, task, spec) do
    cond do
      human?(scope) and spec.status == :pending_approval -> {:ok, :approved}
      human?(scope) -> {:ok, :finalized}
      match?({:leader, _}, coordinator) and Coordinator.mode(task) == :leader -> {:ok, :finalized}
      spec.status == :pending_approval -> {:error, {:spec, :pending_approval}}
      true -> {:ok, :proposed}
    end
  end

  defp note(nil), do: %{}
  defp note(summary), do: %{"summary" => summary}

  @doc """
  Sends the proposal back (people only; `attrs`: `reason` (≤ 4 KB,
  required), `wake`). No proposal → `no_proposal`. Returns `%{spec,
  dispatch}`.
  """
  @spec reject(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def reject(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    reason = param(attrs, :reason)
    wake = wake?(attrs)

    with :ok <- Policy.authorize(scope, :approve_spec),
         :ok <- text(:reason, reason, @max_reason_bytes, false) do
      Lock.dispatching(scope, ident, {:decide, wake}, &reject_locked(&1, &2, &3, reason, wake))
    end
  end

  defp reject_locked(scope, task, spec, reason, wake) do
    with {:ok, spec} <- require_spec(task, spec),
         {:ok, version} <- proposal(spec) do
      task
      |> Store.context(spec)
      |> Store.append(scope, [{"proposal_rejected", version, %{"reason" => reason}}])
      |> Store.persist()

      extra = %{"decision" => "rejected", "version" => version, "reason" => reason}
      dispatch = if wake, do: decided(scope, task, extra)
      {:ok, %{spec: Read.summary_of(task), dispatch: dispatch}}
    end
  end

  @doc """
  Abandons a `draft` / `in_review` / `pending_approval` spec (a
  coordinator or a person; `attrs`: `reason`, required): pending requests
  are cancelled (`abandoned`), a proposal is withdrawn. Returns the
  summary.
  """
  @spec abandon(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def abandon(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    reason = param(attrs, :reason)

    with :ok <- text(:reason, reason, @max_reason_bytes, false) do
      Lock.coordinated(scope, ident, &abandon_locked(&1, &2, &3, reason))
    end
  end

  defp abandon_locked(scope, task, spec, reason) do
    with {:ok, spec} <- require_spec(task, spec),
         {:ok, _coordinator} <- coordinator(scope, task, :coordinate_spec),
         :ok <- open(spec) do
      ctx = Store.context(task, spec)
      pending = for {n, %{status: :requested}} <- Enum.sort(ctx.state.requests), do: n

      cancelled =
        Enum.map(pending, &{"review_request_closed", nil, closed(&1, "cancelled", "abandoned")})

      withdrawn =
        if ctx.state.proposal,
          do: [{"proposal_withdrawn", ctx.state.proposal.version, %{}}],
          else: []

      %{ctx | attention: human_requests?(ctx, pending)}
      |> Store.append(
        scope,
        cancelled ++ withdrawn ++ [{"abandoned", nil, %{"reason" => reason}}]
      )
      |> Store.persist()

      {:ok, Read.summary_of(task)}
    end
  end

  @doc """
  Reopens a `finalized` / `abandoned` spec (a coordinator or a person;
  `attrs`: `reason`, required): back to `draft` without a final version;
  the earlier `approved` / `finalized` events stay. Returns the summary.
  """
  @spec reopen(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def reopen(%Scope{} = scope, ident, attrs) when is_map(attrs) do
    reason = param(attrs, :reason)

    with :ok <- text(:reason, reason, @max_reason_bytes, false) do
      Lock.coordinated(scope, ident, &reopen_locked(&1, &2, &3, reason))
    end
  end

  defp reopen_locked(scope, task, spec, reason) do
    with {:ok, spec} <- require_spec(task, spec),
         {:ok, _coordinator} <- coordinator(scope, task, :coordinate_spec),
         :ok <- closed_spec(spec) do
      task
      |> Store.context(spec)
      |> Store.append(scope, [{"reopened", nil, %{"reason" => reason}}])
      |> Store.persist()

      {:ok, Read.summary_of(task)}
    end
  end

  defp proposal(%Spec{proposal_version: nil}), do: {:error, {:spec, :no_proposal}}
  defp proposal(%Spec{proposal_version: version}), do: {:ok, version}

  defp closed_spec(%Spec{status: status}) when status in [:finalized, :abandoned], do: :ok
  defp closed_spec(%Spec{status: status}), do: {:error, {:spec, :not_closed, status}}

  ## Helpers shared with Helmsman.TaskSpecs.Reviews

  @doc false
  def require_spec(%Task{ident: ident}, nil), do: {:error, {:spec, :not_found, ident}}
  def require_spec(_task, %Spec{} = spec), do: {:ok, spec}

  @doc false
  # The caller's coordinator role for `action` (`:coordinate_spec` or
  # `:rule_spec_issue`): an agent that is not → `not_coordinator`.
  def coordinator(scope, task, action) do
    coordinator = Coordinator.resolve(scope, task)

    case Policy.authorize(scope, action, coordinator) do
      :ok ->
        {:ok, coordinator}

      {:error, :forbidden} = forbidden ->
        if agent?(scope) and Policy.authorize(scope, :write_spec) == :ok,
          do: {:error, {:spec, :not_coordinator, Coordinator.who(task)}},
          else: forbidden
    end
  end

  defp agent?(%Scope{actor: %Actor{kind: kind}}), do: kind != :human

  @doc false
  def human?(%Scope{actor: %Actor{kind: :human}, run: nil}), do: true
  def human?(_scope), do: false

  @doc false
  # The gate's view of the locked spec: the latest version validated now.
  def gate_snapshot(%Spec{} = spec) do
    %{
      status: spec.status,
      latest_version: spec.latest_version,
      validation: Validate.run(version_files(spec, spec.latest_version)),
      unresolved: Read.unresolved_refs(spec.id),
      pending: Read.pending_reviewers(spec)
    }
  end

  defp wake?(attrs), do: param(attrs, :wake) not in [false, "false"]

  defp text(field, value, max, optional?) do
    cond do
      optional? and is_nil(value) -> :ok
      not is_binary(value) or String.trim(value) == "" -> invalid(field, "is required")
      byte_size(value) > max -> invalid(field, "must be at most #{div(max, 1024)} KB")
      true -> :ok
    end
  end

  @doc false
  def invalid(field, message),
    do: {:error, {:spec, :invalid_params, %{field: field, message: message}}}

  @doc false
  # A parameter by atom or string key.
  def param(attrs, key) when is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
