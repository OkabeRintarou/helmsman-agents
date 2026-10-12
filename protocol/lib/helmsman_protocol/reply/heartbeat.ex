defmodule HelmsmanProtocol.Reply.Heartbeat do
  @moduledoc "Reply.Heartbeat protocol payload."
  use HelmsmanProtocol.Schema
  list(:terminate_run_ids, :pos_integer)
end
