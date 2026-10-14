defmodule HelmsmanProtocol.CLI do
  @moduledoc "CLI protocol payload."
  use HelmsmanProtocol.Schema
  field(:provider, {:enum, HelmsmanProtocol.providers()})
  field(:version, :string, nullable: true)
  list(:models, :string)
  list(:efforts, :string)
  field(:available, :boolean)
  field(:unavailable_reason, :string, nullable: true, min_bytes: 1, max_bytes: 1_024)

  field(:vendor, :string, nullable: true, max_bytes: 32)

  def validate(%{vendor: vendor} = value) when not is_nil(vendor) do
    if Regex.match?(~r/\A[a-z0-9]{1,32}\z/, vendor),
      do: validate_availability(value),
      else: HelmsmanProtocol.Schema.invalid(["vendor"], :format)
  end

  def validate(value), do: validate_availability(value)

  defp validate_availability(%{available: true, version: nil}),
    do: HelmsmanProtocol.Schema.invalid(["version"], :required)

  defp validate_availability(%{available: true, unavailable_reason: reason})
       when not is_nil(reason),
       do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :not_allowed)

  defp validate_availability(%{available: false, unavailable_reason: nil}),
    do: HelmsmanProtocol.Schema.invalid(["unavailable_reason"], :required)

  defp validate_availability(value), do: {:ok, value}
end
