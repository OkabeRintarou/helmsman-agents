defmodule HelmsmanProtocol.DeviceAuth.CodeResponse do
  @moduledoc "CodeResponse device authorization payload."
  use HelmsmanProtocol.Schema
  field(:device_code, :string)
  field(:user_code, :string)
  field(:verification_uri, :string)
  field(:verification_uri_complete, :string)
  field(:expires_in, :pos_integer)
  field(:interval, :pos_integer)

  def validate(value) do
    if HelmsmanProtocol.DeviceAuth.valid_user_code?(value.user_code),
      do: {:ok, value},
      else: HelmsmanProtocol.Schema.invalid(["user_code"], :type)
  end
end
