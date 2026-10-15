defmodule HelmsmanWeb.SpecVersionForm do
  @moduledoc """
  The 提交新版本 panel of the spec page (add-spec-workflow-ui D8): the files of the base
  version edited one by one, `specs/<capability>/spec.md` added or files removed, the
  note, a dry-run 校验 and the submission of only the changed files.

  The page keeps the state in `socket.assigns.version_form` (`nil` when closed), forwards
  the `ver_*` events to `handle_event/3` and calls `newer/2` when a version arrives while
  the panel is open. A `stale_version` answer keeps the input; `rebase/2` takes the
  newest files for every file the user did not change and lists the files both sides
  changed (提交后将覆盖).
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.{SpecData, SpecErrors}

  @max_file 262_144
  @max_total 1_048_576
  @max_files 64
  @max_note 4096
  @capability ~r/\A[a-z0-9][a-z0-9-]{0,63}(\/[a-z0-9][a-z0-9-]{0,63}){0,2}\z/

  def limits, do: %{file: @max_file, total: @max_total, files: @max_files, note: @max_note}

  @doc """
  A form on version `base` (0: none) with its files `%{path => content}`; without files,
  the skeleton of a first version.
  """
  def new(base, files, change_id \\ nil) do
    files = if base == 0 and files == %{}, do: skeleton(), else: files

    %{
      base: base,
      files:
        Enum.map(
          sort_paths(Map.keys(files)),
          &file_row(&1, files[&1], if(base == 0, do: nil, else: files[&1]))
        ),
      note: "",
      change_id: change_id,
      cap: "",
      cap_error: nil,
      validation: nil,
      error: nil,
      file_errors: %{},
      stale: nil,
      newer: nil,
      conflicts: []
    }
  end

  defp file_row(path, content, original),
    do: %{path: path, content: content, original: original, removed: false, preview: false}

  defp skeleton do
    %{
      "proposal.md" => "## Why\n\n\n## What Changes\n\n- \n",
      "design.md" => "## Context\n\n\n## Decisions\n\n",
      "tasks.md" => "## 1. 实现\n\n- [ ] 1.1 \n",
      "specs/core/spec.md" =>
        "## ADDED Requirements\n\n### Requirement: 需求名\n\n系统 MUST ……\n\n#### Scenario: 场景名\n- **WHEN** ……\n- **THEN** ……\n"
    }
  end

  @doc "proposal.md, design.md, tasks.md first, then the others by path."
  def sort_paths(paths) do
    {top, rest} = Enum.split_with(paths, &(&1 in ["proposal.md", "design.md", "tasks.md"]))

    Enum.sort_by(
      top,
      &Enum.find_index(["proposal.md", "design.md", "tasks.md"], fn p -> p == &1 end)
    ) ++
      Enum.sort(rest)
  end

  ## Derived

  def changed?(%{removed: true, original: o}), do: o != nil
  def changed?(%{removed: false, original: o, content: c}), do: o != c

  def kept(form), do: Enum.reject(form.files, & &1.removed)
  def total(form), do: form |> kept() |> Enum.map(&byte_size(&1.content)) |> Enum.sum()

  def over_limit?(form) do
    kept = kept(form)

    length(kept) > @max_files or total(form) > @max_total or
      Enum.any?(kept, &(byte_size(&1.content) > @max_file)) or byte_size(form.note) > @max_note
  end

  def dirty?(nil), do: false
  def dirty?(form), do: form.note != "" or Enum.any?(form.files, &changed?/1)

  @doc "The attrs of `submit_version/3`: only the changed files and the removed paths."
  def attrs(form, opts \\ []) do
    changes = Enum.filter(form.files, &changed?/1)

    %{
      base_version: form.base,
      files: for(f <- changes, not f.removed, do: %{path: f.path, content: f.content}),
      remove: for(f <- changes, f.removed, do: f.path),
      note: form.note,
      dry_run: Keyword.get(opts, :dry_run, false)
    }
    |> then(fn a ->
      if form.base == 0 and form.change_id not in [nil, ""],
        do: Map.put(a, :change_id, form.change_id),
        else: a
    end)
  end

  ## Changes

  def change(form, params) do
    files =
      Enum.with_index(form.files, fn f, i ->
        case get_in(params, ["files", to_string(i)]) do
          content when is_binary(content) -> %{f | content: content}
          _ -> f
        end
      end)

    %{
      form
      | files: files,
        note: Map.get(params, "note", form.note),
        change_id: Map.get(params, "change_id", form.change_id),
        cap: Map.get(params, "cap", form.cap),
        cap_error: cap_error(Map.get(params, "cap", form.cap), form)
    }
  end

  defp cap_error("", _form), do: nil

  defp cap_error(cap, form) do
    cond do
      not (cap =~ @capability) ->
        dgettext("ui", "capability 是 1–3 段小写字母、数字与 -，用 / 分隔")

      Enum.any?(form.files, &(&1.path == "specs/#{cap}/spec.md" and not &1.removed)) ->
        dgettext("ui", "这个文件已存在")

      true ->
        nil
    end
  end

  def add(%{cap: cap} = form) do
    case {cap, cap_error(cap, form)} do
      {"", _} ->
        %{form | cap_error: dgettext("ui", "填写 capability")}

      {cap, nil} ->
        path = "specs/#{cap}/spec.md"

        files =
          case Enum.find_index(form.files, &(&1.path == path)) do
            nil -> form.files ++ [file_row(path, "## ADDED Requirements\n\n", nil)]
            i -> List.update_at(form.files, i, &%{&1 | removed: false})
          end

        %{form | files: files, cap: "", cap_error: nil}

      {_cap, error} ->
        %{form | cap_error: error}
    end
  end

  def remove(form, i), do: %{form | files: List.update_at(form.files, i, &remove_row/1)}

  defp remove_row(%{path: p} = f) when p in ["proposal.md", "tasks.md"], do: f
  defp remove_row(f), do: %{f | removed: true}

  def restore(form, i),
    do: %{form | files: List.update_at(form.files, i, &%{&1 | removed: false})}

  def toggle_preview(form, i),
    do: %{form | files: List.update_at(form.files, i, &%{&1 | preview: !&1.preview})}

  @doc "A newer version arrived while the panel is open (it will conflict)."
  def newer(nil, _info), do: nil

  def newer(%{base: base} = form, %{latest: latest} = info) when latest > base,
    do: %{form | newer: info}

  def newer(form, _info), do: form

  @doc """
  Rebases on the latest version `latest` with files `%{path => content}`: the user's
  changed files stay, the others become the latest ones; `conflicts` lists the files
  the user changed that also changed in `latest`.
  """
  def rebase(form, latest, latest_files) do
    mine = Map.new(Enum.filter(form.files, &changed?/1), &{&1.path, &1})

    conflicts =
      for {path, f} <- mine,
          f.original != nil,
          Map.get(latest_files, path) != f.original,
          do: path

    paths = sort_paths(Enum.uniq(Map.keys(latest_files) ++ Map.keys(mine)))

    files =
      Enum.map(paths, fn path ->
        case mine[path] do
          nil -> file_row(path, latest_files[path], latest_files[path])
          f -> %{f | original: latest_files[path]}
        end
      end)

    %{
      form
      | base: latest,
        files: files,
        stale: nil,
        newer: nil,
        conflicts: Enum.sort(conflicts),
        validation: nil,
        error: nil
    }
  end

  @doc "Applies a domain error; `{form, reload?}`."
  def put_error(form, {:spec, :stale_version, latest}, author),
    do: %{form | stale: %{latest: latest, author: author}, error: nil}

  def put_error(form, {:spec, :invalid_files, problems}, _author),
    do: %{
      form
      | file_errors: Map.new(problems, &{&1.path, &1.message}),
        error: SpecErrors.message({:spec, :invalid_files, problems})
    }

  def put_error(form, reason, _author), do: %{form | error: SpecErrors.message(reason)}

  ## Events (forwarded by the page)

  @doc "Handles a `ver_*` event: `{:noreply, socket}`; submissions call `on_submit`."
  def handle_event("ver_change", %{"version" => params}, socket),
    do: {:noreply, update(socket, &change(&1, params))}

  def handle_event("ver_add", _params, socket), do: {:noreply, update(socket, &add/1)}

  def handle_event("ver_remove", %{"index" => i}, socket),
    do: {:noreply, update(socket, &remove(&1, String.to_integer(i)))}

  def handle_event("ver_restore", %{"index" => i}, socket),
    do: {:noreply, update(socket, &restore(&1, String.to_integer(i)))}

  def handle_event("ver_preview", %{"index" => i}, socket),
    do: {:noreply, update(socket, &toggle_preview(&1, String.to_integer(i)))}

  def handle_event("ver_validate", _params, socket) do
    form = socket.assigns.version_form
    %{current_scope: scope, ident: ident} = socket.assigns

    case SpecData.submit_version(scope, ident, attrs(form, dry_run: true)) do
      {:ok, %{validation: validation}} ->
        {:noreply, update(socket, &%{&1 | validation: validation, error: nil, file_errors: %{}})}

      {:error, reason} ->
        {:noreply, update(socket, &put_error(&1, reason, author(socket, reason)))}
    end
  end

  defp update(socket, fun),
    do: Phoenix.Component.assign(socket, :version_form, fun.(socket.assigns.version_form))

  defp author(socket, {:spec, :stale_version, latest}) do
    case Enum.find(socket.assigns.versions, &(&1.number == latest)) do
      %{author: author} -> author
      _ -> nil
    end
  end

  defp author(_socket, _reason), do: nil

  ## Rendering

  attr :form, :map, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, required: true
  attr :diff_path, :any, required: true, doc: "fn from, to -> path of the diff tab"
  attr :closed, :boolean, default: false

  def panel(assigns) do
    assigns = assign(assigns, limits: limits())

    ~H"""
    <.side_panel
      id="spec-version-panel"
      show={@form != nil}
      width={:wide}
      title={if @form, do: dgettext("ui", "提交 v%{n}", n: @form.base + 1), else: ""}
      dirty={dirty?(@form)}
      patch_on_close={@close_path}
    >
      <:error :if={@form && @form.error}>{@form.error}</:error>
      <div :if={@form} class="flex flex-col gap-4">
        <div
          :if={@form.stale || @form.newer}
          id="spec-version-stale"
          role="alert"
          class="flex flex-col gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
        >
          <span>
            {dgettext("ui", "%{author} 已提交 v%{n}",
              author: (@form.stale || @form.newer).author || "?",
              n: (@form.stale || @form.newer).latest
            )}
          </span>
          <div class="flex gap-2">
            <a
              id="spec-version-stale-diff"
              href={@diff_path.(@form.base, (@form.stale || @form.newer).latest)}
              target="_blank"
              rel="noopener"
              class="inline-flex h-6 items-center rounded-field border border-border bg-surface px-2 text-caption text-fg hover:bg-hover"
            >
              {dgettext("ui", "查看差异")}
            </a>
            <.button id="spec-version-rebase" size="xs" phx-click="ver_rebase">
              {dgettext("ui", "基于 v%{n} 重新提交", n: (@form.stale || @form.newer).latest)}
            </.button>
          </div>
        </div>
        <p :if={@closed} id="spec-version-closed" class="text-body text-fg-muted">
          {dgettext("ui", "规格已关闭，不能提交新版本")}
        </p>
        <.form
          for={%{}}
          as={:version}
          id="spec-version-form"
          phx-change="ver_change"
          phx-submit="ver_submit"
          class="flex flex-col gap-3"
        >
          <.input
            :if={@form.base == 0}
            id="spec-version-change-id"
            name="version[change_id]"
            label="change_id"
            value={@form.change_id}
            phx-debounce="300"
          />
          <div id="spec-version-files" class="flex flex-col gap-2">
            <div
              :for={{f, i} <- Enum.with_index(@form.files)}
              id={"spec-version-file-#{i}"}
              data-path={f.path}
              data-state={file_state(f)}
              class={[
                "flex flex-col gap-1 rounded-field border px-3 py-2",
                if(@form.file_errors[f.path], do: "border-danger", else: "border-border")
              ]}
            >
              <div class="flex flex-wrap items-center gap-2 text-body">
                <code class={["font-mono", f.removed && "line-through text-fg-subtle"]}>{f.path}</code>
                <.badge :if={f.original == nil and not f.removed} tone={:success}>
                  {dgettext("ui", "新增")}
                </.badge>
                <.badge :if={changed?(f) and f.original != nil and not f.removed} tone={:info}>
                  {dgettext("ui", "已改")}
                </.badge>
                <.badge :if={f.removed} tone={:danger}>{dgettext("ui", "待删除")}</.badge>
                <.badge :if={f.path in @form.conflicts} tone={:warning} data-conflict>
                  {dgettext("ui", "将覆盖 v%{n} 的修改", n: @form.base)}
                </.badge>
                <span
                  data-bytes
                  class={[
                    "ml-auto text-caption",
                    if(byte_size(f.content) > @limits.file,
                      do: "text-danger-fg",
                      else: "text-fg-muted"
                    )
                  ]}
                >
                  {dgettext("ui", "%{bytes} / %{max} 字节",
                    bytes: byte_size(f.content),
                    max: @limits.file
                  )}
                </span>
                <.button
                  :if={!f.removed}
                  size="xs"
                  variant="ghost"
                  phx-click="ver_preview"
                  phx-value-index={i}
                  id={"spec-version-file-#{i}-preview"}
                >
                  {if f.preview, do: dgettext("ui", "编辑"), else: dgettext("ui", "预览")}
                </.button>
                <.button
                  :if={!f.removed and f.path not in ["proposal.md", "tasks.md"]}
                  size="xs"
                  variant="ghost"
                  phx-click="ver_remove"
                  phx-value-index={i}
                  id={"spec-version-file-#{i}-remove"}
                >
                  {dgettext("ui", "删除")}
                </.button>
                <.button
                  :if={f.removed}
                  size="xs"
                  variant="ghost"
                  phx-click="ver_restore"
                  phx-value-index={i}
                  id={"spec-version-file-#{i}-restore"}
                >
                  {dgettext("ui", "撤销删除")}
                </.button>
              </div>
              <p :if={@form.file_errors[f.path]} class="text-caption text-danger-fg" data-file-error>
                {@form.file_errors[f.path]}
              </p>
              <textarea
                :if={!f.removed}
                id={"spec-version-file-#{i}-content"}
                name={"version[files][#{i}]"}
                rows="10"
                phx-debounce="blur"
                class={[
                  "w-full rounded-field border border-border bg-surface px-2 py-1.5 font-mono text-caption",
                  f.preview && "hidden"
                ]}
              >{Phoenix.HTML.Form.normalize_value("textarea", f.content)}</textarea>
              <.markdown
                :if={!f.removed and f.preview}
                content={f.content}
                scope={@scope}
                anchor_ns={"spec-pv-#{i}"}
              />
            </div>
          </div>
          <div class="flex items-end gap-2">
            <div class="flex-1">
              <.input
                id="spec-version-cap"
                name="version[cap]"
                label={dgettext("ui", "添加规格文件：specs/<capability>/spec.md")}
                value={@form.cap}
                placeholder="settings"
                errors={if(@form.cap_error, do: [@form.cap_error], else: [])}
                phx-debounce="300"
              />
            </div>
            <.button id="spec-version-add" size="sm" icon="lucide-plus" phx-click="ver_add">{dgettext(
              "ui",
              "添加"
            )}</.button>
          </div>
          <.input
            id="spec-version-note"
            name="version[note]"
            type="textarea"
            rows="3"
            label={dgettext("ui", "说明")}
            value={@form.note}
            errors={
              if(byte_size(@form.note) > @limits.note, do: [dgettext("ui", "说明不能超过 4 KB")], else: [])
            }
            phx-debounce="300"
          />
          <p
            id="spec-version-total"
            class={[
              "text-caption",
              if(over_limit?(@form), do: "text-danger-fg", else: "text-fg-muted")
            ]}
          >
            {dgettext("ui", "%{n} / %{max_n} 个文件 · %{bytes} / %{max} 字节",
              n: length(kept(@form)),
              max_n: @limits.files,
              bytes: total(@form),
              max: @limits.total
            )}
          </p>
        </.form>
        <div :if={@form.validation} id="spec-version-validation" class="text-body">
          <p :if={@form.validation.valid} class="text-success-fg">{dgettext("ui", "校验通过")}</p>
          <ul :if={!@form.validation.valid} class="flex flex-col gap-1 text-danger-fg">
            <li :for={e <- @form.validation.errors} class="font-mono text-caption">
              {SpecErrors.validation_line(e)}
            </li>
          </ul>
        </div>
      </div>
      <:footer :let={cancel}>
        <span
          :if={@form && @form.validation && !@form.validation.valid}
          class="text-caption text-warning-fg"
          id="spec-version-draft-note"
        >
          {dgettext("ui", "校验未通过，定稿前需要修好")}
        </span>
        <span :if={!(@form && @form.validation && !@form.validation.valid)} />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="spec-version-validate"
            phx-click="ver_validate"
            disabled={@form == nil or over_limit?(@form)}
          >
            {dgettext("ui", "校验")}
          </.button>
          <.button
            id="spec-version-submit"
            type="submit"
            form="spec-version-form"
            variant="primary"
            disabled={@form == nil or over_limit?(@form) or @closed or @form.stale != nil}
            phx-disable-with={dgettext("ui", "正在提交…")}
          >
            {if @form, do: dgettext("ui", "提交 v%{n}", n: @form.base + 1), else: ""}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp file_state(%{removed: true}), do: "removed"
  defp file_state(%{original: nil}), do: "added"
  defp file_state(f), do: if(changed?(f), do: "changed", else: "same")
end
