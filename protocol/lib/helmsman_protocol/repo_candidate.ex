defmodule HelmsmanProtocol.RepoCandidate do
  @moduledoc """
  One repository found by `repo_browse` (protocol 7): root label, relative path,
  suggested name and the configured name of the same repository. Nothing else.
  """
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.RepoField

  field(:root, :string, min_bytes: 1, max_bytes: 1_024)
  field(:path, :string, min_bytes: 1, max_bytes: 1_024)
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  field(:registered_as, :string, nullable: true, min_bytes: 1, max_bytes: 64)

  @doc false
  def validate(value) do
    RepoField.check(
      value,
      [
        root: &RepoField.root?/1,
        path: &RepoField.path?/1,
        name: &RepoField.name?/1,
        registered_as: &(is_nil(&1) or RepoField.name?(&1))
      ],
      []
    )
  end
end
