defmodule Helmsman.AgentDesigns.DraftTest do
  # add-agent-conversation 3.2: the user's draft edits (decisions 7, 16)
  # and the draft's own rules.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures

  alias Helmsman.{AgentDesigns, Events}
  alias Helmsman.AgentDesigns.Draft

  setup do
    ctx = design_fixture()
    %{id: id} = start_design!(ctx.alice_scope)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    Map.put(ctx, :id, id)
  end

  defp version(id), do: design!(id).draft_version

  defp put(ctx, attrs, version \\ nil),
    do: AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version || version(ctx.id), attrs)

  defp remove(ctx, name),
    do: AgentDesigns.remove_agent(ctx.alice_scope, ctx.id, version(ctx.id), name)

  defp agent(ctx, name, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        provider: "claude",
        runtime_id: ctx.runtime.id,
        model: "sonnet",
        instructions: "You are #{name}."
      },
      extra
    )
  end

  defp entry(id, name), do: Draft.find(design!(id).draft, name)

  describe "the user's edits" do
    test "change the model, then send: the snapshot is on the message (scenario)", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      AgentDesigns.send(ctx.alice_scope, ctx.id, "ok")
      end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: "ok")
      Events.subscribe(AgentDesigns.topic(ctx.id))

      assert {:ok, %{draft_version: v}} = put(ctx, %{name: "fe-dev", model: "opus"})
      assert v == 2
      assert_receive {:agent_design, _}
      assert entry(ctx.id, "fe-dev")["model"] == "opus"
      assert entry(ctx.id, "fe-dev")["updated_by"] == "user"
      assert design!(ctx.id).pending_edits == [%{"agent" => "fe-dev", "fields" => ["model"]}]

      {:ok, view} = AgentDesigns.send(ctx.alice_scope, ctx.id, "more")
      assert view.pending_edits == []

      assert %{role: :user, edits: [%{"agent" => "fe-dev", "fields" => ["model"]}]} =
               List.last(messages!(ctx.id))
    end

    test "a stopped turn keeps its edits on its message (scenario)", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "first")
      {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "second")

      [_, _, first, _stopped, second] = messages!(ctx.id)
      assert [%{"agent" => "fe-dev", "fields" => fields, "added" => true}] = first.edits
      assert "model" in fields
      assert second.edits == []
    end

    test "while a turn runs: turn_running, the draft unchanged (scenario)", ctx do
      {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "go")
      run_turn!(ctx, ctx.id)
      assert put(ctx, agent(ctx, "fe-dev")) == {:error, :turn_running}
      assert remove(ctx, "fe-dev") == {:error, :turn_running}
      assert design!(ctx.id).draft == %{"agents" => []}
    end

    test "an old version: stale, the draft unchanged (scenario)", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      assert put(ctx, %{name: "fe-dev", model: "opus"}, 0) == {:error, :stale}
      assert entry(ctx.id, "fe-dev")["model"] == "sonnet"
    end
  end

  describe "the draft's rules" do
    test "defaults of a new agent; a patch keeps the rest; null restores a default", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev", %{max_concurrency: 4, access: "workspace"}))

      assert %{"access" => "workspace", "max_concurrency" => 4, "timeout_minutes" => 120} =
               entry(ctx.id, "fe-dev")

      {:ok, _} = put(ctx, %{name: "FE-DEV", effort: "medium"})

      assert %{"effort" => "medium", "instructions" => "You are fe-dev.", "model" => "sonnet"} =
               entry(ctx.id, "fe-dev")

      {:ok, _} = put(ctx, %{name: "fe-dev", access: nil, max_concurrency: nil, model: nil})

      assert %{"access" => "owner_only", "max_concurrency" => 2, "model" => nil} =
               entry(ctx.id, "fe-dev")
    end

    test "a new agent needs name, provider and instructions", ctx do
      assert {:error, cs} = put(ctx, %{name: "x"})
      assert %{provider: [_], instructions: [_]} = Helmsman.Agents.errors(cs)
    end

    test "a name taken in the draft or in the workspace", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      {:ok, _} = put(ctx, agent(ctx, "qa"))

      assert {:error, cs} = put(ctx, %{name: "qa", previous_name: "fe-dev"})
      assert {"is already in the draft", []} = cs.errors[:name]

      assert {:error, cs} = put(ctx, agent(ctx, "helper"))
      assert {"has already been taken", _} = cs.errors[:name]
    end

    test "the ninth agent: draft_full", ctx do
      for i <- 1..8, do: {:ok, _} = put(ctx, agent(ctx, "a#{i}"))
      assert put(ctx, agent(ctx, "a9")) == {:error, :draft_full}
      assert {:ok, _} = put(ctx, %{name: "a8", effort: "low"})
      assert length(Draft.agents(design!(ctx.id).draft)) == 8
    end

    test "members access, environment and other execution fields are refused", ctx do
      assert {:error, cs} = put(ctx, agent(ctx, "fe-dev", %{access: "members"}))
      assert {"must be owner_only or workspace", _} = cs.errors[:access]

      for {field, value} <- [
            env: %{"FOO" => "bar"},
            extra_mcp_servers: %{},
            custom_args: ["--x"],
            access_member_ids: [1]
          ] do
        assert {:error, cs} = put(ctx, agent(ctx, "fe-dev", %{field => value}))
        assert {"cannot be set in a draft", []} = cs.errors[field]
      end

      assert {:error, cs} = put(ctx, Map.put(agent(ctx, "fe-dev"), "color", "red"))
      assert {"%{field} is not a draft field", [field: "color"]} = cs.errors[:base]
      assert design!(ctx.id).draft == %{"agents" => []}
    end

    test "a model the runtime does not report lists its models", ctx do
      assert {:error, cs} = put(ctx, agent(ctx, "fe-dev", %{model: "gpt-5"}))

      assert {"is not supported by the runtime", opts} = cs.errors[:model]
      assert opts[:supported] == ["fable", "opus", "sonnet"]
    end
  end

  describe "pending edits" do
    test "fields of one agent are merged; a rename moves them to the new name", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      AgentDesigns.send(ctx.alice_scope, ctx.id, "told")
      end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: "ok")

      {:ok, _} = put(ctx, %{name: "fe-dev", model: "opus"})
      {:ok, _} = put(ctx, %{name: "fe-dev", effort: "high"})
      {:ok, _} = put(ctx, %{name: "web-dev", previous_name: "fe-dev"})

      assert design!(ctx.id).pending_edits == [
               %{"agent" => "web-dev", "fields" => ["effort", "model", "name"]}
             ]

      assert entry(ctx.id, "web-dev")["model"] == "opus"
      refute entry(ctx.id, "fe-dev")
    end

    test "removals; an agent added and removed before the helper saw it disappears", ctx do
      {:ok, _} = put(ctx, agent(ctx, "fe-dev"))
      AgentDesigns.send(ctx.alice_scope, ctx.id, "told")
      end_and_settle!(run_turn!(ctx, ctx.id), :succeeded, summary: "ok")

      {:ok, _} = put(ctx, %{name: "fe-dev", model: "opus"})
      {:ok, _} = remove(ctx, "fe-dev")
      {:ok, _} = put(ctx, agent(ctx, "tmp"))
      {:ok, _} = remove(ctx, "tmp")

      assert design!(ctx.id).pending_edits == [%{"agent" => "fe-dev", "removed" => true}]
      assert remove(ctx, "nobody") == {:error, :not_found}
    end
  end
end
