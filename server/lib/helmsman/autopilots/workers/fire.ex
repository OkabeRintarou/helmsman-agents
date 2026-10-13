defmodule Helmsman.Autopilots.Workers.Fire do
  @moduledoc """
  The scheduled trigger of an autopilot at `at` (`add-autopilots`
  decision 5): `Helmsman.Autopilots.Fire.request/2`. Unique by its
  arguments; a job for a time that is no longer the autopilot's next one
  does nothing.
  """

  use Oban.Worker,
    queue: :autopilots,
    max_attempts: 5,
    unique: [keys: [:autopilot_id, :at], period: :infinity]

  alias Helmsman.Autopilots.Fire

  @impl true
  def perform(%Oban.Job{args: %{"autopilot_id" => id, "at" => at}}) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)

    case Fire.request(id, {:schedule, at}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
