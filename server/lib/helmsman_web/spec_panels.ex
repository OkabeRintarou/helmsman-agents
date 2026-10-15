defmodule HelmsmanWeb.SpecPanels do
  @moduledoc """
  The smaller right-side panels of the spec page (add-spec-workflow-ui D9–D11): 请求评审,
  the issue reply (回复 / 撤回 / 裁定 / 评论), 定稿 / 批准, 退回, 放弃, 重新打开, change_id,
  导出 and 导入. Rendering only: `HelmsmanWeb.SpecLive.Show` keeps their state and
  handles the events.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.SpecComponents

  alias HelmsmanWeb.SpecErrors

  @max_note 8192
  @max_reason 4096
  @max_summary 16_384

  def limits, do: %{note: @max_note, reason: @max_reason, summary: @max_summary}

  defp bytes_hint(assigns) do
    ~H"""
    <p
      class={[
        "text-right text-caption",
        if(byte_size(@text) > @max, do: "text-danger-fg", else: "text-fg-muted")
      ]}
      id={@id}
    >
      {dgettext("ui", "%{bytes} / %{max} 字节", bytes: byte_size(@text), max: @max)}
    </p>
    """
  end

  ## 请求评审

  attr :panel, :map, default: nil
  attr :candidates, :list, default: []
  attr :close_path, :string, required: true
  attr :blocked, :string, default: nil

  def request(assigns) do
    assigns = assign(assigns, max_note: @max_note)

    ~H"""
    <.side_panel
      id="spec-request-panel"
      show={@panel != nil}
      title={dgettext("ui", "请求评审")}
      dirty={@panel != nil and (@panel.selected != [] or @panel.note != "")}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <p :if={@blocked} id="spec-request-blocked" class="mb-3 text-body text-fg-muted">{@blocked}</p>
      <.form
        :if={@panel}
        for={%{}}
        as={:request}
        id="spec-request-form"
        phx-change="request_change"
        phx-submit="request_submit"
        class="flex flex-col gap-3"
      >
        <input type="hidden" name="request[reviewers][]" value="" />
        <fieldset class="flex flex-col gap-1" id="spec-request-reviewers">
          <legend class="text-label font-medium text-fg">{dgettext("ui", "评审人")}</legend>
          <label
            :for={c <- @candidates}
            id={"spec-request-reviewer-#{c.dom}"}
            data-name={c.name}
            class={[
              "flex items-center gap-2 rounded-field px-2 py-1 text-body",
              c.author && "opacity-60"
            ]}
          >
            <input
              type="checkbox"
              name="request[reviewers][]"
              value={c.name}
              checked={c.name in @panel.selected}
              disabled={c.author}
            />
            <span class="text-fg">{c.name}</span>
            <span class="text-caption text-fg-muted">{c.kind_label}</span>
            <.badge :if={c.author} tone={:subtle} data-author>{dgettext("ui", "作者")}</.badge>
            <.badge :if={c.pending} tone={:info} data-pending>{dgettext("ui", "已在评审")}</.badge>
            <span :if={c.unavailable} class="text-caption text-warning-fg" data-unavailable>{c.unavailable}</span>
          </label>
        </fieldset>
        <.input
          id="spec-request-note"
          name="request[note]"
          type="textarea"
          rows="4"
          label={dgettext("ui", "说明（可选）")}
          value={@panel.note}
          phx-debounce="300"
        />
        <.bytes_hint id="spec-request-note-size" text={@panel.note} max={@max_note} />
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-request-submit"
            type="submit"
            form="spec-request-form"
            variant="primary"
            disabled={
              @panel == nil or @panel.selected == [] or @blocked != nil or
                byte_size(@panel.note) > @max_note
            }
          >
            {dgettext("ui", "请求评审")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  ## 回复

  attr :panel, :map, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, required: true

  def note(assigns) do
    assigns = assign(assigns, max_note: @max_note)

    ~H"""
    <.side_panel
      id="spec-note-panel"
      show={@panel != nil}
      title={if @panel, do: dgettext("ui", "回复 %{ref}", ref: @panel.ref), else: ""}
      dirty={@panel != nil and @panel.body != ""}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <div :if={@panel} class="flex flex-col gap-3">
        <blockquote
          id="spec-note-quote"
          class="flex flex-col gap-1 border-l-2 border-border pl-3 text-body"
        >
          <span class="flex items-center gap-2">
            <.severity_badge severity={@panel.issue.severity} />
            <.resolution_badge issue={@panel.issue} />
          </span>
          <.markdown content={@panel.issue.body} scope={@scope} anchor_ns="spec-note-quote" />
        </blockquote>
        <.form
          for={%{}}
          as={:note}
          id="spec-note-form"
          phx-change="note_change"
          phx-submit="note_submit"
          class="flex flex-col gap-3"
        >
          <fieldset class="flex flex-col gap-1" id="spec-note-kinds">
            <legend class="text-label font-medium text-fg">{dgettext("ui", "种类")}</legend>
            <label :for={{value, label} <- @panel.kinds} class="flex items-center gap-1.5 text-body">
              <input
                type="radio"
                name="note[kind]"
                value={value}
                checked={@panel.kind == value}
                id={"spec-note-kind-#{value}"}
              />
              {label}
            </label>
          </fieldset>
          <label :if={@panel.kind == "accepted"} class="flex items-center gap-2 text-body">
            {dgettext("ui", "在哪个版本修改（可选）")}
            <select
              name="note[fixed_in]"
              id="spec-note-fixed-in"
              class="rounded-field border border-border bg-surface px-1 py-0.5"
            >
              <option value="">—</option>
              <option :for={v <- @panel.versions} value={v} selected={to_string(v) == @panel.fixed_in}>
                v{v}
              </option>
            </select>
          </label>
          <.input
            id="spec-note-body"
            name="note[body]"
            type="textarea"
            rows="5"
            label={
              if(@panel.kind in ~w(disputed upheld dismissed),
                do: dgettext("ui", "理由（必填）"),
                else: dgettext("ui", "内容")
              )
            }
            value={@panel.body}
            errors={List.wrap(@panel.body_error)}
            phx-debounce="300"
          />
          <.bytes_hint id="spec-note-size" text={@panel.body} max={@max_note} />
        </.form>
      </div>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button id="spec-note-submit" type="submit" form="spec-note-form" variant="primary">{dgettext(
            "ui",
            "提交"
          )}</.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  @doc "The body error of a note panel, or nil."
  def note_body_error(%{kind: kind, body: body}) do
    cond do
      byte_size(body) > @max_note -> dgettext("ui", "不能超过 8 KB")
      kind in ~w(disputed upheld dismissed) and String.trim(body) == "" -> dgettext("ui", "必填")
      kind == "comment" and String.trim(body) == "" -> dgettext("ui", "必填")
      true -> nil
    end
  end

  ## 定稿 / 批准

  attr :panel, :map, default: nil
  attr :spec, :map, default: nil
  attr :gate, :list, default: []
  attr :wake_target, :string, default: nil
  attr :diff_path, :string, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, required: true

  def finalize(assigns) do
    assigns = assign(assigns, max: @max_summary)

    ~H"""
    <.side_panel
      id="spec-finalize-panel"
      show={@panel != nil and @spec != nil}
      title={finalize_title(@spec)}
      dirty={@panel != nil and @panel.summary != ""}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <div :if={@panel && @spec} class="flex flex-col gap-4">
        <div :if={@spec.proposal} id="spec-finalize-proposal" class="flex flex-col gap-1 text-body">
          <span class="text-fg-muted">
            {dgettext("ui", "%{by} 提议以 v%{v} 定稿", by: @spec.proposal.by, v: @spec.proposal.version)}
          </span>
          <.markdown
            :if={@spec.proposal.summary}
            content={@spec.proposal.summary}
            scope={@scope}
            anchor_ns="spec-finalize-summary"
          />
        </div>
        <.gate gate={@gate} id="spec-finalize-gate" />
        <.link
          :if={@diff_path}
          id="spec-finalize-diff"
          patch={@diff_path}
          class="text-body text-fg-muted hover:underline"
        >
          {dgettext("ui", "对比上一定稿版本或上一版")}
        </.link>
        <.form
          for={%{}}
          as={:finalize}
          id="spec-finalize-form"
          phx-change="finalize_change"
          phx-submit="finalize_submit"
          class="flex flex-col gap-3"
        >
          <.input
            id="spec-finalize-summary"
            name="finalize[summary]"
            type="textarea"
            rows="3"
            label={dgettext("ui", "附言（可选）")}
            value={@panel.summary}
            phx-debounce="300"
          />
          <.bytes_hint id="spec-finalize-summary-size" text={@panel.summary} max={@max} />
          <label :if={@wake_target} class="flex items-center gap-2 text-body" id="spec-finalize-wake">
            <input type="hidden" name="finalize[wake]" value="false" />
            <input type="checkbox" name="finalize[wake]" value="true" checked={@panel.wake} />
            {dgettext("ui", "通知执行方继续（%{target}）", target: @wake_target)}
          </label>
        </.form>
      </div>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-finalize-submit"
            type="submit"
            form="spec-finalize-form"
            variant="primary"
            disabled={
              @panel == nil or Enum.any?(@gate, &(!&1.ok)) or byte_size(@panel.summary) > @max
            }
          >
            {finalize_title(@spec)}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp finalize_title(nil), do: ""

  defp finalize_title(%{proposal: %{version: v}}), do: dgettext("ui", "批准 v%{v}", v: v)
  defp finalize_title(spec), do: dgettext("ui", "定稿 v%{v}", v: spec.latest_version)

  ## 退回 / 放弃 / 重新打开

  attr :panel, :map, default: nil
  attr :wake_target, :string, default: nil
  attr :close_path, :string, required: true

  def reason(assigns) do
    assigns = assign(assigns, max: @max_reason)

    ~H"""
    <.side_panel
      id="spec-reason-panel"
      show={@panel != nil}
      title={reason_title(@panel)}
      dirty={@panel != nil and @panel.reason != ""}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <.form
        :if={@panel}
        for={%{}}
        as={:reason}
        id="spec-reason-form"
        phx-change="reason_change"
        phx-submit="reason_submit"
        class="flex flex-col gap-3"
      >
        <p :if={@panel.kind == :abandon} id="spec-reason-abandon-note" class="text-body text-fg-muted">
          {dgettext("ui", "待完成的评审请求将作废，待批准的提议将撤回。")}
        </p>
        <.input
          id="spec-reason-text"
          name="reason[reason]"
          type="textarea"
          rows="4"
          label={dgettext("ui", "理由（必填）")}
          value={@panel.reason}
          errors={List.wrap(@panel.reason_error)}
          phx-debounce="300"
        />
        <.bytes_hint id="spec-reason-size" text={@panel.reason} max={@max} />
        <label
          :if={@panel.kind == :reject and @wake_target}
          class="flex items-center gap-2 text-body"
          id="spec-reason-wake"
        >
          <input type="hidden" name="reason[wake]" value="false" />
          <input type="checkbox" name="reason[wake]" value="true" checked={@panel.wake} />
          {dgettext("ui", "通知执行方继续（%{target}）", target: @wake_target)}
        </label>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-reason-submit"
            type="submit"
            form="spec-reason-form"
            variant={if(@panel && @panel.kind == :abandon, do: "danger", else: "primary")}
          >
            {reason_title(@panel)}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp reason_title(nil), do: ""
  defp reason_title(%{kind: :reject}), do: dgettext("ui", "退回")
  defp reason_title(%{kind: :abandon}), do: dgettext("ui", "放弃规格")
  defp reason_title(%{kind: :reopen}), do: dgettext("ui", "重新打开")

  @doc "The reason error of a reason panel, or nil."
  def reason_error(%{reason: reason}) do
    cond do
      String.trim(reason) == "" -> dgettext("ui", "必填")
      byte_size(reason) > @max_reason -> dgettext("ui", "不能超过 4 KB")
      true -> nil
    end
  end

  ## change_id

  attr :panel, :map, default: nil
  attr :close_path, :string, required: true

  def change_id(assigns) do
    ~H"""
    <.side_panel
      id="spec-change-id-panel"
      show={@panel != nil}
      title={dgettext("ui", "修改 change_id")}
      patch_on_close={@close_path}
    >
      <.form
        :if={@panel}
        for={%{}}
        as={:change_id}
        id="spec-change-id-form"
        phx-change="change_id_change"
        phx-submit="change_id_submit"
        class="flex flex-col gap-2"
      >
        <.input
          id="spec-change-id-value"
          name="change_id[value]"
          label="change_id"
          value={@panel.value}
          errors={List.wrap(@panel.error)}
          phx-debounce="200"
        />
        <p class="text-caption text-fg-muted">
          {dgettext("ui", "导出时的目录名：2–64 个小写字母、数字与 -，以字母或数字开头")}
        </p>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-change-id-submit"
            type="submit"
            form="spec-change-id-form"
            variant="primary"
            disabled={@panel == nil or @panel.error != nil}
          >
            {dgettext("ui", "保存")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  @change_id ~r/\A[a-z0-9][a-z0-9-]{1,63}\z/

  @doc "The local error of a change_id, or nil."
  def change_id_error(value) do
    if value =~ @change_id,
      do: nil,
      else: dgettext("ui", "change_id 只能用 2–64 个小写字母、数字与 -，以字母或数字开头")
  end

  ## 导出

  attr :panel, :map, default: nil
  attr :versions, :list, default: []
  attr :href, :string, default: nil
  attr :close_path, :string, required: true

  def export(assigns) do
    ~H"""
    <.side_panel
      id="spec-export-panel"
      show={@panel != nil}
      title={dgettext("ui", "导出 OpenSpec 目录")}
      patch_on_close={@close_path}
    >
      <.form
        :if={@panel}
        for={%{}}
        as={:export}
        id="spec-export-form"
        phx-change="export_change"
        class="flex flex-col gap-3"
      >
        <label class="flex flex-col gap-1 text-body">
          {dgettext("ui", "版本")}
          <select
            name="export[version]"
            id="spec-export-version"
            class="rounded-field border border-border bg-surface px-2 py-1"
          >
            <option
              :for={v <- Enum.reverse(@versions)}
              value={v.number}
              selected={v.number == @panel.version}
            >
              v{v.number}
            </option>
          </select>
        </label>
        <fieldset class="flex gap-4 text-body" id="spec-export-format">
          <label :for={f <- ~w(tar.gz zip)} class="flex items-center gap-1.5">
            <input type="radio" name="export[format]" value={f} checked={@panel.format == f} />{f}
          </label>
        </fieldset>
        <label class="flex items-center gap-2 text-body">
          <input type="hidden" name="export[reviews]" value="false" />
          <input
            type="checkbox"
            name="export[reviews]"
            value="true"
            checked={@panel.reviews}
            id="spec-export-reviews"
          />
          {dgettext("ui", "附带评审（reviews/spec-review-<n>.md）")}
        </label>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "关闭")}</.button>
          <.button
            :if={@href}
            id="spec-export-download"
            variant="primary"
            icon="lucide-download"
            href={@href}
            download
          >
            {dgettext("ui", "下载")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  ## 导入

  attr :panel, :map, default: nil
  attr :upload, :any, default: nil
  attr :close_path, :string, required: true

  def import(assigns) do
    ~H"""
    <.side_panel
      id="spec-import-panel"
      show={@panel != nil}
      width={:wide}
      title={dgettext("ui", "导入 OpenSpec 目录")}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <div :if={@panel} class="flex flex-col gap-4">
        <.form
          for={%{}}
          as={:import}
          id="spec-import-form"
          phx-change="import_change"
          phx-submit="import_submit"
          class="flex flex-col gap-3"
        >
          <div :if={@upload} class="flex flex-col gap-1 text-body">
            <span>{dgettext("ui", "压缩包（tar.gz 或 zip，≤ 2 MB）")}</span>
            <label
              for={@upload.ref}
              id="spec-import-pick"
              class="inline-flex h-8 w-fit cursor-pointer items-center gap-1.5 rounded-field border border-border bg-surface px-3 text-body text-fg hover:bg-hover"
            >
              <.icon name="lucide-upload" class="size-4" />{dgettext("ui", "选择文件")}
            </label>
            <p :for={entry <- @upload.entries} class="text-caption text-fg-muted">
              {entry.client_name}
            </p>
            <p :for={err <- upload_errors(@upload)} class="text-caption text-danger-fg">
              {upload_error(err)}
            </p>
          </div>
          <p :if={@panel.name} id="spec-import-name" class="text-caption text-fg-muted">
            {@panel.name}
          </p>
          <.input
            :if={@panel.preview}
            id="spec-import-note"
            name="import[note]"
            type="textarea"
            rows="2"
            label={dgettext("ui", "说明")}
            value={@panel.note}
            phx-debounce="300"
          />
        </.form>
        <div
          :if={@panel.stale}
          id="spec-import-stale"
          role="alert"
          class="flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <span class="flex-1">{dgettext("ui", "已有新版本 v%{n}", n: @panel.stale)}</span>
          <.button id="spec-import-repreview" size="xs" phx-click="import_preview">{dgettext(
            "ui",
            "重新预览"
          )}</.button>
        </div>
        <div :if={@panel.preview} id="spec-import-preview" class="flex flex-col gap-3">
          <p :if={@panel.preview.change_id} class="text-body text-fg-muted" id="spec-import-change-id">
            change_id：<code class="font-mono">{@panel.preview.change_id}</code>
          </p>
          <div id="spec-import-validation" class="text-body">
            <p :if={@panel.preview.validation.valid} class="text-success-fg">
              {dgettext("ui", "校验通过")}
            </p>
            <ul :if={!@panel.preview.validation.valid} class="flex flex-col gap-1 text-danger-fg">
              <li :for={e <- @panel.preview.validation.errors} class="font-mono text-caption">
                {SpecErrors.validation_line(e)}
              </li>
            </ul>
          </div>
          <p
            :if={@panel.preview.warnings != []}
            id="spec-import-warnings"
            class="text-body text-warning-fg"
          >
            {dgettext("ui", "忽略的路径：%{paths}", paths: Enum.join(@panel.preview.warnings, "、"))}
          </p>
          <.diff result={@panel.preview.diff} />
        </div>
      </div>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            :if={@panel && @panel.preview}
            id="spec-import-submit"
            type="submit"
            form="spec-import-form"
            variant="primary"
          >
            {dgettext("ui", "导入为 v%{n}", n: @panel.preview.base_version + 1)}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp upload_error(:too_large), do: dgettext("ui", "文件超过 2 MB")
  defp upload_error(:not_accepted), do: dgettext("ui", "只接受 tar.gz 或 zip")
  defp upload_error(:too_many_files), do: dgettext("ui", "只能上传一个文件")
  defp upload_error(other), do: to_string(other)
end
