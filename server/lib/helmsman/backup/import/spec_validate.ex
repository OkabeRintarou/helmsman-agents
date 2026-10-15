defmodule Helmsman.Backup.Import.SpecValidate do
  @moduledoc "Validates portable spec histories and their derived mutable state before writes."
  alias Helmsman.Backup.{Format, SpecState}
  alias Helmsman.Backup.Import.Validate
  alias Helmsman.TaskSpecs.{Event, Files}

  @types %{
    "specs" => %{
      change_id: :change_id,
      status: {:enum, ~w(draft in_review pending_approval finalized abandoned)},
      latest_version: :nonnegative,
      final_version: {:optional, :positive},
      proposal: :proposal,
      created_by: :name,
      created_at: :time
    },
    "spec_versions" => %{
      n: :positive,
      author: :name,
      at: :time,
      note: {:bytes, 4096},
      files: :files
    },
    "spec_review_requests" => %{
      n: :positive,
      version: :positive,
      reviewer: :name,
      requested_by: :name,
      at: :time,
      note: {:bytes, 8192},
      status: {:enum, ~w(requested submitted cancelled lapsed)},
      close_reason: {:optional, {:enum, ~w(superseded withdrawn abandoned)}},
      review: {:optional, :positive},
      closed_at: {:optional, :time}
    },
    "spec_reviews" => %{
      n: :positive,
      version: :positive,
      reviewer: :name,
      verdict: {:enum, ~w(pass fail comment)},
      summary: {:bytes, 16_384},
      at: :time
    },
    "spec_issues" => %{
      review: :positive,
      n: :positive,
      severity: {:enum, ~w(P1 P2 P3)},
      file: {:optional, {:bytes, 300}},
      line: {:optional, :positive},
      anchor: {:optional, {:bytes, 200}},
      body: {:content, 8192},
      suggestion: {:optional, {:bytes, 8192}}
    },
    "spec_issue_notes" => %{
      review: :positive,
      issue: :positive,
      n: :positive,
      author: :name,
      kind: {:enum, ~w(reply withdraw ruling comment)},
      resolution: {:optional, {:enum, ~w(accepted disputed withdrawn upheld dismissed)}},
      fixed_in_version: {:optional, :positive},
      body: {:bytes, 8192},
      at: :time
    },
    "spec_events" => %{
      n: :positive,
      actor: :name,
      action: {:enum, Event.actions()},
      version: {:optional, :positive},
      data: :event_data,
      at: :time
    }
  }
  @actors ~w(author actor reviewer requested_by created_by)

  def validate(data) do
    errors =
      Enum.flat_map(@types, fn {key, types} ->
        Enum.flat_map(Enum.with_index(data[key]), &record_fields(&1, key, types))
      end)

    if errors == [] do
      errors = references(data) ++ sequences(data)
      if errors == [], do: states(data), else: errors
    else
      errors
    end
  end

  defp record_fields({row, i}, key, types) when is_map(row),
    do: fields(row, Map.put(types, :task, :task_id), "#{key}[#{i}]")

  defp record_fields({_row, i}, key, _types), do: [error("#{key}[#{i}]", "must be an object")]

  defp fields(row, types, path),
    do:
      Enum.flat_map(types, fn {field, type} ->
        check(row[to_string(field)], type, "#{path}.#{field}")
      end)

  defp check(value, :change_id, path) do
    if is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,63}\z/, value),
      do: [],
      else: [error(path, "invalid change_id")]
  end

  defp check(nil, :proposal, _path), do: []

  defp check(value, :proposal, path) when is_map(value),
    do:
      fields(value, %{version: :positive, summary: {:bytes, 16_384}, by: :name, at: :time}, path)

  defp check(_value, :proposal, path), do: [error(path, "must be an object or null")]

  defp check(value, :event_data, path) do
    if is_map(value) and byte_size(Jason.encode!(value)) <= 20_480,
      do: [],
      else: [error(path, "must be an object of at most 20 KB")]
  end

  defp check(value, :files, path) when is_list(value) do
    errors =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {file, i} ->
        if is_map(file),
          do: fields(file, %{path: {:text, 300}, content: {:bytes, 262_144}}, "#{path}[#{i}]"),
          else: [error("#{path}[#{i}]", "must be an object")]
      end)

    if errors == [] do
      files = Map.new(value, &{&1["path"], &1["content"]})

      duplicate =
        if map_size(files) == length(value), do: [], else: [error(path, "duplicate file path")]

      case Files.merge(%{}, files, []) do
        {:ok, _} ->
          duplicate

        {:error, problems} ->
          duplicate ++ Enum.map(problems, &file_error(&1, value, path))
      end
    else
      errors
    end
  end

  defp check(_value, :files, path), do: [error(path, "must be an array")]
  defp check(value, type, path), do: Validate.check(value, type, path)

  defp file_error(problem, files, path) do
    index = Enum.find_index(files, &(&1["path"] == problem.path))
    error(if(index, do: "#{path}[#{index}].path", else: path), problem.message)
  end

  defp references(data) do
    targets =
      Map.new(
        ~w(actors tasks specs spec_versions spec_reviews spec_issues spec_review_requests),
        fn key ->
          {key, Map.new(data[key], &{key(key, &1), &1})}
        end
      )

    Enum.flat_map(Format.spec_collections(), fn collection ->
      Enum.flat_map(
        Enum.with_index(data[collection]),
        &record_references(&1, collection, targets)
      )
    end)
  end

  defp record_references({r, i}, collection, targets) do
    path = "#{collection}[#{i}]"

    refs =
      [{"task", r["task"], if(collection == "specs", do: "tasks", else: "specs")}] ++
        Enum.map(Enum.filter(@actors, &Map.has_key?(r, &1)), &{&1, r[&1], "actors"}) ++
        local_refs(collection, r)

    errors = Enum.flat_map(refs, &reference_error(&1, targets, path))
    errors ++ extra_refs(collection, r, path, targets)
  end

  defp reference_error({field, id, target}, targets, path) do
    if is_nil(id) or Map.has_key?(targets[target], id),
      do: [],
      else: [error("#{path}.#{field}", "unresolved reference")]
  end

  defp key("actors", r), do: r["name"]
  defp key("tasks", r), do: r["id"]
  defp key("specs", r), do: r["task"]
  defp key("spec_issues", r), do: {r["task"], r["review"], r["n"]}
  defp key(_collection, r), do: {r["task"], r["n"]}

  defp local_refs(collection, r) do
    Enum.flat_map(~w(version final_version fixed_in_version review issue), fn field ->
      value = r[field]

      cond do
        is_nil(value) -> []
        field == "issue" -> [{field, {r["task"], r["review"], value}, "spec_issues"}]
        field == "review" and collection == "spec_events" -> []
        field == "review" -> [{field, {r["task"], value}, "spec_reviews"}]
        true -> [{field, {r["task"], value}, "spec_versions"}]
      end
    end)
  end

  defp extra_refs("specs", r, path, targets) do
    if r["proposal"], do: proposal_refs(r, path, targets), else: []
  end

  defp extra_refs("spec_issues", r, path, targets) do
    review = targets["spec_reviews"][{r["task"], r["review"]}]
    version = review && targets["spec_versions"][{r["task"], review["version"]}]
    file = version && Enum.find(version["files"], &(&1["path"] == r["file"]))

    cond do
      r["file"] && is_nil(file) ->
        [error("#{path}.file", "not a file of the reviewed version")]

      r["line"] && (is_nil(file) or r["line"] > length(String.split(file["content"], "\n"))) ->
        [error("#{path}.line", "outside the reviewed file")]

      true ->
        []
    end
  end

  defp extra_refs("spec_issue_notes", r, path, _targets) do
    valid =
      case r["kind"] do
        "comment" -> is_nil(r["resolution"])
        "reply" -> r["resolution"] in ~w(accepted disputed)
        "withdraw" -> r["resolution"] == "withdrawn"
        "ruling" -> r["resolution"] in ~w(upheld dismissed)
      end

    if valid and (is_nil(r["fixed_in_version"]) or r["resolution"] == "accepted"),
      do: [],
      else: [error(path, "kind, resolution and fixed_in_version disagree")]
  end

  defp extra_refs("spec_events", r, path, targets), do: event_refs(r, path, targets)
  defp extra_refs(_collection, _r, _path, _targets), do: []

  defp proposal_refs(r, path, targets) do
    p = r["proposal"]

    if Map.has_key?(targets["spec_versions"], {r["task"], p["version"]}) and
         Map.has_key?(targets["actors"], p["by"]),
       do: [],
       else: [error("#{path}.proposal", "unresolved proposal reference")]
  end

  defp event_refs(r, path, targets) do
    d = r["data"]

    types = event_types(r["action"])

    errors = fields(d, types, "#{path}.data")

    # `data.reviewer` is the reviewer's name when the event happened (audit
    # text, kept as written), not a reference to a current identity.
    refs = Enum.flat_map(~w(request review), &event_reference(&1, r, path, targets))

    needs_version =
      r["action"] in ~w(version_submitted review_requested review_submitted finalize_proposed proposal_withdrawn approved finalized proposal_rejected)

    errors ++
      refs ++
      if(needs_version and is_nil(r["version"]),
        do: [error("#{path}.version", "this action needs a version")],
        else: []
      )
  end

  defp event_types(action) do
    case action do
      "created" ->
        %{change_id: :change_id}

      "change_id_changed" ->
        %{from: :change_id, to: :change_id}

      "review_requested" ->
        %{request: :positive, reviewer: :name}

      "review_request_closed" ->
        %{
          request: :positive,
          status: {:enum, ~w(cancelled lapsed)},
          reason: {:optional, {:enum, ~w(superseded withdrawn abandoned)}}
        }

      "review_submitted" ->
        %{review: :positive, request: {:optional, :positive}}

      "finalize_proposed" ->
        %{summary: {:bytes, 16_384}}

      _ ->
        %{}
    end
  end

  defp event_reference(field, r, path, targets) do
    value = r["data"][field]

    target =
      %{"request" => "spec_review_requests", "review" => "spec_reviews"}[field]

    if is_nil(value) or Map.has_key?(targets[target], {r["task"], value}),
      do: [],
      else: [error("#{path}.data.#{field}", "unresolved reference")]
  end

  defp sequences(data) do
    unique =
      data["specs"]
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), MapSet.new(), []}, fn {r, i}, {tasks, names, errors} ->
        more =
          if MapSet.member?(tasks, r["task"]) or MapSet.member?(names, r["change_id"]),
            do: [error("specs[#{i}]", "duplicate task or change_id")],
            else: []

        {MapSet.put(tasks, r["task"]), MapSet.put(names, r["change_id"]), errors ++ more}
      end)
      |> elem(2)

    unique ++
      Enum.flat_map(Format.spec_collections() -- ["specs"], &collection_sequences(data, &1))
  end

  defp collection_sequences(data, collection) do
    data[collection]
    |> Enum.with_index()
    |> Enum.group_by(fn {r, _} -> group(collection, r) end)
    |> Enum.flat_map(fn {_group, entries} -> sequence_errors(entries, collection) end)
  end

  defp sequence_errors(entries, collection) do
    errors =
      entries
      |> Enum.sort_by(fn {r, _} -> r["n"] end)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{r, i}, n} ->
        if r["n"] == n,
          do: [],
          else: [error("#{collection}[#{i}].n", "sequence must be contiguous from 1")]
      end)

    limit =
      case collection do
        "spec_versions" -> 200
        "spec_issues" -> 100
        "spec_issue_notes" -> 100
        _ -> 2_147_483_647
      end

    errors ++
      if(length(entries) > limit, do: [error(collection, "record limit exceeded")], else: [])
  end

  defp group("spec_issues", r), do: {r["task"], r["review"]}
  defp group("spec_issue_notes", r), do: {r["task"], r["review"], r["issue"]}
  defp group(_, r), do: r["task"]

  defp states(data) do
    data["specs"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {spec, i} ->
      events = Enum.filter(data["spec_events"], &(&1["task"] == spec["task"]))
      notes = Enum.filter(data["spec_issue_notes"], &(&1["task"] == spec["task"]))
      requests = Enum.filter(data["spec_review_requests"], &(&1["task"] == spec["task"]))
      replay = SpecState.replay(events, notes)
      expected = SpecState.portable(replay.spec)

      errors =
        if Map.take(spec, Map.keys(expected)) == expected, do: [], else: [mismatch("specs[#{i}]")]

      versions = Enum.count(data["spec_versions"], &(&1["task"] == spec["task"]))

      errors =
        if spec["latest_version"] == versions,
          do: errors,
          else: [mismatch("specs[#{i}].latest_version") | errors]

      errors ++ request_states(requests, replay.requests, data)
    end)
  end

  defp request_states(requests, expected, data) do
    errors =
      if map_size(expected) == length(requests), do: [], else: [mismatch("spec_review_requests")]

    errors ++
      Enum.flat_map(requests, fn r ->
        state = expected[r["n"]]

        mutable = %{
          version: r["version"],
          status: SpecState.atom(r["status"]),
          close_reason: SpecState.atom(r["close_reason"]),
          review: r["review"]
        }

        closed =
          if r["status"] == "requested",
            do: is_nil(r["closed_at"]),
            else: not is_nil(r["closed_at"])

        index = Enum.find_index(data["spec_review_requests"], &(&1 == r))
        if state == mutable and closed, do: [], else: [mismatch("spec_review_requests[#{index}]")]
      end)
  end

  defp mismatch(path),
    do: %{
      path: path,
      message: "mutable fields disagree with audit replay",
      reason: "spec_state_mismatch"
    }

  defp error(path, message), do: %{path: path, message: message}
end
