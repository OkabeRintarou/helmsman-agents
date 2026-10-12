# Every test runs with a GitHub App configured from the environment, with a
# key generated for this run; tests of the other configuration sources
# (async: false) change the variables and restore them.
Helmsman.GitHubFixtures.put_app_env()

# assert_receive waits up to 1s (default 100ms) so loaded CI runners do not
# fail on slow but correct message delivery; refute_receive keeps 100ms.
# End-to-end tests (real daemon) run separately with `mix test --only e2e`.
ExUnit.start(exclude: [:e2e], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Helmsman.Repo, :manual)
