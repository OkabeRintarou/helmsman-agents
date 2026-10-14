defmodule HelmsmanProtocol.Report.Sync do
  @moduledoc "Report.Sync protocol payload; `local_repositories` exists from protocol 3, `repo_registration` from 7."
  use HelmsmanProtocol.Schema
  embeds(:machine, HelmsmanProtocol.Machine)
  list(:clis, HelmsmanProtocol.CLI)
  field(:max_concurrency, :pos_integer)
  list(:local_repositories, HelmsmanProtocol.LocalRepository, nullable: true, max: 256)
  field(:repo_registration, :boolean, nullable: true)
end
