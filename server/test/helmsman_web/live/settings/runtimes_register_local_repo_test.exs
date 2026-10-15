defmodule HelmsmanWeb.FakeWebRegistration do
  @moduledoc false
  # Test double of `Helmsman.LocalRepositories.WebRegistration` (design D8) for the
  # page's own behaviour: injected error codes, short timeouts, forged input. It follows
  # D8's contract: `browse/2`, `register/3` and `remove/2` subscribe the
  # caller to `local_repo_request:<request_id>` before answering, and the test plays the
  # daemon by broadcasting `{:local_repo_result, …}` there. Every call is reported to the
  # test process as `{:fake, call}`. `RuntimesRegisterLocalRepoDomainTest` runs the same
  # flows against the real module.

  use Agent

  @pubsub Helmsman.PubSub

  def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)

  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def topic(request_id), do: "local_repo_request:" <> request_id

  def result(request_id, daemon_id, outcome),
    do:
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(request_id),
        {:local_repo_result, request_id, daemon_id, outcome}
      )

  defp get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
  defp notify(call), do: send(get(:test), {:fake, call})

  def machines(scope), do: {:ok, Map.get(get(:machines), scope.user.id, [])}

  def browse(_scope, daemon_id), do: request(:browse, {:browse, daemon_id})

  def register(_scope, daemon_id, attrs), do: request(:register, {:register, daemon_id, attrs})

  def remove(_scope, id), do: request(:remove, {:remove, id})

  def remove_workspaces(_scope, _id), do: {:ok, get(:remove_workspaces)}

  def forget(request_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(request_id))
    notify({:forget, request_id})
    :ok
  end

  def list_changes(scope, view) do
    notify({:list_changes, scope.user.id, view})
    {:ok, get(:changes).(scope, view)}
  end

  def browse_timeout_ms, do: get(:browse_timeout_ms)
  def change_timeout_ms, do: get(:change_timeout_ms)

  defp request(kind, call) do
    case Map.get(get(:replies), kind, :ok) do
      :ok ->
        request_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        :ok = Phoenix.PubSub.subscribe(@pubsub, topic(request_id))
        notify(Tuple.insert_at(call, tuple_size(call), request_id))
        {:ok, request_id}

      error ->
        notify(Tuple.insert_at(call, tuple_size(call), nil))
        error
    end
  end
end

