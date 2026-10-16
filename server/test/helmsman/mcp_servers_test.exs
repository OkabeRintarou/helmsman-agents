defmodule Helmsman.McpServersTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  alias Helmsman.Accounts.Scope
  alias Helmsman.{McpServers, Repo}
  alias Helmsman.McpServers.Definition

  setup do
    user = user_fixture()
    %{scope: Scope.for_user(user), other: Scope.for_user(user_fixture())}
  end

  test "only a user's human web session manages encrypted definitions", ctx do
    assert {:ok, d} =
             McpServers.create(ctx.scope, %{
               name: "docs",
               config: %{"command" => "npx", "auth" => %{"secret" => "canary"}}
             })

    refute inspect(d) =~ "canary"
    assert Repo.get!(Definition, d.id).config["auth"]["secret"] == "canary"
    assert {:ok, editable} = McpServers.editable(ctx.scope, d.id)
    refute inspect(editable) =~ "canary"
    assert {:error, :not_found} = McpServers.get(ctx.other, d.id)

    for via <- [:mcp, :api, :run] do
      assert {:error, :forbidden} = McpServers.list(%{ctx.scope | via: via})
      assert {:error, :forbidden} = McpServers.update(%{ctx.scope | via: via}, d.id, %{name: "x"})
    end

    assert {:ok, updated} =
             McpServers.update(ctx.scope, d.id, %{
               name: "renamed",
               config: Map.put(editable, "command", "uvx")
             })

    assert updated.name == "renamed"
    assert Repo.get!(Definition, d.id).config["auth"]["secret"] == "canary"
    assert {:ok, :deleted} = McpServers.delete(ctx.scope, d.id)
  end

  test "32 limit, duplicate names, field boundaries and user cascade", ctx do
    for i <- 1..32,
        do:
          assert(
            {:ok, _} =
              McpServers.create(ctx.scope, %{name: "docs#{i}", config: %{"command" => "npx"}})
          )

    assert {:error, :limit_reached} =
             McpServers.create(ctx.scope, %{name: "overflow", config: %{"command" => "npx"}})

    assert {:error, cs} = McpServers.create(ctx.other, %{name: "bad", config: %{"command" => ""}})
    assert cs.errors[:config]
    refute inspect(cs) =~ "canary"

    Repo.delete_all(
      from m in Helmsman.Workspaces.Membership, where: m.user_id == ^ctx.scope.user.id
    )

    Repo.delete_all(from a in Helmsman.Actors.Actor, where: a.user_id == ^ctx.scope.user.id)
    Repo.delete!(ctx.scope.user)

    assert Repo.aggregate(from(d in Definition, where: d.user_id == ^ctx.scope.user.id), :count) ==
             0
  end
end
