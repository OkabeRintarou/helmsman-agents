defmodule HelmsmanProtocol.RunSpec.Task do
  @moduledoc "RunSpec.Task protocol payload."
  use HelmsmanProtocol.Schema
  field(:ident, :string)
  field(:title, :string)
end
