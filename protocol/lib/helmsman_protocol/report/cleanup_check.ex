defmodule HelmsmanProtocol.Report.CleanupCheck do
  @moduledoc "Batch of daemon-owned task worktrees to check."
  use HelmsmanProtocol.Schema
  list(:items, HelmsmanProtocol.CleanupItem, min: 1, max: 500)
end
