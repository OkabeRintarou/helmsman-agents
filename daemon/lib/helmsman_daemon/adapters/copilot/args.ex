defmodule HelmsmanDaemon.Adapters.Copilot.Args do
  @moduledoc false
  @values ~w(-p --prompt -i --interactive --output-format --additional-mcp-config --enable-mcp-server --mcp-github-auth --session-id --model --reasoning-effort --log-dir --usage-output-file --plugin-dir --mode -C --connect -r --resume --share)
  @switches ~w(--allow-all --yolo --allow-all-tools --allow-all-paths --allow-all-urls --no-ask-user --disable-builtin-mcps --continue --acp --autopilot --plan --fleet --share-gist --remote --remote-export --no-auto-update --banner)

  def filter(args), do: filter(args, [], [])
  defp filter([], kept, removed), do: {Enum.reverse(kept), Enum.reverse(Enum.uniq(removed))}

  defp filter([arg | rest], kept, removed) do
    [name | inline] = String.split(arg, "=", parts: 2)

    cond do
      name == "--secret-env-vars" ->
        rest = Enum.drop_while(rest, &(not String.starts_with?(&1, "-")))
        filter(rest, kept, [name | removed])

      name in @values ->
        filter(skip_value(rest, inline), kept, [name | removed])

      name in @switches ->
        filter(rest, kept, [name | removed])

      true ->
        filter(rest, [arg | kept], removed)
    end
  end

  defp skip_value([value | rest], []) do
    if String.starts_with?(value, "-"), do: [value | rest], else: rest
  end

  defp skip_value(rest, _), do: rest
end
