unless Mix.env() == :test, do: raise("E2E bootstrap requires MIX_ENV=test")

options = System.fetch_env!("HELMSMAN_E2E_OPTIONS") |> File.read!() |> Jason.decode!()

run_worker_opts =
  for key <- [
        :allow_file_urls,
        :prepare_timeout_ms,
        :finalize_timeout_ms,
        :push_backoff_ms,
        :push_args,
        :kill_timeout_ms
      ],
      Map.has_key?(options["run_worker_opts"] || %{}, Atom.to_string(key)) do
    {key, options["run_worker_opts"][Atom.to_string(key)]}
  end

opts = [
  run_worker_opts: run_worker_opts,
  heartbeat_interval_ms: Map.get(options, "heartbeat_interval_ms", 30_000)
]

{:ok, supervisor} = HelmsmanDaemon.TestSupport.start(opts)

{:ok, _control} =
  HelmsmanDaemon.E2EControl.start_link(directory: System.fetch_env!("HELMSMAN_E2E_CONTROL_DIR"))

ref = Process.monitor(supervisor)

receive do
  {:DOWN, ^ref, :process, ^supervisor, reason} ->
    raise("E2E daemon stopped: #{inspect(reason)}")
end
