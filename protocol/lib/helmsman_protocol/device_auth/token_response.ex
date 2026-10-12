defmodule HelmsmanProtocol.DeviceAuth.TokenResponse do
  @moduledoc "TokenResponse device authorization payload."
  use HelmsmanProtocol.Schema
  field(:token, :string)
  field(:daemon_id, :pos_integer)
  list(:workspaces, HelmsmanProtocol.DeviceAuth.Workspace)
  use HelmsmanProtocol.Redacted, [:token]
  def validate(%{token: "hmd_" <> suffix} = value) when byte_size(suffix) > 0, do: {:ok, value}
  def validate(_), do: HelmsmanProtocol.Schema.invalid(["token"], :type)
end
