defmodule HelmsmanProtocol.Report.Pushed do
  @moduledoc "Report.Pushed protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:branch, :string)
  field(:base_sha, :string)
  field(:head_sha, :string)
  list(:commits, HelmsmanProtocol.Report.Pushed.Commit)
  field(:rescue_branch, :string, nullable: true)
end
