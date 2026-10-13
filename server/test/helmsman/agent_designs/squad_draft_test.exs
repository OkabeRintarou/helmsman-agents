defmodule Helmsman.AgentDesigns.SquadDraftTest do
  # add-squads 5.1: squad conversations, the squad part of the draft, the
  # user's edits and the references of draft agents (agent-design "开始创建
  # 对话", "用户修改草稿", "草稿工具"; decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{AgentDesigns, Agents}
  alias Helmsman.AgentDesigns.Prompt

  setup do
    ctx = design_fixture()
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    view = start_squad_design!(ctx, "建一个网页小队：一个 leader，前端、评审、测试各一个")
    end_and_settle!(run_turn!(ctx, view.id), :succeeded, summary: "ok")
    Map.merge(ctx, %{id: view.id, bob: bob_scope.actor})
  end

  defp version(ctx), do: design!(ctx.id).draft_version

  defp put_agent!(ctx, name, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name,
          provider: "claude",
          runtime_id: ctx.runtime.id,
          instructions: "You are #{name}."
        },
        extra
      )

    {:ok, view} = AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version(ctx), attrs)
    view
  end

  defp put_squad(ctx, attrs),
    do: AgentDesigns.put_squad(ctx.alice_scope, ctx.id, version(ctx), attrs)

  defp squad_errors({:error, {:invalid_squad, cs}}), do: Agents.errors(cs)

  test "starting a squad conversation: the empty squad part and a design run", ctx do
    design = design!(ctx.id)
    assert design.kind == :squad

    assert design.draft == %{
             "agents" => [],
             "squad" => %{
               "name" => nil,
               "description" => "",
               "leader" => nil,
               "instructions" => "",
               "members" => []
             }
           }

    assert [%{status: :succeeded}] = design_runs!(ctx.id)
  end

  test "another kind is a kind error; agent stays the default", ctx do
    assert {:error, cs} =
             AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "x", kind: "team"})

    assert %{kind: [_]} = Agents.errors(cs)

    assert {:error, {:design_open, _}} =
             AgentDesigns.start(ctx.alice_scope, %{helper: "helper", message: "x"})
  end

  test "the user edits the squad: version, pending edits, the next turn says so", ctx do
    put_agent!(ctx, "web-lead")
    put_agent!(ctx, "qa")
    bob = ctx.bob.name

    assert {:ok, view} =
             put_squad(ctx, %{
               name: "web-team",
               leader: "web-lead",
               members: [%{name: "qa", role_note: "测试"}, %{name: bob, role_note: "产品决定"}]
             })

    assert %{"name" => "web-team", "leader" => "web-lead", "updated_by" => "user"} =
             view.draft["squad"]

    assert %{able: _, total: 2, restricted: ["web-lead", "qa"]} = view.trigger_summary

    assert %{"squad" => true, "fields" => ["leader", "members", "name"]} =
             Enum.find(view.pending_edits, &(&1["squad"] == true))

    {:ok, _} = put_squad(ctx, %{members: [%{name: "qa", role_note: "端到端测试"}]})
    {:ok, view} = AgentDesigns.send(ctx.alice_scope, ctx.id, "我改了 qa 的说明")

    prompt = Prompt.for_run(current_run!(view.id))
    assert prompt =~ "the squad (leader, members, name)"
    assert prompt =~ "端到端测试"
  end

  test "squad errors: a person leading, the leader as a member, bytes, names taken", ctx do
    put_agent!(ctx, "web-lead")
    bob = ctx.bob.name

    assert %{leader: [_]} = squad_errors(put_squad(ctx, %{leader: bob}))

    assert %{members: [_]} =
             squad_errors(put_squad(ctx, %{leader: "web-lead", members: [%{name: "WEB-LEAD"}]}))

    note = String.duplicate("😀", 600)

    assert %{members: [msg]} =
             squad_errors(put_squad(ctx, %{members: [%{name: bob, role_note: note}]}))

    assert msg =~ bob

    assert %{name: [_]} = squad_errors(put_squad(ctx, %{name: "helper"}))
    assert %{name: [_]} = squad_errors(put_squad(ctx, %{name: "WEB-LEAD"}))
    assert design!(ctx.id).draft["squad"]["name"] == nil
  end

  test "null restores a default; an agent conversation has no squad", ctx do
    {:ok, _} = put_squad(ctx, %{description: "x"})
    {:ok, view} = put_squad(ctx, %{description: nil})
    assert view.draft["squad"]["description"] == ""
  end

  test "renaming a draft agent follows in the squad; removing a referenced one is refused", ctx do
    put_agent!(ctx, "web-lead")
    put_agent!(ctx, "qa")
    {:ok, _} = put_squad(ctx, %{leader: "web-lead", members: [%{name: "qa"}]})

    put_agent!(ctx, "web-captain", %{previous_name: "web-lead"})
    assert design!(ctx.id).draft["squad"]["leader"] == "web-captain"

    assert {:error, {:referenced_by_squad, "qa"}} =
             AgentDesigns.remove_agent(ctx.alice_scope, ctx.id, version(ctx), "QA")

    assert [_, _] = design!(ctx.id).draft["agents"]
  end

  test "an agent conversation refuses put_squad", _ctx do
    ctx = design_fixture()
    %{id: id} = start_design!(ctx.alice_scope)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")

    assert {:error, :not_squad} =
             AgentDesigns.put_squad(ctx.alice_scope, id, design!(id).draft_version, %{name: "x"})

    assert design!(id).draft == %{"agents" => []}
    assert AgentDesigns.get(ctx.alice_scope, id) |> elem(1) |> Map.get(:trigger_summary) == nil
  end

  test "the squad's existing members: a managed agent of another owner", ctx do
    {_carol, carol_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(carol_scope, %{name: "carol/qa", access: "workspace"})
    put_agent!(ctx, "web-lead", %{access: "workspace"})

    assert {:ok, %{trigger_summary: %{restricted: []}}} =
             put_squad(ctx, %{leader: "web-lead", members: [%{name: "carol/qa"}]})
  end
end
