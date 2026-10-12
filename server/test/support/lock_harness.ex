defmodule Helmsman.LockHarness do
  @moduledoc """
  Interleaves transactions on connections of their own (outside the SQL
  sandbox) for lock-order tests: each side is started with `start/2`,
  may pause at a test hook (`Helmsman.Daemons.Locking.hook/1`) or right
  before its commit, and is resumed with `continue/1`.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions

  alias Helmsman.{CommittedData, Tx}

  @wait 5_000

  @doc """
  Runs `fun` in a task on its own connection, inside an outer transaction
  without retries (a deadlock is an error, not retried away). Options:
  `pause: point` stops at the test hook `point`, `pause: :commit` before
  the commit, until `continue/1`. A `Postgrex.Error` is returned as
  `{:raised, code}`.
  """
  def start(fun, opts \\ []) do
    parent = self()
    pause = opts[:pause]

    task = Task.async(fn -> CommittedData.unboxed(fn -> side(fun, parent, pause) end) end)

    assert_receive {:backend, pid, backend}, @wait
    %{task: task, pid: pid, backend: backend}
  end

  defp side(fun, parent, pause) do
    send(parent, {:backend, self(), CommittedData.backend_pid()})
    if pause && pause != :commit, do: install_pause(parent, pause)

    # An `{:error, _}` from a nested domain transaction rolls the outer one
    # back; its own result is still the side's result.
    Tx.run(fn ->
      result = fun.()
      Process.put({__MODULE__, :result}, result)
      if pause == :commit, do: pause!(parent)
      {:ok, result}
    end)

    Process.get({__MODULE__, :result})
  rescue
    error in Postgrex.Error -> {:raised, error.postgres.code}
  end

  defp install_pause(parent, point) do
    Process.put(:helmsman_test_hook, fn
      ^point -> pause!(parent)
      _other -> :ok
    end)
  end

  defp pause!(parent) do
    send(parent, {:paused, self()})

    receive do
      :continue -> :ok
    end
  end

  @doc "Waits until the side has paused."
  def await_paused(%{pid: pid}), do: assert_receive({:paused, ^pid}, @wait)

  @doc "Waits until the side is blocked on a lock."
  def await_blocked(%{backend: backend}), do: CommittedData.await_lock_wait(backend)

  @doc "Resumes a paused side."
  def continue(%{pid: pid}), do: send(pid, :continue)

  @doc "The side's result."
  def result(%{task: task}), do: Task.await(task, @wait)

  @doc """
  `first` pauses (at its hook or before its commit), `second` starts and
  blocks on a lock `first` holds, then `first` goes on. Returns both
  results.
  """
  def interleave(first, first_pause, second) do
    a = start(first, pause: first_pause)
    await_paused(a)
    b = start(second)
    await_blocked(b)
    continue(a)
    {result(a), result(b)}
  end
end
