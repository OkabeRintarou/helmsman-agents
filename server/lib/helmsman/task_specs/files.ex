defmodule Helmsman.TaskSpecs.Files do
  @moduledoc """
  The file rules of a spec version (`task-specs`「版本与文件」): allowed
  paths, contents, limits (in bytes), and merging a submission into its
  base version. Pure.
  """

  @max_file_bytes 256 * 1024
  @max_files 64
  @max_total_bytes 1024 * 1024
  @segment ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  @type problem :: %{path: String.t() | nil, message: String.t()}

  @doc "The limits: file bytes, files per version, bytes per version."
  @spec limits() :: %{file_bytes: pos_integer(), files: pos_integer(), total_bytes: pos_integer()}
  def limits, do: %{file_bytes: @max_file_bytes, files: @max_files, total_bytes: @max_total_bytes}

  @doc """
  Whether `path` may be a file of a version: `proposal.md`, `design.md`,
  `tasks.md` or `specs/<capability>/spec.md` with 1–3 segments.
  """
  @spec allowed_path?(term()) :: boolean()
  def allowed_path?(path) when path in ["proposal.md", "design.md", "tasks.md"], do: true

  def allowed_path?("specs/" <> rest) do
    case String.split(rest, "/") do
      segments when length(segments) in 2..4 ->
        case Enum.split(segments, -1) do
          {caps, ["spec.md"]} -> Enum.all?(caps, &Regex.match?(@segment, &1))
          _other -> false
        end

      _other ->
        false
    end
  end

  def allowed_path?(_path), do: false

  @doc """
  Merges `changes` (`%{path => content}`) and `remove` (paths) into `base`
  (`%{path => content}`). Returns the files of the new version, or the
  problems: a path that is not allowed, removed but not in the base,
  both changed and removed, content that is not a string, invalid UTF-8,
  contains NUL or is over the per-file limit; more files or bytes than a
  version may have.
  """
  @spec merge(%{String.t() => String.t()}, map(), [term()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, [problem()]}
  def merge(base, changes, remove) do
    problems =
      Enum.flat_map(changes, fn {path, content} -> file_problems(path, content) end) ++
        Enum.flat_map(remove, &remove_problems(&1, base, changes))

    if problems != [] do
      {:error, problems}
    else
      files = base |> Map.drop(remove) |> Map.merge(changes)
      total = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

      cond do
        map_size(files) > @max_files ->
          {:error, [%{path: nil, message: "a version has at most #{@max_files} files"}]}

        total > @max_total_bytes ->
          {:error, [%{path: nil, message: "a version has at most 1 MB of files"}]}

        true ->
          {:ok, files}
      end
    end
  end

  defp file_problems(path, content) do
    cond do
      not allowed_path?(path) ->
        [
          %{
            path: inspect_path(path),
            message:
              "not an allowed path: proposal.md, design.md, tasks.md or specs/<capability>/spec.md"
          }
        ]

      not is_binary(content) ->
        [%{path: path, message: "content must be a string"}]

      not String.valid?(content) ->
        [%{path: path, message: "content must be valid UTF-8"}]

      String.contains?(content, <<0>>) ->
        [%{path: path, message: "content must not contain NUL"}]

      byte_size(content) > @max_file_bytes ->
        [%{path: path, message: "a file has at most 256 KB"}]

      true ->
        []
    end
  end

  defp remove_problems(path, base, changes) do
    cond do
      not is_binary(path) or not Map.has_key?(base, path) ->
        [
          %{
            path: inspect_path(path),
            message: "cannot remove a file the base version does not have"
          }
        ]

      Map.has_key?(changes, path) ->
        [%{path: path, message: "cannot both change and remove a file"}]

      true ->
        []
    end
  end

  defp inspect_path(path) when is_binary(path), do: path
  defp inspect_path(path), do: inspect(path)
end
