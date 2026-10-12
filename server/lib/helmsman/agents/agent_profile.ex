defmodule Helmsman.Agents.AgentProfile do
  @moduledoc "Managed agent execution configuration. Secrets stay inside the domain."
  use Ecto.Schema
  import Ecto.Changeset
  alias Helmsman.Repo
  alias Helmsman.Workspaces.Membership

  @type t :: %__MODULE__{}
  @fields ~w(provider runtime_id model effort instructions description access access_member_ids capabilities max_concurrency timeout_minutes idle_timeout_minutes custom_args env extra_mcp_servers)a
  @derive {Inspect, except: [:env, :extra_mcp_servers]}
  schema "agent_profiles" do
    belongs_to :workspace, Helmsman.Workspaces.Workspace
    belongs_to :actor, Helmsman.Actors.Actor
    belongs_to :runtime, Helmsman.Daemons.Runtime
    field :provider, :string
    field :model, :string
    field :effort, :string
    field :instructions, :string, default: ""
    field :description, :string, default: ""
    field :access, :string, default: "owner_only"
    field :access_member_ids, {:array, :id}, default: []
    field :capabilities, {:array, :string}, default: []
    field :max_concurrency, :integer, default: 2
    field :timeout_minutes, :integer, default: 120
    field :idle_timeout_minutes, :integer, default: 20
    field :custom_args, {:array, :string}, default: []
    field :env, Helmsman.Encrypted.Map, redact: true
    field :extra_mcp_servers, Helmsman.Encrypted.Map, redact: true
    field :archived_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs, actor) do
    profile
    |> cast(attrs, @fields, empty_values: [])
    |> normalize_optional()
    |> patch_env(profile, attrs)
    |> validate_non_null()
    |> validate_required([
      :provider,
      :access,
      :max_concurrency,
      :timeout_minutes,
      :idle_timeout_minutes
    ])
    |> validate_inclusion(:provider, Enum.map(HelmsmanProtocol.providers(), &to_string/1))
    |> validate_inclusion(:access, ~w(owner_only members workspace))
    |> validate_length(:description, max: 1000)
    |> validate_length(:instructions, max: 65_536, count: :bytes)
    |> validate_length(:model, min: 1, max: 128, count: :bytes)
    |> validate_length(:effort, min: 1, max: 128, count: :bytes)
    |> validate_number(:max_concurrency, greater_than_or_equal_to: 1, less_than_or_equal_to: 16)
    |> validate_number(:timeout_minutes, greater_than_or_equal_to: 1, less_than_or_equal_to: 1200)
    |> validate_number(:idle_timeout_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 240
    )
    |> validate_limits()
    |> validate_members(actor.workspace_id)
    |> validate_binding(actor)
    |> unique_constraint(:actor_id)
    |> foreign_key_constraint(:runtime_id, name: :agent_profiles_runtime_workspace_fkey)
    |> foreign_key_constraint(:actor_id, name: :agent_profiles_actor_workspace_fkey)
  end

  defp validate_non_null(cs) do
    Enum.reduce([:instructions, :description, :custom_args, :capabilities], cs, fn field, cs ->
      if is_nil(get_field(cs, field)), do: add_error(cs, field, "must not be null"), else: cs
    end)
  end

  defp normalize_optional(cs) do
    Enum.reduce([:model, :effort], cs, fn field, cs ->
      if get_field(cs, field) == "", do: put_change(cs, field, nil), else: cs
    end)
  end

  defp patch_env(cs, profile, attrs) do
    case Map.fetch(attrs, :env) do
      :error -> patch_env_string(cs, profile, attrs)
      {:ok, patch} -> merge_env(cs, profile.env, patch)
    end
  end

  defp patch_env_string(cs, profile, attrs) do
    case Map.fetch(attrs, "env") do
      :error -> cs
      {:ok, patch} -> merge_env(cs, profile.env, patch)
    end
  end

  defp merge_env(cs, old, patch) when is_map(patch) do
    merged =
      Enum.reduce(patch, old || %{}, fn
        {key, nil}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    put_change(cs, :env, merged)
  end

  defp merge_env(cs, _old, _patch), do: cs

  defp validate_limits(cs) do
    cs =
      if is_integer(get_field(cs, :idle_timeout_minutes)) and
           is_integer(get_field(cs, :timeout_minutes)) and
           get_field(cs, :idle_timeout_minutes) > get_field(cs, :timeout_minutes),
         do: add_error(cs, :idle_timeout_minutes, "must not exceed timeout_minutes"),
         else: cs

    cs = validate_subset(cs, :capabilities, ["create_tasks"])

    cs =
      validate_change(cs, :custom_args, fn :custom_args, values ->
        if length(values) <= 64 and Enum.all?(values, &(byte_size(&1) in 1..4096)),
          do: [],
          else: [custom_args: "must contain at most 64 strings of 1-4096 bytes"]
      end)

    cs |> validate_env() |> validate_mcp()
  end

  defp validate_env(cs) do
    case get_field(cs, :env) do
      nil ->
        cs

      env when is_map(env) ->
        cs =
          if map_size(env) > 64,
            do: add_error(cs, :env, "must contain at most 64 variables"),
            else: cs

        Enum.reduce(env, cs, &validate_variable/2)

      _ ->
        add_error(cs, :env, "must be an object")
    end
  end

  defp validate_variable({name, value}, cs) do
    cond do
      not is_binary(name) or not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]{0,127}$/, name) ->
        add_error(cs, :env, "invalid variable name")

      String.starts_with?(String.upcase(name), "HELMSMAN_") ->
        add_error(cs, :env, "%{name} is reserved", name: name)

      not is_binary(value) ->
        add_error(cs, :env, "value of %{name} must be a string", name: name)

      byte_size(value) > 8192 ->
        add_error(cs, :env, "value of %{name} is longer than 8 KB", name: name)

      true ->
        cs
    end
  end

  defp validate_mcp(cs) do
    case get_field(cs, :extra_mcp_servers) do
      nil ->
        cs

      servers when is_map(servers) ->
        cond do
          Enum.any?(Map.keys(servers), &(is_binary(&1) and String.downcase(&1) == "helmsman")) ->
            add_error(cs, :extra_mcp_servers, "helmsman is reserved")

          not json_within_limit?(servers) ->
            add_error(cs, :extra_mcp_servers, "must be a JSON object of at most 32 KB")

          true ->
            cs
        end

      _ ->
        add_error(cs, :extra_mcp_servers, "must be an object")
    end
  end

  defp json_within_limit?(servers) do
    case Jason.encode(servers) do
      {:ok, json} -> byte_size(json) <= 32_768
      _ -> false
    end
  end

  defp validate_members(cs, workspace_id) do
    import Ecto.Query

    if get_field(cs, :access) == "members" do
      ids = Enum.uniq(get_field(cs, :access_member_ids) || [])

      allowed =
        Repo.all(
          from m in Membership,
            where:
              m.workspace_id == ^workspace_id and m.user_id in ^ids and
                m.role in [:owner, :admin, :member],
            select: m.user_id
        )

      cs = put_change(cs, :access_member_ids, ids)

      if length(ids) <= 100 and Enum.all?(ids, &(&1 in allowed)),
        do: cs,
        else: add_error(cs, :access_member_ids, "must contain at most 100 current members")
    else
      put_change(cs, :access_member_ids, [])
    end
  end

  defp validate_binding(cs, actor) do
    import Ecto.Query

    case get_field(cs, :runtime_id) do
      nil ->
        cs

      id ->
        runtime =
          Repo.one(
            from r in Helmsman.Daemons.Runtime,
              join: d in Helmsman.Daemons.Daemon,
              on: d.id == r.daemon_id,
              where:
                r.id == ^id and r.workspace_id == ^actor.workspace_id and
                  d.user_id == ^actor.owner_id,
              where: is_nil(r.disabled_at),
              lock: fragment("FOR SHARE OF ?", r),
              select: r
          )

        validate_runtime(cs, runtime)
    end
  end

  defp validate_runtime(cs, nil), do: invalid_runtime(cs)

  defp validate_runtime(cs, runtime) do
    if runtime.provider == get_field(cs, :provider) do
      cs |> validate_option(:model, runtime.models) |> validate_option(:effort, runtime.efforts)
    else
      invalid_runtime(cs)
    end
  end

  defp invalid_runtime(cs),
    do:
      add_error(
        cs,
        :runtime_id,
        "must be an enabled runtime owned by this agent owner with the same provider"
      )

  defp validate_option(cs, field, options) do
    value = get_field(cs, field)

    if is_nil(value) or options == [] or value in options,
      do: cs,
      else: add_error(cs, field, "is not supported by the runtime")
  end

  def scrub(%Ecto.Changeset{} = cs) do
    sensitive = [:env, :extra_mcp_servers, "env", "extra_mcp_servers"]

    data =
      case cs.data do
        %__MODULE__{} = data -> %{data | env: nil, extra_mcp_servers: nil}
        data -> data
      end

    %{
      cs
      | data: data,
        changes: Map.drop(cs.changes, sensitive),
        params: cs.params && Map.drop(cs.params, sensitive)
    }
  end
end
