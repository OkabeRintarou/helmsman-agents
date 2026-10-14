defmodule Helmsman.Release do
  @moduledoc """
  Management commands of the release, where mix tasks are not available
  (`add-release-distribution` decisions 2 and 9):

      bin/migrate                                    # migrate/0, run by bin/start
      bin/server eval 'Helmsman.Release.rollback(Helmsman.Repo, 20260101000000)'
      bin/server eval 'Helmsman.Release.reindex("acme")'
      bin/server eval 'Helmsman.Release.bootstrap(email: "you@example.com", workspace: "acme")'
      bin/server eval 'Helmsman.Release.export("acme", "/var/lib/helmsman/acme.json.gz")'
      bin/server eval 'Helmsman.Release.import("/var/lib/helmsman/acme.json.gz", "acme", "you@example.com", mode: :merge)'
      bin/server eval 'Helmsman.Release.import_bosun("/var/lib/helmsman/bosun.json", "acme", "you@example.com", dry_run: true)'

  They take the arguments of the matching mix tasks, start only what they
  need (never the HTTP endpoint, no Oban queue or plugin), so they can run
  next to the serving instance (`docker compose exec app …`), print their
  report and exit non-zero when they fail.
  """

  # Its own top-level boundary, like the mix tasks it mirrors.
  use Boundary, top_level?: true, deps: [Helmsman]

  alias Helmsman.{Accounts, Backup, Workspaces}
  alias Helmsman.Accounts.Scope
  alias Helmsman.Search.Reindex

  @app :helmsman

  @doc """
  Runs all pending migrations. Concurrent callers wait on the migration
  lock (`migration_lock: :pg_advisory_lock`), so only one migrates.
  """
  @spec migrate() :: :ok
  def migrate do
    run(fn ->
      load_app()

      for repo <- repos() do
        {:ok, _migrated, _apps} =
          Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end

      :ok
    end)
  end

  @doc "Rolls `repo` back to the migration `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) when is_atom(repo) and is_integer(version) do
    run(fn ->
      load_app()

      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

      :ok
    end)
  end

  @doc """
  Rebuilds the full-text search columns of every workspace, or of the
  workspace `slug` (as `mix helmsman.reindex [--workspace slug]`). Prints
  and returns the counts.
  """
  @spec reindex(String.t() | nil) :: Reindex.counts()
  def reindex(slug \\ nil) when is_binary(slug) or is_nil(slug) do
    run(fn ->
      start_app()

      counts =
        try do
          Reindex.run(workspace: slug)
        rescue
          error in ArgumentError -> fail(Exception.message(error))
        end

      IO.puts(Jason.encode!(counts))
      counts
    end)
  end

  @doc """
  Ensures a confirmed user and a workspace owned by them, as
  `mix helmsman.bootstrap --email … --workspace … [--name …]`:
  `bootstrap(email: "you@example.com", workspace: "acme", name: "Acme")`.
  Prints the user, the workspace and a login link valid for 15 minutes;
  returns the result of `Helmsman.Bootstrap.run/1`.
  """
  @spec bootstrap(keyword() | map()) :: Helmsman.Bootstrap.result()
  def bootstrap(opts) when is_list(opts) or is_map(opts) do
    run(fn ->
      opts = Enum.map(opts, fn {key, value} -> {to_atom(key), value} end)

      unless is_binary(opts[:email]) and is_binary(opts[:workspace]) do
        raise ArgumentError, "usage: bootstrap(email: <email>, workspace: <slug>[, name: <name>])"
      end

      start_app()

      case Helmsman.Bootstrap.run(Keyword.take(opts, [:email, :workspace, :name])) do
        {:ok, result} ->
          IO.puts("""
          User: #{result.user.email}#{created_note(result.created, :user)}
          Workspace: #{result.workspace.slug}#{created_note(result.created, :workspace)}
          Login link (valid for 15 minutes): #{public_url()}/users/log-in/#{result.login_token}\
          """)

          result

        {:error, :not_a_member} ->
          fail("workspace #{opts[:workspace]} exists and #{opts[:email]} is not a member of it")

        {:error, %Ecto.Changeset{} = changeset} ->
          fail("invalid input: #{inspect(changeset.errors)}")

        {:error, reason} ->
          fail("bootstrap failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Exports the workspace `slug` to the gzip JSON file `path`, as
  `mix helmsman.export --workspace SLUG --out PATH`. Prints and returns the
  counts with the file. `path` should be in the data directory
  (`HELMSMAN_DATA_DIR`, a volume in the image).
  """
  @spec export(String.t(), String.t()) :: map()
  def export(slug, path) when is_binary(slug) and is_binary(path) do
    run(fn ->
      start_app()

      workspace = Workspaces.get_by_slug(slug) || fail(~s(no workspace "#{slug}"))

      case Backup.export_to_file(workspace, path) do
        {:ok, stats} ->
          result = Map.put(stats, :file, path)
          IO.puts(Jason.encode!(result))
          result

        {:error, reason} ->
          fail("export failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Imports the Helmsman export `path` into the workspace `slug` as the user
  `email`, as `mix helmsman.import PATH --workspace SLUG --as EMAIL …`.
  `opts`: `mode: :merge | :replace` (default `:merge`), `confirm: slug`
  (replace), `dry_run: true`, `rename: %{"old" => "new"}` (or
  `["old=new"]`). Prints and returns the report.
  """
  @spec import(String.t(), String.t(), String.t(), keyword() | map()) :: map()
  def import(path, slug, email, opts \\ []), do: import_as(path, slug, email, opts, :helmsman)

  @doc """
  Imports the bosun v2 export `path`, as `mix helmsman.import_bosun`; the
  arguments are those of `import/4`.
  """
  @spec import_bosun(String.t(), String.t(), String.t(), keyword() | map()) :: map()
  def import_bosun(path, slug, email, opts \\ []),
    do: import_as(path, slug, email, opts, :bosun)

  defp import_as(path, slug, email, opts, source)
       when is_binary(path) and is_binary(slug) and is_binary(email) do
    run(fn ->
      import_opts = import_opts(opts, source)
      start_app()

      case Backup.import_file(import_scope(email, slug), path, import_opts) do
        {:ok, report} ->
          IO.puts(Jason.encode!(report))
          report

        error ->
          fail("import failed: #{inspect(error)}")
      end
    end)
  end

  # Options for `Backup.import_file/3`. Given options are passed as they
  # are (only the CLI spellings of `mode` and `rename` are translated), so
  # `Backup.options/2` validates them: a non-boolean `dry_run` is
  # `invalid_params`, never a real import. Omitted ones take its defaults.
  defp import_opts(opts, source) when is_list(opts) or is_map(opts) do
    opts = Enum.map(opts, fn {key, value} -> {to_atom(key), value} end)

    [mode: import_mode(Keyword.get(opts, :mode, :merge)), source: source]
    |> put_given(opts, :confirm, & &1)
    |> put_given(opts, :dry_run, & &1)
    |> put_given(opts, :rename, &import_rename/1)
  end

  defp put_given(import_opts, opts, key, fun) do
    if Keyword.has_key?(opts, key),
      do: Keyword.put(import_opts, key, fun.(Keyword.fetch!(opts, key))),
      else: import_opts
  end

  # The scope of `mix helmsman.import --as EMAIL --workspace SLUG`.
  defp import_scope(email, slug) do
    user = Accounts.get_user_by_email(email) || fail("no user #{email}")

    case Workspaces.fetch_for_user(user, slug) do
      {:ok, %{workspace: workspace, membership: membership, actor: actor}} ->
        %{Scope.put_workspace(Scope.for_user(user), workspace, membership, actor) | via: :web}

      _ ->
        fail(~s(no workspace "#{slug}" with #{email} as a member))
    end
  end

  defp import_mode(mode) when mode in [:merge, "merge"], do: :merge
  defp import_mode(mode) when mode in [:replace, "replace"], do: :replace
  defp import_mode(mode), do: fail("invalid mode #{inspect(mode)} (merge or replace)")

  defp import_rename(pairs) when is_list(pairs) do
    Map.new(pairs, fn pair ->
      case is_binary(pair) and String.split(pair, "=", parts: 2) do
        [old, new] when old != "" and new != "" -> {old, new}
        _ -> fail("invalid rename #{inspect(pair)} (old=new)")
      end
    end)
  end

  # A map, or anything else for `Backup.options/2` to refuse.
  defp import_rename(rename), do: rename

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  defp created_note(created, item), do: if(item in created, do: " (created)", else: "")

  defp public_url do
    @app |> Application.get_env(:public_url, "http://localhost:4000") |> String.trim_trailing("/")
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Many platforms require SSL when connecting to the database.
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # The application without the HTTP server and without running jobs: jobs
  # may be inserted, the serving instance runs them. A no-op where the
  # application already runs (tests).
  defp start_app do
    load_app()

    unless List.keymember?(Application.started_applications(), @app, 0) do
      endpoint = Application.get_env(@app, HelmsmanWeb.Endpoint, [])
      Application.put_env(@app, HelmsmanWeb.Endpoint, Keyword.put(endpoint, :server, false))

      oban = Application.get_env(@app, Oban, [])

      Application.put_env(
        @app,
        Oban,
        Keyword.merge(oban, queues: [], plugins: [], peer: false, stager: false)
      )

      {:ok, _apps} = Application.ensure_all_started(@app)
    end

    :ok
  end

  defp run(fun) do
    fun.()
  catch
    :throw, {__MODULE__, :failed} ->
      halt(1)

    kind, reason ->
      IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
      halt(1)
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    throw({__MODULE__, :failed})
  end

  # `System.halt/1`; tests replace it (`config :helmsman, Helmsman.Release, halt: fun`).
  defp halt(status) do
    halt = Keyword.get(Application.get_env(@app, __MODULE__, []), :halt, &System.halt/1)
    halt.(status)
  end
end
