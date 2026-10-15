defmodule Helmsman.Backup.Import.Specs do
  @moduledoc "Independent audit-prefix imports under the maintenance lock; no dispatch."
  import Ecto.Query
  alias Helmsman.Backup.{Export, Format, SpecState}
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  alias Helmsman.TaskSpecs.{
    Blob,
    Event,
    File,
    Issue,
    IssueNote,
    Review,
    ReviewRequest,
    Spec,
    Store,
    Validate,
    Version
  }

  def write(scope, data, tasks, actors, report) do
    local =
      Map.new(Format.spec_collections(), fn key ->
        {key,
         Export.query(key, scope.workspace.id) |> Repo.all() |> Format.encode() |> Jason.decode!()}
      end)

    with {:ok, changes} <- classify(data, local) do
      idents = Enum.map(data["specs"], & &1["task"])

      Repo.all(
        from(t in Task,
          where: t.workspace_id == ^scope.workspace.id and t.ident in ^idents,
          order_by: t.id,
          lock: "FOR UPDATE"
        )
      )

      report =
        Enum.reduce(changes, report, &write_spec(&1, &2, scope, data, local, tasks, actors))

      {:ok, report}
    end
  end

  defp write_spec({row, action}, report, scope, data, local, tasks, actors) do
    incoming = records(data, row["task"])
    previous = records(local, row["task"])

    if action in [:created, :fast_forwarded],
      do: persist(scope, row, incoming, previous, tasks[row["task"]], actors)

    report(row, action, incoming, previous, report)
  end

  defp records(data, task),
    do:
      Map.new(
        Format.spec_collections(),
        &{&1, Enum.filter(data[&1], fn r -> r["task"] == task end)}
      )

  defp classify(data, local) do
    specs = Map.new(local["specs"], &{&1["task"], &1})
    names = Map.new(local["specs"], &{&1["change_id"], &1["task"]})

    data["specs"]
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, i}, {:ok, changes} ->
      action =
        if specs[row["task"]],
          do: compare(records(local, row["task"]), records(data, row["task"])),
          else: :created

      cond do
        match?({:error, _}, action) ->
          {:error, detail} = action

          {:halt,
           {:error, {:diverged, Map.merge(detail, %{task: row["task"], path: "specs[#{i}]"})}}}

        action in [:created, :fast_forwarded] and
            names[row["change_id"]] not in [nil, row["task"]] ->
          {:halt,
           {:error,
            {:change_id_conflict,
             %{
               path: "specs[#{i}].change_id",
               task: row["task"],
               change_id: row["change_id"],
               existing_task: names[row["change_id"]]
             }}}}

        true ->
          {:cont, {:ok, changes ++ [{row, action}]}}
      end
    end)
  end

  defp sequences(data) do
    issues = Enum.group_by(data["spec_issues"], & &1["review"])

    reviews =
      Enum.map(
        data["spec_reviews"],
        &{&1, Enum.sort_by(Map.get(issues, &1["n"], []), fn i -> i["n"] end)}
      )
      |> Enum.sort_by(fn {r, _} -> r["n"] end)

    [
      {"spec_versions",
       Enum.sort_by(data["spec_versions"], & &1["n"])
       |> Enum.map(
         &Map.update!(&1, "files", fn files -> Enum.sort_by(files, fn f -> f["path"] end) end)
       )},
      {"spec_review_requests",
       Enum.sort_by(data["spec_review_requests"], & &1["n"])
       |> Enum.map(&Map.take(&1, ~w(task n version reviewer requested_by at note)))},
      {"spec_reviews", reviews},
      {"spec_issue_notes",
       Enum.sort_by(data["spec_issue_notes"], &{&1["review"], &1["issue"], &1["n"]})},
      {"spec_events", Enum.sort_by(data["spec_events"], & &1["n"])}
    ]
  end

  defp compare(local, incoming) do
    directions = Enum.zip(sequences(local), sequences(incoming)) |> Enum.map(&direction/1)

    cond do
      Enum.all?(directions, fn {_, d, _} -> d == :equal end) ->
        :unchanged

      Enum.all?(directions, fn {_, d, _} -> d in [:equal, :forward] end) ->
        :fast_forwarded

      Enum.all?(directions, fn {_, d, _} -> d in [:equal, :behind] end) ->
        :local_newer

      true ->
        {name, _, position} =
          Enum.find(directions, fn {_, d, _} -> d == :fork end) ||
            Enum.find(directions, fn {_, d, _} -> d != :equal end)

        {:error, %{sequence: name, position: position, message: "spec histories diverged"}}
    end
  end

  defp direction({{name, a}, {_, b}}) do
    common = min(length(a), length(b))

    if Enum.take(a, common) == Enum.take(b, common) do
      {name, size_direction(length(a), length(b)), common + 1}
    else
      index = Enum.zip(a, b) |> Enum.find_index(fn {x, y} -> x != y end)
      {name, :fork, index + 1}
    end
  end

  defp size_direction(a, b) when a < b, do: :forward
  defp size_direction(a, b) when a > b, do: :behind
  defp size_direction(_, _), do: :equal

  defp report(row, action, incoming, previous, report) do
    report = update_in(report, [:counts, "specs", action], &(&1 + 1))

    report =
      if action == :local_newer,
        do: Map.update!(report, :local_newer, &(&1 ++ [row["task"] <> ":spec"])),
        else: report

    Enum.reduce(Format.spec_collections() -- ["specs"], report, fn key, report ->
      total = length(incoming[key])

      if action in [:created, :fast_forwarded] do
        fresh = total - length(previous[key])

        report
        |> update_in([:counts, key, :created], &(&1 + fresh))
        |> update_in([:counts, key, :unchanged], &(&1 + total - fresh))
      else
        update_in(report, [:counts, key, action], &(&1 + total))
      end
    end)
  end

  defp persist(scope, row, incoming, previous, task, actors) do
    replay = SpecState.replay(incoming["spec_events"], incoming["spec_issue_notes"])
    now = DateTime.utc_now()

    spec =
      Store.lock(task) ||
        Repo.insert!(%Spec{
          workspace_id: scope.workspace.id,
          task_id: task.id,
          change_id: row["change_id"],
          created_by_id: actors[row["created_by"]],
          inserted_at: SpecState.parse(row["created_at"]),
          updated_at: now
        })

    versions = versions(spec, incoming, actors)
    reviews = reviews(spec, incoming, versions, actors)
    requests(spec, incoming, versions, reviews, actors, replay.requests)
    issues = issues(spec, incoming, reviews, replay.issues, now)
    notes(spec, incoming, previous, issues, actors)
    events(spec, incoming, previous, actors)
    state = replay.spec
    proposal = state.proposal || %{}

    Repo.update_all(from(s in Spec, where: s.id == ^spec.id),
      set: [
        change_id: state.change_id,
        status: state.status,
        latest_version: state.latest_version,
        final_version: state.final_version,
        proposal_version: proposal[:version],
        proposal_summary: proposal[:summary],
        proposal_by_id: actors[proposal[:by_id]],
        proposal_run_id: nil,
        proposed_at: proposal[:at],
        request_seq: length(incoming["spec_review_requests"]),
        review_seq: length(incoming["spec_reviews"]),
        event_seq: length(incoming["spec_events"]),
        lock_version: spec.lock_version + 1,
        updated_at: now
      ]
    )
  end

  defp versions(spec, data, actors) do
    existing =
      Repo.all(from(v in Version, where: v.spec_id == ^spec.id)) |> Map.new(&{&1.number, &1})

    Enum.reduce(Enum.sort_by(data["spec_versions"], & &1["n"]), existing, fn row, versions ->
      if versions[row["n"]] do
        versions
      else
        files = Map.new(row["files"], &{&1["path"], &1["content"]})
        validation = Validate.run(files)

        version =
          Repo.insert!(%Version{
            workspace_id: spec.workspace_id,
            spec_id: spec.id,
            number: row["n"],
            author_id: actors[row["author"]],
            inserted_at: SpecState.parse(row["at"]),
            note: row["note"],
            validation: Helmsman.Backup.json(validation),
            valid: validation.valid
          })

        write_files(spec, version, files)
        Map.put(versions, row["n"], version)
      end
    end)
  end

  defp write_files(spec, version, files) do
    blobs =
      Map.values(files)
      |> Enum.uniq()
      |> Enum.map(fn content ->
        %{
          workspace_id: spec.workspace_id,
          spec_id: spec.id,
          sha256: :crypto.hash(:sha256, content),
          content: content,
          bytes: byte_size(content)
        }
      end)

    Repo.insert_all(Blob, blobs, on_conflict: :nothing, conflict_target: [:spec_id, :sha256])

    ids =
      Repo.all(from(b in Blob, where: b.spec_id == ^spec.id, select: {b.sha256, b.id}))
      |> Map.new()

    Repo.insert_all(
      File,
      Enum.map(files, fn {path, content} ->
        %{
          workspace_id: spec.workspace_id,
          version_id: version.id,
          path: path,
          blob_id: ids[:crypto.hash(:sha256, content)]
        }
      end)
    )
  end

  defp reviews(spec, data, versions, actors) do
    existing =
      Repo.all(from(r in Review, where: r.spec_id == ^spec.id)) |> Map.new(&{&1.number, &1})

    Enum.reduce(data["spec_reviews"], existing, fn row, reviews ->
      if reviews[row["n"]],
        do: reviews,
        else:
          Map.put(
            reviews,
            row["n"],
            Repo.insert!(%Review{
              workspace_id: spec.workspace_id,
              spec_id: spec.id,
              number: row["n"],
              version_id: versions[row["version"]].id,
              reviewer_id: actors[row["reviewer"]],
              verdict: SpecState.atom(row["verdict"]),
              summary: row["summary"],
              inserted_at: SpecState.parse(row["at"])
            })
          )
    end)
  end

  defp requests(spec, data, versions, reviews, actors, replay) do
    existing =
      Repo.all(from(r in ReviewRequest, where: r.spec_id == ^spec.id))
      |> Map.new(&{&1.number, &1})

    # Release active-request uniqueness before inserting a new request for that pair.
    Enum.each(data["spec_review_requests"], fn row ->
      if existing[row["n"]] do
        fields = request_state(row, reviews, replay[row["n"]])

        Repo.update_all(from(r in ReviewRequest, where: r.id == ^existing[row["n"]].id),
          set: Map.to_list(fields)
        )
      end
    end)

    Enum.each(data["spec_review_requests"], fn row ->
      unless existing[row["n"]] do
        fields =
          Map.merge(request_state(row, reviews, replay[row["n"]]), %{
            workspace_id: spec.workspace_id,
            spec_id: spec.id,
            number: row["n"],
            version_id: versions[row["version"]].id,
            reviewer_id: actors[row["reviewer"]],
            requested_by_id: actors[row["requested_by"]],
            note: row["note"],
            inserted_at: SpecState.parse(row["at"])
          })

        Repo.insert!(struct(ReviewRequest, fields))
      end
    end)
  end

  defp request_state(row, reviews, state),
    do: %{
      status: state.status,
      close_reason: state.close_reason,
      review_id: if(state.review, do: reviews[state.review].id),
      closed_at: SpecState.parse(row["closed_at"])
    }

  defp issues(spec, data, reviews, resolutions, now) do
    review_numbers = Map.new(reviews, fn {n, r} -> {r.id, n} end)

    existing =
      Repo.all(from(i in Issue, where: i.spec_id == ^spec.id))
      |> Map.new(&{{review_numbers[&1.review_id], &1.number}, &1})

    notes = Enum.group_by(data["spec_issue_notes"], &{&1["review"], &1["issue"]})

    Enum.reduce(data["spec_issues"], existing, fn row, issues ->
      key = {row["review"], row["n"]}

      fields = %{
        resolution: Map.get(resolutions, key, :open),
        note_seq: length(Map.get(notes, key, [])),
        updated_at: now
      }

      issue =
        if existing[key] do
          Repo.update!(Ecto.Changeset.change(existing[key], fields))
        else
          attrs =
            Map.new(
              ~w(severity file line anchor body suggestion),
              &{String.to_existing_atom(&1), row[&1]}
            )
            |> Map.update!(:severity, &SpecState.atom/1)

          attrs =
            Map.merge(
              attrs,
              Map.merge(fields, %{
                workspace_id: spec.workspace_id,
                spec_id: spec.id,
                review_id: reviews[row["review"]].id,
                number: row["n"]
              })
            )

          Repo.insert!(struct(Issue, attrs))
        end

      Map.put(issues, key, issue)
    end)
  end

  defp notes(spec, incoming, previous, issues, actors) do
    keys = MapSet.new(previous["spec_issue_notes"], &{&1["review"], &1["issue"], &1["n"]})

    rows =
      for row <- incoming["spec_issue_notes"],
          not MapSet.member?(keys, {row["review"], row["issue"], row["n"]}) do
        %{
          workspace_id: spec.workspace_id,
          issue_id: issues[{row["review"], row["issue"]}].id,
          number: row["n"],
          author_id: actors[row["author"]],
          kind: SpecState.atom(row["kind"]),
          resolution: SpecState.atom(row["resolution"]),
          fixed_in_version: row["fixed_in_version"],
          body: row["body"],
          inserted_at: SpecState.parse(row["at"])
        }
      end

    Repo.insert_all(IssueNote, rows)
  end

  defp events(spec, incoming, previous, actors) do
    rows =
      for row <- incoming["spec_events"], row["n"] > length(previous["spec_events"]) do
        %{
          workspace_id: spec.workspace_id,
          spec_id: spec.id,
          number: row["n"],
          actor_id: actors[row["actor"]],
          action: row["action"],
          version: row["version"],
          data: row["data"],
          inserted_at: SpecState.parse(row["at"])
        }
      end

    Repo.insert_all(Event, rows)
  end
end
