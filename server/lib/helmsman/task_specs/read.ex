defmodule Helmsman.TaskSpecs.Read do
  @moduledoc """
  The reads of `Helmsman.TaskSpecs` (`add-spec-workflow` decisions 17, 22
  and the 界面契约): summary, versions and files, diff, reviews, events,
  the caller's permissions and to-do list. Every member (viewers too) and
  every run token may read.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Policy, Repo}
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.TaskSpecs

  alias Helmsman.TaskSpecs.{
    Blob,
    Coordinator,
    Diff,
    Event,
    File,
    Issue,
    IssueNote,
    Review,
    ReviewRequest,
    Spec,
    Version
  }

  @max_attention 50

  ## Summary

  @doc "The task's spec summary, or nil when it has none."
  @spec summary(Scope.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def summary(%Scope{} = scope, ident) do
    with {:ok, task} <- task(scope, ident), do: {:ok, summary_of(task)}
  end

  @doc false
  # The summary without authorization (the caller checked it).
  def summary_of(%Task{} = task) do
    case Repo.get_by(Spec, task_id: task.id) do
      nil -> nil
      spec -> summary_of(task, spec)
    end
  end

  def summary_of(%Task{} = task, %Spec{} = spec) do
    names = names([spec.proposal_by_id])

    %{
      task: task.ident,
      change_id: spec.change_id,
      status: spec.status,
      latest_version: spec.latest_version,
      final_version: spec.final_version,
      mode: Coordinator.mode(task),
      proposal:
        spec.proposal_version &&
          %{
            version: spec.proposal_version,
            summary: spec.proposal_summary,
            by: names[spec.proposal_by_id],
            at: spec.proposed_at
          },
      pending_reviews: pending_reviews(spec),
      unresolved: unresolved_counts(spec.id),
      latest_valid: latest_valid(spec),
      lock_version: spec.lock_version
    }
  end

  defp pending_reviews(spec) do
    Repo.all(
      from(r in ReviewRequest,
        join: v in assoc(r, :version),
        join: a in Actor,
        on: a.id == r.reviewer_id,
        join: b in Actor,
        on: b.id == r.requested_by_id,
        where: r.spec_id == ^spec.id and r.status == :requested,
        order_by: r.number,
        select: %{
          n: r.number,
          reviewer: a.name,
          version: v.number,
          requested_by: b.name,
          at: r.inserted_at
        }
      )
    )
  end

  defp unresolved_counts(spec_id) do
    counts =
      Repo.all(
        from(i in Issue,
          where: i.spec_id == ^spec_id and i.resolution in [:open, :disputed],
          group_by: i.severity,
          select: {i.severity, count()}
        )
      )
      |> Map.new()

    %{p1: counts[:P1] || 0, p2: counts[:P2] || 0, p3: counts[:P3] || 0}
  end

  defp latest_valid(%Spec{latest_version: 0}), do: nil

  defp latest_valid(%Spec{id: id, latest_version: n}),
    do: Repo.one(from(v in Version, where: v.spec_id == ^id and v.number == ^n, select: v.valid))

  @doc false
  # The refs of the open or disputed P1 / P2 issues, in order.
  def unresolved_refs(spec_id) do
    Repo.all(
      from(i in Issue,
        join: r in assoc(i, :review),
        where:
          i.spec_id == ^spec_id and i.resolution in [:open, :disputed] and
            i.severity in [:P1, :P2],
        order_by: [r.number, i.number],
        select: {r.number, i.number}
      )
    )
    |> Enum.map(fn {r, i} -> "R#{r}.#{i}" end)
  end

  @doc false
  # The reviewers of the `requested` requests on the latest version.
  def pending_reviewers(%Spec{id: id, latest_version: latest}) do
    Repo.all(
      from(r in ReviewRequest,
        join: v in assoc(r, :version),
        join: a in Actor,
        on: a.id == r.reviewer_id,
        where: r.spec_id == ^id and r.status == :requested and v.number == ^latest,
        order_by: r.number,
        select: a.name
      )
    )
  end

  ## Versions

  @doc """
  The spec with its versions and one version (`version:`, default the
  latest) with its validation and files: every path with its `bytes`;
  `content` for the paths in `files:` (default all), nil for the others.
  """
  @spec get(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, ident, opts \\ []) do
    with {:ok, task} <- task(scope, ident),
         {:ok, spec} <- spec(task) do
      number = Keyword.get(opts, :version) || spec.latest_version
      paths = Keyword.get(opts, :files)

      with {:ok, version} <- version(spec, number) do
        {:ok,
         %{
           spec: summary_of(task, spec),
           versions: versions(spec),
           version: version && version_view(version, paths)
         }}
      end
    end
  end

  defp version(%Spec{latest_version: 0}, 0), do: {:ok, nil}

  defp version(spec, number) when is_integer(number) do
    case Repo.one(from(v in Version, where: v.spec_id == ^spec.id and v.number == ^number)) do
      nil -> {:error, {:spec, :version_not_found, number}}
      version -> {:ok, version}
    end
  end

  defp version(_spec, number), do: {:error, {:spec, :version_not_found, number}}

  defp versions(spec) do
    finalized = finalized_versions(spec.id)

    Repo.all(
      from(v in Version,
        join: a in Actor,
        on: a.id == v.author_id,
        where: v.spec_id == ^spec.id,
        order_by: v.number,
        select: %{
          number: v.number,
          author: a.name,
          at: v.inserted_at,
          note: v.note,
          valid: v.valid
        }
      )
    )
    |> Enum.map(&Map.put(&1, :finalized, Map.get(finalized, &1.number, [])))
  end

  # `%{version => [%{at, by}]}` from the `approved` / `finalized` events.
  defp finalized_versions(spec_id) do
    Repo.all(
      from(e in Event,
        join: a in Actor,
        on: a.id == e.actor_id,
        where: e.spec_id == ^spec_id and e.action in ["approved", "finalized"],
        order_by: e.number,
        select: {e.version, %{at: e.inserted_at, by: a.name}}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp version_view(version, paths) do
    files =
      Repo.all(
        from(f in File,
          join: b in Blob,
          on: b.id == f.blob_id,
          where: f.version_id == ^version.id,
          order_by: f.path,
          select: {f.path, b.bytes, b.content}
        )
      )
      |> Enum.map(fn {path, bytes, content} ->
        %{path: path, bytes: bytes, content: if(is_nil(paths) or path in paths, do: content)}
      end)

    %{number: version.number, validation: validation(version.validation), files: files}
  end

  defp validation(%{"valid" => valid, "errors" => errors}) do
    %{
      valid: valid,
      errors:
        Enum.map(errors, fn e ->
          %{file: e["file"], line: e["line"], rule: e["rule"], message: e["message"]}
        end)
    }
  end

  ## Diff

  @doc """
  The line diff of versions `from` and `to` (0: no files), as
  `Helmsman.TaskSpecs.Diff` gives it, with `from` and `to`.
  """
  @spec diff(Scope.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def diff(%Scope{} = scope, ident, from, to) do
    with {:ok, task} <- task(scope, ident),
         {:ok, spec} <- spec(task),
         :ok <- known_version(spec, from),
         :ok <- known_version(spec, to) do
      result = Diff.run(TaskSpecs.version_files(spec, from), TaskSpecs.version_files(spec, to))
      {:ok, Map.merge(%{from: from, to: to}, result)}
    end
  end

  defp known_version(spec, n) when is_integer(n) and n >= 0 and n <= spec.latest_version, do: :ok
  defp known_version(_spec, n), do: {:error, {:spec, :version_not_found, n}}

  ## Reviews

  @doc """
  The requests and reviews with their issues and notes (`version:` only
  that version's reviews; `unresolved_only:` only the open or disputed
  issues, and only reviews that have one).
  """
  @spec reviews(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reviews(%Scope{} = scope, ident, opts \\ []) do
    with {:ok, task} <- task(scope, ident),
         {:ok, spec} <- spec(task) do
      {:ok, %{requests: requests(spec), reviews: review_list(spec, opts)}}
    end
  end

  defp requests(spec) do
    Repo.all(
      from(r in ReviewRequest,
        join: v in assoc(r, :version),
        join: a in Actor,
        on: a.id == r.reviewer_id,
        join: b in Actor,
        on: b.id == r.requested_by_id,
        left_join: rv in assoc(r, :review),
        where: r.spec_id == ^spec.id,
        order_by: r.number,
        select: %{
          n: r.number,
          version: v.number,
          reviewer: a.name,
          requested_by: b.name,
          note: r.note,
          status: r.status,
          close_reason: r.close_reason,
          review: rv.number,
          request_run: not is_nil(r.request_run_id),
          at: r.inserted_at,
          closed_at: r.closed_at
        }
      )
    )
  end

  defp review_list(spec, opts) do
    version = Keyword.get(opts, :version)
    unresolved_only = Keyword.get(opts, :unresolved_only, false)

    query =
      from(r in Review,
        join: v in assoc(r, :version),
        join: a in Actor,
        on: a.id == r.reviewer_id,
        where: r.spec_id == ^spec.id,
        order_by: r.number,
        select: {r, v.number, a}
      )

    query = if version, do: from([r, v] in query, where: v.number == ^version), else: query
    rows = Repo.all(query)
    issues = issues(Enum.map(rows, fn {r, _, _} -> r.id end), unresolved_only)

    for {review, version, reviewer} <- rows,
        list = Map.get(issues, review.id, []),
        not unresolved_only or list != [] do
      %{
        number: review.number,
        version: version,
        reviewer: reviewer.name,
        reviewer_user_id:
          if(reviewer.kind == :human, do: reviewer.user_id, else: reviewer.owner_id),
        verdict: review.verdict,
        summary: review.summary,
        at: review.inserted_at,
        issues: Enum.map(list, &issue_view(&1, review.number))
      }
    end
  end

  defp issues([], _unresolved_only), do: %{}

  defp issues(review_ids, unresolved_only) do
    query =
      from(i in Issue,
        where: i.review_id in ^review_ids,
        order_by: i.number,
        preload: [notes: ^from(n in IssueNote, order_by: n.number, preload: :author)]
      )

    query =
      if unresolved_only,
        do: from(i in query, where: i.resolution in [:open, :disputed]),
        else: query

    query |> Repo.all() |> Enum.group_by(& &1.review_id)
  end

  defp issue_view(issue, review_n) do
    %{
      ref: "R#{review_n}.#{issue.number}",
      severity: issue.severity,
      file: issue.file,
      line: issue.line,
      anchor: issue.anchor,
      body: issue.body,
      suggestion: issue.suggestion,
      resolution: issue.resolution,
      notes:
        Enum.map(issue.notes, fn n ->
          %{
            n: n.number,
            author: n.author.name,
            kind: n.kind,
            resolution: n.resolution,
            fixed_in_version: n.fixed_in_version,
            body: n.body,
            at: n.inserted_at
          }
        end)
    }
  end

  ## Events

  @doc "The audit events, in order: `[%{n, actor, action, version, data, at}]`."
  @spec events(Scope.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def events(%Scope{} = scope, ident) do
    with {:ok, task} <- task(scope, ident),
         {:ok, spec} <- spec(task) do
      {:ok,
       Repo.all(
         from(e in Event,
           join: a in Actor,
           on: a.id == e.actor_id,
           where: e.spec_id == ^spec.id,
           order_by: e.number,
           select: %{
             n: e.number,
             actor: a.name,
             action: e.action,
             version: e.version,
             data: e.data,
             at: e.inserted_at
           }
         )
       )}
    end
  end

  ## Permissions and the to-do list

  @doc """
  What the caller may do with the task's spec (for buttons): `write`,
  `request_review`, `rule`, `propose`, `approve`, `reject`, `abandon`,
  `reopen`. Without a spec only `write` (creating it) may be true.
  """
  @spec permissions(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def permissions(%Scope{} = scope, ident) do
    with {:ok, task} <- task(scope, ident) do
      {:ok, permissions_of(scope, task, Repo.get_by(Spec, task_id: task.id))}
    end
  end

  @buttons [:write, :request_review, :rule, :propose, :approve, :reject, :abandon, :reopen]

  defp permissions_of(scope, task, spec) do
    write = allowed?(scope, :write_spec) and allowed?(scope, :write_task, task)
    coordinator = Coordinator.resolve(scope, task)

    roles = %{
      write: write,
      coordinate: write and allowed?(scope, :coordinate_spec, coordinator),
      human: write and allowed?(scope, :approve_spec),
      rule: write and allowed?(scope, :rule_spec_issue, coordinator),
      run: scope.via == :run
    }

    facts = %{status: spec && spec.status, versions: (spec && spec.latest_version) || 0}
    Map.new(@buttons, &{&1, button?(&1, roles, facts)})
  end

  @open [:draft, :in_review, :pending_approval]

  defp button?(:write, r, f), do: r.write and f.status not in [:finalized, :abandoned]

  defp button?(:request_review, r, f),
    do: r.coordinate and not r.run and f.status in [:draft, :in_review] and f.versions > 0

  defp button?(:rule, r, f), do: r.rule and f.status in @open

  defp button?(:propose, r, f),
    do: r.coordinate and not r.human and f.status in [:draft, :in_review]

  defp button?(:approve, r, f), do: r.human and f.status in @open and f.versions > 0
  defp button?(:reject, r, f), do: r.human and f.status == :pending_approval
  defp button?(:abandon, r, f), do: r.coordinate and f.status in @open
  defp button?(:reopen, r, f), do: r.coordinate and f.status in [:finalized, :abandoned]

  defp allowed?(scope, action, resource \\ nil),
    do: Policy.authorize(scope, action, resource) == :ok

  @doc """
  The caller's to-do list: the `pending_approval` specs of the workspace
  (member and above; oldest proposal first) and the `requested` requests
  that ask the user's own identity, at most #{@max_attention} each.
  """
  @spec attention(Scope.t()) :: {:ok, map()} | {:error, term()}
  def attention(%Scope{workspace: workspace, user: user} = scope) do
    with :ok <- Policy.authorize(scope, :view_spec) do
      approvals =
        if scope.role in [:member, :admin, :owner] do
          Repo.all(
            from(s in Spec,
              join: t in Task,
              on: t.id == s.task_id,
              join: a in Actor,
              on: a.id == s.proposal_by_id,
              where: s.workspace_id == ^workspace.id and s.status == :pending_approval,
              order_by: [s.proposed_at, s.id],
              limit: @max_attention,
              select: %{
                task: t.ident,
                title: t.title,
                version: s.proposal_version,
                proposed_by: a.name,
                at: s.proposed_at
              }
            )
          )
        else
          []
        end

      requests =
        Repo.all(
          from(r in ReviewRequest,
            join: s in Spec,
            on: s.id == r.spec_id,
            join: t in Task,
            on: t.id == s.task_id,
            join: v in assoc(r, :version),
            join: me in Actor,
            on: me.id == r.reviewer_id,
            join: b in Actor,
            on: b.id == r.requested_by_id,
            where:
              r.workspace_id == ^workspace.id and r.status == :requested and me.kind == :human and
                me.user_id == ^user.id,
            order_by: [r.inserted_at, r.id],
            limit: @max_attention,
            select: %{
              task: t.ident,
              title: t.title,
              version: v.number,
              requested_by: b.name,
              at: r.inserted_at
            }
          )
        )

      {:ok, %{pending_approval: approvals, review_requests: requests}}
    end
  end

  ## Helpers

  defp task(%Scope{workspace: %{id: workspace_id}} = scope, ident) when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :view_spec),
         {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      {:ok, task}
    else
      {:error, :forbidden} = error -> error
      _other -> {:error, :not_found}
    end
  end

  defp task(_scope, _ident), do: {:error, :not_found}

  defp spec(%Task{ident: ident} = task) do
    case Repo.get_by(Spec, task_id: task.id) do
      nil -> {:error, {:spec, :not_found, ident}}
      spec -> {:ok, spec}
    end
  end

  defp names(ids) do
    ids = Enum.reject(ids, &is_nil/1)

    if ids == [],
      do: %{},
      else: Map.new(Repo.all(from(a in Actor, where: a.id in ^ids, select: {a.id, a.name})))
  end

  ## The run prompt (`add-spec-workflow` decision 12)

  @doc """
  What `Helmsman.Runs.Prompt` needs about specs for a run of `run` on
  `task`: the task's spec (nil: none), the epic's final spec when the
  task has none, the finalize mode, and for the review triggers the
  version to diff against (`diff_base`: the last version before it with a
  review, else the one before). nil without a task.
  """
  @spec prompt_context(Helmsman.Runs.Run.t(), Task.t() | nil) :: map() | nil
  def prompt_context(_run, nil), do: nil

  def prompt_context(run, %Task{} = task) do
    spec = Repo.get_by(Spec, task_id: task.id)

    %{
      task: task.ident,
      mode: Coordinator.mode(task),
      spec: spec && prompt_spec(spec),
      epic: if(is_nil(spec), do: epic_spec(task)),
      diff_base: spec && diff_bases(spec, run)
    }
  end

  defp prompt_spec(spec) do
    counts = unresolved_counts(spec.id)

    %{
      change_id: spec.change_id,
      status: spec.status,
      latest_version: spec.latest_version,
      final_version: spec.final_version,
      proposal_version: spec.proposal_version,
      valid: latest_valid(spec),
      unresolved: counts.p1 + counts.p2,
      pending: length(pending_reviewers(spec))
    }
  end

  defp epic_spec(%Task{epic_id: nil}), do: nil

  defp epic_spec(%Task{epic_id: epic_id}) do
    Repo.one(
      from(s in Spec,
        join: t in Task,
        on: t.id == s.task_id,
        where: s.task_id == ^epic_id and s.status == :finalized,
        select: %{ident: t.ident, final_version: s.final_version}
      )
    )
  end

  defp diff_bases(spec, run) do
    versions =
      for %{"spec_version" => v} <- run.triggers, is_integer(v) and v > 1, uniq: true, do: v

    Map.new(versions, fn v ->
      reviewed =
        Repo.one(
          from(r in Review,
            join: rv in assoc(r, :version),
            where: r.spec_id == ^spec.id and rv.number < ^v,
            select: max(rv.number)
          )
        )

      {v, reviewed || v - 1}
    end)
  end
end
