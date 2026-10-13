defmodule Mix.Tasks.Helmsman.DevRun do
  @moduledoc "Runs a local task with an adapter and prints its protocol reports."
  @shortdoc "Run an agent locally without a server connection"
  use Mix.Task
  alias HelmsmanDaemon.{Adapter, Paths, RunWorker}
  alias HelmsmanProtocol.{Reply, Report, RunSpec}

  @switches [
    provider: :string,
    prompt: :string,
    model: :string,
    effort: :string,
    mcp_url: :string,
    mcp_token: :string,
    resume: :string,
    home: :string,
    task: :string
  ]

  @impl true
  def run(args), do: run(args, Adapter.registered())

  @doc false
  def run(args, adapters) do
    if Mix.env() not in [:dev, :test], do: Mix.raise("helmsman.dev_run requires dev or test")
    flags = parse!(args)

    adapter =
      Enum.find(adapters, &(Atom.to_string(&1.provider()) == flags[:provider]))

    if !adapter, do: Mix.raise("No adapter for #{flags[:provider]}")
    Mix.Task.run("app.start")
    previous = System.get_env("HELMSMAN_HOME")
    System.put_env("HELMSMAN_HOME", Path.expand(flags[:home] || "~/.helmsman-dev"))

    try do
      execute(spec(flags, adapter.provider()), adapter)
    after
      if previous,
        do: System.put_env("HELMSMAN_HOME", previous),
        else: System.delete_env("HELMSMAN_HOME")
    end
  end

  defp parse!(args) do
    {flags, positional, invalid} = OptionParser.parse(args, strict: @switches)

    valid? =
      positional == [] and invalid == [] and is_binary(flags[:provider]) and
        is_binary(flags[:prompt])

    if !valid?,
      do: Mix.raise("Usage: mix helmsman.dev_run --provider PROVIDER --prompt TEXT [options]")

    flags
  end

  defp spec(flags, provider) do
    %RunSpec{
      run_id: :crypto.strong_rand_bytes(6) |> :binary.decode_unsigned() |> Kernel.+(1),
      workspace: %RunSpec.Workspace{id: 1, slug: "dev"},
      task: %RunSpec.Task{ident: flags[:task] || "DEV-1", title: "Local development run"},
      agent: %RunSpec.Agent{
        name: "Local",
        provider: provider,
        model: flags[:model],
        effort: flags[:effort],
        custom_args: [],
        env: %{},
        extra_mcp_servers: %{}
      },
      prompt: flags[:prompt],
      resume_session_id: flags[:resume],
      repo: nil,
      mcp: %RunSpec.MCP{
        url: flags[:mcp_url] || "http://localhost:4003/mcp",
        token: flags[:mcp_token] || System.get_env("HELMSMAN_RUN_TOKEN") || ""
      },
      limits: %RunSpec.Limits{timeout_ms: 600_000, idle_timeout_ms: 600_000},
      trigger: %RunSpec.Trigger{kind: "manual", reason: nil, feedback_id: nil}
    }
  end

  defp execute(spec, adapter) do
    Paths.ensure!()

    case HelmsmanDaemon.Config.load() do
      {:ok, _} -> :ok
      _ -> Mix.raise("Invalid daemon config.toml")
    end

    {:ok, registry} = Registry.start_link(keys: :unique, name: HelmsmanDaemon.RunRegistry)

    try do
      IO.puts("Work directory: #{Path.join([Paths.home(), "scratch", "dev", spec.task.ident])}")
      {:ok, worker} = RunWorker.start_link({spec, [adapter: adapter, reporter: __MODULE__]})
      ref = Process.monitor(worker)

      receive do
        {:DOWN, ^ref, :process, ^worker, :normal} ->
          :ok

        {:DOWN, ^ref, :process, ^worker, reason} ->
          Mix.raise("Run worker failed: #{inspect(reason)}")
      end
    after
      Supervisor.stop(registry)
    end
  end

  def report(_id, payload) do
    ref = make_ref()
    print(payload)
    send(self(), {:report_result, ref, response(payload)})
    ref
  end

  defp print(%Report.Events{events: events}),
    do: Enum.each(events, &IO.puts(inspect(&1, limit: :infinity)))

  defp print(payload), do: IO.puts(inspect(payload, limit: :infinity))
  defp response(%Report.Starting{}), do: {:ok, %Reply.Starting{action: :proceed, reason: nil}}

  defp response(%Report.Events{events: events}),
    do: {:ok, %Reply.Events{acked_seq: List.last(events).seq}}

  defp response(_), do: {:ok, %Reply.Empty{}}
end
