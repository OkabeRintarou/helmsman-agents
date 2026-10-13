defmodule Helmsman.AgentDesigns.Draft do
  @moduledoc """
  The draft of a creation conversation (`add-agent-conversation` decisions
  3, 5, 7): `%{"agents" => [entry]}`, at most #{8} agents in the order they
  were added, each entry the fields of a new managed agent (string keys)
  and `updated_by` (`"ai"` or `"user"`).

  `put/4` adds or patches one agent by name (case-insensitive; a rename
  gives `previous_name`) and checks it as `Helmsman.Agents.create/2` would
  for the conversation's user (`Helmsman.Agents.validate_new/2`), plus the
  draft's own rules: no other agent of the draft has the name, at most
  #{8} agents, `access` only `owner_only` or `workspace`, and none of the
  fields that are secrets or decide what runs on the owner's machine
  (environment, extra MCP servers, CLI arguments, member list).

  Pending edits (decision 16) are `[%{"agent" => name, "fields" =>
  [field]} | %{"agent" => name, "removed" => true}]`; an agent the user
  added carries `"added" => true` until the helper is told.
  """

  import Ecto.Changeset

  alias Helmsman.Accounts.Scope
  alias Helmsman.Agents
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Repo

  @max_agents 8
  @types %{
    name: :string,
    provider: :string,
    description: :string,
    runtime_id: :integer,
    provider_account_id: :integer,
    model: :string,
    effort: :string,
    instructions: :string,
    capabilities: {:array, :string},
    access: :string,
    max_concurrency: :integer,
    timeout_minutes: :integer,
    idle_timeout_minutes: :integer
  }
  @fields Map.keys(@types)
  @field_names Enum.map(@fields, &Atom.to_string/1)
  @defaults %{
    description: "",
    runtime_id: nil,
    provider_account_id: nil,
    model: nil,
    effort: nil,
    capabilities: [],
    access: "owner_only",
    max_concurrency: 2,
    timeout_minutes: 120,
    idle_timeout_minutes: 20
  }
  @refused ~w(env extra_mcp_servers custom_args access_member_ids wake_on_requested)
  @accesses ~w(owner_only workspace)

  @type entry :: %{String.t() => term()}
  @type draft :: %{String.t() => [entry()]}
  @type edit :: %{String.t() => term()}

  @doc "The most agents a draft holds."
  @spec max_agents() :: pos_integer()
  def max_agents, do: @max_agents

  @doc "The fields of a draft agent, in a stable order."
  @spec fields() :: [String.t()]
  def fields,
    do:
      ~w(name provider description runtime_id provider_account_id model effort instructions capabilities access max_concurrency timeout_minutes idle_timeout_minutes)

  @doc "The defaults of the optional fields (string keys)."
  @spec defaults() :: map()
  def defaults, do: Map.new(@defaults, fn {k, v} -> {Atom.to_string(k), v} end)

  @doc "The agents of `draft`."
  @spec agents(map()) :: [entry()]
  def agents(%{"agents" => agents}) when is_list(agents), do: agents
  def agents(_draft), do: []

  @doc "The agent `name` of `draft` (case-insensitive), or nil."
  @spec find(map(), term()) :: entry() | nil
  def find(draft, name) when is_binary(name),
    do: Enum.find(agents(draft), &same_name?(&1["name"], name))

  def find(_draft, _name), do: nil

  defp same_name?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_name?(_a, _b), do: false

  @doc """
  Adds or patches the agent of `attrs` (string or atom keys) in `draft`,
  written by `by` (`"ai"` / `"user"`), for `user_scope` (the
  conversation's user in its workspace). A new agent needs `name`,
  `provider` and `instructions`; the other fields get the defaults of a
  managed agent. A patch keeps what is not given; `nil` restores the
  default.

  Returns `{:ok, draft, entry, edit}` (`edit`: the pending edit it makes,
  nil when nothing changed), `{:error, :draft_full}` or `{:error,
  changeset}` (schemaless; `errors` as `Helmsman.Agents.validate_new/2`,
  a `model` / `effort` error not supported by the runtime has the
  runtime's values in `supported`).
  """
  @spec put(map(), map(), Scope.t(), String.t()) ::
          {:ok, draft(), entry(), edit() | nil}
          | {:error, :draft_full}
          | {:error, Ecto.Changeset.t()}
  def put(draft, attrs, %Scope{} = user_scope, by) when by in ["ai", "user"] do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    previous = rename_from(attrs)
    existing = find(draft, previous || attrs["name"])
    given = Map.take(attrs, @field_names)

    # Without a rename the name only finds the agent: it keeps its own.
    given =
      if existing && is_nil(previous), do: Map.put(given, "name", existing["name"]), else: given

    cond do
      is_nil(existing) and previous ->
        {:error, error_changeset([{:previous_name, {"is not in the draft", []}}])}

      is_nil(existing) and length(agents(draft)) >= @max_agents ->
        {:error, :draft_full}

      true ->
        put_checked(draft, attrs, given, existing, user_scope, by)
    end
  end

  defp rename_from(%{"previous_name" => previous}) when is_binary(previous) and previous != "",
    do: previous

  defp rename_from(_attrs), do: nil

  defp put_checked(draft, attrs, given, existing, user_scope, by) do
    base = if existing, do: atomize(existing), else: @defaults
    keys = given |> Map.keys() |> Enum.map(&String.to_existing_atom/1)

    cs =
      {base, @types}
      |> cast(given, keys, empty_values: [])
      |> restore_defaults(keys)
      |> blank_to_nil([:model, :effort])
      |> validate_required([:name, :provider, :instructions])
      |> refuse_fields(attrs)
      |> validate_inclusion(:access, @accesses, message: "must be owner_only or workspace")
      |> unique_in_draft(draft, existing)

    entry = apply_changes(cs)

    errors =
      if cs.valid? or only_draft_errors?(cs),
        do: cs.errors ++ validate_new(user_scope, entry),
        else: cs.errors

    if errors == [] do
      stored = stringify(entry) |> Map.put("updated_by", by)
      {:ok, replace(draft, existing, stored), stored, edit(existing, stored, keys)}
    else
      {:error, error_changeset(supported(errors, entry))}
    end
  end

  defp atomize(entry),
    do: Map.new(@fields, fn field -> {field, Map.get(entry, Atom.to_string(field))} end)

  defp stringify(entry),
    do: Map.new(@fields, fn field -> {Atom.to_string(field), Map.get(entry, field)} end)

  defp restore_defaults(cs, keys) do
    Enum.reduce(keys, cs, fn key, cs ->
      if Map.has_key?(cs.changes, key) and is_nil(get_change(cs, key)) and
           Map.has_key?(@defaults, key),
         do: put_change(cs, key, @defaults[key]),
         else: cs
    end)
  end

  defp blank_to_nil(cs, fields) do
    Enum.reduce(fields, cs, fn field, cs ->
      if get_field(cs, field) == "", do: put_change(cs, field, nil), else: cs
    end)
  end

  defp refuse_fields(cs, attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in @field_names or &1 == "previous_name"))
    |> Enum.sort()
    |> Enum.reduce(cs, fn key, cs ->
      error =
        if key in @refused,
          do: {String.to_existing_atom(key), {"cannot be set in a draft", []}},
          else: {:base, {"%{field} is not a draft field", [field: key]}}

      %{cs | errors: cs.errors ++ [error], valid?: false}
    end)
  end

  defp unique_in_draft(cs, draft, existing) do
    name = get_field(cs, :name)

    taken? =
      Enum.any?(agents(draft), fn entry ->
        entry != existing and same_name?(entry["name"], name)
      end)

    if taken?, do: add_error(cs, :name, "is already in the draft"), else: cs
  end

  # Type errors and missing fields make the entry meaningless to check
  # further; the draft's own errors (name in the draft, access, refused
  # fields) do not.
  defp only_draft_errors?(cs),
    do:
      Enum.all?(cs.errors, fn {_field, {_msg, opts}} ->
        opts[:validation] not in [:cast, :required]
      end)

  defp validate_new(user_scope, entry) do
    case Agents.validate_new(user_scope, create_attrs(entry)) do
      :ok -> []
      {:error, cs} -> cs.errors
    end
  end

  defp supported(errors, entry) do
    runtime = entry.runtime_id && Repo.get(Runtime, entry.runtime_id)

    Enum.map(errors, fn
      {field, {"is not supported by the runtime" = msg, opts}}
      when field in [:model, :effort] and not is_nil(runtime) ->
        values = if field == :model, do: runtime.models, else: runtime.efforts
        {field, {msg, Keyword.put(opts, :supported, values)}}

      error ->
        error
    end)
  end

  defp error_changeset(errors),
    do: %Ecto.Changeset{data: %{}, types: @types, valid?: false, errors: errors}

  defp replace(draft, nil, stored), do: %{"agents" => agents(draft) ++ [stored]}

  defp replace(draft, existing, stored),
    do: %{
      "agents" => Enum.map(agents(draft), &if(&1 == existing, do: stored, else: &1))
    }

  defp edit(nil, stored, keys) do
    fields = keys |> Enum.map(&Atom.to_string/1) |> Enum.reject(&(&1 == "name")) |> Enum.sort()
    %{"agent" => stored["name"], "fields" => fields, "added" => true}
  end

  defp edit(existing, stored, _keys) do
    case Enum.filter(fields(), &(Map.get(existing, &1) != Map.get(stored, &1))) do
      [] -> nil
      changed -> %{"agent" => stored["name"], "fields" => Enum.sort(changed)}
    end
  end

  @doc """
  Removes the agent `name` from `draft`: `{:ok, draft, entry}` or
  `{:error, :not_found}`.
  """
  @spec remove(map(), term()) :: {:ok, draft(), entry()} | {:error, :not_found}
  def remove(draft, name) do
    case find(draft, name) do
      nil -> {:error, :not_found}
      entry -> {:ok, %{"agents" => List.delete(agents(draft), entry)}, entry}
    end
  end

  @doc """
  Adds the edit of a `put/4` (renamed from `previous_name` when not nil)
  to the pending edits: one record per agent, fields united, a rename
  moving the record to the new name with `name` among its fields.
  """
  @spec merge_edit([edit()], edit() | nil, String.t() | nil) :: [edit()]
  def merge_edit(pending, nil, _previous), do: pending

  def merge_edit(pending, %{"agent" => name} = edit, previous) do
    {pending, edit} = rename(pending, edit, previous)

    case Enum.find(pending, &same_name?(&1["agent"], name)) do
      nil ->
        pending ++ [edit]

      %{"removed" => true} = old ->
        Enum.map(pending, &if(&1 == old, do: edit, else: &1))

      old ->
        fields = Enum.sort(Enum.uniq(old["fields"] ++ edit["fields"]))
        merged = %{old | "fields" => fields}

        merged =
          if old["added"] || edit["added"], do: Map.put(merged, "added", true), else: merged

        Enum.map(pending, &if(&1 == old, do: merged, else: &1))
    end
  end

  defp rename(pending, edit, previous) when is_binary(previous) do
    if same_name?(previous, edit["agent"]) do
      {pending, edit}
    else
      edit = %{edit | "fields" => Enum.sort(Enum.uniq(["name" | edit["fields"]]))}

      case Enum.find(pending, &same_name?(&1["agent"], previous)) do
        nil -> {pending, edit}
        old -> {List.delete(pending, old), %{merge_old(old, edit) | "agent" => edit["agent"]}}
      end
    end
  end

  defp rename(pending, edit, _previous), do: {pending, edit}

  defp merge_old(old, edit) do
    merged = %{edit | "fields" => Enum.sort(Enum.uniq((old["fields"] || []) ++ edit["fields"]))}
    if old["added"], do: Map.put(merged, "added", true), else: merged
  end

  @doc """
  Records the removal of `name` in the pending edits; an agent the user
  added and the helper never saw just disappears from them.
  """
  @spec merge_removal([edit()], String.t()) :: [edit()]
  def merge_removal(pending, name) do
    case Enum.find(pending, &same_name?(&1["agent"], name)) do
      %{"added" => true} = old ->
        List.delete(pending, old)

      nil ->
        pending ++ [%{"agent" => name, "removed" => true}]

      old ->
        Enum.map(pending, &if(&1 == old, do: %{"agent" => name, "removed" => true}, else: &1))
    end
  end

  @doc "The attributes `Helmsman.Agents.create/2` takes for `entry`."
  @spec create_attrs(map()) :: map()
  def create_attrs(entry) do
    Map.new(@fields, fn field ->
      {field, Map.get(entry, field, Map.get(entry, Atom.to_string(field)))}
    end)
  end
end
