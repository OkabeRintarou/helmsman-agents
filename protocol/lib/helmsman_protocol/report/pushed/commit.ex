defmodule HelmsmanProtocol.Report.Pushed.Commit do
  @moduledoc "Report.Pushed.Commit protocol payload."
  use HelmsmanProtocol.Schema
  field(:sha, :string)
  field(:subject, :string)
end
