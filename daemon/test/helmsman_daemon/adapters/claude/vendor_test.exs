defmodule HelmsmanDaemon.Adapters.Claude.VendorTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Claude.Vendor

  setup %{tmp_dir: dir} do
    user = Path.join(dir, ".claude/settings.json")
    managed = Path.join(dir, "managed-settings.json")
    File.mkdir_p!(Path.dirname(user))
    %{user: user, managed: managed, opts: [home: dir, env: %{}, managed_path: managed]}
  end

  test "official, user endpoint, environment priority and managed priority", ctx do
    assert Vendor.infer(ctx.opts) == "anthropic"
    opts = Keyword.put(ctx.opts, :env, %{"ANTHROPIC_BASE_URL" => "https://api.deepseek.com"})
    assert Vendor.infer(opts) == "deepseek"
    write(ctx.user, %{"ANTHROPIC_BASE_URL" => "https://open.bigmodel.cn"})
    assert Vendor.infer(opts) == "zhipu"

    write(ctx.managed, %{
      "ANTHROPIC_BASE_URL" => "https://api.z.ai",
      "ANTHROPIC_AUTH_TOKEN" => "SECRET"
    })

    assert Vendor.infer(opts) == "zai"
    # Each variable merges separately, so a managed false value overrides a user true value.
    write(ctx.user, %{"CLAUDE_CODE_USE_BEDROCK" => "1"})
    write(ctx.managed, %{"CLAUDE_CODE_USE_BEDROCK" => "0"})
    assert Vendor.infer(opts) == "deepseek"
  end

  test "platform flags and unknown platform flags", ctx do
    for {key, expected} <- [
          {"BEDROCK", "bedrock"},
          {"VERTEX", "vertexai"},
          {"FOUNDRY", "azure"},
          {"GATEWAY", nil},
          {"MANTLE", nil}
        ] do
      for value <- ["1", " true ", "YES", "On"] do
        write(ctx.user, %{
          ("CLAUDE_CODE_USE_" <> key) => value,
          "ANTHROPIC_BASE_URL" => "https://api.z.ai"
        })

        assert Vendor.infer(ctx.opts) == expected
      end
    end

    write(ctx.user, Map.new(~w(BEDROCK VERTEX FOUNDRY), &{"CLAUDE_CODE_USE_" <> &1, "1"}))
    assert Vendor.infer(ctx.opts) == "bedrock"
    write(ctx.user, %{"CLAUDE_CODE_USE_GATEWAY" => "false"})
    assert Vendor.infer(ctx.opts) == "anthropic"
  end

  test "config directory and read-only inference", ctx do
    dir = Path.join(ctx.tmp_dir, "custom")
    File.mkdir_p!(dir)
    path = Path.join(dir, "settings.json")
    write(path, %{"ANTHROPIC_BASE_URL" => "https://api.z.ai"})
    File.chmod!(path, 0o400)
    before = File.stat!(path)
    opts = Keyword.put(ctx.opts, :env, %{"CLAUDE_CONFIG_DIR" => dir})
    assert Vendor.infer(opts) == "zai"
    assert File.stat!(path).mtime == before.mtime
    assert File.stat!(path).mode == before.mode
  end

  test "unrecognized endpoints, corrupt and unreadable sources fail closed", ctx do
    write(ctx.user, %{"ANTHROPIC_BASE_URL" => "https://llm.corp.example"})
    assert Vendor.infer(ctx.opts) == nil
    write(ctx.user, %{"ANTHROPIC_BASE_URL" => ""})
    assert Vendor.infer(ctx.opts) == "anthropic"

    for text <- ["invalid JSON", "[]", ~s({"env":null}), ~s({"env":{"ANTHROPIC_BASE_URL":42}})] do
      File.write!(ctx.user, text)
      assert Vendor.infer(ctx.opts) == nil
    end

    File.rm!(ctx.user)
    File.mkdir!(ctx.user)
    assert Vendor.infer(ctx.opts) == nil
    File.rmdir!(ctx.user)
    File.write!(ctx.managed, "invalid")
    assert Vendor.infer(ctx.opts) == nil
  end

  defp write(path, env), do: File.write!(path, JSON.encode!(%{"env" => env}))
end
