defmodule HelmsmanDaemon.MemoryKeychain do
  @moduledoc """
  In-memory `HelmsmanDaemon.Keychain` with fault injection, for the keychain
  write protocol tests on every platform. Configure with
  `{HelmsmanDaemon.MemoryKeychain, agent: pid}`.

  `fault(kc, op, result, when: fn account -> bool end, times: n)` makes `op`
  (`:add`, `:find`, `:delete`) return `result` instead of acting; for `:add`,
  `{:created, error}` creates the item and still returns `error`.
  """
  @behaviour HelmsmanDaemon.Keychain
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{items: %{}, faults: [], log: []} end)

  def fault(kc, op, result, opts \\ []) do
    fault = %{
      op: op,
      result: result,
      when: Keyword.get(opts, :when, fn _ -> true end),
      times: Keyword.get(opts, :times, :infinity)
    }

    Agent.update(kc, &%{&1 | faults: &1.faults ++ [fault]})
  end

  def clear_faults(kc), do: Agent.update(kc, &%{&1 | faults: []})
  def items(kc), do: Agent.get(kc, & &1.items)
  def log(kc), do: Agent.get(kc, &Enum.reverse(&1.log))
  def put(kc, account, token), do: Agent.update(kc, &put_in(&1.items[account], token))

  @impl true
  def add(_service, account, token, opts) do
    call(opts, :add, account, fn items ->
      if Map.has_key?(items, account),
        do: {{:error, :duplicate}, items},
        else: {:ok, Map.put(items, account, token)}
    end)
  end

  @impl true
  def find(_service, account, opts) do
    call(opts, :find, account, fn items ->
      case Map.fetch(items, account) do
        {:ok, token} -> {{:ok, token}, items}
        :error -> {{:error, :not_found}, items}
      end
    end)
  end

  @impl true
  def delete(_service, account, opts) do
    call(opts, :delete, account, fn items ->
      if Map.has_key?(items, account),
        do: {:ok, Map.delete(items, account)},
        else: {{:error, :not_found}, items}
    end)
  end

  defp call(opts, op, account, action) do
    Agent.get_and_update(opts[:agent], fn state ->
      state = %{state | log: [{op, account} | state.log]}

      case take_fault(state.faults, op, account) do
        {nil, _} ->
          {result, items} = action.(state.items)
          {result, %{state | items: items}}

        {%{result: {:created, error}}, faults} ->
          {_, items} = action.(state.items)
          {error, %{state | items: items, faults: faults}}

        {%{result: result}, faults} ->
          {result, %{state | faults: faults}}
      end
    end)
  end

  defp take_fault(faults, op, account) do
    case Enum.find_index(faults, &(&1.op == op and &1.when.(account))) do
      nil ->
        {nil, faults}

      index ->
        fault = Enum.at(faults, index)

        faults =
          case fault.times do
            :infinity -> faults
            1 -> List.delete_at(faults, index)
            n -> List.replace_at(faults, index, %{fault | times: n - 1})
          end

        {fault, faults}
    end
  end
end
