defmodule Helmsman.E2E.LocalRepoWebRegistrationTest do
  # add-local-repo-web-registration 5.1: real LiveView, protocol 7 daemon,
  # fake CLI, and repositories isolated in a temporary machine home.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.ConnCase, only: [log_in_user: 2]
  import HelmsmanWeb.PortalHelpers

  @moduletag :e2e
  @moduletag timeout: 300_000

  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, GitWorkspaceE2E, Projects, Repo}
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.LocalRepositories.{Change, LocalRepository, TaskLocalBranch, WebRegistration}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup %{conn: conn} do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    temp = Path.join(System.tmp_dir!(), "helmsman-e2e-web-repo-#{tag}")
    code = Path.join(temp, "code")
    app = Path.join(code, "app")
    outside = Path.join([temp, "outside", "external"])
    File.mkdir_p!(app)
    File.mkdir_p!(outside)
    init_repository(app)
    init_repository(outside)
    File.ln_s!(outside, Path.join(code, "link"))
    on_exit(fn -> File.rm_rf!(temp) end)

    {owner, scope, project} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "local-repo-web-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "local-repo-#{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        {owner, scope, project_fixture(scope)}
      end)

    endpoint_url = DaemonE2E.start_endpoint()
    {daemon, token} = daemon_fixture(owner, %{workspace_ids: [scope.workspace.id]})
    machine_home = Path.join(temp, "machine")
    DaemonE2E.write_credentials(machine_home, endpoint_url, daemon.id, token)
    write_config(machine_home, endpoint_url, [code])

    port =
      DaemonE2E.start_e2e_daemon(machine_home, %{
        heartbeat_interval_ms: 60_000,
        config_check_interval_ms: 100,
        merge_check_interval_ms: 600_000,
        run_worker_opts: %{push_backoff_ms: [0, 0]}
      })

    runtime =
      DaemonE2E.wait_until(port, "runtime #{daemon.id} online", fn ->
        Repo.get_by(Runtime,
          daemon_id: daemon.id,
          workspace_id: scope.workspace.id,
          status: "online"
        )
      end)

    DaemonE2E.wait_until(port, "web registration reported by daemon", fn ->
      case Repo.get(Daemon, daemon.id) do
        %Daemon{repo_registration: true} = online -> online
        _ -> nil
      end
    end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{
      conn: conn,
      tag: tag,
      temp: temp,
      code: code,
      app: app,
      outside: outside,
      owner: owner,
      scope: scope,
      project: project,
      daemon: daemon,
      runtime: runtime,
      machine_home: machine_home,
      port: port,
      path: "/w/#{scope.workspace.slug}/settings/runtimes"
    }
  end

  test "web registration, local delivery, link rejection, removal, and disabled roots", ctx do
    {:ok, view, _html} =
      live(
        log_in_user(ctx.conn, ctx.owner),
        ctx.path <> "?panel=register-local-repository"
      )

    assert open?(view, "local-repository-register-panel")

    await_view(
      view,
      fn _html ->
        in_portal?(view, "local-repository-register-panel", "#register-candidate-0")
      end,
      "candidate browse"
    )

    assert in_portal?(view, "local-repository-register-panel", "#register-candidate-0", "app")
    refute in_portal?(view, "local-repository-register-panel", "#register-candidate-1")
    refute in_portal?(view, "local-repository-register-panel", "#register-candidates", "link")

    render_click(view, "select_candidate", %{"index" => "0"})

    render_submit(view, "register", %{
      "register" => %{
        "name" => "app",
        "workspace_ids" => [to_string(ctx.scope.workspace.id)]
      }
    })

    repo =
      DaemonE2E.wait_until(ctx.port, "registered app configuration", fn ->
        case Repo.get_by(LocalRepository,
               daemon_id: ctx.daemon.id,
               workspace_id: ctx.scope.workspace.id,
               name: "app",
               status: "online"
             ) do
          %LocalRepository{} = registered -> registered
          _ -> nil
        end
      end)

    change =
      DaemonE2E.wait_until(ctx.port, "successful web registration record", fn ->
        case Repo.get_by(Change, daemon_id: ctx.daemon.id, action: "register", name: "app") do
          %Change{status: "succeeded"} = completed -> completed
          _ -> nil
        end
      end)

    config = File.read!(Path.join(ctx.machine_home, "config.toml"))
    assert config =~ "allowed_roots = [\"#{ctx.code}\"]"
    assert config =~ "name = \"app\""
    assert config =~ "path = \"#{ctx.app}\""
    assert config =~ "added_from = \"web\""
    assert config =~ "request_id = \"#{change.request_id}\""

    html =
      await_view(
        view,
        fn rendered ->
          not open?(view, "local-repository-register-panel") and
            String.contains?(rendered, "data-status=\"online\"") and
            String.contains?(rendered, "成功")
        end,
        "registration result in LiveView"
      )

    assert html =~ "可用"
    assert has_element?(view, "#local-repository-#{repo.id}-status[data-status=\"online\"]", "可用")

    assert has_element?(
             view,
             "#local-repository-change-#{change.id}[data-state=\"succeeded\"]",
             "成功"
           )

    assert {:ok, _project} =
             Projects.bind_local_repository(ctx.scope, ctx.project.key, repo.id)

    scenario =
      write_scenario(ctx.machine_home, "web-registration", [
        "write delivered through web registration",
        ~s(json {"type":"result","data":{"text":"delivered","success":true}})
      ])

    agent =
      managed_agent_fixture(ctx.scope, %{
        name: "keel/dev",
        runtime_id: ctx.runtime.id,
        custom_args: [scenario]
      })

    actor = agent_actor(ctx.scope.workspace, agent.name)
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: actor.name})
    [run] = runs_of(task.id)
    branch = "hm/#{ctx.scope.workspace.id}/#{String.downcase(task.ident)}"

    assert %Run{status: :succeeded, push_status: :pushed, branch: ^branch} =
             wait_status(ctx.port, run, "delivery to web-registered app")

    Oban.drain_queue(queue: :runs)

    assert GitWorkspaceE2E.git!(ctx.app, ["show", "#{branch}:hello.txt"]) ==
             "delivered through web registration\n"

    assert %TaskLocalBranch{state: "open", branch: ^branch} =
             Repo.get_by!(TaskLocalBranch, task_id: task.id)

    before_link_attempt = File.read!(Path.join(ctx.machine_home, "config.toml"))

    assert {:ok, link_request_id} =
             WebRegistration.register(ctx.scope, ctx.daemon.id, %{
               root: ctx.code,
               path: "link",
               name: "linked",
               workspace_ids: [ctx.scope.workspace.id]
             })

    daemon_id = ctx.daemon.id

    assert_receive {:local_repo_result, ^link_request_id, ^daemon_id,
                    {:error, :outside_root, _message}},
                   15_000

    assert File.read!(Path.join(ctx.machine_home, "config.toml")) == before_link_attempt

    view |> element("#local-repository-remove-#{repo.id}") |> render_click()
    assert open?(view, "local-repository-remove-dialog")
    render_click(view, "remove_local", %{})

    removed =
      DaemonE2E.wait_until(ctx.port, "app removed from machine config", fn ->
        case File.read(Path.join(ctx.machine_home, "config.toml")) do
          {:ok, text} -> if String.contains?(text, "[[local_repositories]]"), do: nil, else: text
          _ -> nil
        end
      end)

    refute removed =~ "[[local_repositories]]"

    assert Repo.get!(Task, task.id)
           |> then(&Repo.get!(Helmsman.Projects.Project, &1.project_id))
           |> Map.fetch!(:local_repository_id) == repo.id

    DaemonE2E.wait_until(ctx.port, "server marks removed repository unavailable", fn ->
      case Repo.get(LocalRepository, repo.id) do
        %LocalRepository{
          status: "unavailable",
          unavailable_reason: "not configured on the machine"
        } = row ->
          row

        _ ->
          nil
      end
    end)

    html =
      await_view(
        view,
        fn rendered ->
          String.contains?(rendered, "机器上已不再配置") and
            not open?(view, "local-repository-remove-dialog")
        end,
        "removed repository explanation"
      )

    assert html =~ "机器上已不再配置"
    assert Repo.get!(Helmsman.Projects.Project, ctx.project.id).local_repository_id == repo.id

    render_patch(view, ctx.path <> "?panel=register-local-repository")

    _html =
      await_view(
        view,
        fn _html ->
          in_portal?(view, "local-repository-register-panel", "#register-candidates")
        end,
        "reopened registration panel"
      )

    write_config(ctx.machine_home, endpoint_url_from_config(config), [])
    disabled_deadline = System.monotonic_time(:millisecond) + 30_000

    DaemonE2E.wait_until(
      ctx.port,
      "web registration disabled after allowed roots cleared",
      fn ->
        case Repo.get(Daemon, ctx.daemon.id) do
          %Daemon{repo_registration: false} = disabled -> disabled
          _ -> nil
        end
      end,
      remaining_ms(disabled_deadline)
    )

    disabled_machine = "#register-machine-#{ctx.daemon.id}[disabled]"
    disabled_reason = "#register-machine-#{ctx.daemon.id}-reason"

    panel =
      await_portal_until(
        view,
        "local-repository-register-panel",
        fn tree ->
          portal_has?(tree, disabled_machine) and
            portal_has?(tree, disabled_reason, "没有允许网页登记的目录")
        end,
        "disabled registration UI after config reload",
        disabled_deadline
      )

    assert portal_has?(panel, disabled_machine)
    assert portal_has?(panel, disabled_reason, "没有允许网页登记的目录")
  end

  defp init_repository(path) do
    File.mkdir_p!(path)
    GitWorkspaceE2E.git!(path, ["init", "--initial-branch=main"])
    GitWorkspaceE2E.git!(path, ["config", "user.name", "Local repo E2E"])
    GitWorkspaceE2E.git!(path, ["config", "user.email", "local-repo-e2e@example.test"])
    File.write!(Path.join(path, "README.md"), "local repository\n")
    GitWorkspaceE2E.git!(path, ["add", "README.md"])
    GitWorkspaceE2E.git!(path, ["commit", "-m", "initial repository"])
  end

  defp write_config(home, endpoint_url, roots) do
    roots = Enum.map_join(roots, ", ", &"\"#{&1}\"")

    File.write!(
      Path.join(home, "config.toml"),
      "server_url = \"#{endpoint_url}\"\nlog_level = \"debug\"\n\n[repos]\nallowed_roots = [#{roots}]\n"
    )
  end

  defp endpoint_url_from_config(config) do
    [_, url] = Regex.run(~r/^server_url = "([^"]+)"$/m, config)
    url
  end

  defp write_scenario(home, name, lines) do
    path = Path.join(home, "#{name}.scenario")
    File.write!(path, Enum.join(lines ++ ["exit 0"], "\n") <> "\n")
    path
  end

  defp wait_status(port, run, label) do
    id = if match?(%Run{}, run), do: run.id, else: run

    DaemonE2E.wait_until(
      port,
      fn -> "#{label} (#{inspect(Repo.get!(Run, id), limit: :infinity)})" end,
      fn ->
        run = Repo.get!(Run, id)
        if run.status in [:succeeded, :failed, :cancelled], do: run
      end
    )
  end

  defp await_view(view, predicate, label, timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_view_until(view, predicate, label, deadline)
  end

  defp await_view_until(view, predicate, label, deadline) do
    html = render(view)

    cond do
      predicate.(html) ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{label}; last LiveView output: #{html}")

      true ->
        Process.sleep(50)
        await_view_until(view, predicate, label, deadline)
    end
  end

  defp await_portal_until(view, portal_id, predicate, label, deadline) do
    tree = portal(view, portal_id)
    now = System.monotonic_time(:millisecond)

    cond do
      now <= deadline and predicate.(tree) ->
        tree

      now >= deadline ->
        flunk("timed out waiting for #{label}")

      true ->
        Process.sleep(min(50, deadline - now))
        await_portal_until(view, portal_id, predicate, label, deadline)
    end
  end

  defp portal_has?(tree, selector, text \\ nil) do
    tree
    |> LazyHTML.query(selector)
    |> Enum.any?(fn node -> is_nil(text) or LazyHTML.text(node) =~ text end)
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
