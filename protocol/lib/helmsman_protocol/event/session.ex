defmodule HelmsmanProtocol.Event.Session do
  @moduledoc "Event.Session protocol payload."
  use HelmsmanProtocol.Schema
  field(:session_id, :string)
end
