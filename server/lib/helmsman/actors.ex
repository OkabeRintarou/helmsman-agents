defmodule Helmsman.Actors do
  @moduledoc """
  Actors: every identity that appears in records (humans, agents, squads and
  the workspace's system identity `helmsman`).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Repo
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @base_max 60
  @name_max 64
  @max_attempts 10

  @doc """
  Derives the base name of a human identity from an email address.

  Takes the part before `@`, downcases it, replaces characters outside
  `[a-z0-9._-]` with `-`, drops leading non-alphanumeric characters and
  truncates to #{@base_max} characters; an empty result becomes `user`.

      iex> derive_human_name("Alice.W@example.com")
      "alice.w"

      iex> derive_human_name("+ops+bob@example.com")
      "ops-bob"
  """
  @spec derive_human_name(String.t()) :: String.t()
  def derive_human_name(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> hd()
    |> String.downcase()
    |> then(&Regex.replace(~r/[^a-z0-9._-]/u, &1, "-"))
    |> String.replace(~r/^[^a-z0-9]+/, "")
    |> String.slice(0, @base_max)
    |> case do
      "" -> "user"
      name -> name
    end
  end

  @doc """
  Returns the user's human identity in `workspace`, creating it if needed.

  Runs in the caller's transaction. The name is derived with
  `derive_human_name/1`; on a conflict `-2`, `-3`, ... is appended. The
  insert uses `ON CONFLICT DO NOTHING`, so a concurrent insert of the same
  name or of the same user's identity never aborts the caller's
  transaction.
  """
  @spec ensure_human(Workspace.t(), User.t()) ::
          {:ok, Actor.t()} | {:error, :name_unavailable}
  def ensure_human(%Workspace{} = workspace, %User{} = user) do
    case get_human(workspace.id, user.id) do
      %Actor{} = actor -> {:ok, actor}
      nil -> insert_human(workspace, user, derive_human_name(user.email), @max_attempts)
    end
  end

  defp insert_human(_workspace, _user, _base, 0), do: {:error, :name_unavailable}

  defp insert_human(workspace, user, base, attempts) do
    name = next_free_name(workspace.id, base)

    row = %{
      workspace_id: workspace.id,
      kind: :human,
      name: name,
      user_id: user.id
    }

    case insert_ignoring_conflicts(row) do
      {:ok, actor} ->
        {:ok, actor}

      :conflict ->
        # Either the same user joined concurrently or the name was taken.
        case get_human(workspace.id, user.id) do
          %Actor{} = actor -> {:ok, actor}
          nil -> insert_human(workspace, user, base, attempts - 1)
        end
    end
  end

  # Picks `base`, else the lowest free `base-N` (N >= 2). `helmsman` counts
  # as taken.
  defp next_free_name(workspace_id, base) do
    pattern = escape_like(base) <> "-%"

    taken =
      from(a in Actor,
        where: a.workspace_id == ^workspace_id,
        where: a.name == ^base or like(a.name, ^pattern),
        select: fragment("lower(?::text)", a.name)
      )
      |> Repo.all()
      |> MapSet.new()
      |> MapSet.put(Actor.system_name())

    if MapSet.member?(taken, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&with_suffix(base, &1))
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      base
    end
  end

  defp with_suffix(base, n) do
    suffix = "-#{n}"
    String.slice(base, 0, @name_max - String.length(suffix)) <> suffix
  end

  defp escape_like(string), do: String.replace(string, ~r/([\\%_])/, "\\\\\\1")

  @doc """
  Returns the workspace's system identity `helmsman`, creating it if needed.

  Runs in the caller's transaction.
  """
  @spec ensure_system(Workspace.t()) :: {:ok, Actor.t()}
  def ensure_system(%Workspace{} = workspace) do
    row = %{workspace_id: workspace.id, kind: :system, name: Actor.system_name()}

    case insert_ignoring_conflicts(row) do
      {:ok, actor} ->
        {:ok, actor}

      :conflict ->
        {:ok,
         Repo.one!(from(a in Actor, where: a.workspace_id == ^workspace.id and a.kind == :system))}
    end
  end

  defp insert_ignoring_conflicts(row) do
    now = DateTime.utc_now(:second)
    row = Map.merge(row, %{inserted_at: now, updated_at: now})

    case Repo.insert_all(Actor, [row], on_conflict: :nothing, returning: true) do
      {1, [actor]} -> {:ok, actor}
      {0, []} -> :conflict
    end
  end

  @doc "Returns the user's human identity in the workspace, or nil."
  @spec get_human(pos_integer(), pos_integer()) :: Actor.t() | nil
  def get_human(workspace_id, user_id) do
    Repo.one(
      from(a in Actor,
        where: a.workspace_id == ^workspace_id and a.user_id == ^user_id and a.kind == :human
      )
    )
  end

  @doc """
  Renames the human identity the scope acts as.
  """
  @spec rename_own(Scope.t(), String.t()) ::
          {:ok, Actor.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def rename_own(%Scope{actor: %Actor{} = actor} = scope, new_name) do
    rename(scope, actor, new_name)
  end

  @doc """
  Renames `actor`. Only allowed for the caller's own human identity
  (`:rename_own_actor`); system identities can never be renamed.
  """
  @spec rename(Scope.t(), Actor.t(), String.t()) ::
          {:ok, Actor.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def rename(%Scope{} = scope, %Actor{} = actor, new_name) do
    Workspaces.write_transaction(scope, :rename_own_actor, actor, fn scope ->
      query =
        from(a in Actor,
          where: a.workspace_id == ^scope.workspace.id and a.id == ^actor.id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        current -> current |> Actor.rename_changeset(%{name: new_name}) |> Repo.update()
      end
    end)
  end
end
