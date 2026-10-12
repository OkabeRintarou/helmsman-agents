defmodule HelmsmanWeb.AgentForm do
  @moduledoc """
  The new / edit panel of managed agents (add-agents-runs-ui D5; spec web-agents 新建与编辑
  Agent). The state is a plain map kept by the page (`AgentLive.Index` for `?panel=new`,
  `AgentLive.Show` for `?panel=edit`); the page forwards the `agent_form_*` events here.

  * Only changed fields are submitted: an edit diffs against the view the panel opened
    with (`base`); an admin who does not own the agent diffs only the description and
    limit fields (the other groups render as `<fieldset disabled>`).
  * Secrets never reach the page: variable values and the MCP JSON are password inputs /
    textareas in `phx-update="ignore"` containers whose ids carry the panel generation
    (`gen`); their params are dropped before the state is stored.
  * Two local checks only: the MCP input must decode to a JSON object, and a new
    variable with a value needs a name. Everything else is the domain's changeset.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1, providers: 0]

  alias Helmsman.{Agents, Members, Runtimes}
  alias HelmsmanWeb.{FormErrors, MarkdownEditor}

  @basic ~w(description)
  @execution ~w(provider runtime_id model effort instructions custom_args)
  @access ~w(access access_member_ids capabilities)
  @limits ~w(max_concurrency timeout_minutes idle_timeout_minutes)
  @integers ~w(max_concurrency timeout_minutes idle_timeout_minutes)
  @defaults %{
    "name" => "",
    "description" => "",
    "provider" => "claude",
    "runtime_id" => "",
    "model" => "",
    "effort" => "",
    "instructions" => "",
    "custom_args" => "",
    "access" => "owner_only",
    "access_member_ids" => [],
    "capabilities" => [],
    "max_concurrency" => "2",
    "timeout_minutes" => "120",
    "idle_timeout_minutes" => "20",
    "env_delete" => [],
    "env_add" => %{}
  }

  ## State

  @doc "A new-agent panel of generation `gen`."
  def new(scope, gen) do
    %{
      mode: :new,
      gen: gen,
      name: nil,
      base: nil,
      configure?: true,
      params: @defaults,
      add_rows: [],
      errors: %{},
      error: nil,
      notice: nil
    }
    |> load_options(scope)
  end

  @doc "An edit panel of generation `gen` for the agent `view` (with its `permissions`)."
  def edit(scope, gen, view, permissions) do
    %{
      mode: :edit,
      gen: gen,
      name: view.name,
      base: view,
      configure?: permissions.configure,
      params: params_of(view),
      add_rows: [],
      errors: %{},
      error: nil,
      notice: nil
    }
    |> load_options(scope)
  end

  defp params_of(view) do
    strings =
      Map.new(~w(description provider model effort instructions access)a, fn key ->
        {Atom.to_string(key), Map.get(view, key) || @defaults[Atom.to_string(key)]}
      end)

    Map.merge(@defaults, strings)
    |> Map.merge(%{
      "name" => view.name,
      "runtime_id" => runtime_param(view.runtime),
      "custom_args" => Enum.join(List.wrap(view.custom_args), "\n"),
      "access_member_ids" => Enum.map(List.wrap(view.access_member_ids), &to_string/1),
      "capabilities" => List.wrap(view.capabilities),
      "max_concurrency" => to_string(view.max_concurrency),
      "timeout_minutes" => to_string(view.timeout_minutes),
      "idle_timeout_minutes" => to_string(view.idle_timeout_minutes)
    })
  end

  defp runtime_param(%{id: id}), do: to_string(id)
  defp runtime_param(_runtime), do: ""

  # Runtimes the owner may bind (their own, enabled, same CLI) and the members who may be
  # named in `access_member_ids` (member and above, not the owner).
  defp load_options(form, scope) do
    owner_id = if form.base, do: form.base.owner.id, else: scope.user.id

    members =
      case Members.list(scope) do
        {:ok, members} ->
          Enum.filter(members, &(&1.role in [:owner, :admin, :member] and &1.user_id != owner_id))

        _ ->
          []
      end

    form |> Map.put(:members, members) |> load_runtimes(scope)
  end

  defp load_runtimes(%{configure?: false} = form, _scope), do: Map.put(form, :runtimes, [])

  defp load_runtimes(form, scope) do
    runtimes =
      case Runtimes.list_bindable(scope, form.params["provider"]) do
        {:ok, runtimes} -> runtimes
        _ -> []
      end

    Map.put(form, :runtimes, runtimes)
  end

  ## Events

  @doc """
  Handles the `agent_form_*` events for a page that keeps the form in
  `socket.assigns.agent_form`: `{:noreply, socket}`, or `{:saved, view, socket}` after a
  successful submit (the page closes the panel or navigates).
  """
  def handle_event(event, params, %{assigns: %{agent_form: %{} = form}} = socket) do
    scope = socket.assigns.current_scope

    case event do
      "agent_form_change" ->
        {:noreply, put(socket, change(form, scope, params))}

      "agent_form_add_env" ->
        {:noreply, put(socket, add_row(form))}

      "agent_form_remove_env" ->
        {:noreply, put(socket, remove_row(form, row_id(params["row"])))}

      "agent_form_submit" ->
        case submit(form, scope, params) do
          {:ok, view} -> {:saved, view, socket}
          {:error, form} -> {:noreply, put(socket, form)}
          {:error, form, reason} -> {:noreply, put(socket, %{form | error: error_text(reason)})}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp put(socket, form), do: Phoenix.Component.assign(socket, :agent_form, form)

  defp row_id(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc "Text of a domain error of the agent functions."
  def error_text(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  def error_text(:not_found), do: dgettext("ui", "Agent 不存在")
  def error_text(:agent_archived), do: dgettext("ui", "Agent 已归档")
  def error_text(:not_managed), do: dgettext("ui", "外接 Agent 没有执行配置")
  def error_text(_reason), do: dgettext("ui", "操作失败，请重试")

  @doc "`phx-change`: keeps the (non-secret) input; a CLI change reloads the runtimes."
  def change(form, scope, params) do
    params = merge(form, params)
    provider_changed? = params["provider"] != form.params["provider"]
    form = %{form | params: params}

    if provider_changed? and form.configure? do
      form = load_runtimes(form, scope)
      ids = Enum.map(form.runtimes, &to_string(&1.id))

      if params["runtime_id"] in ids,
        do: form,
        else: %{form | params: %{params | "runtime_id" => "", "model" => "", "effort" => ""}}
    else
      form
    end
  end

  @doc "Adds an empty `name = value` row."
  def add_row(form) do
    id = Enum.max(form.add_rows, fn -> 0 end) + 1
    %{form | add_rows: form.add_rows ++ [id]}
  end

  @doc "Removes the `name = value` row `id`."
  def remove_row(form, id) do
    %{
      form
      | add_rows: List.delete(form.add_rows, id),
        params: update_in(form.params, ["env_add"], &Map.delete(&1 || %{}, to_string(id)))
    }
  end

  @doc """
  `phx-submit`: `{:ok, view}` (created or updated), `{:error, form}` (field errors,
  input kept) or `{:error, form, reason}` (another error, shown at the top). The
  secrets in `params` are passed to the domain and dropped.
  """
  def submit(form, scope, params) do
    stored = merge(form, params)
    form = %{form | params: stored}

    with :ok <- submittable(form),
         {:ok, attrs} <- attrs(form, params) do
      result =
        case form.mode do
          :new -> Agents.create(scope, attrs)
          :edit when attrs == %{} -> {:ok, form.base}
          :edit -> Agents.update(scope, form.name, attrs)
        end

      case result do
        {:ok, view} -> {:ok, view}
        {:error, %Ecto.Changeset{} = cs} -> {:error, field_errors(form, cs)}
        {:error, reason} -> {:error, form, reason}
      end
    else
      {:local, errors} -> {:error, %{form | errors: errors, error: nil}}
      {:blocked, form} -> {:error, form}
    end
  end

  defp submittable(%{notice: :archived} = form), do: {:blocked, form}
  defp submittable(_form), do: :ok

  defp field_errors(form, cs) do
    errors = FormErrors.messages(cs)

    secrets =
      Map.get(errors, :env, []) ++ Map.get(errors, :extra_mcp_servers, [])

    errors =
      errors
      |> Map.drop([:env, :extra_mcp_servers])
      |> then(&if(secrets == [], do: &1, else: Map.put(&1, :secrets, secrets)))

    %{form | errors: errors, error: dgettext("ui", "请修正下列错误")}
  end

  # Keeps only the non-secret params; the add rows keep their names.
  defp merge(form, params) do
    params = Map.get(params, "agent", params)

    clean =
      params
      |> Map.take(Map.keys(@defaults))
      |> Map.update("env_add", %{}, fn rows ->
        Map.new(rows || %{}, fn {id, row} -> {id, Map.take(row || %{}, ["name"])} end)
      end)

    clean =
      if form.mode == :edit, do: Map.put(clean, "name", form.name), else: clean

    form.params
    |> Map.merge(clean)
    |> Map.update!("access_member_ids", &reject_blank/1)
    |> Map.update!("capabilities", &reject_blank/1)
    |> Map.update!("env_delete", &reject_blank/1)
  end

  defp reject_blank(list), do: list |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))

  @doc """
  The attrs to submit (D5): every field for a new agent; for an edit only the fields that
  differ from `base` (only description and limits without `configure?`), plus the `env`
  patch and `extra_mcp_servers`. `{:local, errors}` for the two local checks.
  """
  def attrs(form, raw_params) do
    raw = Map.get(raw_params, "agent", raw_params)

    with {:ok, env} <- env_patch(form, raw),
         {:ok, mcp} <- mcp(raw) do
      fields = fields(form)
      values = Map.new(fields, &{&1, value(&1, form.params[&1])})

      attrs =
        form
        |> changed(fields, values)
        |> put_secret("env", env, env != %{} and form.configure?)
        |> put_secret("extra_mcp_servers", mcp, mcp != :keep and form.configure?)

      {:ok, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end)}
    end
  end

  defp changed(%{mode: :new} = form, _fields, values),
    do: Map.put(values, "name", String.trim(form.params["name"] || ""))

  defp changed(form, fields, values) do
    base = Map.new(fields, &{&1, value(&1, params_of(form.base)[&1])})
    Map.filter(values, fn {k, v} -> v != base[k] end)
  end

  defp put_secret(attrs, key, value, true), do: Map.put(attrs, key, value)
  defp put_secret(attrs, _key, _value, false), do: attrs

  defp fields(%{configure?: true}), do: @basic ++ @execution ++ @access ++ @limits
  defp fields(_form), do: @basic ++ @limits

  defp value("runtime_id", ""), do: nil
  defp value("runtime_id", id), do: integer(id)
  defp value(field, "") when field in ~w(model effort), do: nil

  defp value("custom_args", text),
    do:
      (text || "")
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(String.trim(&1) == ""))

  defp value("access_member_ids", ids),
    do: ids |> List.wrap() |> Enum.map(&integer/1) |> Enum.sort()

  defp value("capabilities", caps), do: caps |> List.wrap() |> Enum.sort()
  defp value(field, v) when field in @integers, do: integer(v)
  defp value(_field, v), do: v

  defp integer(v) when is_integer(v), do: v

  defp integer(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> n
      _ -> v
    end
  end

  defp env_patch(%{configure?: false}, _raw), do: {:ok, %{}}

  defp env_patch(form, raw) do
    deleted = Map.new(reject_blank(raw["env_delete"]), &{&1, nil})

    replaced =
      for {name, value} <- raw["env_new"] || %{},
          is_binary(value) and value != "",
          name not in Map.keys(deleted),
          into: %{},
          do: {name, value}

    added = added_rows(raw["env_add"])

    if Enum.any?(added, fn {name, value} -> String.trim(name) == "" and value != "" end) do
      {:local, Map.put(form.errors, :secrets, [dgettext("ui", "请填写变量名")])}
    else
      added =
        for {name, value} <- added,
            String.trim(name) != "",
            into: %{},
            do: {String.trim(name), value}

      {:ok, deleted |> Map.merge(replaced) |> Map.merge(added)}
    end
  end

  defp added_rows(nil), do: []

  defp added_rows(rows),
    do: Enum.map(rows, fn {_id, row} -> {Map.get(row, "name", ""), Map.get(row, "value", "")} end)

  defp mcp(%{"mcp_clear" => "true"}), do: {:ok, %{}}

  defp mcp(raw) do
    case String.trim(raw["mcp"] || "") do
      "" ->
        {:ok, :keep}

      json ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:local, %{secrets: [dgettext("ui", "额外的 MCP 服务器必须是 JSON 对象")]}}
        end
    end
  end

  @doc """
  The agent being edited changed elsewhere (`fresh` is its new view, or `nil` when it is
  gone): a notice, the input and the diff base stay.
  """
  def refreshed(%{mode: :edit} = form, fresh) do
    cond do
      fresh == nil or fresh.archived -> %{form | notice: :archived}
      config(fresh) != config(form.base) -> %{form | notice: :modified}
      true -> form
    end
  end

  def refreshed(form, _fresh), do: form

  # `updated_at` has second precision: compare the configuration itself too.
  @config_keys ~w(updated_at description provider model effort instructions custom_args access
                  access_member_ids capabilities max_concurrency timeout_minutes
                  idle_timeout_minutes env_names extra_mcp_server_names)a
  defp config(view),
    do: view |> Map.take(@config_keys) |> Map.put(:runtime_id, view.runtime && view.runtime.id)

  ## Rendering

  attr :form, :map, required: true
  attr :scope, :map, required: true
  attr :close_path, :string, required: true

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="agent-panel"
      show={@form != nil}
      title={panel_title(@form)}
      width={:wide}
      dirty={@form != nil}
      patch_on_close={@close_path}
    >
      <:error :if={@form && @form.error}>{@form.error}</:error>
      <div
        :if={@form && @form.notice}
        id="agent-form-notice"
        role="status"
        class="mb-4 flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
        {notice_text(@form)}
      </div>
      <.agent_form :if={@form} form={@form} scope={@scope} />
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="agent-form-submit"
            type="submit"
            form="agent-form"
            variant="primary"
            disabled={@form != nil and @form.notice == :archived}
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {if(@form && @form.mode == :new, do: dgettext("ui", "创建"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp panel_title(%{mode: :new}), do: dgettext("ui", "新建 Agent")
  defp panel_title(%{mode: :edit, name: name}), do: dgettext("ui", "编辑 %{name}", name: name)
  defp panel_title(_), do: ""

  defp notice_text(%{notice: :modified, name: name}),
    do: dgettext("ui", "%{name} 已被修改，提交仍以面板中的值为准", name: name)

  defp notice_text(%{notice: :archived, name: name}),
    do: dgettext("ui", "%{name} 已归档，不能再修改", name: name)

  attr :form, :map, required: true
  attr :scope, :map, required: true

  defp agent_form(assigns) do
    p = assigns.form.params
    runtime = Enum.find(assigns.form.runtimes, &(to_string(&1.id) == p["runtime_id"]))

    assigns =
      assign(assigns,
        p: p,
        e: assigns.form.errors,
        gen: assigns.form.gen,
        locked?: not assigns.form.configure?,
        runtime_options: runtime_options(assigns.form),
        models: (runtime && runtime.models) || [],
        efforts: (runtime && runtime.efforts) || []
      )

    ~H"""
    <.form
      for={%{}}
      as={:agent}
      id="agent-form"
      phx-change="agent_form_change"
      phx-submit="agent_form_submit"
      class="flex flex-col gap-6"
    >
      <fieldset id="agent-form-basic" class="flex flex-col gap-4">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "基本")}</legend>
        <.input
          :if={@form.mode == :new}
          id="agent-name"
          name="agent[name]"
          label={dgettext("ui", "名字")}
          value={@p["name"]}
          placeholder="keel/dev"
          autocomplete="off"
          errors={Map.get(@e, :name, [])}
        />
        <.input
          id="agent-description"
          name="agent[description]"
          type="textarea"
          rows="2"
          label={dgettext("ui", "描述")}
          value={@p["description"]}
          errors={Map.get(@e, :description, [])}
        />
      </fieldset>

      <p :if={@locked?} id="agent-form-locked" class="text-caption text-fg-muted">
        {dgettext("ui", "只有所属用户能修改执行配置")}
      </p>

      <fieldset id="agent-form-execution" disabled={@locked?} class="flex flex-col gap-4">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "执行")}</legend>
        <.input
          id="agent-provider"
          name="agent[provider]"
          type="select"
          label="CLI"
          value={@p["provider"]}
          options={Enum.map(providers(), &{provider_label(&1), &1})}
          errors={Map.get(@e, :provider, [])}
        />
        <.input
          id="agent-runtime"
          name="agent[runtime_id]"
          type="select"
          label={dgettext("ui", "运行时")}
          value={@p["runtime_id"]}
          options={@runtime_options}
          errors={Map.get(@e, :runtime_id, [])}
        />
        <div class="grid gap-4 sm:grid-cols-2">
          <.choice_or_text
            id="agent-model"
            name="agent[model]"
            label={dgettext("ui", "模型")}
            value={@p["model"]}
            options={@models}
            errors={Map.get(@e, :model, [])}
          />
          <.choice_or_text
            id="agent-effort"
            name="agent[effort]"
            label={dgettext("ui", "推理强度")}
            value={@p["effort"]}
            options={@efforts}
            errors={Map.get(@e, :effort, [])}
          />
        </div>
        <.live_component
          module={MarkdownEditor}
          id={"agent-instructions-#{@gen}"}
          session={@gen}
          scope={@scope}
          name="agent[instructions]"
          value={@p["instructions"]}
          label={dgettext("ui", "指令")}
          errors={Map.get(@e, :instructions, [])}
          submit={:form}
          rows={8}
        />
        <.input
          id="agent-custom-args"
          name="agent[custom_args]"
          type="textarea"
          rows="3"
          label={dgettext("ui", "追加参数（每行一项）")}
          value={@p["custom_args"]}
          class="font-mono"
          errors={Map.get(@e, :custom_args, [])}
        />
      </fieldset>

      <fieldset id="agent-form-access" disabled={@locked?} class="flex flex-col gap-3">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "访问")}</legend>
        <.input
          id="agent-access"
          name="agent[access]"
          type="select"
          label={dgettext("ui", "谁能触发")}
          value={@p["access"]}
          options={[
            {dgettext("ui", "仅所属用户"), "owner_only"},
            {dgettext("ui", "指定成员"), "members"},
            {dgettext("ui", "工作区成员"), "workspace"}
          ]}
          errors={Map.get(@e, :access, [])}
        />
        <div :if={@p["access"] == "members"} id="agent-access-members" class="flex flex-col gap-1">
          <input type="hidden" name="agent[access_member_ids][]" value="" />
          <p :if={@form.members == []} class="text-caption text-fg-muted">
            {dgettext("ui", "没有可指定的成员")}
          </p>
          <label :for={m <- @form.members} class="flex items-center gap-2 text-body text-fg">
            <input
              type="checkbox"
              name="agent[access_member_ids][]"
              value={m.user_id}
              checked={to_string(m.user_id) in @p["access_member_ids"]}
              class="size-4 accent-brand"
            />
            {m.display_name}
          </label>
          <p :for={msg <- Map.get(@e, :access_member_ids, [])} class="text-caption text-danger-fg">
            {msg}
          </p>
        </div>
        <label class="flex items-center gap-2 text-body text-fg">
          <input type="hidden" name="agent[capabilities][]" value="" />
          <input
            id="agent-capability-create-tasks"
            type="checkbox"
            name="agent[capabilities][]"
            value="create_tasks"
            checked={"create_tasks" in @p["capabilities"]}
            class="size-4 accent-brand"
          />
          {dgettext("ui", "允许创建任务")}
        </label>
      </fieldset>

      <fieldset id="agent-form-limits" class="grid gap-4 sm:grid-cols-3">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "限制")}</legend>
        <.input
          id="agent-max-concurrency"
          name="agent[max_concurrency]"
          type="number"
          min="1"
          max="16"
          label={dgettext("ui", "并发上限")}
          value={@p["max_concurrency"]}
          errors={Map.get(@e, :max_concurrency, [])}
        />
        <.input
          id="agent-timeout"
          name="agent[timeout_minutes]"
          type="number"
          min="1"
          label={dgettext("ui", "总时长上限（分钟）")}
          value={@p["timeout_minutes"]}
          errors={Map.get(@e, :timeout_minutes, [])}
        />
        <.input
          id="agent-idle-timeout"
          name="agent[idle_timeout_minutes]"
          type="number"
          min="1"
          label={dgettext("ui", "无输出上限（分钟）")}
          value={@p["idle_timeout_minutes"]}
          errors={Map.get(@e, :idle_timeout_minutes, [])}
        />
      </fieldset>

      <fieldset id="agent-form-secrets" disabled={@locked?} class="flex flex-col gap-3">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "密钥")}</legend>
        <div
          :if={Map.get(@e, :secrets, []) != []}
          id="agent-secrets-error"
          role="alert"
          class="text-caption text-danger-fg"
        >
          <p :for={msg <- @e.secrets}>{msg}</p>
        </div>
        <p class="text-label font-medium text-fg">{dgettext("ui", "环境变量")}</p>
        <input type="hidden" name="agent[env_delete][]" value="" />
        <div
          :for={name <- existing_env(@form)}
          id={"agent-env-#{name}"}
          class="grid grid-cols-[minmax(0,10rem)_1fr_auto] items-center gap-2"
        >
          <code class="truncate font-mono text-label text-fg">{name}</code>
          <div id={"agent-form-#{@gen}-env-#{name}"} phx-update="ignore">
            <input
              type="password"
              name={"agent[env_new][#{name}]"}
              value=""
              placeholder={dgettext("ui", "新值（留空不变）")}
              autocomplete="new-password"
              aria-label={dgettext("ui", "%{name} 的新值", name: name)}
              class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 text-body text-fg"
            />
          </div>
          <label class="flex items-center gap-1 text-caption text-fg-muted">
            <input
              type="checkbox"
              name="agent[env_delete][]"
              value={name}
              checked={name in @p["env_delete"]}
              class="size-4 accent-brand"
            />
            {dgettext("ui", "删除")}
          </label>
        </div>
        <div
          :for={row <- @form.add_rows}
          id={"agent-env-add-#{row}"}
          class="grid grid-cols-[minmax(0,10rem)_1fr_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"agent[env_add][#{row}][name]"}
            value={get_in(@p, ["env_add", to_string(row), "name"])}
            placeholder={dgettext("ui", "变量名")}
            autocomplete="off"
            class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 font-mono text-label text-fg"
          />
          <div id={"agent-form-#{@gen}-env-add-#{row}"} phx-update="ignore">
            <input
              type="password"
              name={"agent[env_add][#{row}][value]"}
              value=""
              placeholder={dgettext("ui", "值")}
              autocomplete="new-password"
              class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 text-body text-fg"
            />
          </div>
          <.icon_button
            icon="lucide-x"
            label={dgettext("ui", "移除")}
            size="sm"
            phx-click="agent_form_remove_env"
            phx-value-row={row}
          />
        </div>
        <div>
          <.button
            id="agent-env-add"
            size="sm"
            variant="ghost"
            icon="lucide-plus"
            phx-click="agent_form_add_env"
          >
            {dgettext("ui", "新增变量")}
          </.button>
        </div>

        <p class="text-label font-medium text-fg">{dgettext("ui", "额外的 MCP 服务器")}</p>
        <p :if={existing_mcp(@form) != []} id="agent-mcp-names" class="text-caption text-fg-muted">
          {Enum.join(existing_mcp(@form), "、")}
        </p>
        <div id={"agent-form-#{@gen}-mcp"} phx-update="ignore">
          <textarea
            name="agent[mcp]"
            rows="4"
            autocomplete="off"
            spellcheck="false"
            aria-label={dgettext("ui", "额外的 MCP 服务器（JSON）")}
            placeholder={dgettext("ui", "JSON 对象，留空不变，填写则整体替换")}
            class="block w-full rounded-field border border-border-strong bg-surface px-2 py-1.5 font-mono text-label text-fg"
          ></textarea>
        </div>
        <label :if={existing_mcp(@form) != []} class="flex items-center gap-2 text-body text-fg">
          <input type="hidden" name="agent[mcp_clear]" value="false" />
          <input type="checkbox" name="agent[mcp_clear]" value="true" class="size-4 accent-brand" />
          {dgettext("ui", "清除全部")}
        </label>
      </fieldset>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :errors, :list, default: []

  defp choice_or_text(%{options: []} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      label={@label}
      value={@value}
      placeholder={dgettext("ui", "CLI 缺省")}
      errors={@errors}
    />
    """
  end

  defp choice_or_text(assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="select"
      label={@label}
      value={@value}
      options={[{dgettext("ui", "CLI 缺省"), ""} | Enum.map(@options, &{&1, &1})]}
      errors={@errors}
    />
    """
  end

  # The bindable runtimes, plus the current binding when it is no longer bindable
  # (disabled) or when the panel cannot list them (an admin editing someone else's).
  defp runtime_options(form) do
    bindable =
      Enum.map(form.runtimes, fn r ->
        status = if r.status == "online", do: dgettext("ui", "在线"), else: dgettext("ui", "离线")
        {"#{r.daemon.name} · #{status}", to_string(r.id)}
      end)

    provider = form.params["provider"]

    current =
      case form.base do
        %{runtime: %{id: id, provider: ^provider} = r} ->
          if Enum.any?(form.runtimes, &(&1.id == id)),
            do: [],
            else: [{current_label(r), to_string(id)}]

        _ ->
          []
      end

    [{dgettext("ui", "不绑定"), ""} | bindable ++ current]
  end

  defp current_label(%{disabled: true} = r),
    do: dgettext("ui", "%{machine}（已禁用）", machine: r.daemon_name)

  defp current_label(r), do: r.daemon_name

  defp existing_env(%{base: %{env_names: names}}) when is_list(names), do: names
  defp existing_env(_form), do: []

  defp existing_mcp(%{base: %{extra_mcp_server_names: names}}) when is_list(names), do: names
  defp existing_mcp(_form), do: []
end
