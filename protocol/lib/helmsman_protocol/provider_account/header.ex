defmodule HelmsmanProtocol.ProviderAccount.Header do
  @moduledoc "A provider request header; its value is write-only outside the wire payload."
  use HelmsmanProtocol.Schema

  @reserved ~w(authorization proxy-authorization host content-length content-type transfer-encoding connection upgrade te trailer keep-alive)
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  field(:value, :string, min_bytes: 1, max_bytes: 4_096)
  use HelmsmanProtocol.Redacted, [:value]

  @doc false
  def valid_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}\z/, name)

  def valid_name?(_), do: false

  @doc false
  def reserved?(name), do: String.downcase(name) in @reserved

  @doc false
  def valid_value?(value) when is_binary(value) and byte_size(value) in 1..4_096//1 do
    String.first(value) != " " and String.last(value) != " " and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
  end

  def valid_value?(_), do: false

  @doc false
  def validate(header) do
    cond do
      not valid_name?(header.name) -> HelmsmanProtocol.Schema.invalid(["name"], :type)
      reserved?(header.name) -> HelmsmanProtocol.Schema.invalid(["name"], :not_allowed)
      not valid_value?(header.value) -> HelmsmanProtocol.Schema.invalid(["value"], :type)
      true -> {:ok, header}
    end
  end
end
