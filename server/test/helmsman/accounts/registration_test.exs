defmodule Helmsman.Accounts.RegistrationTest do
  # Switches the global signup mode.
  use Helmsman.DataCase, async: false

  alias Helmsman.Accounts

  import Helmsman.AccountsFixtures

  defp put_signup_mode(mode) do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :signup_mode, mode)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)
  end

  describe "invite mode" do
    setup do
      put_signup_mode(:invite)
    end

    test "the first user on an empty instance becomes the instance admin" do
      assert Accounts.registration_open?()
      assert {:ok, user} = Accounts.register_user(valid_user_attributes())
      assert user.instance_admin
      assert Repo.reload!(user).instance_admin
    end

    test "a second user without an invitation is rejected" do
      {:ok, _first} = Accounts.register_user(valid_user_attributes())
      refute Accounts.registration_open?()

      email = unique_user_email()

      assert {:error, :signup_closed} =
               Accounts.register_user(valid_user_attributes(email: email))

      refute Accounts.get_user_by_email(email)
    end
  end

  describe "open mode" do
    setup do
      put_signup_mode(:open)
    end

    test "a second user registers and is not an instance admin" do
      {:ok, first} = Accounts.register_user(valid_user_attributes())
      assert first.instance_admin
      assert Accounts.registration_open?()

      assert {:ok, second} = Accounts.register_user(valid_user_attributes())
      refute second.instance_admin
    end
  end

  test "instance_admin cannot be set through registration attrs" do
    put_signup_mode(:open)
    {:ok, _first} = Accounts.register_user(valid_user_attributes())

    {:ok, user} = Accounts.register_user(valid_user_attributes(instance_admin: true))
    refute user.instance_admin
  end

  test "signup_mode/0 defaults to :invite" do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.delete_env(:helmsman, :signup_mode)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)

    assert Accounts.signup_mode() == :invite
  end
end
