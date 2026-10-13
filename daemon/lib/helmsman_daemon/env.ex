defmodule HelmsmanDaemon.Env do
  @moduledoc "Removes inherited session state before launching daemon subprocesses."

  def inherited_drop?(name) do
    String.starts_with?(name, ["GIT_", "VSCODE_"]) or
      name in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"]
  end

  def child_drop?(name), do: inherited_drop?(name) or String.starts_with?(name, "HELMSMAN_")

  def child(base \\ System.get_env()) do
    base |> Map.new() |> Map.reject(fn {name, _} -> child_drop?(name) end)
  end

  def agent(base, overrides) do
    allowed = Map.reject(overrides, fn {name, _} -> String.starts_with?(name, "HELMSMAN_") end)
    base |> child() |> Map.put("GIT_TERMINAL_PROMPT", "0") |> Map.merge(allowed)
  end

  def scrub_process! do
    names = System.get_env() |> Map.keys() |> Enum.filter(&inherited_drop?/1) |> Enum.sort()
    Enum.each(names, &System.delete_env/1)

    if names != [] do
      IO.puts(:stderr, "Ignoring inherited environment variables: #{Enum.join(names, ", ")}")
    end

    names
  end

  def cmd(command, args, opts \\ []) do
    deleted = for {name, _} <- System.get_env(), child_drop?(name), do: {name, nil}
    overrides = Keyword.get(opts, :env, [])
    System.cmd(command, args, Keyword.put(opts, :env, deleted ++ Enum.to_list(overrides)))
  end
end
