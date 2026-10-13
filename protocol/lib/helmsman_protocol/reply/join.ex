defmodule HelmsmanProtocol.Reply.Join do
  @moduledoc "Reply.Join protocol payload; `local_repositories` exists from protocol 3."
  use HelmsmanProtocol.Schema
  field(:daemon_id, :pos_integer)
  list(:runtimes, HelmsmanProtocol.Runtime)
  list(:terminate_run_ids, :pos_integer)
  list(:local_repositories, HelmsmanProtocol.Reply.Join.LocalRepository, nullable: true)
end
