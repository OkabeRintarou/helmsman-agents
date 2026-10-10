defmodule Helmsman.RateLimitHelpers do
  @moduledoc """
  Test helpers for the authentication rate limits.

  The test configuration effectively disables the limits; these helpers
  restore the production thresholds for one test (use only in
  `async: false` modules) and hand out unique client IPs so ETS counters
  never leak between tests.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Callbacks, only: [on_exit: 1]

  @production_limits [
    magic_link_ip: {5, :timer.minutes(1)},
    magic_link_email: {3, :timer.minutes(10)},
    password_ip: {10, :timer.minutes(1)},
    register_ip: {10, :timer.hours(1)}
  ]

  @doc """
  Applies the production limits, with `overrides`, until the test exits.
  """
  def put_rate_limits(overrides \\ []) do
    previous = Application.fetch_env!(:helmsman, Helmsman.RateLimit)

    Application.put_env(
      :helmsman,
      Helmsman.RateLimit,
      Keyword.merge(@production_limits, overrides)
    )

    on_exit(fn -> Application.put_env(:helmsman, Helmsman.RateLimit, previous) end)
  end

  @doc """
  Returns an IPv4 address not used by any other test in this run.
  """
  def unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
