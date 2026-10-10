defmodule Helmsman.ApiTokens.ApiTokenTest do
  use ExUnit.Case, async: true

  alias Helmsman.ApiTokens.ApiToken

  @base %ApiToken{workspace_id: 1, user_id: 2, token_hash: <<0::256>>, prefix: "abcdefgh"}

  defp changeset(attrs), do: ApiToken.create_changeset(@base, attrs)

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  test "accepts a name, scopes, an expiry and a default agent" do
    expires_at = ~U[2030-01-01 00:00:00Z]

    changeset =
      changeset(%{
        name: "laptop",
        scopes: ["mcp", "api:read", "mcp"],
        expires_at: expires_at,
        default_agent_id: 7
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :scopes) == ["mcp", "api:read"]
    assert Ecto.Changeset.get_change(changeset, :expires_at) == expires_at
    assert Ecto.Changeset.get_change(changeset, :default_agent_id) == 7
  end

  test "requires a name of 1-64 characters" do
    assert %{name: ["can't be blank"]} = errors(changeset(%{scopes: ["mcp"]}))

    assert %{name: [_]} =
             errors(changeset(%{name: String.duplicate("n", 65), scopes: ["mcp"]}))

    assert changeset(%{name: String.duplicate("n", 64), scopes: ["mcp"]}).valid?
  end

  test "empty or unknown scopes list the valid ones" do
    for scopes <- [nil, [], ["admin"], ["mcp", "admin"]] do
      assert %{scopes: [message]} = errors(changeset(%{name: "laptop", scopes: scopes}))
      assert message == "must be one or more of: mcp, api:read, api:write"
    end
  end

  test "workspace, user, hash and prefix are not cast from attrs" do
    changeset =
      ApiToken.create_changeset(%ApiToken{}, %{
        name: "laptop",
        scopes: ["mcp"],
        workspace_id: 1,
        user_id: 2,
        token_hash: "x",
        prefix: "y"
      })

    assert %{workspace_id: _, user_id: _, token_hash: _, prefix: _} = errors(changeset)
  end

  test "the hash is redacted when inspected" do
    refute inspect(@base) =~ "token_hash: <<"
  end
end
