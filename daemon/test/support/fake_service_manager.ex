defmodule HelmsmanDaemon.FakeServiceManager do
  @moduledoc """
  Stateful stand-in for systemctl / loginctl / journalctl and launchctl that
  records every command line; tests pass `cmd(fake)` as the service executor.
  """
  use Agent

  def start_link(kind, state \\ %{}) do
    defaults = %{
      available: true,
      enabled: false,
      active: false,
      loaded: false,
      running: false,
      disabled: false,
      linger: "no",
      uid: "501",
      label: "dev.helmsman.helmsman-daemon",
      fail: []
    }

    Agent.start_link(fn -> %{kind: kind, calls: [], state: Map.merge(defaults, state)} end)
  end

  def cmd(fake), do: fn program, args, opts -> call(fake, program, args, opts) end
  def calls(fake), do: Agent.get(fake, &Enum.reverse(&1.calls))
  def update(fake, changes), do: Agent.update(fake, &%{&1 | state: Map.merge(&1.state, changes)})
  def reset_calls(fake), do: Agent.update(fake, &%{&1 | calls: []})

  @doc "Command lines as strings, e.g. `systemctl --user enable --now x.service`."
  def lines(fake),
    do: Enum.map(calls(fake), fn {program, args} -> Enum.join([program | args], " ") end)

  defp call(fake, program, args, opts) do
    reply =
      Agent.get_and_update(fake, fn agent ->
        line = Enum.join([program | args], " ")

        {reply, state} =
          if Enum.any?(agent.state.fail, &String.contains?(line, &1)),
            do: {{"injected failure\n", 1}, agent.state},
            else: respond(agent.kind, program, args, agent.state)

        {reply, %{agent | calls: [{program, args} | agent.calls], state: state}}
      end)

    if opts[:stream], do: IO.write(elem(reply, 0))
    reply
  end

  defp respond(:systemd, "systemctl", ["--user" | args], state), do: systemctl(args, state)

  defp respond(:systemd, "loginctl", ["show-user", _, "--property=Linger"], state),
    do: {{"Linger=#{state.linger}\n", 0}, state}

  defp respond(:systemd, "journalctl", _args, state), do: {{"journal line\n", 0}, state}
  defp respond(_, "id", ["-un"], state), do: {{"tester\n", 0}, state}
  defp respond(_, "id", ["-u"], state), do: {{state.uid <> "\n", 0}, state}

  defp respond(:launchd, "launchctl", args, state),
    do: launchctl(args, "gui/" <> state.uid, state)

  defp respond(:launchd, "tail", _args, state), do: {{"log line\n", 0}, state}

  defp systemctl(["show", "--property=Version"], %{available: true} = state),
    do: {{"Version=255\n", 0}, state}

  defp systemctl(["show", "--property=Version"], state),
    do: {{"Failed to connect to bus: No medium found\n", 1}, state}

  defp systemctl(["is-enabled", _], %{enabled: true} = state), do: {{"enabled\n", 0}, state}
  defp systemctl(["is-enabled", _], state), do: {{"disabled\n", 1}, state}
  defp systemctl(["is-active", _], %{active: true} = state), do: {{"active\n", 0}, state}
  defp systemctl(["is-active", _], state), do: {{"inactive\n", 3}, state}

  defp systemctl(["show", "--property=MainPID", "--value", _], state),
    do: {{if(state.active, do: "4242\n", else: "0\n"), 0}, state}

  defp systemctl(["daemon-reload"], state), do: {{"", 0}, state}

  defp systemctl(["enable", "--now", _], state),
    do: {{"", 0}, %{state | enabled: true, active: true}}

  defp systemctl(["enable", _], state), do: {{"", 0}, %{state | enabled: true}}
  defp systemctl(["restart", _], state), do: {{"", 0}, %{state | active: true}}

  defp systemctl(["disable", "--now", _], state),
    do: {{"", 0}, %{state | enabled: false, active: false}}

  defp launchctl(["print", domain], domain, %{available: true} = state),
    do: {{"domain\n", 0}, state}

  defp launchctl(["print", domain], domain, state), do: {{"Bad request\n", 113}, state}

  defp launchctl(["print", _target], _domain, %{loaded: true, running: true} = state),
    do: {{"\tstate = running\n\tpid = 777\n", 0}, state}

  defp launchctl(["print", _target], _domain, %{loaded: true} = state),
    do: {{"\tstate = waiting\n", 0}, state}

  defp launchctl(["print", _target], _domain, state),
    do: {{"Could not find service\n", 113}, state}

  defp launchctl(["print-disabled", domain], domain, state) do
    flag = if state.disabled, do: "disabled", else: "enabled"
    {{"disabled services = {\n\t\"#{state.label}\" => #{flag}\n}\n", 0}, state}
  end

  defp launchctl(["enable", target], _domain, state),
    do: {{"", 0}, %{state | disabled: false, label: Path.basename(target)}}

  defp launchctl(["disable", target], _domain, state),
    do: {{"", 0}, %{state | disabled: true, label: Path.basename(target)}}

  defp launchctl(["bootout", _], _domain, %{loaded: true} = state),
    do: {{"", 0}, %{state | loaded: false, running: false}}

  defp launchctl(["bootout", _], _domain, state),
    do: {{"Boot-out failed: 3: No such process\n", 3}, state}

  defp launchctl(["bootstrap", domain, _plist], domain, state),
    do: {{"", 0}, %{state | loaded: true, running: not state.disabled}}

  defp launchctl(["kickstart", "-k", _], _domain, state), do: {{"", 0}, %{state | running: true}}
end
