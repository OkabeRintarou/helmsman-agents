defmodule HelmsmanProtocol.Report.Join do
  @moduledoc "Report.Join protocol payload; `local_repositories` exists from protocol 3."
  use HelmsmanProtocol.Schema
  field(:protocol, :pos_integer)
  embeds(:machine, HelmsmanProtocol.Machine)
  list(:clis, HelmsmanProtocol.CLI)
  field(:max_concurrency, :pos_integer)
  list(:active_runs, HelmsmanProtocol.ActiveRun)
  list(:local_repositories, HelmsmanProtocol.LocalRepository, nullable: true, max: 256)
end
