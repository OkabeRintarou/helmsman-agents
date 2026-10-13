defmodule Helmsman.Actors.Actor do
  @moduledoc """
  An identity that appears in records: a human, an agent, a squad or the
  workspace's system identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Helmsman.Accounts.User
  alias Helmsman.Workspaces.Workspace

  @type kind :: :human | :agent | :squad | :system
  @type t :: %__MODULE__{}

  @name_format ~r/^[a-z0-9][a-z0-9._\/-]{0,63}$/
  @name_message "must be 1-64 characters of a-z, 0-9, '.', '_', '/' and '-', " <>
                  "starting with a letter or digit"

  @system_name "helmsman"

  schema "actors" do
    belongs_to :workspace, Workspace
    field :kind, Ecto.Enum, values: [:human, :agent, :squad, :system]
    field :name, :string
    belongs_to :user, User
    belongs_to :owner, User
    field :disabled_at, :utc_datetime
    # Set by `Helmsman.Actors.identify/2` for external agents.
    field :project_key, :string
    field :worktree, :string
    field :last_seen_at, :utc_datetime_usec
    field :unclaimed, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "The name reserved for the system identity."
  @spec system_name() :: String.t()
  def system_name, do: @system_name

  @doc "Returns true if `name` follows the actor naming rule."
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_format, name)

  @doc """
  Changeset for a new actor. `workspace_id`, `kind`, `user_id` and
  `owner_id` are set by the caller.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name])
    |> validate_required([:workspace_id, :kind])
    |> validate_kind_links()
    |> validate_name()
    |> map_constraints()
  end

  @doc "Changeset for renaming an actor."
  @spec rename_changeset(t(), map()) :: Ecto.Changeset.t()
  def rename_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name])
    |> validate_name()
    |> map_constraints()
  end

  defp validate_name(changeset) do
    changeset = validate_required(changeset, [:name])

    with name when is_binary(name) <- get_change(changeset, :name),
         true <- reserved_for_others?(changeset, name) do
      add_error(changeset, :name, "has already been taken")
    else
      _ -> validate_format(changeset, :name, @name_format, message: @name_message)
    end
  end

  defp reserved_for_others?(changeset, name) do
    String.downcase(name) == @system_name and get_field(changeset, :kind) != :system
  end

  defp validate_kind_links(changeset) do
    kind = get_field(changeset, :kind)
    user_id = get_field(changeset, :user_id)
    owner_id = get_field(changeset, :owner_id)

    cond do
      kind == :agent and is_nil(owner_id) ->
        add_error(changeset, :owner_id, "is required for an agent")

      kind != :agent and not is_nil(owner_id) ->
        add_error(changeset, :owner_id, "is only allowed for an agent")

      kind != :human and not is_nil(user_id) ->
        add_error(changeset, :user_id, "is only allowed for a human")

      true ->
        changeset
    end
  end

  defp map_constraints(changeset) do
    changeset
    |> unique_constraint(:name,
      name: :actors_workspace_id_name_index,
      message: "has already been taken"
    )
    |> unique_constraint(:user_id,
      name: :actors_one_human_per_user_index,
      message: "already has a human identity in this workspace"
    )
    |> unique_constraint(:kind,
      name: :actors_one_system_per_workspace_index,
      message: "the workspace already has a system identity"
    )
    |> check_constraint(:name, name: :actors_name_format, message: @name_message)
    |> check_constraint(:name,
      name: :actors_reserved_name_check,
      message: "has already been taken"
    )
    |> check_constraint(:kind, name: :actors_kind_check, message: "is invalid")
    |> check_constraint(:owner_id,
      name: :actors_agent_owner_check,
      message: "is required for an agent and only allowed for an agent"
    )
    |> check_constraint(:user_id,
      name: :actors_user_only_human_check,
      message: "is only allowed for a human"
    )
  end
end
