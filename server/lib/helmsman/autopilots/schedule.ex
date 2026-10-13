defmodule Helmsman.Autopilots.Schedule do
  @moduledoc """
  Cron schedules of autopilots (`add-autopilots` decision 5). Pure.

  A schedule is a standard five-field cron expression (no seconds field,
  no `@reboot` or other `@` shortcuts) in an IANA time zone. The next time
  after a moment is the first local time the expression matches strictly
  after it: a local time skipped by a daylight saving change gives the
  first instant after the change; a local time that occurs twice gives
  only the earlier instant.
  """

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @tzdb Tz.TimeZoneDatabase
  @min_gap_seconds 5 * 60
  @frequency_window 100
  # Local times that resolve to an instant not after the base (the
  # repeated hour of a fall-back day) are skipped; this bounds the loop.
  @max_steps 200

  @type error :: {:cron | :timezone, String.t()}

  @doc """
  Parses a five-field cron expression. Returns `{:error, message}` for
  anything else.
  """
  @spec parse(String.t()) :: {:ok, CronExpression.t()} | {:error, String.t()}
  def parse(cron) when is_binary(cron) do
    fields = String.split(cron)

    cond do
      String.starts_with?(String.trim(cron), "@") ->
        {:error, "must be a five-field cron expression"}

      length(fields) != 5 ->
        {:error, "must be a five-field cron expression"}

      true ->
        case Parser.parse(Enum.join(fields, " "), false) do
          {:ok, %CronExpression{reboot: false} = expr} -> {:ok, expr}
          _ -> {:error, "is not a valid cron expression"}
        end
    end
  end

  def parse(_cron), do: {:error, "is invalid"}

  @doc "Whether `timezone` is an IANA time zone name."
  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?(timezone) when is_binary(timezone) and timezone != "" do
    match?({:ok, _}, DateTime.shift_zone(~U[2000-01-01 00:00:00Z], timezone, @tzdb))
  end

  def valid_timezone?(_timezone), do: false

  @doc """
  Checks `cron` in `timezone` from `from` (decision 5): the expression and
  the zone are valid and, of the next #{@frequency_window} times, no two in
  a row are less than five minutes apart (`too_frequent`). Returns the
  parsed expression, or every error.
  """
  @spec validate(String.t(), String.t(), DateTime.t()) ::
          {:ok, CronExpression.t()} | {:error, [error()]}
  def validate(cron, timezone, %DateTime{} = from) do
    tz_errors =
      if valid_timezone?(timezone), do: [], else: [{:timezone, "is not a valid time zone"}]

    case {parse(cron), tz_errors} do
      {{:error, message}, _} -> {:error, [{:cron, message} | tz_errors]}
      {{:ok, expr}, []} -> frequency(expr, timezone, from)
      # The frequency is still checked, in UTC.
      {{:ok, expr}, _} -> {:error, cron_errors(frequency(expr, "Etc/UTC", from)) ++ tz_errors}
    end
  end

  defp frequency(expr, timezone, from) do
    case times(expr, timezone, from, @frequency_window) do
      [] -> {:error, [{:cron, "never matches"}]}
      times -> if too_frequent?(times), do: {:error, [{:cron, "too_frequent"}]}, else: {:ok, expr}
    end
  end

  defp cron_errors({:ok, _expr}), do: []
  defp cron_errors({:error, errors}), do: errors

  defp too_frequent?(times) do
    times
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> DateTime.diff(b, a) < @min_gap_seconds end)
  end

  @doc """
  The next 5 (or `count`) times of `cron` in `timezone` after `from`,
  or the field errors of `validate/3`.
  """
  @spec preview(String.t(), String.t(), pos_integer(), DateTime.t()) ::
          {:ok, [DateTime.t()]} | {:error, [error()]}
  def preview(cron, timezone, count \\ 5, %DateTime{} = from) do
    with {:ok, expr} <- validate(cron, timezone, from),
         do: {:ok, times(expr, timezone, from, count)}
  end

  @doc """
  The first time of `expr` (a parsed expression or a string) in
  `timezone` strictly after `after`, in UTC; nil when it never matches.
  """
  @spec next_after(CronExpression.t() | String.t(), String.t(), DateTime.t()) ::
          DateTime.t() | nil
  def next_after(cron, timezone, base) when is_binary(cron) do
    case parse(cron) do
      {:ok, expr} -> next_after(expr, timezone, base)
      {:error, _} -> nil
    end
  end

  def next_after(%CronExpression{} = expr, timezone, %DateTime{} = base) do
    {:ok, local} = DateTime.shift_zone(base, timezone, @tzdb)

    start =
      local
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> NaiveDateTime.add(60)

    find_next(expr, timezone, base, start, @max_steps)
  end

  defp find_next(_expr, _tz, _after, _from, 0), do: nil

  defp find_next(expr, tz, base, from, steps) do
    case Scheduler.get_next_run_date(expr, from) do
      {:ok, naive} -> accept_or_next(expr, tz, base, naive, steps)
      {:error, _} -> nil
    end
  end

  defp accept_or_next(expr, tz, base, naive, steps) do
    with {:ok, at} <- resolve(naive, tz),
         :gt <- DateTime.compare(at, base) do
      to_utc(at)
    else
      _not_after -> find_next(expr, tz, base, NaiveDateTime.add(naive, 60), steps - 1)
    end
  end

  # A local time skipped by a daylight saving change → the first instant
  # after the change; one that occurs twice → the earlier.
  defp resolve(naive, tz) do
    case DateTime.from_naive(naive, tz, @tzdb) do
      {:ok, at} -> {:ok, at}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, just_after} -> {:ok, just_after}
      {:error, _} -> :skip
    end
  end

  defp to_utc(%DateTime{} = at) do
    at
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  end

  defp times(expr, timezone, from, count) do
    Enum.reduce_while(1..count, {[], from}, fn _i, {acc, base} ->
      case next_after(expr, timezone, base) do
        nil -> {:halt, {acc, base}}
        at -> {:cont, {[at | acc], at}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
