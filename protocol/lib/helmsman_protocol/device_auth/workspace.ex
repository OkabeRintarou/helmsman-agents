defmodule HelmsmanProtocol.DeviceAuth.Workspace do
  @moduledoc "Workspace device authorization payload."
  use HelmsmanProtocol.Schema
  field(:id, :pos_integer)
  field(:slug, :string)
  field(:name, :string)
end
