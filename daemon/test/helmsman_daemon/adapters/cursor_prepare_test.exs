defmodule HelmsmanDaemon.Adapters.CursorPrepareTest do
  use HelmsmanDaemon.Case
  import ExUnit.CaptureLog
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Cursor
  alias HelmsmanDaemon.Adapters.Cursor.Home
  @fixtures Path.expand("../../fixtures/cursor", __DIR__)

  setup %{tmp_dir: dir} do
    File.write!(Path.join(Paths.home(), "config.toml"), "[cursor]\nenabled = true\n")
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    %{work: work}
  end

  defp cursor_spec(id, fields \\ []) do
    run = spec(id)

    agent =
      struct!(%{run.agent | provider: :cursor, custom_args: []}, Keyword.get(fields, :agent, []))

    struct!(%{run | agent: agent}, Keyword.delete(fields, :agent))
  end

  defp prepare(run, work),
    do: Cursor.prepare(run, Paths.private_dir!(Paths.run(run.run_id)), work, %{})

  test "a new session: fixed arguments, auto model, a new UUID, prompt on stdin", %{work: work} do
    assert {:ok, launch} = prepare(cursor_spec(1, prompt: "do it"), work)
    [executable | args] = launch.argv
    assert Path.basename(executable) == "cursor-agent"

    assert [
             "-p",
             "--force",
             "--output-format",
             "stream-json",
             "--sandbox",
             "disabled",
             "--disable-codebase-ref",
             "--disable-project-configs",
             "--model",
             "auto",
             "--new-session-id",
             uuid
           ] = args

    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    refute Enum.any?(args, &(&1 in ["--approve-mcps", "--api-key", "do it"]))
    assert launch.stdin == "do it"
    assert launch.close_stdin?
    assert launch.track_descendants
    assert Cursor.init_state(cursor_spec(1), launch).session_id == uuid
  end

  test "model and filtered custom arguments", %{work: work} do
    run =
      cursor_spec(2, agent: [model: "composer-2.5", custom_args: ["--trust", "--add-dir", "/d"]])

    assert {:ok, launch} = prepare(run, work)
    assert Enum.drop(launch.argv, 9) |> Enum.take(2) == ["--model", "composer-2.5"]
    assert Enum.take(launch.argv, -2) == ["--add-dir", "/d"]

    assert {:status, %{level: :warning, message: "Ignored conflicting Cursor arguments: --trust"}} in launch.events
  end

  test "resuming checks the recorded chat under the resolved working directory", %{
    tmp_dir: dir,
    work: work
  } do
    id = "80e9e111-3d1a-4b0c-9a65-0123456789ab"
    link = Path.join(dir, "link")
    File.ln_s!(work, link)

    assert {:error, {:cli_error, message}} = prepare(cursor_spec(3, resume_session_id: id), link)
    assert message =~ "can no longer be resumed"
    refute File.exists?(Path.join(Paths.run(3), "home"))

    # The recorded layout (live test R1): chats/<md5(resolved cwd)>/<id>/meta.json
    chat = Path.join([Home.config_dir(), "chats", md5(work), id])
    File.mkdir_p!(chat)
    File.cp!(Path.join(@fixtures, "session_meta.json"), Path.join(chat, "meta.json"))

    assert {:ok, launch} = prepare(cursor_spec(4, resume_session_id: id), link)
    assert Enum.take(launch.argv, -2) == ["--resume", id]
    refute "--new-session-id" in launch.argv
    assert Home.chat_key(link) == md5(work)
  end

  test "an invalid chat ID is never looked up as a path", %{work: work} do
    assert {:error, {:cli_error, _}} = prepare(cursor_spec(5, resume_session_id: "../x"), work)
  end

  test "Cursor off: preparation fails closed", %{work: work} do
    File.rm!(Path.join(Paths.home(), "config.toml"))
    assert {:error, {:cli_error, message}} = prepare(cursor_spec(6), work)
    assert message =~ "[cursor] enabled = true"
  end

  defp md5(path), do: :crypto.hash(:md5, path) |> Base.encode16(case: :lower)

  test "local references expand in private HOME with 0600 and safe missing warnings", %{
    work: work
  } do
    run =
      cursor_spec(20,
        agent: [
          extra_mcp_servers: %{
            "good" => %{"command" => "npx", "env" => %{"TOKEN" => "${env:CANARY}"}},
            "missing" => %{"command" => "${env:NOT_SET}"}
          }
        ]
      )

    dir = Paths.private_dir!(Paths.run(20))

    {result, log} =
      with_log(fn -> Cursor.prepare(run, dir, work, %{"CANARY" => "CANARY_CURSOR_VALUE"}) end)

    assert {:ok, launch} = result
    refute log =~ "CANARY_CURSOR_VALUE"
    path = Path.join([dir, "home", ".cursor", "mcp.json"])
    config = JSON.decode!(File.read!(path))["mcpServers"]
    assert config["good"]["env"]["TOKEN"] == "CANARY_CURSOR_VALUE"
    refute Map.has_key?(config, "missing")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert [{:status, %{level: :warning, message: message}}] = launch.events
    assert message =~ "NOT_SET"
    refute inspect(launch.events) =~ "CANARY_CURSOR_VALUE"
  end
end
