defmodule Mix.Tasks.Helmsman.Export do
  @shortdoc "Exports a workspace snapshot to gzip JSON"
  @moduledoc "mix helmsman.export --workspace SLUG [--out PATH]"
  use Boundary, top_level?: true, deps: [Helmsman]
  use Mix.Task
  alias Helmsman.{Backup, Workspaces}
  @requirements ["app.start"]
  @impl Mix.Task
  def run(args) do
    with {opts, [], []} <- OptionParser.parse(args, strict: [workspace: :string, out: :string]),
         slug when is_binary(slug) <- opts[:workspace],
         %Helmsman.Workspaces.Workspace{} = workspace <- Workspaces.get_by_slug(slug),
         path <- opts[:out] || "#{slug}.helmsman.json.gz",
         {:ok, stats} <- Backup.export_to_file(workspace, path) do
      Mix.shell().info(Jason.encode!(Map.put(stats, :file, path)))
    else
      _ ->
        Mix.shell().error(
          "export failed; usage: mix helmsman.export --workspace SLUG [--out PATH]"
        )

        exit({:shutdown, 1})
    end
  end
end
