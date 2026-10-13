defmodule HelmsmanWeb.DataSettingsComponents do
  @moduledoc """
  Pieces of the data settings page (add-data-settings-ui D6): export rows, the import
  report (counts, identity mapping, locally newer tasks, warnings) and import errors.
  Reports and errors come from untrusted files and are only ever interpolated (escaped).
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1]
  import HelmsmanWeb.Components.Text, only: [task_id_link: 1]

  @collections ~w(actors projects tasks task_events feedback links saved_filters)
  @actions ~w(created fast_forwarded unchanged local_newer)
  @max_local_newer 50

  @doc "Label of an export / import collection."
  def collection_label("actors"), do: dgettext("ui", "身份")
  def collection_label("projects"), do: dgettext("ui", "项目")
  def collection_label("tasks"), do: dgettext("ui", "任务")
  def collection_label("task_events"), do: dgettext("ui", "事件")
  def collection_label("feedback"), do: dgettext("ui", "反馈")
  def collection_label("links"), do: dgettext("ui", "关联")
  def collection_label("saved_filters"), do: dgettext("ui", "筛选器")
  def collection_label(other), do: other

  @doc "Status label of an export or import."
  def status_label(:queued), do: dgettext("ui", "排队中")
  def status_label(:running), do: dgettext("ui", "运行中")
  def status_label(:succeeded), do: dgettext("ui", "成功")
  def status_label(:failed), do: dgettext("ui", "失败")
  def status_label(other), do: to_string(other)

  @doc "Status label of an export (生成中 / 可下载 instead of 运行中 / 成功)."
  def export_status_label(:running), do: dgettext("ui", "生成中")
  def export_status_label(:succeeded), do: dgettext("ui", "可下载")
  def export_status_label(status), do: status_label(status)

  @doc "`1.2 MB`-style size."
  def format_size(nil), do: ""
  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"

  def format_size(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @doc "`项目 2 · 任务 30 · …` from export counts."
  def counts_summary(counts) when is_map(counts) do
    @collections
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_join(" · ", &"#{collection_label(&1)} #{counts[&1]}")
  end

  def counts_summary(_), do: ""

  def mode_label(mode) when mode in [:replace, "replace"], do: dgettext("ui", "替换")
  def mode_label(_), do: dgettext("ui", "合并")

  def source_label(source) when source in [:bosun, "bosun"], do: "bosun"
  def source_label(_), do: "Helmsman"

  @doc "An import report (string keys)."
  attr :id, :string, required: true
  attr :report, :map, required: true
  attr :workspace, :string, required: true, doc: "workspace slug"

  def import_report(assigns) do
    report = assigns.report || %{}
    counts = report["counts"] || %{}
    local_newer = report["local_newer"] || []

    assigns =
      assign(assigns,
        rows: for(c <- @collections, Map.has_key?(counts, c), do: {c, counts[c] || %{}}),
        actions: @actions,
        actors: report["actors"] || [],
        local_newer: Enum.take(local_newer, @max_local_newer),
        more: max(length(local_newer) - @max_local_newer, 0),
        warnings: report["warnings"] || []
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-4 text-body">
      <table :if={@rows != []} id={"#{@id}-counts"} class="w-full text-left">
        <caption class="sr-only">{dgettext("ui", "各类数据的条数")}</caption>
        <thead class="text-caption text-fg-muted">
          <tr>
            <th class="py-1 font-medium">{dgettext("ui", "数据")}</th>
            <th class="py-1 text-right font-medium">{dgettext("ui", "新增")}</th>
            <th class="py-1 text-right font-medium">{dgettext("ui", "快进")}</th>
            <th class="py-1 text-right font-medium">{dgettext("ui", "不变")}</th>
            <th class="py-1 text-right font-medium">{dgettext("ui", "本地较新")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{c, n} <- @rows} id={"#{@id}-count-#{c}"} class="border-t border-border">
            <td class="py-1 text-fg">{collection_label(c)}</td>
            <td :for={a <- @actions} class="py-1 text-right tabular-nums">{n[a] || 0}</td>
          </tr>
        </tbody>
      </table>

      <section :if={@actors != []} id={"#{@id}-actors"}>
        <h3 class="mb-1 text-label font-medium text-fg">{dgettext("ui", "身份映射")}</h3>
        <ul class="flex flex-col gap-1">
          <li :for={a <- @actors} class="flex flex-wrap items-center gap-2">
            <span class="font-mono text-fg">{a["from"]}</span>
            <.icon name="lucide-arrow-right" class="size-3.5 text-fg-muted" />
            <span class="font-mono text-fg">{a["to"]}</span>
            <span class="rounded-field bg-subtle px-1.5 text-caption text-fg-muted">
              {actor_action(a["action"])}
            </span>
          </li>
        </ul>
      </section>

      <section :if={@local_newer != []} id={"#{@id}-local-newer"}>
        <h3 class="mb-1 text-label font-medium text-fg">
          {dgettext("ui", "本地较新的任务（已跳过）")}
        </h3>
        <p class="flex flex-wrap gap-2">
          <.task_id_link :for={ident <- @local_newer} ident={ident} workspace={@workspace} />
          <span :if={@more > 0} class="text-fg-muted">
            {dgettext("ui", "等 %{count} 个", count: @more)}
          </span>
        </p>
      </section>

      <section :if={@warnings != []} id={"#{@id}-warnings"}>
        <h3 class="mb-1 text-label font-medium text-warning-fg">{dgettext("ui", "警告")}</h3>
        <ul class="flex flex-col gap-1">
          <li :for={w <- @warnings} class="text-fg">
            <span :if={w["path"]} class="font-mono text-fg-muted">{w["path"]}</span>
            <span :if={w["name"]} class="font-mono">{w["name"]}</span>
            {w["message"]}
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp actor_action("existing"), do: dgettext("ui", "已有")
  defp actor_action("unclaimed"), do: dgettext("ui", "新建为未认领")
  defp actor_action("created"), do: dgettext("ui", "新建")
  defp actor_action(other), do: other

  @doc """
  Import errors: `%{"path", "message"}` validation entries or one
  `%{"reason", "detail"}` failure (string keys, as stored on the import row).
  """
  attr :id, :string, required: true
  attr :errors, :list, required: true
  attr :workspace, :string, required: true, doc: "workspace slug"

  def import_errors(assigns) do
    assigns = assign(assigns, groups: group_errors(assigns.errors))

    ~H"""
    <div id={@id} role="alert" class="flex flex-col gap-3 text-body">
      <div
        :for={{title, hint, items} <- @groups}
        class="rounded-field border border-danger tint-danger p-3"
      >
        <p class="font-medium text-danger-fg">{title}</p>
        <p :if={hint} class="text-caption text-fg-muted">{hint}</p>
        <ul :if={items != []} class="mt-2 flex flex-col gap-1">
          <li :for={item <- items} class="text-fg">
            <%= case item do %>
              <% {:task, ident, reason} -> %>
                <.task_id_link ident={ident} workspace={@workspace} />
                <span class="text-fg-muted">{blocked_reason(reason)}</span>
              <% {:entry, path, message} -> %>
                <span :if={path} class="font-mono text-fg-muted">{path}</span>
                {message}
            <% end %>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp group_errors(errors) do
    {validation, failures} = Enum.split_with(errors || [], &(not Map.has_key?(&1, "reason")))

    validation_group =
      if validation == [],
        do: [],
        else: [
          {dgettext("ui", "文件校验失败（%{count} 处）", count: length(validation)),
           dgettext("ui", "文件未写入任何数据"),
           Enum.map(validation, &{:entry, &1["path"], &1["message"]})}
        ]

    validation_group ++ Enum.map(failures, &failure/1)
  end

  defp failure(%{"reason" => "replace_blocked", "detail" => detail}) when is_list(detail) do
    {dgettext("ui", "无法替换：以下任务有进行中的运行或未关闭的 PR"), dgettext("ui", "等它们结束或关闭后再试"),
     Enum.map(detail, &{:task, &1["task"], &1["reason"]})}
  end

  defp failure(%{"reason" => reason} = error) do
    {title, hint} = reason_text(reason)
    {title, hint, detail_items(error["detail"])}
  end

  defp detail_items(%{} = detail) do
    if detail["path"] || detail["message"],
      do: [{:entry, detail["path"], detail["message"]}],
      else: []
  end

  defp detail_items(list) when is_list(list), do: Enum.flat_map(list, &detail_items/1)
  defp detail_items(_), do: []

  defp reason_text("invalid_import"),
    do: {dgettext("ui", "文件校验失败"), dgettext("ui", "文件未写入任何数据")}

  defp reason_text("diverged"),
    do: {dgettext("ui", "任务历史与本地分叉"), dgettext("ui", "导入已整体回滚")}

  defp reason_text("cycle"),
    do: {dgettext("ui", "依赖关系成环"), dgettext("ui", "导入已整体回滚")}

  defp reason_text("actor_kind_conflict"),
    do: {dgettext("ui", "身份种类冲突"), dgettext("ui", "可在身份改名中把它改为其他名字")}

  defp reason_text(reason), do: {reason_message(reason), nil}

  @doc "Message for a failure reason (atom or string)."
  def reason_message(reason) when is_atom(reason), do: reason_message(Atom.to_string(reason))
  def reason_message("busy"), do: dgettext("ui", "工作区正忙（有其他导入或维护进行中），请稍后再试")
  def reason_message("unsupported_format"), do: dgettext("ui", "不支持的文件格式")
  def reason_message("too_large"), do: dgettext("ui", "文件超过导入上限")
  def reason_message("storage_unavailable"), do: dgettext("ui", "数据目录不可用，请联系管理员")
  def reason_message("confirmation_required"), do: dgettext("ui", "替换需要输入工作区地址确认")
  def reason_message("forbidden"), do: dgettext("ui", "没有权限执行此操作")
  def reason_message("interrupted"), do: dgettext("ui", "导入被中断")
  def reason_message(_), do: dgettext("ui", "导入失败")

  defp blocked_reason("active_run"), do: dgettext("ui", "有进行中的运行")
  defp blocked_reason("open_pr"), do: dgettext("ui", "有未关闭的 PR")
  defp blocked_reason(other), do: other
end
