defmodule HelmsmanWeb.TaskEvidence do
  @moduledoc """
  Turns the transition panel's form params into the `opts` of
  `Helmsman.Tasks.transition/4` (design D8). Pure; the domain layer validates the
  values (commit format, lengths).

  Params: `"kind"` (`"evidence"` or `"reason"`), `"to"` (target status, for a reason),
  `"commits"` (split on blanks and commas), `"result"` (`"none"` / `"passed"` /
  `"failed"`), `"command"`, `"summary"` and `"comment"`. A reason panel requires the
  comment, which becomes the transition's reason feedback (`feedback: %{kind,
  content}`, the kind from `HelmsmanWeb.TaskTransitions.reason_kind/1`); the evidence
  panels keep it as the transition's `comment`. With a test result the command is
  required.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  alias HelmsmanWeb.TaskTransitions

  @spec parse(map()) :: {:ok, map()} | {:error, %{atom() => String.t()}}
  def parse(params) do
    reason? = params["kind"] == "reason"
    comment = String.trim(params["comment"] || "")

    errors =
      %{}
      |> put_if(reason? and comment == "", :comment, dgettext("ui", "请填写原因"))
      |> check_tests(params)

    cond do
      errors != %{} ->
        {:error, errors}

      reason? ->
        kind = TaskTransitions.reason_kind(params["to"])
        {:ok, %{feedback: %{kind: kind, content: params["comment"]}}}

      true ->
        opts =
          %{}
          |> put_present(:comment, comment)
          |> put_present(:commits, commits(params["commits"]))
          |> put_present(:tests, tests(params))

        {:ok, opts}
    end
  end

  defp check_tests(errors, params) do
    put_if(
      errors,
      params["result"] in ~w(passed failed) and String.trim(params["command"] || "") == "",
      :command,
      dgettext("ui", "不能为空")
    )
  end

  defp commits(nil), do: []
  defp commits(raw), do: String.split(raw, ~r/[\s,]+/, trim: true)

  defp tests(%{"result" => result} = params) when result in ~w(passed failed) do
    %{
      command: String.trim(params["command"] || ""),
      passed: result == "passed",
      summary: String.trim(params["summary"] || "")
    }
  end

  defp tests(_params), do: nil

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp put_present(map, _key, value) when value in [nil, "", []], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
