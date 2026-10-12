# Every test runs with a GitHub App configured from the environment, with a
# key generated for this run; tests of the other configuration sources
# (async: false) change the variables and restore them.
Helmsman.GitHubFixtures.put_app_env()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Helmsman.Repo, :manual)
