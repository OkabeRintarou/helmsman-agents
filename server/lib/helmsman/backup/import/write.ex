defmodule Helmsman.Backup.Import.Write do
  @moduledoc "Maintenance-locked bulk writes with no task dispatch or per-record notifications."
  import Ecto.Query
  alias Helmsman.Backup.{Export, Format}
  alias Helmsman.Backup.Import.{Actors, Merge, Replace, Validate}
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Feedback.Entry
  alias Helmsman.Filters.SavedFilter
  alias Helmsman.Links.Link
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Search.Document
  alias Helmsman.Tasks.{Task, TaskEvent}

  def run(scope, data, opts) do
    with {:ok, mapping, actor_report} <- Actors.map(scope, data, opts[:rename] || %{}),
         :ok <- maybe_replace(scope, opts) do
      data = Actors.normalize(data, mapping)
      actors = mapping |> Map.values() |> Map.new(&{&1.name, &1.id})

      report = %{
        counts:
          Map.new(
            ~w(projects tasks task_events feedback links saved_filters),
            &{&1, %{created: 0, fast_forwarded: 0, unchanged: 0, local_newer: 0}}
          ),
        actors: actor_report,
        local_newer: [],
        warnings: []
      }

      {projects, report} = projects(scope, data, opts, report)

      local =
        Map.new(~w(tasks task_events feedback links), fn key ->
          {key,
           Export.query(key, scope.workspace.id)
           |> Repo.all()
           |> Format.encode()
           |> Jason.decode!()}
        end)

      write_records(scope, data, opts, projects, actors, local, report)
    end
  end

  defp write_records(scope, data, _opts, projects, actors, local, report) do
    with {:ok, changes, report} <- classify(data, local, report),
         {:ok, tasks, report} <- tasks(scope, changes, projects, actors, report),
         {:ok, report} <- histories(scope, data, changes, tasks, actors, report),
         {:ok, report} <- links(scope, data, local, tasks, actors, report) do
      report = filters(scope, data, report)

      local_tasks = Map.new(local["tasks"], &{&1["id"], &1})

      changed =
        changes
        |> Enum.filter(fn {row, action} ->
          action == :created or
            (action == :fast_forwarded and row["status"] != local_tasks[row["id"]]["status"])
        end)
        |> Enum.map(fn {row, _} -> tasks[row["id"]].id end)

      Enum.each(changed, &Dependencies.changed/1)
      {:ok, report}
    end
  end

  defp maybe_replace(scope, opts),
    do: if(opts[:mode] == :replace, do: Replace.clear(scope.workspace.id), else: :ok)

  defp parse(nil), do: nil
  defp parse(value), do: elem(DateTime.from_iso8601(value), 1)

  defp count(report, kind, action, n \\ 1),
    do: update_in(report, [:counts, kind, action], &(&1 + n))

  defp batch(schema, rows) do
    rows
    |> Enum.chunk_every(1000)
    |> Enum.flat_map(fn rows -> elem(Repo.insert_all(schema, rows, returning: true), 1) end)
  end

  defp projects(scope, data, opts, report) do
    current =
      Repo.all(from(p in Project, where: p.workspace_id == ^scope.workspace.id))
      |> Map.new(&{&1.key, &1})

    portable =
      Export.query("projects", scope.workspace.id) |> Repo.all() |> Map.new(&{&1["key"], &1})

    Enum.reduce(data["projects"], {current, report}, fn row, {projects, report} ->
      project = projects[row["key"]]

      cond do
        is_nil(project) ->
          %{rows: [[id]]} =
            Repo.query!(
              "INSERT INTO projects(workspace_id,key,name,description,task_seq,archived_at,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id",
              [
                scope.workspace.id,
                row["key"],
                row["name"],
                row["description"],
                row["task_seq"],
                naive(row["archived_at"]),
                naive(row["created_at"]),
                naive(row["updated_at"])
              ]
            )

          {Map.put(projects, row["key"], Repo.get!(Project, id)),
           count(report, "projects", :created)}

        opts[:mode] == :replace or row["updated_at"] > portable[row["key"]]["updated_at"] ->
          Repo.query!(
            "UPDATE projects SET name=$2,description=$3,archived_at=$4,task_seq=greatest(task_seq,$5),updated_at=$6 WHERE id=$1",
            [
              project.id,
              row["name"],
              row["description"],
              naive(row["archived_at"]),
              row["task_seq"],
              naive(row["updated_at"])
            ]
          )

          {Map.put(projects, row["key"], Repo.get!(Project, project.id)),
           count(report, "projects", :fast_forwarded)}

        row["task_seq"] > project.task_seq ->
          Repo.update_all(from(p in Project, where: p.id == ^project.id),
            set: [task_seq: row["task_seq"]]
          )

          {Map.put(projects, row["key"], %{project | task_seq: row["task_seq"]}),
           count(report, "projects", :fast_forwarded)}

        true ->
          {projects, count(report, "projects", :unchanged)}
      end
    end)
  end

  defp naive(nil), do: nil
  defp naive(value), do: value |> parse() |> DateTime.to_naive()

  defp classify(data, local, report) do
    tasks = Map.new(local["tasks"], &{&1["id"], &1})
    le = Enum.group_by(local["task_events"], & &1["task"])
    ie = Enum.group_by(data["task_events"], & &1["task"])
    lf = Enum.group_by(local["feedback"], &elem(Validate.feedback_parts(&1["id"]), 0))
    inf = Enum.group_by(data["feedback"], &elem(Validate.feedback_parts(&1["id"]), 0))

    Enum.reduce_while(Enum.with_index(data["tasks"]), {:ok, [], report}, fn {row, index},
                                                                            {:ok, changes, report} ->
      id = row["id"]

      action =
        if tasks[id],
          do:
            Merge.classify(
              tasks[id],
              row,
              Map.get(le, id, []),
              sorted_events(ie[id]),
              Map.get(lf, id, []),
              sorted_feedback(inf[id])
            ),
          else: :created

      classification_result(
        action,
        row,
        index,
        changes,
        report,
        length(sorted_events(ie[id])) > length(Map.get(le, id, [])) or
          length(sorted_feedback(inf[id])) > length(Map.get(lf, id, []))
      )
    end)
  end

  defp classification_result({:error, detail}, _row, index, _changes, _report, _progress),
    do: {:halt, {:error, {:diverged, %{path: "tasks[#{index}]", message: inspect(detail)}}}}

  defp classification_result(action, row, _index, changes, report, progress) do
    report = count(report, "tasks", action)

    report =
      if action == :local_newer,
        do: Map.update!(report, :local_newer, &(&1 ++ [row["id"]])),
        else: report

    {:cont, {:ok, changes ++ [{Map.put(row, "__history_progress", progress), action}], report}}
  end

  defp sorted_events(rows), do: Enum.sort_by(rows || [], & &1["n"])

  defp sorted_feedback(rows),
    do: Enum.sort_by(rows || [], &elem(Validate.feedback_parts(&1["id"]), 1))

  defp task_fields(row, scope, projects, actors) do
    %{
      workspace_id: scope.workspace.id,
      project_id: projects[row["project"]].id,
      seq: row["seq"],
      ident: row["id"],
      title: row["title"],
      description: row["description"],
      status: String.to_existing_atom(row["status"]),
      priority: String.to_existing_atom(row["priority"]),
      kind: String.to_existing_atom(row["kind"]),
      labels: row["labels"],
      created_by_id: actors[row["created_by"]],
      assignee_id: actors[row["assignee"]],
      inserted_at: parse(row["created_at"]),
      updated_at: parse(row["updated_at"]),
      lock_version: 1,
      search:
        Document.task(%{
          ident: row["id"],
          labels: row["labels"],
          title: row["title"],
          description: row["description"]
        })
    }
  end

  defp tasks(scope, changes, projects, actors, report) do
    rows =
      Enum.filter(changes, fn {_, action} -> action == :created end)
      |> Enum.map(fn {row, _} -> task_fields(row, scope, projects, actors) end)

    batch(Task, rows)

    tasks =
      Repo.all(from(t in Task, where: t.workspace_id == ^scope.workspace.id))
      |> Map.new(&{&1.ident, &1})

    tasks =
      Enum.reduce(changes, tasks, &update_task(&1, &2, scope, projects, actors))

    {:ok, tasks, report}
  end

  defp update_task({row, action}, tasks, scope, projects, actors) do
    task = tasks[row["id"]]

    if action in [:created, :fast_forwarded] do
      fields =
        task_fields(row, scope, projects, actors)
        |> Map.drop([:workspace_id, :project_id, :seq, :ident, :kind, :inserted_at])
        |> Map.put(:epic_id, if(row["epic"], do: tasks[row["epic"]].id))

      fields =
        Map.put(
          fields,
          :lock_version,
          if(action == :created, do: 1, else: task.lock_version + 1)
        )

      # Equal sequences with older input must only advance supersession, not rewind fields.
      fields =
        if action == :fast_forwarded and not row["__history_progress"] and
             row["updated_at"] <= Format.time(task.updated_at),
           do: %{lock_version: task.lock_version + 1},
           else: fields

      Repo.update_all(from(t in Task, where: t.id == ^task.id), set: Map.to_list(fields))
      task = struct(task, fields)
      Map.put(tasks, task.ident, task)
    else
      tasks
    end
  end

  defp histories(scope, data, changes, tasks, actors, report) do
    selected =
      changes
      |> Enum.filter(fn {_, a} -> a in [:created, :fast_forwarded] end)
      |> Map.new(fn {r, a} -> {r["id"], a} end)

    task_idents = Map.new(tasks, fn {ident, task} -> {task.id, ident} end)

    existing =
      Repo.all(from(f in Entry, where: f.workspace_id == ^scope.workspace.id))
      |> Map.new(&{"#{task_idents[&1.task_id]}##{&1.seq}", &1})

    feedback =
      Enum.filter(
        data["feedback"],
        &Map.has_key?(selected, elem(Validate.feedback_parts(&1["id"]), 0))
      )

    fresh = Enum.reject(feedback, &Map.has_key?(existing, &1["id"])) |> sorted_feedback()

    rows =
      Enum.map(fresh, fn r ->
        {ident, seq} = Validate.feedback_parts(r["id"])

        %{
          workspace_id: scope.workspace.id,
          task_id: tasks[ident].id,
          seq: seq,
          thread_seq: r["thread"],
          author_id: actors[r["author"]],
          kind: String.to_existing_atom(r["kind"]),
          content: r["content"],
          mentions: Enum.map(r["mentions"], &actors[&1]),
          fallback: r["fallback"],
          status: :active,
          inserted_at: parse(r["at"]),
          search: Document.feedback(r["content"])
        }
      end)

    inserted = batch(Entry, rows)

    ids =
      Enum.zip(fresh, inserted) |> Map.new(fn {r, f} -> {r["id"], f} end) |> Map.merge(existing)

    Enum.each(feedback, &advance_revision(&1, ids))

    events = append_events(scope, data, selected, tasks, actors, ids)

    for ident <- Map.keys(selected) do
      task = tasks[ident]
      active = Repo.all(from(f in Entry, where: f.task_id == ^task.id and f.status == :active))

      last =
        active
        |> Enum.filter(&(&1.kind in [:question, :answer]))
        |> Enum.max_by(& &1.thread_seq, fn -> nil end)

      max_seq = Repo.one(from(f in Entry, where: f.task_id == ^task.id, select: max(f.seq))) || 0

      Repo.update_all(from(t in Task, where: t.id == ^task.id),
        set: [
          feedback_seq: max_seq,
          feedback_count: length(active),
          open_question: not is_nil(last) and last.kind == :question
        ]
      )
    end

    {:ok,
     report
     |> count("feedback", :created, length(fresh))
     |> count("feedback", :unchanged, length(data["feedback"]) - length(fresh))
     |> count("task_events", :created, length(events))
     |> count("task_events", :unchanged, length(data["task_events"]) - length(events))}
  end

  defp advance_revision(r, ids) do
    f = ids[r["id"]]

    fields =
      if is_nil(f.supersedes_id) and r["supersedes"],
        do: %{supersedes_id: ids[r["supersedes"]].id},
        else: %{}

    fields =
      if f.status == :active and r["status"] == "superseded",
        do:
          Map.merge(fields, %{
            status: :superseded,
            superseded_by_id: ids[r["superseded_by"]].id,
            search: nil
          }),
        else: fields

    if fields != %{}, do: Repo.update!(Ecto.Changeset.change(f, fields))
  end

  defp append_events(scope, data, selected, tasks, actors, ids) do
    event_counts =
      Repo.all(
        from(e in TaskEvent,
          where: e.workspace_id == ^scope.workspace.id,
          group_by: e.task_id,
          select: {e.task_id, count(e.id)}
        )
      )
      |> Map.new()

    events =
      Enum.filter(data["task_events"], fn r ->
        Map.has_key?(selected, r["task"]) and
          r["n"] > Map.get(event_counts, tasks[r["task"]].id, 0)
      end)
      |> Enum.sort_by(&{&1["task"], &1["n"]})

    rows =
      Enum.map(events, fn r ->
        %{
          workspace_id: scope.workspace.id,
          task_id: tasks[r["task"]].id,
          actor_id: actors[r["actor"]],
          from_status: if(r["from"], do: String.to_existing_atom(r["from"])),
          to_status: String.to_existing_atom(r["to"]),
          comment: r["comment"],
          commits: r["commits"],
          tests: r["tests"],
          auto: r["auto"],
          auto_reason: if(r["auto_reason"], do: String.to_existing_atom(r["auto_reason"])),
          feedback_id: if(r["feedback"], do: ids[r["feedback"]].id),
          verified_sha: r["verified_sha"],
          assignee_side_ids: r["assignee_side"] |> Enum.map(&actors[&1]) |> nil_if_empty(),
          inserted_at: parse(r["at"])
        }
      end)

    batch(TaskEvent, rows)

    events
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(values), do: values

  defp links(scope, data, local, tasks, actors, report) do
    keys = MapSet.new(local["links"], &Map.take(&1, ~w(from to type)))
    fresh = Enum.reject(data["links"], &MapSet.member?(keys, Map.take(&1, ~w(from to type))))

    if Validate.cycle?(local["links"] ++ fresh) do
      {:error, {:cycle, %{path: "links", message: "merged depends_on graph contains a cycle"}}}
    else
      rows =
        Enum.map(fresh, fn r ->
          %{
            workspace_id: scope.workspace.id,
            from_task_id: tasks[r["from"]].id,
            to_task_id: tasks[r["to"]].id,
            type: String.to_existing_atom(r["type"]),
            actor_id: actors[r["actor"]],
            inserted_at: parse(r["at"])
          }
        end)

      batch(Link, rows)

      if fresh != [],
        do: Enum.each(fresh, &Dependencies.changed(tasks[&1["from"]].id))

      {:ok,
       report
       |> count("links", :created, length(fresh))
       |> count("links", :unchanged, length(data["links"]) - length(fresh))}
    end
  end

  defp filters(scope, data, report) do
    existing =
      Repo.all(
        from(f in SavedFilter,
          where: f.workspace_id == ^scope.workspace.id and f.owner_id == ^scope.user.id,
          select: {fragment("lower(?::text)", f.name), f.bql}
        )
      )
      |> Map.new()

    Enum.reduce(data["saved_filters"], {existing, report}, fn r, {existing, report} ->
      cond do
        existing[filter_name_key(r["name"])] == r["bql"] ->
          {existing, count(report, "saved_filters", :unchanged)}

        match?({:error, _}, Helmsman.BQL.parse(r["bql"])) or map_size(existing) >= 100 ->
          {existing,
           Map.update!(
             report,
             :warnings,
             &(&1 ++
                 [
                   %{
                     path: "saved_filters",
                     name: r["name"],
                     message: "invalid BQL or filter limit reached"
                   }
                 ])
           )}

        true ->
          name = free_name(r["name"], existing, 0)

          Repo.insert!(%SavedFilter{
            workspace_id: scope.workspace.id,
            owner_id: scope.user.id,
            name: name,
            bql: r["bql"],
            visibility: :workspace
          })

          {Map.put(existing, filter_name_key(name), r["bql"]),
           count(report, "saved_filters", :created)}
      end
    end)
    |> elem(1)
  end

  defp free_name(base, existing, n) do
    suffix =
      case n do
        0 -> ""
        1 -> " (imported)"
        n -> " (imported #{n})"
      end

    name = String.slice(base, 0, 80 - String.length(suffix)) <> suffix

    if Map.has_key?(existing, filter_name_key(name)),
      do: free_name(base, existing, n + 1),
      else: name
  end

  # citext compares the database's locale-aware lowercasing, not Elixir's Unicode rules.
  defp filter_name_key(name) do
    %{rows: [[key]]} = Repo.query!("SELECT lower($1::text)", [name])
    key
  end
end
