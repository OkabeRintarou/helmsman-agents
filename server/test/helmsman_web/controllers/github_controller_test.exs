defmodule HelmsmanWeb.GitHubControllerTest do
  # Some tests remove the GitHub App environment variables.
  use HelmsmanWeb.ConnCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.GitHub.App
  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Installation
  alias Helmsman.Repo
  alias HelmsmanWeb.Endpoint

  setup :register_and_log_in_user

  defp make_instance_admin(user), do: set_instance_admin(user, true)

  # The first user registered in a test is an instance administrator.
  defp set_instance_admin(user, admin?),
    do: user |> Ecto.Changeset.change(instance_admin: admin?) |> Repo.update!()

  defp manifest_state(user, opts \\ []),
    do: Phoenix.Token.sign(Endpoint, "github-manifest", %{u: user.id}, opts)

  defp install_state(workspace, user, opts \\ []),
    do: Phoenix.Token.sign(Endpoint, "github-install", %{w: workspace.id, u: user.id}, opts)

  defp expired, do: [signed_at: System.system_time(:second) - 601]

  defp no_github_calls, do: stub_github(fn _conn -> flunk("GitHub must not be called") end)

  describe "GET /admin/github/callback" do
    defp stub_conversion do
      stub_github(fn conn ->
        "/app-manifests/the-code/conversions" = conn.request_path

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "id" => 12,
          "slug" => "helmsman-test",
          "name" => "Helmsman Test",
          "html_url" => "https://github.com/apps/helmsman-test",
          "owner" => %{"login" => "acme"},
          "client_id" => "Iv1.cb",
          "client_secret" => "cb-secret",
          "webhook_secret" => "cb-webhook",
          "pem" => "pem"
        })
      end)
    end

    test "403 for other users, without calling GitHub", %{conn: conn, user: user} do
      without_app_env()
      set_instance_admin(user, false)
      no_github_calls()

      conn =
        get(conn, ~p"/admin/github/callback", %{code: "the-code", state: manifest_state(user)})

      assert response(conn, 403)
      refute Repo.exists?(App)
    end

    test "a state not issued to this user in the last 10 minutes is refused", %{
      conn: conn,
      user: user
    } do
      without_app_env()
      make_instance_admin(user)
      no_github_calls()
      other = user_fixture()

      for state <- [manifest_state(other), manifest_state(user, expired()), "garbage"] do
        conn = get(conn, ~p"/admin/github/callback", %{code: "the-code", state: state})
        assert redirected_to(conn) == ~p"/admin/github"
        assert Phoenix.Flash.get(conn.assigns.flash, :error)
      end

      refute Repo.exists?(App)
    end

    test "saves the App; the configuration then comes from the database", %{
      conn: conn,
      user: user
    } do
      without_app_env()
      make_instance_admin(user)
      stub_conversion()

      conn =
        get(conn, ~p"/admin/github/callback", %{code: "the-code", state: manifest_state(user)})

      assert redirected_to(conn) == ~p"/admin/github"
      assert Phoenix.Flash.get(conn.assigns.flash, :info)

      assert %App{app_id: 12, slug: "helmsman-test", created_by_id: user_id} = Repo.one(App)
      assert user_id == user.id
      assert {:ok, %AppConfig{source: :database}} = AppConfig.current()
    end
  end

  describe "GET /w/:slug/settings/github/connect" do
    test "403 for members", %{conn: conn, user: user} do
      workspace = workspace_fixture(user_fixture())
      member_fixture(workspace, user, :member)
      no_github_calls()

      assert conn |> get(~p"/w/#{workspace.slug}/settings/github/connect") |> response(403)
    end

    test "admins are redirected to the installation page with a valid state", %{
      conn: conn,
      user: user
    } do
      workspace = workspace_fixture(user)

      stub_github(fn conn ->
        "/app" = conn.request_path
        Req.Test.json(conn, %{"id" => app_id(), "slug" => "helmsman-env"})
      end)

      conn = get(conn, ~p"/w/#{workspace.slug}/settings/github/connect")
      location = redirected_to(conn, 302)
      assert location =~ "https://github.com/apps/helmsman-env/installations/new?state="

      %{"state" => state} = URI.decode_query(URI.parse(location).query)

      assert {:ok, %{w: workspace_id, u: user_id}} =
               Phoenix.Token.verify(Endpoint, "github-install", state, max_age: 600)

      assert {workspace_id, user_id} == {workspace.id, user.id}
    end
  end

  describe "GET /github/setup" do
    setup %{user: user} do
      %{workspace: workspace_fixture(user)}
    end

    test "an expired state or one of another user links nothing", %{
      conn: conn,
      user: user,
      workspace: workspace
    } do
      no_github_calls()

      for state <- [
            install_state(workspace, user, expired()),
            install_state(workspace, user_fixture())
          ] do
        conn =
          get(conn, ~p"/github/setup", %{installation_id: "42", code: "c", state: state})

        assert redirected_to(conn) == ~p"/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error)
      end

      refute Repo.exists?(Installation)
    end

    test "links the installation and returns to the GitHub settings", %{
      conn: conn,
      user: user,
      workspace: workspace
    } do
      id = unique_github_id()

      stub_github(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/login/oauth/access_token"} ->
            Req.Test.json(conn, %{"access_token" => "gho_user"})

          {"GET", "/user/installations"} ->
            Req.Test.json(conn, %{"installations" => [%{"id" => id}]})

          {"GET", "/app/installations/" <> _} ->
            Req.Test.json(conn, github_installation(id))
        end
      end)

      conn =
        get(conn, ~p"/github/setup", %{
          installation_id: Integer.to_string(id),
          setup_action: "install",
          code: "oauth-code",
          state: install_state(workspace, user)
        })

      assert redirected_to(conn) == ~p"/w/#{workspace.slug}/settings/github"
      assert Phoenix.Flash.get(conn.assigns.flash, :info)

      assert %Installation{workspace_id: workspace_id} =
               Repo.get_by(Installation, installation_id: id)

      assert workspace_id == workspace.id
    end

    test "an error from the connection is shown on the GitHub settings", %{
      conn: conn,
      user: user,
      workspace: workspace
    } do
      no_github_calls()

      conn =
        get(conn, ~p"/github/setup", %{
          installation_id: "42",
          state: install_state(workspace, user)
        })

      assert redirected_to(conn) == ~p"/w/#{workspace.slug}/settings/github"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OAuth"
    end
  end
end
