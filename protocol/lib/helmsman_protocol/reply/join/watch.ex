defmodule HelmsmanProtocol.Reply.Join.Watch do
  @moduledoc "Local task branch whose merge state the daemon checks."
  use HelmsmanProtocol.Schema
  field(:branch, :string, min_bytes: 1, max_bytes: 255)
  field(:head_sha, :string, min_bytes: 1, max_bytes: 64)
  field(:base_branch, :string, min_bytes: 1, max_bytes: 255)
end
