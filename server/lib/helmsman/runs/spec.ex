defmodule Helmsman.Runs.Spec do
  @moduledoc """
  The run description sent to the daemon that claimed a run
  (`HelmsmanProtocol.RunSpec`, `add-run-lifecycle` decision 9).

  Built inside the claim transaction, after the run was checked again: the
  agent's execution settings come from `Helmsman.Agents.execution_config/1`
  (decrypted `env` and `extra_mcp_servers`). `repo` comes from
  `Helmsman.Runs.GitRepo` (`add-daemon-git-workspace` decision 2); nil
  when the project has no repository, and the daemon then works in a
  scratch directory. The provider account is the one the claim recorded
  on the run (`add-provider-accounts` decision 12), read as it is now:
  this is the only place its API key is read. The description holds the
  run token, the push token, the provider account's key and secrets: it
  only
  goes into the claim reply and is never logged (the protocol's `Inspect`
  hides those fields).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.Prompt, as: DesignPrompt
  alias Helmsman.Agents
  alias Helmsman.Autopilots
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Feedback.Id, as: FeedbackId
  alias Helmsman.ProviderAccounts.{Headers, ProviderAccount}
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{GitRepo, LocalRepo, Prompt, Run}
  alias Helmsman.Squads
  alias Helmsman.Squads.Orchestration
  alias Helmsman.Tasks.{Epics, Task}
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanProtocol.RunSpec

  @design_timeout_minutes 15
  @design_idle_minutes 5

  @doc """
  The run description of the claimed `run`, with its `token`, the
  server's `base_url` (the MCP endpoint is `base_url <> "/mcp"`) and its
  repository (`GitRepo.resolve/3` or `LocalRepo.resolve/4`; nil: none).
  """
  @spec build(Run.t(), String.t(), String.t(), GitRepo.t() | LocalRepo.t() | nil) ::
          {:ok, RunSpec.t()} | {:error, term()}
  def build(%Run{} = run, token, base_url, repo \\ nil)
      when is_binary(token) and is_binary(base_url) do
    with {:ok, profile} <- Agents.execution_config(run.agent_id) do
      agent = Repo.get!(Actor, run.agent_id)
      workspace = Repo.get!(Workspace, run.workspace_id)
      task = run.task_id && Repo.get!(Task, run.task_id)
      resume_session_id = resume_session_id(run)

      ctx = %{
        agent: agent,
        profile: profile,
        workspace: workspace,
        task: task,
        names: trigger_names(run),
        retried: retried(run),
        feedback: quoted_feedback(run, task),
        resume?: not is_nil(resume_session_id),
        repo: repo,
        squad: run.squad_id && Squads.load(run.squad_id),
        autopilot: Autopilots.prompt_context(run),
        delegations: delegations(run),
        spec: Helmsman.TaskSpecs.prompt_context(run, task),
        orchestration: orchestration(run, task)
      }

      RunSpec.new(%{
        run_id: run.id,
        workspace: %{id: workspace.id, slug: workspace.slug},
        task: task && %{ident: task.ident, title: task.title},
        agent: %{
          name: agent.name,
          provider: String.to_existing_atom(profile.provider),
          model: profile.model,
          effort: profile.effort,
          custom_args: profile.custom_args || [],
          env: profile.env || %{},
          extra_mcp_servers: profile.extra_mcp_servers || %{},
          provider_account: provider_account(run.provider_account_id)
        },
        prompt: prompt(run, ctx),
        resume_session_id: resume_session_id,
        repo: repo && repo_spec(repo),
        mcp: %{url: base_url <> "/mcp", token: token},
        limits: limits(run, profile),
        trigger: main_trigger(run.triggers)
      })
    end
  end

  # `add-agent-conversation` decision 8: a design run gets the prompt of
  # its conversation and at most 15 minutes, 5 without output.
  defp prompt(run, ctx) do
    if Runs.design_run?(run), do: DesignPrompt.for_run(run), else: Prompt.build(run, ctx)
  end

  defp limits(run, profile) do
    {timeout, idle} =
      if Runs.design_run?(run),
        do:
          {min(profile.timeout_minutes, @design_timeout_minutes),
           min(profile.idle_timeout_minutes, @design_idle_minutes)},
        else: {profile.timeout_minutes, profile.idle_timeout_minutes}

    %{timeout_ms: timeout * 60_000, idle_timeout_ms: idle * 60_000}
  end

  defp provider_account(nil), do: nil

  defp provider_account(id) do
    account = Repo.get!(ProviderAccount, id)

    %{
      base_url: account.base_url,
      api_key: account.api_key,
      models: account.models || %{},
      headers:
        Enum.map(Headers.decode(account.headers), fn header ->
          %{name: header["name"], value: header["value"]}
        end)
    }
  end

  # `add-local-repositories` decision 13: the name only, no path or token.
  # `add-autopilots` decision 13: a run-only autopilot run gets a read-only
  # checkout (`mode: :snapshot`, no task branch); the claim reply is encoded
  # for the daemon's protocol, and a daemon older than
  # `HelmsmanProtocol.snapshot_version/0` already failed the claim
  # (`Runs.Claim`).
  defp repo_spec(%{kind: :local} = repo) do
    %{
      kind: :local,
      mode: Map.get(repo, :mode, :task),
      name: repo.local_repository.name,
      base_branch: repo.base_branch,
      branch: repo.branch,
      rescue_branches: repo.rescue_branches
    }
  end

  defp repo_spec(repo) do
    %{
      kind: :github,
      mode: Map.get(repo, :mode, :task),
      github_repository_id: repo.repository.github_id,
      clone_url: GitRepo.clone_url(repo.repository),
      base_branch: repo.base_branch,
      branch: repo.branch,
      rescue_branches: repo.rescue_branches,
      git_token: repo.token.token,
      git_token_expires_at: repo.token.expires_at
    }
  end

  @doc """
  The main trigger of a run: the first that is not a retry marker; a
  `reopen` for a merge conflict wins (designs/14 §7). Only retry markers:
  the first of them.
  """
  @spec main_trigger([map()]) :: %{
          kind: String.t(),
          reason: String.t() | nil,
          feedback_id: pos_integer() | nil
        }
  def main_trigger(triggers) do
    trigger =
      Enum.find(triggers, &(&1["kind"] == "reopen" and &1["reason"] == "merge_conflict")) ||
        Enum.find(triggers, &(&1["kind"] != "retry")) || List.first(triggers) ||
        %{"kind" => "manual"}

    %{kind: trigger["kind"], reason: trigger["reason"], feedback_id: trigger["feedback_id"]}
  end

  @doc """
  The session to resume (`update-codex-user-home` decision 7): with a task,
  inspect the latest ended run of the same agent, task and runtime that
  started the CLI. Return its confirmed session unless it failed with
  `context_overflow`. A run without a session prevents falling back to an
  older session; preparation failures do not count. Nil without a task.
  """
  @spec resume_session_id(Run.t()) :: String.t() | nil
  def resume_session_id(%Run{task_id: nil}), do: nil

  def resume_session_id(%Run{} = run) do
    query =
      from(r in Run,
        where:
          r.agent_id == ^run.agent_id and r.task_id == ^run.task_id and
            r.runtime_id == ^run.runtime_id and r.id != ^run.id and
            r.status in ^Run.ended_statuses() and not is_nil(r.started_at),
        order_by: [desc_nulls_last: r.finished_at, desc: r.id],
        limit: 1,
        select: {r.session_id, r.failure_reason}
      )

    case Repo.one(query) do
      {_session, :context_overflow} -> nil
      {session, _reason} -> session
      nil -> nil
    end
  end

  # The system identity is written `Helmsman` (`add-continuation-triggers`
  # decision 9).
  defp trigger_names(run) do
    ids = run.triggers |> Enum.map(& &1["by_actor_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(a in Actor, where: a.id in ^ids, select: {a.id, a.name, a.kind})
    |> Repo.all()
    |> Map.new(fn
      {id, _name, :system} -> {id, "Helmsman"}
      {id, name, _kind} -> {id, name}
    end)
  end

  # The records the triggers quote or refer to, each as the current record
  # of its revision chain.
  defp quoted_feedback(_run, nil), do: %{}

  defp quoted_feedback(run, %Task{} = task) do
    ids =
      run.triggers
      |> Enum.flat_map(&[&1["feedback_id"], &1["question_id"]])
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    ids
    |> current_records(task.id)
    |> then(fn records ->
      loaded =
        records
        |> Map.values()
        |> Enum.uniq_by(& &1.id)
        |> Feedback.load(task.ident)
        |> Map.new(&{&1.id, &1})

      Map.new(records, fn {id, entry} ->
        entry = loaded[entry.id]

        {id,
         %{
           id: FeedbackId.build(task.ident, entry.seq),
           content: entry.content,
           target: entry.target
         }}
      end)
    end)
  end

  # Follows `superseded_by_id` one level per query; chains are short.
  defp current_records([], _task_id), do: %{}

  defp current_records(ids, task_id) do
    entries =
      Map.new(
        Repo.all(from(f in Entry, where: f.id in ^ids and f.task_id == ^task_id)),
        &{&1.id, &1}
      )

    {done, next} =
      Enum.reduce(ids, {%{}, %{}}, fn id, {done, next} ->
        case entries[id] do
          nil -> {done, next}
          %Entry{superseded_by_id: nil} = entry -> {Map.put(done, id, entry), next}
          %Entry{superseded_by_id: later} -> {done, Map.put(next, id, later)}
        end
      end)

    later = current_records(next |> Map.values() |> Enum.uniq(), task_id)

    Enum.reduce(next, done, fn {id, later_id}, acc ->
      case later[later_id] do
        nil -> acc
        entry -> Map.put(acc, id, entry)
      end
    end)
  end

  # `add-squads` decision 9: the members' runs a `delegate_done` reports
  # (their last output) and the squads `delegated` triggers name.
  defp delegations(run) do
    run_ids = for %{"kind" => "delegate_done", "delegated_run_id" => id} <- run.triggers, do: id
    squad_ids = for %{"kind" => "delegated", "squad_id" => id} <- run.triggers, do: id

    runs =
      Map.new(Repo.all(from(r in Run, where: r.id in ^run_ids, select: {r.id, r.summary})))

    squads =
      Repo.all(
        from(s in Squads.Squad,
          join: a in Actor,
          on: a.id == s.actor_id,
          where: s.id in ^squad_ids,
          select: {s.id, a.name}
        )
      )
      |> Map.new()

    %{summaries: runs, squads: squads, orchestrators: orchestrators(run)}
  end

  # The squad names of the runs that started this one by orchestration
  # (`improve-squad-leader-orchestration` decision 15).
  defp orchestrators(run) do
    ids = for %{"orchestrated" => true, "orchestrator_run_id" => id} <- run.triggers, do: id

    if ids == [] do
      %{}
    else
      Repo.all(
        from(r in Run,
          join: s in Squads.Squad,
          on: s.id == r.squad_id,
          join: a in Actor,
          on: a.id == s.actor_id,
          where: r.id in ^ids,
          select: {r.id, a.name}
        )
      )
      |> Map.new()
    end
  end

  # The leader's orchestration section (`improve-squad-leader-orchestration`
  # decision 15): the root and the tasks of its scope with what each waits
  # for (`Helmsman.Tasks.Epics.step_states/2` for an epic's steps), or nil.
  defp orchestration(%Run{squad_id: nil}, _task), do: nil
  defp orchestration(_run, nil), do: nil

  defp orchestration(%Run{squad_id: squad_id}, %Task{} = task) do
    case Orchestration.root(task, squad_id) do
      nil -> nil
      root -> %{root: root, rows: orchestration_rows(root, squad_id)}
    end
  end

  defp orchestration_rows(root, squad_id) do
    ids = root |> Orchestration.scope_ids(squad_id) |> MapSet.delete(root.id)
    steps = if root.kind == :epic, do: Epics.step_states(root), else: []
    steps = Enum.filter(steps, &MapSet.member?(ids, &1.task.id))
    rest = ids |> MapSet.difference(MapSet.new(steps, & &1.task.id)) |> Enum.sort()
    # The subtasks the squad created for the root (`root_task_id`).
    states = steps ++ Epics.task_states(rest)
    assignees = states |> Enum.map(& &1.task.assignee_id) |> Enum.reject(&is_nil/1)

    actors =
      Repo.all(from(a in Actor, where: a.id in ^assignees, select: {a.id, {a.name, a.kind}}))
      |> Map.new()

    Enum.map(states, fn state ->
      {name, kind} = Map.get(actors, state.task.assignee_id, {nil, nil})

      %{
        ident: state.task.ident,
        status: state.task.status,
        title: state.task.title,
        assignee: name,
        assignee_kind: state.assignee_kind || kind,
        waiting_for: state.waiting_for,
        blocked_by: state.blocked_by
      }
    end)
  end

  defp retried(run) do
    ids =
      run.triggers
      |> Enum.filter(&(&1["kind"] == "retry"))
      |> Enum.map(& &1["retry_of"])
      |> Enum.filter(&is_integer/1)

    Map.new(Repo.all(from(r in Run, where: r.id in ^ids, select: {r.id, r.failure_reason})))
  end
end
