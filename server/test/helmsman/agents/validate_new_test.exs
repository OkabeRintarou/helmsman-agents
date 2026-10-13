defmodule Helmsman.Agents.ValidateNewTest do
  # add-agent-conversation 3.2: `Agents.validate_new/2` gives the field
  # errors `create/2` gives, without writing (decision 7).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents

  setup do
    ctx = design_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {bob_daemon, _} = daemon_fixture(bob, %{workspace_ids: [ctx.workspace.id]})
    bob_runtime = runtime_fixture(ctx.workspace, bob_daemon)
    account = provider_account_fixture(ctx.alice, %{name: "zai"})
    Map.merge(ctx, %{bob_scope: bob_scope, bob_runtime: bob_runtime, account: account})
  end

  defp attrs(ctx, extra) do
    Map.merge(
      %{name: "fe-dev", provider: "claude", runtime_id: ctx.runtime.id, instructions: "x"},
      extra
    )
  end

  defp both(ctx, extra) do
    attrs = attrs(ctx, extra)
    actors = Repo.aggregate(Actor, :count)
    validated = Agents.validate_new(ctx.alice_scope, attrs)
    assert Repo.aggregate(Actor, :count) == actors

    created =
      case Agents.create(ctx.alice_scope, attrs) do
        {:ok, _view} -> :ok
        {:error, cs} -> {:error, errors_on(cs)}
      end

    validated =
      case validated do
        :ok -> :ok
        {:error, cs} -> {:error, Agents.errors(cs)}
      end

    {validated, created}
  end

  for {label, extra, field} <- [
        {"the name rule", %{name: "Bad Name"}, :name},
        {"a taken name", %{name: "helper"}, :name},
        {"a taken name in another case", %{name: "HELPER"}, :name},
        {"a CLI other than the runtime's", %{provider: "codex"}, :runtime_id},
        {"a model not in the list", %{model: "gpt-5"}, :model},
        {"an effort not in the list", %{effort: "ultra"}, :effort},
        {"a description too long", %{description: String.duplicate("d", 1001)}, :description},
        {"too much concurrency", %{max_concurrency: 17}, :max_concurrency},
        {"idle above the total", %{timeout_minutes: 5, idle_timeout_minutes: 6},
         :idle_timeout_minutes},
        {"an unknown capability", %{capabilities: ["delegate"]}, :capabilities},
        {"an unknown provider", %{provider: "vim"}, :provider}
      ] do
    test "#{label}: the same errors as create/2", ctx do
      {validated, created} = both(ctx, unquote(Macro.escape(extra)))
      assert {:error, errors} = created
      assert Map.has_key?(errors, unquote(field))
      assert validated == created
    end
  end

  test "another user's runtime: the same runtime_id error", ctx do
    {validated, created} = both(ctx, %{runtime_id: ctx.bob_runtime.id})
    assert {:error, %{runtime_id: [_]}} = created
    assert validated == created
  end

  test "a provider account relaxes the model list; another user's account is refused", ctx do
    assert both(ctx, %{name: "a1", provider_account_id: ctx.account.id, model: "glm-5.3"}) ==
             {:ok, :ok}

    other = provider_account_fixture(ctx.bob_scope.user, %{name: "bobs"})
    {validated, created} = both(ctx, %{name: "a2", provider_account_id: other.id})
    assert {:error, %{provider_account_id: ["does not exist"]}} = created
    assert validated == created
  end

  test "several errors at once", ctx do
    assert {:error, cs} =
             Agents.validate_new(ctx.alice_scope, attrs(ctx, %{name: "Bad", model: "gpt-5"}))

    assert %{name: [_], model: [_]} = Agents.errors(cs)
  end
end
