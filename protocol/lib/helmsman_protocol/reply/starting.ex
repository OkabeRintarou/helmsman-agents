defmodule HelmsmanProtocol.Reply.Starting do
  @moduledoc "Reply.Starting protocol payload."
  use HelmsmanProtocol.Schema
  field(:action, {:enum, [:proceed, :abort]})
  field(:reason, :string, nullable: true)

  def validate(%{action: :abort, reason: nil}),
    do: HelmsmanProtocol.Schema.invalid(["reason"], :required)

  def validate(value), do: {:ok, value}
end
