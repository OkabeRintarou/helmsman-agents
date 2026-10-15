defmodule HelmsmanWeb.SpecArchiveTest do
  @moduledoc """
  Spec web-specs 导出 OpenSpec 目录 and 导入 OpenSpec 目录 (add-spec-workflow-ui D11, tasks
  3.4, 3.5, 6.3): the export download and the import panel, on the real
  `Helmsman.TaskSpecs` archive functions.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.TaskSpecsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.TaskSpecs

  @panel "spec-import-panel"

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 3, change_id: "add-settings-page")
    Map.put(ctx, :conn, conn)
  end

  defp export(ctx, user, query),
    do: get(log_in_user(ctx.conn, user), "/w/#{ctx.slug}/t/#{ctx.ident}/spec/export?" <> query)

  describe "导出 OpenSpec 目录" do
    test "下载 tar.gz", ctx do
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.vic), ctx.path <> "?panel=export")
      assert open?(view, "spec-export-panel")

      render_change(view, "export_change", %{
        "export" => %{"version" => "3", "format" => "tar.gz", "reviews" => "true"}
      })

      href = portal_attr(view, "spec-export-panel", "#spec-export-download", "href")

      assert href ==
               "/w/#{ctx.slug}/t/#{ctx.ident}/spec/export?version=3&format=tar.gz&reviews=true"

      conn = get(log_in_user(build_conn(), ctx.vic), href)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/gzip"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(filename="add-settings-page-v3.tar.gz")
      {:ok, entries} = :erl_tar.extract({:binary, conn.resp_body}, [:memory, :compressed])

      assert {~c"add-settings-page/proposal.md", _} =
               List.keyfind(entries, ~c"add-settings-page/proposal.md", 0)
    end

    test "zip", ctx do
      conn = export(ctx, ctx.alice, "version=1&format=zip")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/zip"]
    end

    test "不存在的版本, another workspace, a malformed version", ctx do
      assert export(ctx, ctx.alice, "version=9").status == 404
      assert export(ctx, ctx.alice, "version=x").status == 404

      other = user_fixture()
      ws = workspace_fixture(other)
      scope = workspace_scope_fixture(other, ws)
      task = task_fixture(scope, project_fixture(scope, %{key: "OPS"}).key)
      spec_fixture(scope, task.ident)

      conn = get(log_in_user(ctx.conn, ctx.alice), "/w/#{ws.slug}/t/#{task.ident}/spec/export")
      assert conn.status == 404
    end

    test "logged out", ctx do
      conn = get(ctx.conn, "/w/#{ctx.slug}/t/#{ctx.ident}/spec/export")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "导入 OpenSpec 目录" do
    # A tar.gz of `[{name, content}]`, through a temporary file (`:erl_tar` writes files).
    defp archive(entries) do
      path =
        Path.join(System.tmp_dir!(), "spec-archive-#{System.unique_integer([:positive])}.tar.gz")

      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
      body = File.read!(path)
      File.rm!(path)
      body
    end

    defp upload(view, name, binary) do
      file =
        file_input(view, "#spec-import-upload-form", :spec_archive, [
          %{name: name, content: binary, type: "application/gzip"}
        ])

      render_upload(file, name)
    end

    test "预览后导入", ctx do
      files = spec_files(tag: "imported")

      binary =
        archive(
          for({path, content} <- files, do: {~c"openspec/changes/add-x/#{path}", content}) ++
            [{~c"openspec/changes/add-x/reviews/spec-review-1.md", "# review"}]
        )

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path <> "?panel=import")
      assert open?(view, @panel)
      upload(view, "add-x.tar.gz", binary)

      assert in_portal?(view, @panel, "#spec-import-preview")
      assert in_portal?(view, @panel, "#spec-import-validation", "校验通过")
      refute in_portal?(view, @panel, "#spec-import-warnings")
      assert in_portal?(view, @panel, "[data-path='proposal.md'][data-change=modified]")
      assert in_portal?(view, @panel, "#spec-import-submit", "导入为 v4")
      assert {:ok, %{latest_version: 3}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)

      render_submit(view, "import_submit", %{"import" => %{"note" => "from the repo"}})
      assert render(view) =~ "已导入为 v4"
      refute open?(view, @panel)
      assert {:ok, %{latest_version: 4}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    end

    test "带链接的压缩包", ctx do
      dir = Path.join(System.tmp_dir!(), "spec-link-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "add-x"))
      File.ln_s!("/etc/passwd", Path.join(dir, "add-x/proposal.md"))
      tar = Path.join(dir, "x.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(tar),
          [{~c"add-x/proposal.md", String.to_charlist(Path.join(dir, "add-x/proposal.md"))}],
          [:compressed]
        )

      binary = File.read!(tar)
      File.rm_rf!(dir)

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path <> "?panel=import")
      upload(view, "x.tar.gz", binary)

      assert in_portal?(view, @panel, "[role=alert]", "压缩包不合法")
      refute in_portal?(view, @panel, "#spec-import-submit")
      assert {:ok, %{latest_version: 3}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    end

    test "stale: 重新预览; closing drops the archive", ctx do
      binary =
        archive(for {path, content} <- spec_files(tag: "i"), do: {~c"add-x/#{path}", content})

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path <> "?panel=import")
      upload(view, "add-x.tar.gz", binary)
      assert in_portal?(view, @panel, "#spec-import-submit", "导入为 v4")

      submit(ctx.alice_scope, ctx, 3, spec_files(tag: "v4"))
      render_submit(view, "import_submit", %{"import" => %{"note" => ""}})
      assert in_portal?(view, @panel, "#spec-import-stale", "已有新版本 v4")

      render_click(view, "import_preview", %{})
      assert in_portal?(view, @panel, "#spec-import-submit", "导入为 v5")

      render_patch(view, ctx.path)
      refute open?(view, @panel)
      assert :sys.get_state(view.pid).socket.assigns.import_panel == nil
      refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "Settings get lost. i"
    end
  end
end
