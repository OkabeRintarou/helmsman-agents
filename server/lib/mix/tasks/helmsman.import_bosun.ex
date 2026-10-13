defmodule Mix.Tasks.Helmsman.ImportBosun do
  @shortdoc "Imports a bosun v2 snapshot"
  @moduledoc "Same options as mix helmsman.import; source is bosun v2."
  use Boundary, top_level?: true, deps: [Helmsman, Mix.Tasks.Helmsman.Import]
  use Mix.Task
  alias Mix.Tasks.Helmsman.Import
  @requirements ["app.start"]
  @impl Mix.Task
  def run(args), do: Import.execute(args, :bosun)
end
