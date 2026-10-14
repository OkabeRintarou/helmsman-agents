defmodule HelmsmanWeb.SessionCookieTest do
  # The Secure flag follows the public URL's scheme at runtime
  # (`config :helmsman, :secure_cookies`, from PHX_URL_SCHEME).
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.RuntimeConfigHelpers

  setup do
    previous = Application.get_env(:helmsman, :secure_cookies)
    on_exit(fn -> Application.put_env(:helmsman, :secure_cookies, previous) end)
  end

  defp cookie(conn, name) do
    [cookie] =
      conn |> get_resp_header("set-cookie") |> Enum.filter(&String.starts_with?(&1, name <> "="))

    cookie
  end

  defp log_in(conn) do
    user = set_password(user_fixture())

    post(conn, ~p"/users/log-in", %{
      "user" => %{
        "email" => user.email,
        "password" => valid_user_password(),
        "remember_me" => "true"
      }
    })
  end

  for {scheme, secure?} <- [{"https", true}, {"http", false}] do
    test "PHX_URL_SCHEME=#{scheme}: session and remember-me cookies #{if secure?, do: "are", else: "are not"} Secure",
         %{conn: conn} do
      config = read_prod_runtime(prod_env(%{"PHX_URL_SCHEME" => unquote(scheme)}))
      assert config[:helmsman][:secure_cookies] == unquote(secure?)
      Application.put_env(:helmsman, :secure_cookies, config[:helmsman][:secure_cookies])

      # A page render stores the CSRF token in a new session.
      page = get(conn, ~p"/users/log-in")
      assert cookie(page, "_helmsman_key") =~ ~r/; secure/i == unquote(secure?)

      conn = log_in(build_conn())
      assert redirected_to(conn) == ~p"/"
      assert cookie(conn, "_helmsman_key") =~ ~r/; secure/i == unquote(secure?)
      assert cookie(conn, "_helmsman_web_user_remember_me") =~ ~r/; secure/i == unquote(secure?)
    end
  end

  test "the session options keep SameSite=Lax and add Secure only for https" do
    Application.put_env(:helmsman, :secure_cookies, false)
    refute Keyword.has_key?(HelmsmanWeb.Endpoint.session_options(), :secure)
    assert HelmsmanWeb.Endpoint.session_options()[:same_site] == "Lax"

    Application.put_env(:helmsman, :secure_cookies, true)
    assert HelmsmanWeb.Endpoint.session_options()[:secure] == true
  end
end
