defmodule HelmsmanMCP.SpecPresent do
  @moduledoc """
  The JSON views of task specs (`add-spec-workflow` decision 20) for the
  MCP tools and REST: times as ISO 8601, a diff's hunks as unified diff
  text.
  """

  @max_inline_bytes 256 * 1024

  @doc "The largest version `get_spec` returns whole without `files`."
  @spec max_inline_bytes() :: pos_integer()
  def max_inline_bytes, do: @max_inline_bytes

  @doc "A spec summary (`Helmsman.TaskSpecs.summary/2`), or nil."
  @spec summary(map() | nil) :: map() | nil
  def summary(nil), do: nil

  def summary(%{} = spec) do
    %{
      task: spec.task,
      change_id: spec.change_id,
      status: spec.status,
      latest_version: spec.latest_version,
      final_version: spec.final_version,
      finalize_mode: spec.mode,
      proposal: spec.proposal && %{spec.proposal | at: time(spec.proposal.at)},
      pending_reviews: Enum.map(spec.pending_reviews, &%{&1 | at: time(&1.at)}),
      unresolved: spec.unresolved,
      latest_valid: spec.latest_valid,
      lock_version: spec.lock_version
    }
  end

  @doc """
  The spec part of a task view (`get_task`, spec-tools 「任务视图的规格摘要」):
  counts instead of lists, or nil.
  """
  @spec brief(map() | nil) :: map() | nil
  def brief(nil), do: nil

  def brief(%{} = spec) do
    %{
      change_id: spec.change_id,
      status: spec.status,
      latest_version: spec.latest_version,
      final_version: spec.final_version,
      finalize_mode: spec.mode,
      unresolved_issues: spec.unresolved.p1 + spec.unresolved.p2 + spec.unresolved.p3,
      pending_reviews: length(spec.pending_reviews)
    }
  end

  @doc """
  `Helmsman.TaskSpecs.get/3`. `whole?`: the caller did not name `files`,
  so a version above 256 KB comes as its file list only.
  """
  @spec get(map(), boolean()) :: map()
  def get(%{} = result, whole?) do
    version = result.version && version(result.version, whole?)

    %{
      spec: summary(result.spec),
      versions:
        Enum.map(result.versions, fn v ->
          %{
            number: v.number,
            author: v.author,
            at: time(v.at),
            note: v.note,
            valid: v.valid,
            finalized: Enum.map(v.finalized, &%{&1 | at: time(&1.at)})
          }
        end),
      version: version
    }
  end

  defp version(version, whole?) do
    total = version.files |> Enum.map(& &1.bytes) |> Enum.sum()

    if whole? and total > @max_inline_bytes do
      %{
        number: version.number,
        validation: version.validation,
        files: Enum.map(version.files, &Map.take(&1, [:path, :bytes])),
        truncated:
          "The files total #{total} bytes, more than 256 KB: only the list is shown. " <>
            "Read them in batches with get_spec(files: [...])."
      }
    else
      %{
        number: version.number,
        validation: version.validation,
        files:
          for file <- version.files do
            if is_nil(file.content), do: Map.take(file, [:path, :bytes]), else: file
          end
      }
    end
  end

  @doc "`Helmsman.TaskSpecs.diff/4`: each file's hunks as unified diff text."
  @spec diff(map()) :: map()
  def diff(%{} = diff) do
    %{
      from: diff.from,
      to: diff.to,
      truncated: diff.truncated,
      files: Enum.map(diff.files, &diff_file/1)
    }
  end

  defp diff_file(file) do
    file
    |> Map.take([:path, :change, :old_lines, :new_lines])
    |> Map.put(:diff, Enum.map_join(file.hunks, &hunk/1))
  end

  defp hunk(hunk) do
    lines =
      Enum.map_join(hunk.lines, fn
        {:eq, text} -> " " <> text <> "\n"
        {:del, text} -> "-" <> text <> "\n"
        {:ins, text} -> "+" <> text <> "\n"
      end)

    "@@ -#{hunk.old_start},#{hunk.old_lines} +#{hunk.new_start},#{hunk.new_lines} @@\n" <> lines
  end

  @doc "`Helmsman.TaskSpecs.import_archive/4`: a dry run's diff as `diff/1` shows it."
  @spec import_result(map()) :: map()
  def import_result(%{diff: %{} = diff} = result), do: %{result | diff: diff(diff)}
  def import_result(result), do: result

  @doc "`Helmsman.TaskSpecs.reviews/3`."
  @spec reviews(map()) :: map()
  def reviews(%{requests: requests, reviews: reviews}) do
    %{
      requests: Enum.map(requests, &times(&1, [:at, :closed_at])),
      reviews:
        Enum.map(reviews, fn review ->
          review
          |> Map.drop([:reviewer_user_id])
          |> times([:at])
          |> Map.update!(:issues, fn issues ->
            Enum.map(issues, fn issue ->
              Map.update!(issue, :notes, fn notes -> Enum.map(notes, &times(&1, [:at])) end)
            end)
          end)
        end)
    }
  end

  @doc "`Helmsman.TaskSpecs.events/2`."
  @spec events([map()]) :: [map()]
  def events(events), do: Enum.map(events, &times(&1, [:at]))

  @doc "`Helmsman.TaskSpecs.attention/1`."
  @spec attention(map()) :: map()
  def attention(%{} = attention) do
    Map.new(attention, fn {key, items} -> {key, Enum.map(items, &times(&1, [:at]))} end)
  end

  defp times(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} -> Map.put(acc, key, time(value))
        :error -> acc
      end
    end)
  end

  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp time(other), do: other
end
