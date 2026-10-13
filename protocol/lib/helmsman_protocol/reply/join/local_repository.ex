defmodule HelmsmanProtocol.Reply.Join.LocalRepository do
  @moduledoc "Registered local repository and its merge watch list in a join / sync reply."
  use HelmsmanProtocol.Schema
  field(:workspace_id, :pos_integer)
  field(:name, :string, min_bytes: 1, max_bytes: 255)
  field(:local_repository_id, :pos_integer)
  list(:watch, HelmsmanProtocol.Reply.Join.Watch, max: 500)
end
