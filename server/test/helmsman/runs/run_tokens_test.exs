defmodule Helmsman.Runs.RunTokensTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Runs.{Run, RunToken, RunTokens}
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(bob_scope, %{name: "bob/dev"})
    agent = agent_actor(ctx.workspace, "bob/dev")
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    run =
      run_fixture(agent, %{
        task_id: task.id,
        status: :claimed,
        capabilities: ["read", "write_task"]
      })

    {:ok, token} = RunTokens.issue(run)
    Map.merge(ctx, %{bob: bob, agent: agent, task: task, run: run, token: token})
  end

  defp set_status(run, status),
    do: Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: status])

  test "a token is hmr_ and 52 base32 characters; only its hash is stored", ctx do
    assert "hmr_" <> rest = ctx.token
    assert byte_size(rest) == 52
    assert rest =~ ~r/\A[a-z2-7]+\z/

    token = Repo.get_by!(RunToken, run_id: ctx.run.id)
    assert token.token_hash == :crypto.hash(:sha256, ctx.token)
    refute inspect(token) =~ "token_hash"
    assert DateTime.diff(token.expires_at, token.inserted_at) == 24 * 3600
  end

  test "valid while claimed, running or cancelling", ctx do
    for status <- [:claimed, :running, :cancelling] do
      set_status(ctx.run, status)
      assert {:ok, found} = RunTokens.authenticate(ctx.token)
      assert found.run.id == ctx.run.id
      assert found.run.task.ident == ctx.task.ident
      assert found.agent.name == "bob/dev"
      assert found.user.id == ctx.bob.id
      assert found.workspace.id == ctx.workspace.id
      assert found.role == :member
    end
  end

  test "invalid once the run is not active", ctx do
    for status <- [:queued, :deferred, :succeeded, :failed, :cancelled] do
      set_status(ctx.run, status)
      assert {:error, :unauthorized} = RunTokens.authenticate(ctx.token)
    end
  end

  test "expires 24 hours after it was issued", ctx do
    later = DateTime.add(DateTime.utc_now(), 24 * 3600 - 60, :second)
    assert {:ok, _} = RunTokens.authenticate(ctx.token, now: later)

    expired = DateTime.add(DateTime.utc_now(), 24 * 3600 + 1, :second)
    assert {:error, :unauthorized} = RunTokens.authenticate(ctx.token, now: expired)
  end

  test "revoked", ctx do
    assert :ok = RunTokens.revoke(ctx.run.id)
    assert {:error, :unauthorized} = RunTokens.authenticate(ctx.token)
  end

  test "invalid once the agent's owner left; the role is the owner's current one", ctx do
    Repo.update_all(
      from(m in Membership,
        where: m.user_id == ^ctx.bob.id and m.workspace_id == ^ctx.workspace.id
      ),
      set: [role: :viewer]
    )

    assert {:ok, %{role: :viewer}} = RunTokens.authenticate(ctx.token)

    Repo.delete_all(
      from(m in Membership,
        where: m.user_id == ^ctx.bob.id and m.workspace_id == ^ctx.workspace.id
      )
    )

    assert {:error, :unauthorized} = RunTokens.authenticate(ctx.token)
  end

  test "the daemon channel does not take run tokens", ctx do
    assert {:error, :unauthorized} = Helmsman.Daemons.authenticate(ctx.token)
  end

  test "a disabled agent is not refused here", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.agent, disabled_at: DateTime.utc_now(:second)))
    assert {:ok, _} = RunTokens.authenticate(ctx.token)
  end

  test "malformed tokens", ctx do
    for token <- ["", "hmr_", "hmr_short", "hm_" <> String.duplicate("a", 52), ctx.token <> "a"] do
      assert {:error, :unauthorized} = RunTokens.authenticate(token)
    end

    other = "hmr_" <> String.duplicate("a", 52)
    assert {:error, :unauthorized} = RunTokens.authenticate(other)
  end

  test "the scope: the agent as actor, the owner as user, via :run, no API token", ctx do
    assert {:ok, %Scope{} = scope} = RunTokens.scope(ctx.token)
    assert scope.via == :run
    assert scope.actor.name == "bob/dev"
    assert scope.user.id == ctx.bob.id
    assert scope.role == :member
    assert scope.run.id == ctx.run.id
    assert scope.token == nil
    assert Scope.credential(scope) == {:run, ctx.run.id}
  end
end
