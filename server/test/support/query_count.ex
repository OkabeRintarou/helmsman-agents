defmodule Helmsman.QueryCount do
  @moduledoc "Counts the repo queries a function makes from the calling process."

  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "Runs `fun` and returns `{result, number of queries}`."
  def count(fun) do
    parent = self()
    ref = make_ref()
    handler = "query-count-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
