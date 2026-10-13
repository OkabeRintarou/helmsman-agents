defmodule Helmsman.Runs.DesignSpecTest do
  # add-agent-conversation 2.4: the run description of a design run
  # (decisions 8, 17).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.{AgentDesigns, Agents, Dispatch, Runs}
  alias Helmsman.Agents.AgentProfile

  @base_url "http://localhost:4000"

  setup do
    design_fixture()
  end

  defp claim_specs(ctx) do
    {:ok, specs} = Runs.claim(dctx(ctx.helper), @base_url)
    specs
  end

  defp set_limits(ctx, timeout, idle) do
    Repo.update_all(from(p in AgentProfile, where: p.actor_id == ^ctx.helper.id),
      set: [timeout_minutes: timeout, idle_timeout_minutes: idle]
    )
  end

  test "no task, no repository, the design prompt", ctx do
    %{id: id} = start_design!(ctx.alice_scope, "Build me a reviewer")
    [spec] = claim_specs(ctx)

    assert spec.task == nil and spec.repo == nil and spec.resume_session_id == nil
    assert spec.prompt =~ "design new managed agents"
    assert spec.prompt =~ "> Build me a reviewer"
    assert spec.trigger.kind == "design"
    assert spec.run_id == current_run!(id).id
  end

  test "the second turn does not resume the first's session (scenario)", ctx do
    %{id: id} = start_design!(ctx.alice_scope, "first")
    [first] = claim_specs(ctx)
    start!(ctx.helper, first.run_id)

    finish!(ctx.helper, first.run_id, :succeeded, %{summary: "Which CLI?", session_id: "sess-1"})

    AgentDesigns.settle(first.run_id)
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, id, "claude")
    [second] = claim_specs(ctx)

    assert second.resume_session_id == nil
    assert second.prompt =~ "[you] Which CLI?"
    assert second.prompt =~ "[user] first"
    assert second.prompt =~ "> claude"
  end

  for {{timeout, idle}, {want_timeout, want_idle}} <- [
        {{120, 3}, {15, 3}},
        # tasks.md 2.4 names 10 / 20, which the profile's check refuses
        # (idle above total); 10 / 8 exercises the same two minimums.
        {{10, 8}, {10, 5}},
        {{120, 20}, {15, 5}}
      ] do
    test "limits: #{timeout}/#{idle} minutes give #{want_timeout}/#{want_idle} (scenario)", ctx do
      set_limits(ctx, unquote(timeout), unquote(idle))
      start_design!(ctx.alice_scope)
      [spec] = claim_specs(ctx)

      assert Map.from_struct(spec.limits) == %{
               timeout_ms: unquote(want_timeout) * 60_000,
               idle_timeout_ms: unquote(want_idle) * 60_000
             }
    end
  end

  test "a helper with an account, env and extra MCP: the same execution fields as a manual " <>
         "run, none of them in the prompt (scenario)",
       ctx do
    account = provider_account_fixture(ctx.alice, %{name: "zai", api_key: "sk-SENTINEL-KEY"})

    {:ok, _} =
      Agents.update(ctx.alice_scope, "helper", %{
        provider_account_id: account.id,
        env: %{"FOO" => "env-SENTINEL-VALUE"},
        extra_mcp_servers: %{"docs" => %{"command" => "mcp-SENTINEL-CMD"}},
        custom_args: ["--verbose"]
      })

    Repo.update_all(from(p in AgentProfile, where: p.actor_id == ^ctx.helper.id),
      set: [max_concurrency: 4]
    )

    start_design!(ctx.alice_scope)

    {:ok, _} = Dispatch.run_agent(ctx.alice_scope, "helper", nil, "do something")
    specs = claim_specs(ctx)
    assert [design, manual] = Enum.sort_by(specs, &(&1.trigger.kind != "design"))
    assert design.trigger.kind == "design" and manual.trigger.kind == "manual"

    assert design.agent == manual.agent
    assert design.agent.provider_account.api_key == "sk-SENTINEL-KEY"
    assert design.agent.env == %{"FOO" => "env-SENTINEL-VALUE"}
    assert "hmr_" <> _ = design.mcp.token
    assert design.mcp.url == manual.mcp.url

    prompt = inspect(design.prompt)

    for secret <- ["SENTINEL", design.mcp.token, "api.z.ai", "FOO"] do
      refute prompt =~ secret
    end
  end
end
