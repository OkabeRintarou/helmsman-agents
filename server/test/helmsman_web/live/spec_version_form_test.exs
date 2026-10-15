defmodule HelmsmanWeb.SpecVersionFormTest do
  @moduledoc """
  Spec web-specs 提交新版本 (add-spec-workflow-ui D8, tasks 3.1): the panel on the real
  domain, and `HelmsmanWeb.SpecVersionForm`'s pure parts.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.TaskSpecs
  alias HelmsmanWeb.SpecVersionForm

  @panel "spec-version-panel"

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    Map.put(ctx, :conn, conn)
  end

  defp open(ctx, query), do: live(log_in_user(ctx.conn, ctx.alice), ctx.path <> query)

  defp index(view, path) do
    view
    |> portal(@panel)
    |> LazyHTML.query("[data-path='#{path}']")
    |> LazyHTML.attribute("id")
    |> hd()
    |> String.replace("spec-version-file-", "")
  end

  defp files(ident, scope, n) do
    {:ok, %{version: %{files: files}}} = TaskSpecs.get(scope, ident, version: n)
    Map.new(files, &{&1.path, &1.content})
  end

  test "起草第一版", ctx do
    {:ok, view, _html} = open(ctx, "")
    view |> element("#spec-empty-draft") |> render_click()
    assert open?(view, @panel)
    assert in_portal?(view, @panel, "#spec-version-panel-title", "提交 v1")
    assert in_portal?(view, @panel, "[data-path='proposal.md'][data-state=added]")
    assert in_portal?(view, @panel, "[data-path='specs/core/spec.md']")

    assert portal_attr(view, @panel, "#spec-version-change-id", "value") ==
             String.downcase(ctx.ident)

    i = index(view, "proposal.md")

    render_submit(view, "ver_submit", %{
      "version" => %{
        "files" => %{i => "## Why\n\nBecause.\n\n## What Changes\n\n- X\n"},
        "note" => "first"
      }
    })

    assert render(view) =~ "已提交 v1"
    assert has_element?(view, "#spec-version-1")
    refute open?(view, @panel)
    assert has_element?(view, "#spec-file-path", "proposal.md")
    assert files(ctx.ident, ctx.alice_scope, 1)["proposal.md"] =~ "Because."
  end

  test "只发送改动", ctx do
    submit(ctx.alice_scope, ctx, 0, spec_files())
    {:ok, view, _html} = open(ctx, "?panel=version")

    spec = index(view, "specs/settings/spec.md")
    tasks = index(view, "tasks.md")
    new_spec = spec_files(tag: "two")["specs/settings/spec.md"]

    render_change(view, "ver_change", %{"version" => %{"files" => %{spec => new_spec}}})
    assert in_portal?(view, @panel, "[data-path='specs/settings/spec.md'][data-state=changed]")
    # tasks.md cannot be removed; the removal of a removable file is undone with 撤销删除.
    render_click(view, "ver_remove", %{"index" => tasks})
    refute in_portal?(view, @panel, "[data-path='tasks.md'][data-state=removed]")

    form = :sys.get_state(view.pid).socket.assigns.version_form

    form =
      SpecVersionForm.remove(
        %{
          form
          | files:
              form.files ++
                [hd(form.files) |> Map.merge(%{path: "design.md", original: "x", content: "x"})]
        },
        length(form.files)
      )

    attrs = SpecVersionForm.attrs(form)
    assert attrs.base_version == 1
    assert attrs.files == [%{path: "specs/settings/spec.md", content: new_spec}]
    assert attrs.remove == ["design.md"]

    render_submit(view, "ver_submit", %{"version" => %{"files" => %{spec => new_spec}}})
    v2 = files(ctx.ident, ctx.alice_scope, 2)
    assert v2["specs/settings/spec.md"] == new_spec
    assert v2["proposal.md"] == spec_files()["proposal.md"]
  end

  test "removing a file sends it in remove", ctx do
    submit(ctx.alice_scope, ctx, 0, Map.put(spec_files(), "design.md", "## Context\n"))
    {:ok, view, _html} = open(ctx, "?panel=version")
    design = index(view, "design.md")

    render_click(view, "ver_remove", %{"index" => design})
    assert in_portal?(view, @panel, "[data-path='design.md'][data-state=removed]")
    render_submit(view, "ver_submit", %{"version" => %{}})

    refute Map.has_key?(files(ctx.ident, ctx.alice_scope, 2), "design.md")
  end

  test "版本冲突", ctx do
    submit(ctx.alice_scope, ctx, 0, spec_files())
    submit(ctx.alice_scope, ctx, 1, spec_files(tag: "v2"))
    {:ok, view, _html} = open(ctx, "?panel=version")
    proposal = index(view, "proposal.md")
    mine = "## Why\n\nalice's why\n\n## What Changes\n\n- mine\n"
    render_change(view, "ver_change", %{"version" => %{"files" => %{proposal => mine}}})

    # keel/fe submits v3 meanwhile (changing proposal.md too): an early notice.
    fe_files = spec_files(tag: "v3")
    submit(run_scope(ctx, ctx.fe), ctx, 2, fe_files)
    eventually(fn -> in_portal?(view, @panel, "#spec-version-stale", "keel/fe 已提交 v3") end)

    render_submit(view, "ver_submit", %{"version" => %{"files" => %{proposal => mine}}})
    assert in_portal?(view, @panel, "#spec-version-stale", "keel/fe 已提交 v3")
    assert portal_text(view, @panel, "#spec-version-file-#{proposal}-content") =~ "alice's why"
    assert portal_attr(view, @panel, "#spec-version-stale-diff", "href") =~ "from=2&tab=diff&to=3"

    render_click(view, "ver_rebase", %{})
    assert in_portal?(view, @panel, "#spec-version-panel-title", "提交 v4")
    assert in_portal?(view, @panel, "[data-path='proposal.md'] [data-conflict]", "将覆盖 v3 的修改")
    tasks = index(view, "tasks.md")
    assert portal_text(view, @panel, "#spec-version-file-#{tasks}-content") =~ "v3"
    assert portal_text(view, @panel, "#spec-version-file-#{proposal}-content") =~ "alice's why"

    render_submit(view, "ver_submit", %{"version" => %{}})
    v4 = files(ctx.ident, ctx.alice_scope, 4)
    assert v4["proposal.md"] == mine
    assert v4["tasks.md"] == fe_files["tasks.md"]
  end

  test "超出大小", ctx do
    submit(ctx.alice_scope, ctx, 0, spec_files())
    {:ok, view, _html} = open(ctx, "?panel=version")
    i = index(view, "proposal.md")

    render_change(view, "ver_change", %{
      "version" => %{"files" => %{i => String.duplicate("a", 262_145)}}
    })

    assert in_portal?(view, @panel, "#spec-version-file-#{i} [data-bytes].text-danger-fg")
    assert in_portal?(view, @panel, "#spec-version-submit[disabled]")
  end

  test "校验 is a dry run; no_changes; a capability", ctx do
    submit(ctx.alice_scope, ctx, 0, spec_files())
    {:ok, view, _html} = open(ctx, "?panel=version")
    spec = index(view, "specs/settings/spec.md")

    render_change(view, "ver_change", %{
      "version" => %{"files" => %{spec => spec_files(invalid: true)["specs/settings/spec.md"]}}
    })

    render_click(view, "ver_validate", %{})
    assert in_portal?(view, @panel, "#spec-version-validation", "需求没有场景")
    assert in_portal?(view, @panel, "#spec-version-draft-note", "定稿前需要修好")
    assert {:ok, %{latest_version: 1}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)

    render_change(view, "ver_change", %{
      "version" => %{"files" => %{spec => spec_files()["specs/settings/spec.md"]}}
    })

    render_submit(view, "ver_submit", %{"version" => %{}})
    assert in_portal?(view, @panel, "[role=alert]", "没有可提交的修改")

    render_change(view, "ver_change", %{"version" => %{"cap" => "Bad Cap"}})

    assert in_portal?(
             view,
             @panel,
             "#spec-version-cap ~ p, [phx-feedback-for], p",
             "capability 是 1–3 段"
           )

    render_change(view, "ver_change", %{"version" => %{"cap" => "api/v1"}})
    render_click(view, "ver_add", %{})
    assert in_portal?(view, @panel, "[data-path='specs/api/v1/spec.md'][data-state=added]")
  end

  test "invalid files are marked on their row" do
    form = SpecVersionForm.new(1, %{"proposal.md" => "a", "tasks.md" => "b"})

    form =
      SpecVersionForm.put_error(
        form,
        {:spec, :invalid_files, [%{path: "tasks.md", message: "is not valid UTF-8"}]},
        nil
      )

    assert form.file_errors == %{"tasks.md" => "is not valid UTF-8"}
    assert form.error =~ "tasks.md is not valid UTF-8"
  end
end
