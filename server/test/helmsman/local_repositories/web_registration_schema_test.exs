defmodule Helmsman.LocalRepositories.WebRegistrationSchemaTest do
  # add-local-repo-web-registration 3.1: the CHECK constraints and the
  # unique request ID of `local_repository_changes`, written straight to
  # the database.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Daemons.Daemon
  alias Helmsman.LocalRepositories.Change

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)
    {daemon, _token} = daemon_fixture(user, %{workspace_ids: [workspace.id]})
    %{user: user, workspace: workspace, daemon: daemon}
  end

  defp record(ctx, attrs) do
    struct!(
      Change,
      Map.merge(
        %{
          daemon_id: ctx.daemon.id,
          user_id: ctx.user.id,
          workspace_id: ctx.workspace.id,
          action: "register",
          name: "app",
          root: "~/code",
          path: "app",
          workspace_ids: [ctx.workspace.id],
          request_id: "req#{System.unique_integer([:positive])}xxxxxxxxxxxxxxxxxx",
          inserted_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp violates(constraint, fun) do
    Repo.transact(fn -> {:ok, fun.()} end)
    flunk("expected #{constraint} to be violated")
  rescue
    error in Postgrex.Error -> assert error.postgres.constraint == constraint
    error in Ecto.ConstraintError -> assert error.constraint == constraint
  end

  test "daemons default to no web registration", ctx do
    refute Repo.get!(Daemon, ctx.daemon.id).repo_registration
  end

  test "a register and a remove are stored", ctx do
    assert %Change{status: "pending"} = Repo.insert!(record(ctx, %{}))

    assert %Change{root: nil, path: nil} =
             Repo.insert!(record(ctx, %{action: "remove", root: nil, path: nil}))
  end

  test "action and status are checked", ctx do
    violates("local_repository_changes_action_check", fn ->
      Repo.insert!(record(ctx, %{action: "rename", root: nil, path: nil}))
    end)

    violates("local_repository_changes_status_check", fn ->
      Repo.insert!(record(ctx, %{status: "lost"}))
    end)
  end

  test "root and path go with register only", ctx do
    violates("local_repository_changes_location_check", fn ->
      Repo.insert!(record(ctx, %{root: nil}))
    end)

    violates("local_repository_changes_location_check", fn ->
      Repo.insert!(record(ctx, %{path: nil}))
    end)

    violates("local_repository_changes_location_check", fn ->
      Repo.insert!(record(ctx, %{action: "remove"}))
    end)

    violates("local_repository_changes_location_check", fn ->
      Repo.insert!(record(ctx, %{action: "remove", root: nil}))
    end)
  end

  test "the message is at most 1024 bytes", ctx do
    assert Repo.insert!(record(ctx, %{message: String.duplicate("a", 1024)}))

    violates("local_repository_changes_message_length", fn ->
      Repo.insert!(record(ctx, %{message: String.duplicate("é", 513)}))
    end)
  end

  test "the request ID is unique", ctx do
    Repo.insert!(record(ctx, %{request_id: "same-request-id-0000000"}))

    violates("local_repository_changes_request_id_index", fn ->
      Repo.insert!(record(ctx, %{request_id: "same-request-id-0000000", name: "lib"}))
    end)
  end
end
