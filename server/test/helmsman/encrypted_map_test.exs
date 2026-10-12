defmodule Helmsman.EncryptedMapTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures
  alias Helmsman.Agents.AgentProfile

  test "database stores authenticated ciphertext and schemas redact both maps" do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)

    managed_agent_fixture(scope, %{
      env: %{"API_KEY" => "unique-secret-value"},
      extra_mcp_servers: %{"private" => %{"key" => "unique-mcp-secret"}}
    })

    profile = Repo.one!(AgentProfile)

    %{rows: [[env, mcp]]} =
      Repo.query!("SELECT env, extra_mcp_servers FROM agent_profiles WHERE id = $1", [profile.id])

    assert :binary.match(env, "unique-secret-value") == :nomatch
    assert :binary.match(mcp, "unique-mcp-secret") == :nomatch
    assert Repo.get!(AgentProfile, profile.id).env == %{"API_KEY" => "unique-secret-value"}

    assert Repo.get!(AgentProfile, profile.id).extra_mcp_servers == %{
             "private" => %{"key" => "unique-mcp-secret"}
           }

    refute inspect(profile) =~ "unique-secret-value"
    refute inspect(profile) =~ "unique-mcp-secret"
    cs = Ecto.Changeset.change(profile, env: %{"NEW" => "submitted-secret"})
    refute inspect(cs) =~ "submitted-secret"
  end
end
