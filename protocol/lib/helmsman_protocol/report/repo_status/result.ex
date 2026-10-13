defmodule HelmsmanProtocol.Report.RepoStatus.Result do
  @moduledoc "Report.RepoStatus.Result protocol payload."
  use HelmsmanProtocol.Schema
  field(:branch, :string, min_bytes: 1, max_bytes: 255)
  field(:head_sha, :string, min_bytes: 1, max_bytes: 64)
  field(:merged, {:enum, [:yes, :no, :unknown]})
end
