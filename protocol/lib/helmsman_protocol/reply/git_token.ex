defmodule HelmsmanProtocol.Reply.GitToken do
  @moduledoc "Reply.GitToken protocol payload."
  use HelmsmanProtocol.Schema
  field(:token, :string)
  field(:expires_at, :datetime)
  use HelmsmanProtocol.Redacted, [:token]
end