defmodule HelmsmanWeb.SettingsLive.RuntimesRegisterLocalRepoTest do
  @moduledoc """
  Spec web-local-repositories 网页登记本地仓库, 网页移除本地仓库, 网页操作记录 and
  运行时页的本地仓库「admin 不能修改别人的仓库」(add-local-repo-web-registration D11,
  tasks 4.1–4.3).

  Not async: the page's registration implementation is swapped for
  `HelmsmanWeb.FakeWebRegistration` through the application environment.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias HelmsmanWeb.FakeWebRegistration, as: Fake
  alias HelmsmanWeb.LocalRepoRegistrationComponents, as: Components

  @panel "local-repository-register-panel"
  @dialog "local-repository-remove-dialog"

  setup %{conn: conn} do
    previous = Application.get_env(:helmsman, HelmsmanWeb.LocalRepoRegistration)
    Application.put_env(:helmsman, HelmsmanWeb.LocalRepoRegistration, impl: Fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman, HelmsmanWeb.LocalRepoRegistration, previous),
        else: Application.delete_env(:helmsman, HelmsmanWeb.LocalRepoRegistration)
    end)

    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    beta = workspace_fixture(olga, %{name: "Beta"})
    alice = user_fixture(%{display_name: "alice"})
    carol = user_fixture(%{display_name: "carol"})
    bob = user_fixture(%{display_name: "bob"})
    member_fixture(ws, alice, :member)
    member_fixture(beta, alice, :member)
    member_fixture(ws, carol, :admin)
    member_fixture(ws, bob, :member)

    {mbp, _} = daemon_fixture(alice, %{name: "alice-mbp", workspace_ids: [ws.id, beta.id]})
    runtime_fixture(ws, mbp)
    {carol_box, _} = daemon_fixture(carol, %{name: "carol-box", workspace_ids: [ws.id]})
    runtime_fixture(ws, carol_box)

    workspaces = [
      %{id: ws.id, slug: ws.slug, name: "Acme"},
      %{id: beta.id, slug: beta.slug, name: "Beta"}
    ]

    start_supervised!(
      {Fake,
       %{
         test: self(),
         machines: %{alice.id => [machine(mbp, :ok, workspaces)]},
         replies: %{},
         remove_workspaces: workspaces,
         changes: fn _scope, _view -> [] end,
         browse_timeout_ms: 15_000,
         change_timeout_ms: 20_000
       }}
    )

    %{
      conn: conn,
      ws: ws,
      beta: beta,
      users: %{alice: alice, carol: carol, bob: bob},
      mbp: mbp,
      workspaces: workspaces,
      path: "/w/#{ws.slug}/settings/runtimes"
    }
  end

  defp machine(daemon, eligibility, workspaces),
    do: %{
      daemon_id: daemon.id,
      name: daemon.name,
      eligibility: eligibility,
      workspaces: workspaces
    }

  defp open(ctx, who, query \\ ""),
    do: live(log_in_user(ctx.conn, ctx.users[who]), ctx.path <> query)

  defp open_panel(ctx, who \\ :alice),
    do: open(ctx, who, "?panel=register-local-repository")

  defp browse_reply(ctx, request_id, overrides \\ %{}) do
    Fake.result(
      request_id,
      ctx.mbp.id,
      {:ok,
       Map.merge(
         %{
           roots: ["~/code"],
           repositories: [
             %{root: "~/code", path: "app", name: "app", registered_as: nil},
             %{root: "~/code", path: "group/lib", name: "lib", registered_as: nil},
             %{root: "~/code", path: "web", name: "web", registered_as: "web"}
           ],
           truncated: false
         },
         overrides
       )}
    )
  end

  # Opens the panel, lets alice-mbp list its candidates and picks `app`.
  defp pick_app(ctx) do
    {:ok, view, _html} = open_panel(ctx)
    mbp = ctx.mbp.id
    assert_receive {:fake, {:browse, ^mbp, browse_id}}
    browse_reply(ctx, browse_id)
    render(view)
    render_click(view, "select_candidate", %{"index" => "0"})
    view
  end

  defp submit(view, params) do
    render_submit(view, "register", %{"register" => params})
  end

  defp panel?(view, selector, text \\ nil), do: in_portal?(view, @panel, selector, text)
  defp dialog?(view, selector, text \\ nil), do: in_portal?(view, @dialog, selector, text)

  describe "网页登记本地仓库" do
    test "the entry needs one of the user's own machines", ctx do
      {:ok, alice, _html} = open(ctx, :alice)
      assert has_element?(alice, "#local-repository-register", "登记本地仓库")

      {:ok, carol, _html} = open(ctx, :carol, "?all=1")
      refute has_element?(carol, "#local-repository-register")
    end

    test "the empty state mentions registering from the web", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, "#local-repositories-empty #local-repositories-add-command")
      assert has_element?(view, "#local-repositories-empty-web", "登记本地仓库")
    end

    test "registering a candidate on the only machine", ctx do
      {:ok, view, _html} = open_panel(ctx)
      mbp = ctx.mbp.id
      assert open?(view, @panel)

      # The only eligible machine is selected and asked for its candidates.
      assert_receive {:fake, {:browse, ^mbp, browse_id}}
      assert panel?(view, "#register-machine-#{mbp}[checked]")
      assert panel?(view, "#register-browse-status", "正在读取 alice-mbp 上的仓库…")

      browse_reply(ctx, browse_id)
      render(view)
      assert_receive {:fake, {:forget, ^browse_id}}
      refute panel?(view, "#register-browse-status")
      assert panel?(view, "#register-candidates [role=group]", "~/code")
      assert panel?(view, "#register-candidate-0", "app")
      assert panel?(view, "#register-candidate-1", "group/lib")
      assert panel?(view, "#register-candidate-2[disabled]", "已登记为 web")

      # A registered candidate cannot be picked.
      render_click(view, "select_candidate", %{"index" => "2"})
      refute panel?(view, "#local-repository-register-form")

      render_click(view, "select_candidate", %{"index" => "0"})
      assert panel?(view, "#register-name[value=app]")
      assert panel?(view, "#register-workspace-#{ctx.ws.id} input[checked]")
      refute panel?(view, "#register-workspace-#{ctx.beta.id} input[checked]")

      # Root and path come from the kept candidate, whatever the form says.
      submit(view, %{
        "name" => "app",
        "root" => "/etc",
        "path" => "../../secret",
        "workspace_ids" => ["", to_string(ctx.ws.id), to_string(ctx.beta.id)]
      })

      assert_receive {:fake, {:register, ^mbp, attrs, register_id}}

      assert attrs == %{
               root: "~/code",
               path: "app",
               name: "app",
               workspace_ids: [ctx.ws.id, ctx.beta.id]
             }

      assert panel?(view, "#local-repository-register-submit[disabled]", "正在等待 alice-mbp 确认…")

      # A second submit while waiting sends nothing.
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      refute_receive {:fake, {:register, _, _, _}}, 50

      # The daemon's sync already listed the repository; then the result arrives.
      local_repository_fixture(ctx.ws, ctx.mbp, %{name: "app"})
      Fake.result(register_id, mbp, {:ok, %{action: :register, name: "app"}})
      assert_patch(view, ctx.path)
      assert render(view) =~ "已在 alice-mbp 上登记 app"
      refute open?(view, @panel)
      assert has_element?(view, ~s(#local-repositories [data-status="online"]), "可用")
    end

    test "an outdated daemon cannot be chosen", ctx do
      Fake.put(:machines, %{
        ctx.users.alice.id => [machine(ctx.mbp, :daemon_outdated, ctx.workspaces)]
      })

      {:ok, view, _html} = open_panel(ctx)
      mbp = ctx.mbp.id

      refute_receive {:fake, {:browse, _, _}}, 50
      assert panel?(view, "#register-machine-#{mbp}[disabled]")
      assert panel?(view, "#register-machine-#{mbp}-reason", "守护进程版本过旧")
      assert panel?(view, "#register-machine-#{mbp}-reason", "helmsman repos add")

      # A forged selection is ignored.
      render_change(view, "select_machine", %{"daemon_id" => to_string(mbp)})
      refute_receive {:fake, {:browse, _, _}}, 50
    end

    test "a machine without allowed roots offers the two commands", ctx do
      Fake.put(:machines, %{
        ctx.users.alice.id => [machine(ctx.mbp, :registration_disabled, ctx.workspaces)]
      })

      {:ok, view, _html} = open_panel(ctx)
      reason = "#register-machine-#{ctx.mbp.id}-reason"

      assert panel?(view, "#register-machine-#{ctx.mbp.id}[disabled]")
      assert panel?(view, "#{reason}-roots-command-text", "helmsman repos roots add <目录>")

      assert panel?(
               view,
               "#{reason}-add-command-text",
               "helmsman repos add <路径> --name <名字> --workspace #{ctx.ws.slug}"
             )
    end

    test "the machine allowing web registration while the panel is open", ctx do
      alice = ctx.users.alice.id
      Fake.put(:machines, %{alice => [machine(ctx.mbp, :registration_disabled, ctx.workspaces)]})
      {:ok, view, _html} = open_panel(ctx)
      assert panel?(view, "#register-machine-#{ctx.mbp.id}[disabled]")

      Fake.put(:machines, %{alice => [machine(ctx.mbp, :ok, ctx.workspaces)]})
      send(view.pid, {:daemons_changed})

      eventually(fn -> !panel?(view, "#register-machine-#{ctx.mbp.id}[disabled]") end)
      assert open?(view, @panel)
      mbp = ctx.mbp.id
      assert_receive {:fake, {:browse, ^mbp, _}}
    end

    test "a machine update keeps the chosen candidate and the input", ctx do
      view = pick_app(ctx)

      render_change(view, "validate_register", %{
        "register" => %{"name" => "app-2", "workspace_ids" => [""]}
      })

      send(view.pid, {:daemons_changed})
      # Past the reload throttle (500ms).
      Process.sleep(700)

      assert panel?(view, "#register-name[value=app-2]")
      assert panel?(view, "#register-workspaces-error", "至少选择一个工作区")
      assert panel?(view, "#register-candidate-0[aria-pressed=true]")
    end

    test "name_taken keeps the panel and the input", ctx do
      view = pick_app(ctx)

      submit(view, %{
        "name" => "app",
        "workspace_ids" => [to_string(ctx.ws.id), to_string(ctx.beta.id)]
      })

      assert_receive {:fake, {:register, _, _, register_id}}

      Fake.result(register_id, ctx.mbp.id, {:error, :name_taken, nil})
      render(view)

      assert open?(view, @panel)
      assert panel?(view, "#register-name-error", "这台机器上已有同名的本地仓库")
      assert panel?(view, "#register-name[value=app]")
      assert panel?(view, "#register-candidate-0[aria-pressed=true]")
      assert panel?(view, "#register-workspace-#{ctx.beta.id} input[checked]")
      refute panel?(view, "#local-repository-register-submit[disabled]")
    end

    test "while waiting the form is locked and the result names what was sent", ctx do
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, %{name: "app"}, register_id}}
      assert panel?(view, "#register-fields[disabled]")

      render_change(view, "validate_register", %{
        "register" => %{"name" => "other", "workspace_ids" => [to_string(ctx.beta.id)]}
      })

      assert panel?(view, "#register-name[value=app]")
      assert panel?(view, "#register-workspace-#{ctx.ws.id} input[checked]")

      Fake.result(register_id, ctx.mbp.id, {:ok, %{action: :register, name: "app"}})
      assert_patch(view, ctx.path)
      html = render(view)
      assert html =~ "已在 alice-mbp 上登记 app"
      refute html =~ "登记 other"
    end

    test "a late change does not move name_taken to another name", ctx do
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, _, register_id}}

      render_change(view, "validate_register", %{
        "register" => %{"name" => "other", "workspace_ids" => [to_string(ctx.beta.id)]}
      })

      Fake.result(register_id, ctx.mbp.id, {:error, :name_taken, nil})
      render(view)

      assert panel?(view, "#register-name-error", "这台机器上已有同名的本地仓库")
      assert panel?(view, "#register-name[value=app]")
      assert panel?(view, "#register-workspace-#{ctx.ws.id} input[checked]")
      refute panel?(view, "#register-workspace-#{ctx.beta.id} input[checked]")
      refute panel?(view, "#register-fields[disabled]")
    end

    test "outside_root is explained at the top of the panel", ctx do
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, _, register_id}}

      Fake.result(register_id, ctx.mbp.id, {:error, :outside_root, nil})
      render(view)

      assert panel?(view, "#register-error", "经过符号链接")
      assert panel?(view, "#register-error", "helmsman repos add")
      refute panel?(view, "#register-error-reread")
    end

    test "missing offers reading the candidates again", ctx do
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, _, register_id}}

      Fake.result(register_id, ctx.mbp.id, {:error, :missing, nil})
      render(view)
      assert panel?(view, "#register-error", "机器上已找不到这个目录")

      render_click(view, "reread", %{})
      mbp = ctx.mbp.id
      assert_receive {:fake, {:browse, ^mbp, _}}
      assert panel?(view, "#register-browse-status")
    end

    test "the daemon's message is shown as is", ctx do
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, _, register_id}}

      Fake.result(
        register_id,
        ctx.mbp.id,
        {:error, :not_a_repository, "detected dubious ownership"}
      )

      render(view)

      assert panel?(view, "#register-error", "不是可登记的 git 仓库")
      assert panel?(view, ~s(#register-error span[lang="en"]), "detected dubious ownership")
    end

    test "invalid workspaces are marked under the workspaces", ctx do
      Fake.put(:replies, %{register: {:error, {:invalid_workspaces, [ctx.beta.id]}}})
      view = pick_app(ctx)

      submit(view, %{
        "name" => "app",
        "workspace_ids" => [to_string(ctx.ws.id), to_string(ctx.beta.id)]
      })

      assert panel?(view, "#register-workspaces-error", "所选工作区不在这台机器的服务范围内")
      assert panel?(view, "#register-workspace-#{ctx.beta.id}[data-invalid=true]")
    end

    test "names and workspaces are checked before sending", ctx do
      view = pick_app(ctx)

      render_change(view, "validate_register", %{
        "register" => %{"name" => "App!", "workspace_ids" => [""]}
      })

      assert panel?(view, "#register-name-error", "名字只能用小写字母")
      assert panel?(view, "#register-workspaces-error", "至少选择一个工作区")

      submit(view, %{"name" => "App!", "workspace_ids" => [""]})
      refute_receive {:fake, {:register, _, _, _}}, 50

      # Workspaces the machine does not serve are dropped.
      submit(view, %{"name" => "app", "workspace_ids" => ["999999", to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, %{workspace_ids: ids}, _}}
      assert ids == [ctx.ws.id]
    end

    test "no reply within the wait", ctx do
      Fake.put(:change_timeout_ms, 50)
      view = pick_app(ctx)
      submit(view, %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]})
      assert_receive {:fake, {:register, _, _, register_id}}
      assert_receive {:fake, {:forget, ^register_id}}, 500

      assert panel?(view, "#register-notice", "alice-mbp 没有在 20 秒内回复")
      assert panel?(view, "#register-notice", "结果以机器上的配置为准")
      refute panel?(view, "#local-repository-register-submit[disabled]")

      # A result arriving later is no longer this page's.
      Fake.result(register_id, ctx.mbp.id, {:ok, %{action: :register, name: "app"}})
      assert open?(view, @panel)
    end

    test "results of another request or another machine are ignored", ctx do
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}

      Fake.result(
        browse_id,
        ctx.mbp.id + 1,
        {:ok, %{roots: ["/x"], repositories: [], truncated: false}}
      )

      send(view.pid, {:local_repo_result, "other-request-id-000000", ctx.mbp.id, {:ok, %{}}})
      render(view)
      assert panel?(view, "#register-browse-status")

      browse_reply(ctx, browse_id)
      render(view)
      assert panel?(view, "#register-candidate-0")
    end

    test "filtering the candidates by path", ctx do
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}
      browse_reply(ctx, browse_id)
      render(view)

      render_change(view, "filter_candidates", %{"filter" => "GROUP"})
      assert panel?(view, "#register-candidate-1")
      refute panel?(view, "#register-candidate-0")

      render_change(view, "filter_candidates", %{"filter" => "nothing"})
      assert panel?(view, "#register-candidates-none", "没有匹配的仓库")
    end

    test "a truncated list says so", ctx do
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}
      browse_reply(ctx, browse_id, %{truncated: true})
      render(view)

      assert panel?(view, "#register-truncated", "只列出了一部分")
    end

    test "no candidate lists the roots", ctx do
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}
      browse_reply(ctx, browse_id, %{roots: ["~/code", "~/work"], repositories: []})
      render(view)

      assert panel?(view, "#register-no-candidates", "允许的目录下没有找到 git 仓库")
      assert panel?(view, "#register-no-candidates", "~/work")
    end

    test "a browse failure or timeout can be read again", ctx do
      Fake.put(:browse_timeout_ms, 50)
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}
      assert_receive {:fake, {:forget, ^browse_id}}, 500

      assert panel?(view, "#register-browse-error", "没有在 15 秒内送回仓库列表")
      Fake.put(:browse_timeout_ms, 15_000)
      render_click(view, "reread", %{})
      assert_receive {:fake, {:browse, _, browse_id}}

      Fake.result(browse_id, ctx.mbp.id, {:error, :disabled, nil})
      render(view)
      assert panel?(view, "#register-browse-error", "没有允许网页登记的目录")
      assert panel?(view, "#register-reread")
    end

    test "closing the panel stops waiting", ctx do
      {:ok, view, _html} = open_panel(ctx)
      assert_receive {:fake, {:browse, _, browse_id}}

      render_patch(view, ctx.path)
      assert_receive {:fake, {:forget, ^browse_id}}
      refute open?(view, @panel)
    end

    test "every result code has its copy" do
      codes = ~w(forbidden not_found daemon_outdated registration_disabled disabled
                 daemon_offline busy root_not_allowed invalid_path missing outside_root
                 not_a_repository inside_daemon_home invalid_name name_taken
                 already_registered invalid_workspaces not_configured config_error)a

      fallback = Components.code_text(:something_else, "m")

      for code <- codes do
        text = Components.code_text(code, "alice-mbp")
        assert text != fallback, "#{code} has no copy"
      end

      assert Components.code_text(:daemon_offline, "alice-mbp") == "alice-mbp 离线"
      assert Components.code_text(:busy, "alice-mbp") =~ "alice-mbp 正在处理另一个请求"
    end
  end

  describe "网页移除本地仓库" do
    setup ctx do
      app = local_repository_fixture(ctx.ws, ctx.mbp, %{name: "app"})
      owner_scope = workspace_scope_fixture(ctx.users.carol, ctx.ws)
      bos = project_fixture(owner_scope, %{key: "BOS"})
      bind_local(bos, app)
      %{app: app}
    end

    test "removing after the confirmation", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      id = ctx.app.id

      view |> element("#local-repository-remove-#{id}") |> render_click()
      assert open?(view, @dialog)
      assert dialog?(view, "#local-repository-remove-dialog-title", "从 alice-mbp 的配置中移除 app？")

      assert dialog?(
               view,
               "#local-repository-remove-dialog-description",
               "helmsman repos remove app"
             )

      assert dialog?(view, "#local-repository-remove-workspaces", "Acme、Beta")
      assert dialog?(view, "#local-repository-remove-projects", "BOS")
      assert dialog?(view, "#local-repository-remove-dialog-description", "仓库文件和其中的 hm/… 分支都不会改变")

      render_click(view, "remove_local", %{})
      assert_receive {:fake, {:remove, ^id, request_id}}
      assert dialog?(view, "#local-repository-remove-status", "正在等待 alice-mbp 确认…")
      assert dialog?(view, "#local-repository-remove-confirm[disabled]")

      ctx.app
      |> Ecto.Changeset.change(
        status: "unavailable",
        unavailable_reason: "not configured on the machine"
      )
      |> Helmsman.Repo.update!()

      Fake.result(request_id, ctx.mbp.id, {:ok, %{action: :remove, name: "app"}})
      html = render(view)
      assert html =~ "已从 alice-mbp 移除 app"
      refute open?(view, @dialog)
      assert has_element?(view, "#local-repository-#{id} [data-reason]", "机器上已不再配置")
      refute has_element?(view, "#local-repository-remove-#{id}")
    end

    test "a failure or no reply is shown in the dialog", ctx do
      Fake.put(:change_timeout_ms, 50)
      {:ok, view, _html} = open(ctx, :alice)
      render_click(view, "ask_remove", %{"id" => to_string(ctx.app.id)})
      render_click(view, "remove_local", %{})
      assert_receive {:fake, {:remove, _, request_id}}
      assert_receive {:fake, {:forget, ^request_id}}, 500

      assert dialog?(view, "#local-repository-remove-error", "alice-mbp 没有在 20 秒内回复")
      refute dialog?(view, "#local-repository-remove-confirm[disabled]")

      Fake.put(:change_timeout_ms, 20_000)
      render_click(view, "remove_local", %{})
      assert_receive {:fake, {:remove, _, request_id}}
      Fake.result(request_id, ctx.mbp.id, {:error, :config_error, "unsupported TOML"})
      render(view)

      assert dialog?(view, "#local-repository-remove-error", "config.toml 无法安全地自动修改")
      assert dialog?(view, ~s(#local-repository-remove-error span[lang="en"]), "unsupported TOML")

      render_click(view, "dismiss_remove", %{})
      refute open?(view, @dialog)
    end

    test "an offline machine disables 移除 with the reason", ctx do
      Fake.put(:machines, %{
        ctx.users.alice.id => [machine(ctx.mbp, :daemon_offline, ctx.workspaces)]
      })

      {:ok, view, _html} = open(ctx, :alice)
      button = "#local-repository-remove-#{ctx.app.id}"

      assert has_element?(view, "#{button}[aria-disabled=true]")
      assert has_element?(view, "#local-repositories [role=tooltip]", "alice-mbp 离线")

      render_click(view, "ask_remove", %{"id" => to_string(ctx.app.id)})
      refute open?(view, @dialog)
    end

    test "a row no longer configured on the machine has no 移除", ctx do
      ctx.app
      |> Ecto.Changeset.change(
        status: "unavailable",
        unavailable_reason: "not configured on the machine"
      )
      |> Helmsman.Repo.update!()

      {:ok, view, _html} = open(ctx, :alice)
      refute has_element?(view, "#local-repository-remove-#{ctx.app.id}")
    end

    test "admin carol cannot change alice's repository", ctx do
      {:ok, view, _html} = open(ctx, :carol, "?all=1")
      assert has_element?(view, "#local-repository-#{ctx.app.id} [data-owner]", "alice")
      refute has_element?(view, "#local-repository-remove-#{ctx.app.id}")
      refute has_element?(view, "#local-repository-#{ctx.app.id} button", "移除")

      render_click(view, "ask_remove", %{"id" => to_string(ctx.app.id)})
      refute open?(view, @dialog)
      refute_receive {:fake, {:remove, _, _}}, 50
    end
  end

  describe "网页操作记录" do
    defp change(ctx, attrs) do
      Map.merge(
        %{
          id: 1,
          action: :register,
          name: "app",
          daemon_name: "alice-mbp",
          operator: %{user_id: ctx.users.alice.id, name: "alice"},
          root: "~/code",
          path: "app",
          state: :succeeded,
          error: nil,
          message: nil,
          inserted_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        },
        attrs
      )
    end

    test "the user's own record", ctx do
      Fake.put(:changes, fn _scope, _view -> [change(ctx, %{})] end)
      {:ok, view, _html} = open(ctx, :alice)
      alice = ctx.users.alice.id
      assert_receive {:fake, {:list_changes, ^alice, :mine}}

      row = "#local-repository-change-1"
      assert has_element?(view, "#local-repository-changes h3", "网页操作记录")
      assert has_element?(view, "#{row} [data-operator]", "alice")
      assert has_element?(view, "#{row} [data-machine]", "alice-mbp")
      assert has_element?(view, "#{row} [data-action]", "登记")
      assert has_element?(view, "#{row} [data-name]", "app")
      assert has_element?(view, "#{row} [data-location]", "~/code / app")
      assert has_element?(view, "#{row} [data-result]", "成功")
    end

    test "no record, no section", ctx do
      {:ok, view, _html} = open(ctx, :alice)
      refute has_element?(view, "#local-repository-changes")
    end

    test "the all view only for owners and admins", ctx do
      {:ok, _carol, _html} = open(ctx, :carol, "?all=1")
      carol = ctx.users.carol.id
      assert_receive {:fake, {:list_changes, ^carol, :all}}

      {:ok, _bob, _html} = open(ctx, :bob, "?all=1")
      bob = ctx.users.bob.id
      assert_receive {:fake, {:list_changes, ^bob, :mine}}
      refute_receive {:fake, {:list_changes, ^bob, :all}}, 50
    end

    test "a late result updates the record without a reload", ctx do
      Fake.put(:changes, fn _scope, _view ->
        [change(ctx, %{state: :pending, completed_at: nil})]
      end)

      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, "#local-repository-change-1[data-state=pending]", "等待中")

      Fake.put(:changes, fn _scope, _view ->
        [change(ctx, %{state: :failed, error: :config_error, message: "bad toml"})]
      end)

      send(view.pid, {:local_repository_changes_changed})

      eventually(fn -> has_element?(view, "#local-repository-change-1[data-state=failed]") end)
      assert has_element?(view, "#local-repository-change-1 [data-result]", "失败")

      assert has_element?(
               view,
               "#local-repository-change-1 [data-result]",
               "config.toml 无法安全地自动修改"
             )
    end

    test "no reply and removals", ctx do
      Fake.put(:changes, fn _scope, _view ->
        [
          change(ctx, %{
            id: 2,
            action: :remove,
            root: nil,
            path: nil,
            state: :no_reply,
            completed_at: nil
          })
        ]
      end)

      {:ok, view, _html} = open(ctx, :alice)
      assert has_element?(view, "#local-repository-change-2 [data-action]", "移除")
      assert has_element?(view, "#local-repository-change-2 [data-result]", "没有收到回复")
      refute has_element?(view, "#local-repository-change-2 [data-location]")
    end
  end
end
