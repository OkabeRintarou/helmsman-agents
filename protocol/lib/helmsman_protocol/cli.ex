defmodule HelmsmanProtocol.CLI do
  @moduledoc "CLI protocol payload."
  use HelmsmanProtocol.Schema
  field(:provider, {:enum, HelmsmanProtocol.providers()})
  field(:version, :string, nullable: true)
  list(:models, :string)
  list(:efforts, :string)
  field(:available, :boolean)
  field(:unavailable_reason, :string, nullable: true, min_bytes: 1, max_bytes: 1_024)

  def validate(%{available: true, version: nil}),
    do: HelmsmanProtocol.Schema.invalid(["version"], :required)

  def validate(%{available: true, unavailable_reason: reason}) when not is_nil(reason),
    do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :not_allowed)

  def validate(%{available: false, unavailable_reason: nil}),
    do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :required)

  def validate(value), do: {:ok, value}
end
