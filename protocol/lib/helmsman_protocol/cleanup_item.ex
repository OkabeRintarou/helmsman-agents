defmodule HelmsmanProtocol.CleanupItem do
  @moduledoc "Task identity in a worktree cleanup request."
  use HelmsmanProtocol.Schema
  field(:workspace_id, :pos_integer)
  field(:ident, :string, min_bytes: 1)
end
