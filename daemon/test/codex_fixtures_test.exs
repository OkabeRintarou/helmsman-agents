defmodule HelmsmanDaemon.CodexFixturesTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.CodexFixtures

  test "all recordings have version, exit, stderr and provenance without secrets" do
    fixtures = Path.wildcard(Path.join(CodexFixtures.root(), "*.jsonl"))
    assert length(fixtures) >= 10

    for path <- fixtures do
      basename = Path.rootname(path)

      for ext <- [".stderr", ".exit", ".version", ".source"],
          do: assert(File.exists?(basename <> ext))

      assert String.trim(File.read!(basename <> ".version")) == "codex-cli 0.162.1"
      assert {_, ""} = Integer.parse(String.trim(File.read!(basename <> ".exit")))
      assert String.split(File.read!(path), "\n", trim: true) != []
      Enum.each(String.split(File.read!(path), "\n", trim: true), &JSON.decode!/1)
    end

    denylist =
      System.get_env("HELMSMAN_FIXTURE_DENYLIST", "") |> String.split([",", "\n"], trim: true)

    for path <- Path.wildcard(Path.join(CodexFixtures.root(), "*")) do
      text = File.read!(path)
      refute text =~ ~r/\b(?:hm_|hmr_|hmd_|sk-)/
      refute text =~ "/Users/"
      refute text =~ "/home/jenkins"
      for value <- denylist, do: refute(text =~ value)
    end
  end
end
