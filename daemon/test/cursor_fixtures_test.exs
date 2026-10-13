defmodule HelmsmanDaemon.CursorFixturesTest do
  use ExUnit.Case, async: true

  test "recorded fixtures contain no keys, tokens, home paths or Cursor hosts" do
    files = Path.wildcard(Path.expand("fixtures/cursor/*", __DIR__))
    assert files != []

    for path <- files do
      text = File.read!(path)
      refute text =~ ~r/key_[A-Za-z0-9]{16,}|crsr_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{20,}/, path

      refute text |> String.replace("hmr_probe_DUMMY_12345", "") =~
               ~r/(?:hm_|hmr_|hmd_)[A-Za-z0-9]/,
             path

      refute text =~ ~r{/(?:home|Users)/}, path
      refute text =~ ~r/[A-Za-z0-9.-]+\.cursor\.sh/, path
      refute text =~ ~r/[\w.+-]+@[\w-]+\.[\w.]+/, path
    end

    for name <- ~w(error_rate_limit error_quota error_context),
        do: assert(File.exists?(Path.expand("fixtures/cursor/#{name}.source", __DIR__)))
  end
end
