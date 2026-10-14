defmodule Helmsman.ReleaseTest do
  # The release's management commands (add-release-distribution decision
  # 9), called as `bin/server eval` would. Replaces System.halt/1 and
  # changes the signup mode: not async.
  use Helmsman.DataCase, async: false

  import ExUnit.CaptureIO
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts
  alias Helmsman.Backup
  alias Helmsman.Backup.Import.Read
  alias Helmsman.Release
  alias Helmsman.Tasks.Task

  setup do
    test = self()
    previous = Application.get_env(:helmsman, Release)
    mode = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, Release, halt: fn status -> send(test, {:halted, status}) end)
    Application.put_env(:helmsman, :signup_mode, :invite)

    on_exit(fn ->
      Application.put_env(:helmsman, :signup_mode, mode)

      if previous,
        do: Application.put_env(:helmsman, Release, previous),
        else: Application.delete_env(:helmsman, Release)
    end)
  end

  test "migrate/0: nothing pending, :ok" do
    assert Release.migrate() == :ok
    refute_received {:halted, _}
  end

  test "rollback/2 to a version above every migration changes nothing" do
    assert Release.rollback(Helmsman.Repo, 99_999_999_999_999) == :ok
    assert Release.migrate() == :ok
    refute_received {:halted, _}
  end

  test "reindex/1 rebuilds one workspace's columns and prints the counts as JSON" do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project = project_fixture(scope)
    task_fixture(scope, project.key)

    output = capture_io(fn -> send(self(), {:counts, Release.reindex(workspace.slug)}) end)

    assert_received {:counts, %{tasks: 1, feedback: 0, cleared: 0, skipped: 0} = counts}
    assert Jason.decode!(output, keys: :atoms) == counts
    assert %{tasks: tasks} = capture_io_result(fn -> Release.reindex() end)
    assert tasks >= 1
    refute_received {:halted, _}
  end

  test "reindex/1 of an unknown workspace exits 1" do
    stderr = capture_io(:stderr, fn -> Release.reindex("no-such-workspace") end)
    assert stderr =~ ~s(no workspace "no-such-workspace")
    assert_received {:halted, 1}
  end

  test "bootstrap/1 creates the user and workspace and prints a login link" do
    output =
      capture_io(fn ->
        send(self(), {:result, Release.bootstrap(email: "ops@example.com", workspace: "acme")})
      end)

    assert_received {:result, %{user: user, workspace: workspace, created: [:user, :workspace]}}
    assert user.email == "ops@example.com" and workspace.slug == "acme"
    assert output =~ "User: ops@example.com (created)"
    assert output =~ "Workspace: acme (created)"

    [_, token] =
      Regex.run(
        ~r"Login link \(valid for 15 minutes\): http://localhost:4000/users/log-in/(\S+)",
        output
      )

    assert %{id: id} = Accounts.get_user_by_magic_link_token(token)
    assert id == user.id

    # Again: nothing created, a new link.
    output =
      capture_io(fn ->
        Release.bootstrap(%{"email" => "ops@example.com", "workspace" => "acme"})
      end)

    assert output =~ "Workspace: acme\n"
    refute_received {:halted, _}
  end

  test "bootstrap/1 fails with 1 for a workspace the user is not a member of, or bad arguments" do
    workspace_fixture(user_fixture(), %{slug: "taken"})

    stderr =
      capture_io(:stderr, fn ->
        Release.bootstrap(email: "ops@example.com", workspace: "taken")
      end)

    assert stderr =~ "workspace taken exists and ops@example.com is not a member of it"
    assert_received {:halted, 1}

    stderr = capture_io(:stderr, fn -> Release.bootstrap(email: "ops@example.com") end)
    assert stderr =~ "usage: bootstrap"
    assert_received {:halted, 1}
  end

  describe "export/2, import/4 and import_bosun/4" do
    setup do
      previous = Application.get_env(:helmsman, :backup_sandbox)
      Application.put_env(:helmsman, :backup_sandbox, true)
      # Several users (the outer setup's mode is restored on exit).
      Application.put_env(:helmsman, :signup_mode, :open)
      owner = user_fixture()
      workspace = workspace_fixture(owner)
      scope = workspace_scope_fixture(owner, workspace)
      project = project_fixture(scope)
      task_fixture(scope, project.key)
      path = Path.join(System.tmp_dir!(), "release-#{System.unique_integer([:positive])}.json.gz")

      on_exit(fn ->
        File.rm(path)
        Application.put_env(:helmsman, :backup_sandbox, previous)
      end)

      %{owner: owner, workspace: workspace, scope: scope, path: path}
    end

    test "export/2 writes the file and prints the counts; an unknown workspace exits 1", ctx do
      output = capture_io(fn -> Release.export(ctx.workspace.slug, ctx.path) end)

      assert %{"counts" => %{"tasks" => 1}, "file" => file} = Jason.decode!(output)
      assert file == ctx.path
      assert {:ok, %{"format" => "helmsman-export"}} = Read.file(ctx.path)
      refute_received {:halted, _}

      stderr = capture_io(:stderr, fn -> Release.export("no-such-workspace", ctx.path) end)
      assert stderr =~ ~s(no workspace "no-such-workspace")
      assert_received {:halted, 1}
    end

    test "import/4 merges into another workspace; dry_run and rename as in the mix task", ctx do
      {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
      target = workspace_fixture(ctx.owner)

      output =
        capture_io(fn ->
          Release.import(ctx.path, target.slug, ctx.owner.email,
            dry_run: true,
            rename: [ctx.scope.actor.name <> "=historical"]
          )
        end)

      assert Jason.decode!(output)["counts"]["tasks"]["created"] == 1
      assert task_count(target) == 0

      output =
        capture_io(fn ->
          Release.import(ctx.path, target.slug, ctx.owner.email, %{"mode" => "merge"})
        end)

      assert Jason.decode!(output)["counts"]["tasks"]["created"] == 1
      assert task_count(target) == 1
      refute_received {:halted, _}
    end

    test "import/4 exits 1 without writing: replace without confirmation, bad mode, non-member, non-admin",
         ctx do
      {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
      target = workspace_fixture(ctx.owner)
      member = user_fixture()
      member_fixture(target, member, :member)

      for {args, message} <- [
            {[ctx.path, target.slug, ctx.owner.email, [mode: :replace]], "import failed"},
            {[ctx.path, target.slug, ctx.owner.email, [mode: :overwrite]], "invalid mode"},
            {[ctx.path, target.slug, ctx.owner.email, [rename: ["nope"]]], "invalid rename"},
            {[ctx.path, target.slug, user_fixture().email, []],
             ~s(no workspace "#{target.slug}")},
            {[ctx.path, target.slug, "nobody@example.com", []], "no user nobody@example.com"},
            {[ctx.path, target.slug, member.email, []], "import failed"}
          ] do
        stderr = capture_io(:stderr, fn -> apply(Release, :import, args) end)
        assert stderr =~ message
        assert_received {:halted, 1}
      end

      assert task_count(target) == 0
    end

    test "a dry_run that is not a boolean is refused before any write, for every mode and source",
         ctx do
      {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
      target = workspace_fixture(ctx.owner)
      # Replace must not delete the task that is there.
      target_scope = workspace_scope_fixture(ctx.owner, target)
      task_fixture(target_scope, project_fixture(target_scope).key)
      bosun = "test/fixtures/bosun/export-v2.json"

      for value <- ["true", "false", 1, 0, %{}, [], [true], nil],
          {fun, path, extra} <- [
            {:import, ctx.path, []},
            {:import, ctx.path, [mode: :replace, confirm: target.slug]},
            {:import_bosun, bosun, []}
          ],
          opts <- [Keyword.put(extra, :dry_run, value), Map.new([{"dry_run", value} | extra])] do
        stderr =
          capture_io(:stderr, fn ->
            apply(Release, fun, [path, target.slug, ctx.owner.email, opts])
          end)

        assert stderr =~ "import failed: {:error, :invalid_params}"
        assert_received {:halted, 1}
      end

      assert task_count(target) == 1

      # true: the report only; false or omitted: the import.
      output =
        capture_io(fn ->
          Release.import_bosun(bosun, target.slug, ctx.owner.email, dry_run: true)
        end)

      assert Jason.decode!(output)["counts"]["tasks"]["created"] == 3
      assert task_count(target) == 1

      capture_io(fn ->
        Release.import(ctx.path, target.slug, ctx.owner.email, %{"dry_run" => false})
      end)

      assert task_count(target) == 2
      refute_received {:halted, _}
    end

    test "import_bosun/4 imports a bosun v2 file", ctx do
      target = workspace_fixture(ctx.owner)

      output =
        capture_io(fn ->
          Release.import_bosun("test/fixtures/bosun/export-v2.json", target.slug, ctx.owner.email,
            rename: %{"user" => "historical"}
          )
        end)

      assert Jason.decode!(output)["counts"]["tasks"]["created"] == 3
      assert task_count(target) == 3
      refute_received {:halted, _}
    end
  end

  defp task_count(workspace) do
    Repo.aggregate(from(t in Task, where: t.workspace_id == ^workspace.id), :count)
  end

  defp capture_io_result(fun) do
    capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
