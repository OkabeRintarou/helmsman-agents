defmodule Helmsman.GitHub.ManifestTest do
  # Removes the GitHub App environment variables.
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.GitHubFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.GitHub
  alias Helmsman.GitHub.App
  alias Helmsman.GitHub.AppConfig

  @base_url "https://helmsman.example"

  setup do
    admin = user_fixture() |> Ecto.Changeset.change(instance_admin: true) |> Repo.update!()
    %{admin: Scope.for_user(admin), user: Scope.for_user(user_fixture())}
  end

  defp params(extra \\ %{}),
    do: Map.merge(%{name: "Helmsman", owner_org: nil, public?: false, base_url: @base_url}, extra)

  describe "manifest/2" do
    setup do: without_app_env()

    test "contains every field of design decision 5", %{admin: admin} do
      assert {:ok, %{action_url: action_url, manifest_json: json}} =
               GitHub.manifest(admin, params())

      assert action_url == "https://github.com/settings/apps/new"

      assert Jason.decode!(json) == %{
               "name" => "Helmsman",
               "url" => @base_url,
               "hook_attributes" => %{"url" => @base_url <> "/webhooks/github", "active" => true},
               "redirect_url" => @base_url <> "/admin/github/callback",
               "callback_urls" => [@base_url <> "/github/setup"],
               "setup_url" => @base_url <> "/github/setup",
               "setup_on_update" => true,
               "request_oauth_on_install" => true,
               "public" => false,
               "default_permissions" => %{
                 "contents" => "write",
                 "pull_requests" => "write",
                 "checks" => "read",
                 "statuses" => "read",
                 "metadata" => "read"
               },
               "default_events" => ~w(pull_request check_suite check_run status repository)
             }
    end

    test "an organization and a public App", %{admin: admin} do
      assert {:ok, %{action_url: url, manifest_json: json}} =
               GitHub.manifest(admin, params(%{owner_org: "acme", public?: true}))

      assert url == "https://github.com/organizations/acme/settings/apps/new"
      assert %{"public" => true} = Jason.decode!(json)
    end

    test "invalid names and organizations are refused", %{admin: admin} do
      assert GitHub.manifest(admin, params(%{name: " "})) == {:error, :invalid_params}
      assert GitHub.manifest(admin, params(%{owner_org: "a/b"})) == {:error, :invalid_params}
    end

    test "non instance administrators and agents → forbidden", %{admin: admin, user: user} do
      assert GitHub.manifest(user, params()) == {:error, :forbidden}
      agent = %{admin | actor: %Actor{kind: :agent}}
      assert GitHub.manifest(agent, params()) == {:error, :forbidden}
    end
  end

  describe "complete_manifest/2" do
    defp stub_conversion do
      test = self()

      stub_github(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/app-manifests/abc123/conversions"
        send(test, :converted)

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "id" => 99,
          "slug" => "helmsman-acme",
          "name" => "Helmsman Acme",
          "html_url" => "https://github.com/apps/helmsman-acme",
          "owner" => %{"login" => "acme"},
          "client_id" => "Iv1.abc",
          "client_secret" => "conv-client-secret",
          "webhook_secret" => "conv-webhook-secret",
          "pem" => "-----BEGIN RSA PRIVATE KEY-----\nconv\n-----END RSA PRIVATE KEY-----\n"
        })
      end)
    end

    test "saves the App and the configuration source becomes the database", %{admin: admin} do
      without_app_env()
      stub_conversion()

      assert {:ok, %{configured?: true, source: :database, slug: "helmsman-acme"} = overview} =
               GitHub.complete_manifest(admin, "abc123")

      refute Map.has_key?(overview, :private_key)
      assert {:ok, %AppConfig{source: :database, app_id: 99}} = AppConfig.current()

      %{rows: [[secret]]} = Repo.query!("SELECT webhook_secret FROM github_apps")
      refute secret =~ "conv-webhook-secret"
      assert Repo.one(App).webhook_secret == "conv-webhook-secret"
    end

    test "non instance administrators and agents → forbidden", %{admin: admin, user: user} do
      without_app_env()
      stub_github(fn _conn -> flunk("GitHub must not be called") end)

      assert GitHub.complete_manifest(user, "abc123") == {:error, :forbidden}
      agent = %{admin | actor: %Actor{kind: :agent}}
      assert GitHub.complete_manifest(agent, "abc123") == {:error, :forbidden}
      refute Repo.exists?(App)
    end

    test "refused when the environment configures the App", %{admin: admin} do
      stub_github(fn _conn -> flunk("GitHub must not be called") end)
      assert GitHub.complete_manifest(admin, "abc123") == {:error, :already_configured}
      assert GitHub.manifest(admin, params()) == {:error, :already_configured}
    end

    test "refused when an App was already created", %{admin: admin} do
      without_app_env()
      stub_conversion()
      assert {:ok, _} = GitHub.complete_manifest(admin, "abc123")
      assert_received :converted

      assert GitHub.complete_manifest(admin, "abc123") == {:error, :already_configured}
      refute_received :converted
    end
  end
end
