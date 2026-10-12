defmodule HelmsmanProtocol.Event.Result do
  @moduledoc "Event.Result protocol payload."
  use HelmsmanProtocol.Schema
  field(:text, :string)
  field(:success, :boolean)
end
