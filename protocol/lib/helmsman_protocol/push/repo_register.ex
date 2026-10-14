defmodule HelmsmanProtocol.Push.RepoRegister do
  @moduledoc """
  Push.RepoRegister (protocol 7): register `root`/`path` as `name` for `workspaces`.

  The daemon validates everything again; `path` is relative to the root label.
  """
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.RepoField
  field(:request_id, :string, min_bytes: 22, max_bytes: 64)
  field(:root, :string, min_bytes: 1, max_bytes: 1_024)
  field(:path, :string, min_bytes: 1, max_bytes: 1_024)
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  list(:workspaces, :pos_integer, min: 1, max: 50)

  @doc false
  def validate(value) do
    with {:ok, value} <-
           RepoField.check(
             value,
             [
               request_id: &RepoField.request_id?/1,
               root: &RepoField.root?/1,
               path: &RepoField.path?/1,
               name: &RepoField.name?/1
             ],
             []
           ),
         do: RepoField.unique_ids(value, :workspaces)
  end
end
