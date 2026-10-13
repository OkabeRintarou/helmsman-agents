defmodule HelmsmanProtocol.Report.Sync do
  @moduledoc "Report.Sync protocol payload; `local_repositories` exists from protocol 3."
  use HelmsmanProtocol.Schema
  embeds(:machine, HelmsmanProtocol.Machine)
  list(:clis, HelmsmanProtocol.CLI)
  field(:max_concurrency, :pos_integer)
  list(:local_repositories, HelmsmanProtocol.LocalRepository, nullable: true, max: 256)
end
