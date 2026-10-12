defmodule HelmsmanDaemon.ClaudeFixturesTest do
  use ExUnit.Case, async: true

  test "recorded fixtures contain no credentials or user home paths" do
    files = Path.wildcard(Path.expand("fixtures/claude/*", __DIR__))
    assert files != []

    for path <- files do
      text = File.read!(path)
      refute text =~ ~r/(?:hm_|hmr_|hmd_|sk-ant-)/, path
      refute text =~ ~r{/(?:home|Users)/}, path

      refute text =~
               ~r/(?:api[_-]?key|authorization)\s*[=:]\s*["']?(?:Bearer\s+)?[A-Za-z0-9_-]{20,}/i,
             path

      refute text =~ ~r/Ocp-Apim[^:\n]*:\s*(?!<redacted>)[A-Za-z0-9_-]{12,}/i, path
      refute text =~ ~r/NTID\s*[=:]\s*(?!<redacted>)[A-Za-z0-9_-]+/i, path

      if Path.extname(path) == ".jsonl" do
        for line <- String.split(text, "\n", trim: true), do: assert(is_map(JSON.decode!(line)))
        assert File.exists?(Path.rootname(path) <> ".version")
      end
    end
  end
end
