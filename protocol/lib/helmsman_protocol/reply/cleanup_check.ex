defmodule HelmsmanProtocol.Reply.CleanupCheck do
  @moduledoc "Cleanup decision for each requested worktree."
  use HelmsmanProtocol.Schema
  list(:results, HelmsmanProtocol.CleanupResult, min: 1, max: 500)
end
