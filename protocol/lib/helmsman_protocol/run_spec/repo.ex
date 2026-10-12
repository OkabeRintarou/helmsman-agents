defmodule HelmsmanProtocol.RunSpec.Repo do
  @moduledoc "RunSpec.Repo protocol payload."
  use HelmsmanProtocol.Schema
  field(:clone_url, :string, min_bytes: 1)
  field(:base_branch, :string, min_bytes: 1)
  field(:branch, :string, min_bytes: 1)
  list(:rescue_branches, :string)
  field(:git_token, :string, min_bytes: 1)
  field(:git_token_expires_at, :datetime)
  use HelmsmanProtocol.Redacted, [:git_token]
end
