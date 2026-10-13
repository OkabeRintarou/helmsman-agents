defmodule Helmsman.Autopilots.Form do
  @moduledoc false
  # Normalizing and validating the attributes of an autopilot
  # (`add-autopilots` decision 1): every field error at once, as a
  # schemaless changeset.

  import Ecto.Query

  alias Ecto.Changeset
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Autopilots.{Autopilot, Schedule, Target}
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Squads.Squad

  @fields ~w(name agent project mode title_template instructions create_tasks cron timezone overlap)
  @name_chars 80
  @title_chars 200
  @instructions_bytes 16_384

  @types %{
    name: :string,
    agent: :string,
    project: :string,
    mode: :string,
    title_template: :string,
    instructions: :string,
    create_tasks: :boolean,
    cron: :string,
    timezone: :string,
    overlap: :string,
    enabled: :boolean,
    note: :string,
    lock_version: :integer
  }

  @doc "String keys, only the known ones; `given` lists them."
  @spec normalize(map()) :: map()
  def normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    given = attrs |> Map.take(@fields) |> Map.keys() |> MapSet.new()

    %{
      given: given,
      values: Map.take(attrs, @fields),
      enabled: Map.get(attrs, "enabled", true),
      lock_version: attrs["lock_version"]
    }
  end

  @doc """
  Guesses the target identity named in `attrs` (or the current one),
  then locks it `FOR SHARE` with its profile or squad row (decision 2:
  after the autopilot row). Returns the target, or nil.
  """
  @spec lock_target(pos_integer(), map(), Autopilot.t() | nil) :: Target.t() | nil
  def lock_target(ws, attrs, current) do
    id =
      case Map.fetch(attrs.values, "agent") do
        {:ok, name} when is_binary(name) ->
          Repo.one(
            from(a in Actor,
              where: a.workspace_id == ^ws and a.name == ^String.trim(name),
              select: a.id
            )
          )

        {:ok, _other} ->
          nil

        :error ->
          current && current.agent_id
      end

    with id when is_integer(id) <- id,
         %Actor{} = actor <- Repo.one(from(a in Actor, where: a.id == ^id, lock: "FOR SHARE")) do
      case actor.kind do
        :agent ->
          Repo.one(from(p in AgentProfile, where: p.actor_id == ^id, lock: "FOR SHARE"))

        :squad ->
          Repo.one(from(s in Squad, where: s.actor_id == ^id, lock: "FOR SHARE"))

        _other ->
          nil
      end

      Target.of_actor(actor)
    else
      _ -> nil
    end
  end

  @doc """
  The project named in `attrs` (or the current one): `{:ok, project |
  nil}`, or `:error` for an unknown key.
  """
  @spec project(pos_integer(), map(), Autopilot.t() | nil) :: {:ok, Project.t() | nil} | :error
  def project(ws, attrs, current) do
    case Map.fetch(attrs.values, "project") do
      {:ok, key} when key in [nil, ""] ->
        {:ok, nil}

      {:ok, key} when is_binary(key) ->
        by_key(ws, key)

      {:ok, _other} ->
        :error

      :error ->
        {:ok, current && current.project_id && Repo.get(Project, current.project_id)}
    end
  end

  defp by_key(ws, key) do
    query =
      from(p in Project,
        where:
          p.workspace_id == ^ws and
            fragment("upper(?)", p.key) == ^String.upcase(String.trim(key))
      )

    case Repo.one(query) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  @doc """
  Validates the merged values (the given ones over `current`'s) and
  returns the columns to write, or every field error.

  `ctx`: `target` (`lock_target/3`), `project` (`project/3`),
  `name_taken` and `now`.
  """
  @spec validate(map(), Autopilot.t() | nil, map()) :: {:ok, map()} | {:error, Changeset.t()}
  def validate(attrs, current, ctx) do
    v = merged(attrs, current)
    creating? = is_nil(current)

    {mode_errors, mode} = mode(v["mode"])
    {overlap_errors, overlap} = overlap(v["overlap"])
    timezone = blank_default(v["timezone"], "UTC")
    cron = blank_default(v["cron"], nil)
    changed_schedule? = creating? or given?(attrs, "cron") or given?(attrs, "timezone")

    errors =
      name_errors(v["name"], ctx.name_taken) ++
        mode_errors ++
        target_errors(ctx.target, mode, attrs, creating?) ++
        project_errors(ctx.project, mode, creating? or given?(attrs, "project")) ++
        title_errors(v["title_template"], mode) ++
        instructions_errors(v["instructions"]) ++
        bool_errors(v["create_tasks"]) ++
        overlap_errors ++
        schedule_errors(cron, timezone, ctx.now, changed_schedule?)

    case errors do
      [] ->
        {:ok,
         %{
           name: String.trim(v["name"]),
           agent_id: ctx.target.actor.id,
           project_id: project_id(ctx.project),
           mode: mode,
           title_template: blank_default(v["title_template"], nil),
           instructions: v["instructions"],
           create_tasks: v["create_tasks"] == true,
           cron: cron && Enum.join(String.split(cron), " "),
           timezone: timezone,
           overlap: overlap
         }}

      errors ->
        {:error, error_changeset(errors)}
    end
  end

  defp merged(attrs, nil), do: attrs.values

  defp merged(attrs, %Autopilot{} = a) do
    Map.merge(
      %{
        "name" => a.name,
        "mode" => Atom.to_string(a.mode),
        "title_template" => a.title_template,
        "instructions" => a.instructions,
        "create_tasks" => a.create_tasks,
        "cron" => a.cron,
        "timezone" => a.timezone,
        "overlap" => Atom.to_string(a.overlap)
      },
      attrs.values
    )
  end

  defp given?(attrs, key), do: MapSet.member?(attrs.given, key)

  defp blank_default(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: value
  end

  defp blank_default(nil, default), do: default
  defp blank_default(value, _default), do: value

  defp name_errors(name, taken?) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        [{:name, "can't be blank"}]

      String.length(trimmed) > @name_chars ->
        [{:name, "should be at most #{@name_chars} characters"}]

      taken? ->
        [{:name, "has already been taken"}]

      true ->
        []
    end
  end

  defp name_errors(nil, _taken?), do: [{:name, "can't be blank"}]
  defp name_errors(_name, _taken?), do: [{:name, "is invalid"}]

  defp mode(mode) when mode in ["create_task", :create_task], do: {[], :create_task}
  defp mode(mode) when mode in ["run_only", :run_only], do: {[], :run_only}
  defp mode(nil), do: {[{:mode, "can't be blank"}], nil}
  defp mode(_mode), do: {[{:mode, "is invalid"}], nil}

  defp overlap(value) when value in [nil, "", "skip", :skip], do: {[], :skip}
  defp overlap(value) when value in ["queue", :queue], do: {[], :queue}
  defp overlap(_value), do: {[{:overlap, "is invalid"}], nil}

  # The current target may stay even when it is now archived; a new one
  # (or any on creation) must be valid for the mode.
  defp target_errors(nil, _mode, attrs, creating?) do
    if creating? or given?(attrs, "agent"),
      do: [
        {:agent,
         if(attrs.values["agent"] in [nil, ""], do: "can't be blank", else: "does not exist")}
      ],
      else: [{:agent, "does not exist"}]
  end

  defp target_errors(%{actor: %Actor{kind: :squad}}, :run_only, _attrs, _creating?),
    do: [{:agent, "must be a managed agent"}]

  defp target_errors(_target, _mode, attrs, false) when not is_map_key(attrs.values, "agent"),
    do: []

  defp target_errors(target, mode, _attrs, _creating?) do
    case Target.field_error(target, mode || :create_task) do
      nil -> []
      message -> [{:agent, message}]
    end
  end

  defp project_errors(:error, _mode, _new?), do: [{:project, "does not exist"}]
  defp project_errors({:ok, nil}, :create_task, _new?), do: [{:project, "can't be blank"}]

  defp project_errors({:ok, %Project{archived_at: archived}}, _mode, true)
       when not is_nil(archived),
       do: [{:project, "is archived"}]

  defp project_errors(_project, _mode, _new?), do: []

  defp project_id({:ok, %Project{id: id}}), do: id
  defp project_id(_project), do: nil

  # Saved as nil when blank (`blank_default/2`): create_task needs one.
  defp title_errors(nil, :create_task), do: [{:title_template, "can't be blank"}]

  defp title_errors(title, mode) when is_binary(title) do
    cond do
      String.trim(title) == "" and mode == :create_task ->
        [{:title_template, "can't be blank"}]

      String.length(title) > @title_chars ->
        [{:title_template, "should be at most #{@title_chars} characters"}]

      true ->
        []
    end
  end

  defp title_errors(nil, _mode), do: []
  defp title_errors(_title, _mode), do: [{:title_template, "is invalid"}]

  defp instructions_errors(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        [{:instructions, "can't be blank"}]

      not String.valid?(text) ->
        [{:instructions, "is invalid"}]

      byte_size(text) > @instructions_bytes ->
        [{:instructions, "should be at most #{@instructions_bytes} bytes"}]

      true ->
        []
    end
  end

  defp instructions_errors(nil), do: [{:instructions, "can't be blank"}]
  defp instructions_errors(_text), do: [{:instructions, "is invalid"}]

  defp bool_errors(value) when is_boolean(value) or is_nil(value), do: []
  defp bool_errors(_value), do: [{:create_tasks, "is invalid"}]

  defp schedule_errors(_cron, timezone, _now, false) do
    if Schedule.valid_timezone?(timezone), do: [], else: [{:timezone, "is not a valid time zone"}]
  end

  defp schedule_errors(nil, timezone, _now, true) do
    if Schedule.valid_timezone?(timezone), do: [], else: [{:timezone, "is not a valid time zone"}]
  end

  defp schedule_errors(cron, timezone, now, true) when is_binary(cron) do
    case Schedule.validate(cron, timezone, now) do
      {:ok, _expr} -> []
      {:error, errors} -> errors
    end
  end

  defp schedule_errors(_cron, _timezone, _now, true), do: [{:cron, "is invalid"}]

  @doc "A schemaless changeset with `errors` (`[{field, message}]`)."
  @spec error_changeset([{atom(), String.t()}]) :: Changeset.t()
  def error_changeset(errors) do
    errors
    |> Enum.reduce(Changeset.change({%{}, @types}), fn {field, message}, cs ->
      Changeset.add_error(cs, field, message)
    end)
    |> Map.put(:action, :validate)
  end
end
