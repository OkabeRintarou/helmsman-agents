defmodule HelmsmanMCP.Tools.DeleteFilter do
  @moduledoc "`delete_filter`: delete an owned or administrable shared query."
  use HelmsmanMCP.Tool,
    name: "delete_filter",
    description:
      "Delete a saved BQL filter. Private filters belong to their owner; admins may delete shared filters.",
    schema: %{
      filter_id:
        {:required, {:either, {:integer, :string}},
         description: "Filter ID (integer or decimal string)."}
    },
    mode: :read

  alias Helmsman.Filters
  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    with {:ok, _} <- Filters.delete(scope, args["filter_id"]), do: {:ok, %{deleted: true}}
  end
end
