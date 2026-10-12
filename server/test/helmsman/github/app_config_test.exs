defmodule Helmsman.GitHub.AppConfigTest do
  # Changes the GitHub App environment variables.
  use Helmsman.DataCase, async: false

  import Helmsman.GitHubFixtures

  alias Helmsman.GitHub.App
  alias Helmsman.GitHub.AppConfig

  defp insert_app do
    Repo.insert!(%App{
      app_id: 77,
      slug: "helmsman-db",
      name: "Helmsman DB",
      html_url: "https://github.com/apps/helmsman-db",
      owner_login: "acme",
      client_id: "Iv1.db",
      client_secret: "db-client-secret",
      private_key: "db-private-key",
      webhook_secret: "db-webhook-secret"
    })
  end

  test "environment variables take precedence over the database" do
    insert_app()
    assert {:ok, %AppConfig{source: :env, app_id: app_id}} = AppConfig.current()
    assert app_id == app_id()
  end

  test "the database configuration is used without the variables" do
    without_app_env()
    insert_app()

    assert {:ok, %AppConfig{source: :database, app_id: 77, slug: "helmsman-db"} = config} =
             AppConfig.current()

    assert config.webhook_secret == "db-webhook-secret"
  end

  test "one missing variable falls back to the database" do
    without_app_env(["GITHUB_APP_CLIENT_SECRET"])
    insert_app()
    assert {:ok, %AppConfig{source: :database}} = AppConfig.current()
    refute AppConfig.env_configured?()
  end

  test "neither source → github_not_configured" do
    without_app_env()
    assert AppConfig.current() == {:error, :github_not_configured}
  end

  test "inspect hides the three secrets" do
    {:ok, config} = AppConfig.current()
    output = inspect(config)

    refute output =~ "test-webhook-secret"
    refute output =~ "test-client-secret"
    refute output =~ "PRIVATE KEY"
    assert output =~ "app_id: #{app_id()}"

    app = insert_app()
    refute inspect(app) =~ "db-private-key"
    refute inspect(app) =~ "db-client-secret"
    refute inspect(app) =~ "db-webhook-secret"
  end

  test "the cache keeps a result until invalidated" do
    Application.put_env(:helmsman, AppConfig, cache: true)

    on_exit(fn ->
      Application.put_env(:helmsman, AppConfig, cache: false)
      AppConfig.invalidate()
    end)

    AppConfig.invalidate()
    assert {:ok, %AppConfig{source: :env}} = AppConfig.current()
    without_app_env()
    assert {:ok, %AppConfig{source: :env}} = AppConfig.current()
    AppConfig.invalidate()
    assert AppConfig.current() == {:error, :github_not_configured}
  end

  test "absence is never cached: an App saved after a negative read is seen" do
    Application.put_env(:helmsman, AppConfig, cache: true)

    on_exit(fn ->
      Application.put_env(:helmsman, AppConfig, cache: false)
      AppConfig.invalidate()
    end)

    without_app_env()
    AppConfig.invalidate()

    # A read that finds no App leaves nothing in the cache, so the App
    # saved afterwards is seen even when the invalidation ran before that
    # read returned (or not at all).
    assert AppConfig.current() == {:error, :github_not_configured}
    insert_app()
    assert {:ok, %AppConfig{source: :database, app_id: 77}} = AppConfig.current()
  end
end
