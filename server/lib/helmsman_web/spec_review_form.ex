defmodule HelmsmanWeb.SpecReviewForm do
  @moduledoc """
  The 写评审 panel of the spec page (add-spec-workflow-ui D9): verdict, summary and up to
  100 issues for the latest version, checked in place (byte limits, required fields,
  the line within the chosen file). The page keeps the state in
  `socket.assigns.review_form`, renders `panel/1` and handles `rev_*` events with
  `change/2`, `add_issue/1`, `remove_issue/2`, `move/3` and `put_error/2`.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.SpecErrors

  @max_summary 16_384
  @max_text 8192
  @max_anchor 200
  @max_issues 100

  @doc "A review of version `version` whose files are `%{path => line count}`."
  def new(version, files, prefill \\ %{}) do
    issues =
      case prefill do
        %{file: file} when is_binary(file) -> [issue(file, prefill[:line])]
        _ -> []
      end

    %{
      version: version,
      files: files,
      verdict: nil,
      summary: "",
      issues: issues,
      errors: %{},
      error: nil,
      stale: nil
    }
  end

  defp issue(file \\ nil, line \\ nil),
    do: %{
      severity: "P2",
      file: file,
      line: line && to_string(line),
      anchor: "",
      body: "",
      suggestion: ""
    }

  def dirty?(nil), do: false
  def dirty?(form), do: form.verdict != nil or form.summary != "" or form.issues != []

  def change(form, params) do
    issues =
      Enum.with_index(form.issues, fn i, k ->
        case get_in(params, ["issues", to_string(k)]) do
          %{} = p -> issue_change(i, p)
          _ -> i
        end
      end)

    form = %{
      form
      | verdict: params["verdict"] || form.verdict,
        summary: params["summary"] || form.summary,
        issues: issues
    }

    %{form | errors: errors(form)}
  end

  defp issue_change(i, p) do
    %{
      i
      | severity: p["severity"] || i.severity,
        file: blank(p["file"], i.file),
        line: p["line"] || i.line,
        anchor: p["anchor"] || i.anchor,
        body: p["body"] || i.body,
        suggestion: p["suggestion"] || i.suggestion
    }
  end

  defp blank(nil, old), do: old
  defp blank("", _old), do: nil
  defp blank(v, _old), do: v

  def add_issue(%{issues: issues} = form) when length(issues) >= @max_issues, do: form
  def add_issue(form), do: %{form | issues: form.issues ++ [issue()]}

  def remove_issue(form, k), do: %{form | issues: List.delete_at(form.issues, k), errors: %{}}

  def move(form, k, dir) do
    j = if dir == "up", do: k - 1, else: k + 1

    if j < 0 or j >= length(form.issues) do
      form
    else
      a = Enum.at(form.issues, k)
      b = Enum.at(form.issues, j)
      %{form | issues: form.issues |> List.replace_at(k, b) |> List.replace_at(j, a), errors: %{}}
    end
  end

  @doc "Field errors: `%{:verdict | :summary | {k, field} => text}`."
  def errors(form) do
    base =
      []
      |> add_if(byte_size(form.summary) > @max_summary, :summary, dgettext("ui", "摘要不能超过 16 KB"))

    issue_errors =
      form.issues
      |> Enum.with_index()
      |> Enum.flat_map(fn {i, k} ->
        []
        |> add_if(String.trim(i.body) == "", {k, :body}, dgettext("ui", "必填"))
        |> add_if(byte_size(i.body) > @max_text, {k, :body}, dgettext("ui", "不能超过 8 KB"))
        |> add_if(
          byte_size(i.suggestion) > @max_text,
          {k, :suggestion},
          dgettext("ui", "不能超过 8 KB")
        )
        |> add_if(byte_size(i.anchor) > @max_anchor, {k, :anchor}, dgettext("ui", "不能超过 200 字节"))
        |> add_if(
          i.file != nil and not Map.has_key?(form.files, i.file),
          {k, :file},
          dgettext("ui", "v%{v} 没有这个文件", v: form.version)
        )
        |> add_if(line_error(i, form.files) != nil, {k, :line}, line_error(i, form.files))
      end)

    Map.new(base ++ issue_errors)
  end

  defp line_error(%{line: line}, _files) when line in [nil, ""], do: nil
  defp line_error(%{file: nil}, _files), do: dgettext("ui", "先选择文件")

  defp line_error(%{file: file, line: line}, files) do
    max = Map.get(files, file, 0)

    case Integer.parse(to_string(line)) do
      {n, ""} when n >= 1 and n <= max -> nil
      _ -> dgettext("ui", "行号在 1–%{max} 之间", max: max)
    end
  end

  defp add_if(list, true, key, text), do: [{key, text} | list]
  defp add_if(list, false, _key, _text), do: list

  def valid?(form), do: form.verdict != nil and errors(form) == %{}

  @doc "The attrs of `submit_review/3`."
  def attrs(form) do
    %{
      version: form.version,
      verdict: form.verdict,
      summary: form.summary,
      issues:
        Enum.map(form.issues, fn i ->
          %{
            severity: i.severity,
            file: i.file,
            line: i.line && i.line != "" && String.to_integer(i.line),
            anchor: if(i.anchor == "", do: nil, else: i.anchor),
            body: i.body,
            suggestion: if(i.suggestion == "", do: nil, else: i.suggestion)
          }
        end)
    }
  end

  def put_error(form, {:spec, :stale_version, latest}), do: %{form | stale: latest, error: nil}

  def put_error(form, {:spec, :invalid_issues, problems}) do
    errors = Map.new(problems, &{{&1.index - 1, :issue}, &1.message})
    %{form | errors: errors, error: SpecErrors.message({:spec, :invalid_issues, problems})}
  end

  def put_error(form, reason), do: %{form | error: SpecErrors.message(reason)}

  @doc "Targets the latest version `version` (files `%{path => lines}`) keeping the input."
  def retarget(form, version, files) do
    form = %{form | version: version, files: files, stale: nil, error: nil}
    %{form | errors: errors(form)}
  end

  ## Rendering

  defp verdicts,
    do: [
      {"pass", dgettext("ui", "通过")},
      {"fail", dgettext("ui", "不通过")},
      {"comment", dgettext("ui", "意见")}
    ]

  attr :form, :map, default: nil
  attr :close_path, :string, required: true
  attr :own, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="spec-review-panel"
      show={@form != nil}
      width={:wide}
      title={if @form, do: dgettext("ui", "评审 v%{n}", n: @form.version), else: ""}
      dirty={dirty?(@form)}
      patch_on_close={@close_path}
    >
      <:error :if={@form && @form.error}>{@form.error}</:error>
      <div :if={@form} class="flex flex-col gap-4">
        <p
          :if={@own}
          id="spec-review-own"
          class="rounded-field border border-border bg-surface px-3 py-2 text-body text-fg-muted"
        >
          {dgettext("ui", "你写了 v%{n}，不能评审它", n: @form.version)}
        </p>
        <div
          :if={@form.stale}
          id="spec-review-stale"
          role="alert"
          class="flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <span class="flex-1">{dgettext("ui", "已有 v%{n}，评审只能针对最新版本", n: @form.stale)}</span>
          <.button id="spec-review-retarget" size="xs" phx-click="rev_retarget">
            {dgettext("ui", "改为评审 v%{n}", n: @form.stale)}
          </.button>
        </div>
        <.form
          for={%{}}
          as={:review}
          id="spec-review-form"
          phx-change="rev_change"
          phx-submit="rev_submit"
          class="flex flex-col gap-3"
        >
          <fieldset class="flex flex-col gap-1" id="spec-review-verdict">
            <legend class="text-label font-medium text-fg">{dgettext("ui", "结论")}</legend>
            <div class="flex gap-4">
              <label :for={{value, label} <- verdicts()} class="flex items-center gap-1.5 text-body">
                <input
                  type="radio"
                  name="review[verdict]"
                  value={value}
                  checked={@form.verdict == value}
                  id={"spec-review-verdict-#{value}"}
                />
                {label}
              </label>
            </div>
          </fieldset>
          <.input
            id="spec-review-summary"
            name="review[summary]"
            type="textarea"
            rows="4"
            label={dgettext("ui", "摘要（Markdown）")}
            value={@form.summary}
            errors={List.wrap(@form.errors[:summary])}
            phx-debounce="300"
          />
          <div id="spec-review-issues" class="flex flex-col gap-2">
            <div
              :for={{i, k} <- Enum.with_index(@form.issues)}
              id={"spec-review-issue-#{k}"}
              class="flex flex-col gap-2 rounded-field border border-border px-3 py-2"
            >
              <div class="flex items-center gap-2">
                <span class="text-label font-medium text-fg">{dgettext("ui", "问题 %{n}", n: k + 1)}</span>
                <select
                  name={"review[issues][#{k}][severity]"}
                  id={"spec-review-issue-#{k}-severity"}
                  class="rounded-field border border-border bg-surface px-1 py-0.5 text-body"
                >
                  <option :for={s <- ~w(P1 P2 P3)} value={s} selected={i.severity == s}>{s}</option>
                </select>
                <span class="flex-1" />
                <.icon_button
                  icon="lucide-arrow-up"
                  label={dgettext("ui", "上移")}
                  size="xs"
                  phx-click="rev_move"
                  phx-value-index={k}
                  phx-value-dir="up"
                />
                <.icon_button
                  icon="lucide-arrow-down"
                  label={dgettext("ui", "下移")}
                  size="xs"
                  phx-click="rev_move"
                  phx-value-index={k}
                  phx-value-dir="down"
                />
                <.icon_button
                  icon="lucide-trash"
                  label={dgettext("ui", "删除")}
                  size="xs"
                  phx-click="rev_remove"
                  phx-value-index={k}
                  id={"spec-review-issue-#{k}-remove"}
                />
              </div>
              <p :if={@form.errors[{k, :issue}]} class="text-caption text-danger-fg" data-issue-error>
                {@form.errors[{k, :issue}]}
              </p>
              <div class="grid grid-cols-[1fr_6rem] gap-2">
                <div>
                  <select
                    name={"review[issues][#{k}][file]"}
                    id={"spec-review-issue-#{k}-file"}
                    class="w-full rounded-field border border-border bg-surface px-1 py-1 text-body"
                  >
                    <option value="">{dgettext("ui", "（不定位到文件）")}</option>
                    <option
                      :for={path <- Enum.sort(Map.keys(@form.files))}
                      value={path}
                      selected={i.file == path}
                    >
                      {path}
                    </option>
                  </select>
                  <p :if={@form.errors[{k, :file}]} class="text-caption text-danger-fg">
                    {@form.errors[{k, :file}]}
                  </p>
                </div>
                <.input
                  id={"spec-review-issue-#{k}-line"}
                  name={"review[issues][#{k}][line]"}
                  value={i.line}
                  placeholder={dgettext("ui", "行")}
                  errors={List.wrap(@form.errors[{k, :line}])}
                  phx-debounce="300"
                />
              </div>
              <.input
                id={"spec-review-issue-#{k}-anchor"}
                name={"review[issues][#{k}][anchor]"}
                value={i.anchor}
                placeholder={dgettext("ui", "锚点（可选）")}
                errors={List.wrap(@form.errors[{k, :anchor}])}
                phx-debounce="300"
              />
              <.input
                id={"spec-review-issue-#{k}-body"}
                name={"review[issues][#{k}][body]"}
                type="textarea"
                rows="3"
                value={i.body}
                placeholder={dgettext("ui", "问题（必填）")}
                errors={List.wrap(@form.errors[{k, :body}])}
                phx-debounce="300"
              />
              <.input
                id={"spec-review-issue-#{k}-suggestion"}
                name={"review[issues][#{k}][suggestion]"}
                type="textarea"
                rows="2"
                value={i.suggestion}
                placeholder={dgettext("ui", "建议（可选）")}
                errors={List.wrap(@form.errors[{k, :suggestion}])}
                phx-debounce="300"
              />
            </div>
          </div>
          <div>
            <.button
              id="spec-review-add-issue"
              size="sm"
              icon="lucide-plus"
              phx-click="rev_add_issue"
              disabled={length(@form.issues) >= 100}
            >
              {dgettext("ui", "添加问题")}
            </.button>
          </div>
        </.form>
      </div>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-review-submit"
            type="submit"
            form="spec-review-form"
            variant="primary"
            disabled={@form == nil or @own or @form.stale != nil}
            phx-disable-with={dgettext("ui", "正在提交…")}
          >
            {dgettext("ui", "提交评审")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end
