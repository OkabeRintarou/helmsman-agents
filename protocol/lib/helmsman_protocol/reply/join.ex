defmodule HelmsmanProtocol.Reply.Join do
  @moduledoc "Reply.Join protocol payload."
  use HelmsmanProtocol.Schema
  field(:daemon_id, :pos_integer)
  list(:runtimes, HelmsmanProtocol.Runtime)
  list(:terminate_run_ids, :pos_integer)
end
