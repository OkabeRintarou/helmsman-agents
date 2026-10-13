defmodule HelmsmanProtocol.LocalRepository do
  @moduledoc "Local repository reported by a daemon in `join` / `sync` (protocol 3)."
  use HelmsmanProtocol.Schema
  field(:name, :string, min_bytes: 1, max_bytes: 255)
  field(:path, :string, min_bytes: 1, max_bytes: 4_096)
  list(:workspaces, :pos_integer, max: 1_000)
  field(:default_branch, :string, nullable: true, min_bytes: 1, max_bytes: 255)
  field(:available, :boolean)
  field(:unavailable_reason, :string, nullable: true, min_bytes: 1, max_bytes: 1_024)

  @doc false
  def validate(%{available: true, unavailable_reason: reason}) when not is_nil(reason),
    do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :not_allowed)

  def validate(%{available: false, unavailable_reason: nil}),
    do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :required)

  def validate(value), do: {:ok, value}
end
