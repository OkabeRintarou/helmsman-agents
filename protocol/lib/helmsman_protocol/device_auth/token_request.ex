defmodule HelmsmanProtocol.DeviceAuth.TokenRequest do
  @moduledoc "TokenRequest device authorization payload."
  use HelmsmanProtocol.Schema
  field(:device_code, :string)
end
