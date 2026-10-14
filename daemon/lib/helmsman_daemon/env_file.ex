defmodule HelmsmanDaemon.EnvFile do
  @moduledoc """
  `<home>/daemon.env`: environment variables for the background service, which
  does not inherit the user's shell.

  One `KEY=VALUE` per line; lines starting with `#` and blank lines are
  ignored; the value is everything after the first `=`, taken literally (no
  quotes, no shell expansion). Only variables missing from the environment are
  set; `HELMSMAN_*` names are ignored. The file is not read when its mode grants
  any group or other permission. The daemon's usual scrubbing (`Env`) runs
  afterwards.
  """
  require Logger
  alias HelmsmanDaemon.Paths

  @name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  def path, do: Path.join(Paths.home(), "daemon.env")

  @doc "Parses contents into `{variables, ignored_line_numbers}`."
  def parse(contents) do
    {vars, ignored} =
      contents
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, number}, {vars, ignored} ->
        case parse_line(String.trim_leading(line)) do
          :skip -> {vars, ignored}
          {:ok, pair} -> {[pair | vars], ignored}
          :error -> {vars, [number | ignored]}
        end
      end)

    {Enum.reverse(vars), Enum.reverse(ignored)}
  end

  defp parse_line(""), do: :skip
  defp parse_line("#" <> _), do: :skip

  defp parse_line(line) do
    with [name, value] <- String.split(line, "=", parts: 2),
         name = String.trim_trailing(name),
         true <- name =~ @name do
      {:ok, {name, value}}
    else
      _ -> :error
    end
  end

  @doc """
  Reads the file and applies it to the process environment. Returns
  `{:ok, applied_names}`, `{:error, :insecure}` or `{:error, :enoent}`.
  """
  def load do
    case read() do
      {:ok, vars, ignored} ->
        Enum.each(ignored, &Logger.warning("daemon.env line #{&1} ignored: expected KEY=VALUE"))

        applied =
          for {name, value} <- vars,
              not String.starts_with?(name, "HELMSMAN_"),
              System.get_env(name) == nil do
            System.put_env(name, value)
            name
          end

        {:ok, applied}

      {:error, :insecure} = error ->
        Logger.warning(
          "daemon.env is not read: its permissions must be 0600 (chmod 600 #{path()})"
        )

        error

      error ->
        error
    end
  end

  @doc "Variable names defined in the file, or `{:error, reason}` (:enoent, :insecure)."
  def names do
    case read() do
      {:ok, vars, _ignored} -> {:ok, Enum.map(vars, &elem(&1, 0))}
      error -> error
    end
  end

  defp read do
    path = path()

    with {:ok, stat} <- File.stat(path),
         :ok <- private(stat),
         {:ok, contents} <- File.read(path) do
      {vars, ignored} = parse(contents)
      {:ok, vars, ignored}
    end
  end

  defp private(%File.Stat{type: :regular, mode: mode}) do
    if Bitwise.band(mode, 0o077) == 0, do: :ok, else: {:error, :insecure}
  end

  defp private(_), do: {:error, :insecure}
end
