defmodule Helmsman.Backup.Bosun do
  @moduledoc "Converts bosun v2 records into the portable v1 snapshot; no bosun code is embedded."
  alias Helmsman.Backup.Format
  alias Helmsman.Backup.Import.Validate

  def convert(data, human, rename \\ %{})

  def convert(%{"format" => "bosun-export", "version" => 2} = data, human, rename) do
    actor = fn name -> if name == "user", do: Map.get(rename, "user", human), else: name end
    exported = time(data["exported_at"])

    tasks = convert_tasks(data, actor)
    events = convert_events(data, actor)
    feedback = convert_feedback(data, actor)
    links = convert_links(data, actor)
    filters = convert_filters(data, actor)
    actors = convert_actors(data, actor, tasks, events, feedback, links, filters)
    projects = convert_projects(data, exported)

    converted = %{
      "format" => "helmsman-export",
      "version" => 1,
      "exported_at" => exported,
      "source" => %{"host" => "bosun", "app_version" => "2"},
      "workspace" => %{"slug" => "bosun", "name" => "bosun"},
      "actors" => actors,
      "projects" => projects,
      "tasks" => tasks,
      "task_events" => events,
      "feedback" => feedback,
      "links" => links,
      "saved_filters" => filters
    }

    case Validate.validate(converted, Map.delete(rename, "user")) do
      {:ok, _} ->
        {:ok, converted}

      {:error, {:invalid_import, errors}} ->
        {:error,
         {:invalid_import,
          Enum.map(
            errors,
            &Map.update!(&1, :path, fn path -> bosun_path(path, data, events) end)
          )}}

      error ->
        error
    end
  rescue
    _ -> {:error, {:invalid_import, [%{path: "$", message: "invalid bosun record"}]}}
  end

  def convert(_, _, _), do: {:error, :unsupported_format}

  defp convert_tasks(data, actor) do
    tasks =
      Enum.map(data["tasks"] || [], fn row ->
        history = Enum.reverse(row["history"] || [])

        %{
          "id" => row["id"],
          "project" => row["project_key"],
          "seq" => row["seq"],
          "title" => row["title"],
          "description" => row["description"] || "",
          "status" => normalize(row["status"]),
          "priority" => normalize(row["priority"]),
          "kind" => row["kind"] || "task",
          "labels" => row["labels"] || [],
          "epic" => row["epic"],
          "created_by" =>
            actor.(row["created_by"] || (List.first(history) || %{})["actor"] || "user"),
          "assignee" => actor.(row["assignee"]),
          "created_at" => time(row["created_at"]),
          "updated_at" => time(row["updated_at"])
        }
      end)

    tasks
  end

  defp convert_events(data, actor) do
    events =
      Enum.flat_map(data["tasks"] || [], fn row ->
        row["history"]
        |> Enum.reverse()
        |> Enum.with_index(1)
        |> Enum.map(fn {h, n} ->
          %{
            "task" => row["id"],
            "n" => n,
            "from" => normalize(h["from"]),
            "to" => normalize(h["to"]),
            "actor" => actor.(h["actor"] || "user"),
            "comment" => h["comment"],
            "commits" => h["commits"] || [],
            "tests" => h["tests"],
            "auto" => false,
            "auto_reason" => nil,
            "feedback" => nil,
            "verified_sha" => nil,
            "assignee_side" => [],
            "at" => time(h["at"])
          }
        end)
      end)

    events
  end

  defp convert_feedback(data, actor) do
    feedback_rows = data["feedback"] || []

    feedback =
      Enum.map(feedback_rows, fn f ->
        %{
          "id" => f["id"],
          "thread" => thread(f, Map.new(feedback_rows, &{&1["id"], &1}), %{}),
          "author" => actor.(f["author"] || "user"),
          "kind" => f["kind"] || "comment",
          "content" => f["content"],
          "status" => if(f["superseded_by"], do: "superseded", else: "active"),
          "supersedes" => f["supersedes"],
          "superseded_by" => f["superseded_by"],
          "mentions" => [],
          "fallback" => false,
          "at" => time(f["created_at"])
        }
      end)

    feedback
  end

  defp convert_links(data, actor) do
    links =
      Enum.map(data["links"] || [], fn r ->
        %{
          "from" => r["from"],
          "to" => r["to"],
          "type" => normalize(r["type"]),
          "actor" => actor.(r["actor"] || "user"),
          "at" => time(r["created_at"])
        }
      end)

    links
  end

  defp convert_filters(data, actor) do
    filters =
      Enum.map(data["filters"] || [], fn r ->
        %{"name" => r["name"], "bql" => r["query"], "owner" => actor.("user")}
      end)

    filters
  end

  defp convert_actors(data, actor, tasks, events, feedback, links, filters) do
    actors =
      Enum.map(data["actors"] || [], fn r ->
        %{"name" => actor.(r["name"]), "kind" => r["kind"], "disabled" => false, "owner" => nil}
      end)

    names =
      (Enum.flat_map(tasks, &[&1["created_by"], &1["assignee"]]) ++
         Enum.map(events, & &1["actor"]) ++
         Enum.map(feedback, & &1["author"]) ++
         Enum.map(links, & &1["actor"]) ++ Enum.map(filters, & &1["owner"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    existing = MapSet.new(actors, & &1["name"])

    actors =
      (actors ++ Enum.reject(names, &MapSet.member?(existing, &1)))
      |> Enum.map(fn r ->
        if is_map(r),
          do: r,
          else: %{"name" => r, "kind" => "human", "disabled" => false, "owner" => nil}
      end)

    actors
  end

  defp convert_projects(data, exported) do
    projects =
      Enum.map(data["projects"] || [], fn r ->
        %{
          "key" => r["key"],
          "name" => r["name"],
          "description" => r["description"] || "",
          "task_seq" => r["task_seq"],
          "archived_at" => if(r["archived"], do: exported),
          "created_at" => time(r["created_at"]),
          "updated_at" => time(r["updated_at"])
        }
      end)

    projects
  end

  defp normalize(nil), do: nil
  defp normalize(v) when is_binary(v), do: v |> String.downcase() |> String.replace("-", "_")
  defp time(v) when is_integer(v), do: v |> DateTime.from_unix!(:millisecond) |> Format.time()
  defp time(v) when is_binary(v), do: v |> DateTime.from_iso8601() |> elem(1) |> Format.time()

  @spec thread(map(), map(), map()) :: pos_integer() | nil
  defp thread(f, rows, seen) do
    if f["supersedes"] && not Map.has_key?(seen, f["id"]) && rows[f["supersedes"]] do
      thread(rows[f["supersedes"]], rows, Map.put(seen, f["id"], true))
    else
      elem(Validate.feedback_parts(f["id"]), 1)
    end
  end

  defp bosun_path(path, data, events) do
    case Regex.run(~r/^task_events\[(\d+)\](.*)$/, path) do
      [_, index, rest] ->
        event = Enum.at(events, String.to_integer(index))
        ti = Enum.find_index(data["tasks"], &(&1["id"] == event["task"]))
        task = Enum.at(data["tasks"], ti)
        "tasks[#{ti}].history[#{length(task["history"]) - event["n"]}]#{rest}"

      _ ->
        path
        |> String.replace("saved_filters[", "filters[")
        |> String.replace(".bql", ".query")
        |> String.replace(".project", ".project_key")
        |> String.replace(".at", ".created_at")
    end
  end
end
