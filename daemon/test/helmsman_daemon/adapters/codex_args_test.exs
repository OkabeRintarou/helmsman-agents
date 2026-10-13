defmodule HelmsmanDaemon.Adapters.CodexArgsTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Codex.Config

  test "safe provider and feature overrides survive while isolation keys and values are removed" do
    args = [
      "-c",
      ~s(model_provider="gw"),
      "--config=mcp_servers.x.url=VALUE_SENTINEL",
      "--listen",
      "ADDRESS_SENTINEL",
      "--enable",
      "foo",
      "-c",
      "sandbox_mode=VALUE_SENTINEL"
    ]

    assert {["-c", ~s(model_provider="gw"), "--enable", "foo"], removed} = Config.filter(args)
    assert removed == ["mcp_servers.x.url", "--listen", "sandbox_mode"]
    refute inspect(removed) =~ "SENTINEL"
  end

  test "profile selections and tables are removed for bound and unbound agents" do
    for bound <- [false, true] do
      assert {[], ["profile", "profiles.work.model_provider", "--profile"]} =
               Config.filter(
                 [
                   "-c",
                   "profile=VALUE_SENTINEL",
                   "--config=profiles.work.model_provider=VALUE_SENTINEL",
                   "--profile",
                   "work"
                 ],
                 bound
               )
    end
  end
end
