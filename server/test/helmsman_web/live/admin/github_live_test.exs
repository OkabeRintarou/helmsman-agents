defmodule HelmsmanWeb.Admin.GitHubLiveTest do
  @moduledoc """
  Spec web-github 实例管理的 GitHub App 页 (add-github-ui tasks 5.1).
  """
  # Some tests remove the GitHub App environment variables.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.GitHub.App
  alias Helmsman.GitHub.AppConfig
  alias Helmsman.Repo
  alias HelmsmanWeb.GitHubState

  @secrets ["test-webhook-secret", "test-client-secret", "PRIVATE KEY", "cb-secret", "cb-webhook"]

  setup %{conn: conn} do
    # The first user registered in a test is an instance administrator.
    admin = user_fixture()
    user = user_fixture()
    %{conn: conn, admin: admin, user: user}
  end

  defp open(conn, user), do: conn |> log_in_user(user) |> live(~p"/admin/github")

  defp refute_secrets(view, html) do
    state = view.pid |> :sys.get_state() |> inspect(limit: :infinity, printable_limit: :infinity)

    for secret <- @secrets do
      refute html =~ secret
      refute state =~ secret
    end
  end

  defp stub_conversion do
    stub_github(fn conn ->
      "/app-manifests/the-code/conversions" = conn.request_path

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "id" => 12,
        "slug" => "helmsman-prod",
        "name" => "Helmsman Prod",
        "html_url" => "https://github.com/apps/helmsman-prod",
        "owner" => %{"login" => "acme-inc"},
        "client_id" => "Iv1.cb",
        "client_secret" => "cb-secret",
        "webhook_secret" => "cb-webhook",
        "pem" => "pem"
      })
    end)
  end

  defp form_attr(html, selector, attr),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)

  describe "access" do
    test "non-instance administrators get 403", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)

      assert_raise HelmsmanWeb.ForbiddenError, fn -> live(conn, ~p"/admin/github") end
      assert_error_sent 403, fn -> get(conn, ~p"/admin/github") end
    end

    test "logged-out visitors are sent to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin/github")
    end
  end

  describe "frame" do
    test "实例管理 with the single tab GitHub App and the page title", %{conn: conn, admin: admin} do
      {:ok, view, _html} = open(conn, admin)

      assert has_element?(view, "main#hm-main h1", "实例管理")

      assert has_element?(
               view,
               ~s(nav a[href="/admin/github"][aria-current="page"]),
               "GitHub App"
             )

      refute has_element?(view, ~s(nav a[href="/users/settings"]))
      assert has_element?(view, "#hm-back-to-workspace[href='/']")
      assert page_title(view) =~ "GitHub App · Helmsman"
    end
  end

  describe "configured" do
    test "by environment variables: source, App ID and the restart note, no secrets", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, html} = open(conn, admin)

      assert has_element?(view, "#github-app-source", "环境变量")
      assert has_element?(view, "#github-app-id", Integer.to_string(app_id()))
      assert has_element?(view, "#github-app-env-note", "由环境变量配置；修改请更新环境变量并重启服务")
      refute has_element?(view, "#github-manifest-form")
      refute_secrets(view, html)
    end

    test "by the manifest flow: the stored overview, no restart note", %{
      conn: conn,
      admin: admin
    } do
      without_app_env()

      Repo.insert!(%App{
        app_id: 77,
        slug: "helmsman-db",
        name: "Helmsman DB",
        html_url: "https://github.com/apps/helmsman-db",
        owner_login: "acme-inc",
        client_id: "Iv1.db",
        client_secret: "test-client-secret",
        webhook_secret: "test-webhook-secret",
        private_key: "-----BEGIN RSA PRIVATE KEY-----",
        created_by_id: admin.id
      })

      {:ok, view, html} = open(conn, admin)

      assert has_element?(view, "#github-app-source", "GitHub 上创建（manifest）")
      assert has_element?(view, "#github-app-id", "77")
      assert html =~ "helmsman-db"
      assert html =~ "acme-inc"

      assert has_element?(
               view,
               ~s(#github-app-homepage[href="https://github.com/apps/helmsman-db"][target="_blank"][rel="noopener noreferrer"])
             )

      refute has_element?(view, "#github-app-env-note")
      refute_secrets(view, html)
    end
  end

  describe "creating the App" do
    setup do
      without_app_env()
      :ok
    end

    test "posts the manifest to the organization's App page with a state", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, html} = open(conn, admin)

      assert has_element?(view, "#github-app-name[value=Helmsman][maxlength='34']")
      # No state is issued when the page opens.
      assert form_attr(html, "#github-manifest-form", "action") == []
      refute has_element?(view, "#github-manifest")

      html =
        view
        |> form("#github-manifest-form",
          app: %{name: "Helmsman Prod", owner_org: "acme-inc", public: "false"}
        )
        |> render_submit()

      assert [_] = form_attr(html, "#github-manifest-form[phx-trigger-action]", "id")
      assert ["post"] = form_attr(html, "#github-manifest-form", "method")
      [action] = form_attr(html, "#github-manifest-form", "action")
      assert action =~ "https://github.com/organizations/acme-inc/settings/apps/new?state="
      %{"state" => state} = URI.decode_query(URI.parse(action).query)
      assert GitHubState.verify_manifest(state, admin.id) == :ok

      # No CSRF token of this site is posted to GitHub.
      assert form_attr(html, "#github-manifest-form input[name=_csrf_token]", "value") == []

      [manifest] = form_attr(html, "#github-manifest-form #github-manifest", "value")

      assert %{
               "name" => "Helmsman Prod",
               "public" => false,
               "request_oauth_on_install" => true,
               "hook_attributes" => %{"url" => hook},
               "redirect_url" => redirect_url
             } = Jason.decode!(manifest)

      assert hook =~ "/webhooks/github"
      assert redirect_url =~ "/admin/github/callback"
    end

    test "the state is issued on submit, so a page left open still completes", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = open(conn, admin)

      # A state issued long before (when the page was opened) would be refused.
      stale =
        Phoenix.Token.sign(HelmsmanWeb.Endpoint, "github-manifest", %{u: admin.id},
          signed_at: System.system_time(:second) - 30 * 60
        )

      assert GitHubState.verify_manifest(stale, admin.id) == :error

      html =
        view
        |> form("#github-manifest-form",
          app: %{name: "Helmsman Prod", owner_org: "acme-inc", public: "true"}
        )
        |> render_submit()

      [action] = form_attr(html, "#github-manifest-form", "action")
      %{"state" => state} = URI.decode_query(URI.parse(action).query)

      stub_conversion()

      conn =
        build_conn()
        |> log_in_user(admin)
        |> get(~p"/admin/github/callback", %{code: "the-code", state: state})

      assert redirected_to(conn) == ~p"/admin/github"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "GitHub App 已创建"
      assert %App{app_id: 12, slug: "helmsman-prod"} = Repo.one(App)
      assert {:ok, %AppConfig{source: :database}} = AppConfig.current()

      {:ok, view, html} = live(conn, ~p"/admin/github")
      assert has_element?(view, "#github-app-source", "GitHub 上创建（manifest）")
      assert html =~ "GitHub App 已创建"
      refute_secrets(view, html)
    end

    test "an invalid name or organization is reported and not submitted", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = open(conn, admin)

      html =
        view
        |> form("#github-manifest-form", app: %{name: "Helmsman", owner_org: "bad org!"})
        |> render_change()

      assert html =~ "名称或组织无效"
      assert has_element?(view, "#github-manifest-submit[disabled]")

      html =
        view
        |> form("#github-manifest-form", app: %{name: "  ", owner_org: ""})
        |> render_submit()

      assert html =~ "名称或组织无效"
      refute has_element?(view, "#github-manifest-form[phx-trigger-action]")
      refute has_element?(view, "#github-manifest")

      view
      |> form("#github-manifest-form", app: %{name: "Helmsman", owner_org: ""})
      |> render_change()

      refute has_element?(view, "#github-manifest-error")
      refute has_element?(view, "#github-manifest-submit[disabled]")
    end

    test "a personal account App goes to the user's App page", %{conn: conn, admin: admin} do
      {:ok, view, _html} = open(conn, admin)

      html =
        view
        |> form("#github-manifest-form", app: %{name: "Helmsman", owner_org: ""})
        |> render_submit()

      [action] = form_attr(html, "#github-manifest-form", "action")
      assert action =~ "https://github.com/settings/apps/new?state="
    end

    test "configured meanwhile: the overview replaces the form", %{conn: conn, admin: admin} do
      {:ok, view, _html} = open(conn, admin)

      Repo.insert!(%App{
        app_id: 78,
        slug: "other",
        name: "Other",
        html_url: "https://github.com/apps/other",
        owner_login: "acme",
        client_id: "Iv1.o",
        client_secret: "test-client-secret",
        webhook_secret: "test-webhook-secret",
        private_key: "-----BEGIN RSA PRIVATE KEY-----",
        created_by_id: admin.id
      })

      html =
        view
        |> form("#github-manifest-form", app: %{name: "Helmsman", owner_org: ""})
        |> render_submit()

      assert html =~ "GitHub App 已经配置过了"
      assert has_element?(view, "#github-app-id", "78")
      refute has_element?(view, "#github-manifest-form")
    end
  end

  describe "user menu" do
    setup %{admin: admin, user: user} do
      ws = workspace_fixture(admin, %{name: "Acme"})
      member_fixture(ws, user, :member)
      %{ws: ws}
    end

    test "instance administrators have 实例管理 leading to /admin/github", %{
      conn: conn,
      admin: admin,
      ws: ws
    } do
      {:ok, view, _html} = conn |> log_in_user(admin) |> live("/w/#{ws.slug}")

      assert has_element?(view, ~s(#hm-instance-admin[href="/admin/github"]), "实例管理")

      assert {:error, {:live_redirect, %{to: "/admin/github"}}} =
               view |> element("#hm-instance-admin") |> render_click()
    end

    test "other users do not", %{conn: conn, user: user, ws: ws} do
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/w/#{ws.slug}")

      assert has_element?(view, "#hm-provider-accounts")
      refute has_element?(view, "#hm-instance-admin")
    end
  end
end
