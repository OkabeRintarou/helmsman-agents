defmodule Mix.Tasks.Helmsman do
  @moduledoc "Run the Helmsman daemon CLI."
  use Mix.Task
  @shortdoc "Run the Helmsman daemon CLI"
  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    HelmsmanDaemon.CLI.main(args)
  end
end
