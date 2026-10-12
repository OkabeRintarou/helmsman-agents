defmodule HelmsmanProtocol.Reply.Claim do
  @moduledoc "Reply.Claim protocol payload."
  use HelmsmanProtocol.Schema
  list(:runs, HelmsmanProtocol.RunSpec)
end
