defmodule HelmsmanProtocol.RoundtripTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Event, FailureReason, Fixtures, Reply, Report, RunSpec}

  @seed {73_913, 19_271, 97_531}
  test "200 seeded JSON roundtrips per RunSpec, Finished, Events, Join and Join reply" do
    :rand.seed(:exsss, @seed)

    for iteration <- 1..200 do
      samples = [
        {RunSpec, random_run()},
        {Report.Finished, random_finished()},
        {Report.Events, random_events()},
        {Report.Join, random_join()},
        {Reply.Join, random_reply()}
      ]

      for {module, payload} <- samples do
        context = "seed=#{inspect(@seed)} iteration=#{iteration} module=#{inspect(module)}"
        assert {:ok, value} = module.from_wire(payload), context
        wire = module.to_wire(value) |> JSON.encode!() |> JSON.decode!()
        assert module.from_wire(wire) == {:ok, value}, context
      end
    end
  end

  defp random_run do
    Fixtures.run_spec()
    |> Map.put("run_id", id())
    |> Map.put("prompt", text())
    |> Map.put("resume_session_id", maybe(text()))
    |> Map.put("task", maybe(%{"ident" => text(), "title" => text()}))
    |> Map.put("repo", maybe(Fixtures.repo()))
    |> put_in(["agent", "provider"], pick(~w(claude codex copilot cursor)))
    |> put_in(["agent", "model"], maybe(text()))
    |> put_in(["agent", "effort"], maybe(text()))
    |> put_in(["agent", "custom_args"], Enum.map(1..:rand.uniform(5), fn _ -> text() end))
    |> put_in(["agent", "env"], %{"KEY" => text()})
    |> put_in(["agent", "provider_account"], maybe(random_provider_account()))
    |> put_in(["agent", "extra_mcp_servers"], %{"nested" => [nil, true, id(), %{"x" => text()}]})
    |> put_in(["trigger", "kind"], pick(~w(assign manual reopen future_kind)))
    |> put_in(["trigger", "reason"], maybe(text()))
    |> put_in(["trigger", "feedback_id"], maybe(id()))
  end

  defp random_provider_account do
    %{
      "base_url" => "https://api.example.com/#{id()}",
      "api_key" => "test-key-#{id()}",
      "models" => if(:rand.uniform(2) == 1, do: %{}, else: %{"default" => text()})
    }
  end

  defp random_usage do
    Map.new(Fixtures.usage(), fn
      {"cost_usd", _} -> {"cost_usd", maybe(:rand.uniform() * 10)}
      {key, _} -> {key, maybe(:rand.uniform(10_000) - 1)}
    end)
  end

  defp random_finished do
    status = pick(~w(succeeded failed cancelled))

    reason =
      if status == "failed",
        do: FailureReason.daemon_reportable() |> pick() |> Atom.to_string(),
        else: nil

    Fixtures.finished()
    |> Map.merge(%{
      "run_id" => id(),
      "status" => status,
      "failure_reason" => reason,
      "error" => maybe(text()),
      "summary" => maybe(text()),
      "session_id" => maybe(text()),
      "usage" => maybe(random_usage())
    })
  end

  defp random_events do
    start = id()

    events =
      for index <- 1..:rand.uniform(20) do
        type = Event.types() |> pick() |> Atom.to_string()
        payload = Fixtures.event(type, start + index * 2)
        payload = if type == "usage", do: Map.put(payload, "data", random_usage()), else: payload

        Map.put(
          payload,
          "at",
          DateTime.to_iso8601(DateTime.add(~U[2026-10-12 07:00:00.000000Z], id(), :microsecond))
        )
      end

    %{"run_id" => id(), "events" => events}
  end

  defp random_join do
    Fixtures.join()
    |> Map.put("max_concurrency", :rand.uniform(20))
    |> Map.put(
      "active_runs",
      if(:rand.uniform(2) == 1, do: [], else: [%{"run_id" => id(), "last_seq" => id() - 1}])
    )
    |> put_in(["machine", "name"], text())
    |> Map.put(
      "clis",
      if(:rand.uniform(2) == 1,
        do: [],
        else: [Fixtures.cli() |> Map.put("provider", pick(~w(claude codex copilot cursor)))]
      )
    )
  end

  defp random_reply do
    Fixtures.join_reply()
    |> Map.put("daemon_id", id())
    |> Map.put("terminate_run_ids", if(:rand.uniform(2) == 1, do: [], else: [id(), id()]))
    |> Map.put(
      "runtimes",
      if(:rand.uniform(2) == 1,
        do: [],
        else: [
          %{
            "workspace_id" => id(),
            "workspace_slug" => text(),
            "provider" => pick(~w(claude codex copilot cursor)),
            "runtime_id" => id()
          }
        ]
      )
    )
  end

  defp id, do: :rand.uniform(100_000)
  defp text, do: "值😀-#{id()}"
  defp pick(items), do: Enum.at(items, :rand.uniform(length(items)) - 1)
  defp maybe(value), do: if(:rand.uniform(2) == 1, do: nil, else: value)
end
