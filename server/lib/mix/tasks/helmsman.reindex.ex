defmodule Mix.Tasks.Helmsman.Reindex do
  @shortdoc "Rebuilds the full-text search columns"

  @moduledoc """
  Rebuilds the search columns of every task and feedback record, or of
  one workspace's (`Helmsman.Search.Reindex`), and prints the counts.

      $ mix helmsman.reindex [--workspace acme]

  Run it once after deploying full-text search and after changing the
  tokenizer. It may run while the application serves requests and may be
  run again.
  """

  use Boundary, top_level?: true, deps: [Helmsman]

  use Mix.Task

  alias Helmsman.Search.Reindex

  @usage "usage: mix helmsman.reindex [--workspace <slug>]"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [workspace: :string]) do
      {opts, [], []} -> reindex(opts)
      _ -> fail(@usage)
    end
  end

  defp reindex(opts) do
    %{tasks: tasks, feedback: feedback, cleared: cleared, skipped: skipped} =
      Reindex.run(workspace: opts[:workspace])

    Mix.shell().info(
      "Reindexed tasks: #{tasks}, feedback: #{feedback}, cleared: #{cleared}, " <>
        "skipped (changed meanwhile): #{skipped}"
    )
  rescue
    error in ArgumentError -> fail(Exception.message(error))
  end

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
