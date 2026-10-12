defmodule HelmsmanDaemon.E2EControlTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{AtomicFile, E2EControl}

  test "kill acknowledgement waits for the requested worker to exit", %{tmp_dir: dir} do
    start_execution()
    {:ok, target} = Runs.start_run(spec(801, "stalled"), reporter: TestReporter)
    {:ok, other} = Runs.start_run(spec(802, "stalled"), reporter: TestReporter)
    assert_receive {:report, 801, %Report.Started{}, _, _, _}
    assert_receive {:report, 802, %Report.Started{}, _, _, _}
    start_supervised!({E2EControl, directory: dir})

    path = Path.join(dir, "kill.json")
    :ok = AtomicFile.write(path, Jason.encode!(%{op: "kill_run", run_id: 801}))
    eventually(fn -> File.exists?(Path.join(dir, "kill.reply.json")) end)
    reply = File.read!(Path.join(dir, "kill.reply.json")) |> Jason.decode!()
    assert reply == %{"status" => "killed", "run_id" => 801}
    refute Process.alive?(target)
    assert Process.alive?(other)
    refute File.exists?(path)

    path = Path.join(dir, "missing.json")
    :ok = AtomicFile.write(path, Jason.encode!(%{op: "kill_run", run_id: 999}))
    eventually(fn -> File.exists?(Path.join(dir, "missing.reply.json")) end)

    assert File.read!(Path.join(dir, "missing.reply.json")) |> Jason.decode!() ==
             %{"status" => "not_found", "run_id" => 999}

    Runs.cancel(802)
    assert_receive {:report, 802, %Report.Finished{status: :cancelled}, _, _, _}, 2_000
  end
end
