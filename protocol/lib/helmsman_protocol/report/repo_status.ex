defmodule HelmsmanProtocol.Report.RepoStatus do
  @moduledoc "Report.RepoStatus protocol payload (protocol 3): merge checks of local branches."
  use HelmsmanProtocol.Schema
  field(:workspace_id, :pos_integer)
  field(:name, :string, min_bytes: 1, max_bytes: 255)
  list(:results, HelmsmanProtocol.Report.RepoStatus.Result, max: 500)
end
