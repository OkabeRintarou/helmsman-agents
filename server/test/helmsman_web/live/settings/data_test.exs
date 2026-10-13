defmodule HelmsmanWeb.SettingsLive.DataTest do
  @moduledoc """
  Spec web-data-settings (add-data-settings-ui) against the real `Helmsman.Backup` and
  claim functions of `Helmsman.Actors`. Exports run their real worker; imports are
  started for real and either run by their worker or, for end states that need
  specific reports or errors, finished by writing the row and sending the domain's own
  notification (`Backup.notify_import/1`).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures, only: [managed_agent_fixture: 2]
  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]

  alias Helmsman.{Actors, Backup, Events, Members, Repo, Workspaces}
  alias Helmsman.Actors.Actor
  alias Helmsman.Backup.{ExportRecord, Files, ImportRecord}
  alias Helmsman.Backup.Workers.Import, as: ImportWorker
  alias HelmsmanWeb.SettingsLive.Data

  setup %{conn: conn} do
    _admin = user_fixture()
    owner = user_fixture(%{display_name: "olivia"})
    ws = workspace_fixture(owner, %{name: "Acme"})
    users = %{owner: owner}

    users =
      for {role, name} <- [admin: "alice", member: "bob", member2: "carol", viewer: "dave"],
          into: users do
        user = user_fixture(%{display_name: name})
        member_fixture(ws, user, if(role == :member2, do: :member, else: role))
        {role, user}
      end

    on_exit(fn -> File.rm_rf(Files.directory(:imports) |> Path.join("#{ws.id}-*")) end)
    %{conn: conn, ws: ws, users: users, path: "/w/#{ws.slug}/settings/data"}
  end

  defp open(ctx, role, query \\ ""),
    do: live(log_in_user(ctx.conn, ctx.users[role]), ctx.path <> query)

  defp scope(ctx, role), do: workspace_scope_fixture(ctx.users[role], ctx.ws)
  defp row(name), do: "#unclaimed-#{Data.dom_key(name)}"

  defp actor_name(ctx, role), do: scope(ctx, role).actor.name

  defp unclaimed!(ctx, name),
    do: Repo.insert!(%Actor{workspace_id: ctx.ws.id, kind: :human, name: name})

  defp put_import(ctx, attrs) do
    defaults = %{
      workspace_id: ctx.ws.id,
      user_id: ctx.users[:owner].id,
      mode: :merge,
      source: :helmsman,
      status: :succeeded,
      dry_run: false,
      file_name: "acme.json",
      report: %{},
      errors: []
    }

    Repo.insert!(struct(ImportRecord, Map.merge(defaults, Map.new(attrs))))
  end

  # Ends an import with `attrs` and notifies like the import worker does.
  defp finish_import(id, attrs) do
    {:ok, record} =
      Helmsman.Tx.run(fn ->
        record = ImportRecord |> Repo.get!(id) |> Ecto.Changeset.change(attrs) |> Repo.update!()
        Backup.notify_import(record)
        {:ok, record}
      end)

    if record.status == :succeeded and not record.dry_run,
      do:
        Events.broadcast(Events.topic(:workspace, record.workspace_id), {:workspace_imported, id})

    record
  end

  defp imports(ctx),
    do: Repo.all(from(i in ImportRecord, where: i.workspace_id == ^ctx.ws.id, order_by: i.id))

  defp latest_id(ctx), do: List.last(imports(ctx)).id

  defp staged_path(view), do: :sys.get_state(view.pid).socket.assigns.staged.path

  describe "roles" do
    test "an admin sees every section", ctx do
      {:ok, view, _html} = open(ctx, :admin)

      for id <- ~w(data-export data-import data-imports data-identities),
          do: assert(has_element?(view, "##{id}"))

      assert has_element?(view, ~s(nav[aria-label="设置"] a[aria-current="page"]), "数据")
      assert has_element?(view, "header h1", "数据")
      assert page_title(view) == "数据 · Acme"
      refute has_element?(view, "#data-admin-only")
    end

    test "a viewer only sees the identities", ctx do
      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(view, "#data-identities")
      assert has_element?(view, "#data-admin-only", "导出与导入需要管理员权限")

      for id <-
            ~w(data-export data-import data-imports export-button import-button external-agents),
          do: refute(has_element?(view, "##{id}"))
    end

    test "the import panel of a viewer is not opened", ctx do
      assert {:error, {:live_redirect, %{to: path}}} = open(ctx, :viewer, "?panel=import")
      assert path == ctx.path
    end
  end

  describe "export" do
    test "a failed export shows its reason", ctx do
      export =
        Repo.insert!(%ExportRecord{
          workspace_id: ctx.ws.id,
          user_id: ctx.users[:admin].id,
          status: :failed,
          error: "storage unavailable"
        })

      {:ok, view, _html} = open(ctx, :admin)

      assert has_element?(view, "#export-#{export.id}", "失败")
      assert has_element?(view, "#export-#{export.id}", "storage unavailable")
      refute has_element?(view, "#export-#{export.id}-download")
    end

    test "an export in progress by another admin", ctx do
      {:ok, _} = Backup.request_export(scope(ctx, :owner))
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#export-button") |> render_click()

      assert render(view) =~ "已有进行中的导出"
      assert has_element?(view, "#exports-empty")
    end

    test "expired and pruned exports disappear", ctx do
      expired =
        Repo.insert!(%ExportRecord{
          workspace_id: ctx.ws.id,
          user_id: ctx.users[:admin].id,
          status: :succeeded,
          expires_at: DateTime.add(DateTime.utc_now(), -1)
        })

      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, "#export-#{expired.id}")

      {:ok, other} = Backup.request_export(scope(ctx, :admin))
      assert has_element?(view, "#export-#{other.id}")

      # Pruning deletes rows without a notification; a later one finds the row gone.
      Repo.delete!(other)
      send(view.pid, {:export, other.id})
      refute has_element?(view, "#export-#{other.id}")
    end
  end

  describe "import panel" do
    defp upload(view, name \\ "acme.helmsman.json.gz", content \\ "{}") do
      file =
        file_input(view, "#import-upload-form", :import_file, [
          %{name: name, content: content, type: "application/gzip"}
        ])

      render_upload(file, name)
      file
    end

    defp dry_run(view), do: render_submit(view, "dry_run", %{})

    defp panel?(view, selector, text \\ nil), do: in_portal?(view, "import-panel", selector, text)

    test "an admin (not owner) only has merge", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      assert open?(view, "import-panel")
      refute panel?(view, ~s(input[name="import[mode]"][value="replace"]))
    end

    test "replace needs the slug", ctx do
      {:ok, view, _html} = open(ctx, :owner, "?panel=import")
      upload(view)

      assert panel?(view, ~s(input[name="import[mode]"][value="replace"]))
      render_change(view, "validate_import", %{import: %{mode: "replace", confirm: "acm"}})
      assert panel?(view, "#import-replace-warning", "不会被清理")
      assert panel?(view, "#import-dry-run[disabled]")

      render_change(view, "validate_import", %{import: %{mode: "replace", confirm: ctx.ws.slug}})
      refute panel?(view, "#import-dry-run[disabled]")
      dry_run(view)

      [record] = imports(ctx)
      assert record.mode == :replace and record.dry_run
    end

    test "dry run is disabled without a file", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      assert panel?(view, "#import-dry-run[disabled]")
    end

    test "unsupported files are refused", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")

      file =
        file_input(view, "#import-upload-form", :import_file, [
          %{name: "notes.txt", content: "x", type: "text/plain"}
        ])

      assert {:error, [[_, :not_accepted]]} = render_upload(file, "notes.txt")
    end

    test "duplicated old names are flagged", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      render_click(view, "add_rename", %{})
      assert panel?(view, "#rename-1")

      render_change(view, "validate_import", %{
        import: %{rename: %{"0" => %{from: "bob", to: "x"}, "1" => %{from: "bob", to: "y"}}}
      })

      assert panel?(view, "#rename-1", "旧名重复")
      assert panel?(view, "#import-dry-run[disabled]")
    end

    test "the import button opens the panel when no import runs (walkthrough)", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      assert has_element?(view, ~s(a#import-button[href="#{ctx.path}?panel=import"]))
      refute has_element?(view, "#import-button[data-hm-disabled]")

      view |> element("#import-button") |> render_click()
      assert_patch(view, ctx.path <> "?panel=import")
      assert open?(view, "import-panel")
      refute panel?(view, "#import-dry-run[data-hm-disabled]")
    end

    test "the import button is disabled while an import runs", ctx do
      put_import(ctx, status: :running)
      {:ok, view, _html} = open(ctx, :admin)
      assert has_element?(view, "#import-button[disabled]")
      assert has_element?(view, "#import-button[data-hm-disabled]")
      refute has_element?(view, "a#import-button")
      assert has_element?(view, "#import-busy", "已有进行中的导入")
    end
  end

  describe "dry run and confirm" do
    test "changing the options after the preview needs a new dry run", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      finish_import(latest_id(ctx), status: :succeeded, report: %{})
      assert panel?(view, "#import-confirm-button")

      render_change(view, "validate_import", %{
        import: %{rename: %{"0" => %{from: "bob", to: "robert"}}}
      })

      assert panel?(view, "#import-stale", "预览已失效")
      refute panel?(view, "#import-confirm-button")
      assert panel?(view, "#import-dry-run")
    end

    test "a forced change during the dry run drops its result", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      first = latest_id(ctx)
      assert panel?(view, "#import-form fieldset[disabled]")

      render_change(view, "validate_import", %{import: %{source: "bosun"}})
      finish_import(first, status: :succeeded, report: %{})

      refute panel?(view, "#import-confirm-button")
      render_click(view, "confirm_import", %{})
      assert length(imports(ctx)) == 1

      dry_run(view)
      second = Repo.get!(ImportRecord, latest_id(ctx))
      assert second.source == :bosun
      finish_import(second.id, status: :succeeded, report: %{})
      render_click(view, "confirm_import", %{})
      real = Repo.get!(ImportRecord, latest_id(ctx))
      refute real.dry_run
      assert real.source == :bosun
      assert Map.delete(real.options, "dry_run") == Map.delete(second.options, "dry_run")
    end

    test "closing during the dry run abandons it", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      first = latest_id(ctx)
      old_path = staged_path(view)

      render_patch(view, ctx.path)
      refute File.exists?(old_path)
      render_patch(view, ctx.path <> "?panel=import")
      upload(view, "other.json", "{}")

      finish_import(first, status: :succeeded, report: %{})
      refute panel?(view, "#import-confirm-button")
      refute panel?(view, "#import-preview")
      assert panel?(view, "#import-dry-run")
    end

    test "switching to another panel abandons the preview (code review 1 P2-1)", ctx do
      history = put_import(ctx, status: :succeeded, user_id: ctx.users[:admin].id)
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      staged = staged_path(view)
      finish_import(latest_id(ctx), status: :succeeded, report: %{})
      assert panel?(view, "#import-confirm-button")

      render_patch(view, ctx.path <> "?import=#{history.id}")
      refute File.exists?(staged)
      render_patch(view, ctx.path <> "?panel=import")

      refute panel?(view, "#import-confirm-button")
      refute panel?(view, "#import-staged")
      render_click(view, "confirm_import", %{})
      assert length(imports(ctx)) == 2
    end

    test "a result arriving after switching away mid dry run is not confirmable", ctx do
      unclaimed!(ctx, "robert")
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      first = latest_id(ctx)

      render_patch(
        view,
        ctx.path <> "?" <> URI.encode_query(%{"panel" => "assign", "actor" => "robert"})
      )

      finish_import(first, status: :succeeded, report: %{})
      render_patch(view, ctx.path <> "?panel=import")

      refute panel?(view, "#import-preview")
      refute panel?(view, "#import-confirm-button")
      assert panel?(view, "#import-dry-run[disabled]")
    end

    test "a dry run changes nothing and is listed as such", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      id = latest_id(ctx)
      finish_import(id, status: :succeeded, report: %{})
      assert has_element?(view, "#import-#{id}", "试运行")
      refute has_element?(view, "#hm-import-notice")
    end

    test "locally newer tasks are capped at 50", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      newer = for n <- 1..53, do: "BOS-#{n}"
      finish_import(latest_id(ctx), status: :succeeded, report: %{"local_newer" => newer})

      assert panel?(view, "#import-preview-report-local-newer", "等 3 个")
      link = "#import-preview-report-local-newer a[href=\"/w/#{ctx.ws.slug}/t/BOS-"
      assert panel?(view, link <> "50\"]")
      refute panel?(view, link <> "51\"]")
    end

    test "the temporary file goes away with the LiveView", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      path = staged_path(view)
      assert File.exists?(path)

      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      Process.sleep(100)
      refute File.exists?(path)
    end
  end

  describe "errors" do
    defp fail_with(ctx, errors) do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      dry_run(view)
      finish_import(latest_id(ctx), status: :failed, errors: errors)
      view
    end

    test "a real invalid file fails validation and keeps the form", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view, "broken.json", "{")
      dry_run(view)
      assert :ok = ImportWorker.perform(%Oban.Job{args: %{"id" => latest_id(ctx)}})

      assert panel?(view, "#import-errors")
      assert panel?(view, "#import-staged")
      refute panel?(view, "#import-dry-run[disabled]")
    end

    test "validation errors list their paths", ctx do
      view = fail_with(ctx, [%{"path" => "tasks[12].title", "message" => "can't be blank"}])

      assert panel?(view, "#import-errors", "tasks[12].title")
      assert panel?(view, "#import-errors", "文件未写入任何数据")
    end

    test "actor kind conflicts suggest renaming", ctx do
      view =
        fail_with(ctx, [
          %{
            "reason" => "actor_kind_conflict",
            "detail" => %{"path" => "actors[2]", "message" => "keel is an agent"}
          }
        ])

      assert panel?(view, "#import-errors", "身份种类冲突")
      assert panel?(view, "#import-errors", "可在身份改名中把它改为其他名字")
      assert panel?(view, "#import-errors", "actors[2]")
    end

    test "blocked replace lists the tasks", ctx do
      view =
        fail_with(ctx, [
          %{
            "reason" => "replace_blocked",
            "detail" => [%{"task" => "BOS-7", "reason" => "open_pr"}]
          }
        ])

      assert panel?(view, ~s(#import-errors a[href="/w/#{ctx.ws.slug}/t/BOS-7"]))
      assert panel?(view, "#import-errors", "有未关闭的 PR")
    end

    test "busy is reported at once", ctx do
      {:ok, view, _html} = open(ctx, :admin, "?panel=import")
      upload(view)
      put_import(ctx, status: :queued)
      dry_run(view)
      assert panel?(view, "#import-errors", "工作区正忙")
    end

    test "untrusted text is escaped", ctx do
      view = fail_with(ctx, [%{"path" => "tasks[0]", "message" => "<script>alert(1)</script>"}])

      html = render(view)
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      warned =
        put_import(ctx,
          report: %{"warnings" => [%{"path" => "saved_filters[0]", "message" => "<b>bad</b>"}]}
        )

      {:ok, view, _html} = open(ctx, :admin, "?import=#{warned.id}")
      refute render(view) =~ "<b>bad</b>"
    end
  end

  describe "history" do
    test "a failed import opens its detail", ctx do
      row =
        put_import(ctx,
          status: :failed,
          user_id: ctx.users[:admin].id,
          file_name: "old.json",
          errors: [
            %{"reason" => "diverged", "detail" => %{"path" => "tasks[3]", "message" => "differs"}}
          ]
        )

      {:ok, view, _html} = open(ctx, :admin)
      assert has_element?(view, "#import-#{row.id}", "old.json")
      assert has_element?(view, "#import-#{row.id}", actor_name(ctx, :admin))

      view |> element("#import-#{row.id} a") |> render_click()
      assert_patch(view, ctx.path <> "?import=#{row.id}")
      assert in_portal?(view, "import-detail-panel", "#import-detail-errors", "任务历史与本地分叉")
      assert in_portal?(view, "import-detail-panel", "#import-detail-errors", "tasks[3]")
    end

    test "an open detail follows the import (code review 1 P2-2)", ctx do
      row = put_import(ctx, status: :queued)
      {:ok, view, _html} = open(ctx, :admin, "?import=#{row.id}")
      assert in_portal?(view, "import-detail-panel", "#import-detail", "排队中")

      finish_import(row.id, status: :running)
      assert in_portal?(view, "import-detail-panel", "#import-detail", "运行中")

      finish_import(row.id,
        status: :succeeded,
        report: %{"counts" => %{"tasks" => %{"created" => 4}}}
      )

      assert in_portal?(view, "import-detail-panel", "#import-detail-report-count-tasks", "4")
    end

    test "an open detail of a failed import shows its errors live", ctx do
      row = put_import(ctx, status: :running)
      {:ok, view, _html} = open(ctx, :admin, "?import=#{row.id}")
      finish_import(row.id, status: :failed, errors: [%{"reason" => "busy"}])
      assert in_portal?(view, "import-detail-panel", "#import-detail-errors", "工作区正忙")
    end

    test "an open detail whose import can no longer be read closes", ctx do
      row = put_import(ctx, status: :queued)
      {:ok, view, _html} = open(ctx, :admin, "?import=#{row.id}")
      Repo.delete!(row)
      send(view.pid, {:import, row.id})
      assert_patch(view, ctx.path)
      assert render(view) =~ "导入记录不存在"
    end

    test "an unknown import closes the panel", ctx do
      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               open(ctx, :admin, "?import=999999")

      assert path == ctx.path
      assert flash["error"] == "导入记录不存在"
    end

    test "only the latest 50 imports are listed", ctx do
      for _ <- 1..51, do: put_import(ctx, status: :succeeded)
      {:ok, view, _html} = open(ctx, :admin)

      assert view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#imports > li")
             |> Enum.count() == 50
    end

    test "another admin's import shows up live", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      path = Path.join(System.tmp_dir!(), "hm-data-test-#{System.unique_integer([:positive])}")
      File.write!(path, "{")
      on_exit(fn -> File.rm(path) end)
      {:ok, row} = Backup.start_import(scope(ctx, :owner), path, mode: :merge)

      assert has_element?(view, "#import-#{row.id}", "排队中")
      assert has_element?(view, "#import-button[disabled]")

      assert :ok = ImportWorker.perform(%Oban.Job{args: %{"id" => row.id}})
      assert has_element?(view, "#import-#{row.id}", "失败")
      refute has_element?(view, "#import-button[disabled]")
    end
  end

  describe "identities" do
    setup ctx do
      unclaimed!(ctx, "robert")
      :ok
    end

    test "empty state", ctx do
      Repo.delete_all(
        from(a in Actor, where: a.workspace_id == ^ctx.ws.id and a.name == "robert")
      )

      {:ok, view, _html} = open(ctx, :member)
      assert has_element?(view, "#unclaimed-empty", "没有待认领的身份")
    end

    test "requesting and being approved", ctx do
      {:ok, bob, _html} = open(ctx, :member)
      {:ok, admin, _html} = open(ctx, :admin)

      bob |> element("#{row("robert")} button", "这是我") |> render_click()
      assert in_portal?(bob, "data-confirm", "#data-confirm", "无法撤销")
      render_click(bob, "confirm_request", %{"name" => "robert"})
      assert has_element?(bob, row("robert"), "你已申请")

      {:ok, [claim]} = Actors.list_claims(scope(ctx, :admin))
      assert has_element?(admin, "#claim-#{claim.id}")

      admin |> element("#claim-#{claim.id} button", "批准") |> render_click()
      assert in_portal?(admin, "data-confirm", "#data-confirm", "批准并合并")
      render_click(admin, "confirm_approve", %{"id" => claim.id})
      assert render(admin) =~ "已把 robert 合并到"
      refute has_element?(admin, row("robert"))
      refute has_element?(bob, row("robert"))
    end

    test "withdrawing a claim", ctx do
      {:ok, _} = Actors.request_claim(scope(ctx, :member), "robert")
      {:ok, view, _html} = open(ctx, :member)
      view |> element("#{row("robert")} button", "撤回申请") |> render_click()
      assert has_element?(view, "#{row("robert")} button", "这是我")
    end

    test "members only see their own claims", ctx do
      {:ok, claim} = Actors.request_claim(scope(ctx, :member), "robert")
      {:ok, carol, _html} = open(ctx, :member2)
      {:ok, bob, _html} = open(ctx, :member)
      {:ok, admin, _html} = open(ctx, :admin)

      assert has_element?(carol, "#{row("robert")} button", "这是我")
      refute has_element?(carol, "#claim-#{claim.id}")
      refute render(carol) =~ "申请认领"
      refute has_element?(carol, "#{row("robert")} a", "指定给成员")

      assert has_element?(bob, row("robert"), "你已申请")
      assert has_element?(bob, "#{row("robert")} button", "撤回申请")
      refute has_element?(bob, "#claim-#{claim.id}")

      assert has_element?(admin, "#claim-#{claim.id} button", "批准")
      assert has_element?(admin, "#claim-#{claim.id} button", "拒绝")
    end

    test "a claim from another page appears for admins only", ctx do
      {:ok, admin, _html} = open(ctx, :admin)
      {:ok, carol, _html} = open(ctx, :member2)
      {:ok, claim} = Actors.request_claim(scope(ctx, :viewer), "robert")

      assert has_element?(admin, "#claim-#{claim.id}", "申请认领")
      refute has_element?(carol, "#claim-#{claim.id}")
    end

    test "a claim handled by someone else", ctx do
      {:ok, claim} = Actors.request_claim(scope(ctx, :member), "robert")
      {:ok, view, _html} = open(ctx, :admin)
      {:ok, _} = Actors.decide_claim(scope(ctx, :owner), claim.id, :approve)

      render_click(view, "reject_claim", %{"id" => to_string(claim.id)})
      assert render(view) =~ "该身份或申请已被处理"
      refute has_element?(view, row("robert"))
    end

    test "assigning to a member", ctx do
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#{row("robert")} a", "指定给成员") |> render_click()

      assert_patch(
        view,
        ctx.path <> "?" <> URI.encode_query(%{"panel" => "assign", "actor" => "robert"})
      )

      assert in_portal?(view, "assign-panel", "#assign-user option", actor_name(ctx, :member))
      render_submit(view, "assign", %{assign: %{user_id: ctx.users[:member].id}})

      assert in_portal?(view, "data-confirm", "#data-confirm", "此操作无法撤销")
      render_click(view, "confirm_assign", %{})
      assert_patch(view, ctx.path)
      refute has_element?(view, row("robert"))
      refute Repo.get_by(Actor, workspace_id: ctx.ws.id, name: "robert")
    end

    test "the assign panel closes when the identity is merged elsewhere", ctx do
      {:ok, view, _html} =
        open(ctx, :admin, "?" <> URI.encode_query(%{"panel" => "assign", "actor" => "robert"}))

      assert in_portal?(view, "assign-panel", "#assign-form")
      {:ok, _} = Actors.claim_for(scope(ctx, :owner), "robert", ctx.users[:member].id)
      assert_patch(view, ctx.path)
      assert render(view) =~ "该身份或申请已被处理"
    end

    test "the assign dialog closes when the chosen member leaves (code review 1 P2-3)", ctx do
      {:ok, view, _html} =
        open(ctx, :admin, "?" <> URI.encode_query(%{"panel" => "assign", "actor" => "robert"}))

      render_submit(view, "assign", %{assign: %{user_id: ctx.users[:member].id}})
      assert open?(view, "data-confirm")

      membership = Workspaces.get_membership(ctx.ws.id, ctx.users[:member].id)
      {:ok, _} = Members.remove(scope(ctx, :owner), membership.id)

      assert_patch(view, ctx.path)
      refute open?(view, "data-confirm")
      refute open?(view, "assign-panel")
      assert render(view) =~ "该身份或申请已被处理"

      render_click(view, "confirm_assign", %{})
      assert Repo.get_by(Actor, workspace_id: ctx.ws.id, name: "robert")
    end

    test "the approve dialog closes when another admin handles the claim", ctx do
      {:ok, claim} = Actors.request_claim(scope(ctx, :member), "robert")
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#claim-#{claim.id} button", "批准") |> render_click()
      assert open?(view, "data-confirm")

      {:ok, _} = Actors.decide_claim(scope(ctx, :owner), claim.id, :reject)
      refute open?(view, "data-confirm")
      assert render(view) =~ "该身份或申请已被处理"
    end

    test "the approve dialog closes when the applicant leaves", ctx do
      {:ok, claim} = Actors.request_claim(scope(ctx, :member), "robert")
      {:ok, view, _html} = open(ctx, :admin)
      view |> element("#claim-#{claim.id} button", "批准") |> render_click()

      membership = Workspaces.get_membership(ctx.ws.id, ctx.users[:member].id)
      {:ok, _} = Members.remove(scope(ctx, :owner), membership.id)
      refute open?(view, "data-confirm")
    end

    test "the unclaimed mark follows the identity onto task pages", ctx do
      owner = scope(ctx, :owner)
      Helmsman.ProjectsFixtures.project_fixture(owner, %{key: "BOS", name: "Bosun"})
      task = Helmsman.ProjectsFixtures.task_fixture(owner, "BOS")
      robert = Repo.get_by!(Actor, workspace_id: ctx.ws.id, name: "robert")

      Repo.update_all(from(t in Helmsman.Tasks.Task, where: t.id == ^task.id),
        set: [created_by_id: robert.id]
      )

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.users[:member]), "/w/#{ctx.ws.slug}/t/#{task.ident}")

      assert render(view) =~ "robert（未认领）"
    end
  end

  describe "external agents" do
    test "an admin transfers an agent", ctx do
      agent_fixture(ctx.ws, ctx.users[:admin], "bob/dev")
      {:ok, view, _html} = open(ctx, :admin)
      key = Data.dom_key("bob/dev")
      assert has_element?(view, "#agent-#{key}", "alice")

      view |> element("#agent-#{key} a", "转给") |> render_click()
      assert in_portal?(view, "transfer-panel", "#transfer-form", "不能再以它的身份写入")
      render_submit(view, "transfer", %{transfer: %{user_id: ctx.users[:member].id}})

      assert render(view) =~ "已把 bob/dev 转给"
      assert has_element?(view, "#agent-#{key}", "bob")

      assert Repo.get_by!(Actor, workspace_id: ctx.ws.id, name: "bob/dev").owner_id ==
               ctx.users[:member].id
    end

    test "members do not see the section", ctx do
      {:ok, view, _html} = open(ctx, :member)
      refute has_element?(view, "#external-agents")
    end

    test "managed agents are not offered", ctx do
      managed_agent_fixture(scope(ctx, :admin), %{name: "keel/dev"})
      {:ok, view, _html} = open(ctx, :admin)
      refute has_element?(view, "#agent-#{Data.dom_key("keel/dev")}")

      query = "?" <> URI.encode_query(%{"panel" => "transfer", "agent" => "keel/dev"})
      assert {:error, {:live_redirect, %{flash: flash}}} = open(ctx, :admin, query)
      assert flash["error"] =~ "不是外接 Agent"
    end

    test "an agent gone before the transfer", ctx do
      agent = agent_fixture(ctx.ws, ctx.users[:admin], "bob/dev")
      query = "?" <> URI.encode_query(%{"panel" => "transfer", "agent" => "bob/dev"})
      {:ok, view, _html} = open(ctx, :admin, query)
      Repo.delete!(agent)

      render_submit(view, "transfer", %{transfer: %{user_id: ctx.users[:member].id}})
      assert render(view) =~ "该身份或申请已被处理"
    end
  end
end
