defmodule HelmsmanDaemon.Adapters.CopilotArgsTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Copilot.Args

  @values ~w(-p --prompt -i --interactive --output-format --additional-mcp-config --enable-mcp-server --mcp-github-auth --session-id --model --reasoning-effort --log-dir --usage-output-file --plugin-dir --mode -C --connect -r --resume --share)
  @switches ~w(--allow-all --yolo --allow-all-tools --allow-all-paths --allow-all-urls --no-ask-user --disable-builtin-mcps --continue --acp --autopilot --plan --fleet --share-gist --remote --remote-export --no-auto-update --banner)
  test "every reserved argument, separate and equals forms" do
    for name <- @values, args <- [[name, "value"], [name <> "=value"]] do
      assert {[], [^name]} = Args.filter(args)
    end

    for name <- @switches, arg <- [name, name <> "=true"] do
      assert {[], [^name]} = Args.filter([arg])
    end
  end

  test "optional values preserve next flag, secret vars consume all values" do
    for name <- ~w(--connect -r --resume --share),
        do:
          assert(
            {["--no-custom-instructions"], [name]} ==
              Args.filter([name, "--no-custom-instructions"])
          )

    assert {["--add-dir", "/data", "--no-custom-instructions"],
            ["--enable-mcp-server", "--secret-env-vars"]} =
             Args.filter([
               "--add-dir",
               "/data",
               "--enable-mcp-server=github",
               "--secret-env-vars",
               "A",
               "B",
               "--no-custom-instructions"
             ])

    assert {["--deny-tool", "shell"], ["--secret-env-vars"]} =
             Args.filter(["--secret-env-vars=A", "B", "--deny-tool", "shell"])
  end
end
