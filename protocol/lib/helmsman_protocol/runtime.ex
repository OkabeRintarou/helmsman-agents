defmodule HelmsmanProtocol.Runtime do
  @moduledoc "Runtime protocol payload."
  use HelmsmanProtocol.Schema
  field(:workspace_id, :pos_integer)
  field(:workspace_slug, :string)
  field(:provider, {:enum, HelmsmanProtocol.providers()})
  field(:runtime_id, :pos_integer)
end
