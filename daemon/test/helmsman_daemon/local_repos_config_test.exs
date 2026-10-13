defmodule HelmsmanDaemon.LocalReposConfigTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  import ExUnit.CaptureIO
  import HelmsmanDaemon.LocalRepoHelpers
  alias HelmsmanDaemon.{CLI, Connection, LocalMergeCheck, LocalRepos}
  alias HelmsmanProtocol.Messages

  setup %{tmp_dir: tmp_dir} do
    isolate_home(tmp_dir)
    :ok
  end

  defp runtime(id, slug),
    do: %{
      "workspace_id" => id,
      "workspace_slug" => slug,
      "provider" => "claude",
      "runtime_id" => id
    }

  defp start_connection(opts \\ []) do
    start_execution()
    start_supervised!({LocalMergeCheck, repo_status_sender: fn _ -> :ok end})

    start_supervised!(
      {Connection,
       Keyword.merge(
         [
           test_mode?: true,
           credentials: credentials(),
           stop: fn code -> raise "unexpected daemon exit #{code}" end,
           heartbeat_interval_ms: 100_000,
           rotation_interval_ms: 100_000,
           config_check_interval_ms: 50
         ],
         opts
       )}
    )
  end

  defp join(client, runtimes) do
    accept_connect(client)

    assert_join(
      "daemon:1",
      payload,
      {:ok, %{"daemon_id" => 1, "runtimes" => runtimes, "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(client, ref, {:ok, %{"runs" => []}})
    payload
  end

  defp cli(args) do
    {code, output} = with_io(fn -> CLI.run(args) end)
    {code, output}
  end

  test "repos add while the daemon runs: sync within the check interval reports the repository" do
    user = user_repo()
    git!(user, ["switch", "-q", "-c", "develop"])
    client = start_connection()
    join = join(client, [runtime(7, "acme")])
    assert join["local_repositories"] == []

    # Connection recorded the served workspaces after the join reply.
    assert LocalRepos.served() == [%{id: 7, slug: "acme"}]
    refute_push("daemon:1", "sync", _, 120)

    assert {0, output} = cli(["repos", "add", user, "--name", "app", "--workspace", "acme"])
    assert output =~ "Added local repository app"

    assert_push("daemon:1", "sync", payload, ref, 1_000)

    reply(
      client,
      ref,
      {:ok, %{"daemon_id" => 1, "runtimes" => [runtime(7, "acme")], "terminate_run_ids" => []}}
    )

    assert {:ok, %Report.Sync{local_repositories: [repo]}} = Messages.decode("sync", payload)

    assert %{
             name: "app",
             path: ^user,
             workspaces: [7],
             default_branch: "develop",
             available: true,
             unavailable_reason: nil
           } = Map.from_struct(repo)

    assert Toml.decode!(File.read!(LocalRepos.config_path()))["local_repositories"] == [
             %{"name" => "app", "path" => user, "workspaces" => [7]}
           ]

    refute_push("daemon:1", "sync", _, 150)
  end

  test "a path that is not a git repository is reported unavailable" do
    plain = Path.join(scratch(), "plain")
    File.mkdir_p!(plain)
    configure([{"app", plain, [7]}])

    assert [%{available: false, unavailable_reason: "not a git repository", workspaces: [7]}] =
             LocalRepos.report([7])
  end

  test "repos add maps slugs to IDs and needs the served workspaces file" do
    user = user_repo()

    assert {1, output} = cli(["repos", "add", user, "--name", "app", "--workspace", "acme"])
    assert output =~ "start the daemon once"
    refute File.exists?(LocalRepos.config_path())

    served([{7, "acme"}, {9, "beta"}])
    assert {1, output} = cli(["repos", "add", user, "--name", "app", "--workspace", "nope"])
    assert output =~ "workspace nope is not served"

    assert {1, _} = cli(["repos", "add", user, "--name", "Bad Name", "--workspace", "acme"])
    assert {2, _} = cli(["repos", "add", user, "--workspace", "acme"])

    assert {0, _} =
             cli([
               "repos",
               "add",
               user,
               "--name",
               "app",
               "--workspace",
               "beta",
               "--workspace",
               "acme"
             ])

    assert [%{workspaces: [9, 7]}] = LocalRepos.report([7, 9])
    assert {1, output} = cli(["repos", "add", user, "--name", "app", "--workspace", "acme"])
    assert output =~ "already exists"
  end

  test "a workspace slug change keeps the shared IDs; list shows the current slug" do
    user = user_repo()
    served([{7, "acme"}])
    assert {0, _} = cli(["repos", "add", user, "--name", "app", "--workspace", "acme"])
    served([{7, "acme-renamed"}])

    assert [%{workspaces: [7]}] = LocalRepos.report([7])
    assert {0, output} = cli(["repos", "list"])
    assert output =~ "app\t#{user}\tworkspaces: acme-renamed\tavailable"
  end

  test "duplicate names, relative paths, home paths and bad layouts are unavailable with reasons" do
    user = user_repo()
    inside = Path.join(Paths.home(), "inside")
    File.mkdir_p!(inside)

    configure([
      {"dup", user, [7]},
      {"dup", user, [7]},
      {"rel", "relative/app", [7]},
      {"home", inside, [7]},
      {"Bad", user, [7]},
      {"ok", user, [7]}
    ])

    reasons = Map.new(LocalRepos.report([7]), &{&1.name, &1.unavailable_reason})

    assert reasons == %{
             "dup" => "duplicate name on the machine",
             "rel" => "path must be absolute",
             "home" => "path is inside the daemon home directory",
             "Bad" => "invalid name (lowercase letters, digits, - and _, at most 64 characters)",
             "ok" => nil
           }
  end

  test "bare repositories are accepted; a subdirectory of a work tree is not" do
    root = scratch()
    bare = Path.join(root, "bare.git")
    File.mkdir_p!(bare)
    git!(bare, ["init", "-q", "--bare"])
    user = user_repo(root)
    File.mkdir_p!(Path.join(user, "src"))
    configure([{"bare", bare, [7]}, {"sub", Path.join(user, "src"), [7]}])

    assert [
             %{available: true},
             %{available: false, unavailable_reason: "path is not the root of a git repository"}
           ] = LocalRepos.report([7])
  end

  test "workspace IDs not served are ignored in reports and marked by repos list" do
    user = user_repo()
    configure([{"app", user, [7, 8]}])
    served([{7, "acme"}])

    assert [%{workspaces: [7]}] = LocalRepos.report([7])
    assert {0, output} = cli(["repos", "list"])
    assert output =~ "workspaces: acme, 8 (not served by this daemon)"
  end

  test "repos add and remove keep the rest of config.toml; a failed write leaves it unchanged" do
    user = user_repo()
    served([{7, "acme"}])
    original = "# machine settings\nmax_concurrency = 2\n\n[extra]\nkey = \"value\"\n"
    File.write!(LocalRepos.config_path(), original)

    assert {:error, _} =
             LocalRepos.add(user, "app", ["acme"], before_rename: fn -> raise "interrupted" end)

    assert File.read!(LocalRepos.config_path()) == original

    assert File.ls!(Paths.home()) |> Enum.filter(&String.starts_with?(&1, "config.toml")) == [
             "config.toml"
           ]

    assert :ok = LocalRepos.add(user, "app", ["acme"])
    assert :ok = LocalRepos.add(user, "other", ["acme"])
    text = File.read!(LocalRepos.config_path())
    assert text =~ "# machine settings"
    decoded = Toml.decode!(text)
    assert decoded["max_concurrency"] == 2
    assert decoded["extra"] == %{"key" => "value"}
    assert Enum.map(decoded["local_repositories"], & &1["name"]) == ["app", "other"]
    assert {:ok, %{max_concurrency: 2}} = HelmsmanDaemon.Config.load()

    assert {0, _} = cli(["repos", "remove", "app"])
    assert {1, _} = cli(["repos", "remove", "app"])
    decoded = Toml.decode!(File.read!(LocalRepos.config_path()))
    assert Enum.map(decoded["local_repositories"], & &1["name"]) == ["other"]
    assert decoded["extra"] == %{"key" => "value"}

    File.write!(
      LocalRepos.config_path(),
      "local_repositories = [{name = \"x\", path = \"/x\", workspaces = [7]}]\n"
    )

    assert {:error, message} = LocalRepos.add(user, "app", ["acme"])
    assert message =~ "edit it manually"
  end

  test "protocol 1 joins report no local repositories" do
    user = user_repo()
    configure([{"app", user, [1]}])
    client = start_connection(protocol_version: 1)
    accept_connect(client)

    assert_join(
      "daemon:1",
      payload,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    refute Map.has_key?(payload, "local_repositories")
    assert payload["protocol"] == 1
  end

  test "join reports only workspaces served by the daemon" do
    user = user_repo()
    configure([{"app", user, [1, 5]}])
    client = start_connection()
    payload = join(client, [runtime(1, "bos")])

    assert [%{"name" => "app", "workspaces" => [1], "available" => true}] =
             payload["local_repositories"]
  end
end
