# Independent BEAM entry point for credentials concurrency tests.
alias HelmsmanDaemon.Credentials
[mode, generation, pause] = System.argv()
opts = [store: :keychain, keychain: {HelmsmanDaemon.FileKeychain, []}]

hook = fn event ->
  if inspect(event) == pause do
    IO.puts("paused")
    if IO.gets("") == :eof, do: System.halt(0)
  end

  :ok
end

IO.puts("starting")

result =
  case mode do
    "write" ->
      credentials = %Credentials{
        server_url: "https://example.test",
        daemon_id: 1,
        token: "hmd_test_generation_" <> generation,
        issued_at: DateTime.add(~U[2026-10-01 00:00:00Z], String.to_integer(generation))
      }

      Credentials.write(credentials, Keyword.put(opts, :hook, hook))

    "read" ->
      Credentials.read(Keyword.put(opts, :hook, hook))

    "delete" ->
      Credentials.delete(opts)
  end

IO.puts("result:" <> inspect(result))
