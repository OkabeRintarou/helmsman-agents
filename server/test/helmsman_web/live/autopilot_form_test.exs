defmodule HelmsmanWeb.AutopilotFormTest do
  @moduledoc """
  Spec web-autopilots 新建与编辑自动化 (add-squads-autopilots-ui D10): the autopilot panel,
  its schedule presets and preview, against `Helmsman.Autopilots`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Agents, Autopilots}
  alias HelmsmanWeb.AutopilotForm

  doctest AutopilotForm

  @panel "autopilot-panel"

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    bob = user_fixture(%{display_name: "bob"})
    carol = user_fixture(%{display_name: "carol"})
    member_fixture(ws, bob, :member)
    member_fixture(ws, carol, :admin)
    alice_scope = workspace_scope_fixture(alice, ws)

    project_fixture(alice_scope, %{key: "BOS", name: "Backoffice"})
    managed_agent_fixture(alice_scope, %{name: "keel/triage"})
    managed_agent_fixture(alice_scope, %{name: "keel/shared", access: "workspace"})
    squad_fixture(alice_scope, %{name: "web-team", leader: "keel/shared"})
    squad_fixture(alice_scope, %{name: "old-team", leader: "keel/shared"})
    {:ok, _} = Helmsman.Squads.disable(alice_scope, "old-team")

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, bob: bob, carol: carol},
      alice_scope: alice_scope,
      alice_name: alice_scope.actor.name,
      bob_name: workspace_scope_fixture(bob, ws).actor.name,
      list: "/w/#{ws.slug}/autopilots"
    }
  end

  defp open(ctx, who, path, tz \\ nil) do
    conn = log_in_user(ctx.conn, ctx.users[who])
    conn = if tz, do: put_connect_params(conn, %{"timezone" => tz}), else: conn
    live(conn, path)
  end

  defp new_panel(ctx, who, tz \\ nil), do: open(ctx, who, ctx.list <> "?panel=new-autopilot", tz)

  defp change(view, params), do: render_change(view, "ap_form_change", %{"autopilot" => params})
  defp submit(view, params), do: render_submit(view, "ap_form_submit", %{"autopilot" => params})

  defp has?(view, selector, text \\ nil), do: in_portal?(view, @panel, selector, text)
  defp value(view, selector), do: portal_attr(view, @panel, selector, "value")
  defp checked?(view, selector), do: portal_attr(view, @panel, selector, "checked") != nil

  defp create!(scope, attrs) do
    {:ok, view} =
      Autopilots.create(
        scope,
        Map.merge(
          %{
            agent: "keel/triage",
            project: "BOS",
            mode: "create_task",
            title_template: "{{date}}",
            instructions: "Do the thing."
          },
          attrs
        )
      )

    view.id
  end

  defp stored(ctx, id) do
    {:ok, view} = Autopilots.get(ctx.alice_scope, id)
    view
  end

  defp valid(attrs \\ %{}) do
    Map.merge(
      %{
        "name" => "nightly-triage",
        "mode" => "create_task",
        "agent" => "keel/triage",
        "project" => "BOS",
        "title_template" => "Triage {{date}}",
        "instructions" => "Look at new issues.",
        "schedule" => "none",
        "overlap" => "skip"
      },
      attrs
    )
  end

  test "creating an autopilot that triages every weekday", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice, "Asia/Shanghai")
    assert open?(view, @panel)
    assert has?(view, "#autopilot-initiator-note", "保存后，定时与 webhook 触发以你的权限运行")

    change(view, valid(%{"schedule" => "weekdays"}))
    assert value(view, "#autopilot-timezone") == "Asia/Shanghai"

    change(
      view,
      valid(%{"schedule" => "weekdays", "time" => "09:00", "timezone" => "Asia/Shanghai"})
    )

    assert has?(view, "#autopilot-preview-text", "每个工作日 09:00（Asia/Shanghai）")
    times = view |> portal(@panel) |> LazyHTML.query("#autopilot-preview-times li")
    texts = Enum.map(times, &LazyHTML.text/1)
    assert length(texts) == 5

    for text <- texts do
      assert text =~ ~r/\d{4}-\d\d-\d\d 周[一二三四五] 09:00/u
    end

    result =
      submit(
        view,
        valid(%{"schedule" => "weekdays", "time" => "09:00", "timezone" => "Asia/Shanghai"})
      )

    {:error, {:live_redirect, %{to: to}}} = result
    [id] = Regex.run(~r{/autopilots/(\d+)$}, to, capture: :all_but_first)
    stored = stored(ctx, String.to_integer(id))
    assert stored.cron == "0 9 * * 1-5"
    assert stored.timezone == "Asia/Shanghai"
    assert stored.title_template == "Triage {{date}}"
    assert stored.project.key == "BOS"
    assert stored.agent == %{name: "keel/triage", kind: "agent"}
    assert stored.initiator.name == ctx.alice_name

    {:ok, _show, html} = follow_redirect(result, log_in_user(ctx.conn, ctx.users.alice))
    assert html =~ "已保存 nightly-triage，下一次："
  end

  test "a schedule that is too frequent", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    change(view, %{"schedule" => "custom"})
    change(view, %{"schedule" => "custom", "cron" => "*/2 * * * *"})

    assert has?(view, "#autopilot-schedule-errors", "两次之间至少 5 分钟")
    refute has?(view, "#autopilot-preview")

    change(view, %{"schedule" => "custom", "cron" => "0 9 * *"})
    assert has?(view, "#autopilot-schedule-errors", "不是有效的 cron 表达式")

    change(view, %{"schedule" => "custom", "cron" => "0 9 * * *", "timezone" => "Mars/Base"})
    assert has?(view, "#autopilot-schedule-errors", "未知的时区")
  end

  test "create-task mode without a project and a title", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    submit(view, valid(%{"project" => "", "title_template" => ""}))

    assert has?(view, "#autopilot-project-error", "不能为空")
    assert has?(view, "#autopilot-title-template-error", "不能为空")
    assert open?(view, @panel)
    assert value(view, "#autopilot-name") == "nightly-triage"
  end

  test "all field errors at once", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    submit(view, valid(%{"name" => "", "project" => "", "instructions" => ""}))

    assert has?(view, "#autopilot-name-error", "不能为空")
    assert has?(view, "#autopilot-project-error", "不能为空")
    assert has?(view, ".hm-field", "不能为空")
  end

  test "run-only mode offers no squads", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    assert has?(view, ~s(#autopilot-agent optgroup[label="小队"] option[value="web-team"]))
    refute has?(view, ~s(#autopilot-agent option[value="old-team"]))

    change(view, %{"mode" => "run_only"})
    refute has?(view, ~s(#autopilot-agent optgroup[label="小队"]))
    assert has?(view, ~s(#autopilot-agent option[value="keel/triage"]))
    assert has?(view, "#autopilot-project-help", "只读检出")
    assert has?(view, "#autopilot-create-tasks")
    refute has?(view, "#autopilot-title-template")
  end

  # add-squads-autopilots-ui 6.2: a create-task autopilot that targets a squad, created
  # in the panel and run now with the real domain, assigns its task to the squad.
  test "an autopilot targeting a squad assigns its task to the squad", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)
    result = submit(view, valid(%{"name" => "squad-triage", "agent" => "web-team"}))
    {:error, {:live_redirect, %{to: to}}} = result
    [id] = Regex.run(~r{/autopilots/(\d+)$}, to, capture: :all_but_first)
    id = String.to_integer(id)

    assert stored(ctx, id).agent == %{name: "web-team", kind: "squad"}

    {:ok, record} = Autopilots.run_now(ctx.alice_scope, id)
    task = Helmsman.Repo.get!(Helmsman.Tasks.Task, record.task_id)
    assignee = Helmsman.Repo.get!(Helmsman.Actors.Actor, task.assignee_id)
    assert {assignee.kind, assignee.name} == {:squad, "web-team"}
  end

  test "a squad picked before switching to run-only is a field error", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    change(view, %{"agent" => "web-team"})
    change(view, %{"mode" => "run_only", "agent" => "web-team"})

    assert has?(view, "#autopilot-agent-error", "仅运行模式只能选托管 Agent")
  end

  test "a target the user cannot trigger", ctx do
    {:ok, view, _html} = new_panel(ctx, :carol)

    assert has?(view, ~s(#autopilot-agent option[value="keel/triage"][disabled]))
    refute has?(view, ~s(#autopilot-agent option[value="keel/shared"][disabled]))
    assert has?(view, ~s(#autopilot-agent-notes [data-target="keel/triage"]), "你无权触发 keel/triage")
  end

  test "editing someone else's autopilot", ctx do
    id = create!(ctx.alice_scope, %{name: "nightly-triage", agent: "keel/shared"})

    {:ok, view, _html} = open(ctx, :bob, "#{ctx.list}/#{id}?panel=edit")

    assert has?(
             view,
             "#autopilot-initiator-warning.tint-warning",
             "当前以 #{ctx.alice_name} 的权限运行"
           )

    assert has?(view, "#autopilot-initiator-warning", "保存后改为以你（#{ctx.bob_name}）的权限运行")
    assert has?(view, "#autopilot-config-note", "排队中的那次请求（如有）会作废")

    submit(view, valid(%{"agent" => "keel/shared", "instructions" => "New text"}))
    assert stored(ctx, id).initiator.name == ctx.bob_name
    assert stored(ctx, id).instructions == "New text"
    refute open?(view, @panel)
    assert render(view) =~ "已保存 nightly-triage"
  end

  test "editing one's own autopilot has no warning", ctx do
    id = create!(ctx.alice_scope, %{name: "mine"})
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.list}/#{id}?panel=edit")

    assert open?(view, @panel)
    refute has?(view, "#autopilot-initiator-warning")
  end

  test "the weekly preset generates the expression and is recognised again", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    change(view, %{"schedule" => "weekly"})
    params = %{"schedule" => "weekly", "days" => ["", "1", "3"], "time" => "18:30"}
    change(view, params)
    assert has?(view, "#autopilot-preview-text", "每周一、周三 18:30（UTC）")

    {:error, {:live_redirect, %{to: to}}} = submit(view, valid(params))
    id = to |> String.split("/") |> List.last()
    assert stored(ctx, String.to_integer(id)).cron == "30 18 * * 1,3"

    {:ok, view, _html} = open(ctx, :alice, to <> "?panel=edit")
    assert checked?(view, "#autopilot-schedule-weekly")
    assert checked?(view, "#autopilot-day-1")
    assert checked?(view, "#autopilot-day-3")
    refute checked?(view, "#autopilot-day-2")
    assert value(view, "#autopilot-time") == "18:30"
  end

  test "an expression no preset generates is edited as custom cron", ctx do
    id = create!(ctx.alice_scope, %{name: "monthly", cron: "0 9 1-7 * 1"})

    {:ok, view, _html} = open(ctx, :alice, "#{ctx.list}/#{id}?panel=edit")

    assert checked?(view, "#autopilot-schedule-custom")
    assert value(view, "#autopilot-cron") == "0 9 1-7 * 1"
  end

  test "an invalid browser time zone defaults to UTC", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice, "Not/AZone")
    change(view, %{"schedule" => "daily"})
    assert value(view, "#autopilot-timezone") == "UTC"
  end

  test "the workspace limit", ctx do
    for n <- 1..100, do: create!(ctx.alice_scope, %{name: "a#{n}"})
    {:ok, view, _html} = new_panel(ctx, :alice)

    submit(view, valid())
    assert in_portal?(view, @panel, "[role=alert]", "每个工作区最多 100 个自动化")
    assert open?(view, @panel)
  end

  test "a stale edit offers to load the latest version", ctx do
    id = create!(ctx.alice_scope, %{name: "nightly"})
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.list}/#{id}?panel=edit")

    {:ok, _} = Autopilots.update(ctx.alice_scope, id, %{instructions: "Changed elsewhere"})
    submit(view, valid(%{"name" => "nightly", "instructions" => "Mine"}))

    assert has?(view, "#autopilot-form-stale", "这个自动化刚被他人修改")
    assert value(view, "#autopilot-name") == "nightly"

    render_click(view, "ap_form_reload", %{})
    refute has?(view, "#autopilot-form-stale")
    submit(view, valid(%{"name" => "nightly", "instructions" => "Mine"}))
    assert stored(ctx, id).instructions == "Mine"
  end

  test "an archived target and project are kept when editing other fields", ctx do
    id = create!(ctx.alice_scope, %{name: "nightly"})
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/triage")
    {:ok, _} = Helmsman.Projects.archive(ctx.alice_scope, "BOS")
    {:ok, view, _html} = open(ctx, :alice, "#{ctx.list}/#{id}?panel=edit")

    submit(view, valid(%{"name" => "nightly", "instructions" => "Still triage"}))
    refute open?(view, @panel)
    assert stored(ctx, id).instructions == "Still triage"
    assert stored(ctx, id).agent.name == "keel/triage"
    assert stored(ctx, id).project.key == "BOS"
  end

  test "a target the user lost is refused and closes the panel", ctx do
    {:ok, view, _html} = new_panel(ctx, :carol)

    submit(view, valid())
    refute open?(view, @panel)
    assert render(view) =~ "你无权触发 keel/triage"
  end

  test "the instructions byte count", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)
    change(view, %{"instructions" => "说明"})
    assert has?(view, "#autopilot-instructions-size", "6 / 16384")
  end

  test "the default title follows the name until edited", ctx do
    {:ok, view, _html} = new_panel(ctx, :alice)

    change(view, %{"name" => "dep-bump"})
    assert value(view, "#autopilot-title-template") == "{{date}} dep-bump"

    change(view, %{"name" => "dep-bump", "title_template" => "Bump {{date}}"})
    change(view, %{"name" => "dep-bumps", "title_template" => "Bump {{date}}"})
    assert value(view, "#autopilot-title-template") == "Bump {{date}}"
  end

  test "a viewer cannot open the panel", ctx do
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ctx.ws, vic, :viewer)
    {:ok, view, _html} = live(log_in_user(ctx.conn, vic), ctx.list <> "?panel=new-autopilot")
    refute open?(view, @panel)
  end
end
