defmodule Mix.Tasks.Helmsman.BootstrapTest do
  # Replaces the global Mix shell.
  use Helmsman.DataCase, async: false

  alias Mix.Tasks.Helmsman.Bootstrap, as: Task

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp run_failing(args) do
    assert catch_exit(Task.run(args)) == {:shutdown, 1}
    assert_received {:mix_shell, :error, [message]}
    message
  end

  test "prints the usage and exits non-zero when arguments are missing or unknown" do
    for args <- [
          [],
          ["--email", "you@x.com"],
          ["--workspace", "acme"],
          ["--email", "a@x", "--workspace", "w", "extra"],
          ["--bogus", "1"]
        ] do
      assert run_failing(args) =~ "usage: mix helmsman.bootstrap --email"
    end
  end

  test "prints a login link on success" do
    Task.run(["--email", "you@x.com", "--workspace", "acme", "--name", "Acme Inc."])

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "User: you@x.com (created)"
    assert output =~ "Workspace: acme (created)"
    assert output =~ HelmsmanWeb.Endpoint.url() <> "/users/log-in/"
  end

  test "exits non-zero when the workspace belongs to someone else" do
    Task.run(["--email", "you@x.com", "--workspace", "acme"])
    assert_received {:mix_shell, :info, _}

    assert run_failing(["--email", "other@x.com", "--workspace", "acme"]) =~
             "is not a member"
  end

  test "exits non-zero on invalid input" do
    assert run_failing(["--email", "you@x.com", "--workspace", "acme_inc"]) =~
             "invalid input: slug"
  end
end
