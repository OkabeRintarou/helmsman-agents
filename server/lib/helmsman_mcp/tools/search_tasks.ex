defmodule HelmsmanMCP.Tools.SearchTasks do
  @moduledoc "`search_tasks`: full-text search (`add-fulltext-search` decision 10)."

  use HelmsmanMCP.Tool,
    name: "search_tasks",
    description:
      "Full-text search over task IDs, labels, titles, descriptions and feedback, in " <>
        "Chinese and English. Best matches first; an exact task ID such as BOS-12 comes first.",
    schema: %{
      query: {:required, :string, description: "The text to search for."},
      project_key: {:string, description: "Only this project (e.g. BOS)."},
      limit: {:integer, description: "At most this many tasks (default 20, at most 50)."}
    },
    mode: :read

  alias Helmsman.Search
  alias Helmsman.Search.Snippet
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"query" => query} = args, %{scope: scope}) do
    opts =
      [project_key: args["project_key"], limit: args["limit"]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, hits} <- Search.search(scope, query, opts), do: {:ok, Enum.map(hits, &hit/1)}
  end

  defp hit(%{task: task} = hit) do
    compact(%{
      id: task.id,
      title: task.title,
      status: Present.status(task.status),
      project_key: task.project_key,
      assignee: task.assignee && Map.take(task.assignee, [:name, :kind]),
      snippet: hit.snippet && Snippet.to_text(hit.snippet),
      feedback: hit.feedback && feedback(hit.feedback)
    })
  end

  defp feedback(feedback) do
    compact(%{
      id: feedback.id,
      author: feedback.author,
      kind: feedback.kind,
      snippet: feedback.snippet && Snippet.to_text(feedback.snippet)
    })
  end

  # Keys without a value are left out.
  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
