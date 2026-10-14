defmodule HelmsmanProtocol.Report.RepoChangeResult do
  @moduledoc "Report.RepoChangeResult (protocol 7): the answer to `repo_register` / `repo_remove`."
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.{RepoField, RepoRequestError}
  field(:request_id, :string, min_bytes: 22, max_bytes: 64)
  field(:action, {:enum, [:register, :remove]})
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  field(:error, {:enum, RepoRequestError.all()}, nullable: true)
  field(:message, :string, nullable: true, max_bytes: 1_024)

  @doc false
  def validate(value),
    do:
      RepoField.check(
        value,
        [request_id: &RepoField.request_id?/1, name: &RepoField.name?/1],
        []
      )
end
