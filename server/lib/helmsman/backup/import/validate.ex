defmodule Helmsman.Backup.Import.Validate do
  @moduledoc "Validates an entire portable snapshot before any database writes."
  alias Helmsman.Actors.Actor
  alias Helmsman.Backup.Format
  alias Helmsman.Backup.Import.SpecValidate
  alias Helmsman.Tasks.Evidence
  alias Helmsman.Tasks.Task

  @types %{
    "actors" => %{
      name: :name,
      kind: {:enum, ~w(human agent squad system)},
      disabled: :boolean,
      owner: {:optional, :name}
    },
    "projects" => %{
      key: :key,
      name: {:text, 80},
      description: {:bytes, 65_536},
      task_seq: :nonnegative,
      spec_finalize: {:enum, ~w(approval leader)},
      archived_at: {:optional, :time},
      created_at: :time,
      updated_at: :time
    },
    "tasks" => %{
      id: :task_id,
      project: :key,
      seq: :positive,
      title: {:text, 200},
      description: {:bytes, 65_536},
      status: {:enum, Enum.map(Task.statuses(), &to_string/1)},
      priority: {:enum, Enum.map(Task.priorities(), &to_string/1)},
      kind: {:enum, ~w(task epic)},
      labels: :labels,
      epic: {:optional, :task_id},
      created_by: :name,
      assignee: {:optional, :name},
      created_at: :time,
      updated_at: :time
    },
    "task_events" => %{
      task: :task_id,
      n: :positive,
      from: {:optional, {:enum, Enum.map(Task.statuses(), &to_string/1)}},
      to: {:enum, Enum.map(Task.statuses(), &to_string/1)},
      actor: :name,
      comment: {:optional, {:characters, 10_000}},
      commits: :commits,
      tests: {:optional, :tests},
      auto: :boolean,
      auto_reason: {:optional, {:enum, ~w(ci_failed merge_conflict)}},
      feedback: {:optional, :feedback_id},
      verified_sha: {:optional, :sha},
      assignee_side: {:array, :name},
      at: :time
    },
    "feedback" => %{
      id: :feedback_id,
      thread: :positive,
      author: :name,
      kind: {:enum, ~w(comment review question answer)},
      content: {:content, 65_536},
      status: {:enum, ~w(active superseded)},
      reply_to: {:optional, :feedback_id},
      reply_root: {:optional, :feedback_id},
      supersedes: {:optional, :feedback_id},
      superseded_by: {:optional, :feedback_id},
      mentions: {:array, :name},
      fallback: :boolean,
      at: :time
    },
    "links" => %{
      from: :task_id,
      to: :task_id,
      type: {:enum, ~w(depends_on replaces)},
      actor: :name,
      at: :time
    },
    "saved_filters" => %{name: {:text, 80}, bql: {:text, 2000}, owner: :name}
  }

  def validate(data, rename \\ %{})

  def validate(%{"format" => "helmsman-export", "version" => version} = data, rename)
      when version in [1, 2] do
    data = legacy_defaults(data)

    data =
      Map.update(data, "feedback", nil, fn
        rows when is_list(rows) ->
          Enum.map(rows, fn
            row when is_map(row) ->
              row |> Map.put_new("reply_to", nil) |> Map.put_new("reply_root", nil)

            row ->
              row
          end)

        other ->
          other
      end)

    basic = Enum.take(fields(data) ++ records(data), 100)

    errors =
      if basic == [],
        do:
          references(data) ++
            histories(data) ++
            rename_errors(data, rename) ++ SpecValidate.validate(data),
        else: basic

    case Enum.take(errors, 100) do
      [] -> {:ok, data}
      errors -> {:error, {:invalid_import, errors}}
    end
  end

  def validate(_, _), do: {:error, :unsupported_format}

  defp legacy_defaults(%{"version" => 1} = data) do
    data = Enum.reduce(Format.spec_collections(), data, &Map.put(&2, &1, []))

    if is_list(data["projects"]),
      do:
        Map.update!(
          data,
          "projects",
          &Enum.map(&1, fn r -> project_defaults(r) end)
        ),
      else: data
  end

  defp legacy_defaults(data), do: data
  defp project_defaults(row) when is_map(row), do: Map.put_new(row, "spec_finalize", "approval")
  defp project_defaults(row), do: row

  defp fields(data) do
    Enum.flat_map(Format.collections(data["version"]), fn name ->
      if is_list(data[name]), do: [], else: [error(name, "must be an array")]
    end) ++
      check(data["exported_at"], :time, "exported_at") ++
      if(is_map(data["source"]) and is_map(data["workspace"]),
        do: [],
        else: [error("$", "source and workspace must be objects")]
      )
  end

  defp rows(data, name) do
    case data[name] do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp indexed(data, name),
    do: rows(data, name) |> Enum.with_index() |> Enum.filter(fn {r, _} -> is_map(r) end)

  defp records(data) do
    Enum.flat_map(@types, fn {name, types} ->
      indexed_rows = rows(data, name) |> Enum.with_index()
      Enum.flat_map(indexed_rows, &record_fields(&1, name, types)) ++ duplicates(data, name)
    end)
  end

  defp record_fields({record, index}, name, types) when is_map(record) do
    Enum.flat_map(types, fn {field, type} ->
      check(record[to_string(field)], type, "#{name}[#{index}].#{field}")
    end)
  end

  defp record_fields({_record, index}, name, _types),
    do: [error("#{name}[#{index}]", "must be an object")]

  defp duplicates(data, name) do
    indexed(data, name)
    |> Enum.reduce({MapSet.new(), []}, &duplicate(&1, &2, name))
    |> elem(1)
    |> Enum.reverse()
  end

  defp duplicate({row, index}, {seen, errors}, name) do
    key = duplicate_key(name, row)

    errors =
      if MapSet.member?(seen, key),
        do: [error("#{name}[#{index}]", "duplicate record") | errors],
        else: errors

    {MapSet.put(seen, key), errors}
  end

  defp duplicate_key("actors", %{"name" => name}) when is_binary(name), do: String.downcase(name)
  defp duplicate_key("actors", row), do: row["name"]
  defp duplicate_key("projects", row), do: row["key"]
  defp duplicate_key("tasks", row), do: row["id"]
  defp duplicate_key("task_events", row), do: {row["task"], row["n"]}
  defp duplicate_key("feedback", row), do: row["id"]
  defp duplicate_key("links", row), do: {row["from"], row["to"], row["type"]}
  defp duplicate_key("saved_filters", row), do: {row["owner"], row["name"]}

  def check(value, type, path),
    do: if(valid?(value, type), do: [], else: [error(path, "invalid value for #{inspect(type)}")])

  defp valid?(nil, {:optional, _}), do: true
  defp valid?(v, {:optional, type}), do: valid?(v, type)
  defp valid?(v, {:enum, values}), do: v in values
  defp valid?(v, :boolean), do: is_boolean(v)
  defp valid?(v, :positive), do: is_integer(v) and v > 0 and v <= 2_147_483_647
  defp valid?(v, :nonnegative), do: is_integer(v) and v >= 0 and v <= 2_147_483_647
  defp valid?(v, :name), do: is_binary(v) and Actor.valid_name?(v)
  defp valid?(v, :key), do: is_binary(v) and Regex.match?(~r/^[A-Z][A-Z0-9]{1,9}$/, v)

  defp valid?(v, :task_id),
    do: is_binary(v) and Regex.match?(~r/^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]*$/, v)

  defp valid?(v, :feedback_id),
    do:
      is_binary(v) and Regex.match?(~r/^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]*#[1-9][0-9]*$/, v) and
        valid?(elem(feedback_parts(v), 1), :positive)

  defp valid?(v, :time),
    do:
      is_binary(v) and match?({:ok, _, 0}, DateTime.from_iso8601(v)) and String.ends_with?(v, "Z")

  defp valid?(v, {:text, max}),
    do: is_binary(v) and String.trim(v) != "" and length(String.codepoints(v)) <= max

  defp valid?(v, {:characters, max}), do: is_binary(v) and length(String.codepoints(v)) <= max
  defp valid?(v, {:bytes, max}), do: is_binary(v) and byte_size(v) <= max
  defp valid?(v, {:content, max}), do: valid?(v, {:bytes, max}) and String.trim(v) != ""
  defp valid?(v, {:array, type}), do: is_list(v) and Enum.all?(v, &valid?(&1, type))

  defp valid?(v, :labels),
    do: is_list(v) and length(v) <= 20 and Enum.all?(v, &valid?(&1, {:text, 32}))

  defp valid?(v, :sha), do: is_binary(v) and Regex.match?(~r/^[a-f0-9]{40}$/, v)

  defp valid?(v, :commits),
    do: is_list(v) and match?({:ok, _}, Evidence.normalize(%{commits: v}))

  defp valid?(v, :tests),
    do:
      is_map(v) and valid?(v["command"], {:characters, 2000}) and is_boolean(v["passed"]) and
        valid?(v["summary"], {:characters, 2000})

  defp references(data) do
    actors = Map.new(indexed(data, "actors"), fn {r, _} -> {r["name"], r} end)
    projects = Map.new(indexed(data, "projects"), fn {r, _} -> {r["key"], r} end)
    tasks = Map.new(indexed(data, "tasks"), fn {r, _} -> {r["id"], r} end)
    feedback = Map.new(indexed(data, "feedback"), fn {r, _} -> {r["id"], r} end)

    targets = %{actors: actors, projects: projects, tasks: tasks, feedback: feedback}

    Enum.flat_map(@types, fn {name, _} ->
      Enum.flat_map(indexed(data, name), &record_references(&1, name, targets))
    end)
  end

  defp record_references({row, index}, name, targets) do
    path = "#{name}[#{index}]"

    errors =
      reference_fields(name)
      |> Enum.flat_map(fn {field, target} ->
        ref(row[field], targets[target], "#{path}.#{field}")
      end)

    errors =
      errors ++
        Enum.flat_map(
          array_fields(name),
          &array_references(row[&1], targets.actors, "#{path}.#{&1}")
        )

    errors ++ specific(name, row, path, targets.projects, targets.tasks, targets.feedback)
  end

  defp array_references(values, actors, path) when is_list(values),
    do: Enum.flat_map(values, &ref(&1, actors, path))

  defp array_references(_, _, _), do: []
  defp array_fields("feedback"), do: ["mentions"]
  defp array_fields("task_events"), do: ["assignee_side"]
  defp array_fields(_), do: []
  defp reference_fields("actors"), do: [{"owner", :actors}]
  defp reference_fields("projects"), do: []

  defp reference_fields("tasks"),
    do: [{"project", :projects}, {"epic", :tasks}, {"created_by", :actors}, {"assignee", :actors}]

  defp reference_fields("task_events"),
    do: [{"task", :tasks}, {"actor", :actors}, {"feedback", :feedback}]

  defp reference_fields("feedback"),
    do: [
      {"author", :actors},
      {"supersedes", :feedback},
      {"superseded_by", :feedback},
      {"reply_to", :feedback},
      {"reply_root", :feedback}
    ]

  defp reference_fields("links"), do: [{"from", :tasks}, {"to", :tasks}, {"actor", :actors}]
  defp reference_fields("saved_filters"), do: [{"owner", :actors}]

  defp ref(nil, _, _), do: []

  defp ref(value, target, path),
    do: if(Map.has_key?(target, value), do: [], else: [error(path, "unresolved reference")])

  defp specific("actors", r, path, _, _, _) do
    if r["kind"] == "system" != (r["name"] == "helmsman"),
      do: [error(path, "only helmsman may be system")],
      else: []
  end

  defp specific("tasks", r, path, projects, tasks, _) do
    errors =
      if r["id"] == "#{r["project"]}-#{r["seq"]}",
        do: [],
        else: [error("#{path}.id", "must match project and seq")]

    errors =
      if is_map(projects[r["project"]]) and is_integer(r["seq"]) and
           is_integer(projects[r["project"]]["task_seq"]) and
           projects[r["project"]]["task_seq"] < r["seq"],
         do: [error("#{path}.seq", "exceeds project task_seq") | errors],
         else: errors

    if r["epic"] && (r["kind"] == "epic" or get_in(tasks, [r["epic"], "kind"]) != "epic"),
      do: [error("#{path}.epic", "must reference an Epic; Epic cannot have an Epic") | errors],
      else: errors
  end

  defp specific("feedback", r, path, _, tasks, feedback) do
    {task, _seq} = feedback_parts(r["id"])
    errors = ref(task, tasks, "#{path}.id")

    errors =
      Enum.reduce(
        [{"supersedes", "superseded_by"}, {"superseded_by", "supersedes"}],
        errors,
        fn {field, reverse}, errors ->
          target = feedback[r[field]]

          if r[field] &&
               (not is_map(target) or target[reverse] != r["id"] or
                  elem(feedback_parts(r[field]), 0) != task),
             do: [
               error("#{path}.#{field}", "revision references must be reciprocal within one task")
               | errors
             ],
             else: errors
        end
      )

    errors =
      if r["status"] == "superseded" != not is_nil(r["superseded_by"]),
        do: [error("#{path}.status", "must agree with superseded_by") | errors],
        else: errors

    errors = reply_errors(r, path, feedback) ++ errors
    thread = r["thread"]

    case root(r, feedback, %{}) do
      {:ok, ^thread} -> errors
      _ -> [error("#{path}.thread", "must be the revision chain root sequence") | errors]
    end
  end

  defp specific("links", r, path, _, _, _) do
    if r["from"] == r["to"], do: [error(path, "link endpoints must differ")], else: []
  end

  defp specific(_, _, _, _, _, _), do: []

  defp reply_errors(r, path, feedback) do
    {task, seq} = feedback_parts(r["id"])
    target = feedback[r["reply_to"]]
    root = feedback[r["reply_root"]]
    previous = feedback[r["supersedes"]]

    valid = valid_reply?(r, target, root, task, seq)

    preserved =
      not is_map(previous) or
        {r["reply_to"], r["reply_root"]} == {previous["reply_to"], previous["reply_root"]}

    if valid and preserved,
      do: [],
      else: [
        error(
          "#{path}.reply_to",
          "reply must reference an earlier record and its root in the same task, unchanged by revisions"
        )
      ]
  end

  defp valid_reply?(%{"reply_to" => nil, "reply_root" => root}, _target, _root, _task, _seq),
    do: is_nil(root)

  defp valid_reply?(r, target, root, task, seq) when is_map(target) and is_map(root) do
    target_seq = elem(feedback_parts(target["id"]), 1)

    checks = [
      elem(feedback_parts(target["id"]), 0) == task,
      elem(feedback_parts(root["id"]), 0) == task,
      target_seq < seq,
      elem(feedback_parts(root["id"]), 1) <= target_seq,
      is_nil(root["supersedes"]),
      is_nil(root["reply_to"]),
      r["reply_root"] == (target["reply_root"] || "#{task}##{target["thread"]}")
    ]

    Enum.all?(checks)
  end

  defp valid_reply?(_r, _target, _root, _task, _seq), do: false

  @spec root(map(), map(), map()) :: {:ok, integer() | nil} | :cycle | :missing
  defp root(r, feedback, seen) do
    cond do
      Map.has_key?(seen, r["id"]) ->
        :cycle

      is_nil(r["supersedes"]) ->
        {:ok, elem(feedback_parts(r["id"]), 1)}

      is_map(feedback[r["supersedes"]]) ->
        root(feedback[r["supersedes"]], feedback, Map.put(seen, r["id"], true))

      true ->
        :missing
    end
  end

  def feedback_parts(id) when is_binary(id) do
    case String.split(id, "#") do
      [task, seq] ->
        case Integer.parse(seq) do
          {n, ""} -> {task, n}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  def feedback_parts(_), do: {nil, nil}

  defp histories(data) do
    events = indexed(data, "task_events") |> Enum.group_by(fn {r, _} -> r["task"] end)

    errors =
      Enum.flat_map(indexed(data, "tasks"), fn {t, i} ->
        history = Map.get(events, t["id"], []) |> Enum.sort_by(fn {r, _} -> r["n"] end)

        state_errors =
          cond do
            history == [] ->
              []

            Enum.map(history, fn {r, _} -> r["n"] end) != Enum.to_list(1..length(history)) ->
              [error("tasks[#{i}]", "event sequence must be contiguous from 1")]

            elem(List.last(history), 0)["to"] != t["status"] ->
              [error("tasks[#{i}].status", "must agree with final event")]

            true ->
              []
          end

        state_errors ++ event_time_errors(history)
      end)

    links = indexed(data, "links") |> Enum.map(&elem(&1, 0))
    if cycle?(links), do: errors ++ [error("links", "depends_on cycle")], else: errors
  end

  defp event_time_errors(history) do
    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{previous, _}, {current, index}] ->
      {:ok, previous_at, 0} = DateTime.from_iso8601(previous["at"])
      {:ok, current_at, 0} = DateTime.from_iso8601(current["at"])

      if DateTime.compare(current_at, previous_at) == :lt,
        do: [
          error(
            "task_events[#{index}].at",
            "must not be earlier than the previous event of the same task"
          )
        ],
        else: []
    end)
  end

  def cycle?(links) do
    graph =
      links
      |> Enum.filter(&(&1["type"] == "depends_on"))
      |> Enum.group_by(& &1["from"], & &1["to"])

    Enum.reduce_while(Map.keys(graph), %{}, fn node, done ->
      case visit(node, graph, %{}, done) do
        :cycle -> {:halt, :cycle}
        done -> {:cont, done}
      end
    end) == :cycle
  end

  @spec visit(term(), map(), map(), map()) :: :cycle | map()
  defp visit(node, graph, active, done) do
    cond do
      Map.has_key?(active, node) ->
        :cycle

      Map.has_key?(done, node) ->
        done

      true ->
        visit_children(node, graph, active, done)
    end
  end

  @spec visit_children(term(), map(), map(), map()) :: :cycle | map()
  defp visit_children(node, graph, active, done) do
    result =
      Enum.reduce_while(Map.get(graph, node, []), done, fn next, done ->
        case visit(next, graph, Map.put(active, node, true), done) do
          :cycle -> {:halt, :cycle}
          done -> {:cont, done}
        end
      end)

    if result == :cycle, do: :cycle, else: Map.put(result, node, true)
  end

  defp rename_errors(data, rename) when is_map(rename) do
    names = indexed(data, "actors") |> Enum.map(fn {r, _} -> r["name"] end)

    errors =
      Enum.flat_map(rename, fn {old, new} ->
        if old in names and valid?(new, :name) and
             old == "helmsman" == (new == "helmsman"),
           do: [],
           else: [
             error(
               "rename.#{inspect(old)}",
               "must map an existing actor to a valid, nonreserved name"
             )
           ]
      end)

    mapped = Enum.map(names, &Map.get(rename, &1, &1))

    if Enum.all?(mapped, &is_binary/1) and
         length(Enum.uniq_by(mapped, &String.downcase/1)) != length(mapped),
       do: [error("rename", "mapped actor names must be unique") | errors],
       else: errors
  end

  defp rename_errors(_, _), do: [error("rename", "must be an object")]
  defp error(path, message), do: %{path: path, message: message}
end
