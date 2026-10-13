defmodule HelmsmanDaemon.Adapters.TrackingFake do
  @moduledoc "The fake CLI adapter declaring descendant tracking (`add-cursor-adapter` decision 10)."
  alias HelmsmanDaemon.Adapters.Fake
  defdelegate init_state(spec), to: Fake
  defdelegate handle_output(stream, line, state), to: Fake
  defdelegate finish(status, state), to: Fake
  defdelegate interrupt(state), to: Fake
  defdelegate steer(ref, text, state), to: Fake
  defdelegate executable(), to: Fake
  defdelegate min_version(), to: Fake
  defdelegate detect(), to: Fake
  def provider, do: :cursor
  def track_descendants?, do: true

  def prepare(spec, run_dir, work_dir) do
    with {:ok, launch} <- Fake.prepare(spec, run_dir, work_dir),
         do: {:ok, %{launch | track_descendants: true}}
  end
end
