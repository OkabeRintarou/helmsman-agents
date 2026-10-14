defmodule HelmsmanProtocol.Push.RepoRemove do
  @moduledoc "Push.RepoRemove (protocol 7): remove the configured repository `name`."
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.RepoField
  field(:request_id, :string, min_bytes: 22, max_bytes: 64)
  field(:name, :string, min_bytes: 1, max_bytes: 64)

  @doc false
  def validate(value),
    do:
      RepoField.check(
        value,
        [request_id: &RepoField.request_id?/1, name: &RepoField.name?/1],
        []
      )
end
