defmodule HelmsmanProtocol.CleanupResult do
  @moduledoc "Server permission and commit evidence for safe local cleanup."
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.Schema
  field(:workspace_id, :pos_integer)
  field(:ident, :string, min_bytes: 1)
  field(:deletable, :boolean)
  field(:base_branch, :string, nullable: true)
  list(:pushed_heads, :string, max: 200)

  def validate(value) do
    case Enum.find_index(value.pushed_heads, &(not Regex.match?(~r/\A[0-9a-f]{40}\z/, &1))) do
      nil -> {:ok, value}
      index -> Schema.invalid(["pushed_heads", index], :type)
    end
  end
end
