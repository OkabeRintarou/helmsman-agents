defmodule HelmsmanMCP.Present do
  @moduledoc """
  The external form of the domain values MCP returns (designs/08 §3):
  statuses upper case (`IN_PROGRESS`), times ISO 8601 strings, identities
  `%{name, kind}`.

  Fields are copied from a whitelist: a field the domain adds later is not
  shown until it is added here.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Avatars
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.Outcome

  @doc """
  The avatar fields of an identity view (`add-actor-avatars` decision
  13) for the avatar `key` (nil: none): `has_avatar` for every caller;
  `avatar_url`, the REST read address, only for an API token's scope
  (`Helmsman.Avatars.api_url/2`), else nil.
  """
  @spec avatar(Scope.t(), String.t() | nil) :: %{
          has_avatar: boolean(),
          avatar_url: String.t() | nil
        }
  def avatar(%Scope{} = scope, key),
    do: %{has_avatar: is_binary(key), avatar_url: Avatars.api_url(scope, key)}

  @doc """
  Adds the avatar fields to the identity view `view`, looked up by its
  `name` in `appearance` (`Helmsman.Actors.appearance/1`).
  """
  @spec put_avatar(map(), Scope.t(), map()) :: map()
  def put_avatar(%{name: name} = view, %Scope{} = scope, appearance) do
    key = get_in(appearance, [name, :avatar_key])
    Map.merge(view, avatar(scope, key))
  end

  @doc "A project."
  @spec project(Project.t()) :: map()
  def project(%Project{} = project) do
    %{
      key: project.key,
      name: project.name,
      description: project.description,
      archived: not is_nil(project.archived_at),
      archived_at: time(project.archived_at),
      task_count: project.task_seq,
      created_at: time(project.inserted_at),
      updated_at: time(project.updated_at)
    }
  end

  @doc "A task summary (`Helmsman.Tasks.summary/1`)."
  @spec summary(map()) :: map()
  def summary(%{} = summary) do
    %{
      id: summary.id,
      project_key: summary.project_key,
      title: summary.title,
      status: status(summary.status),
      priority: summary.priority,
      labels: summary.labels,
      created_by: actor(summary.created_by),
      assignee: actor(summary.assignee),
      commits: summary.commits,
      feedback_count: summary.feedback_count,
      open_question: summary.open_question,
      blocked: summary.blocked,
      lock_version: summary.lock_version,
      kind: summary.kind,
      epic: summary.epic,
      progress: progress(summary.progress),
      created_at: time(summary.created_at),
      updated_at: time(summary.updated_at)
    }
  end

  @doc """
  A task detail (`Helmsman.Tasks.detail/1`): the summary, the
  description, the history (oldest first), every feedback record, an
  epic's steps (`children`, summaries), a step's `epic_title` and every
  link.
  """
  @spec detail(map()) :: map()
  def detail(%{} = detail) do
    detail
    |> summary()
    |> Map.merge(%{
      description: detail.description,
      history: Enum.map(detail.history, &event/1),
      feedback: Enum.map(detail.feedback, &feedback/1),
      children: detail.children && Enum.map(detail.children, &summary/1),
      epic_title: detail.epic_title,
      links: Enum.map(detail.links, &link/1)
    })
  end

  @doc """
  A task link (`Helmsman.Links.for_task/1`); `waiting_for` only on an
  outgoing `depends_on` that is not satisfied.
  """
  @spec link(map()) :: map()
  def link(%{} = link) do
    view = %{
      type: link.type,
      direction: link.direction,
      task: link.task,
      title: link.title,
      status: status(link.status),
      kind: link.kind,
      actor: actor(link.actor),
      created_at: time(link.created_at)
    }

    case Map.get(link, :waiting_for) do
      nil -> view
      waiting_for -> Map.put(view, :waiting_for, waiting_for)
    end
  end

  @doc "A history entry (`Helmsman.Tasks.event_view/1`)."
  @spec event(map()) :: map()
  def event(%{} = event) do
    %{
      from: status(event.from),
      to: status(event.to),
      actor: actor(event.actor),
      comment: event.comment,
      commits: event.commits,
      tests: tests(event.tests),
      auto: event.auto,
      feedback: event.feedback,
      at: time(event.at)
    }
  end

  @doc "A feedback record (`Helmsman.Feedback.view/1`)."
  @spec feedback(map()) :: map()
  def feedback(%{} = view) do
    %{
      id: view.id,
      seq: view.seq,
      thread_seq: view.thread_seq,
      reply_to: view[:reply_to],
      reply_root: view[:reply_root],
      target: view[:target],
      kind: view.kind,
      content: view.content,
      author: actor(view.author),
      mentions: view.mentions,
      status: view.status,
      supersedes: view.supersedes,
      superseded_by: view.superseded_by,
      at: time(view.at)
    }
    |> put_feedback_dispatch(view[:dispatch] || [])
  end

  # The triggers a record caused (`add-continuation-triggers` decision
  # 10), when there are any.
  defp put_feedback_dispatch(result, []), do: result

  defp put_feedback_dispatch(result, dispatch) do
    Map.put(
      result,
      :dispatch,
      Enum.map(dispatch, &dispatch_item/1)
    )
  end

  # A run as a squad leader names its squad (`add-squads` decision 4).
  defp put_squad(view, %{name: name}), do: Map.put(view, :squad, name)
  defp put_squad(view, _none), do: view

  # A squad's outcome also names the squad and, refused, the blocking
  # leader and members (`add-squads` decision 5).
  defp dispatch_item(item) do
    base = Map.take(item, [:agent, :trigger, :result, :reason])

    Enum.reduce([:squad, :refused], base, fn key, acc ->
      case item[key] do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @doc "A run summary (`Helmsman.Runs.summary/1`)."
  @spec run(map()) :: map()
  def run(%{} = run) do
    %{
      id: run.id,
      task: run.task,
      agent: run.agent,
      lane: run.lane,
      status: status(run.status),
      triggers:
        Enum.map(run.triggers, fn trigger ->
          %{
            kind: trigger.kind,
            by: actor(trigger.by),
            at: time(trigger.at),
            instructions: trigger.instructions
          }
        end),
      failure_reason: run.failure_reason,
      priority: run.priority,
      created_at: time(run.inserted_at),
      updated_at: time(run.updated_at)
    }
    |> put_squad(run[:squad])
  end

  @doc """
  An execution event of a run (`Helmsman.Runs.event_view/1`): `seq`,
  `kind`, `at` and its whitelisted `data`.
  """
  @spec run_event(map()) :: map()
  def run_event(%{seq: seq, type: type, data: data, at: at}),
    do: %{seq: seq, kind: to_string(type), at: time(at), data: data}

  @doc """
  Puts the dispatch outcomes of a task write (`Helmsman.Runs.Outcome`) in
  `result` as `dispatch`, when there are any.
  """
  @spec put_dispatch(map(), [Outcome.t()]) :: map()
  def put_dispatch(result, []), do: result

  def put_dispatch(result, outcomes),
    do: Map.put(result, :dispatch, Enum.map(outcomes, &Outcome.view/1))

  @doc "A status name in upper case (`in_progress` → `IN_PROGRESS`)."
  @spec status(atom() | String.t() | nil) :: String.t() | nil
  def status(nil), do: nil
  def status(status) when is_atom(status), do: status |> Atom.to_string() |> String.upcase()
  def status(status) when is_binary(status), do: String.upcase(status)

  defp actor(nil), do: nil
  defp actor(%{name: name, kind: kind}), do: %{name: name, kind: to_string(kind)}

  defp tests(nil), do: nil

  defp tests(%{} = tests),
    do: %{command: tests.command, passed: tests.passed, summary: tests.summary}

  defp progress(nil), do: nil

  defp progress(%{} = progress) do
    %{
      total: progress.total,
      done: progress.done,
      by_status: Map.new(progress.by_status, fn {name, count} -> {status(name), count} end)
    }
  end

  defp time(nil), do: nil
  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
