# Independent BEAM entry point for config lock tests: `repos add NAME PATH [pause]`.
alias HelmsmanDaemon.LocalRepos
[name, path | rest] = System.argv()

hook = fn ->
  if rest == ["pause"] do
    IO.puts("paused")
    if IO.gets("") == :eof, do: System.halt(0)
  end

  :ok
end

IO.puts("starting")
IO.puts("result:" <> inspect(LocalRepos.add(path, name, ["acme"], before_rename: hook)))
