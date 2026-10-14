defmodule HelmsmanWeb.QueryComponents do
  @moduledoc """
  Pieces of the BQL page (add-search-query-ui D4, D5, D7): the error with its one-line
  preview, the field reference, the example queries, the order description and the
  result table.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.{CollabComponents, TaskComponents}

  @window 40

  @examples [
    "status IN (new, in_progress) AND assignee = currentUser()",
    "assignee_kind = agent AND run = failed",
    "pr = open AND ci = failure",
    "updated >= -7d ORDER BY updated DESC",
    ~s(text ~ "登录")
  ]

  @doc "Example queries shown on an empty page."
  def examples, do: @examples

  @doc """
  The one-line preview of `bql` with the error at codepoint `position` (from 1): the
  word from there to the next whitespace is marked; past the end a caret is shown. Long
  queries are cut to #{@window} codepoints around the position, with ellipses.

  Returns `%{before, mark, after, caret?, lead?, trail?}` (plain text; the template
  escapes it).
  """
  def preview(bql, position) when is_binary(bql) and is_integer(position) do
    chars =
      bql |> String.codepoints() |> Enum.map(&if(&1 in ["\n", "\r", "\t"], do: " ", else: &1))

    n = length(chars)
    at = min(max(position - 1, 0), n)

    mark_len =
      case chars |> Enum.drop(at) |> Enum.take_while(&(&1 != " ")) |> length() do
        0 when at < n -> 1
        len -> len
      end

    start = max(at - @window, 0)
    stop = min(max(at + @window, at + 1), n)
    mark_end = min(at + mark_len, stop)

    %{
      before: slice(chars, start, at),
      mark: slice(chars, at, mark_end),
      after: slice(chars, mark_end, stop),
      caret?: at >= n,
      lead?: start > 0,
      trail?: stop < n
    }
  end

  defp slice(chars, from, to), do: chars |> Enum.slice(from, max(to - from, 0)) |> Enum.join()

  @doc "The order description: 按相关度, 按 updated 降序, several joined with 、."
  def order_label(:relevance), do: dgettext("ui", "按相关度")
  def order_label([]), do: nil

  def order_label(order) when is_list(order) do
    order
    |> Enum.map_join("、", fn
      {field, :asc} -> dgettext("ui", "%{field} 升序", field: field)
      {field, _desc} -> dgettext("ui", "%{field} 降序", field: field)
    end)
    |> then(&dgettext("ui", "按 %{order}", order: &1))
  end

  def order_label(_order), do: nil

  @doc "BQL text of an operator of `BQL.fields/0`."
  def operator_label(:eq), do: "="
  def operator_label(:neq), do: "!="
  def operator_label(:match), do: "~"
  def operator_label(:nmatch), do: "!~"
  def operator_label(:gt), do: ">"
  def operator_label(:gte), do: ">="
  def operator_label(:lt), do: "<"
  def operator_label(:lte), do: "<="
  def operator_label(:in), do: "IN"
  def operator_label(:not_in), do: "NOT IN"
  def operator_label(:empty), do: "IS EMPTY"
  def operator_label(:not_empty), do: "IS NOT EMPTY"
  def operator_label(op), do: to_string(op)

  @doc "What a field of `BQL.fields/0` takes: its values, or a description of its type."
  def field_values_label(%{name: :project, values: :name}), do: dgettext("ui", "项目 Key")
  def field_values_label(%{name: :labels, values: :name}), do: dgettext("ui", "标签")
  def field_values_label(%{name: :squad, values: :name}), do: dgettext("ui", "小队名")
  def field_values_label(%{values: values}), do: values_label(values)

  @doc "What a value type takes: the values, or a description of the type."
  def values_label(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  def values_label(:date), do: dgettext("ui", "日期：2026-10-01、-7d")
  def values_label(:identity), do: dgettext("ui", "身份名或 currentUser()")
  def values_label(:task_id), do: dgettext("ui", "任务 ID（KEY-N）")
  def values_label(:text), do: dgettext("ui", "文本")
  def values_label(:integer), do: dgettext("ui", "整数")
  def values_label(:boolean), do: "true / false"
  def values_label(:project), do: dgettext("ui", "项目 Key")
  def values_label(:label), do: dgettext("ui", "标签")
  def values_label(:squad), do: dgettext("ui", "小队名")
  def values_label(:name), do: dgettext("ui", "名字")
  def values_label(other), do: to_string(other)

  @doc """
  The error under the editor: 第 N 个字符：<domain message> and the preview, or a plain
  message (timeouts, other failures). `error` is `%{message, position, bql}` (position
  and bql may be nil).
  """
  attr :id, :string, default: "query-error"
  attr :error, :map, required: true

  def query_error(assigns) do
    %{error: error} = assigns

    assigns =
      assign(assigns,
        preview: error[:position] && error[:bql] && preview(error.bql, error.position)
      )

    ~H"""
    <div
      id={@id}
      role="alert"
      class="flex flex-col gap-1.5 rounded-field border border-danger tint-danger px-3 py-2"
    >
      <p id={"#{@id}-message"} class="flex items-start gap-1.5 text-body text-danger-fg">
        <.icon name="lucide-circle-alert" class="mt-0.5 size-4 flex-none" />
        <span :if={@error[:position]}>
          {dgettext("ui", "第 %{n} 个字符：", n: @error.position)}{@error.message}
        </span>
        <span :if={!@error[:position]}>{@error.message}</span>
      </p>
      <p
        :if={@preview}
        id={"#{@id}-preview"}
        aria-label={dgettext("ui", "出错位置")}
        class="overflow-hidden whitespace-pre font-mono text-label text-fg"
        phx-no-format
      ><span :if={@preview.lead?} class="text-fg-subtle">…</span><span>{@preview.before}</span><mark
          :if={@preview.mark != ""}
          class="rounded-sm bg-danger/30 text-fg"
        >{@preview.mark}</mark><span>{@preview.after}</span><span
          :if={@preview.caret?}
          data-caret
          class="text-danger-fg"
        >▏</span><span :if={@preview.trail?} class="text-fg-subtle">…</span></p>
    </div>
    """
  end

  @doc "The field reference (collapsed by default on the page)."
  attr :fields, :list, required: true

  def fields_reference(assigns) do
    ~H"""
    <section id="query-fields" class="flex flex-col gap-2" aria-label={dgettext("ui", "字段速查")}>
      <p class="text-body text-fg-muted">
        {dgettext(
          "ui",
          "写法：字段 运算 值，用 AND / OR / NOT 与括号组合，ORDER BY 字段 [ASC|DESC] 排序。点击字段名把它加到查询末尾。"
        )}
      </p>
      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-body">
          <caption class="sr-only">{dgettext("ui", "BQL 字段")}</caption>
          <thead>
            <tr class="h-8 border-b border-border text-left text-caption text-fg-muted">
              <th scope="col" class="px-2 font-medium">{dgettext("ui", "字段")}</th>
              <th scope="col" class="px-2 font-medium">{dgettext("ui", "别名")}</th>
              <th scope="col" class="px-2 font-medium">{dgettext("ui", "运算")}</th>
              <th scope="col" class="px-2 font-medium">{dgettext("ui", "取值")}</th>
              <th scope="col" class="px-2 font-medium">{dgettext("ui", "可排序")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={field <- @fields}
              id={"query-field-#{field.name}"}
              class="border-b border-border align-top"
            >
              <td class="px-2 py-1.5">
                <button
                  type="button"
                  class="font-mono text-label text-brand-fg hover:underline"
                  phx-click="add_field"
                  phx-value-name={field.name}
                  data-field-name
                >
                  {field.name}
                </button>
              </td>
              <td class="px-2 py-1.5 font-mono text-label text-fg-muted" data-aliases>
                {Enum.join(field.aliases, ", ")}
              </td>
              <td class="px-2 py-1.5 font-mono text-label text-fg-muted" data-operators>
                {Enum.map_join(field.operators, "  ", &operator_label/1)}
              </td>
              <td class="px-2 py-1.5 text-label text-fg-muted" data-values>
                {field_values_label(field)}
              </td>
              <td class="px-2 py-1.5" data-sortable={to_string(field.sortable)}>
                <.icon
                  :if={field.sortable}
                  name="lucide-check"
                  class="size-4 text-success"
                  label={dgettext("ui", "可排序")}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  @doc "Example queries; a click fills the editor and runs."
  def example_list(assigns) do
    assigns = assign(assigns, :examples, @examples)

    ~H"""
    <section id="query-examples" class="flex flex-col gap-2">
      <p class="text-body text-fg-muted">{dgettext("ui", "试试这些查询：")}</p>
      <div class="flex flex-wrap gap-2">
        <button
          :for={{example, i} <- Enum.with_index(@examples)}
          id={"query-example-#{i}"}
          type="button"
          phx-click="example"
          phx-value-bql={example}
          class="rounded-field border border-border bg-surface px-2 py-1 font-mono text-label text-fg hover:bg-hover"
        >
          {example}
        </button>
      </div>
    </section>
    """
  end

  @doc "The result rows (columns as in the task list, plus the project)."
  attr :rows, :any, required: true
  attr :slug, :string, required: true
  attr :agents, :map, default: %{}
  attr :appearance, :map, default: %{}
  attr :has_more, :boolean, default: false
  attr :class, :any, default: nil

  def result_table(assigns) do
    ~H"""
    <.data_table
      id="query-tasks"
      class={@class}
      rows={@rows}
      label={dgettext("ui", "查询结果")}
      row_click={&JS.navigate("/w/#{@slug}/t/#{&1.id}")}
      has_more={@has_more}
      load_more="load_more"
    >
      <:col :let={task} label="ID" class="w-24">
        <.task_id_link ident={task.id} workspace={@slug} status={task.status} />
      </:col>
      <:col :let={task} label={dgettext("ui", "标题")}>
        <span class="inline-flex min-w-0 items-center gap-1.5">
          <CollabComponents.epic_badge :if={task[:kind] == "epic"} kind="epic" />
          <span class="truncate text-fg">{task.title}</span>
          <.tooltip :if={task[:blocked]} text={dgettext("ui", "被阻塞")} class="flex-none">
            <.icon
              name="lucide-octagon-pause"
              class="size-3.5 text-warning"
              label={dgettext("ui", "被阻塞")}
              data-blocked
            />
          </.tooltip>
          <.tooltip :if={task[:open_question]} text={dgettext("ui", "待回答")} class="flex-none">
            <.icon
              name="lucide-circle-question-mark"
              class="size-3.5 text-warning"
              label={dgettext("ui", "待回答")}
              data-open-question
            />
          </.tooltip>
        </span>
      </:col>
      <:col :let={task} label={dgettext("ui", "项目")} class="w-20" secondary>
        <span class="font-mono text-label text-fg-muted" data-project>{task.project_key}</span>
      </:col>
      <:col :let={task} label={dgettext("ui", "状态")} class="w-10 md:w-28">
        <span class="md:hidden"><.status_icon status={task.status} /></span>
        <span class="hidden md:inline-flex"><.status_badge status={task.status} /></span>
      </:col>
      <:col :let={task} label={dgettext("ui", "优先级")} secondary class="w-16">
        <.priority_icon priority={task.priority} />
      </:col>
      <:col :let={task} label={dgettext("ui", "执行方")} class="w-12 sm:w-32">
        <span :if={task.assignee}>
          <TaskComponents.actor_ref
            actor={task.assignee}
            agents={@agents}
            appearance={@appearance}
            compact
          />
        </span>
      </:col>
      <:col :let={task} label={dgettext("ui", "更新")} secondary class="w-24">
        <.relative_time
          id={"query-task-#{task.id}-updated"}
          at={task.updated_at}
          class="text-caption text-fg-muted"
        />
      </:col>
    </.data_table>
    """
  end
end
