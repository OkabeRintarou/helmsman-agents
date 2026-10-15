defmodule HelmsmanMCP.SpecErrorText do
  @moduledoc """
  The texts of the spec errors `{:spec, reason, ...}` of
  `Helmsman.TaskSpecs` (`add-spec-workflow` decision 20), called by
  `HelmsmanMCP.ErrorText.format/2`.
  """

  alias HelmsmanMCP.Context

  @max_listed 10

  @doc "The text of a spec error, or `:error`."
  @spec format(tuple(), Context.t()) :: {:ok, String.t()} | :error
  def format({:spec, :not_found, ident}, _ctx) do
    {:ok,
     "#{ident} has no spec yet. Create it with submit_spec_version(task_id: \"#{ident}\", " <>
       "base_version: 0, files: [...])."}
  end

  def format({:spec, :stale_version, latest}, ctx) do
    ident = task(ctx)
    given = ctx.args["base_version"] || ctx.args["version"]

    diff =
      if is_integer(given) and given > 0 and given < latest,
        do: "Read the changes with diff_spec(\"#{ident}\", #{given}, #{latest}) and resubmit",
        else: "Read it with get_spec(\"#{ident}\") and resubmit"

    {:ok,
     "The latest version is #{latest}#{if given, do: ", not #{given}", else: ""}. " <>
       "#{diff} with base_version: #{latest}."}
  end

  def format({:spec, :closed, status}, ctx) do
    {:ok,
     "The spec of #{task(ctx)} is #{status}; ask a person or the squad leader to reopen it " <>
       "(update_spec status: \"draft\")."}
  end

  def format({:spec, :not_closed, status}, ctx),
    do:
      {:ok, "The spec of #{task(ctx)} is #{status}: only a finalized or abandoned spec reopens."}

  def format({:spec, :no_changes}, ctx) do
    {:ok, "Nothing changed compared with version #{ctx.args["base_version"] || "the base"}."}
  end

  def format({:spec, :no_version}, ctx) do
    {:ok,
     "The spec of #{task(ctx)} has no version yet. Submit one with submit_spec_version " <>
       "(or delegate(..., spec: \"draft\")) first."}
  end

  def format({:spec, :pending_approval}, ctx) do
    {:ok,
     "The spec of #{task(ctx)} is waiting for a person's approval. Wait for the decision; " <>
       "a new version withdraws the proposal."}
  end

  def format({:spec, :no_proposal}, ctx),
    do: {:ok, "The spec of #{task(ctx)} has no proposal waiting for approval."}

  def format({:spec, :invalid, errors}, ctx) do
    {:ok,
     "Version #{ctx.args["version"] || "the latest"} does not pass validation: " <>
       list_errors(errors) <> ". Fix it and submit a new version."}
  end

  def format({:spec, :unresolved_issues, refs}, _ctx) do
    {:ok,
     "Unresolved P1/P2 issues: #{Enum.join(refs, ", ")}. Reply with reply_spec_issue or rule " <>
       "with rule_spec_issue first."}
  end

  def format({:spec, :reviews_pending, names}, ctx) do
    {:ok,
     "Reviews still pending on version #{ctx.args["version"] || "the latest"} from " <>
       "#{Enum.join(names, ", ")}. Wait for them or cancel_spec_review."}
  end

  def format({:spec, :not_coordinator, %{task: ident, assignee: name, kind: :squad}}, _ctx) do
    {:ok,
     "Only the leader of #{name} (in a run as the squad) or a person can do this on #{ident}."}
  end

  def format({:spec, :not_coordinator, %{task: ident, assignee: name, kind: :agent}}, _ctx),
    do: {:ok, "Only #{name} (the assignee) or a person can do this on #{ident}."}

  def format({:spec, :not_coordinator, %{task: ident}}, _ctx),
    do: {:ok, "Only a person can do this on #{ident}."}

  def format({:spec, :review_pending, %{reviewer: name, request: n, requested_by: by} = p}, ctx) do
    {:ok,
     "#{name} already has a pending review request R#{n} on version #{p[:version]} (requested " <>
       ~s[by #{by}). Wait for it, or cancel_spec_review("#{task(ctx)}", "#{name}") and ] <>
       "delegate again."}
  end

  def format({:spec, :own_version, name}, _ctx),
    do: {:ok, "#{name} wrote the latest version and cannot review it. Pick another reviewer."}

  def format({:spec, :invalid_reviewer, name}, _ctx) do
    {:ok,
     "#{name} cannot review: a reviewer is a person who joined the workspace or an agent " <>
       "(not a squad or the system)."}
  end

  def format({:spec, :issue_resolved, ref, resolution}, _ctx) do
    {:ok,
     "#{ref} is already #{resolution}; you can still add a comment (reply_spec_issue without " <>
       "resolution)."}
  end

  def format({:spec, :issue_not_found, ref}, ctx),
    do:
      {:ok, "There is no issue #{ref} on #{task(ctx)}; list_spec_reviews shows them (R<n>.<i>)."}

  def format({:spec, :request_not_found, ref}, ctx),
    do: {:ok, "No pending review request #{ref} on #{task(ctx)}; list_spec_reviews shows them."}

  def format({:spec, :version_not_found, n}, ctx),
    do: {:ok, "#{task(ctx)} has no spec version #{inspect(n)}; get_spec lists the versions."}

  def format({:spec, :invalid_files, problems}, _ctx) do
    {:ok,
     "Invalid files: " <>
       Enum.map_join(Enum.take(problems, @max_listed), "; ", fn p ->
         if p.path, do: "#{p.path}: #{p.message}", else: p.message
       end) <>
       ". Paths: proposal.md, design.md, tasks.md, specs/<capability>/spec.md."}
  end

  def format({:spec, :invalid_issues, problems}, _ctx) do
    {:ok,
     "Invalid issues: " <>
       Enum.map_join(Enum.take(problems, @max_listed), "; ", fn
         %{index: nil, message: m} -> m
         %{index: i, message: m} -> "issue #{i}: #{m}"
       end) <> "."}
  end

  def format({:spec, :invalid_archive, message}, _ctx) do
    {:ok,
     "Invalid archive: #{message}. Upload a tar.gz or zip of an OpenSpec change directory " <>
       "(at most 2 MB, 200 entries and 1 MB of files; regular files only)."}
  end

  def format({:spec, :invalid_params, %{field: field, message: message}}, _ctx),
    do: {:ok, "#{field} #{message}."}

  def format(_reason, _ctx), do: :error

  defp task(%Context{args: args}), do: args["task_id"] || "the task"

  defp list_errors(errors) do
    errors
    |> Enum.take(@max_listed)
    |> Enum.map_join("; ", fn e ->
      location = if e.line, do: "#{e.file}:#{e.line}", else: e.file
      "#{location} #{e.rule} #{e.message}"
    end)
  end
end
