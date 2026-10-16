defmodule Helmsman.McpServers.Entry do
  @moduledoc "MCP entry validation and write-only field projections. Errors contain paths, never values."
  @known ~w(type command args env cwd url headers)
  @lists ~w(tools enabled_tools disabled_tools alwaysAllow autoApprove)
  @scalars ~w(timeout startup_timeout_sec startup_timeout_ms tool_timeout_sec disabled enabled trust disableToolCache)
  @reference ~r/\$\{env:([A-Za-z_][A-Za-z0-9_]{0,127})\}/
  @name ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @variable ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @header ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/

  def type(entry) when is_map(entry),
    do: entry["type"] || if(entry["command"], do: "stdio", else: "http")

  def type(_), do: nil

  def references(value) when is_binary(value),
    do: Regex.scan(@reference, value, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

  def references(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&references/1) |> Enum.uniq()

  def references(value) when is_list(value),
    do: value |> Enum.flat_map(&references/1) |> Enum.uniq()

  def references(_), do: []
  def contains_refs?(value) when is_binary(value), do: String.contains?(value, "${env:")

  def contains_refs?(value) when is_map(value),
    do: Enum.any?(Map.values(value), &contains_refs?/1)

  def contains_refs?(value) when is_list(value), do: Enum.any?(value, &contains_refs?/1)
  def contains_refs?(_), do: false
  def reserved?(name), do: String.starts_with?(String.upcase(name), "HELMSMAN_")

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(@name, name) and String.downcase(name) != "helmsman"

  def public?(key, value) when key in @lists,
    do: is_list(value) and Enum.all?(value, &is_binary/1)

  def public?(key, value) when key in @scalars, do: is_number(value) or is_boolean(value)
  def public?(_, _), do: false

  def validate(servers, old \\ %{}, limit \\ 32_768)
  def validate(nil, _old, _limit), do: {:ok, nil}

  def validate(servers, old, limit) when is_map(servers) do
    {merged, errors} =
      Enum.reduce(servers, {%{}, []}, fn {name, entry}, {acc, errors} ->
        path = if is_binary(name), do: name, else: "name"
        {entry, keep_errors} = merge_keep(path, entry, old || %{})

        {Map.put(acc, name, entry),
         errors ++
           keep_errors ++
           entry_errors(path, entry) ++
           if(is_binary(name), do: [], else: [{"name", "invalid server name"}])}
      end)

    folded =
      Enum.map(Map.keys(servers), fn name ->
        if is_binary(name), do: String.downcase(name), else: nil
      end)

    errors =
      errors ++
        if(length(Enum.uniq(folded)) != length(folded),
          do: [{"name", "names must be unique ignoring case"}],
          else: []
        )

    errors =
      errors ++
        if(within_limit?(merged, limit),
          do: [],
          else: [{"", "configuration is too large or invalid JSON"}]
        )

    if errors == [], do: {:ok, merged}, else: {:error, errors}
  end

  def validate(_, _, _), do: {:error, [{"", "must be an object"}]}

  def editable(servers) do
    Map.new(servers || %{}, fn {name, entry} ->
      {name, if(is_map(entry), do: editable_entry(name, entry), else: %{})}
    end)
  end

  defp editable_entry(name, entry) do
    Map.new(entry, fn
      {key, values} when key in ["env", "headers"] and is_map(values) ->
        {key,
         Map.new(values, fn {k, value} ->
           {k,
            if(is_binary(value) and references(value) != [], do: value, else: %{"$keep" => name})}
         end)}

      {key, value} ->
        {key, if(readable?(key, value), do: value, else: %{"$keep" => name})}
    end)
  end

  defp readable?(key, value) when key in ~w(type command cwd url), do: is_binary(value)
  defp readable?("args", value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp readable?(key, value), do: public?(key, value)

  defp merge_keep(name, entry, old) when is_map(entry) do
    Enum.reduce(entry, {%{}, []}, fn
      {key, values}, {acc, errors} when key in ["env", "headers"] and is_map(values) ->
        {values, more} =
          Enum.reduce(values, {%{}, []}, fn {k, v}, {vs, es} ->
            {value, more} = kept(v, old, [key, k], "#{name}.#{key}.#{k}")
            {Map.put(vs, k, value), es ++ more}
          end)

        {Map.put(acc, key, values), errors ++ more}

      {key, value}, {acc, errors} ->
        {value, more} =
          if key in @known, do: {value, []}, else: kept(value, old, [key], "#{name}.#{key}")

        {Map.put(acc, key, value), errors ++ more}
    end)
  end

  defp merge_keep(_name, entry, _old), do: {entry, []}

  defp kept(%{"$keep" => source} = marker, old, path, field) when map_size(marker) == 1 do
    case fetch_path(old[source], path) do
      {:ok, value} -> {value, []}
      :error -> {nil, [{field, "no stored value to keep"}]}
    end
  end

  defp kept(value, _old, _path, _field), do: {value, []}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    with {:ok, value} <- Map.fetch(map, key), do: fetch_path(value, rest)
  end

  defp fetch_path(value, []), do: {:ok, value}
  defp fetch_path(_, _), do: :error

  defp entry_errors(name, entry) when is_map(entry) do
    base =
      if valid_name?(name),
        do: [],
        else: [
          {"#{name}.name",
           if(is_binary(name) and String.downcase(name) == "helmsman",
             do: "helmsman is reserved",
             else: "invalid server name"
           )}
        ]

    typed =
      case type(entry) do
        "stdio" ->
          string(entry["command"], "#{name}.command", 1, 1_024) ++
            args(entry["args"], name) ++
            pairs(entry["env"], name, "env", 64, @variable) ++ cwd(entry["cwd"], name)

        type when type in ["http", "sse"] ->
          url(entry["url"], name) ++ pairs(entry["headers"], name, "headers", 32, @header)

        _ ->
          [{"#{name}.type", "must be stdio, http or sse"}]
      end

    base ++ typed ++ reference_errors(Map.take(entry, @known), name)
  end

  defp entry_errors(name, _), do: [{"#{name}", "must be an object"}]

  defp string(v, path, min, max),
    do:
      if(is_binary(v) and byte_size(v) in min..max,
        do: [],
        else: [{path, "must be a string of #{min}-#{max} bytes"}]
      )

  defp args(nil, _), do: []

  defp args(values, name) when is_list(values) and length(values) <= 64,
    do:
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> string(v, "#{name}.args.#{i}", 0, 4_096) end)

  defp args(_, name), do: [{"#{name}.args", "must contain at most 64 strings"}]
  defp pairs(nil, _, _, _, _), do: []

  defp pairs(values, name, field, max, regex) when is_map(values) and map_size(values) <= max do
    Enum.flat_map(values, fn {key, value} ->
      if is_binary(key) and Regex.match?(regex, key),
        do: string(value, "#{name}.#{field}.#{key}", 0, 8_192),
        else: [{"#{name}.#{field}", "invalid key"}]
    end)
  end

  defp pairs(_, name, field, max, _),
    do: [{"#{name}.#{field}", "must be an object of at most #{max} entries"}]

  defp cwd(nil, _), do: []

  defp cwd(value, name),
    do:
      if(
        is_binary(value) and (String.starts_with?(value, "/") or String.starts_with?(value, "~/")),
        do: [],
        else: [{"#{name}.cwd", "must be an absolute path or start with ~/"}]
      )

  defp url(value, name) do
    valid =
      is_binary(value) and byte_size(value) <= 2_048 and
        URI.parse(value).scheme in ["http", "https"] and is_binary(URI.parse(value).host) and
        URI.parse(value).host != ""

    if valid, do: [], else: [{"#{name}.url", "must be an absolute HTTP or HTTPS URL"}]
  end

  defp reference_errors(value, path) when is_map(value),
    do: Enum.flat_map(value, fn {k, v} -> reference_errors(v, "#{path}.#{k}") end)

  defp reference_errors(value, path) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> reference_errors(v, "#{path}.#{i}") end)

  defp reference_errors(value, path) when is_binary(value) do
    if Enum.any?(references(value), &reserved?/1),
      do: [{path, "HELMSMAN_ variables cannot be referenced"}],
      else: []
  end

  defp reference_errors(_, _), do: []

  defp within_limit?(value, limit) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json) <= limit
      _ -> false
    end
  rescue
    _ -> false
  end
end
