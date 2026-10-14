defmodule HelmsmanWeb.AutopilotLiveTest do
  @moduledoc """
  Spec web-autopilots 自动化列表页, 自动化详情页, 立即运行, Webhook 令牌, 触发历史, 自动化页实时刷新
  (add-squads-autopilots-ui D8, D11, D12, D14), against `Helmsman.Autopilots`.

  Records in states the domain only reaches over time (finished runs, retention, many
  pages) are inserted with `Repo`; realtime tests drive the domain (run now, settle,
  disable, delete) and observe its notifications.
  """
  use HelmsmanWeb.ConnCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures, only: [agent_actor: 2, profile: 1, run_fixture: 1]
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Agents, Autopilots, Projects, Repo, Runtimes}
  alias Helmsman.Autopilots.{Autopilot, Record, State}
  alias Helmsman.Autopilots.Workers.Prune
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    bob = user_fixture(%{display_name: "bob"})
    carol = user_fixture(%{display_name: "carol"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, bob, :member)
    member_fixture(ws, carol, :admin)
    member_fixture(ws, vic, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)
    bob_scope = workspace_scope_fixture(bob, ws)

    project_fixture(alice_scope, %{key: "BOS", name: "Backoffice"})
    managed_agent_fixture(alice_scope, %{name: "keel/triage"})
    managed_agent_fixture(alice_scope, %{name: "keel/shared", access: "workspace"})

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, bob: bob, carol: carol, vic: vic},
      alice_scope: alice_scope,
      bob_scope: bob_scope,
      alice_name: alice_scope.actor.name,
      bob_name: bob_scope.actor.name,
      list: "/w/#{ws.slug}/autopilots"
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)
  defp show_path(ctx, id), do: "#{ctx.list}/#{id}"

  defp create!(scope, attrs) do
    {:ok, view} = Autopilots.create(scope, attrs)
    view.id
  end

  defp nightly(ctx, attrs \\ %{}) do
    create!(
      ctx.alice_scope,
      Map.merge(
        %{
          name: "nightly-triage",
          agent: "keel/triage",
          project: "BOS",
          mode: "create_task",
          title_template: "Triage {{date}}",
          cron: "0 9 * * 1-5",
          timezone: "Asia/Shanghai",
          instructions: "Look at **new** issues."
        },
        Map.new(attrs)
      )
    )
  end

  defp run_only(ctx, attrs \\ %{}) do
    create!(
      ctx.alice_scope,
      Map.merge(
        %{
          name: "dep-bump",
          agent: "keel/triage",
          mode: "run_only",
          cron: "0 3 * * *",
          instructions: "Bump the dependencies."
        },
        Map.new(attrs)
      )
    )
  end

  # Disabled after five failures: a state reached over days of failed triggers.
  defp dep_bump(ctx, reason \\ :consecutive_failures) do
    id = run_only(ctx)
    set!(id, enabled: false, disabled_reason: reason, consecutive_failures: 5, next_run_at: nil)
    id
  end

  defp set!(id, changes),
    do: Repo.update_all(from(a in Autopilot, where: a.id == ^id), set: changes)

  defp row!(id), do: Repo.get(Autopilot, id)

  defp insert_record(id, attrs) do
    autopilot = Repo.get!(Autopilot, id)

    Repo.insert!(
      struct!(
        Record,
        Map.merge(
          %{
            workspace_id: autopilot.workspace_id,
            autopilot_id: id,
            source: :schedule,
            status: :succeeded,
            config: State.snapshot(autopilot)
          },
          Map.new(attrs)
        )
      )
    ).id
  end

  defp run_now!(scope, id) do
    {:ok, record} = Autopilots.run_now(scope, id)
    record
  end

  defp finish_task!(%Record{task_id: task_id, autopilot_id: id}, status) do
    Repo.update_all(from(t in Task, where: t.id == ^task_id), set: [status: status])
    {:ok, _} = Autopilots.settle(id)
  end

  defp finish_run!(%Record{run_id: run_id, autopilot_id: id}, changes) do
    Repo.update_all(from(r in Run, where: r.id == ^run_id),
      set: [finished_at: DateTime.utc_now()] ++ changes
    )

    {:ok, _} = Autopilots.settle(id)
  end

  defp record_ids(view) do
    ~r/id="record-(\d+)"/
    |> Regex.scan(render(element(view, "#autopilot-records")))
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  defp token_in_dialog(view) do
    [token] =
      Regex.run(
        ~r/hma_[A-Za-z0-9_-]+/,
        portal_text(view, "webhook-token-dialog", "#webhook-token-value")
      )

    token
  end

  defp row(id), do: "#autopilot-#{id}"
  defp record(id), do: "#record-#{id}"

  describe "list page" do
    test "list content", ctx do
      night = nightly(ctx)
      insert_record(night, status: :succeeded, finished_at: DateTime.utc_now())
      dep = dep_bump(ctx)

      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      assert page_title(view) =~ "自动化"
      assert has_element?(view, "#{row(night)} [data-mode]", "建任务")
      assert has_element?(view, "#{row(night)} [data-target]", "keel/triage")
      assert has_element?(view, "#{row(night)} [data-trigger]", "每个工作日 09:00（Asia/Shanghai）")

      assert view |> element("#{row(night)} [data-next-run]") |> render() =~
               ~r/\d{4}-\d\d-\d\d \d\d:\d\d/

      assert has_element?(view, ~s(#{row(night)} [data-record-status="succeeded"]), "成功")
      assert has_element?(view, ~s(#autopilot-#{night}-toggle[aria-checked="true"]))

      assert has_element?(view, "#{row(dep)} [data-disabled-reason]", "连续失败 5 次后停用")
      assert has_element?(view, "#{row(dep)} [data-mode]", "仅运行")
      assert view |> element("#{row(dep)} [data-next-run]") |> render() =~ "—"
      assert has_element?(view, ~s(#autopilot-#{dep}-toggle[aria-checked="false"]))
      assert has_element?(view, ~s(#{row(night)}[phx-click*="/autopilots/#{night}"]))
    end

    test "webhook mark and manual-only trigger", ctx do
      id = nightly(ctx, cron: nil)
      {:ok, _} = Autopilots.enable_webhook(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      assert has_element?(view, "#{row(id)} [data-trigger]", "仅手动")
      assert has_element?(view, ~s(#{row(id)} [data-trigger] [aria-label="webhook"]))
      assert view |> element("#{row(id)} [data-next-run]") |> render() =~ "—"
    end

    test "a failed or skipped last result explains its reason", ctx do
      id = nightly(ctx)
      run_now!(ctx.alice_scope, id)
      assert %Record{status: :skipped, reason: "overlap"} = run_now!(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      assert has_element?(view, "#{row(id)} [data-last-run]", "上一次还在进行，已跳过")
    end

    test "warning", ctx do
      id = nightly(ctx)
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/triage")
      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      assert has_element?(view, "#{row(id)} [data-warning]")
      assert has_element?(view, "#autopilot-#{id}-warnings", "目标已归档")
    end

    test "an admin turns off someone else's autopilot and cannot turn it on again", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :carol, ctx.list)

      refute has_element?(view, "#autopilot-#{id}-toggle[data-readonly]")
      view |> element("#autopilot-#{id}-toggle") |> render_click()

      refute row!(id).enabled
      assert has_element?(view, ~s(#autopilot-#{id}-toggle[aria-checked="false"][data-readonly]))
      assert has_element?(view, "#autopilot-#{id}-toggle-reason", "你无权触发 keel/triage")
      refute has_element?(view, "#autopilot-#{id}-toggle[phx-click]")
    end

    test "a viewer sees every autopilot read-only", ctx do
      night = nightly(ctx)
      dep = dep_bump(ctx)
      {:ok, view, _html} = open(ctx, :vic, ctx.list)

      assert has_element?(view, row(night))
      assert has_element?(view, row(dep))
      assert has_element?(view, "#autopilot-#{night}-toggle[data-readonly]")
      assert has_element?(view, "#autopilot-#{dep}-toggle[data-readonly]")
      assert has_element?(view, "#autopilot-#{night}-toggle-reason", "只读成员")
      refute has_element?(view, "#autopilots-new")
    end

    test "turning on an autopilot authorized by someone else asks first", ctx do
      id = nightly(ctx, agent: "keel/shared")
      {:ok, _} = Autopilots.disable(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :bob, ctx.list)

      view |> element("#autopilot-#{id}-toggle") |> render_click()
      refute row!(id).enabled
      assert open?(view, "autopilot-enable-dialog")

      assert in_portal?(
               view,
               "autopilot-enable-dialog",
               "#autopilot-enable-dialog-description",
               "当前以 #{ctx.alice_name} 的权限运行"
             )

      assert in_portal?(
               view,
               "autopilot-enable-dialog",
               "#autopilot-enable-dialog-description",
               "以你的权限运行"
             )

      render_click(view, "confirm_enable", %{"id" => to_string(id)})
      assert row!(id).enabled
      assert row!(id).initiator_user_id == ctx.users.bob.id
      assert has_element?(view, ~s(#autopilot-#{id}-toggle[aria-checked="true"]))
    end

    test "turning on one's own autopilot needs no confirmation", ctx do
      id = nightly(ctx)
      {:ok, _} = Autopilots.disable(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      view |> element("#autopilot-#{id}-toggle") |> render_click()
      assert row!(id).enabled
      refute open?(view, "autopilot-enable-dialog")
    end

    test "empty state explains the triggers and the modes", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.list)

      html = view |> element("#autopilots-empty") |> render()
      for word <- ~w(定时 手动 webhook 建任务 仅运行), do: assert(html =~ word)
      assert has_element?(view, "#autopilots-new", "新建自动化")
    end
  end

  describe "detail page" do
    test "disabled after consecutive failures", ctx do
      id = dep_bump(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert has_element?(view, "#autopilot-disabled-banner", "连续失败 5 次后停用")
      assert has_element?(view, "#autopilot-banner-enable", "启用")
      assert has_element?(view, ~s(#autopilot-state[data-state="disabled"]))
      refute has_element?(view, "#autopilot-upcoming")

      view |> element("#autopilot-banner-enable") |> render_click()
      assert row!(id).enabled
      assert row!(id).consecutive_failures == 0
      refute has_element?(view, "#autopilot-disabled-banner")
      assert has_element?(view, "#autopilot-upcoming li")
    end

    for {reason, text} <- [
          {:manual, "已手动停用"},
          {:consecutive_failures, "连续失败 5 次后停用"},
          {:unauthorized, "授权来源无权触发目标"},
          {:initiator_left, "授权来源已离开工作区"},
          {:agent_archived, "目标已归档"},
          {:project_archived, "项目已归档"}
        ] do
      test "disabled reason #{reason}", ctx do
        id = dep_bump(ctx, unquote(reason))
        {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
        assert has_element?(view, "#autopilot-disabled-banner [data-reason]", unquote(text))
      end
    end

    test "configuration", ctx do
      id = nightly(ctx)
      set!(id, consecutive_failures: 2)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert has_element?(view, ~s([data-config="agent"]), "keel/triage")
      assert has_element?(view, ~s([data-config="mode"]), "建任务")
      assert has_element?(view, ~s([data-config="project"]), "BOS")
      assert has_element?(view, ~s([data-config="title-template"]), "Triage {{date}}")
      assert has_element?(view, ~s([data-config="schedule"]), "每个工作日 09:00（Asia/Shanghai）")
      assert has_element?(view, ~s([data-config="schedule"] code), "0 9 * * 1-5")
      assert has_element?(view, ~s([data-config="initiator"]), "以 #{ctx.alice_name} 的权限运行")
      assert has_element?(view, ~s([data-config="created-by"]), ctx.alice_name)
      assert has_element?(view, ~s([data-config="failures"]), "2 次")
      assert has_element?(view, ~s([data-config="overlap"]), "跳过")
      assert has_element?(view, "#autopilot-instructions strong", "new")
      refute has_element?(view, "#autopilot-warnings")

      times = view |> element("#autopilot-upcoming") |> render()
      assert length(Regex.scan(~r/<li>/, times)) == 5
      assert length(Regex.scan(~r/ 09:00/, times)) == 5
    end

    test "warning banner", ctx do
      id = nightly(ctx)
      runtime_id = profile(agent_actor(ctx.ws, "keel/triage")).runtime_id
      {:ok, _} = Runtimes.disable(ctx.alice_scope, runtime_id)
      {:ok, _} = Projects.archive(ctx.alice_scope, "BOS")
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert has_element?(view, "#autopilot-warnings", "下一次触发会失败：目标的运行时已禁用、项目已归档")
    end

    test "the viewer's detail page", ctx do
      id = nightly(ctx)
      insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :vic, show_path(ctx, id))

      assert has_element?(view, "#autopilot-config", "keel/triage")
      assert length(record_ids(view)) == 1
      refute has_element?(view, "#autopilot-run-now")
      refute has_element?(view, "#autopilot-edit")
      refute has_element?(view, "#autopilot-more")
      refute has_element?(view, "#webhook-enable")
      refute has_element?(view, "#webhook-rotate")

      {:ok, view, _html} = open(ctx, :vic, show_path(ctx, id) <> "?panel=run-now")
      refute in_portal?(view, "run-now-panel", "#run-now-form")
    end

    test "delete", ctx do
      task = task_fixture(ctx.alice_scope, "BOS", %{title: "Triage"})
      id = nightly(ctx)
      insert_record(id, status: :succeeded, task_id: task.id)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      view |> element("#autopilot-delete") |> render_click()
      assert in_portal?(view, "autopilot-confirm", "#autopilot-confirm-description", "触发历史一并删除")
      assert in_portal?(view, "autopilot-confirm", "#autopilot-confirm-description", "已建的任务与运行保留")

      assert portal_attr(view, "autopilot-confirm", "#autopilot-confirm-confirm", "phx-click") =~
               "delete"

      result = render_click(view, "delete", %{})
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ctx.list

      {:ok, _list, html} = follow_redirect(result, log_in_user(ctx.conn, ctx.users.alice))
      assert html =~ "已删除 nightly-triage"
      assert row!(id) == nil
      assert {:error, :not_found} = Autopilots.get(ctx.alice_scope, id)
      assert {:ok, _} = Helmsman.Tasks.get(ctx.alice_scope, task.ident)
    end

    test "disable from the menu", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      view |> element("#autopilot-disable") |> render_click()
      refute row!(id).enabled
      assert has_element?(view, "#autopilot-disabled-banner", "已手动停用")
    end

    test "an unknown autopilot or one of another workspace is a 404", ctx do
      other = workspace_fixture(ctx.users.bob, %{name: "Other"})
      other_scope = workspace_scope_fixture(ctx.users.bob, other)
      managed_agent_fixture(other_scope, %{name: "keel/other"})

      other_id =
        create!(other_scope, %{
          name: "elsewhere",
          agent: "keel/other",
          mode: "run_only",
          instructions: "Elsewhere."
        })

      for path <- [show_path(ctx, 999_999), show_path(ctx, other_id), "#{ctx.list}/abc"] do
        assert_raise HelmsmanWeb.NotFoundError, fn -> open(ctx, :alice, path) end
      end
    end
  end

  describe "run now" do
    test "a create-task autopilot", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      view |> element("#autopilot-run-now") |> render_click()
      assert_patch(view, show_path(ctx, id) <> "?panel=run-now")
      assert open?(view, "run-now-panel")
      refute in_portal?(view, "run-now-panel", "#run-now-trial")

      render_submit(view, "run_now_submit", %{"run" => %{"note" => "今天重点看 BOS-12"}})

      assert has_element?(view, "#run-now-result", "已开始")
      [top] = record_ids(view)
      {:ok, run} = Autopilots.get_run(ctx.alice_scope, top)
      assert "BOS-" <> _ = run.task
      assert has_element?(view, ~s(#run-now-result a[href="/w/#{ctx.ws.slug}/t/#{run.task}"]))
      assert has_element?(view, "#{record(top)} [data-source]", "手动 · #{ctx.alice_name}")
      assert run.note == "今天重点看 BOS-12"
      refute open?(view, "run-now-panel")
    end

    test "skipped while the previous one is running", ctx do
      id = nightly(ctx)
      run_now!(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?panel=run-now")

      render_submit(view, "run_now_submit", %{"run" => %{"note" => ""}})

      assert has_element?(view, "#run-now-result", "上一次还在进行，已跳过这一次")
      [top, _] = record_ids(view)
      assert has_element?(view, ~s(#{record(top)} [data-record-status="skipped"]), "已跳过")
    end

    test "queued and failed outcomes", ctx do
      id = nightly(ctx, overlap: "queue")
      run_now!(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?panel=run-now")
      render_submit(view, "run_now_submit", %{"run" => %{"note" => ""}})
      assert has_element?(view, "#run-now-result", "已排队")

      managed_agent_fixture(ctx.alice_scope, %{name: "keel/old"})
      old = nightly(ctx, name: "old-agent", agent: "keel/old")
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/old")
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, old) <> "?panel=run-now")
      render_submit(view, "run_now_submit", %{"run" => %{"note" => ""}})
      assert has_element?(view, "#run-now-result", "立即运行失败：目标已归档")
    end

    test "a trial run of a disabled autopilot", ctx do
      id = dep_bump(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?panel=run-now")

      assert in_portal?(view, "run-now-panel", "#run-now-trial", "这是一次试运行，成功不会自动启用")
    end

    test "a note over 4 KB", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?panel=run-now")
      note = String.duplicate("a", 4097)

      render_change(view, "run_now_change", %{"run" => %{"note" => note}})
      assert in_portal?(view, "run-now-panel", "#run-now-note-size", "4097 / 4096")

      render_submit(view, "run_now_submit", %{"run" => %{"note" => note}})
      assert in_portal?(view, "run-now-panel", "#run-now-note-error", "不能超过 4 KB")
      assert record_ids(view) == []
    end
  end

  describe "webhook" do
    defp assert_token_gone(view, token) do
      refute render(view) =~ token

      refute :sys.get_state(view.pid) |> inspect(limit: :infinity, printable_limit: :infinity) =~
               token
    end

    test "enabling shows the token once", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert has_element?(view, "#autopilot-webhook", "开启后，定时与 webhook 触发改为以你的权限运行")
      html = view |> element("#webhook-enable") |> render_click()
      assert html =~ "webhook-token-dialog"

      token = token_in_dialog(view)
      assert {:ok, _hash} = Autopilots.authenticate_webhook(id, token)
      {:ok, %{webhook: %{enabled: true, url: url}}} = Autopilots.get(ctx.alice_scope, id)
      assert url =~ "/hooks/autopilots/#{id}"
      assert open?(view, "webhook-token-dialog")
      assert in_portal?(view, "webhook-token-dialog", "#webhook-token-url-text", url)
      curl = portal_text(view, "webhook-token-dialog", "#webhook-token-curl")
      assert curl =~ "Authorization: " <> "Bearer " <> token
      assert curl =~ "X-Delivery-Id"
      assert in_portal?(view, "webhook-token-dialog", "#webhook-token", "关闭后将无法再次查看")
      assert in_portal?(view, "webhook-token-dialog", "p", "丢失请轮换令牌")
      refute html =~ ~s(id="flash-info")

      assert portal_attr(view, "webhook-token-dialog", "#webhook-token-done", "phx-click") =~
               "close_token"

      render_click(view, "close_token", %{})
      refute open?(view, "webhook-token-dialog")
      assert_token_gone(view, token)
      assert has_element?(view, "#webhook-url-text", url)
      assert has_element?(view, "#webhook-rotate")
    end

    test "rotating the token", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
      view |> element("#webhook-enable") |> render_click()
      old = token_in_dialog(view)
      render_click(view, "close_token", %{})

      view |> element("#webhook-rotate") |> render_click()
      assert in_portal?(view, "autopilot-confirm", "#autopilot-confirm-description", "旧令牌立即失效")
      render_click(view, "rotate", %{})

      new = token_in_dialog(view)
      assert new != old
      assert {:error, :unauthorized} = Autopilots.authenticate_webhook(id, old)
      assert {:ok, _hash} = Autopilots.authenticate_webhook(id, new)
      assert in_portal?(view, "webhook-token-dialog", "#webhook-token-rotated", "旧令牌已失效")

      render_click(view, "close_token", %{})
      assert_token_gone(view, new)
    end

    test "closing the dialog with the overlay's cancel also clears the token", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
      view |> element("#webhook-enable") |> render_click()
      token = token_in_dialog(view)

      render_hook(view, "close_token", %{})
      assert_token_gone(view, token)
    end

    test "turning the webhook off asks first", ctx do
      id = nightly(ctx)
      {:ok, %{token: token}} = Autopilots.enable_webhook(ctx.alice_scope, id)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      view |> element("#webhook-disable") |> render_click()
      assert in_portal?(view, "autopilot-confirm", "#autopilot-confirm-title", "关闭 webhook？")
      assert {:ok, _hash} = Autopilots.authenticate_webhook(id, token)

      render_click(view, "disable_webhook", %{})
      assert {:error, :unauthorized} = Autopilots.authenticate_webhook(id, token)
      assert has_element?(view, "#webhook-enable")
    end
  end

  describe "history" do
    test "history and links", ctx do
      task = task_fixture(ctx.alice_scope, "BOS", %{title: "Triage"})
      id = nightly(ctx)
      ok = insert_record(id, status: :succeeded, task_id: task.id, result: "Done.\nMore.")
      missed = insert_record(id, status: :skipped, reason: "missed")
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert record_ids(view) == [missed, ok]

      assert has_element?(
               view,
               ~s(#{record(ok)} a[href="/w/#{ctx.ws.slug}/t/#{task.ident}"]),
               task.ident
             )

      assert has_element?(view, "#{record(ok)} [data-source]", "定时")
      assert has_element?(view, "#{record(ok)} [data-result]", "Done.")
      refute view |> element("#{record(ok)} [data-result]") |> render() =~ "More."
      assert has_element?(view, "#{record(missed)} [data-record-status]", "已跳过")
      assert has_element?(view, "#{record(missed)} [data-reason]", "服务停机错过")

      # Below md the link column is hidden (390 px overflow, walkthrough 5.1); the
      # row's record panel carries the same link.
      assert has_element?(view, "#{record(ok)} td.hidden [data-link]")
      view |> element(record(ok)) |> render_click()

      assert in_portal?(
               view,
               "record-panel",
               ~s([data-detail="link"] a[href="/w/#{ctx.ws.slug}/t/#{task.ident}"])
             )
    end

    test "the content of a webhook record", ctx do
      id = nightly(ctx)

      rid =
        insert_record(id,
          source: :webhook,
          status: :succeeded,
          delivery_id: "d-123456789",
          payload: %{"ref" => "main"}
        )

      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
      assert has_element?(view, "#{record(rid)} [data-source]", "webhook")

      view |> element(record(rid)) |> render_click()
      assert_patch(view, show_path(ctx, id) <> "?record=#{rid}")

      assert in_portal?(view, "record-panel", "#record-payload", "Webhook 内容（来自外部，不可信）")
      assert portal_text(view, "record-panel", "#record-payload-json") =~ ~s("ref": "main")
      assert in_portal?(view, "record-panel", ~s([data-detail="source"]), "webhook · d-123456")
    end

    test "a non-JSON webhook payload is text", ctx do
      id = nightly(ctx)
      payload = %{"raw" => "hello", "truncated" => true}
      rid = insert_record(id, source: :webhook, status: :failed, payload: payload)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?record=#{rid}")

      assert in_portal?(view, "record-panel", "#record-payload-raw", "hello")
      assert in_portal?(view, "record-panel", "#record-payload-raw", "已截断")
    end

    # code-review-1 P2-2: only the exact {raw, truncated} wrapper is text.
    test "a JSON body with a raw key is JSON", ctx do
      id = nightly(ctx)

      for payload <- [
            %{"raw" => "hello", "ref" => "main"},
            %{"raw" => "hello"},
            %{"raw" => "hello", "truncated" => "yes"}
          ] do
        rid = insert_record(id, source: :webhook, status: :failed, payload: payload)
        {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?record=#{rid}")

        refute in_portal?(view, "record-panel", "#record-payload-raw")
        json = portal_text(view, "record-panel", "#record-payload-json")
        assert json =~ ~s("raw": "hello")
        for {key, value} <- payload, do: assert(json =~ ~s("#{key}": "#{value}"))
      end

      rid =
        insert_record(id,
          source: :webhook,
          status: :failed,
          payload: %{"raw" => "plain text", "truncated" => false}
        )

      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?record=#{rid}")
      assert in_portal?(view, "record-panel", "#record-payload-raw", "plain text")
      refute in_portal?(view, "record-panel", "#record-payload-raw", "已截断")
    end

    test "the result of a run-only record", ctx do
      id = dep_bump(ctx)
      run = run_fixture(agent_actor(ctx.ws, "keel/triage"))

      rid =
        insert_record(id,
          source: :manual,
          initiator_user_id: ctx.users.alice.id,
          note: "look at deps",
          status: :succeeded,
          run_id: run.id,
          result: "- one\n- two"
        )

      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id) <> "?record=#{rid}")

      assert in_portal?(view, "record-panel", "#record-result li", "one")
      assert in_portal?(view, "record-panel", "#record-result li", "two")

      assert in_portal?(
               view,
               "record-panel",
               ~s(a[href="/w/#{ctx.ws.slug}/runs/#{run.id}"]),
               "运行 ##{run.id}"
             )

      assert in_portal?(view, "record-panel", "#record-note", "look at deps")

      assert in_portal?(
               view,
               "record-panel",
               ~s([data-detail="source"]),
               "手动 · #{ctx.alice_name}"
             )

      assert has_element?(view, ~s(#{record(rid)} a[href="/w/#{ctx.ws.slug}/runs/#{run.id}"]))
    end

    test "加载更多 uses the oldest loaded id", ctx do
      id = nightly(ctx)
      ids = for _ <- 1..60, do: insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert record_ids(view) == ids |> Enum.reverse() |> Enum.take(50)
      assert has_element?(view, "#autopilot-records-more")
      view |> element("#autopilot-records-more") |> render_click()
      assert record_ids(view) == Enum.reverse(ids)
      refute has_element?(view, "#autopilot-records-more")
    end

    test "exactly one page has no 加载更多", ctx do
      id = nightly(ctx)
      for _ <- 1..50, do: insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))

      assert length(record_ids(view)) == 50
      refute has_element?(view, "#autopilot-records-more")
    end

    for {code, text} <- [
          {"overlap", "上一次还在进行，已跳过"},
          {"superseded", "被更新的请求取代"},
          {"missed", "服务停机错过"},
          {"unauthorized", "授权来源无权触发目标"},
          {"initiator_left", "授权来源已离开工作区"},
          {"agent_archived", "目标已归档"},
          {"agent_disabled", "目标已停用"},
          {"squad_disabled", "小队已停用"},
          {"no_runtime", "目标没有绑定运行时"},
          {"runtime_disabled", "目标的运行时已禁用"},
          {"project_archived", "项目已归档"},
          {"run_failed", "运行失败"},
          {"task_rejected", "任务被拒绝"},
          {"stopped", "运行被人停止"},
          {"task_cancelled", "任务已撤销"},
          {"task_deleted", "任务已被删除"},
          {"reassigned", "任务被改派"},
          {"autopilot_disabled", "自动化已停用"},
          {"config_changed", "配置已修改"},
          {"some_new_code", "some_new_code"}
        ] do
      test "reason #{code}", ctx do
        id = nightly(ctx)
        rid = insert_record(id, status: :failed, reason: unquote(code))
        {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
        assert has_element?(view, "#{record(rid)} [data-reason]", unquote(text))
      end
    end

    test "the domain's statuses and sources are atoms", ctx do
      id = nightly(ctx)
      rid = insert_record(id, status: :cancelled, reason: "reassigned", source: :manual)
      {:ok, view, _html} = open(ctx, :alice, show_path(ctx, id))
      assert has_element?(view, "#{record(rid)} [data-reason]", "任务被改派")
      assert has_element?(view, "#{record(rid)} [data-record-status]", "已取消")
      assert has_element?(view, "#{record(rid)} [data-source]", "手动")
    end
  end

  describe "realtime" do
    test "a new record appears on top and is updated in place", ctx do
      id = nightly(ctx)
      old = insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))

      new = run_now!(ctx.alice_scope, id)
      assert has_element?(view, ~s(#{record(new.id)} [data-record-status="started"]), "进行中")
      assert record_ids(view) == [new.id, old]

      finish_task!(new, :done)
      assert has_element?(view, ~s(#{record(new.id)} [data-record-status="succeeded"]), "成功")
      assert record_ids(view) == [new.id, old]
    end

    test "the list's last result", ctx do
      id = nightly(ctx)
      insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :bob, ctx.list)

      started = run_now!(ctx.alice_scope, id)
      assert has_element?(view, ~s(#{row(id)} [data-record-status="started"]))

      finish_task!(started, :rejected)
      assert has_element?(view, ~s(#{row(id)} [data-record-status="failed"]), "失败")
    end

    test "the list follows changes, new and deleted autopilots", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :bob, ctx.list)

      {:ok, _} = Autopilots.disable(ctx.alice_scope, id)
      assert has_element?(view, ~s(#autopilot-#{id}-toggle[aria-checked="false"]))

      other = run_only(ctx)
      assert has_element?(view, row(other))

      {:ok, _} = Autopilots.delete(ctx.alice_scope, id)
      refute has_element?(view, row(id))
    end

    test "deleted while being viewed", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))

      {:ok, _} = Autopilots.delete(ctx.alice_scope, id)
      flash = assert_redirect(view, ctx.list)
      assert flash["error"] =~ "自动化已被删除"
    end

    test "the configuration follows changes", ctx do
      id = nightly(ctx)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))

      # The next trigger finds the target archived and disables the autopilot.
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/triage")
      assert %Record{status: :failed} = run_now!(ctx.alice_scope, id)

      assert has_element?(view, "#autopilot-disabled-banner", "目标已归档，已停用")
    end

    test "a record beyond the first page is superseded", ctx do
      id = nightly(ctx, overlap: "queue")
      started = run_now!(ctx.alice_scope, id)

      ids =
        for n <- 1..109 do
          insert_record(id, status: if(n == 50, do: :pending, else: :succeeded))
        end

      pending = Enum.at(ids, 49)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))
      view |> element("#autopilot-records-more") |> render_click()

      shown = record_ids(view)
      assert length(shown) == 100
      assert Enum.at(shown, 59) == pending
      assert has_element?(view, ~s(#{record(pending)} [data-record-status="pending"]))

      # A new request supersedes the queued one and is queued itself.
      newest = run_now!(ctx.alice_scope, id)
      assert newest.status == :pending

      assert has_element?(view, ~s(#{record(pending)} [data-record-status="skipped"]))
      assert has_element?(view, "#{record(pending)} [data-reason]", "被更新的请求取代")
      assert record_ids(view) == [newest.id | shown]

      view |> element("#autopilot-records-more") |> render_click()
      assert record_ids(view) == [newest.id | Enum.reverse(ids)] ++ [started.id]
    end

    test "a started record on the second page finishes in place", ctx do
      id = nightly(ctx)
      started = run_now!(ctx.alice_scope, id)
      ids = for _ <- 1..59, do: insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))
      view |> element("#autopilot-records-more") |> render_click()
      assert has_element?(view, ~s(#{record(started.id)} [data-record-status="started"]))

      finish_task!(started, :done)
      assert has_element?(view, ~s(#{record(started.id)} [data-record-status="succeeded"]))
      assert Enum.count(record_ids(view), &(&1 == started.id)) == 1
      assert record_ids(view) == Enum.reverse(ids) ++ [started.id]
    end

    test "an older record that is not loaded is ignored", ctx do
      id = nightly(ctx)
      started = run_now!(ctx.alice_scope, id)
      for _ <- 1..59, do: insert_record(id, status: :succeeded)
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))

      finish_task!(started, :done)
      _ = render(view)
      refute has_element?(view, record(started.id))
      assert length(record_ids(view)) == 50
    end

    test "the open record panel follows its record", ctx do
      id = run_only(ctx)
      started = run_now!(ctx.alice_scope, id)
      assert started.run_id
      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id) <> "?record=#{started.id}")
      assert in_portal?(view, "record-panel", ~s([data-record-status="started"]))

      finish_run!(started, status: :succeeded, summary: "**all good**")
      _ = render(view)
      assert in_portal?(view, "record-panel", ~s([data-record-status="succeeded"]))
      assert in_portal?(view, "record-panel", "#record-result strong", "all good")
    end

    # Retention deletes records without a notification; a notification of a record that
    # is gone by the time it is read (`get_run` → not_found) removes it.
    test "a deleted record leaves the history", ctx do
      id = nightly(ctx)
      keep = insert_record(id, status: :succeeded)
      old = DateTime.add(DateTime.utc_now(), -31 * 86_400)

      gone =
        insert_record(id, status: :skipped, reason: "overlap", inserted_at: old, updated_at: old)

      {:ok, view, _html} = open(ctx, :bob, show_path(ctx, id))
      assert record_ids(view) == [gone, keep]

      assert :ok = perform_job(Prune, %{})
      send(view.pid, {:autopilot_run, id, gone})
      refute has_element?(view, record(gone))
      assert record_ids(view) == [keep]
    end
  end
end
