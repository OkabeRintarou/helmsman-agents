defmodule HelmsmanWeb.AutopilotForm do
  @moduledoc """
  The new / edit panel of autopilots (add-squads-autopilots-ui D10; spec web-autopilots
  新建与编辑自动化). The state is a plain map kept by the page (`AutopilotLive.Index` for
  `?panel=new-autopilot`, `AutopilotLive.Show` for `?panel=edit`); the page forwards the
  `ap_form_*` events to `handle_event/3`.

  * Schedule presets (不定时 / 每小时 / 每天 / 每个工作日 / 每周 / 自定义 cron) generate a
    5-field expression (`cron_of/1`); an edit recognises an expression a preset generates
    again and otherwise shows it as 自定义 cron (`preset_of/1`).
  * Every change of the schedule or the time zone asks the domain's `preview/3` (the
    inputs are debounced 300 ms) for the description and the next 5 times; its errors
    show under the schedule.
  * Targets: the managed, unarchived agents with the current user's dispatchability
    (`RunData.availability/1`; `:unauthorized` ones are not selectable) and, in
    `create_task` mode, the enabled squads (`SquadData`).
  * A new autopilot's time zone defaults to the browser's (`timezone` connect param).
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AutopilotComponents, only: [local_time: 3]

  alias Helmsman.{Agents, Projects}

  alias HelmsmanWeb.{
    AutopilotComponents,
    AutopilotData,
    CronText,
    FormErrors,
    MarkdownEditor,
    RunComponents,
    RunData,
    SquadData
  }

  @max_instructions 16_384
  @keys ~w(name mode agent project title_template instructions create_tasks schedule minute
           time days cron timezone overlap)
  @defaults %{
    "name" => "",
    "mode" => "create_task",
    "agent" => "",
    "project" => "",
    "title_template" => "{{date}}",
    "instructions" => "",
    "create_tasks" => "false",
    "schedule" => "none",
    "minute" => "0",
    "time" => "09:00",
    "days" => ["1"],
    "cron" => "",
    "timezone" => "UTC",
    "overlap" => "skip"
  }

  ## State

  @doc "A new-autopilot panel of generation `gen`; `timezone` is the browser's."
  def new(scope, gen, timezone) do
    %{base_form(scope, gen, timezone) | params: %{@defaults | "timezone" => timezone}}
    |> load_targets(scope)
    |> refresh_preview()
  end

  @doc "An edit panel of generation `gen` for the autopilot `view`."
  def edit(scope, gen, view, timezone) do
    %{base_form(scope, gen, timezone) | mode: :edit, id: view.id, base: view}
    |> Map.put(:params, params_of(view))
    |> Map.put(:own?, AutopilotData.own?(view, scope))
    |> load_targets(scope)
    |> refresh_preview()
  end

  defp base_form(scope, gen, timezone) do
    %{
      mode: :new,
      gen: gen,
      id: nil,
      base: nil,
      params: @defaults,
      errors: %{},
      error: nil,
      stale: false,
      preview: nil,
      previewed: nil,
      targets: %{agents: [], squads: []},
      projects: [],
      browser_tz: timezone,
      own?: false,
      user_name: (scope.actor && scope.actor.name) || scope.user.display_name
    }
    |> load_projects(scope)
  end

  defp params_of(view) do
    @defaults
    |> Map.merge(%{
      "name" => view.name,
      "mode" => to_string(view.mode),
      "agent" => (view.agent && view.agent.name) || "",
      "project" => (view.project && view.project.key) || "",
      "title_template" => view.title_template || "",
      "instructions" => view.instructions || "",
      "create_tasks" => to_string(view.create_tasks == true),
      "timezone" => view.timezone || "UTC",
      "overlap" => to_string(view.overlap || "skip")
    })
    |> Map.merge(preset_of(view.cron))
  end

  ## Schedule presets

  @doc """
  The schedule params of a stored `cron`: a preset when the preset generates exactly
  this expression again, otherwise `custom`.

      iex> HelmsmanWeb.AutopilotForm.preset_of("30 18 * * 1,3")
      %{"schedule" => "weekly", "time" => "18:30", "days" => ["1", "3"]}

      iex> HelmsmanWeb.AutopilotForm.preset_of("0 9 1-7 * 1")
      %{"schedule" => "custom", "cron" => "0 9 1-7 * 1"}
  """
  def preset_of(cron) when cron in [nil, ""], do: %{"schedule" => "none"}

  def preset_of(cron) do
    normalized = cron |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")

    candidate =
      case String.split(normalized, " ") do
        [m, "*", "*", "*", "*"] -> %{"schedule" => "hourly", "minute" => m}
        [m, h, "*", "*", "*"] -> %{"schedule" => "daily", "time" => hhmm(h, m)}
        [m, h, "*", "*", "1-5"] -> %{"schedule" => "weekdays", "time" => hhmm(h, m)}
        [m, h, "*", "*", dow] -> weekly_preset(h, m, dow)
        _ -> nil
      end

    if candidate && cron_of(Map.merge(@defaults, candidate)) == {:ok, normalized},
      do: candidate,
      else: %{"schedule" => "custom", "cron" => cron}
  end

  defp weekly_preset(h, m, dow),
    do: %{"schedule" => "weekly", "time" => hhmm(h, m), "days" => String.split(dow, ",")}

  defp hhmm(h, m) do
    with {:ok, h} <- int(h, 0, 23), {:ok, m} <- int(m, 0, 59) do
      pad(h) <> ":" <> pad(m)
    else
      _ -> "invalid"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  The cron expression of the schedule params: `{:ok, cron | nil}` (nil = 不定时) or
  `{:error, message}`.

      iex> HelmsmanWeb.AutopilotForm.cron_of(%{"schedule" => "weekly", "time" => "18:30", "days" => ["3", "1"]})
      {:ok, "30 18 * * 1,3"}
  """
  def cron_of(%{"schedule" => "none"}), do: {:ok, nil}

  def cron_of(%{"schedule" => "hourly"} = p) do
    case int(p["minute"], 0, 59) do
      {:ok, m} -> {:ok, "#{m} * * * *"}
      :error -> {:error, dgettext("ui", "分钟须为 0–59")}
    end
  end

  def cron_of(%{"schedule" => schedule} = p) when schedule in ~w(daily weekdays weekly) do
    with {:ok, {h, m}} <- time(p["time"]),
         {:ok, dow} <- dow(schedule, p["days"]) do
      {:ok, "#{m} #{h} * * #{dow}"}
    end
  end

  def cron_of(%{"schedule" => "custom"} = p) do
    case p["cron"] |> to_string() |> String.split(~r/\s+/, trim: true) |> Enum.join(" ") do
      "" -> {:error, dgettext("ui", "请输入 cron 表达式")}
      cron -> {:ok, cron}
    end
  end

  def cron_of(_params), do: {:ok, nil}

  defp dow("daily", _days), do: {:ok, "*"}
  defp dow("weekdays", _days), do: {:ok, "1-5"}

  defp dow("weekly", days) do
    days =
      for d <- List.wrap(days), {:ok, n} <- [int(d, 0, 6)], uniq: true, do: n

    case Enum.sort_by(days, &rem(&1 + 6, 7)) do
      [] -> {:error, dgettext("ui", "至少选择一天")}
      days -> {:ok, Enum.join(days, ",")}
    end
  end

  defp time(text) do
    with [h, m] <- String.split(to_string(text), ":", parts: 2),
         {:ok, h} <- int(h, 0, 23),
         {:ok, m} <- int(String.slice(m, 0, 2), 0, 59) do
      {:ok, {h, m}}
    else
      _ -> {:error, dgettext("ui", "请输入有效的时刻")}
    end
  end

  defp int(text, min, max) do
    case Integer.parse(to_string(text)) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  ## Options

  defp load_targets(form, scope) do
    availability =
      case RunData.availability(scope) do
        {:ok, map} -> map
        _ -> %{}
      end

    agents =
      case Agents.list(scope) do
        {:ok, list} ->
          for a <- list, a.kind == "managed", not a.archived do
            result = get_in(availability, [a.name, :result]) || :ok

            %{
              name: a.name,
              selectable?: result != {:skipped, :unauthorized},
              note: RunComponents.unavailable_reason(a.name, result)
            }
          end

        _ ->
          []
      end

    %{form | targets: %{agents: agents, squads: squads(scope)}}
    |> keep_current_target()
  end

  defp squads(scope) do
    case SquadData.list(scope) do
      {:ok, list} ->
        availability = SquadData.availability(scope)

        for s <- list, not s.disabled do
          result = Map.get(availability, s.name, :ok)

          %{
            name: s.name,
            selectable?: not unauthorized?(result),
            note: squad_note(s.name, result)
          }
        end

      _ ->
        []
    end
  end

  defp unauthorized?({:skipped, :unauthorized, _refused}), do: true
  defp unauthorized?(_result), do: false

  defp squad_note(_name, :ok), do: nil

  defp squad_note(_name, {:skipped, :unauthorized, refused})
       when is_list(refused) and refused != [],
       do: dgettext("ui", "你无权触发 %{names}", names: Enum.join(refused, "、"))

  defp squad_note(name, {:skipped, :unauthorized, _}),
    do: dgettext("ui", "你无权触发 %{name}", name: name)

  defp squad_note(_name, {:skipped, :squad_disabled, _}), do: dgettext("ui", "小队已停用")
  defp squad_note(_name, {:skipped, :agent_archived, _}), do: dgettext("ui", "leader 已归档")
  defp squad_note(_name, {:skipped, :agent_disabled, _}), do: dgettext("ui", "leader 已停用")
  defp squad_note(name, _result), do: dgettext("ui", "不能启动 %{name}", name: name)

  # An edit keeps the stored target selectable-as-is even when it is no longer offered
  # (archived, disabled squad …), so saving other fields does not silently change it.
  defp keep_current_target(%{base: %{agent: %{name: name, kind: kind}}} = form) do
    key = if to_string(kind) == "squad", do: :squads, else: :agents

    if Enum.any?(form.targets[key], &(&1.name == name)),
      do: form,
      else:
        put_in(
          form,
          [:targets, key],
          form.targets[key] ++ [%{name: name, selectable?: true, note: nil}]
        )
  end

  defp keep_current_target(form), do: form

  defp load_projects(form, scope) do
    projects =
      case Projects.list(scope) do
        {:ok, list} -> Enum.map(list, &%{key: &1.key, name: &1.name})
        _ -> []
      end

    %{form | projects: projects}
  end

  defp squad?(form, name), do: Enum.any?(form.targets.squads, &(&1.name == name))

  ## Events

  @doc """
  Handles the `ap_form_*` events for a page keeping the form in
  `socket.assigns.autopilot_form`: `{:noreply, socket}`, `{:saved, view, socket}` after a
  successful submit, or `{:closed, message, socket}` when the panel must close with an
  error message (`forbidden`, `not_found`).
  """
  def handle_event(event, params, %{assigns: %{autopilot_form: %{} = form}} = socket) do
    scope = socket.assigns.current_scope

    case event do
      "ap_form_change" ->
        {:noreply, put(socket, change(form, params["autopilot"] || %{}))}

      "ap_form_reload" ->
        {:noreply, put(socket, reload(form, scope))}

      "ap_form_submit" ->
        handle_submit(form, scope, params, socket)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp handle_submit(form, scope, params, socket) do
    case submit(form, scope, params["autopilot"] || %{}) do
      {:ok, view} -> {:saved, view, socket}
      {:error, form} -> {:noreply, put(socket, form)}
      {:close, reason, form} -> {:closed, close_text(form, reason), socket}
    end
  end

  defp put(socket, form), do: Phoenix.Component.assign(socket, :autopilot_form, form)

  defp close_text(form, :forbidden),
    do: dgettext("ui", "你无权触发 %{target}", target: form.params["agent"])

  defp close_text(_form, :not_found), do: dgettext("ui", "这个自动化已不存在")
  defp close_text(_form, _reason), do: dgettext("ui", "操作失败，请重试")

  @doc "`phx-change`: keeps the input, updates the default title and the preview."
  def change(form, raw) do
    params = merge(form.params, raw)

    # The default title follows the name until the user edits the title.
    params =
      if form.params["title_template"] == default_title(form.params["name"]) and
           params["title_template"] == form.params["title_template"],
         do: %{params | "title_template" => default_title(params["name"])},
         else: params

    %{form | params: params}
    |> refresh_preview()
    |> local_agent_error()
  end

  defp default_title(name), do: String.trim("{{date}} " <> String.trim(to_string(name)))

  defp merge(params, raw) do
    Enum.reduce(@keys, params, fn key, acc ->
      case Map.fetch(raw, key) do
        {:ok, value} when key == "days" ->
          Map.put(acc, key, Enum.reject(List.wrap(value), &(&1 == "")))

        {:ok, value} when is_binary(value) ->
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  # 仅运行 with a squad selected (D10).
  defp local_agent_error(form) do
    errors = Map.delete(form.errors, :agent_mode)

    if form.params["mode"] == "run_only" and squad?(form, form.params["agent"]),
      do: %{form | errors: Map.put(errors, :agent_mode, [run_only_squad_text()])},
      else: %{form | errors: errors}
  end

  defp run_only_squad_text, do: dgettext("ui", "仅运行模式只能选托管 Agent")

  defp refresh_preview(form) do
    tz = form.params["timezone"]

    case cron_of(form.params) do
      {:ok, nil} ->
        %{form | preview: :none, previewed: nil}

      {:ok, cron} when {cron, tz} == form.previewed ->
        form

      {:ok, cron} ->
        preview =
          case AutopilotData.preview(cron, tz, 5) do
            {:ok, times} -> {:ok, CronText.describe(cron, tz), times}
            {:error, errors} -> {:error, schedule_messages(errors)}
          end

        %{form | preview: preview, previewed: {cron, tz}}

      {:error, message} ->
        %{form | preview: {:error, [message]}, previewed: nil}
    end
  end

  defp schedule_messages(errors) do
    for {field, messages} <- errors, msg <- List.wrap(messages), do: schedule_text(field, msg)
  end

  @doc "Display text of a `cron` / `timezone` error of `preview/3` or a save."
  def schedule_text(:cron, msg) when msg in [:too_frequent, "too_frequent", "is too frequent"],
    do: dgettext("ui", "两次之间至少 5 分钟")

  def schedule_text(:cron, _msg), do: dgettext("ui", "不是有效的 cron 表达式（标准 5 段：分 时 日 月 周）")
  def schedule_text(:timezone, _msg), do: dgettext("ui", "未知的时区")
  def schedule_text(_field, msg), do: to_string(msg)

  defp reload(%{mode: :edit} = form, scope) do
    case AutopilotData.get(scope, form.id) do
      {:ok, view} -> edit(scope, form.gen + 1, view, form.browser_tz)
      _ -> %{form | stale: false, error: close_text(form, :not_found)}
    end
  end

  defp reload(form, _scope), do: form

  @doc """
  `phx-submit`: `{:ok, view}`, `{:error, form}` (field errors or a message at the top,
  input kept) or `{:close, reason, form}` (`forbidden`, `not_found`).
  """
  def submit(form, scope, raw) do
    form = change(form, raw)

    case cron_of(form.params) do
      {:ok, cron} ->
        save(form, scope, attrs(form.params, cron))

      {:error, message} ->
        {:error, local_agent_error(%{form | errors: %{schedule: [message]}, error: nil})}
    end
  end

  defp save(form, scope, attrs) do
    result =
      case form.mode do
        :new ->
          AutopilotData.create(scope, attrs)

        :edit ->
          AutopilotData.update(
            scope,
            form.id,
            attrs |> drop_unchanged(form.base) |> Map.put("lock_version", form.base.lock_version)
          )
      end

    case result do
      {:ok, view} ->
        {:ok, view}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error,
         local_agent_error(%{form | errors: changeset_errors(cs), error: nil, stale: false})}

      {:error, :stale} ->
        {:error, %{form | stale: true, error: nil}}

      {:error, :limit_reached} ->
        {:error, %{form | error: dgettext("ui", "每个工作区最多 100 个自动化"), errors: %{}}}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:close, reason, form}

      {:error, _} ->
        {:error, %{form | error: close_text(form, :failed)}}
    end
  end

  defp attrs(p, cron) do
    create_task? = p["mode"] == "create_task"

    %{
      "name" => String.trim(p["name"]),
      "mode" => p["mode"],
      "agent" => blank_nil(p["agent"]),
      "project" => blank_nil(p["project"]),
      "title_template" => if(create_task?, do: blank_nil(p["title_template"])),
      "instructions" => p["instructions"],
      "create_tasks" => not create_task? and p["create_tasks"] == "true",
      "cron" => cron,
      "timezone" => String.trim(p["timezone"]),
      "overlap" => p["overlap"]
    }
  end

  # The stored target and project stay as they are when not changed, even when they are
  # archived since (the domain only checks the ones given).
  defp drop_unchanged(attrs, base) do
    attrs
    |> drop_if("agent", base.agent && base.agent.name)
    |> drop_if("project", base.project && base.project.key)
  end

  defp drop_if(attrs, key, current) do
    if current != nil and attrs[key] == current, do: Map.delete(attrs, key), else: attrs
  end

  defp blank_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      v -> v
    end
  end

  defp changeset_errors(cs) do
    messages = FormErrors.messages(cs)

    schedule =
      for field <- [:cron, :timezone], Map.has_key?(messages, field), into: %{} do
        {field, for({^field, {msg, _}} <- cs.errors, do: schedule_text(field, msg))}
      end

    messages = Map.merge(messages, schedule)

    if Enum.any?(cs.errors, &match?({:agent, {"must be a managed agent", _}}, &1)),
      do: Map.put(messages, :agent, [dgettext("ui", "须为托管 Agent（仅运行模式不能选小队）")]),
      else: messages
  end

  ## Rendering

  attr :form, :map, required: true
  attr :scope, :map, required: true
  attr :close_path, :string, default: nil

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="autopilot-panel"
      show={@form != nil}
      title={panel_title(@form)}
      width={:wide}
      dirty={@form != nil}
      patch_on_close={@close_path}
    >
      <:error :if={@form && @form.error}>{@form.error}</:error>
      <div
        :if={@form && @form.stale}
        id="autopilot-form-stale"
        role="alert"
        class="mb-4 flex items-center gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="size-4 shrink-0" />
        <span class="flex-1">{dgettext("ui", "这个自动化刚被他人修改")}</span>
        <.button id="autopilot-form-reload" size="xs" phx-click="ap_form_reload">
          {dgettext("ui", "载入最新")}
        </.button>
      </div>
      <.autopilot_form :if={@form} form={@form} scope={@scope} />
      <:footer :let={cancel}>
        <p id="autopilot-initiator-note" class="min-w-0 text-caption text-fg-muted">
          {dgettext("ui", "保存后，定时与 webhook 触发以你的权限运行（你是授权来源）")}
        </p>
        <div class="flex flex-none items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="autopilot-form-submit"
            type="submit"
            form="autopilot-form"
            variant="primary"
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {if(@form && @form.mode == :new, do: dgettext("ui", "创建"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp panel_title(%{mode: :new}), do: dgettext("ui", "新建自动化")
  defp panel_title(%{mode: :edit, base: base}), do: dgettext("ui", "编辑 %{name}", name: base.name)
  defp panel_title(_), do: ""

  attr :form, :map, required: true
  attr :scope, :map, required: true

  defp autopilot_form(assigns) do
    form = assigns.form
    p = form.params
    create_task? = p["mode"] == "create_task"

    assigns =
      assign(assigns,
        p: p,
        e: form.errors,
        gen: form.gen,
        create_task?: create_task?,
        target_options: target_options(form, create_task?),
        target_notes: target_notes(form, create_task?),
        bytes: byte_size(p["instructions"] || ""),
        max_bytes: @max_instructions,
        other_initiator: other_initiator(form)
      )

    ~H"""
    <.form
      for={%{}}
      as={:autopilot}
      id="autopilot-form"
      phx-change="ap_form_change"
      phx-submit="ap_form_submit"
      class="flex flex-col gap-6"
    >
      <div
        :if={@other_initiator}
        id="autopilot-initiator-warning"
        role="status"
        class="flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
        {dgettext("ui", "当前以 %{initiator} 的权限运行；保存后改为以你（%{me}）的权限运行",
          initiator: @other_initiator,
          me: @form.user_name
        )}
      </div>

      <.input
        id="autopilot-name"
        name="autopilot[name]"
        label={dgettext("ui", "名字")}
        value={@p["name"]}
        errors={Map.get(@e, :name, [])}
        autocomplete="off"
        phx-debounce="300"
      />

      <fieldset id="autopilot-mode" class="flex flex-col gap-2">
        <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "模式")}</legend>
        <label
          :for={{value, label, help} <- mode_options()}
          class={[
            "flex cursor-pointer items-start gap-2 rounded-field border px-3 py-2",
            if(@p["mode"] == value, do: "border-brand", else: "border-border")
          ]}
        >
          <input
            type="radio"
            id={"autopilot-mode-#{value}"}
            name="autopilot[mode]"
            value={value}
            checked={@p["mode"] == value}
            class="mt-1 size-4 accent-brand"
          />
          <span class="flex flex-col">
            <span class="text-body font-medium text-fg">{label}</span>
            <span class="text-caption text-fg-muted">{help}</span>
          </span>
        </label>
        <.error_list id="autopilot-mode-error" errors={Map.get(@e, :mode, [])} />
      </fieldset>

      <div class="flex flex-col gap-1">
        <.input
          id="autopilot-agent"
          name="autopilot[agent]"
          type="select"
          label={dgettext("ui", "目标")}
          prompt={dgettext("ui", "选择 Agent 或小队")}
          value={@p["agent"]}
          options={@target_options}
          errors={Map.get(@e, :agent, []) ++ Map.get(@e, :agent_mode, [])}
        />
        <ul :if={@target_notes != []} id="autopilot-agent-notes" class="flex flex-col gap-0.5">
          <li
            :for={{name, note} <- @target_notes}
            class="text-caption text-fg-muted"
            data-target={name}
          >
            {dgettext("ui", "%{name}：%{note}", name: name, note: note)}
          </li>
        </ul>
      </div>

      <.input
        id="autopilot-project"
        name="autopilot[project]"
        type="select"
        label={dgettext("ui", "项目")}
        prompt={if(@create_task?, do: dgettext("ui", "选择项目"), else: dgettext("ui", "不选项目"))}
        value={@p["project"]}
        options={Enum.map(@form.projects, &{"#{&1.key} · #{&1.name}", &1.key})}
        errors={Map.get(@e, :project, [])}
        help={
          if(!@create_task?,
            do: dgettext("ui", "可选。项目绑定了仓库时，在基础分支的只读检出里运行")
          )
        }
      />

      <.input
        :if={@create_task?}
        id="autopilot-title-template"
        name="autopilot[title_template]"
        label={dgettext("ui", "标题模板")}
        value={@p["title_template"]}
        errors={Map.get(@e, :title_template, [])}
        help={
          dgettext(
            "ui",
            "{{date}} 换成触发日期（自动化时区里的 YYYY-MM-DD），{{source}} 换成触发方式（schedule / manual / webhook）"
          )
        }
        phx-debounce="300"
      />

      <div class="flex flex-col gap-1">
        <.live_component
          module={MarkdownEditor}
          id={"autopilot-instructions-#{@gen}"}
          session={@gen}
          scope={@scope}
          name="autopilot[instructions]"
          value={@p["instructions"]}
          label={dgettext("ui", "说明")}
          errors={Map.get(@e, :instructions, [])}
          submit={:form}
          rows={8}
        />
        <p
          id="autopilot-instructions-size"
          class={[
            "text-right text-caption",
            if(@bytes > @max_bytes, do: "text-danger-fg", else: "text-fg-muted")
          ]}
        >
          {dgettext("ui", "%{bytes} / %{max} 字节", bytes: @bytes, max: @max_bytes)}
        </p>
      </div>

      <.input
        :if={!@create_task?}
        id="autopilot-create-tasks"
        name="autopilot[create_tasks]"
        type="checkbox"
        label={dgettext("ui", "允许建任务")}
        checked={@p["create_tasks"] == "true"}
        help={dgettext("ui", "运行中的 Agent 可以在工作区里新建任务（不能修改已有任务）")}
        errors={Map.get(@e, :create_tasks, [])}
      />

      <.schedule_fields form={@form} p={@p} e={@e} />

      <fieldset id="autopilot-overlap" class="flex flex-col gap-2">
        <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "重叠策略")}</legend>
        <label
          :for={{value, label, help} <- overlap_options()}
          class="flex cursor-pointer items-start gap-2"
        >
          <input
            type="radio"
            id={"autopilot-overlap-#{value}"}
            name="autopilot[overlap]"
            value={value}
            checked={@p["overlap"] == value}
            class="mt-1 size-4 accent-brand"
          />
          <span class="flex flex-col">
            <span class="text-body text-fg">{label}</span>
            <span class="text-caption text-fg-muted">{help}</span>
          </span>
        </label>
        <.error_list id="autopilot-overlap-error" errors={Map.get(@e, :overlap, [])} />
      </fieldset>

      <p :if={@form.mode == :edit} id="autopilot-config-note" class="text-caption text-fg-muted">
        {dgettext(
          "ui",
          "修改模式、目标、项目、说明、标题模板、时区或「允许建任务」后，排队中的那次请求（如有）会作废。"
        )}
      </p>
    </.form>
    """
  end

  attr :form, :map, required: true
  attr :p, :map, required: true
  attr :e, :map, required: true

  defp schedule_fields(assigns) do
    form = assigns.form

    assigns =
      assign(assigns,
        schedule: assigns.p["schedule"],
        tz: assigns.p["timezone"],
        errors:
          preview_errors(form.preview) ++
            Map.get(assigns.e, :schedule, []) ++ Map.get(assigns.e, :cron, []),
        timezones: AutopilotComponents.timezones()
      )

    ~H"""
    <fieldset id="autopilot-schedule" class="flex flex-col gap-3">
      <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "计划")}</legend>
      <div class="flex flex-wrap gap-x-4 gap-y-1.5">
        <label
          :for={{value, label} <- schedule_options()}
          class="inline-flex cursor-pointer items-center gap-1.5 text-body text-fg"
        >
          <input
            type="radio"
            id={"autopilot-schedule-#{value}"}
            name="autopilot[schedule]"
            value={value}
            checked={@schedule == value}
            class="size-4 accent-brand"
          />
          {label}
        </label>
      </div>

      <.input
        :if={@schedule == "hourly"}
        id="autopilot-minute"
        name="autopilot[minute]"
        type="number"
        min="0"
        max="59"
        label={dgettext("ui", "每小时的第几分钟")}
        value={@p["minute"]}
        phx-debounce="300"
      />
      <div :if={@schedule == "weekly"} id="autopilot-days" class="flex flex-wrap gap-3">
        <input type="hidden" name="autopilot[days][]" value="" />
        <label
          :for={d <- [1, 2, 3, 4, 5, 6, 0]}
          class="inline-flex cursor-pointer items-center gap-1.5 text-body text-fg"
        >
          <input
            type="checkbox"
            id={"autopilot-day-#{d}"}
            name="autopilot[days][]"
            value={d}
            checked={to_string(d) in List.wrap(@p["days"])}
            class="size-4 accent-brand"
          />
          {CronText.weekday_name(d)}
        </label>
      </div>
      <.input
        :if={@schedule in ~w(daily weekdays weekly)}
        id="autopilot-time"
        name="autopilot[time]"
        type="time"
        label={dgettext("ui", "时刻")}
        value={@p["time"]}
        phx-debounce="300"
      />
      <.input
        :if={@schedule == "custom"}
        id="autopilot-cron"
        name="autopilot[cron]"
        label={dgettext("ui", "cron 表达式")}
        value={@p["cron"]}
        placeholder="0 9 * * 1-5"
        help={dgettext("ui", "标准 5 段：分 时 日 月 周")}
        autocomplete="off"
        phx-debounce="300"
      />
      <.input
        :if={@schedule != "none"}
        id="autopilot-timezone"
        name="autopilot[timezone]"
        label={dgettext("ui", "时区")}
        value={@tz}
        list="autopilot-timezones"
        autocomplete="off"
        errors={Map.get(@e, :timezone, [])}
        phx-debounce="300"
      />
      <input :if={@schedule == "none"} type="hidden" name="autopilot[timezone]" value={@tz} />
      <datalist id="autopilot-timezones">
        <option :for={tz <- @timezones} value={tz} />
      </datalist>

      <.error_list id="autopilot-schedule-errors" errors={@errors} />

      <p :if={@schedule == "none"} id="autopilot-preview-none" class="text-caption text-fg-muted">
        {dgettext("ui", "不定时：只能手动或通过 webhook 触发")}
      </p>
      <div
        :if={match?({:ok, _, _}, @form.preview)}
        id="autopilot-preview"
        class="flex flex-col gap-1 rounded-field border border-border bg-surface px-3 py-2"
      >
        <p id="autopilot-preview-text" class="text-body font-medium text-fg">
          {elem(@form.preview, 1)}
        </p>
        <p class="text-caption text-fg-muted">{dgettext("ui", "接下来 5 次：")}</p>
        <ol id="autopilot-preview-times" class="flex flex-col gap-0.5 text-label text-fg">
          <li :for={at <- elem(@form.preview, 2)} class="font-mono">
            {local_time(at, @tz, weekday: true)}
            <span :if={@form.browser_tz != @tz} class="text-fg-muted">
              {dgettext("ui", "（你的时间 %{time}）", time: local_time(at, @form.browser_tz, []))}
            </span>
          </li>
        </ol>
      </div>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  defp error_list(assigns) do
    ~H"""
    <div :if={@errors != []} id={@id} class="flex flex-col gap-0.5">
      <p :for={msg <- @errors} class="flex items-center gap-1 text-caption text-danger-fg">
        <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
      </p>
    </div>
    """
  end

  defp preview_errors({:error, messages}), do: messages
  defp preview_errors(_preview), do: []

  defp other_initiator(%{mode: :edit, own?: false, base: %{initiator: %{name: name}}}),
    do: name

  defp other_initiator(%{mode: :edit, base: %{initiator: nil}}), do: dgettext("ui", "（已离开的成员）")
  defp other_initiator(_form), do: nil

  defp target_options(form, create_task?) do
    agents = Enum.map(form.targets.agents, &option/1)
    squads = Enum.map(form.targets.squads, &option/1)

    [{"Agent", agents}] ++
      if(create_task? and squads != [], do: [{dgettext("ui", "小队"), squads}], else: [])
  end

  defp option(target) do
    label = if target.note, do: "#{target.name} — #{target.note}", else: target.name
    [key: label, value: target.name, disabled: not target.selectable?]
  end

  defp target_notes(form, create_task?) do
    targets = form.targets.agents ++ if(create_task?, do: form.targets.squads, else: [])
    for %{note: note, name: name} <- targets, note != nil, do: {name, note}
  end

  defp mode_options do
    [
      {"create_task", dgettext("ui", "建任务"), dgettext("ui", "在项目里建一张任务交给目标，之后走普通任务流程；要改代码选这个")},
      {"run_only", dgettext("ui", "仅运行"), dgettext("ui", "不建任务：Agent 看完写结论，不推送任何改动")}
    ]
  end

  defp schedule_options do
    [
      {"none", dgettext("ui", "不定时")},
      {"hourly", dgettext("ui", "每小时")},
      {"daily", dgettext("ui", "每天")},
      {"weekdays", dgettext("ui", "每个工作日")},
      {"weekly", dgettext("ui", "每周")},
      {"custom", dgettext("ui", "自定义 cron")}
    ]
  end

  defp overlap_options do
    [
      {"skip", dgettext("ui", "跳过"), dgettext("ui", "上一次还在进行时跳过本次")},
      {"queue", dgettext("ui", "排队"), dgettext("ui", "等上一次结束后执行最新的一次")}
    ]
  end
end
