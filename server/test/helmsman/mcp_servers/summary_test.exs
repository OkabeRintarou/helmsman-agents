defmodule Helmsman.McpServers.SummaryTest do
  use ExUnit.Case, async: true
  alias Helmsman.McpServers.Summary

  test "URL credentials/query values and sensitive argument forms are masked" do
    assert Summary.mask("https://u:p@a.test/mcp?key=zzz&region=eu") ==
             "https://••••@a.test/mcp?key=••••&region=••••"

    for key <- ~w(token key secret password passwd auth credential) do
      assert Summary.mask(["--#{key}", "abc123", "safe"]) == ["--#{key}", "••••", "safe"]
      assert Summary.mask(["--#{key}=abc123"]) == ["--#{key}=••••"]
    end

    for value <- [
          "ghp_x",
          "gho_x",
          "github_pat_x",
          "glpat-x",
          "sk-x",
          "xoxb-x",
          "xoxp-x",
          "AKIAx",
          String.duplicate("a", 32)
        ],
        do: assert(Summary.mask(value) == "••••")

    assert Summary.mask(["--token", "${env:KEY}", "plain", "-y"]) == [
             "--token",
             "${env:KEY}",
             "plain",
             "-y"
           ]

    assert Summary.mask(String.duplicate("a", 31)) == String.duplicate("a", 31)
  end

  test "summaries expose only names of fixed env/headers and opaque fields" do
    summary =
      Summary.of("docs", %{
        "command" => "npx",
        "env" => %{"TOKEN" => "canary", "REF" => "${env:KEY}"},
        "auth" => %{"secret" => "canary2"}
      })

    assert summary.env == %{"TOKEN" => [], "REF" => ["KEY"]}
    assert summary.other_fields == ["auth"]
    refute inspect(summary) =~ "canary"
  end
end
