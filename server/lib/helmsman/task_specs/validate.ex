defmodule Helmsman.TaskSpecs.Validate do
  @moduledoc """
  The structure check of a spec version (`add-spec-workflow` decision 4):
  everything `openspec validate --strict` (1.10) checks, warnings counted
  as errors, plus the Helmsman rules on `proposal.md` and `tasks.md`.
  Where OpenSpec's behaviour is unclear the stricter side is taken
  (requirement names compare case-insensitively, MODIFIED and REMOVED of
  one name conflict), so a version that passes here passes the CLI too.

  A pure function over `%{path => content}`; the lines inside fenced code
  blocks (``` or ~~~, closed by a fence of the same character that is not
  shorter) are never headings and are no requirement text.
  """

  @type error :: %{
          file: String.t(),
          line: pos_integer() | nil,
          rule: String.t(),
          message: String.t()
        }
  @type result :: %{valid: boolean(), errors: [error()]}

  @section ~r/^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements\s*$/
  @requirement ~r/^### Requirement:\s*(.+?)\s*$/
  @scenario ~r/^#### Scenario:/
  @heading ~r/^(\#{1,6})\s/
  @normative ~r/(?<![A-Za-z0-9_])(SHALL|MUST)(?![A-Za-z0-9_])/
  @fence ~r/^ {0,3}(`{3,}|~{3,})(.*)$/
  @from ~r/^\s*-\s*FROM:\s*`### Requirement:\s*(.+?)\s*`\s*$/
  @to ~r/^\s*-\s*TO:\s*`### Requirement:\s*(.+?)\s*`\s*$/
  @renamed_marker ~r/^\s*-\s*(FROM|TO):/
  @task_item ~r/^\s*[-*] \[[ xX]\]/

  @doc "Validates the files of a version; see the module documentation."
  @spec run(%{String.t() => String.t()} | [{String.t(), String.t()}]) :: result()
  def run(files) do
    files = Map.new(files)

    spec_files =
      files
      |> Enum.filter(fn {path, _} -> spec_path?(path) end)
      |> Enum.sort()

    {spec_errors, deltas} =
      Enum.reduce(spec_files, {[], 0}, fn {path, content}, {errors, count} ->
        {file_errors, file_count} = check_spec(path, content)
        {errors ++ file_errors, count + file_count}
      end)

    no_deltas =
      if deltas == 0,
        do: [
          error(
            "specs",
            nil,
            "no_deltas",
            "The change must have at least one delta: a specs/<capability>/spec.md " <>
              "with \"## ADDED Requirements\" (or MODIFIED, REMOVED, RENAMED) and requirements"
          )
        ],
        else: []

    errors =
      Enum.sort_by(
        check_proposal(files["proposal.md"]) ++
          check_tasks(files["tasks.md"]) ++ no_deltas ++ spec_errors,
        &{&1.file, &1.line || 0, &1.rule}
      )

    %{valid: errors == [], errors: errors}
  end

  @doc "True for the path of a spec delta file: `specs/**/spec.md`."
  @spec spec_path?(String.t()) :: boolean()
  def spec_path?(path),
    do: String.starts_with?(path, "specs/") and Path.basename(path) == "spec.md"

  defp error(file, line, rule, message),
    do: %{file: file, line: line, rule: rule, message: message}

  # Lines numbered from 1, each `{number, text, fenced?}`.
  defp lines(content) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.map_reduce(nil, fn {text, n}, fence -> fence_step(text, n, fence) end)
    |> elem(0)
  end

  # `{line, fence}`: the line marked fenced or not, and the fence open
  # after it. An info string with a backtick opens no backtick fence.
  defp fence_step(text, n, nil) do
    case Regex.run(@fence, text) do
      [_, "`" <> _ = marker, info] ->
        if String.contains?(info, "`"),
          do: {{n, text, false}, nil},
          else: {{n, text, true}, marker}

      [_, marker, _info] ->
        {{n, text, true}, marker}

      nil ->
        {{n, text, false}, nil}
    end
  end

  defp fence_step(text, n, open) do
    case Regex.run(@fence, text) do
      [_, marker, rest] ->
        {{n, text, true}, if(closes?(open, marker, rest), do: nil, else: open)}

      nil ->
        {{n, text, true}, open}
    end
  end

  defp closes?(open, marker, rest) do
    String.first(open) == String.first(marker) and byte_size(marker) >= byte_size(open) and
      String.trim(rest) == ""
  end

  # proposal.md: non-empty `## Why` and `## What Changes`.
  defp check_proposal(nil),
    do: [error("proposal.md", nil, "missing_proposal", "proposal.md is missing")]

  defp check_proposal(content) do
    lines = lines(content)

    for title <- ["Why", "What Changes"], not section_filled?(lines, title) do
      error(
        "proposal.md",
        section_line(lines, title),
        "proposal_sections",
        "proposal.md must have a non-empty \"## #{title}\" section"
      )
    end
  end

  defp section_line(lines, title) do
    Enum.find_value(lines, fn {n, text, fenced} ->
      if not fenced and String.trim_trailing(text) == "## " <> title, do: n
    end)
  end

  defp section_filled?(lines, title) do
    case Enum.split_while(lines, fn {_n, text, fenced} ->
           fenced or String.trim_trailing(text) != "## " <> title
         end) do
      {_before, [_heading | rest]} ->
        rest
        |> Enum.take_while(fn {_n, text, fenced} ->
          fenced or not Regex.match?(~r/^\#{1,2}\s/, text)
        end)
        |> Enum.any?(fn {_n, text, _fenced} -> String.trim(text) != "" end)

      {_all, []} ->
        false
    end
  end

  defp check_tasks(nil), do: [error("tasks.md", nil, "missing_tasks", "tasks.md is missing")]

  defp check_tasks(content) do
    if Enum.any?(lines(content), fn {_n, text, fenced} ->
         not fenced and Regex.match?(@task_item, text)
       end),
       do: [],
       else: [
         error(
           "tasks.md",
           nil,
           "tasks_no_items",
           "tasks.md must have at least one \"- [ ]\" item"
         )
       ]
  end

  # One spec.md: its errors and the number of parsed delta entries.
  defp check_spec(path, content) do
    sections = sections(lines(content))

    {errors, count} =
      Enum.reduce(sections, {[], 0}, fn section, {errors, count} ->
        {section_errors, n} = check_section(path, section)
        {errors ++ section_errors, count + n}
      end)

    errors = errors ++ duplicates(path, sections) ++ conflicts(path, sections)

    if count == 0 do
      {[
         error(
           path,
           nil,
           "no_delta_sections",
           "#{path} must have \"## ADDED Requirements\" (or MODIFIED, REMOVED, RENAMED) " <>
             "with at least one \"### Requirement:\" entry"
         )
         | errors
       ], 0}
    else
      {errors, count}
    end
  end

  # `[%{kind, line, lines}]` for each delta section, up to the next level 1
  # or 2 heading.
  defp sections(lines) do
    lines
    |> Enum.chunk_while(
      nil,
      fn {n, text, fenced} = line, acc ->
        match = not fenced && Regex.run(@section, text)

        cond do
          match ->
            section = %{kind: match |> Enum.at(1) |> String.downcase(), line: n, lines: []}
            flush(acc, section, :lines)

          not fenced and Regex.match?(~r/^\#{1,2}\s/, text) ->
            flush(acc, nil, :lines)

          acc == nil ->
            {:cont, nil}

          true ->
            {:cont, %{acc | lines: [line | acc.lines]}}
        end
      end,
      &flush(&1, nil, :lines)
    )
  end

  # Emits the finished chunk `acc` (its `key` list was built in reverse)
  # and continues with `next`.
  defp flush(nil, next, _key), do: {:cont, next}
  defp flush(acc, next, key), do: {:cont, Map.update!(acc, key, &Enum.reverse/1), next}

  # A section's requirements: `%{name, line, body}` where `body` is the
  # lines until the next level 1-3 heading.
  defp requirements(section_lines) do
    section_lines
    |> Enum.chunk_while(
      nil,
      fn {_n, text, fenced} = line, acc ->
        match = not fenced && Regex.run(@requirement, text)

        cond do
          match ->
            flush(acc, %{name: Enum.at(match, 1), line: elem(line, 0), body: []}, :body)

          not fenced and Regex.match?(~r/^\#{1,3}\s/, text) ->
            flush(acc, nil, :body)

          acc == nil ->
            {:cont, nil}

          true ->
            {:cont, %{acc | body: [line | acc.body]}}
        end
      end,
      &flush(&1, nil, :body)
    )
  end

  defp check_section(path, %{kind: "renamed"} = section), do: check_renamed(path, section)

  defp check_section(_path, %{kind: "removed"} = section),
    do: {[], length(requirements(section.lines))}

  defp check_section(path, %{kind: kind} = section) do
    requirements = requirements(section.lines)
    label = String.upcase(kind)
    {Enum.flat_map(requirements, &check_requirement(path, label, &1)), length(requirements)}
  end

  defp check_requirement(path, label, %{name: name, line: line, body: body}) do
    {text, rest} = Enum.split_while(body, fn line -> not scenario?(line) end)

    text =
      for {_n, text, false} <- text,
          not Regex.match?(@heading, text),
          String.trim(text) != "",
          do: text

    scenario = rest != []

    [
      text == [] &&
        error(
          path,
          line,
          "requirement_text_missing",
          ~s(#{label} "#{name}" is missing requirement text)
        ),
      (text != [] and not Enum.any?(text, &Regex.match?(@normative, &1))) &&
        error(
          path,
          line,
          "requirement_no_normative",
          ~s(#{label} "#{name}" must contain SHALL or MUST in its requirement text)
        ),
      not scenario &&
        error(
          path,
          line,
          "requirement_no_scenario",
          ~s(#{label} "#{name}" must include at least one "#### Scenario:" block)
        )
    ]
    |> Enum.filter(& &1)
  end

  defp scenario?({_n, text, false}), do: Regex.match?(@scenario, text)
  defp scenario?(_line), do: false

  # RENAMED: `- FROM:` / `- TO:` pairs, in that order.
  defp check_renamed(path, section) do
    {errors, pending, pairs} =
      Enum.reduce(section.lines, {[], nil, 0}, fn
        {_n, _text, true}, acc ->
          acc

        {n, text, false}, {errors, pending, pairs} ->
          cond do
            Regex.match?(@from, text) and pending == nil ->
              {errors, n, pairs}

            Regex.match?(@to, text) and pending != nil ->
              {errors, nil, pairs + 1}

            Regex.match?(@renamed_marker, text) ->
              {[renamed_error(path, n) | errors], nil, pairs}

            true ->
              {errors, pending, pairs}
          end
      end)

    errors = if pending, do: [renamed_error(path, pending) | errors], else: errors
    {Enum.reverse(errors), pairs}
  end

  defp renamed_error(path, line) do
    error(
      path,
      line,
      "renamed_malformed",
      "RENAMED entries must be pairs of \"- FROM: `### Requirement: A`\" and " <>
        "\"- TO: `### Requirement: B`\""
    )
  end

  defp norm(name), do: name |> String.trim() |> String.downcase()

  defp names(%{kind: "renamed"}), do: []
  defp names(section), do: requirements(section.lines)

  defp duplicates(path, sections) do
    for section <- sections,
        {_name, [_first | rest]} <- Enum.group_by(names(section), &norm(&1.name)),
        req <- rest do
      error(
        path,
        req.line,
        "duplicate_requirement",
        ~s(Requirement "#{req.name}" appears more than once in #{String.upcase(section.kind)})
      )
    end
  end

  # The same name in two of ADDED, MODIFIED and REMOVED of one file.
  defp conflicts(path, sections) do
    sections
    |> Enum.filter(&(&1.kind in ["added", "modified", "removed"]))
    |> Enum.flat_map(fn section -> Enum.map(names(section), &{section.kind, &1}) end)
    |> Enum.group_by(fn {_kind, req} -> norm(req.name) end)
    |> Enum.flat_map(fn {_name, entries} ->
      kinds = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      if length(kinds) > 1 do
        {_kind, req} = entries |> Enum.sort_by(fn {_k, r} -> r.line end) |> List.last()
        labels = Enum.map_join(kinds, " and ", &String.upcase/1)

        [
          error(
            path,
            req.line,
            "requirement_conflict",
            ~s(Requirement "#{req.name}" is present in both #{labels})
          )
        ]
      else
        []
      end
    end)
  end
end
