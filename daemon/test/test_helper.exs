# assert_receive waits up to 1s (default 100ms) so loaded CI runners do not
# fail on slow but correct message delivery; refute_receive keeps 100ms.
# :macos tests (real keychain, launchd log file) run with `mix test --include macos`.
ExUnit.start(
  exclude: [:macos] ++ if(System.get_env("HELMSMAN_REAL_CLI") == "1", do: [], else: [:real_cli]),
  assert_receive_timeout: 1_000
)
