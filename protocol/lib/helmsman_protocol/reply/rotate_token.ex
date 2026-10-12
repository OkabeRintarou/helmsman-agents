defmodule HelmsmanProtocol.Reply.RotateToken do
  @moduledoc "Reply.RotateToken protocol payload."
  use HelmsmanProtocol.Schema
  field(:token, :string)
  use HelmsmanProtocol.Redacted, [:token]
end
