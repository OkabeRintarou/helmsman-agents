defmodule Helmsman.Backup.Import.Merge do
  @moduledoc "Pure audit-prefix classification; supersession only advances."
  @event_fields ~w(from to actor comment commits tests auto auto_reason feedback verified_sha at)
  @feedback_fields ~w(author kind content thread supersedes at)

  def classify(local, incoming, local_events, events, local_feedback, feedback) do
    e = prefix(local_events, events, @event_fields)
    f = prefix(local_feedback, feedback, @feedback_fields)

    if local["kind"] != incoming["kind"] do
      {:error, :kind}
    else
      classify_prefixes(e, f, local, incoming, local_feedback, feedback)
    end
  end

  defp classify_prefixes({:different, n}, _f, _local, _incoming, _lf, _feedback),
    do: {:error, {:event, n}}

  defp classify_prefixes(_e, {:different, n}, _local, _incoming, _lf, _feedback),
    do: {:error, {:feedback, n}}

  defp classify_prefixes(e, f, local, incoming, local_feedback, feedback) do
    case {e, f} do
      {:shorter, :longer} -> {:error, :crossed_prefixes}
      {:longer, :shorter} -> {:error, :crossed_prefixes}
      {:longer, _} -> :local_newer
      {_, :longer} -> :local_newer
      {:shorter, _} -> :fast_forwarded
      {_, :shorter} -> :fast_forwarded
      _ -> classify_fields(local, incoming, local_feedback, feedback)
    end
  end

  defp classify_fields(local, incoming, local_feedback, feedback) do
    if incoming["updated_at"] > local["updated_at"] or advances?(local_feedback, feedback),
      do: :fast_forwarded,
      else: :unchanged
  end

  defp prefix(local, incoming, fields) do
    different =
      Enum.zip(local, incoming)
      |> Enum.with_index(1)
      |> Enum.find(fn {{a, b}, _} -> Map.take(a, fields) != Map.take(b, fields) end)

    cond do
      different -> {:different, elem(different, 1)}
      length(local) < length(incoming) -> :shorter
      length(local) > length(incoming) -> :longer
      true -> :same
    end
  end

  defp advances?(local, incoming),
    do:
      Enum.zip(local, incoming)
      |> Enum.any?(fn {a, b} -> a["status"] == "active" and b["status"] == "superseded" end)
end
