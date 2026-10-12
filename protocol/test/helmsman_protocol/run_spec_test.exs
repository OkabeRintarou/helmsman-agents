defmodule HelmsmanProtocol.RunSpecTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, RunSpec}

  test "run without task, repository, model or effort" do
    payload =
      Fixtures.run_spec()
      |> Map.merge(%{"task" => nil, "repo" => nil})
      |> put_in(["agent", "model"], nil)
      |> put_in(["agent", "effort"], nil)

    assert {:ok, spec} = RunSpec.from_wire(payload)
    assert spec.task == nil
    assert spec.repo == nil
    assert spec.agent.model == nil
    assert spec.agent.effort == nil
    assert RunSpec.to_wire(spec) == payload
  end

  test "provider, custom arguments, environment and repository constraints" do
    cases = [
      {["agent", "provider"], "gemini", {:enum, [:claude, :codex, :copilot, :cursor]}},
      {["agent", "custom_args"], "--flag value", :type},
      {["agent", "custom_args"], List.duplicate("x", 65), {:count, 0, 64}},
      {["agent", "env"], nil, :type},
      {["repo", "git_token"], nil, :type},
      {["agent", "model"], "", :type},
      {["agent", "effort"], String.duplicate("x", 129), {:too_long, 128}}
    ]

    for {path, value, reason} <- cases do
      assert {:error, {:invalid_payload, ^path, ^reason}} =
               RunSpec.from_wire(put_in(Fixtures.run_spec(), path, value))
    end

    assert {:error, {:invalid_payload, ["agent", "custom_args", 0], :type}} =
             RunSpec.from_wire(put_in(Fixtures.run_spec(), ["agent", "custom_args"], [""]))

    assert {:error, {:invalid_payload, ["agent", "custom_args", 0], {:too_long, 4_096}}} =
             RunSpec.from_wire(
               put_in(Fixtures.run_spec(), ["agent", "custom_args"], [
                 String.duplicate("x", 4_097)
               ])
             )

    assert {:error, {:invalid_payload, ["repo", "git_token_expires_at"], :required}} =
             RunSpec.from_wire(
               update_in(Fixtures.run_spec(), ["repo"], &Map.delete(&1, "git_token_expires_at"))
             )

    assert {:ok, spec} = RunSpec.from_wire(Fixtures.run_spec())
    assert spec.repo.git_token_expires_at == ~U[2026-10-12 08:00:00Z]
  end

  test "trigger is a bounded free string with nullable reason and feedback" do
    for kind <- ["assign", "manual", "new_trigger"] do
      assert {:ok, trigger} =
               RunSpec.Trigger.from_wire(%{"kind" => kind, "reason" => nil, "feedback_id" => nil})

      assert trigger.kind == kind
    end

    for field <- ["kind", "reason"] do
      for {value, reason} <- [{"", :type}, {String.duplicate("x", 65), {:too_long, 64}}] do
        assert {:error, {:invalid_payload, [^field], ^reason}} =
                 RunSpec.Trigger.from_wire(
                   Map.put(
                     %{"kind" => "reopen", "reason" => nil, "feedback_id" => nil},
                     field,
                     value
                   )
                 )
      end
    end
  end

  test "inspection hides secrets at every nesting level and encoding preserves them" do
    assert {:ok, spec} = RunSpec.from_wire(Fixtures.run_spec())

    for value <- [spec, spec.agent, spec.repo, spec.mcp] do
      inspected = inspect(value)

      for secret <- ["env-secret", "mcp-secret", "git-secret", "hmr_secret"],
          do: refute(inspected =~ secret)

      assert inspected =~ "**redacted**"
    end

    assert inspect(spec) =~ "API_KEY"
    assert inspect(spec.agent) =~ "API_KEY"
    assert RunSpec.to_wire(spec) == Fixtures.run_spec()
    assert {:ok, ^spec} = RunSpec.new(Map.from_struct(spec))
  end

  test "inspection of malformed values never falls back to the raw structure" do
    malformed_envs = [
      "env-secret",
      ["env-secret"],
      [{"API_KEY", "env-secret"}],
      42,
      %{1 => "env-secret"}
    ]

    for env <- malformed_envs do
      agent = %RunSpec.Agent{env: env, extra_mcp_servers: %{"token" => "mcp-secret"}}
      {:ok, spec} = RunSpec.from_wire(Fixtures.run_spec())

      for value <- [agent, %{spec | agent: agent}] do
        inspected = inspect(value)
        refute inspected =~ "env-secret"
        refute inspected =~ "mcp-secret"
        refute inspected =~ "Inspect.Error"
        assert inspected =~ "**redacted**"
      end
    end

    assert {:ok, spec} = RunSpec.from_wire(Fixtures.run_spec())
    inspected = inspect(%{spec.agent | env: %{"API_KEY" => "env-secret"}})
    assert inspected =~ "API_KEY"
    refute inspected =~ "env-secret"
  end

  test "malformed env never causes Inspect.Error or reveals raw secrets" do
    malformed = [
      "env-secret",
      ["env-secret"],
      [{:invalid, "env-secret"}],
      7,
      %{"KEY" => ["env-secret"]},
      %{"env-secret" => 7},
      %{invalid: "env-secret"}
    ]

    for env <- malformed do
      agent = %RunSpec.Agent{env: env, extra_mcp_servers: %{"token" => "mcp-secret"}}

      for value <- [agent, %RunSpec{agent: agent}] do
        output = inspect(value)
        for secret <- ["env-secret", "mcp-secret", "Inspect.Error"], do: refute(output =~ secret)
        assert output =~ "**redacted**"
      end
    end
  end

  test "malformed nested fields are redacted before Inspect can fall back" do
    values = [
      %RunSpec{agent: "env-secret", repo: "git-secret", mcp: "hmr_secret"},
      %RunSpec{
        agent: %{env: "env-secret", extra_mcp_servers: %{"token" => "mcp-secret"}},
        repo: %{git_token: "git-secret"},
        mcp: %{token: "hmr_secret"}
      }
    ]

    for value <- values do
      output = inspect(value)

      for secret <- ["env-secret", "mcp-secret", "git-secret", "hmr_secret", "Inspect.Error"],
          do: refute(output =~ secret)
    end
  end
end
