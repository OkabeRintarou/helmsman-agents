defmodule HelmsmanProtocol.ErrorReply do
  @moduledoc "Channel errors and the structured version incompatibility response."
  alias HelmsmanProtocol.Schema
  use HelmsmanProtocol.Schema

  @codes ~w(invalid_payload unsupported_protocol not_found wrong_state)a
  field(:reason, {:enum, @codes})
  field(:message, :string)
  field(:server_version, :pos_integer, nullable: true)
  field(:min_version, :pos_integer, nullable: true)
  field(:upgrade_url, :string, nullable: true)

  @spec codes() :: [atom()]
  def codes, do: @codes

  @spec new(atom(), String.t()) :: {:ok, t()} | {:error, HelmsmanProtocol.Schema.error()}
  def new(reason, message), do: new(%{reason: reason, message: message})

  @spec unsupported_protocol(String.t()) :: {:ok, t()} | {:error, HelmsmanProtocol.Schema.error()}
  def unsupported_protocol(upgrade_url) do
    new(%{
      reason: :unsupported_protocol,
      message: "Unsupported protocol version",
      server_version: HelmsmanProtocol.version(),
      min_version: HelmsmanProtocol.min_version(),
      upgrade_url: upgrade_url
    })
  end

  def validate(%{reason: :unsupported_protocol} = value) do
    case Enum.find([:server_version, :min_version, :upgrade_url], &is_nil(Map.fetch!(value, &1))) do
      nil -> {:ok, value}
      field -> HelmsmanProtocol.Schema.invalid([Atom.to_string(field)], :required)
    end
  end

  def validate(value), do: {:ok, value}

  def from_wire(%{"reason" => "unsupported_protocol"} = payload),
    do: Schema.decode(__MODULE__, __schema__(), payload, :wire)

  def from_wire(payload) when is_map(payload),
    do:
      Schema.decode(
        __MODULE__,
        __schema__(),
        Map.drop(payload, ~w(server_version min_version upgrade_url)),
        :wire
      )

  def from_wire(payload), do: Schema.decode(__MODULE__, __schema__(), payload, :wire)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: Schema.invalid([], :type)
  end

  def new(%{reason: reason} = attrs)
      when reason not in [:unsupported_protocol, "unsupported_protocol"] do
    Schema.decode(
      __MODULE__,
      __schema__(),
      Map.drop(attrs, [:server_version, :min_version, :upgrade_url]),
      :native
    )
  end

  def new(attrs), do: Schema.decode(__MODULE__, __schema__(), attrs, :native)

  def to_wire(%{reason: :unsupported_protocol} = value), do: Schema.encode(value, __schema__())
  def to_wire(value), do: Map.take(Schema.encode(value, __schema__()), ~w(reason message))
end
