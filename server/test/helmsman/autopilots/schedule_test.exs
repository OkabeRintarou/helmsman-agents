defmodule Helmsman.Autopilots.ScheduleTest do
  # add-autopilots 2.1: cron parsing, validation and the next time (pure).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helmsman.Autopilots.Schedule

  @from ~U[2026-10-13 12:00:00Z]

  defp next(cron, tz, at), do: Schedule.next_after(cron, tz, at)

  test "too frequent: */2 is refused, every 5 minutes is fine" do
    assert Schedule.validate("*/2 * * * *", "UTC", @from) == {:error, [{:cron, "too_frequent"}]}
    assert {:ok, _} = Schedule.validate("*/5 * * * *", "UTC", @from)
    assert Schedule.validate("0,1 9 * * *", "UTC", @from) == {:error, [{:cron, "too_frequent"}]}
  end

  test "@reboot, shortcuts, six fields and unknown zones are refused" do
    assert {:error, [{:cron, _}]} = Schedule.validate("@reboot", "UTC", @from)
    assert {:error, [{:cron, _}]} = Schedule.validate("@daily", "UTC", @from)
    assert {:error, [{:cron, _}]} = Schedule.validate("0 0 9 * * *", "UTC", @from)
    assert {:error, [{:cron, _}]} = Schedule.validate("61 * * * *", "UTC", @from)

    assert Schedule.validate("0 9 * * *", "Mars/Olympus", @from) ==
             {:error, [{:timezone, "is not a valid time zone"}]}

    assert {:error, [{:cron, _}, {:timezone, _}]} =
             Schedule.validate("nope", "Mars/Olympus", @from)
  end

  test "a skipped local time gives the first instant after the change, once that day" do
    # 2027-03-14: 02:00-03:00 does not exist in New York.
    at = next("30 2 * * *", "America/New_York", ~U[2027-03-14 05:00:00Z])
    assert at == ~U[2027-03-14 07:00:00.000000Z]
    {:ok, local} = DateTime.shift_zone(at, "America/New_York")
    assert {local.hour, local.minute} == {3, 0}
    # The next one is the next day at 02:30 EDT.
    assert next("30 2 * * *", "America/New_York", at) == ~U[2027-03-15 06:30:00.000000Z]
  end

  test "a repeated local time fires once, at the earlier instant" do
    # 2027-11-07: 01:00-02:00 happens twice in New York.
    first = next("30 1 * * *", "America/New_York", ~U[2027-11-07 04:00:00Z])
    assert first == ~U[2027-11-07 05:30:00.000000Z]
    assert next("30 1 * * *", "America/New_York", first) == ~U[2027-11-08 06:30:00.000000Z]
    # From inside the second 01:xx, the second 01:30 is not a time.
    assert next("30 1 * * *", "America/New_York", ~U[2027-11-07 06:10:00Z]) ==
             ~U[2027-11-08 06:30:00.000000Z]
  end

  test "weekdays at 09:00 in Shanghai are 01:00Z on the next five working days" do
    {:ok, times} = Schedule.preview("0 9 * * 1-5", "Asia/Shanghai", 5, ~U[2026-10-16 02:00:00Z])

    assert times == [
             ~U[2026-10-19 01:00:00.000000Z],
             ~U[2026-10-20 01:00:00.000000Z],
             ~U[2026-10-21 01:00:00.000000Z],
             ~U[2026-10-22 01:00:00.000000Z],
             ~U[2026-10-23 01:00:00.000000Z]
           ]

    assert Enum.all?(times, &(Date.day_of_week(DateTime.to_date(&1)) in 1..5))
  end

  test "the next time is strictly after the base, even on a matching minute" do
    assert next("0 9 * * *", "UTC", ~U[2026-10-13 09:00:00Z]) == ~U[2026-10-14 09:00:00.000000Z]
    assert next("0 9 * * *", "UTC", ~U[2026-10-13 08:59:59Z]) == ~U[2026-10-13 09:00:00.000000Z]
  end

  @zones ["UTC", "America/New_York", "Europe/London", "Asia/Shanghai", "Australia/Lord_Howe"]

  property "next_after/3 is strictly later and monotonic" do
    check all minute <- member_of(["*/5", "0", "30", "15,45", "*/10"]),
              hour <- member_of(["*", "1", "2", "9", "*/3"]),
              dow <- member_of(["*", "1-5", "0"]),
              zone <- member_of(@zones),
              offset <- integer(0..(400 * 86_400)),
              step <- integer(0..(3 * 86_400)),
              max_runs: 200 do
      cron = "#{minute} #{hour} * * #{dow}"
      {:ok, expr} = Schedule.parse(cron)
      t1 = DateTime.add(~U[2027-01-01 00:00:00Z], offset)
      t2 = DateTime.add(t1, step)
      n1 = Schedule.next_after(expr, zone, t1)
      n2 = Schedule.next_after(expr, zone, t2)
      assert DateTime.compare(n1, t1) == :gt
      assert DateTime.compare(n2, t2) == :gt
      assert DateTime.compare(n1, n2) in [:lt, :eq]
    end
  end
end
