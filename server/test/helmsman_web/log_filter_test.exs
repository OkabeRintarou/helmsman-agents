defmodule HelmsmanWeb.LogFilterTest do
  # Credentials and agent environments never appear in request logs
  # (add-release-distribution decision 6). Raises the global log level.
  use HelmsmanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures

  defp capture_debug(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: level)
    end
  end

  test "sensitive parameter names are filtered, whatever their nesting" do
    params = %{
      "user" => %{"email" => "a@example.com", "password" => "pw-1"},
      "token" => "hm_value",
      "access_token" => "hmr_value",
      "authorization" => "Bearer x",
      "client_secret" => "cs",
      "api_key" => "k",
      "account" => %{"headers" => %{"X-Key" => "hv"}},
      "agent" => %{
        "env_add" => %{"1" => %{"name" => "OPENAI_API_KEY", "value" => "env-1"}},
        "env_new" => %{"ANTHROPIC_API_KEY" => "env-2"}
      }
    }

    filtered = inspect(Phoenix.Logger.filter_values(params))

    for value <- ~w(pw-1 hm_value hmr_value cs hv env-1 env-2) do
      refute filtered =~ value
    end

    refute filtered =~ "Bearer x"
    assert filtered =~ "a@example.com"
  end

  test "a login request's log has no password; a token in the query string is filtered",
       %{conn: conn} do
    user = set_password(user_fixture())

    log =
      capture_debug(fn ->
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

        get(build_conn(), "/users/log-in?token=hm_query-token-value-1234")
      end)

    assert log =~ "POST /users/log-in"
    refute log =~ valid_user_password()
    refute log =~ "query-token-value-1234"
  end
end
