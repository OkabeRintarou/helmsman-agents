defmodule Helmsman.Accounts.RateLimitTest do
  # Changes the global rate limit configuration.
  use Helmsman.DataCase, async: false

  import Swoosh.TestAssertions
  import Helmsman.AccountsFixtures
  import Helmsman.RateLimitHelpers

  alias Helmsman.Accounts

  setup do
    put_rate_limits()
  end

  # user_fixture/1 logs the user in through a magic link email.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp request(email, ip), do: Accounts.request_login_link(email, ip, &"[TOKEN]#{&1}[TOKEN]")

  describe "request_login_link/3" do
    test "the 6th request from one IP within a minute is rejected and sends no email" do
      ip = unique_ip()
      users = for _ <- 1..6, do: user_fixture()
      flush_emails()

      for user <- Enum.take(users, 5) do
        assert :ok = request(user.email, ip)
        assert_email_sent(to: user.email)
      end

      assert {:error, :rate_limited} = request(List.last(users).email, ip)
      assert_no_email_sent()
    end

    test "the 4th request for one email within 10 minutes is rejected" do
      user = user_fixture()
      flush_emails()

      for _ <- 1..3 do
        assert :ok = request(user.email, unique_ip())
        assert_email_sent(to: user.email)
      end

      assert {:error, :rate_limited} = request(user.email, unique_ip())
      assert_no_email_sent()
    end

    test "case and surrounding whitespace do not bypass the email limit" do
      user = user_fixture(email: "alice#{System.unique_integer([:positive])}@x.com")
      flush_emails()
      [local, _] = String.split(user.email, "@")

      variants = [
        String.capitalize(local) <> "@x.com",
        local <> "@x.com",
        " " <> String.upcase(local) <> "@X.COM ",
        local <> "@X.com"
      ]

      results = Enum.map(variants, &request(&1, unique_ip()))
      assert results == [:ok, :ok, :ok, {:error, :rate_limited}]
      assert_email_sent(to: user.email)
      assert_email_sent(to: user.email)
      assert_email_sent(to: user.email)
      assert_no_email_sent()
    end

    test "unknown emails are counted the same way and never receive email" do
      email = "nobody#{System.unique_integer([:positive])}@example.com"

      results = for _ <- 1..4, do: request(email, unique_ip())

      assert results == [:ok, :ok, :ok, {:error, :rate_limited}]
      assert_no_email_sent()
    end
  end

  describe "login_user_by_password/3" do
    test "the 11th attempt from one IP within a minute is rejected" do
      user = user_fixture() |> set_password()
      ip = unique_ip()

      for _ <- 1..10 do
        assert {:error, :invalid_credentials} =
                 Accounts.login_user_by_password(user.email, "wrong password", ip)
      end

      assert {:error, :rate_limited} =
               Accounts.login_user_by_password(user.email, valid_user_password(), ip)

      assert {:ok, _user} =
               Accounts.login_user_by_password(user.email, valid_user_password(), unique_ip())
    end
  end

  describe "register_user/2 with :ip" do
    test "the 11th submission from one IP is rejected, and allowed again after the window" do
      put_rate_limits(register_ip: {10, 1_000})
      ip = unique_ip()
      # Start right after a window boundary so all 11 submissions share a window.
      Process.sleep(1_000 - rem(System.system_time(:millisecond), 1_000))

      # Failed submissions count as well.
      for _ <- 1..5 do
        assert {:error, %Ecto.Changeset{}} = Accounts.register_user(%{email: "bad"}, ip: ip)
      end

      for _ <- 1..5 do
        assert {:ok, _user} = Accounts.register_user(valid_user_attributes(), ip: ip)
      end

      email = unique_user_email()

      assert {:error, :rate_limited} =
               Accounts.register_user(valid_user_attributes(email: email), ip: ip)

      refute Accounts.get_user_by_email(email)

      # Fixed one-second window: wait for it to pass.
      Process.sleep(1_000)
      assert {:ok, _user} = Accounts.register_user(valid_user_attributes(email: email), ip: ip)
    end

    test "registrations without :ip are not limited" do
      put_rate_limits(register_ip: {1, :timer.hours(1)})

      for _ <- 1..3 do
        assert {:ok, _user} = Accounts.register_user(valid_user_attributes())
      end
    end
  end
end
