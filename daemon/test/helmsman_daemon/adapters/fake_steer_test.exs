defmodule HelmsmanDaemon.Adapters.FakeSteerTest do
  # add-run-steering 2.2: the fake adapter's steering modes.
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Fake

  defp state(mode) do
    run = spec(1)
    Fake.init_state(%{run | agent: %{run.agent | custom_args: ["success" | List.wrap(mode)]}})
  end

  test "unsupported by default" do
    assert Fake.steer(31, "x", state(nil)) == :unsupported
    assert Fake.steer(31, "x", state("unsupported")) == :unsupported
  end

  test "delivered: one line, taken once written" do
    assert {:ok, line, :delivered, _} = Fake.steer(31, ~s(a\nb "q"), state("delivered"))
    assert line == ~S(steer 31 "a\nb \"q\"") <> "\n"
  end

  test "pending: steer_ok confirms, steer_rejected rejects, unknown refs are ignored" do
    assert {:ok, ~s(steer 31 "x"\n), :pending, st} = Fake.steer(31, "x", state("pending"))
    assert {:ok, _, :pending, st} = Fake.steer(32, "y", st)

    assert {[{:status, %{level: :info}}], [{:steer_result, 31, :delivered}], st} =
             Fake.handle_output(:stdout, "steer_ok 31", st)

    assert {[], [], ^st} = Fake.handle_output(:stdout, "steer_ok 31", st)

    assert {[{:status, %{level: :warning, message: "steer rejected: no turn"}}],
            [{:steer_result, 32, {:rejected, "no turn"}}], st} =
             Fake.handle_output(:stdout, "steer_rejected 32 no turn", st)

    assert MapSet.size(st.pending_steers) == 0
  end

  test "a steering mode keeps stdin open" do
    run = spec(1)
    run = %{run | agent: %{run.agent | custom_args: ["success", "pending"]}}
    assert {:ok, %{close_stdin?: false}} = Fake.prepare(run, "/tmp", "/tmp")
    assert {:ok, %{close_stdin?: true}} = Fake.prepare(spec(1), "/tmp", "/tmp")
  end
end
