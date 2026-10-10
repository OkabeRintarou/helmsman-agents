defmodule Helmsman.Accounts.MagicLinkRaceTest do
  # Consumes one magic link from two connections outside the SQL sandbox,
  # so this module must not run concurrently with others.
  use ExUnit.Case, async: false

  @moduletag :db_race

  import Helmsman.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts
  alias Helmsman.CommittedData
  alias Helmsman.Repo

  # Every user of this module has an email in this domain, so cleanup only
  # deletes rows the module created.
  @domain "magic-link-race.test"

  setup do
    on_exit(&delete_committed_users/0)
  end

  test "a link of an unconfirmed user logs in exactly once" do
    {user, token} = unboxed(fn -> with_link(unconfirmed_user_fixture(racer_attrs())) end)

    results = race(user, [fn -> consume(token) end, fn -> consume(token) end])

    assert Enum.sort(Enum.map(results, &outcome/1)) == [:not_found, :ok]
    assert unboxed(fn -> Repo.reload!(user).confirmed_at end)
  end

  test "a link of a confirmed user logs in exactly once and never raises" do
    {user, token} = unboxed(fn -> with_link(user_fixture(racer_attrs())) end)

    results = race(user, [fn -> consume(token) end, fn -> consume(token) end])

    assert Enum.sort(Enum.map(results, &outcome/1)) == [:not_found, :ok]
  end

  test "two different links of an unconfirmed user log in exactly once without deadlock" do
    {user, token1, token2} =
      unboxed(fn ->
        user = unconfirmed_user_fixture(racer_attrs())
        {_user, token1} = with_link(user)
        {_user, token2} = with_link(user)
        {user, token1, token2}
      end)

    results = race(user, [fn -> consume(token1) end, fn -> consume(token2) end])

    # Confirming the account expires all of its tokens, including the other link.
    assert Enum.sort(Enum.map(results, &outcome/1)) == [:not_found, :ok]
  end

  test "a link and a password change of the same user do not deadlock" do
    {user, token} = unboxed(fn -> with_link(user_fixture(racer_attrs())) end)

    change_password = fn ->
      unboxed(fn -> Accounts.update_user_password(user, %{password: "new valid password"}) end)
    end

    [link_result, password_result] = race(user, [fn -> consume(token) end, change_password])

    assert outcome(link_result) in [:ok, :not_found]
    assert {:ok, {_user, _expired_tokens}} = password_result
    # Either way the password change expired every token of the user.
    assert unboxed(fn -> Repo.all_by(Accounts.UserToken, user_id: user.id) end) == []
  end

  defp with_link(user) do
    {encoded_token, _hashed} = generate_user_magic_link_token(user)
    {user, encoded_token}
  end

  defp outcome({:ok, {%Accounts.User{}, _tokens}}), do: :ok
  defp outcome({:error, :not_found}), do: :not_found

  # A third transaction holds the user's row lock until every racer is
  # blocked, so their work overlaps; then it releases them together.
  defp race(user, funs) do
    parent = self()

    holder = Task.async(fn -> unboxed(fn -> hold_user_row(parent, user.id) end) end)
    assert_receive :locked, 5_000

    racers = Enum.map(funs, &Task.async/1)

    wait_until_blocked(length(funs))
    send(holder.pid, :release)
    Task.await(holder)
    Task.await_many(racers, 10_000)
  end

  defp consume(token), do: unboxed(fn -> Accounts.login_user_by_magic_link(token) end)

  defp hold_user_row(parent, user_id) do
    Repo.transact(fn ->
      Repo.query!("SELECT 1 FROM users WHERE id = $1 FOR UPDATE", [user_id])
      send(parent, :locked)

      receive do
        :release -> {:ok, :released}
      end
    end)
  end

  defp wait_until_blocked(count, attempts \\ 200)

  defp wait_until_blocked(_count, 0), do: flunk("consumers never blocked on the row lock")

  defp wait_until_blocked(count, attempts) do
    %{rows: [[blocked]]} =
      unboxed(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity " <>
            "WHERE datname = current_database() AND wait_event_type = 'Lock'"
        )
      end)

    if blocked >= count do
      :ok
    else
      Process.sleep(10)
      wait_until_blocked(count, attempts - 1)
    end
  end

  # Also removes the `default` workspace of the first user.
  defp racer_attrs, do: %{email: "user#{System.unique_integer([:positive])}@#{@domain}"}

  # Also removes the `default` workspace a first user gets.
  defp delete_committed_users do
    import Ecto.Query

    pattern = "%@" <> @domain

    ids =
      unboxed(fn ->
        Repo.all(from(u in Accounts.User, where: like(u.email, ^pattern), select: u.id))
      end)

    CommittedData.delete_user_data!(ids)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
