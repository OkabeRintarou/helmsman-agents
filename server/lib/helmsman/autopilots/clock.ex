defmodule Helmsman.Autopilots.Clock do
  @moduledoc """
  The time autopilots see (`add-autopilots` decision 16). In the test
  environment a process (and the processes it starts) may set its own with
  `put/1`; elsewhere it is the system clock.
  """

  @key {__MODULE__, :now}

  @doc "The current time (UTC, microseconds)."
  @spec now() :: DateTime.t()
  if Mix.env() == :test do
    def now do
      case Process.get(@key) || inherited() do
        %DateTime{} = at -> at
        nil -> DateTime.utc_now()
      end
    end

    defp inherited do
      Enum.find_value(Process.get(:"$callers", []), fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> List.keyfind(dict, @key, 0) |> then(&(&1 && elem(&1, 1)))
          nil -> nil
        end
      end)
    end

    @doc "Sets the time of the calling process (tests only); nil clears it."
    @spec put(DateTime.t() | nil) :: :ok
    def put(nil) do
      Process.delete(@key)
      :ok
    end

    def put(%DateTime{microsecond: {us, _}} = at) do
      Process.put(@key, %{at | microsecond: {us, 6}})
      :ok
    end
  else
    def now, do: DateTime.utc_now()
  end
end
