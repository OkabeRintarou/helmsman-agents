defmodule HelmsmanWeb.UserLive.LoginRateLimitTest do
  # Changes the global rate limit configuration.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Helmsman.AccountsFixtures
  import Helmsman.RateLimitHelpers

  setup do
    put_rate_limits()
  end

  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  # Submits the magic link form once and returns the flash text the user sees.
  defp submit_magic(conn, email) do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    case lv |> form("#login_form_magic", user: %{email: email}) |> render_submit() do
      {:error, {:live_redirect, %{to: "/users/log-in"}}} = redirect ->
        {:ok, _lv, html} = follow_redirect(redirect, conn, ~p"/users/log-in")
        {:redirected, flash_text(html)}

      html when is_binary(html) ->
        {:rendered, flash_text(html)}
    end
  end

  defp flash_text(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#flash-info, #flash-error")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Each group uses its own client IP, so the per-IP limit (5) never masks
  # the per-email limit (3) under test.
  defp conn_from_new_ip(conn) do
    Plug.Test.put_peer_data(conn, %{address: unique_ip(), port: 4000, ssl_cert: nil})
  end

  test "registered and unregistered emails get identical responses", %{conn: conn} do
    user = user_fixture()
    flush_emails()
    unknown = "nobody#{System.unique_integer([:positive])}@example.com"

    unknown_results = for _ <- 1..4, do: submit_magic(conn_from_new_ip(conn), unknown)
    assert_no_email_sent()

    known_conn = conn_from_new_ip(conn)
    known_results = for _ <- 1..4, do: submit_magic(known_conn, user.email)

    assert Enum.take(known_results, 3) == Enum.take(unknown_results, 3)
    assert [{:redirected, info} | _] = known_results
    assert info =~ "如果该邮箱已注册"

    assert List.last(known_results) == List.last(unknown_results)
    assert List.last(known_results) == {:rendered, "请求过于频繁，请稍后再试"}

    for _ <- 1..3, do: assert_email_sent(to: user.email)
    assert_no_email_sent()
  end

  test "the per-IP limit uses the LiveView peer address", %{conn: conn} do
    conn = conn_from_new_ip(conn)

    results =
      for _ <- 1..6 do
        submit_magic(conn, "someone#{System.unique_integer([:positive])}@example.com")
      end

    assert Enum.count(results, &match?({:redirected, _}, &1)) == 5
    assert List.last(results) == {:rendered, "请求过于频繁，请稍后再试"}
  end

  test "password log in is limited per remote IP", %{conn: conn} do
    user = user_fixture() |> set_password()
    ip = unique_ip()

    post_login = fn password ->
      %{conn | remote_ip: ip}
      |> post(~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => password}})
    end

    for _ <- 1..10 do
      conn = post_login.("wrong password")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "邮箱或密码错误"
    end

    conn = post_login.(valid_user_password())
    assert redirected_to(conn) == ~p"/users/log-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "请求过于频繁，请稍后再试"
    refute get_session(conn, :user_token)
  end

  test "registration submissions are limited per LiveView peer address", %{conn: conn} do
    put_rate_limits(register_ip: {2, :timer.hours(1)})
    conn = conn_from_new_ip(conn)
    {:ok, lv, _html} = live(conn, ~p"/users/register")

    lv |> form("#registration_form", user: %{"email" => "bad"}) |> render_submit()
    lv |> form("#registration_form", user: %{"email" => "bad"}) |> render_submit()

    email = unique_user_email()
    html = lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()

    assert html =~ "请求过于频繁，请稍后再试"
    refute Helmsman.Accounts.get_user_by_email(email)
  end
end
