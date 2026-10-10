defmodule Mix.Tasks.Helmsman.Bootstrap do
  @shortdoc "Creates a user and a workspace and prints a login link"

  @moduledoc """
  Creates (if missing) a confirmed user and a workspace owned by that user,
  then prints a login link valid for 15 minutes.

      $ mix helmsman.bootstrap --email you@example.com --workspace acme [--name "Acme Inc."]

  Running it again with the same arguments changes nothing and prints a new
  link. It fails when the workspace exists and the user is not a member.
  """

  # A separate top-level boundary: it may call the domain and build the URL
  # with the web endpoint, which the domain itself must not reference.
  use Boundary, top_level?: true, deps: [Helmsman, HelmsmanWeb]

  use Mix.Task

  @usage "usage: mix helmsman.bootstrap --email <email> --workspace <slug> [--name <name>]"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [email: :string, workspace: :string, name: :string])

    with [] <- rest ++ invalid,
         email when is_binary(email) <- opts[:email],
         slug when is_binary(slug) <- opts[:workspace] do
      bootstrap(email: email, workspace: slug, name: opts[:name])
    else
      _ -> fail(@usage)
    end
  end

  defp bootstrap(opts) do
    case Helmsman.Bootstrap.run(opts) do
      {:ok, %{user: user, workspace: workspace, login_token: token, created: created}} ->
        Mix.shell().info("""
        User: #{user.email}#{created_note(created, :user)}
        Workspace: #{workspace.slug}#{created_note(created, :workspace)}
        Login link (valid for 15 minutes): #{HelmsmanWeb.Endpoint.url()}/users/log-in/#{token}\
        """)

      {:error, :not_a_member} ->
        fail("workspace #{opts[:workspace]} exists and #{opts[:email]} is not a member of it")

      {:error, %Ecto.Changeset{} = changeset} ->
        fail("invalid input: #{format_errors(changeset)}")

      {:error, reason} ->
        fail("bootstrap failed: #{inspect(reason)}")
    end
  end

  defp created_note(created, item), do: if(item in created, do: " (created)", else: "")

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
