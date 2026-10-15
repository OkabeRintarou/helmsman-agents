defmodule HelmsmanWeb.SpecArchiveStub do
  @moduledoc """
  PLACEHOLDER(add-spec-workflow 3.x): stands in for `Helmsman.TaskSpecs.export_archive/3`
  and `import_archive/4` (`add-spec-workflow` decision 18, `add-spec-workflow-ui`
  domain-request-1 R4, R5) until the domain's third group is merged. The tests put it in
  `config :helmsman, :spec_archives` (async: false).

  Export returns a real `tar.gz` / `zip` of the version through the real reads; import
  reads a `tar.gz` in memory (`invalid_archive` for a link, an absolute path or `..`),
  drops the common directory prefix, ignores `.openspec.yaml` and `reviews/`, warns about
  other paths, and submits the files as a complete new version through the real
  `submit_version/3` (a dry run adds the diff against the base).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.TaskSpecs
  alias Helmsman.TaskSpecs.Diff

  @allowed ~r"\A(proposal|design|tasks)\.md\z|\Aspecs/[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*){0,2}/spec\.md\z"

  def export_archive(scope, ident, opts) do
    with {:ok, data} <- TaskSpecs.get(scope, ident, version: opts[:version]),
         %{} = version <- data.version || {:error, {:spec, :no_version}} do
      id = data.spec.change_id
      entries = for f <- version.files, do: {~c"#{id}/#{f.path}", f.content}

      {type, ext, body} =
        if opts[:format] == "zip" do
          {:ok, {_, zip}} = :zip.create(~c"x.zip", entries, [:memory])
          {"application/zip", "zip", zip}
        else
          {"application/gzip", "tar.gz", tar(entries)}
        end

      {:ok, %{filename: "#{id}-v#{version.number}.#{ext}", content_type: type, body: body}}
    end
  end

  def import_archive(scope, ident, binary, opts) do
    with {:ok, entries} <- untar(binary) do
      {files, warnings} = sort(entries)
      base = opts[:base_version]
      base_files = if base > 0, do: version_files(scope, ident, base), else: %{}

      attrs = %{
        base_version: base,
        files: files,
        remove: Map.keys(base_files) -- Map.keys(files),
        note: opts[:note] || "",
        dry_run: opts[:dry_run] == true
      }

      with {:ok, result} <- TaskSpecs.submit_version(scope, ident, attrs) do
        result = Map.put(result, :warnings, warnings)
        {:ok, preview(result, opts[:dry_run], ident, base_files, files, base)}
      end
    end
  end

  defp preview(result, true, ident, base_files, files, base) do
    change_id = if base == 0, do: String.downcase(ident)
    diff = Map.merge(%{from: base, to: nil}, Diff.run(base_files, files))
    Map.merge(result, %{dry_run: true, base_version: base, change_id: change_id, diff: diff})
  end

  defp preview(result, _dry_run, _ident, _base_files, _files, _base), do: result

  @doc "A `tar.gz` of `[{name, content}]` (charlist names), in memory."
  def tar(entries) do
    path =
      Path.join(System.tmp_dir!(), "spec-archive-#{System.unique_integer([:positive])}.tar.gz")

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    body = File.read!(path)
    File.rm!(path)
    body
  end

  defp version_files(scope, ident, n) do
    {:ok, %{version: %{files: files}}} = TaskSpecs.get(scope, ident, version: n)
    Map.new(files, &{&1.path, &1.content})
  end

  defp untar(binary) do
    with {:ok, table} <- :erl_tar.table({:binary, binary}, [:compressed, :verbose]),
         true <- Enum.all?(table, &plain?/1),
         {:ok, entries} <- :erl_tar.extract({:binary, binary}, [:memory, :compressed]) do
      {:ok, Enum.map(entries, fn {name, content} -> {to_string(name), content} end)}
    else
      _ -> {:error, {:spec, :invalid_archive, "link, absolute path or .."}}
    end
  end

  defp plain?({name, type, _size, _mtime, _mode, _uid, _gid}) do
    name = to_string(name)

    type in [:regular, :directory] and not String.starts_with?(name, "/") and
      ".." not in String.split(name, "/")
  end

  defp sort(entries) do
    names = Enum.map(entries, &elem(&1, 0))
    prefix = prefix(names)

    Enum.reduce(entries, {%{}, []}, fn {name, content}, {files, warnings} ->
      path = String.replace_prefix(name, prefix, "")

      cond do
        path =~ @allowed -> {Map.put(files, path, content), warnings}
        path == ".openspec.yaml" or String.starts_with?(path, "reviews/") -> {files, warnings}
        true -> {files, warnings ++ [path]}
      end
    end)
  end

  defp prefix(names) do
    names
    |> Enum.map(&(&1 |> String.split("/") |> Enum.drop(-1)))
    |> Enum.reduce(fn dirs, acc ->
      acc |> Enum.zip(dirs) |> Enum.take_while(fn {a, b} -> a == b end) |> Enum.map(&elem(&1, 0))
    end)
    |> case do
      [] -> ""
      parts -> Enum.join(parts, "/") <> "/"
    end
  end
end
