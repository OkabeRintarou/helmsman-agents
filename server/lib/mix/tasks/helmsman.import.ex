defmodule Mix.Tasks.Helmsman.Import do
  @shortdoc "Imports a workspace snapshot"
  @moduledoc "mix helmsman.import PATH --workspace SLUG --as EMAIL [--mode merge|replace] [--confirm SLUG] [--dry-run] [--rename old=new]"
  use Boundary, top_level?: true, deps: [Helmsman]
  use Mix.Task
  alias Helmsman.{Accounts, Backup, Workspaces}
  alias Helmsman.Accounts.Scope
  @requirements ["app.start"]
  @impl Mix.Task
  def run(args), do: execute(args, :helmsman)

  def execute(args, source) do
    with {opts, [path], []} <-
           OptionParser.parse(args,
             strict: [
               workspace: :string,
               as: :string,
               mode: :string,
               confirm: :string,
               dry_run: :boolean,
               rename: :keep
             ]
           ),
         {:ok, mode} <- mode(opts[:mode] || "merge"),
         {:ok, rename} <- rename(Keyword.get_values(opts, :rename)),
         user when not is_nil(user) <- Accounts.get_user_by_email(opts[:as] || ""),
         {:ok, %{workspace: workspace, membership: membership, actor: actor}} <-
           Workspaces.fetch_for_user(user, opts[:workspace] || ""),
         scope <- %{
           Scope.put_workspace(Scope.for_user(user), workspace, membership, actor)
           | via: :web
         },
         {:ok, report} <-
           Backup.import_file(scope, path,
             mode: mode,
             source: source,
             confirm: opts[:confirm],
             dry_run: opts[:dry_run] || false,
             rename: rename
           ) do
      Mix.shell().info(Jason.encode!(report))
    else
      error ->
        Mix.shell().error("import failed: #{inspect(error)}")
        exit({:shutdown, 1})
    end
  end

  defp mode("merge"), do: {:ok, :merge}
  defp mode("replace"), do: {:ok, :replace}
  defp mode(_), do: {:error, :invalid_mode}

  defp rename(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [old, new] when old != "" and new != "" -> {:cont, {:ok, Map.put(acc, old, new)}}
        _ -> {:halt, {:error, :invalid_rename}}
      end
    end)
  end
end
