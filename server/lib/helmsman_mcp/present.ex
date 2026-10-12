defmodule HelmsmanMCP.Present do
  @moduledoc """
  The external form of the domain values MCP returns (designs/08 §3):
  statuses upper case (`IN_PROGRESS`), times ISO 8601 strings, identities
  `%{name, kind}`.

  Fields are copied from a whitelist: a field the domain adds later is not
  shown until it is added here.
  """

  alias Helmsman.Projects.Project

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
      lock_version: summary.lock_version,
      created_at: time(summary.created_at),
      updated_at: time(summary.updated_at)
    }
  end

  @doc """
  A task detail (`Helmsman.Tasks.detail/1`): the summary, the
  description, the history (oldest first) and every feedback record.
  """
  @spec detail(map()) :: map()
  def detail(%{} = detail) do
    detail
    |> summary()
    |> Map.merge(%{
      description: detail.description,
      history: Enum.map(detail.history, &event/1),
      feedback: Enum.map(detail.feedback, &feedback/1)
    })
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
      kind: view.kind,
      content: view.content,
      author: actor(view.author),
      mentions: view.mentions,
      status: view.status,
      supersedes: view.supersedes,
      superseded_by: view.superseded_by,
      at: time(view.at)
    }
  end

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

  defp time(nil), do: nil
  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
