defmodule Helmsman.ProjectsSpecFinalizeTest do
  # add-spec-workflow 1.5: projects 「项目的规格定稿方式」 (decision 7).
  use Helmsman.DataCase, async: true

  import Helmsman.TaskSpecsFixtures

  alias Helmsman.{Events, Projects, TaskSpecs}

  setup do
    specs_fixture()
  end

  test "an admin changes it; reading gives it; the project is notified", ctx do
    {:ok, project} = Projects.get(ctx.alice_scope, ctx.project.key)
    assert project.spec_finalize == :approval
    Events.subscribe(Events.topic(:project, ctx.project.id))

    assert {:ok, %{spec_finalize: :leader}} =
             Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})

    assert_receive _project_changed
    assert {:ok, %{spec_finalize: :leader}} = Projects.get(ctx.alice_scope, ctx.project.key)
  end

  test "an archived project too", ctx do
    {:ok, _} = Projects.archive(ctx.alice_scope, ctx.project.key)

    assert {:ok, _} =
             Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})
  end

  test "members and agents cannot", ctx do
    assert {:error, :forbidden} =
             Projects.update(ctx.bob_scope, ctx.project.key, %{spec_finalize: "leader"})

    agent_scope = %{ctx.alice_scope | actor: ctx.lead, via: :mcp}

    assert {:error, :forbidden} =
             Projects.update(agent_scope, ctx.project.key, %{spec_finalize: "leader"})

    # Other fields as before.
    assert {:ok, _} = Projects.update(agent_scope, ctx.project.key, %{name: "Renamed"})
  end

  test "an invalid mode is a field error", ctx do
    assert {:error, %Ecto.Changeset{errors: [spec_finalize: _]}} =
             Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "never"})
  end

  test "a pending proposal stays pending after the change", ctx do
    spec_fixture(ctx.alice_scope, ctx.task.ident)
    {lead, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})

    {:ok, %{decision: :proposed}} =
      TaskSpecs.finalize(lead, ctx.task.ident, %{version: 1, summary: "ok"})

    {:ok, _} = Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: "leader"})

    assert {:ok, %{status: :pending_approval}} =
             TaskSpecs.summary(ctx.alice_scope, ctx.task.ident)
  end
end
