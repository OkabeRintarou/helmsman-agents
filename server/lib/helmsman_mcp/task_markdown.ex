defmodule HelmsmanMCP.TaskMarkdown do
  @moduledoc """
  A task as plain Markdown text for an agent's context (the resource
  `helmsman://tasks/{id}` and the prompt `work_on_task`): fields,
  description, history and the active feedback. Descriptions and feedback
  are included verbatim; nothing is rendered to HTML.
  """

  alias Helmsman.Feedback.Replies
  alias HelmsmanMCP.Present

  @doc "Renders a task detail (`Helmsman.Tasks.detail/1`)."
  @spec render(map()) :: String.t()
  def render(%{} = detail) do
    [
      "# #{detail.id}: #{detail.title}\n",
      fields(detail),
      section("Description", blank(detail.description, "(none)")),
      section("History", Enum.map_join(detail.history, "\n", &event/1)),
      section("Feedback", feedback(detail.feedback))
    ]
    |> Enum.join("\n")
  end

  defp fields(detail) do
    [
      {"Status", Present.status(detail.status)},
      {"Priority", detail.priority},
      {"Labels", if(detail.labels == [], do: "none", else: Enum.join(detail.labels, ", "))},
      {"Requester", actor(detail.created_by)},
      {"Assignee", actor(detail.assignee) || "unassigned"},
      {"Open question", if(detail.open_question, do: "yes", else: "no")},
      {"Version (lock_version)", detail.lock_version}
    ]
    |> Enum.map_join(fn {label, value} -> "- #{label}: #{value}\n" end)
  end

  defp section(title, body), do: "## #{title}\n\n#{body}\n"

  defp event(event) do
    move =
      case event.from do
        nil -> "created as #{Present.status(event.to)}"
        from -> "#{Present.status(from)} -> #{Present.status(event.to)}"
      end

    auto = if event.auto, do: " (auto)", else: ""

    [
      "- #{time(event.at)} #{actor(event.actor)}: #{move}#{auto}",
      event.comment && "  - Comment: #{indent(event.comment)}",
      event.commits != [] && "  - Commits: #{Enum.join(event.commits, ", ")}",
      event.tests && "  - Tests: #{tests(event.tests)}",
      event.feedback && "  - Reason: #{event.feedback}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp tests(tests) do
    result = if tests.passed, do: "passed", else: "failed"
    Enum.join([result, tests.command && "`#{tests.command}`", tests.summary], " - ")
  end

  defp feedback(entries) do
    case Enum.filter(entries, &(&1.status == "active")) do
      [] ->
        "(none)"

      active ->
        Enum.map_join(active, "\n", &feedback_entry/1)
    end
  end

  defp feedback_entry(entry) do
    reply = Replies.label(entry)
    relation = if reply == "", do: "", else: " — " <> reply

    "### #{entry.id} #{entry.kind} by #{actor(entry.author)}, #{time(entry.at)}#{relation}\n\n" <>
      "#{entry.content}\n"
  end

  defp actor(nil), do: nil
  defp actor(%{name: name, kind: kind}), do: "#{name} (#{kind})"

  defp blank(value, default) when value in [nil, ""], do: default
  defp blank(value, _default), do: value

  defp indent(text), do: String.replace(text, "\n", "\n    ")

  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
