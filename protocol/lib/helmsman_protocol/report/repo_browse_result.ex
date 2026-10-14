defmodule HelmsmanProtocol.Report.RepoBrowseResult do
  @moduledoc """
  Report.RepoBrowseResult (protocol 7): the answer to `repo_browse`.

  `roots` are the labels of all valid roots; every repository's `root` must be
  one of them. With an `error`, `repositories` must be empty.
  """
  use HelmsmanProtocol.Schema
  alias HelmsmanProtocol.{RepoField, RepoRequestError, Schema}
  field(:request_id, :string, min_bytes: 22, max_bytes: 64)
  field(:error, {:enum, RepoRequestError.all()}, nullable: true)
  field(:message, :string, nullable: true, max_bytes: 1_024)
  list(:roots, :string, max: 16, item_min_bytes: 1, item_max_bytes: 1_024)
  list(:repositories, HelmsmanProtocol.RepoCandidate, max: 200)
  field(:truncated, :boolean)

  @doc false
  def validate(value) do
    with {:ok, value} <-
           RepoField.check(value, [request_id: &RepoField.request_id?/1], []),
         :ok <- roots(value.roots),
         :ok <- listed(value.repositories, value.roots) do
      if value.error && value.repositories != [],
        do: Schema.invalid(["repositories"], :not_allowed),
        else: {:ok, value}
    end
  end

  defp roots(roots) do
    case Enum.find_index(roots, &(not RepoField.root?(&1))) do
      nil -> :ok
      index -> Schema.invalid(["roots", index], :type)
    end
  end

  defp listed(repositories, roots) do
    case Enum.find_index(repositories, &(&1.root not in roots)) do
      nil -> :ok
      index -> Schema.invalid(["repositories", index, "root"], :not_allowed)
    end
  end
end
