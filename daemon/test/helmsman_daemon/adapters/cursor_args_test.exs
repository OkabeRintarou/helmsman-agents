defmodule HelmsmanDaemon.Adapters.CursorArgsTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Cursor.Args

  test "the spec example" do
    assert Args.filter(["--add-dir", "/data", "--approve-mcps", "--api-key=k", "-H", "X-Team: a"]) ==
             {["--add-dir", "/data", "-H", "X-Team: a"], ["--approve-mcps", "--api-key"]}
  end

  @valued ~w(--output-format --model --new-session-id --api-key --auth-token --sandbox --workspace --mode --worktree-base --plugin-dir --data-dir -e --endpoint)
  @switches ~w(-p --print --stream-partial-output -f --force --yolo --approve-mcps --trust --continue --plan --auto-review --skip-worktree-setup --disable-project-configs --disable-codebase-ref --list-models)

  for flag <- @valued do
    test "#{flag} is removed with its value, both forms" do
      flag = unquote(flag)
      assert Args.filter([flag, "v", "--keep"]) == {["--keep"], [flag]}
      assert Args.filter([flag <> "=v", "--keep"]) == {["--keep"], [flag]}
    end
  end

  for flag <- @switches do
    test "#{flag} is removed alone" do
      flag = unquote(flag)
      assert Args.filter([flag, "--keep", "v"]) == {["--keep", "v"], [flag]}
    end
  end

  for flag <- ~w(--resume -w --worktree) do
    test "#{flag} takes an optional value" do
      flag = unquote(flag)
      assert Args.filter([flag, "id", "--keep"]) == {["--keep"], [flag]}
      assert Args.filter([flag, "--keep"]) == {["--keep"], [flag]}
      assert Args.filter([flag <> "=id"]) == {[], [flag]}
      assert Args.filter([flag]) == {[], [flag]}
    end
  end
end
