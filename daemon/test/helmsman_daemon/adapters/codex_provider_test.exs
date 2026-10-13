defmodule HelmsmanDaemon.Adapters.CodexProviderTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanProtocol.ProviderAccount
  @fixtures Path.expand("../../fixtures/codex", __DIR__)

  defp bound do
    run = spec(1)

    %{
      run
      | agent: %{
          run.agent
          | provider: :codex,
            custom_args: [],
            provider_account: %ProviderAccount{
              base_url: "https://account.example/v1",
              api_key: "ACCOUNT_SENTINEL",
              models: %{"default" => "account-model"}
            }
        }
    }
  end

  defp params(launch) do
    launch.stdin
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> List.last()
    |> JSON.decode!()
    |> Map.fetch!("params")
  end

  setup %{tmp_dir: dir} do
    HelmsmanDaemon.CodexLogin.install(dir)

    File.write!(
      Path.join(dir, "config.toml"),
      "[codex]\nhome=" <> JSON.encode!(Path.join(dir, "codex"))
    )

    :ok
  end

  test "provider config roundtrips TOML escaping; model precedence applies to start and resume",
       %{tmp_dir: dir} do
    for url <- ["https://account.example/v1", ~s(https://account.example/quote"/slash\\/v1)],
        model <- [nil, "", "agent-model"],
        resume <- [nil, "session"] do
      run = bound()

      run = %{
        run
        | agent: %{
            run.agent
            | model: model,
              provider_account: %{run.agent.provider_account | base_url: url}
          },
          resume_session_id: resume
      }

      assert {:ok, launch} = Codex.prepare(run, dir, dir)

      assert launch.env == [
               {"CODEX_HOME", Config.home()},
               {"HELMSMAN_PROVIDER_API_KEY", "ACCOUNT_SENTINEL"}
             ]

      assert Enum.slice(launch.argv, 8, 3) == ["-c", ~s(model_provider="helmsman_account"), "-c"]
      assert {:ok, config} = Toml.decode(List.last(launch.argv))

      assert config["model_providers"]["helmsman_account"] == %{
               "name" => "Helmsman provider account",
               "base_url" => url,
               "wire_api" => "responses",
               "env_key" => "HELMSMAN_PROVIDER_API_KEY"
             }

      assert params(launch)["model"] == if(model in [nil, ""], do: "account-model", else: model)
      refute inspect(launch.argv) =~ "ACCOUNT_SENTINEL"
      refute IO.iodata_to_binary(launch.stdin) =~ "ACCOUNT_SENTINEL"
      assert File.ls!(Config.home()) == []
      refute inspect(launch) =~ "ACCOUNT_SENTINEL"
    end
  end

  test "provider custom config conflicts removed in separated, inline and quoted forms", %{
    tmp_dir: dir
  } do
    for key <- [
          "model_provider",
          "model_providers",
          "model_providers.helmsman_account.http_headers",
          ~s("model_providers"."helmsman_account".http_headers)
        ],
        flag <- ["-c", "--config"],
        inline? <- [true, false] do
      value = key <> "=SECRET_SENTINEL"
      args = if inline?, do: [flag <> "=" <> value], else: [flag, value]
      run = bound()
      run = %{run | agent: %{run.agent | custom_args: args ++ ["-c", "tools.web_search=true"]}}
      assert {:ok, launch} = Codex.prepare(run, dir, dir)
      assert Enum.take(launch.argv, -2) == ["-c", "tools.web_search=true"]
      refute inspect(launch.argv) =~ "SECRET_SENTINEL"
      assert [{:status, %{message: message}}] = launch.events
      assert message =~ String.replace(key, "\"", "")
      refute message =~ "SECRET_SENTINEL"
    end

    assert {["-c", ~s(model_provider="mine")], []} =
             Config.filter(["-c", ~s(model_provider="mine")])
  end

  test "snapshots disabled for bound and unbound accounts; old directories and symlinks are removed",
       %{tmp_dir: dir} do
    for run <- [bound(), %{bound() | agent: %{bound().agent | provider_account: nil}}] do
      Paths.private_dir!(Config.home())
      snapshots = Path.join(Config.home(), "shell_snapshots")
      File.mkdir_p!(snapshots)
      File.write!(Path.join(snapshots, "old.sh"), "legacy")
      outside = Path.join(dir, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "untouched")
      File.ln_s!(outside, Path.join(snapshots, "link"))

      run = %{
        run
        | agent: %{
            run.agent
            | custom_args: [
                "--enable",
                "shell_snapshot",
                "--enable",
                "shell_snapshot_v2",
                "-c",
                "features.shell_snapshot=true"
              ]
          }
      }

      assert {:ok, launch} = Codex.prepare(run, dir, dir)

      assert Enum.slice(launch.argv, 2, 4) == [
               "--disable",
               "shell_snapshot",
               "--disable",
               "shell_snapshot_v2"
             ]

      assert Enum.take(launch.argv, -6) == run.agent.custom_args
      refute File.exists?(snapshots)
      assert File.read!(Path.join(outside, "keep")) == "untouched"
      File.ln_s!(outside, snapshots)
      assert {:ok, _} = Codex.prepare(run, dir, dir)
      assert File.lstat(snapshots) == {:error, :enoent}
      assert File.read!(Path.join(outside, "keep")) == "untouched"
    end
  end

  test "snapshot cleanup failure emits a name-only warning and continues", %{tmp_dir: dir} do
    Paths.private_dir!(Config.home())
    nested = Path.join([Config.home(), "shell_snapshots", "private"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "SECRET_SENTINEL"), "legacy")
    File.chmod!(nested, 0o000)
    on_exit(fn -> File.chmod(nested, 0o700) end)
    assert {:ok, launch} = Codex.prepare(bound(), dir, dir)
    assert [{:status, %{level: :warning, message: message}}] = launch.events
    assert message == "Could not remove old Codex shell snapshots"
    File.chmod!(nested, 0o700)
  end

  test "reserved id is rejected in detection and preparation without exposing values", %{
    tmp_dir: dir
  } do
    Paths.private_dir!(Config.home())
    path = Path.join(Config.home(), "config.toml")

    File.write!(
      path,
      ~s([model_providers.helmsman_account]\nhttp_headers={x="SECRET_SENTINEL"}\n)
    )

    assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)
    assert message =~ "reserved"
    assert message =~ "helmsman_account"
    refute message =~ "SECRET_SENTINEL"
    assert {:error, {:workspace_prepare, ^message}} = Codex.prepare(bound(), dir, dir)
  end

  test "recorded thread provider starts normally; derived mismatches abort before turn/start" do
    reply = File.read!(Path.join(@fixtures, "provider_thread_start.jsonl")) |> String.trim()

    assert {[{:session, _}], [{:write, _}], _} =
             Codex.handle_output(:stdout, reply, Codex.init_state(bound()))

    mismatch = File.read!(Path.join(@fixtures, "provider_thread_mismatch.jsonl")) |> String.trim()

    assert {[], [{:abort, :cli_error, message}], state} =
             Codex.handle_output(:stdout, mismatch, Codex.init_state(bound()))

    assert message =~ "openai"
    assert {[], [], ^state} = Codex.handle_output(:stdout, reply, state)
    plain = spec(1)

    assert {[{:session, _}], [{:write, _}], _} =
             Codex.handle_output(:stdout, mismatch, Codex.init_state(plain))

    decoded = JSON.decode!(reply)

    missing =
      JSON.encode!(%{decoded | "result" => Map.delete(decoded["result"], "modelProvider")})

    assert {[], [{:abort, :cli_error, _}], _} =
             Codex.handle_output(:stdout, missing, Codex.init_state(bound()))

    resume = %{bound() | resume_session_id: "session"}

    assert {[], [{:abort, :cli_error, _}], _} =
             Codex.handle_output(:stdout, mismatch, Codex.init_state(resume))

    assert {[{:session, _}], [{:write, _}], _} =
             Codex.handle_output(:stdout, missing, Codex.init_state(resume))
  end

  test "unbound environment warning lists only names", %{tmp_dir: dir} do
    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: [],
            env: %{
              "OPENAI_BASE_URL" => "URL_SENTINEL",
              "OPENAI_API_KEY" => "KEY_SENTINEL",
              "CODEX_API_KEY" => "CODEX_SENTINEL",
              "FOO" => "1"
            }
        }
    }

    assert {:ok, launch} = Codex.prepare(run, dir, dir)
    assert [{:status, %{message: message}}] = launch.events
    assert message =~ "CODEX_API_KEY, OPENAI_API_KEY, OPENAI_BASE_URL"

    for value <- ["URL_SENTINEL", "KEY_SENTINEL", "CODEX_SENTINEL", "FOO"],
        do: refute(message =~ value)

    assert {:ok, launch} =
             Codex.prepare(
               %{run | agent: %{run.agent | provider_account: bound().agent.provider_account}},
               dir,
               dir
             )

    assert launch.events == []
  end
end
