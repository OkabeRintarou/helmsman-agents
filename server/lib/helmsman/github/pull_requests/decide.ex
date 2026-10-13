defmodule Helmsman.GitHub.PullRequests.Decide do
  @moduledoc """
  What the reconciliation of one task does (`add-pr-reconcile-merge`
  decisions 6–9, 21, 22): a pure function of a database snapshot, what
  GitHub reported and the current time. No I/O.

  ## Snapshot (`Helmsman.GitHub.PullRequests.Snapshot`)

    * `task` - `%{id, ident, title, body, status, assignee_id, slug,
      creator_name}`
    * `project` - `%{base_branch, merge_policy, merge_method, require_ci,
      delete_branch_after_merge}` (`base_branch` already defaulted)
    * `repository` - `%{id, owner, name, available?}`
    * `branch` - the task branch
    * `settings` - the project's binding and merge settings as read (only
      compared by the reconciliation before its writes)
    * `pr` - the current `Helmsman.GitHub.PullRequest` or nil
    * `pushes` - the push records of the task's runs in the project's
      repository (`pushed` and `conflict`): `%{id, agent_id,
      causal_agent_ids, head_sha, base_sha, rescue_branch, claimed_at}`
    * `latest_push` - the latest `pushed` one (decision 6) or nil
    * `active_run_id` - a `claimed | running | cancelling` run or nil
    * `verification` - the latest move to `verified`: `%{id, actor_id,
      actor_kind, actor_name, verified_sha, run_causal_agent_ids,
      inserted_at}` or nil
    * `max_auto_reopens`, `public_url`

  ## GitHub input

    * `pr` - the current row's pull request as read now
      (`Helmsman.GitHub.PullRequests.Api.facts/1`)
    * `found` - an open pull request of the task branch not recorded yet
    * `checks` - `%{runs: [check run], statuses: [status]}` of the head
    * `chain_base` - `%{sha => compare status}` for the base the verified
      push chain ends on (`chain_end/2`)
    * `included` - whether the latest push is in the merged pull request
      (decision 21); nil when unknown

  ## Result

  `{actions, changes}`: `changes` (a keyword list) applies to the row the
  decision is about (the current row, or the one `{:adopt, facts}`
  records first); actions run in order.
  """

  alias Helmsman.GitHub.PullRequest

  @failure_conclusions ~w(failure cancelled timed_out action_required startup_failure stale)
  @passing_conclusions ~w(success neutral skipped)
  @ci_timeout_seconds 6 * 3600
  @max_failed_names 5
  @max_name_bytes 100
  @max_failed_lines 20
  @max_summary_bytes 2048
  @max_note_bytes 1024
  @max_body_chars 2000

  @type action ::
          {:adopt, map()}
          | {:create, map()}
          | :close
          | :reopen
          | :to_draft
          | :ready
          | {:merge, map()}
          | {:auto_reopen, map()}
          | {:escalate, map()}
          | :cleanup
          | {:poll, pos_integer()}

  @doc "Decides the actions and row changes; see the module documentation."
  @spec decide(map(), map() | nil, DateTime.t()) :: {[action()], keyword()}
  def decide(%{repository: %{available?: false}} = snap, _github, _now) do
    if snap.task.status == :verified and PullRequest.open?(snap.pr),
      do: {[], blocked(:repository_unavailable, "Repository is not available.")},
      else: {[], []}
  end

  def decide(snap, github, now) do
    github = github || %{}

    case current(snap, github) do
      {nil, adopt} ->
        {adopt ++ create_actions(snap), []}

      {row, adopt} ->
        {actions, changes} = by_state(snap, row, github, now)
        {adopt ++ actions, facts_changes(row) ++ changes}
    end
  end

  # The row the decision is about, with GitHub's facts applied, and the
  # adoption of an unrecorded open pull request (decision 5 step 2). A
  # merge not recorded yet is recorded first; the adoption follows on the
  # next reconciliation.
  defp current(snap, github) do
    row = with_facts(snap.pr, github[:pr])

    case {row, github[:found]} do
      {%PullRequest{state: :merged, merged_at: nil}, _found} ->
        {row, []}

      {row, found} when found != nil and (row == nil or row.state not in [:draft, :open]) ->
        {adopted_row(snap, found), [{:adopt, found}]}

      {row, _found} ->
        {row, []}
    end
  end

  defp with_facts(nil, _facts), do: nil
  defp with_facts(row, nil), do: row

  defp with_facts(row, facts),
    do: %{row | state: facts.state, head_sha: facts.head_sha || row.head_sha}

  defp adopted_row(snap, facts) do
    %PullRequest{
      number: facts.number,
      node_id: facts.node_id,
      url: facts.url,
      branch: snap.branch,
      base_branch: facts.base_branch || snap.project.base_branch,
      state: facts.state,
      head_sha: facts.head_sha
    }
  end

  defp facts_changes(row), do: [state: row.state, head_sha: row.head_sha]

  ## Decision 6: the target state

  defp by_state(snap, %PullRequest{state: state} = row, _github, _now)
       when state in [:draft, :open] and snap.task.status in [:cancelled, :rejected],
       do: {[:close], reset_merge(row)}

  defp by_state(snap, %PullRequest{state: :open} = row, _github, _now)
       when snap.task.status in [:new, :in_progress] do
    if row.draft_supported, do: {[:to_draft], reset_merge(row)}, else: {[], reset_merge(row)}
  end

  defp by_state(snap, %PullRequest{state: :draft} = row, _github, _now)
       when snap.task.status in [:new, :in_progress],
       do: {[], reset_merge(row)}

  defp by_state(snap, %PullRequest{state: :draft} = row, _github, _now)
       when snap.task.status == :done,
       do: {[:ready], reset_merge(row)}

  defp by_state(snap, %PullRequest{state: :draft}, _github, _now)
       when snap.task.status == :verified,
       do: {[:ready], []}

  defp by_state(snap, %PullRequest{state: :open} = row, _github, _now)
       when snap.task.status == :done,
       do: {[], reset_merge(row)}

  defp by_state(snap, %PullRequest{state: :open} = row, github, now)
       when snap.task.status == :verified,
       do: evaluate(snap, row, github, now)

  defp by_state(snap, %PullRequest{state: :closed, closed_by_helmsman: true}, _github, _now)
       when snap.task.status in [:new, :in_progress, :done, :verified],
       do: {[:reopen], []}

  defp by_state(snap, %PullRequest{state: :closed, closed_by_helmsman: false}, _github, _now)
       when snap.task.status == :verified do
    {[],
     blocked(
       :pr_closed,
       "The pull request was closed on GitHub; reopen it there to continue."
     ) ++ [waiting_since: nil]}
  end

  defp by_state(_snap, %PullRequest{state: :closed} = row, _github, _now),
    do: {[], reset_merge(row)}

  defp by_state(snap, %PullRequest{state: :merged} = row, github, now),
    do: merged(snap, row, github, now)

  # Leaving the merge evaluation (the task is no longer verified) drops
  # its status; a merge stays recorded.
  defp reset_merge(%PullRequest{merge_status: status, waiting_since: nil})
       when status in [:none, :merged],
       do: []

  defp reset_merge(%PullRequest{merge_status: :merged}), do: [waiting_since: nil]

  defp reset_merge(_row),
    do: [merge_status: :none, merge_reason: nil, merge_note: nil, waiting_since: nil]

  defp create_actions(snap) do
    if snap.latest_push != nil and snap.task.status not in [:cancelled, :rejected] do
      [
        {:create,
         %{
           head: snap.branch,
           head_sha: snap.latest_push.head_sha,
           base: snap.project.base_branch,
           title: "#{snap.task.ident}: #{snap.task.title}",
           body: body(snap),
           draft: snap.task.status in [:new, :in_progress]
         }}
      ]
    else
      []
    end
  end

  @doc """
  The pull request body (decision 12): the task link, the first
  #{@max_body_chars} characters of the task body quoted, and the
  Helmsman footer.
  """
  @spec body(map()) :: String.t()
  def body(%{task: task, public_url: public_url}) do
    link = "Task: #{public_url}/w/#{task.slug}/t/#{task.ident}"
    text = task.body || ""

    quoted =
      if String.trim(text) == "" do
        []
      else
        lines =
          text
          |> String.slice(0, @max_body_chars)
          |> String.split("\n")
          |> Enum.map(&String.trim_trailing("> " <> &1))

        lines = if String.length(text) > @max_body_chars, do: lines ++ ["> …"], else: lines
        [Enum.join(lines, "\n")]
      end

    footer =
      "---\nManaged by Helmsman. Commits pushed to this branch outside Helmsman runs " <>
        "are not merged automatically."

    Enum.join([link | quoted] ++ [footer], "\n\n")
  end

  ## Merged pull requests (decisions 6, 7 end, 21)

  # Recording `merged_at` (the first time) or a new `included_sha` calls
  # the dependency hook in the same transaction (the reconciliation's
  # `update_row`), so the decision only returns the facts.
  defp merged(snap, row, github, now) when is_nil(row.merged_at) do
    facts = github[:pr]
    {include_actions, include_changes} = inclusion(snap, row, github)
    row = %{row | included_sha: Keyword.get(include_changes, :included_sha, row.included_sha)}

    {include_actions ++ cleanup(snap, row),
     [
       merged_at: now,
       merged_sha: (facts && facts.merge_commit_sha) || row.merged_sha,
       merge_status: :merged,
       merge_reason: nil,
       merge_note: nil,
       waiting_since: nil
     ] ++ include_changes}
  end

  defp merged(snap, row, github, _now) do
    {include_actions, include_changes} = inclusion(snap, row, github)
    row = %{row | included_sha: Keyword.get(include_changes, :included_sha, row.included_sha)}
    {include_actions ++ cleanup(snap, row), include_changes}
  end

  # Whether the latest push is in the merged pull request (decision 21).
  defp inclusion(%{latest_push: nil}, _row, _github), do: {[], []}

  defp inclusion(%{latest_push: %{head_sha: sha}}, %{included_sha: sha}, _github),
    do: {[], []}

  defp inclusion(snap, row, github) do
    sha = snap.latest_push.head_sha

    cond do
      sha == row.head_sha ->
        {[], [included_sha: sha]}

      github[:included] == true ->
        {[], [included_sha: sha]}

      github[:included] == false and snap.task.status in [:new, :in_progress, :done, :verified] ->
        {create_actions(snap), []}

      true ->
        {[], []}
    end
  end

  # After a merge, once: verified, no active run, the latest push is the
  # merged head (decision 7, end).
  defp cleanup(snap, row) do
    if settled?(snap, row) and cleanup_pending?(snap, row), do: [:cleanup], else: []
  end

  defp settled?(%{latest_push: nil}, _row), do: false

  defp settled?(snap, row) do
    latest = snap.latest_push.head_sha

    snap.task.status == :verified and is_nil(snap.active_run_id) and latest == row.head_sha and
      row.included_sha == latest
  end

  defp cleanup_pending?(snap, row) do
    (snap.project.delete_branch_after_merge and is_nil(row.branch_deleted_at)) or
      is_nil(row.rescue_cleaned_at)
  end

  ## Decision 7: the merge evaluation

  defp evaluate(snap, row, github, now) do
    v = snap.verification
    request = merge_request(row, v)

    with :ok <- check_policy(snap, v, request),
         :ok <- check_independence(snap, v, request),
         :ok <- check_verified_sha(snap, v),
         :ok <- check_chain(snap, v, github),
         :ok <- check_active_run(snap),
         :ok <- check_head(row, v) do
      check_ci(snap, row, v, github, now)
    else
      {:stop, changes} -> {[], changes ++ [waiting_since: nil]}
    end
  end

  @doc "The merge request of `row` when it is for the verification `v`, else nil."
  @spec merge_request(PullRequest.t(), map() | nil) :: map() | nil
  def merge_request(%PullRequest{merge_request: %{"verification_event_id" => id} = r}, %{id: id}),
    do: r

  def merge_request(_row, _v), do: nil

  defp check_policy(%{project: %{merge_policy: "manual"}}, _v, nil),
    do: stop(:none, :policy_manual, "Merge policy is manual; merge on GitHub or use Merge now.")

  defp check_policy(%{project: %{merge_policy: "on_verified_human"}}, v, nil)
       when v == nil or v.actor_kind != :human,
       do:
         stop(
           :blocked,
           :agent_verified,
           "Verified by an agent; this project only merges automatically after a person verifies."
         )

  defp check_policy(_snap, _v, _request), do: :ok

  defp check_independence(_snap, _v, %{"skip_independence_reason" => reason})
       when is_binary(reason),
       do: :ok

  defp check_independence(_snap, nil, _request), do: :ok

  defp check_independence(snap, v, _request) do
    case independence(snap, v) do
      :ok -> :ok
      {:error, note} -> stop(:blocked, :not_independent, note)
    end
  end

  @doc """
  Whether the verification `v` is independent of the work (decision 7
  step 2): `:ok` or `{:error, note}` saying which rule fails.
  """
  @spec independence(map(), map()) :: :ok | {:error, String.t()}
  def independence(snap, v) do
    provenance = provenance(snap.pushes)

    cond do
      v.actor_kind == :system ->
        {:error, "Not independent: verified by the system identity."}

      v.actor_id in provenance ->
        {:error, "Not independent: #{v.actor_name} contributed commits to this branch."}

      v.actor_kind == :agent and
          not MapSet.disjoint?(MapSet.new(v.run_causal_agent_ids || []), provenance) ->
        {:error,
         "Not independent: #{v.actor_name} verified in a run caused by an agent " <>
           "that contributed commits."}

      v.actor_id == snap.task.assignee_id ->
        {:error, "Not independent: #{v.actor_name} is the assignee (self-verification)."}

      true ->
        :ok
    end
  end

  @doc "The agents that contributed commits: every push's agent and causal chain."
  @spec provenance([map()]) :: MapSet.t()
  def provenance(pushes),
    do: MapSet.new(Enum.flat_map(pushes, &[&1.agent_id | &1.causal_agent_ids || []]))

  defp check_verified_sha(_snap, v) when v == nil or v.verified_sha == nil,
    do:
      stop(
        :blocked,
        :verified_sha_missing,
        "This verification has no recorded commit. Re-verify at the current commit."
      )

  defp check_verified_sha(snap, v) do
    if Enum.any?(snap.pushes, &(is_nil(&1.rescue_branch) and &1.head_sha == v.verified_sha)),
      do: :ok,
      else:
        stop(
          :blocked,
          :verified_sha_not_pushed,
          "The verified commit was not pushed to this repository by a Helmsman run. " <>
            "Re-verify at the current commit, or merge it on GitHub."
        )
  end

  defp check_chain(snap, v, github) do
    case chain_end(snap.pushes, v.verified_sha) do
      {:ok, base} ->
        if Map.get(github[:chain_base] || %{}, base) in ["identical", "behind"],
          do: :ok,
          else: chain_broken(base)

      {:broken, sha} ->
        chain_broken(sha)
    end
  end

  defp chain_broken(sha),
    do:
      stop(
        :blocked,
        :push_chain_broken,
        "Commit #{short(sha)} on the branch was not pushed by a Helmsman run; merge it on GitHub."
      )

  @doc """
  Follows the push chain from the push of `verified_sha` (decision 7 step
  4): `{:ok, base}`, the base that must be on the base branch, or
  `{:broken, sha}` when the chain comes back to a push already followed.
  Only pushes to the task branch count.
  """
  @spec chain_end([map()], String.t()) :: {:ok, String.t()} | {:broken, String.t()}
  def chain_end(pushes, verified_sha) do
    by_head =
      pushes
      |> Enum.filter(&is_nil(&1.rescue_branch))
      |> Map.new(&{&1.head_sha, &1})

    follow(by_head, verified_sha, %{})
  end

  defp follow(by_head, sha, seen) do
    cond do
      Map.has_key?(seen, sha) -> {:broken, sha}
      push = by_head[sha] -> follow(by_head, push.base_sha, Map.put(seen, sha, true))
      true -> {:ok, sha}
    end
  end

  defp check_active_run(%{active_run_id: nil}), do: :ok

  defp check_active_run(%{active_run_id: id}),
    do: stop(:waiting, :run_active, "Waiting for run ##{id} to finish.")

  defp check_head(row, v) do
    if row.head_sha == v.verified_sha,
      do: :ok,
      else: stop(:stale, :head_changed, "New commits after verification.")
  end

  defp check_ci(snap, row, v, github, now) do
    {state, checks} = summarize_checks(github[:checks], row.head_sha)
    ci = [checks_state: state, checks: checks]

    case effective_ci(state, snap.project.require_ci) do
      :pending -> pending(row, v, now, ci)
      :failure -> failure(snap, row, v, :ci_failed, ci_failed_content(row, github[:checks]), ci)
      :success -> mergeable(snap, row, v, github, ci)
    end
  end

  defp effective_ci(:none, true), do: :pending
  defp effective_ci(:none, false), do: :success
  defp effective_ci(state, _require), do: state

  defp pending(row, v, now, ci) do
    since =
      cond do
        is_nil(row.waiting_since) -> now
        # A new verification restarts the wait.
        DateTime.before?(row.waiting_since, v.inserted_at) -> now
        true -> row.waiting_since
      end

    waited = DateTime.diff(now, since)

    if waited > @ci_timeout_seconds do
      {[],
       ci ++ blocked(:ci_timeout, "CI did not finish within 6 hours.") ++ [waiting_since: since]}
    else
      {[{:poll, (waited / 4) |> trunc() |> max(60) |> min(900)}],
       ci ++
         [
           merge_status: :waiting,
           merge_reason: :ci_pending,
           merge_note: "Waiting for CI.",
           waiting_since: since
         ]}
    end
  end

  # `mergeable` is null while GitHub computes it: ask again shortly.
  defp mergeable(snap, row, v, github, ci) do
    facts = github[:pr] || github[:found]

    if facts == nil or facts.mergeable == nil do
      {[{:poll, 30}], ci ++ [waiting_since: nil]}
    else
      {[
         {:merge,
          %{sha: v.verified_sha, method: snap.project.merge_method, row_head: row.head_sha}}
       ], ci ++ [waiting_since: nil]}
    end
  end

  @doc """
  What a merge call's result means (decision 7 step 9):

    * `{:merged, sha}` - `merged`, with the merge commit
    * `:head_changed` - 409, or 422 with a new head: `stale`
    * `{:not_allowed, mergeable_state, message}` - 405, with the pull
      request read again: `dirty` → the automatic reopen for a conflict;
      a message about required status checks → `waiting`; else `blocked`
      with GitHub's message
  """
  @spec merge_outcome(map(), PullRequest.t(), map(), term()) :: {[action()], keyword()}
  def merge_outcome(_snap, _row, _v, {:merged, sha}),
    do: {[], [merge_status: :merged, merged_sha: sha, merge_reason: nil, merge_note: nil]}

  def merge_outcome(_snap, _row, _v, :head_changed),
    do:
      {[],
       [
         merge_status: :stale,
         merge_reason: :head_changed,
         merge_note: "New commits after verification."
       ]}

  def merge_outcome(snap, row, v, {:not_allowed, "dirty", _message}),
    do: failure(snap, row, v, :merge_conflict, conflict_content(row))

  def merge_outcome(_snap, _row, _v, {:not_allowed, _state, message}) do
    message = message || ""

    if String.match?(message, ~r/status check|expected/i) do
      {[{:poll, 60}],
       [
         merge_status: :waiting,
         merge_reason: :required_checks,
         merge_note: "Waiting for required checks."
       ]}
    else
      {[],
       blocked(
         :merge_rejected,
         String.trim(truncate(message, 500) <> " Resolve it on GitHub.")
       )}
    end
  end

  @doc "The task branch could not be restored for a new pull request (decision 6)."
  @spec branch_missing() :: keyword()
  def branch_missing,
    do:
      blocked(
        :branch_missing,
        "The task branch no longer exists on GitHub and could not be restored."
      )

  @doc """
  The automatic reopen for `reason` (`:ci_failed` or `:merge_conflict`)
  of the verification `v`, or, once the reopens are used up, `failed`
  and the question to the task's creator once per verification
  (decisions 8, 9). `changes` are kept.
  """
  @spec failure(map(), PullRequest.t(), map(), atom(), String.t(), keyword()) ::
          {[action()], keyword()}
  def failure(snap, row, v, reason, content, changes \\ []) do
    if row.auto_reopen_count >= snap.max_auto_reopens do
      {limit_reason, note} = limit(reason, row.auto_reopen_count)

      escalate =
        if row.escalated_event_id == v.id,
          do: [],
          else: [
            {:escalate, %{verification_event_id: v.id, content: question(snap, row, reason)}}
          ]

      {escalate,
       changes ++
         [merge_status: :failed, merge_reason: limit_reason, merge_note: note, waiting_since: nil]}
    else
      {[{:auto_reopen, %{verification_event_id: v.id, reason: reason, content: content}}],
       changes ++ [waiting_since: nil]}
    end
  end

  defp limit(:ci_failed, n),
    do: {:ci_failed_limit, "CI failed again after #{n} automatic reopens; waiting for a person."}

  defp limit(:merge_conflict, n),
    do:
      {:merge_conflict_limit,
       "The pull request still has merge conflicts after #{n} automatic reopens; " <>
         "waiting for a person."}

  defp question(snap, row, reason) do
    what = if reason == :ci_failed, do: "CI failed", else: "has merge conflicts"

    "@#{snap.task.creator_name} #{snap.task.ident} still fails (#{what}) after " <>
      "#{row.auto_reopen_count} automatic reopens. A person needs to look at it: #{row.url}"
  end

  @doc "The review written when CI failed on the pull request (decision 8)."
  @spec ci_failed_content(PullRequest.t(), map() | nil) :: String.t()
  def ci_failed_content(row, checks) do
    checks = checks || %{runs: [], statuses: []}
    failed_runs = Enum.filter(checks.runs, &(run_state(&1) == :failure))
    failed_statuses = Enum.filter(checks.statuses, &(&1["state"] in ["failure", "error"]))

    lines =
      (Enum.map(failed_runs, &"- #{&1["name"]}: #{&1["conclusion"]} #{&1["details_url"]}") ++
         Enum.map(failed_statuses, &"- #{&1["context"]}: #{&1["state"]} #{&1["target_url"]}"))
      |> Enum.take(@max_failed_lines)
      |> Enum.map(&String.trim_trailing/1)

    output =
      with [%{"output" => %{} = output} | _] <- failed_runs,
           text when text != "" <-
             [output["title"], output["summary"]]
             |> Enum.reject(&(&1 in [nil, ""]))
             |> Enum.join("\n\n") do
        [truncate(text, @max_summary_bytes)]
      else
        _ -> []
      end

    header = "CI failed on #{short(row.head_sha)} (pull request ##{row.number}):"
    Enum.join([Enum.join([header | lines], "\n") | output], "\n\n")
  end

  @doc "The review written when the pull request has merge conflicts (decision 8)."
  @spec conflict_content(PullRequest.t()) :: String.t()
  def conflict_content(row) do
    "Pull request ##{row.number} has merge conflicts with #{row.base_branch}. The next run " <>
      "merges #{row.base_branch} into #{row.branch}; resolve the conflicts there."
  end

  ## Checks (decisions 7 step 7, 22)

  @doc """
  Summarizes check runs and commit statuses into a `checks_state` and the
  `checks` detail (decision 22) of `head_sha`.
  """
  @spec summarize_checks(map() | nil, String.t() | nil) ::
          {:none | :pending | :success | :failure, map() | nil}
  def summarize_checks(nil, _head_sha), do: {:none, nil}

  def summarize_checks(%{runs: runs, statuses: statuses}, head_sha) do
    run_states = Enum.map(runs, &run_state/1)
    status_states = Enum.map(statuses, &status_state(&1["state"]))
    states = run_states ++ status_states

    state =
      cond do
        states == [] -> :none
        :failure in states -> :failure
        :pending in states -> :pending
        true -> :success
      end

    failed =
      failed_names(Enum.zip(runs, run_states), "name") ++
        failed_names(Enum.zip(statuses, status_states), "context")

    {state,
     %{
       "head_sha" => head_sha,
       "total" => length(states),
       "passed" => Enum.count(states, &(&1 == :success)),
       "pending" => Enum.count(states, &(&1 == :pending)),
       "failed" =>
         failed
         |> Enum.map(&truncate(&1, @max_name_bytes))
         |> Enum.uniq()
         |> Enum.sort()
         |> Enum.take(@max_failed_names)
     }}
  end

  defp failed_names(pairs, key),
    do: for({item, :failure} <- pairs, do: to_string(item[key] || ""))

  defp run_state(%{"status" => "completed", "conclusion" => conclusion}) do
    cond do
      conclusion in @passing_conclusions -> :success
      conclusion in @failure_conclusions -> :failure
      true -> :pending
    end
  end

  defp run_state(_run), do: :pending

  defp status_state("success"), do: :success
  defp status_state(state) when state in ["failure", "error"], do: :failure
  defp status_state(_state), do: :pending

  ## Helpers

  defp stop(status, reason, note),
    do: {:stop, [merge_status: status, merge_reason: reason, merge_note: note(note)]}

  defp blocked(reason, note),
    do: [merge_status: :blocked, merge_reason: reason, merge_note: note(note)]

  defp note(text), do: truncate(text, @max_note_bytes)

  @doc "The first 7 characters of a SHA."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: "(none)"
  def short(sha), do: String.slice(sha, 0, 7)

  @doc "Truncates `text` to at most `bytes` bytes without splitting a character."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, bytes) when byte_size(text) <= bytes, do: text
  def truncate(text, bytes), do: valid_prefix(binary_part(text, 0, bytes))

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
