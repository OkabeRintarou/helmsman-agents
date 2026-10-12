defmodule Helmsman.Runs.Spec do
  @moduledoc """
  The run description sent to the daemon that claimed a run
  (`HelmsmanProtocol.RunSpec`, `add-run-lifecycle` decision 9).

  Built inside the claim transaction, after the run was checked again: the
  agent's execution settings come from `Helmsman.Agents.execution_config/1`
  (decrypted `env` and `extra_mcp_servers`). `repo` comes from
  `Helmsman.Runs.GitRepo` (`add-daemon-git-workspace` decision 2); nil
  when the project has no repository, and the daemon then works in a
  scratch directory. The description holds the run token, the push token
  and secrets: it only
  goes into the claim reply and is never logged (the protocol's `Inspect`
  hides those fields).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Repo
  alias Helmsman.Runs.{GitRepo, Prompt, Run}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanProtocol.RunSpec

  @doc """
  The run description of the claimed `run`, with its `token`, the
  server's `base_url` (the MCP endpoint is `base_url <> "/mcp"`) and its
  repository (`GitRepo.resolve/3`; nil: none).
  """
  @spec build(Run.t(), String.t(), String.t(), GitRepo.t() | nil) ::
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
        resume?: not is_nil(resume_session_id),
        repo: repo
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
          extra_mcp_servers: profile.extra_mcp_servers || %{}
        },
        prompt: Prompt.build(run, ctx),
        resume_session_id: resume_session_id,
        repo: repo && repo_spec(repo),
        mcp: %{url: base_url <> "/mcp", token: token},
        limits: %{
          timeout_ms: profile.timeout_minutes * 60_000,
          idle_timeout_ms: profile.idle_timeout_minutes * 60_000
        },
        trigger: main_trigger(run.triggers)
      })
    end
  end

  defp repo_spec(repo) do
    %{
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
  The session to resume (decision 11): with a task, the one of the latest
  ended run of the same agent, task and runtime that has a session, unless
  that run failed with `context_overflow`. Nil without a task.
  """
  @spec resume_session_id(Run.t()) :: String.t() | nil
  def resume_session_id(%Run{task_id: nil}), do: nil

  def resume_session_id(%Run{} = run) do
    query =
      from(r in Run,
        where:
          r.agent_id == ^run.agent_id and r.task_id == ^run.task_id and
            r.runtime_id == ^run.runtime_id and r.id != ^run.id and
            r.status in ^Run.ended_statuses() and not is_nil(r.session_id),
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

  defp trigger_names(run) do
    ids = run.triggers |> Enum.map(& &1["by_actor_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Map.new(Repo.all(from(a in Actor, where: a.id in ^ids, select: {a.id, a.name})))
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
