defmodule HelmsmanMCP.Tools.CancelRun do
  @moduledoc """
  `cancel_run`: stops a run (designs/13 §8, `add-run-lifecycle` decision
  21). A queued run is cancelled at once; a running one is stopped by its
  daemon. Run tokens may not stop runs.
  """

  use HelmsmanMCP.Tool,
    name: "cancel_run",
    description:
      "Stop a run (see list_runs): a queued run is cancelled at once, a running one is " <>
        "interrupted (status CANCELLING until its machine confirms).",
    schema: %{run_id: {:required, :integer, description: "Run ID (from list_runs)."}},
    mode: :write

  alias Helmsman.Runs
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"run_id" => id}, %{scope: scope}) do
    with {:ok, run} <- Runs.cancel(scope, id), do: {:ok, %{run: Present.run(run)}}
  end
end
