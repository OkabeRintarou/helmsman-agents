defmodule HelmsmanWeb.Throttle do
  @moduledoc """
  Coalesces reloads (add-agents-runs-ui D4): the first notification schedules `message`
  after the delay, the ones arriving meanwhile are dropped. The page clears the timer
  with `done/2` when it handles `message`.

  The delay is `config :helmsman, HelmsmanWeb.Throttle, delay_ms: …` (default 500).
  """
  import Phoenix.Component, only: [assign: 3]

  @doc "Schedules `message` unless it is already scheduled."
  def schedule(socket, message \\ :reload) do
    timers = socket.assigns[:throttle_timers] || %{}

    if Map.has_key?(timers, message) do
      socket
    else
      ref = Process.send_after(self(), message, delay())
      assign(socket, :throttle_timers, Map.put(timers, message, ref))
    end
  end

  @doc "Marks `message` as handled: the next notification schedules it again."
  def done(socket, message \\ :reload),
    do:
      assign(
        socket,
        :throttle_timers,
        Map.delete(socket.assigns[:throttle_timers] || %{}, message)
      )

  defp delay, do: Application.get_env(:helmsman, __MODULE__, [])[:delay_ms] || 500
end
