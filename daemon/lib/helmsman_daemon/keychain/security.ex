defmodule HelmsmanDaemon.Keychain.Security do
  @moduledoc """
  `HelmsmanDaemon.Keychain` backed by macOS `security`.

  Items are added with `security -i` and the command on standard input, so the
  token never appears in any process's arguments; reads print it only to the
  child's standard output. Options: `:security` (executable, default
  `/usr/bin/security`), `:keychain` (keychain file; default login keychain),
  `:timeout` (ms).
  """
  @behaviour HelmsmanDaemon.Keychain
  alias HelmsmanDaemon.Exec

  # `security` exits with the low byte of the OSStatus.
  @not_found 44
  @interaction_not_allowed 36
  @auth_failed 51

  @impl true
  def add(service, account, token, opts) do
    values = [service, account, token | keychain(opts)]

    if Enum.all?(values, &quotable?/1) do
      command =
        [
          "add-generic-password",
          "-s",
          quoted(service),
          "-a",
          quoted(account),
          "-w",
          quoted(token)
        ] ++
          Enum.map(keychain(opts), &quoted/1)

      case run(["-i"], Enum.join(command, " ") <> "\n", opts) do
        {:ok, _} -> :ok
        {:error, _, _} = error -> {:error, reason(error)}
      end
    else
      {:error, :unsupported_characters}
    end
  end

  @impl true
  def find(service, account, opts) do
    case run(
           ["find-generic-password", "-s", service, "-a", account, "-w" | keychain(opts)],
           nil,
           opts
         ) do
      {:ok, output} -> {:ok, String.trim_trailing(output, "\n")}
      error -> {:error, reason(error)}
    end
  end

  @impl true
  def delete(service, account, opts) do
    case run(
           ["delete-generic-password", "-s", service, "-a", account | keychain(opts)],
           nil,
           opts
         ) do
      {:ok, _} -> :ok
      error -> {:error, reason(error)}
    end
  end

  defp keychain(opts), do: List.wrap(opts[:keychain])

  # `security -i` splits its input on whitespace and honours double quotes.
  defp quotable?(value), do: not String.contains?(value, ["\"", "\\", "\n", "\r", <<0>>])
  defp quoted(value), do: "\"" <> value <> "\""

  defp reason({:error, @not_found, _}), do: :not_found
  defp reason({:error, :timeout, _}), do: :timeout

  defp reason({:error, status, stderr}) do
    cond do
      stderr =~ "could not be found" -> :not_found
      status == @interaction_not_allowed or stderr =~ "User interaction is not allowed" -> :locked
      status == @auth_failed or stderr =~ ~r/locked/i -> :locked
      true -> {:exit, status}
    end
  end

  defp run(args, stdin, opts) do
    executable = Keyword.get(opts, :security, "/usr/bin/security")
    Exec.capture([executable | args], stdin: stdin, timeout: Keyword.get(opts, :timeout, 30_000))
  end
end
