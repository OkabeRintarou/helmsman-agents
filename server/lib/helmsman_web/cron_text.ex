defmodule HelmsmanWeb.CronText do
  @moduledoc """
  Plain-language description of an autopilot's cron (add-squads-autopilots-ui D9).

  Covers the common standard 5-field forms — every N minutes, minute M of every hour,
  every day, every weekday (`1-5`), some days of the week, and day D of every month —
  and falls back to `cron <expression>` for anything else. The time zone is appended
  in full-width parentheses. Display only: validity and the next times come from the
  domain's `preview/3`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  @doc """
  Describes `cron` in `timezone`.

      iex> HelmsmanWeb.CronText.describe("0 9 * * 1-5", "Asia/Shanghai")
      "每个工作日 09:00（Asia/Shanghai）"
  """
  @spec describe(String.t(), String.t() | nil) :: String.t()
  def describe(cron, timezone) when is_binary(cron) do
    text =
      case cron |> String.trim() |> String.split(~r/\s+/) do
        [_, _, _, _, _] = fields -> fields |> phrase() |> Kernel.||(fallback(cron))
        _ -> fallback(cron)
      end

    text <> zone(timezone)
  end

  defp fallback(cron), do: dgettext("ui", "cron %{expr}", expr: String.trim(cron))

  defp zone(tz) when is_binary(tz) and tz != "", do: dgettext("ui", "（%{tz}）", tz: tz)
  defp zone(_tz), do: ""

  defp phrase(["*/" <> step, "*", "*", "*", "*"]) do
    with {:ok, n} <- int(step, 1, 59), do: dgettext("ui", "每 %{n} 分钟", n: n)
  end

  defp phrase([minute, "*", "*", "*", "*"]) do
    with {:ok, m} <- int(minute, 0, 59), do: dgettext("ui", "每小时第 %{m} 分", m: m)
  end

  defp phrase([minute, hour, dom, "*", dow]) do
    with {:ok, m} <- int(minute, 0, 59),
         {:ok, h} <- int(hour, 0, 23) do
      day_phrase(dom, dow, clock(h, m))
    end
  end

  defp phrase(_fields), do: nil

  defp day_phrase("*", "*", time), do: dgettext("ui", "每天 %{time}", time: time)
  defp day_phrase("*", "1-5", time), do: dgettext("ui", "每个工作日 %{time}", time: time)

  defp day_phrase("*", dow, time) do
    with {:ok, days} <- weekdays(dow) do
      dgettext("ui", "每%{days} %{time}",
        days: Enum.map_join(days, "、", &weekday_name/1),
        time: time
      )
    end
  end

  defp day_phrase(dom, "*", time) do
    with {:ok, d} <- int(dom, 1, 31),
         do: dgettext("ui", "每月 %{d} 日 %{time}", d: d, time: time)
  end

  defp day_phrase(_dom, _dow, _time), do: nil

  # A comma-separated list of single days 0–7 (0 and 7 are Sunday), Monday first.
  defp weekdays(dow) do
    dow
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case int(part, 0, 7) do
        {:ok, 7} -> {:cont, {:ok, [0 | acc]}}
        {:ok, d} -> {:cont, {:ok, [d | acc]}}
        nil -> {:halt, nil}
      end
    end)
    |> case do
      {:ok, days} -> {:ok, days |> Enum.uniq() |> Enum.sort_by(&rem(&1 + 6, 7))}
      nil -> nil
    end
  end

  @doc "「周一」…「周日」 for a cron weekday 0–7."
  def weekday_name(d) when d in [0, 7], do: dgettext("ui", "周日")
  def weekday_name(1), do: dgettext("ui", "周一")
  def weekday_name(2), do: dgettext("ui", "周二")
  def weekday_name(3), do: dgettext("ui", "周三")
  def weekday_name(4), do: dgettext("ui", "周四")
  def weekday_name(5), do: dgettext("ui", "周五")
  def weekday_name(6), do: dgettext("ui", "周六")

  defp clock(h, m), do: pad(h) <> ":" <> pad(m)
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp int(text, min, max) do
    case Integer.parse(text) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> nil
    end
  end
end
