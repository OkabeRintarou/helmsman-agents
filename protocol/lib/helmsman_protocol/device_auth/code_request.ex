defmodule HelmsmanProtocol.DeviceAuth.CodeRequest do
  @moduledoc "CodeRequest device authorization payload."
  use HelmsmanProtocol.Schema
  field(:protocol, :pos_integer)
  embeds(:machine, HelmsmanProtocol.Machine)
end
