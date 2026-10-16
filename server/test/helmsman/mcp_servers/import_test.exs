defmodule Helmsman.McpServers.ImportTest do
  use ExUnit.Case, async: true
  alias Helmsman.McpServers.{Entry, Import, Templates}

  test "templates validate and credential templates use local references" do
    assert length(Templates.all()) == 6
    for t <- Templates.all(), do: assert({:ok, _} = Entry.validate(%{t.name => t.config}))
  end

  test "CLI JSON, VS Code, single entries and shell quoting" do
    for text <- [
          ~s({"mcpServers":{"docs":{"command":"npx"}}}),
          ~s({"servers":{"docs":{"command":"npx"}},"inputs":[]}),
          "claude mcp add docs -- npx",
          "codex mcp add docs -- npx",
          ~s(claude mcp add-json docs '{"command":"npx"}')
        ] do
      assert {:ok, [%{name: "docs", config: %{"command" => "npx"}, errors: []}]} =
               Import.parse(text)
    end

    assert {:ok, [%{name: "mine"}]} = Import.parse(~s({"command":"npx"}), "mine")

    assert {:ok, [%{config: config}]} =
             Import.parse(
               ~s(claude mcp add --transport http github https://a.test -H "Authorization: Bearer ${GITHUB_PAT}")
             )

    assert config["headers"]["Authorization"] == "Bearer ${env:GITHUB_PAT}"

    assert {:ok, [%{config: %{"args" => ["a b"]}}]} =
             Import.parse(~s(codex mcp add docs -- npx 'a b'))
  end

  test "Codex env and bearer translation, unsupported inputs and defaults warn" do
    assert {:ok, [%{config: config}]} =
             Import.parse(
               ~s([mcp_servers.docs]\ncommand = "uvx"\nenv_vars = ["TOKEN"]\nbearer_token_env_var = "PAT"\n[mcp_servers.docs.env_http_headers]\nX-Key = "KEY"\n)
             )

    assert config["env"]["TOKEN"] == "${env:TOKEN}"
    assert config["headers"] == %{"Authorization" => "Bearer ${env:PAT}", "X-Key" => "${env:KEY}"}

    assert {:ok, [%{config: config, warnings: warnings}]} =
             Import.parse(~s({"command":"npx","args":["${X:-default}","${input:path}"]}))

    assert config["args"] == ["${env:X}", ""]
    assert Enum.sort(warnings) == [:default_ignored, :input_unsupported]
    assert {:error, :unrecognized_format} = Import.parse("garbage")
  end
end
