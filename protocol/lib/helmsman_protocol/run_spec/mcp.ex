defmodule HelmsmanProtocol.RunSpec.MCP do
  @moduledoc "RunSpec.MCP protocol payload."
  use HelmsmanProtocol.Schema
  field(:url, :string)
  field(:token, :string)
  use HelmsmanProtocol.Redacted, [:token]
end
