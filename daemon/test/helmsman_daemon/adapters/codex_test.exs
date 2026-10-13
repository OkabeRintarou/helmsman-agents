defmodule HelmsmanDaemon.Adapters.CodexTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex

  test "start and resume request full access without approvals", %{tmp_dir: dir} do
    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: [
              "-c",
              ~s(model_provider="test"),
              "-c",
              ~s(model_providers.test.name="Test")
            ]
        }
    }

    for resume <- [nil, "session"] do
      assert {:ok, launch} = Codex.prepare(%{run | resume_session_id: resume}, dir, dir)
      frame = launch.stdin |> List.last() |> JSON.decode!()
      assert frame["method"] == if(resume, do: "thread/resume", else: "thread/start")
      assert frame["params"]["approvalPolicy"] == "never"
      assert frame["params"]["sandbox"] == "danger-full-access"
    end
  end

  test "bubblewrap startup stderr produces no events and does not change finish" do
    state = Codex.init_state(spec(1))
    before = Codex.finish(0, state)

    line =
      "ERROR codex_app_server: Codex's Linux sandbox uses bubblewrap and needs access to create user namespaces."

    assert {[], [], after_state} = Codex.handle_output(:stderr, line, state)
    assert after_state.stderr == [line]
    assert Codex.finish(0, after_state) == before
  end
end
