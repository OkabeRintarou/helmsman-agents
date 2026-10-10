defmodule Helmsman.CommittedData do
  @moduledoc """
  Helpers for `async: false` tests that commit data on their own
  connections outside the SQL sandbox.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Repo

  @doc "Runs `fun` on a connection of its own, outside the sandbox."
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Deletes, children first, the committed rows of the given users: the
  workspaces they own (including a first user's `default` workspace), their
  memberships and identities elsewhere, their tokens and the users. Every
  other row is left alone.
  """
  def delete_user_data!(user_ids) do
    unboxed(fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT workspace_id FROM memberships WHERE user_id = ANY($1) AND role = 'owner'",
          [user_ids]
        )

      workspace_ids = List.flatten(rows)

      Repo.query!(
        "DELETE FROM actors WHERE workspace_id = ANY($1) OR user_id = ANY($2) OR owner_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!(
        "DELETE FROM memberships WHERE workspace_id = ANY($1) OR user_id = ANY($2)",
        [workspace_ids, user_ids]
      )

      Repo.query!("DELETE FROM workspaces WHERE id = ANY($1)", [workspace_ids])
      Repo.query!("DELETE FROM users_tokens WHERE user_id = ANY($1)", [user_ids])
      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [user_ids])
    end)

    :ok
  end
end
