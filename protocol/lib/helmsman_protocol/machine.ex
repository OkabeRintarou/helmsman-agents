defmodule HelmsmanProtocol.Machine do
  @moduledoc "Machine protocol payload."
  use HelmsmanProtocol.Schema
  field(:machine_id, :string)
  field(:name, :string)
  field(:os, :string)
  field(:arch, :string)
  field(:daemon_version, :string)
end
