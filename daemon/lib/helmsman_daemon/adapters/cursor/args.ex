defmodule HelmsmanDaemon.Adapters.Cursor.Args do
  @moduledoc "Removes `custom_args` that conflict with the protocol or isolation (`add-cursor-adapter` decision 8)."

  @valued ~w(--output-format --model --new-session-id --api-key --auth-token --sandbox --workspace --mode --worktree-base --plugin-dir --data-dir -e --endpoint)
  @optional ~w(--resume -w --worktree)
  @switches ~w(-p --print --stream-partial-output -f --force --yolo --approve-mcps --trust --continue --plan --auto-review --skip-worktree-setup --disable-project-configs --disable-codebase-ref --list-models)

  @doc "`{kept, removed flag names}`; both `--flag value` and `--flag=value`."
  def filter(args), do: filter(args, [], [])

  defp filter([], kept, removed), do: {Enum.reverse(kept), Enum.uniq(Enum.reverse(removed))}

  defp filter([arg | rest], kept, removed) do
    flag = arg |> String.split("=", parts: 2) |> hd()
    inline? = String.contains?(arg, "=")

    cond do
      flag in @valued ->
        filter(if(inline?, do: rest, else: Enum.drop(rest, 1)), kept, [flag | removed])

      flag in @optional ->
        filter(if(inline?, do: rest, else: drop_value(rest)), kept, [flag | removed])

      flag in @switches ->
        filter(rest, kept, [flag | removed])

      true ->
        filter(rest, [arg | kept], removed)
    end
  end

  defp drop_value([value | rest]),
    do: if(String.starts_with?(value, "-"), do: [value | rest], else: rest)

  defp drop_value([]), do: []
end
