defmodule HelmsmanMCP.Tools.SaveFilter do
  @moduledoc "`save_filter`: create or partially update a saved BQL query."
  # User-owned metadata: use the read identity path, avoiding an automatic
  # agent creation for a filter write. The domain enforces write permission.
  use HelmsmanMCP.Tool,
    name: "save_filter",
    description:
      "Save a BQL filter. Without filter_id, name and bql are required. With filter_id, change only provided fields. Only the owner may change shared; lock_version rejects stale updates.",
    schema: %{
      name: {:string, description: "Name, 1–80 characters."},
      bql: {:string, description: "BQL query."},
      filter_id:
        {:meta, {:either, {:integer, :string}},
         description: "ID to update (integer or decimal string)."},
      shared:
        {:boolean, description: "Share with the workspace (default false for new filters)."},
      lock_version: {:integer, description: "Expected version when updating."}
    },
    mode: :read

  alias Helmsman.Filters
  alias HelmsmanMCP.Args
  alias HelmsmanMCP.Tools.ListFilters
  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    attrs = Args.take(args, [:name, :bql, :lock_version])

    attrs =
      case Map.fetch(args, "shared") do
        {:ok, true} -> Map.put(attrs, :visibility, :workspace)
        {:ok, false} -> Map.put(attrs, :visibility, :private)
        {:ok, _} -> Map.put(attrs, :visibility, :invalid)
        :error -> attrs
      end

    result =
      case Map.fetch(args, "filter_id") do
        {:ok, id} -> Filters.update(scope, id, attrs)
        :error -> Filters.create(scope, Map.delete(attrs, :lock_version))
      end

    with {:ok, filter} <- result, do: {:ok, ListFilters.present(filter)}
  end
end
