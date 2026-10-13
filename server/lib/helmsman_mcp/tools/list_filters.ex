defmodule HelmsmanMCP.Tools.ListFilters do
  @moduledoc "`list_filters`: visible saved BQL queries."
  use HelmsmanMCP.Tool,
    name: "list_filters",
    description: "List your private and shared BQL filters, and workspace shared filters.",
    schema: %{},
    mode: :read

  alias Helmsman.Filters
  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope}) do
    with {:ok, filters} <- Filters.list(scope),
         do: {:ok, Enum.map(filters.mine ++ filters.shared, &present/1)}
  end

  def present(f),
    do: %{
      id: f.id,
      name: f.name,
      bql: f.bql,
      shared: f.visibility == :workspace,
      owner: %{id: f.owner_id, name: f.owner.display_name, left: f.owner_left},
      lock_version: f.lock_version
    }
end
