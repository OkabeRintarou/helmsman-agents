defmodule HelmsmanWeb.CronTextTest do
  @moduledoc "add-squads-autopilots-ui D9: the plain-language cron description."
  use ExUnit.Case, async: true

  alias HelmsmanWeb.CronText

  doctest CronText

  @cases [
    {"*/15 * * * *", "UTC", "每 15 分钟（UTC）"},
    {"5 * * * *", "UTC", "每小时第 5 分（UTC）"},
    {"0 9 * * *", "Asia/Shanghai", "每天 09:00（Asia/Shanghai）"},
    {"0 9 * * 1-5", "Asia/Shanghai", "每个工作日 09:00（Asia/Shanghai）"},
    {"30 18 * * 1,3,5", "UTC", "每周一、周三、周五 18:30（UTC）"},
    {"0 10 * * 0,6", "UTC", "每周六、周日 10:00（UTC）"},
    {"0 10 * * 7", "UTC", "每周日 10:00（UTC）"},
    {"0 3 1 * *", "Europe/Berlin", "每月 1 日 03:00（Europe/Berlin）"},
    {"  0  9 * * *  ", "UTC", "每天 09:00（UTC）"},
    # Fallbacks: the expression itself.
    {"0 9 1-7 * 1", "UTC", "cron 0 9 1-7 * 1（UTC）"},
    {"@daily", "UTC", "cron @daily（UTC）"},
    {"not a cron", "Asia/Shanghai", "cron not a cron（Asia/Shanghai）"},
    {"61 9 * * *", "UTC", "cron 61 9 * * *（UTC）"},
    {"0 9 * * 1-3", "UTC", "cron 0 9 * * 1-3（UTC）"},
    {"0 9 * 1 *", "UTC", "cron 0 9 * 1 *（UTC）"},
    {"0 0 9 * * *", "UTC", "cron 0 0 9 * * *（UTC）"}
  ]

  for {cron, tz, expected} <- @cases do
    test "#{inspect(cron)} in #{tz}" do
      assert CronText.describe(unquote(cron), unquote(tz)) == unquote(expected)
    end
  end

  test "every description ends with the time zone" do
    for {cron, tz, _} <- @cases do
      assert String.ends_with?(CronText.describe(cron, tz), "（#{tz}）")
    end
  end
end
