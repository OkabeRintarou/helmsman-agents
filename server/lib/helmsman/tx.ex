defmodule Helmsman.Tx do
  @moduledoc """
  The single entry point for domain write transactions.

  `run/2` opens the outermost transaction and keeps a queue of callbacks
  registered with `after_commit/1`. Nested `run/2` calls join the current
  transaction and append to the same queue. The callbacks run in
  registration order only after the outermost transaction commits; on
  rollback (an `{:error, _}` result or an exception) they are discarded.
  """

  require Logger

  alias Helmsman.Repo

  @queue {__MODULE__, :after_commit}
  @retryable [:deadlock_detected, :serialization_failure]

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Runs `fun` in a transaction; see the module documentation.

  `fun` must return `{:ok, value}` or `{:error, reason}`, which is returned.
  Inside a nested call, an `{:error, _}` result marks the whole outer
  transaction for rollback (Ecto's nested transaction semantics).

  ## Options

    * `:retry` - how many times the outermost transaction is run again
      after a deadlock or serialization failure (default `0`). Each attempt
      starts with an empty callback queue; when the retries are used up the
      result is `{:error, code}` (without retries the error is raised). Only the database transaction is retried,
      never the callbacks that run after the commit. Ignored when joining
      an outer transaction, which cannot be retried from inside.
  """
  @spec run((-> result()), keyword()) :: result()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      Repo.transact(fun)
    else
      case transact(fun, Keyword.get(opts, :retry, 0), 0) do
        {{:ok, _} = result, callbacks} ->
          Enum.each(callbacks, &run_callback/1)
          result

        {result, _callbacks} ->
          result
      end
    end
  end

  # Without the :retry option a retryable failure is raised as before.
  defp transact(fun, retries, attempt_no) do
    case attempt(fun) do
      {:retry, _error, _stacktrace} when retries > 0 -> transact(fun, retries - 1, attempt_no + 1)
      {:retry, error, stacktrace} when attempt_no == 0 -> reraise error, stacktrace
      {:retry, error, _stacktrace} -> {{:error, error.postgres.code}, []}
      done -> done
    end
  end

  # Returns the transaction result with the callbacks it registered, or
  # `{:retry, error, stacktrace}` after a retryable failure (nothing was
  # committed).
  defp attempt(fun) do
    Process.put(@queue, [])

    try do
      result = Repo.transact(fun)
      {result, @queue |> Process.get() |> Enum.reverse()}
    rescue
      error in Postgrex.Error ->
        case error.postgres do
          %{code: code} when code in @retryable -> {:retry, error, __STACKTRACE__}
          _ -> reraise error, __STACKTRACE__
        end
    after
      Process.delete(@queue)
    end
  end

  # The transaction has committed: a failing side effect is logged and must
  # neither stop the remaining callbacks nor turn the result into an error.
  defp run_callback(callback) do
    callback.()
  catch
    kind, reason ->
      Logger.error(
        "after_commit callback failed after the transaction committed:\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  @doc """
  Registers a zero-arity function to run after the outermost transaction
  started by `run/2` commits.

  Raises if there is no such transaction, including inside a transaction
  that was opened with `Repo.transact/2` directly.
  """
  @spec after_commit((-> any())) :: :ok
  def after_commit(fun) when is_function(fun, 0) do
    case Process.get(@queue) do
      queue when is_list(queue) ->
        Process.put(@queue, [fun | queue])
        :ok

      nil ->
        raise "Helmsman.Tx.after_commit/1 must be called inside a transaction " <>
                "started by Helmsman.Tx.run/2"
    end
  end
end
