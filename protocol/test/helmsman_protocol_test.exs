defmodule HelmsmanProtocolTest do
  use ExUnit.Case, async: true
  doctest HelmsmanProtocol

  test "connection constants and version range" do
    assert HelmsmanProtocol.providers() == ~w(claude codex copilot cursor)a
    assert HelmsmanProtocol.local_repositories_version() < HelmsmanProtocol.cleanup_version()
    assert HelmsmanProtocol.cleanup_version() == 4
    assert HelmsmanProtocol.provider_account_headers_version() == 5
    assert HelmsmanProtocol.snapshot_version() == 6
    assert HelmsmanProtocol.snapshot_version() < HelmsmanProtocol.repo_registration_version()
    assert HelmsmanProtocol.repo_registration_version() < HelmsmanProtocol.mcp_env_version()
    assert HelmsmanProtocol.mcp_env_version() <= HelmsmanProtocol.version()

    assert HelmsmanProtocol.provider_account_version() <
             HelmsmanProtocol.local_repositories_version()

    assert HelmsmanProtocol.min_version() == 1
    assert HelmsmanProtocol.socket_path() == "/daemon/socket"
    assert HelmsmanProtocol.token_header() == "x-helmsman-token"
    assert HelmsmanProtocol.topic(42) == "daemon:42"

    for version <- 1..HelmsmanProtocol.version(),
        do: assert(HelmsmanProtocol.compatible?(version))

    for version <- [0, HelmsmanProtocol.version() + 1, "1", nil, 1.0],
        do: refute(HelmsmanProtocol.compatible?(version))

    for id <- [0, -1, "42"],
        do: assert_raise(FunctionClauseError, fn -> HelmsmanProtocol.topic(id) end)
  end
end
