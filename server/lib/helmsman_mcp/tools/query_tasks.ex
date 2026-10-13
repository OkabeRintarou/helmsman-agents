defmodule HelmsmanMCP.Tools.QueryTasks do
  @moduledoc "`query_tasks`: workspace BQL queries and saved filters."
  use HelmsmanMCP.Tool,
    name: "query_tasks",
    description:
      "Query workspace tasks with BQL, or execute a saved filter. Pass exactly one of bql and filter_id. See helmsman://bql for syntax and fields.",
    schema: %{
      bql: {:string, description: "BQL query; an empty string matches everything."},
      filter_id:
        {:meta, {:either, {:integer, :string}},
         description: "Saved filter ID (integer or decimal string)."},
      limit: {:integer, description: "Page size, 1-200; default 50."},
      offset: {:integer, description: "Skip 0-10000 tasks; default 0."}
    },
    mode: :read

  alias Helmsman.{Filters, Tasks}
  alias HelmsmanMCP.{Args, Present}
  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    with {:ok, input} <- input(scope, args),
         {:ok, result} <-
           Tasks.query(scope, input, Map.to_list(Args.take(args, [:limit, :offset]))) do
      {:ok,
       %{
         tasks: Enum.map(result.tasks, &Present.summary/1),
         total: result.total,
         order: order(result.order),
         text:
           "#{result.total} total; #{length(result.tasks)} tasks on this page; order: #{order_text(result.order)}."
       }}
    end
  end

  defp input(scope, args) do
    case {Map.has_key?(args, "bql"), Map.has_key?(args, "filter_id")} do
      {true, false} -> {:ok, args["bql"]}
      {false, true} -> Filters.get(scope, args["filter_id"])
      _ -> {:error, :bql_or_filter}
    end
  end

  defp order(:relevance), do: "relevance"

  defp order(order),
    do:
      Enum.map(order, fn {field, direction} ->
        %{field: to_string(field), dir: to_string(direction)}
      end)

  defp order_text(:relevance), do: "relevance"
  defp order_text(order), do: Enum.map_join(order, ", ", fn {f, d} -> "#{f} #{d}" end)
end
