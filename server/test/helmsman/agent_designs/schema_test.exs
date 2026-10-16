defmodule Helmsman.AgentDesigns.SchemaTest do
  # add-agent-conversation 1.1: the tables' constraints (decision 3).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures

  alias Helmsman.AgentDesigns.{AgentDesign, AgentDesignMessage}

  setup do
    ctx = design_fixture()
    Map.put(ctx, :design, start_design!(ctx.alice_scope))
  end

  defp insert_design(ctx, attrs) do
    Repo.insert(
      struct!(
        %AgentDesign{
          workspace_id: ctx.workspace.id,
          user_id: ctx.alice.id,
          helper_agent_id: ctx.helper.id,
          last_activity_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp sql(query, params), do: Repo.query(query, params)

  # add-edit-design-conversations 1.1: one `open` conversation per slot.
  defp edit_attrs(ctx, kind),
    do: %{kind: kind, target_actor_id: ctx.helper.id, baseline: %{"agent" => %{}}}

  test "a second open conversation of the same user, workspace and slot violates the index",
       ctx do
    assert_raise Ecto.ConstraintError, ~r/agent_designs_one_open_per_slot_index/, fn ->
      insert_design(ctx, %{})
    end

    assert_raise Ecto.ConstraintError, ~r/agent_designs_one_open_per_slot_index/, fn ->
      insert_design(ctx, %{kind: :squad})
    end

    assert {:ok, _} = insert_design(ctx, %{status: :confirmed, closed_at: DateTime.utc_now()})
    assert {:ok, _} = insert_design(ctx, %{status: :expired, closed_at: DateTime.utc_now()})
  end

  test "different slots coexist; the slot is generated from the kind", ctx do
    assert {:ok, edit} = insert_design(ctx, edit_attrs(ctx, :agent_edit))
    assert edit.slot == :edit
    assert Repo.get!(AgentDesign, ctx.design.id).slot == :create

    assert_raise Ecto.ConstraintError, ~r/agent_designs_one_open_per_slot_index/, fn ->
      insert_design(ctx, edit_attrs(ctx, :squad_edit))
    end
  end

  test "an edit kind needs its target and baseline; the others have none", ctx do
    closed = %{status: :expired, closed_at: DateTime.utc_now()}

    assert_raise Ecto.ConstraintError, ~r/agent_designs_target_check/, fn ->
      insert_design(ctx, Map.put(closed, :kind, :agent_edit))
    end

    assert_raise Ecto.ConstraintError, ~r/agent_designs_target_check/, fn ->
      insert_design(ctx, Map.merge(closed, %{edit_attrs(ctx, :agent) | kind: :agent}))
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :generated_always}}} =
             sql("UPDATE agent_designs SET slot = 'edit' WHERE id = $1", [ctx.design.id])
  end

  test "a second non-user message of one run violates the index; user messages do not", ctx do
    run_id = design!(ctx.design.id).current_run_id

    message = fn seq, role ->
      Repo.insert(%AgentDesignMessage{
        design_id: ctx.design.id,
        seq: seq,
        role: role,
        content: "x",
        run_id: run_id,
        inserted_at: DateTime.utc_now()
      })
    end

    assert {:ok, _} = message.(2, :assistant)

    assert_raise Ecto.ConstraintError, ~r/agent_design_messages_settled_run_index/, fn ->
      message.(3, :system)
    end

    assert {:ok, _} = message.(4, :user)
  end

  test "CHECK constraints refuse unknown kinds, statuses and roles", ctx do
    id = ctx.design.id

    # `add-squads` decision 2 adds `squad`.
    assert {:ok, _} = sql("UPDATE agent_designs SET kind = 'squad' WHERE id = $1", [id])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "agent_designs_target_check"}}} =
             sql("UPDATE agent_designs SET kind = 'agent_edit' WHERE id = $1", [id])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "agent_designs_kind_check"}}} =
             sql("UPDATE agent_designs SET kind = 'team' WHERE id = $1", [id])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "agent_designs_status_check"}}} =
             sql("UPDATE agent_designs SET status = 'paused' WHERE id = $1", [id])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "agent_design_messages_role_check"}}} =
             sql("UPDATE agent_design_messages SET role = 'tool' WHERE design_id = $1", [id])
  end

  test "a run may have the design capability", ctx do
    run_id = design!(ctx.design.id).current_run_id

    assert {:ok, _} =
             sql("UPDATE runs SET capabilities = ARRAY['read','design'] WHERE id = $1", [run_id])

    assert {:error, %Postgrex.Error{postgres: %{constraint: "runs_capabilities_check"}}} =
             sql("UPDATE runs SET capabilities = ARRAY['admin'] WHERE id = $1", [run_id])
  end
end
