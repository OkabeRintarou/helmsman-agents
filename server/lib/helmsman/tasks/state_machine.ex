defmodule Helmsman.Tasks.StateMachine do
  @moduledoc """
  The task state machine (designs/05 §2): the transition table and the
  checks a transition must pass. Pure functions, no database access;
  `Helmsman.Tasks.transition/4` collects the context and applies the result.

  | from          | to                                   |
  |---------------|--------------------------------------|
  | `new`         | `in_progress`, `rejected`, `cancelled` |
  | `in_progress` | `done`, `rejected`, `cancelled`      |
  | `done`        | `verified`, `in_progress`            |
  | `verified`    | `in_progress`                        |
  | `rejected`    | `new`                                |
  | `cancelled`   | `new`                                |
  """

  alias Helmsman.Tasks.Task

  @type status :: Task.status()

  @typedoc """
  What `check/3` needs besides the two statuses:

    * `blockers` - IDs of unmet dependencies (`new → in_progress`)
    * `replaced_by` - IDs of the tasks replacing this one (`cancelled → new`)
    * `active_run` - another run still working on the task, excluding the
      one making the transition (`done → verified`)
    * `self_verify?` - the acting identity is the task's assignee
    * `has_passing_tests?` - this transition, or the latest one to `done`,
      carries tests with `passed: true`
    * `assignee_name` - reported by `self_verify_requires_tests`
  """
  @type ctx :: %{
          blockers: [String.t()],
          replaced_by: [String.t()],
          active_run: term(),
          self_verify?: boolean(),
          has_passing_tests?: boolean(),
          assignee_name: String.t() | nil
        }

  @type reason ::
          {:invalid_transition, status(), status(), [status()]}
          | {:blocked, [String.t()]}
          | {:replaced, [String.t()]}
          | {:run_active, term()}
          | {:self_verify_requires_tests, String.t() | nil}

  @transitions %{
    new: [:in_progress, :rejected, :cancelled],
    in_progress: [:done, :rejected, :cancelled],
    done: [:verified, :in_progress],
    verified: [:in_progress],
    rejected: [:new],
    cancelled: [:new]
  }

  @by_name Map.new(Task.statuses(), &{Atom.to_string(&1), &1})
  @aliases %{"reject" => :rejected, "canceled" => :cancelled}

  @doc "The statuses a task in `from` may move to."
  @spec allowed(status()) :: [status()]
  def allowed(from) when is_map_key(@transitions, from), do: Map.fetch!(@transitions, from)

  @doc """
  Parses a target status given by a person or an agent: case-insensitive,
  surrounding blanks ignored, spaces and dashes read as underscores, plus
  the aliases `reject` and `canceled`. Atoms are accepted too.

      iex> Helmsman.Tasks.StateMachine.normalize(" In Progress ")
      {:ok, :in_progress}

      iex> Helmsman.Tasks.StateMachine.normalize("canceled")
      {:ok, :cancelled}
  """
  @spec normalize(term()) :: {:ok, status()} | {:error, {:invalid_status, term(), [status()]}}
  def normalize(input) when is_atom(input) and not is_nil(input) and not is_boolean(input),
    do: input |> Atom.to_string() |> lookup(input)

  def normalize(input) when is_binary(input), do: lookup(input, input)
  def normalize(input), do: invalid_status(input)

  defp lookup(string, input) do
    key = string |> String.trim() |> String.downcase() |> String.replace([" ", "-"], "_")

    case Map.get(@by_name, key) || Map.get(@aliases, key) do
      nil -> invalid_status(input)
      status -> {:ok, status}
    end
  end

  defp invalid_status(input), do: {:error, {:invalid_status, input, Task.statuses()}}

  @doc """
  Checks the transition `from → to` in `ctx`, in this order: the
  transition table, unmet dependencies (`new → in_progress`), replacement
  (`cancelled → new`), another active run (`done → verified`) and the
  self-verification rule (`done → verified` by the assignee needs passing
  tests).
  """
  @spec check(status(), status(), ctx()) :: :ok | {:error, reason()}
  def check(from, to, ctx) when is_map(ctx) do
    allowed = allowed(from)

    if to in allowed,
      do: check_extra(from, to, ctx),
      else: {:error, {:invalid_transition, from, to, allowed}}
  end

  defp check_extra(:new, :in_progress, %{blockers: [_ | _] = blockers}),
    do: {:error, {:blocked, blockers}}

  defp check_extra(:cancelled, :new, %{replaced_by: [_ | _] = replaced_by}),
    do: {:error, {:replaced, replaced_by}}

  defp check_extra(:done, :verified, ctx), do: check_verify(ctx)
  defp check_extra(_from, _to, _ctx), do: :ok

  defp check_verify(%{active_run: run}) when not is_nil(run), do: {:error, {:run_active, run}}

  defp check_verify(%{self_verify?: true, has_passing_tests?: passing} = ctx)
       when passing != true,
       do: {:error, {:self_verify_requires_tests, ctx.assignee_name}}

  defp check_verify(_ctx), do: :ok
end
