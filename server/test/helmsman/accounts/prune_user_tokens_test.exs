defmodule Helmsman.Accounts.PruneUserTokensTest do
  # Expired login tokens (add-release-distribution decision 8).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AccountsFixtures

  alias Helmsman.Accounts
  alias Helmsman.Accounts.UserToken
  alias Helmsman.Accounts.Workers.PruneUserTokens

  setup do
    %{user: user_fixture()}
  end

  # A token of `context` inserted `seconds` ago.
  defp token(user, context, seconds) do
    inserted_at = DateTime.utc_now(:second) |> DateTime.add(-seconds, :second)

    Repo.insert!(%UserToken{
      token: :crypto.strong_rand_bytes(32),
      context: context,
      sent_to: user.email,
      user_id: user.id,
      inserted_at: inserted_at
    })
  end

  defp exists?(%UserToken{id: id}), do: Repo.exists?(from(t in UserToken, where: t.id == ^id))

  test "each kind goes just after its validity and stays just before", %{user: user} do
    %{session: session, login: login, change: change} = UserToken.validity_seconds()
    assert session == 14 * 86_400 and login == 15 * 60 and change == 7 * 86_400

    expired = [
      token(user, "session", session + 60),
      token(user, "login", login + 60),
      token(user, "change:old@example.com", change + 60)
    ]

    kept = [
      token(user, "session", session - 60),
      token(user, "login", login - 60),
      token(user, "change:old@example.com", change - 60),
      # An unknown context is never pruned.
      token(user, "other", 365 * 86_400)
    ]

    assert PruneUserTokens.prune() == 3
    assert Enum.map(expired, &exists?/1) == [false, false, false]
    assert Enum.all?(kept, &exists?/1)
  end

  test "a valid session keeps working", %{user: user} do
    session = Accounts.generate_user_session_token(user)
    token(user, "session", 15 * 86_400)

    assert PruneUserTokens.prune() == 1
    assert {%{id: id}, _inserted_at} = Accounts.get_user_by_session_token(session)
    assert id == user.id
  end

  test "batches: at most batch × max_batches rows per execution", %{user: user} do
    for _ <- 1..5, do: token(user, "login", 3600)

    assert PruneUserTokens.prune(batch: 2, max_batches: 2) == 4
    assert PruneUserTokens.prune(batch: 2, max_batches: 2) == 1
    assert :ok = perform_job(PruneUserTokens, %{})
  end
end
