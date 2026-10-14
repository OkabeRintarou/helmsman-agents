defmodule HelmsmanDaemon.Adapters.Codex.VendorTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex.Vendor

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "codex")

    %{
      home: home,
      path: Path.join(home, "config.toml"),
      opts: [location: {:ok, {:user, home}}, env: %{}]
    }
  end

  test "default, top-level endpoint and ignored environment override", ctx do
    assert Vendor.infer(ctx.opts) == "openai"
    opts = Keyword.put(ctx.opts, :env, %{"OPENAI_BASE_URL" => "https://api.deepseek.com"})
    assert Vendor.infer(opts) == "openai"

    for {url, expected} <- [
          {"https://api.deepseek.com", "deepseek"},
          {"", "openai"},
          {" ", "openai"},
          {"https://internal.example", nil}
        ] do
      File.write!(ctx.path, "openai_base_url = \"#{url}\"\n")
      assert Vendor.infer(opts) == expected
    end

    File.write!(ctx.path, "openai_base_url = 42\n")
    assert Vendor.infer(opts) == nil
    File.rm!(ctx.path)
    assert Vendor.infer(env: %{"HOME" => ctx.tmp_dir, "CODEX_HOME" => ctx.home}) == "openai"
  end

  test "builtins and custom providers", ctx do
    for {id, expected} <- [{"ollama", "ollama"}, {"lmstudio", nil}, {"missing", nil}] do
      File.write!(ctx.path, "model_provider = \"#{id}\"\n")
      assert Vendor.infer(ctx.opts) == expected
    end

    File.write!(ctx.path, """
    model_provider = "glm"
    [model_providers.glm]
    base_url = "https://open.bigmodel.cn/api/paas/v4?key=SECRET"
    """)

    before = File.read!(ctx.path)
    stat = File.stat!(ctx.path)
    assert Vendor.infer(ctx.opts) == "zhipu"
    assert File.read!(ctx.path) == before
    assert File.stat!(ctx.path).mtime == stat.mtime

    for value <- ["", " ", "https://internal.example"] do
      File.write!(
        ctx.path,
        "model_provider = \"custom\"\n[model_providers.custom]\nbase_url = \"#{value}\"\n"
      )

      assert Vendor.infer(ctx.opts) == nil
    end

    File.write!(
      ctx.path,
      "model_provider = \"custom\"\n[model_providers.custom]\nname = \"custom\"\n"
    )

    assert Vendor.infer(ctx.opts) == nil
  end

  test "validation errors return nil without executing codex", ctx do
    for config <- [
          "profile = \"old\"",
          "[model_providers.helmsman_account]",
          "invalid [",
          "model_provider = 42",
          "model_providers = []"
        ] do
      File.write!(ctx.path, config)
      assert Vendor.infer(ctx.opts) == nil
    end

    previous = Application.get_env(:helmsman_daemon, :codex_executable)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman_daemon, :codex_executable, previous),
        else: Application.delete_env(:helmsman_daemon, :codex_executable)
    end)

    executable = Path.join(ctx.tmp_dir, "probe")
    marker = Path.join(ctx.tmp_dir, "executed")
    File.write!(executable, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(executable, 0o700)
    Application.put_env(:helmsman_daemon, :codex_executable, executable)
    File.rm!(ctx.path)
    assert Vendor.infer(ctx.opts) == "openai"
    refute File.exists?(marker)
  end

  test "private directory is never created and location failures return nil", ctx do
    home = Path.join(ctx.tmp_dir, "private-missing")
    assert Vendor.infer(location: {:ok, {:private, home}}, env: %{}) == "openai"
    refute File.exists?(home)
    assert Vendor.infer(location: {:error, :unavailable}, env: %{}) == nil
    assert Vendor.infer(location: {:ok, {:user, home}}, env: %{}) == nil
  end
end
