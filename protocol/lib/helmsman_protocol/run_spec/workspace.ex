defmodule HelmsmanProtocol.RunSpec.Workspace do
  @moduledoc "RunSpec.Workspace protocol payload."
  use HelmsmanProtocol.Schema
  field(:id, :pos_integer)
  field(:slug, :string)
end
