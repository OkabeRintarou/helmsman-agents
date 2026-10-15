defmodule HelmsmanWeb.SettingsLive.RuntimesRegisterLocalRepoDomainTest do
  @moduledoc """
  The runtimes page against the real `Helmsman.LocalRepositories.WebRegistration`
  (add-local-repo-web-registration D8, D11): the test plays the daemon on its channel
  topic and answers through `WebRegistration.deliver/2`. The page's own behaviour (every
  error code, timeouts, forged input) is covered with a double in
  `RuntimesRegisterLocalRepoTest`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.Daemons.Daemon
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.WebRegistration
  alias Helmsman.Repo
  alias HelmsmanProtocol.{Push, Report}

  @v HelmsmanProtocol.repo_registration_version()
  @panel "local-repository-register-panel"
  @dialog "local-repository-remove-dialog"

  setup %{conn: conn} do
    olga = user_fixture(%{display_name: "olga"})
    ws = workspace_fixture(olga, %{name: "Acme"})
    alice = user_fixture(%{display_name: "alice"})
    member_fixture(ws, alice, :member)

    {mbp, _} =
      daemon_fixture(alice, %{
        name: "alice-mbp",
        workspace_ids: [ws.id],
        protocol_version: @v,
        repo_registration: true
      })

    runtime_fixture(ws, mbp)
    :ok = Events.subscribe(Events.topic(:daemon, mbp.id))

    %{
      conn: log_in_user(conn, alice),
      ws: ws,
      mbp: mbp,
      path: "/w/#{ws.slug}/settings/runtimes"
    }
  end

  defp daemon_ctx(daemon) do
    daemon = Repo.get!(Daemon, daemon.id)

    %{
      daemon_id: daemon.id,
      user_id: daemon.user_id,
      auth_epoch: daemon.auth_epoch,
      protocol: daemon.protocol_version
    }
  end

  defp deliver(ctx, report), do: :ok = WebRegistration.deliver(daemon_ctx(ctx.mbp), report)

  test "listing, registering and the record go through the domain", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path <> "?panel=register-local-repository")
    assert_receive {:local_repo_request, %Push.RepoBrowse{request_id: browse_id}}

    deliver(ctx, %Report.RepoBrowseResult{
      request_id: browse_id,
      error: nil,
      message: nil,
      roots: ["~/code"],
      repositories: [%{root: "~/code", path: "app", name: "app", registered_as: nil}],
      truncated: false
    })

    eventually(fn -> in_portal?(view, @panel, "#register-candidate-0", "app") end)
    render_click(view, "select_candidate", %{"index" => "0"})

    render_submit(view, "register", %{
      "register" => %{"name" => "app", "workspace_ids" => [to_string(ctx.ws.id)]}
    })

    assert_receive {:local_repo_request,
                    %Push.RepoRegister{request_id: register_id, root: "~/code", path: "app"}}

    local_repository_fixture(ctx.ws, ctx.mbp, %{name: "app"})

    deliver(ctx, %Report.RepoChangeResult{
      request_id: register_id,
      action: :register,
      name: "app",
      error: nil,
      message: nil
    })

    eventually(fn -> render(view) =~ "已在 alice-mbp 上登记 app" end)
    refute open?(view, @panel)

    eventually(fn ->
      has_element?(view, "#local-repository-changes [data-result]", "成功")
    end)

    assert has_element?(view, "#local-repository-changes [data-location]", "~/code / app")
  end

  test "removing goes through the domain", ctx do
    app = local_repository_fixture(ctx.ws, ctx.mbp, %{name: "app"})
    {:ok, view, _html} = live(ctx.conn, ctx.path)

    view |> element("#local-repository-remove-#{app.id}") |> render_click()
    assert in_portal?(view, @dialog, "#local-repository-remove-workspaces", "Acme")

    render_click(view, "remove_local", %{})
    assert_receive {:local_repo_request, %Push.RepoRemove{request_id: request_id, name: "app"}}

    deliver(ctx, %Report.RepoChangeResult{
      request_id: request_id,
      action: :remove,
      name: "app",
      error: nil,
      message: nil
    })

    eventually(fn -> render(view) =~ "已从 alice-mbp 移除 app" end)
    refute open?(view, @dialog)
  end
end
