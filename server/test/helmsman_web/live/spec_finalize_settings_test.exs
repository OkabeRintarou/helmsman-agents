defmodule HelmsmanWeb.SpecFinalizeSettingsTest do
  @moduledoc """
  Spec web-projects 项目的规格定稿方式 and web-squads 小队的规格定稿方式
  (add-spec-workflow-ui D17, tasks 6.1, 6.2), against `Helmsman.Projects` and
  `Helmsman.Squads`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Projects, Squads}

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    carol = user_fixture(%{display_name: "carol"})
    member_fixture(ws, alice, :member)
    member_fixture(ws, carol, :admin)
    olga_scope = workspace_scope_fixture(olga, ws)
    alice_scope = workspace_scope_fixture(alice, ws)
    carol_scope = workspace_scope_fixture(carol, ws)

    for name <- ~w(keel/lead keel/fe),
        do: managed_agent_fixture(alice_scope, %{name: name, access: "workspace"})

    {:ok, _} =
      Squads.create(alice_scope, %{
        name: "web-team",
        leader: "keel/lead",
        members: [%{name: "keel/fe", role_note: ""}]
      })

    project = project_fixture(olga_scope, %{key: "BOS"})

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, carol: carol, olga: olga},
      alice_scope: alice_scope,
      carol_scope: carol_scope,
      olga_scope: olga_scope,
      project: project,
      squad_path: "/w/#{ws.slug}/squads/web-team"
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)

  defp spec_finalize(ctx) do
    {:ok, view} = Squads.get(ctx.alice_scope, "web-team")
    view.spec_finalize
  end

  defp submit(view, params), do: render_submit(view, "squad_form_submit", %{"squad" => params})

  describe "项目的规格定稿方式" do
    test "改为 Leader 定稿", ctx do
      path = "/w/#{ctx.ws.slug}/p/BOS?panel=edit-project"
      {:ok, view, _html} = open(ctx, :carol, path)
      assert in_portal?(view, "edit-project", "#edit-project-spec-finalize-approval[checked]")

      render_submit(view, "edit_project_save", %{
        "project" => %{"name" => "BOS", "description" => "", "spec_finalize" => "leader"}
      })

      assert {:ok, %{spec_finalize: :leader}} = Projects.get(ctx.olga_scope, "BOS")

      {:ok, again, _html} = open(ctx, :carol, path)
      assert in_portal?(again, "edit-project", "#edit-project-spec-finalize-leader[checked]")
    end

    test "回填, and saving other fields sends nothing about it", ctx do
      {:ok, view, _html} = open(ctx, :olga, "/w/#{ctx.ws.slug}/p/BOS?panel=edit-project")
      assert in_portal?(view, "edit-project", "#edit-project-spec-finalize-approval[checked]")
      refute in_portal?(view, "edit-project", "#edit-project-spec-finalize-leader[checked]")

      render_submit(view, "edit_project_save", %{
        "project" => %{"name" => "Bosun", "description" => "", "spec_finalize" => "approval"}
      })

      assert {:ok, %{name: "Bosun", spec_finalize: :approval}} =
               Projects.get(ctx.olga_scope, "BOS")
    end
  end

  describe "小队的规格定稿方式" do
    test "admin 设为 Leader 定稿", ctx do
      {:ok, view, _html} = open(ctx, :carol, ctx.squad_path <> "?panel=edit")

      refute in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize option[value=leader][disabled]"
             )

      submit(view, %{"spec_finalize" => "leader"})
      assert spec_finalize(ctx) == :leader
      assert has_element?(view, "#squad-spec-finalize", "Leader 定稿")
    end

    test "member 不能放宽", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.squad_path <> "?panel=edit")
      assert has_element?(view, "#squad-spec-finalize", "继承项目")

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize option[value=leader][disabled]"
             )

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize-help",
               "只有管理员可以设为 Leader 定稿"
             )

      # A forged `leader` is ignored by the form; `approval` is saved.
      render_change(view, "squad_form_change", %{"squad" => %{"spec_finalize" => "leader"}})

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize option[value=''][selected]"
             )

      submit(view, %{"spec_finalize" => "approval"})
      assert spec_finalize(ctx) == :approval
    end

    test "非 admin 保存其他字段", ctx do
      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{spec_finalize: "leader"})
      {:ok, view, _html} = open(ctx, :alice, ctx.squad_path <> "?panel=edit")

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize option[value=leader][selected]"
             )

      form = :sys.get_state(view.pid).socket.assigns.squad_form
      refute Map.has_key?(HelmsmanWeb.SquadForm.attrs(form), :spec_finalize)

      submit(view, %{"description" => "builds the web", "spec_finalize" => "leader"})
      assert spec_finalize(ctx) == :leader
      assert {:ok, %{description: "builds the web"}} = Squads.get(ctx.alice_scope, "web-team")
    end

    test "非 admin 收紧", ctx do
      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{spec_finalize: "leader"})
      {:ok, view, _html} = open(ctx, :alice, ctx.squad_path <> "?panel=edit")

      render_change(view, "squad_form_change", %{"squad" => %{"spec_finalize" => "approval"}})

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize option[value=leader][disabled]"
             )

      submit(view, %{"spec_finalize" => "approval"})

      assert spec_finalize(ctx) == :approval
      assert has_element?(view, "#squad-spec-finalize", "需要人批准")

      {:ok, again, _html} = open(ctx, :alice, ctx.squad_path <> "?panel=edit")

      assert in_portal?(
               again,
               "squad-panel",
               "#squad-form-spec-finalize option[value=leader][disabled]"
             )
    end

    test "a refused change shows under the field and keeps the input", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.squad_path <> "?panel=edit")

      # The page offered `leader` (as if alice were an admin); the domain refuses it.
      :sys.replace_state(view.pid, fn state ->
        socket = state.socket
        form = %{socket.assigns.squad_form | admin?: true}
        %{state | socket: Phoenix.Component.assign(socket, :squad_form, form)}
      end)

      submit(view, %{"spec_finalize" => "leader", "description" => "kept"})

      assert in_portal?(
               view,
               "squad-panel",
               "#squad-form-spec-finalize [data-error]",
               "只有管理员可以设为 Leader 定稿"
             )

      assert portal_text(view, "squad-panel", "#squad-form-description") =~ "kept"
      assert spec_finalize(ctx) == nil
    end
  end
end
