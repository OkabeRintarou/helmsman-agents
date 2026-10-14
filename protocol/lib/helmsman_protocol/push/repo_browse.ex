defmodule HelmsmanProtocol.Push.RepoBrowse do
  @moduledoc "Push.RepoBrowse (protocol 7): list repositories below the allowed roots."
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.RepoField
  field(:request_id, :string, min_bytes: 22, max_bytes: 64)

  @doc false
  def validate(value), do: RepoField.check(value, [request_id: &RepoField.request_id?/1], [])
end
