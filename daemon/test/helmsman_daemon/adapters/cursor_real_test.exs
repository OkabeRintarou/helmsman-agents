defmodule HelmsmanDaemon.Adapters.CursorRealTest do
  @moduledoc """
  Real `cursor-agent` smoke test (not in CI): new session, resume, stop.
  Needs `CURSOR_API_KEY` and `HELMSMAN_REAL_CLI=1`. Runs in a temporary
  daemon home and user `HOME`; prints the stopped run's tagged processes
  (live test R3).
  """
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  @moduletag :real_cli
  @moduletag timeout: 600_000
  alias HelmsmanDaemon.Adapters.Cursor
  alias HelmsmanDaemon.ProcScan

  setup do
    File.write!(Path.join(Paths.home(), "config.toml"), "[cursor]\nenabled = true\n")
    start_execution()
    :ok
  end

  defp run(id, prompt, fields \\ []) do
    run = spec(id)

    run = %{
      struct!(run, fields)
      | prompt: prompt,
        agent: %{run.agent | provider: :cursor, custom_args: []},
        limits: %{run.limits | timeout_ms: 300_000, idle_timeout_ms: 240_000}
    }

    {:ok, _} = Runs.start_run(run, adapter: Cursor, reporter: TestReporter)
    run
  end

  defp await(id, events \\ [], until \\ fn _ -> false end) do
    receive do
      {:report, ^id, %Report.Events{events: batch}, _, _, _} ->
        events = events ++ batch
        if until.(events), do: {:running, events}, else: await(id, events, until)

      {:report, ^id, %Report.Finished{} = finished, _, _, _} ->
        {finished, events}

      {:report, ^id, _, _, _, _} ->
        await(id, events, until)
    after
      300_000 -> flunk("Cursor run #{id} did not finish")
    end
  end

  defp tagged do
    for dir <- Path.wildcard("/proc/[0-9]*"),
        {:ok, env} <- [File.read(Path.join(dir, "environ"))],
        String.contains?(env, ProcScan.var() <> "="),
        do:
          {String.to_integer(Path.basename(dir)), String.trim(File.read!(Path.join(dir, "comm")))}
  end

  test "new session, resume, stop" do
    assert System.get_env("CURSOR_API_KEY") not in [nil, ""], "set CURSOR_API_KEY"
    assert {:ok, %{version: version}} = Cursor.detect()
    IO.puts("cursor-agent #{version}")

    run(1, "Reply exactly with the word PELICAN and nothing else.")
    {finished, _} = await(1)
    assert finished.status == :succeeded, inspect(finished)
    assert finished.summary =~ "PELICAN"
    session = finished.session_id
    # Natural end: worker-server and every other tagged process went first.
    assert tagged() == []
    assert session =~ ~r/\A[0-9a-f-]{36}\z/

    run(2, "Which word did you reply with last time? Reply with that word only.",
      resume_session_id: session
    )

    {finished, _} = await(2)
    assert finished.status == :succeeded, inspect(finished)
    assert finished.session_id == session
    assert finished.summary =~ "PELICAN"

    run(3, "Run the shell command `sleep 30` and wait for it, then reply DONE.")

    shell? = fn events ->
      Enum.any?(events, &match?(%{type: :tool_call, data: %{name: "shell"}}, &1))
    end

    {:running, _} = await(3, [], shell?)
    Process.sleep(1_000)
    before = tagged()

    for {pid, comm} <- before do
      {:ok, stat} = ProcScan.stat(File.read!("/proc/#{pid}/stat"))
      cmd = File.read!("/proc/#{pid}/cmdline") |> String.replace(<<0>>, " ") |> Path.basename()

      IO.puts(
        "tagged: pid #{pid} comm #{comm} ppid #{stat.ppid} pgrp #{stat.pgrp} sid #{stat.sid} cmd #{String.slice(cmd, 0, 60)}"
      )
    end

    assert Enum.any?(before, &match?({_, "sleep"}, &1))
    Runs.cancel(3)
    {finished, _} = await(3)
    assert finished.status == :cancelled
    left = Enum.filter(before, fn {pid, _} -> alive?(pid) end)
    IO.puts("still alive after finished: #{inspect(left)}")
    assert left == []
  end
end
