defmodule HelmsmanWeb.AgentForm do
  @moduledoc """
  The new / edit panel of managed agents (add-agents-runs-ui D5; spec web-agents 新建与编辑
  Agent). The state is a plain map kept by the page (`AgentLive.Index` for `?panel=new-agent`,
  `AgentLive.Show` for `?panel=edit`); the page forwards the `agent_form_*` events here.

  * Only changed fields are submitted: an edit diffs against the view the panel opened
    with (`base`); an admin who does not own the agent diffs only the description and
    limit fields (the other groups render as `<fieldset disabled>`).
  * Secrets never reach the page: variable values and the MCP JSON are password inputs /
    textareas in `phx-update="ignore"` containers whose ids carry the panel generation
    (`gen`); their params are dropped before the state is stored.
  * Two local checks only: the MCP input must decode to a JSON object, and a new
    variable with a value needs a name. Everything else is the domain's changeset.
  * Provider accounts (add-provider-accounts-ui D8): for `claude` / `codex` the execution
    group has a 供应商账号 select listing the current user's accounts of that CLI
    (`ProviderAccounts.options/2`); with an account the model is free text. Changing the
    CLI clears an account of another CLI; an edit switching a bound agent to a CLI
    without accounts submits `provider_account_id: nil` explicitly.
  * Draft forms (add-agent-conversation-ui D7): `draft_new/2` and `draft_edit/4` edit an
    agent of a creation conversation's draft (a map with string keys). The name is
    editable in both; there are no secrets, CLI arguments or member list, 谁能触发 has
    two choices and the owner is always the current user. `draft_attrs/1` gives what to
    send to `put_agent/4`; the page submits it and `rebase/2` merges a newer draft agent
    after a `stale` refusal.
  * Edit conversations (add-edit-design-conversations D14): `draft_edit/5` with
    `lock_name: true` (the name is fixed), `baseline:` (the target's current
    configuration: each field that differs gets 「恢复为当前配置」, `agent_form_revert`)
    and `configure?: false` for an admin who is not the owner (as the edit panel).
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1, providers: 0]

  import HelmsmanWeb.ProviderAccountComponents,
    only: [accounts_path: 0, accounts_path: 1, host: 1, supported?: 1]

  alias Helmsman.{Agents, Members, ProviderAccounts, Runtimes}
  alias HelmsmanWeb.{FormErrors, MarkdownEditor}

  @basic ~w(description)
  @execution ~w(provider runtime_id provider_account_id model effort instructions custom_args)
  @access ~w(access access_member_ids capabilities wake_on_requested)
  @draft_fields ~w(description provider runtime_id provider_account_id model effort instructions
                   access capabilities max_concurrency timeout_minutes idle_timeout_minutes)
  @draft_modes [:draft_new, :draft_edit]
  @limits ~w(max_concurrency timeout_minutes idle_timeout_minutes)
  @integers ~w(max_concurrency timeout_minutes idle_timeout_minutes)
  @defaults %{
    "name" => "",
    "description" => "",
    "provider" => "claude",
    "runtime_id" => "",
    "provider_account_id" => "",
    "model" => "",
    "effort" => "",
    "instructions" => "",
    "custom_args" => "",
    "access" => "owner_only",
    "access_member_ids" => [],
    "capabilities" => [],
    "wake_on_requested" => "true",
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
      notice: nil,
      missing_account: nil,
      model_cleared: nil
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
      notice: nil,
      missing_account: nil,
      model_cleared: nil
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
      "provider_account_id" => runtime_param(view[:provider_account]),
      "custom_args" => Enum.join(List.wrap(view.custom_args), "\n"),
      "access_member_ids" => Enum.map(List.wrap(view.access_member_ids), &to_string/1),
      "capabilities" => List.wrap(view.capabilities),
      "wake_on_requested" => to_string(Map.get(view, :wake_on_requested, true) != false),
      "max_concurrency" => to_string(view.max_concurrency),
      "timeout_minutes" => to_string(view.timeout_minutes),
      "idle_timeout_minutes" => to_string(view.idle_timeout_minutes)
    })
  end

  defp runtime_param(%{id: id}), do: to_string(id)
  defp runtime_param(_runtime), do: ""

  @doc "A panel adding an agent to the draft (generation `gen`)."
  def draft_new(scope, gen) do
    %{
      mode: :draft_new,
      gen: gen,
      name: nil,
      base: nil,
      configure?: true,
      params: @defaults,
      add_rows: [],
      errors: %{},
      error: nil,
      notice: nil,
      missing_account: nil,
      model_cleared: nil
    }
    |> load_options(scope)
  end

  @doc """
  A panel editing the draft agent `entry` (string keys) of generation `gen`; `errors`
  are field errors to show at once (a refused confirmation, D8). `opts`:
  `lock_name` (the name cannot change), `baseline` (the configuration the fields
  can be reverted to), `configure?` (false: only the description and limits).
  """
  def draft_edit(scope, gen, entry, errors \\ %{}, opts \\ []) do
    %{
      mode: :draft_edit,
      gen: gen,
      name: entry["name"],
      base: entry,
      lock_name?: Keyword.get(opts, :lock_name, false),
      baseline: Keyword.get(opts, :baseline),
      configure?: Keyword.get(opts, :configure?, true),
      params: draft_params(entry),
      add_rows: [],
      errors: errors,
      error: nil,
      notice: nil,
      missing_account: nil,
      model_cleared: nil
    }
    |> load_options(scope)
  end

  @doc "Whether `form` edits a draft agent."
  def draft?(%{mode: mode}), do: mode in @draft_modes
  def draft?(_form), do: false

  defp draft_params(entry) do
    string = fn key -> to_string(entry[key] || @defaults[key]) end

    Map.merge(@defaults, %{
      "name" => entry["name"] || "",
      "description" => entry["description"] || "",
      "provider" => entry["provider"] || @defaults["provider"],
      "runtime_id" => id_param(entry["runtime_id"]),
      "provider_account_id" => id_param(entry["provider_account_id"]),
      "model" => entry["model"] || "",
      "effort" => entry["effort"] || "",
      "instructions" => entry["instructions"] || "",
      "access" => entry["access"] || "owner_only",
      "capabilities" => List.wrap(entry["capabilities"]),
      "max_concurrency" => string.("max_concurrency"),
      "timeout_minutes" => string.("timeout_minutes"),
      "idle_timeout_minutes" => string.("idle_timeout_minutes")
    })
  end

  defp id_param(id) when is_integer(id), do: to_string(id)
  defp id_param(_id), do: ""

  # Runtimes the owner may bind (their own, enabled, same CLI) and the members who may be
  # named in `access_member_ids` (member and above, not the owner).
  defp load_options(form, scope) do
    owner_id = if form.mode == :edit, do: form.base.owner.id, else: scope.user.id

    members =
      case Members.list(scope) do
        {:ok, members} ->
          Enum.filter(members, &(&1.role in [:owner, :admin, :member] and &1.user_id != owner_id))

        _ ->
          []
      end

    form |> Map.put(:members, members) |> load_runtimes(scope) |> load_accounts(scope)
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

  # The current user's accounts of the selected CLI. An admin editing someone else's
  # agent lists none: the select only shows the current binding.
  defp load_accounts(%{configure?: false} = form, _scope), do: Map.put(form, :accounts, [])

  defp load_accounts(form, scope) do
    provider = form.params["provider"]

    accounts =
      with true <- supported?(provider),
           {:ok, options} <- ProviderAccounts.options(scope, provider) do
        options
      else
        _ -> []
      end

    Map.put(form, :accounts, accounts)
  end

  @doc """
  The user's provider accounts changed (another tab): reloads the options of the
  select, keeping the selected value; a selected account that is gone stays as the
  current item with a hint.
  """
  def accounts_changed(form, scope) do
    selected = form.params["provider_account_id"]
    previous = Enum.find(form.accounts, &(to_string(&1.id) == selected))
    form = load_accounts(form, scope)

    if previous && not Enum.any?(form.accounts, &(&1.id == previous.id)),
      do: %{form | missing_account: %{id: previous.id, name: previous.name}},
      else: form
  end

  @doc """
  The workspace's runtimes changed (another tab, a machine going offline …): reloads the
  runtime and account options, keeping the selected values; a selected runtime no
  longer bindable shows as unavailable.
  """
  def runtimes_changed(%{configure?: true} = form, scope),
    do: form |> load_runtimes(scope) |> accounts_changed(scope)

  def runtimes_changed(form, _scope), do: form

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

      "agent_form_revert" ->
        {:noreply, put(socket, revert(form, scope, params["field"]))}

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
    previous_account = form.params["provider_account_id"]
    form = %{form | params: params, model_cleared: nil}

    form =
      if provider_changed? and form.configure? do
        form = form |> load_runtimes(scope) |> load_accounts(scope)
        ids = Enum.map(form.runtimes, &to_string(&1.id))

        form =
          if params["runtime_id"] in ids,
            do: form,
            else: %{form | params: %{params | "runtime_id" => "", "model" => "", "effort" => ""}}

        keep_account(form)
      else
        form
      end

    clear_model(form, previous_account)
  end

  # An account of another CLI is cleared with the CLI change.
  defp keep_account(form) do
    selected = form.params["provider_account_id"]

    if selected == "" or Enum.any?(form.accounts, &(to_string(&1.id) == selected)),
      do: form,
      else: put_param(form, "provider_account_id", "")
  end

  # Back from an account to the CLI's own login: a model the runtime does not report is
  # cleared (with a hint), since the select only offers the reported ones.
  defp clear_model(form, previous_account) do
    model = form.params["model"]
    models = runtime_models(form)

    if previous_account != "" and form.params["provider_account_id"] == "" and model != "" and
         models != [] and model not in models,
       do: %{put_param(form, "model", "") | model_cleared: model},
       else: form
  end

  defp put_param(form, key, value), do: %{form | params: Map.put(form.params, key, value)}

  defp runtime_models(form) do
    case Enum.find(form.runtimes, &(to_string(&1.id) == form.params["runtime_id"])) do
      %{models: models} when is_list(models) -> models
      _ -> []
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

    hidden_account_errors =
      if supported?(form.params["provider"]),
        do: [],
        else: Map.get(errors, :provider_account_id, [])

    error =
      case hidden_account_errors do
        [] -> dgettext("ui", "请修正下列错误")
        messages -> Enum.join([dgettext("ui", "供应商账号") <> "：" | messages], "")
      end

    %{form | errors: errors, error: error}
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

    clean = if draft?(form), do: Map.drop(clean, ~w(custom_args access_member_ids)), else: clean

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
        |> unbind(form)
        |> put_secret("env", env, env != %{} and form.configure?)
        |> put_secret("extra_mcp_servers", mcp, mcp != :keep and form.configure?)

      {:ok, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end)}
    end
  end

  defp changed(%{mode: :new} = form, _fields, values) do
    values
    |> Map.reject(fn {k, v} -> k == "provider_account_id" and v == nil end)
    |> Map.put("name", String.trim(form.params["name"] || ""))
  end

  defp changed(form, fields, values) do
    base = Map.new(fields, &{&1, value(&1, params_of(form.base)[&1])})
    Map.filter(values, fn {k, v} -> v != base[k] end)
  end

  # A bound agent moved to a CLI without accounts: the binding is dropped in the same
  # request (the domain refuses a CLI that does not match the account).
  defp unbind(attrs, %{mode: :edit, configure?: true, base: %{provider_account: %{}}} = form) do
    if supported?(form.params["provider"]),
      do: attrs,
      else: Map.put(attrs, "provider_account_id", nil)
  end

  defp unbind(attrs, _form), do: attrs

  defp put_secret(attrs, key, value, true), do: Map.put(attrs, key, value)
  defp put_secret(attrs, _key, _value, false), do: attrs

  defp fields(%{configure?: true} = form) do
    execution =
      if supported?(form.params["provider"]),
        do: @execution,
        else: List.delete(@execution, "provider_account_id")

    @basic ++ execution ++ @access ++ @limits
  end

  defp fields(_form), do: @basic ++ @limits

  defp value(field, "") when field in ~w(runtime_id provider_account_id), do: nil
  defp value(field, id) when field in ~w(runtime_id provider_account_id), do: integer(id)
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
  defp value("wake_on_requested", v), do: v in [true, "true"]
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

  ## Draft forms (add-agent-conversation-ui D7)

  @doc """
  Merges the submitted `params` of a draft form: `{form, attrs}` with the attrs for
  `put_agent/4` (`draft_attrs/1`).
  """
  def draft_submit(form, params) do
    form = %{form | params: merge(form, params)}
    {form, draft_attrs(form)}
  end

  @doc """
  The attrs of a draft form (string keys): every field for `:draft_new`; for
  `:draft_edit` the fields that differ from the draft agent it opened with, plus `name`
  and, after a rename, `previous_name`. Empty runtime, account, model and effort are
  `nil` (the domain's default); never secrets, CLI arguments or members.
  """
  def draft_attrs(%{mode: :draft_new} = form) do
    form
    |> draft_values()
    |> Map.put("name", String.trim(form.params["name"] || ""))
  end

  def draft_attrs(%{mode: :draft_edit, base: base} = form) do
    fields = draft_fields(form)
    old = draft_params(base)
    name = String.trim(form.params["name"] || "")

    attrs =
      form
      |> draft_values()
      |> Map.filter(fn {k, v} -> v != value(k, old[k]) end)
      |> Map.put("name", name)

    # A bound agent moved to a CLI without accounts drops the binding.
    attrs =
      if "provider_account_id" not in fields and base["provider_account_id"] != nil,
        do: Map.put(attrs, "provider_account_id", nil),
        else: attrs

    if name != base["name"], do: Map.put(attrs, "previous_name", base["name"]), else: attrs
  end

  defp draft_values(form),
    do: Map.new(draft_fields(form), &{&1, value(&1, form.params[&1])})

  defp draft_fields(form) do
    if supported?(form.params["provider"]),
      do: @draft_fields,
      else: List.delete(@draft_fields, "provider_account_id")
  end

  @doc """
  The fields of a draft form that differ from its `baseline` (an edit
  conversation's target as it is now), among those the form may change.
  """
  def reverts(%{baseline: %{} = baseline} = form) do
    old = draft_params(baseline)
    editable = if form.configure?, do: @draft_fields, else: @basic ++ @limits

    Enum.filter(editable, fn field ->
      Map.has_key?(baseline, field) and
        value(field, form.params[field]) != value(field, old[field])
    end)
  end

  def reverts(_form), do: []

  defp revert(%{baseline: %{} = baseline} = form, scope, field) when is_binary(field) do
    if field in reverts(form) do
      form = %{form | params: Map.put(form.params, field, draft_params(baseline)[field])}

      if field == "provider",
        do: form |> load_runtimes(scope) |> load_accounts(scope),
        else: form
    else
      form
    end
  end

  defp revert(form, _scope, _field), do: form

  @doc "Field errors of a refused draft save (a changeset of `put_agent/4`)."
  def draft_errors(form, %Ecto.Changeset{} = cs), do: field_errors(form, cs)

  @doc """
  The draft changed under an edit form (a `stale` save, D7): the fields the user did
  not change take the values of `fresh` (the draft agent now, or nil when it was
  removed — the form then adds it again), the others keep the panel's values; `fresh`
  becomes the base, so the next save sends only the user's changes.
  """
  def rebase(%{mode: :draft_edit} = form, _scope, nil),
    do: %{form | mode: :draft_new, base: nil, notice: :draft_removed, error: nil}

  def rebase(%{mode: :draft_edit} = form, scope, fresh) do
    old = draft_params(form.base)
    new = draft_params(fresh)

    params =
      Map.new(form.params, fn {k, v} ->
        if k in ["name" | @draft_fields] and same_value?(k, v, old[k]),
          do: {k, new[k]},
          else: {k, v}
      end)

    form = %{form | base: fresh, name: fresh["name"], params: params, notice: :draft_stale}

    if params["provider"] != old["provider"],
      do: form |> load_runtimes(scope) |> load_accounts(scope),
      else: form
  end

  def rebase(form, _scope, _fresh), do: %{form | notice: :draft_stale, error: nil}

  defp same_value?("name", a, b), do: String.trim(a || "") == String.trim(b || "")
  defp same_value?(k, a, b), do: value(k, a) == value(k, b)

  # `updated_at` has second precision: compare the configuration itself too.
  @config_keys ~w(updated_at description provider model effort instructions custom_args access
                  access_member_ids capabilities max_concurrency timeout_minutes
                  idle_timeout_minutes env_names extra_mcp_server_names)a
  defp config(view),
    do:
      view
      |> Map.take(@config_keys)
      |> Map.put(:runtime_id, view.runtime && view.runtime.id)
      |> Map.put(:provider_account_id, view[:provider_account] && view.provider_account.id)

  ## Rendering

  attr :form, :map, required: true
  attr :scope, :map, required: true
  attr :close_path, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  attr :locked, :string, default: nil, doc: "why saving a draft form is unavailable now"

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="agent-panel"
      show={@form != nil}
      title={panel_title(@form)}
      width={:wide}
      dirty={@form != nil}
      patch_on_close={@close_path}
      on_cancel={@on_cancel}
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
      <div
        :if={@locked}
        id="agent-form-locked-notice"
        role="status"
        class="mb-4 flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-hourglass" class="mt-0.5 size-4 shrink-0" />
        {@locked}
      </div>
      <div
        :if={@form && reverts(@form) != []}
        id="agent-form-reverts"
        class="mb-4 flex flex-col gap-1 rounded-field border border-border bg-surface px-3 py-2"
      >
        <p class="text-caption text-fg-muted">{dgettext("ui", "与当前配置不同的字段")}</p>
        <div :for={field <- reverts(@form)} class="flex items-center justify-between gap-2">
          <span class="text-body text-fg">
            {HelmsmanWeb.AgentDesignComponents.field_label(field)}
          </span>
          <.button
            id={"agent-form-revert-#{field}"}
            size="xs"
            variant="ghost"
            phx-click="agent_form_revert"
            phx-value-field={field}
          >
            {dgettext("ui", "恢复为当前配置")}
          </.button>
        </div>
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
            disabled={(@form != nil and @form.notice == :archived) or @locked != nil}
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {submit_label(@form)}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp submit_label(%{mode: :new}), do: dgettext("ui", "创建")
  defp submit_label(%{mode: mode}) when mode in @draft_modes, do: dgettext("ui", "保存到草稿")
  defp submit_label(_form), do: dgettext("ui", "保存")

  defp panel_title(%{mode: :new}), do: dgettext("ui", "新建 Agent")
  defp panel_title(%{mode: :draft_new}), do: dgettext("ui", "添加 Agent")

  defp panel_title(%{mode: :draft_edit, base: base}),
    do: dgettext("ui", "编辑 %{name}", name: base["name"])

  defp panel_title(%{mode: :edit, name: name}), do: dgettext("ui", "编辑 %{name}", name: name)
  defp panel_title(_), do: ""

  defp notice_text(%{notice: :modified, name: name}),
    do: dgettext("ui", "%{name} 已被修改，提交仍以面板中的值为准", name: name)

  defp notice_text(%{notice: :archived, name: name}),
    do: dgettext("ui", "%{name} 已归档，不能再修改", name: name)

  defp notice_text(%{notice: :draft_stale}),
    do: dgettext("ui", "草稿刚被更新（可能是 AI 或另一个标签页），已载入最新内容，你改过的字段保留")

  defp notice_text(%{notice: :draft_removed, name: name}),
    do: dgettext("ui", "%{name} 已从草稿移除，保存会重新加入", name: name)

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
        account?: supported?(p["provider"]),
        account: selected_account(assigns.form),
        models:
          if(p["provider_account_id"] in ["", nil],
            do: (runtime && runtime.models) || [],
            else: []
          ),
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
      <p
        :if={@form.mode == :new}
        id="agent-form-design"
        class="flex items-center gap-2 rounded-field border border-info tint-info px-3 py-2 text-body text-info-fg"
      >
        <.icon name="lucide-messages-square" class="size-4 shrink-0" />
        {dgettext("ui", "不确定怎么配？")}
        <.link
          id="agent-form-design-link"
          navigate={HelmsmanWeb.Url.agent_design_path(@scope.workspace.slug)}
          class="font-medium underline"
        >
          {dgettext("ui", "和 AI 对话创建")}
        </.link>
      </p>

      <fieldset id="agent-form-basic" class="flex flex-col gap-4">
        <legend class="mb-2 text-label font-semibold text-fg">{dgettext("ui", "基本")}</legend>
        <.input
          :if={@form.mode != :edit}
          id="agent-name"
          name="agent[name]"
          label={dgettext("ui", "名字")}
          value={@p["name"]}
          disabled={@form[:lock_name?] == true}
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
        <.account_select :if={@account?} form={@form} errors={Map.get(@e, :provider_account_id, [])} />
        <div class="grid gap-4 sm:grid-cols-2">
          <div class="flex flex-col gap-1">
            <.choice_or_text
              id="agent-model"
              name="agent[model]"
              label={dgettext("ui", "模型")}
              value={@p["model"]}
              options={@models}
              placeholder={@p["provider_account_id"] not in ["", nil] && dgettext("ui", "账号的缺省模型")}
              errors={Map.get(@e, :model, [])}
            />
            <.model_label
              :if={@p["model"] not in ["", nil]}
              id="agent-model-preview"
              model={@p["model"]}
              account_icon={HelmsmanWeb.ProviderAccountComponents.account_icon(@account)}
              class="text-caption text-fg-muted"
            />
            <p
              :if={@p["provider_account_id"] not in ["", nil]}
              id="agent-model-account-hint"
              class="text-caption text-fg-muted"
            >
              {model_hint(@account)}
            </p>
            <p :if={@form.model_cleared} id="agent-model-cleared" class="text-caption text-warning-fg">
              {dgettext("ui", "已清空：%{model} 不在运行时上报的模型里", model: @form.model_cleared)}
            </p>
          </div>
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
          :if={not draft?(@form)}
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
          options={access_options(@form)}
          errors={Map.get(@e, :access, [])}
        />
        <div
          :if={@p["access"] == "members" and not draft?(@form)}
          id="agent-access-members"
          class="flex flex-col gap-1"
        >
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
        <div :if={not draft?(@form)} class="flex flex-col gap-0.5">
          <label class="flex items-center gap-2 text-body text-fg">
            <input type="hidden" name="agent[wake_on_requested]" value="false" />
            <input
              id="agent-wake-on-requested"
              type="checkbox"
              name="agent[wake_on_requested]"
              value="true"
              checked={@p["wake_on_requested"] == "true"}
              aria-describedby="agent-wake-on-requested-help"
              class="size-4 accent-brand"
            />
            {dgettext("ui", "它提出的任务有进展时唤醒它")}
          </label>
          <p id="agent-wake-on-requested-help" class="pl-6 text-caption text-fg-muted">
            {dgettext("ui", "任务被完成或拒绝、执行方提问时，给它排一次运行（回调提出方）")}
          </p>
        </div>
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

      <p :if={draft?(@form)} id="agent-form-draft-note" class="text-caption text-fg-muted">
        {dgettext(
          "ui",
          "环境变量、额外 MCP 服务器、追加参数与指定成员请在创建后到 Agent 的编辑面板设置"
        )}
      </p>

      <fieldset
        :if={not draft?(@form)}
        id="agent-form-secrets"
        disabled={@locked?}
        class="flex flex-col gap-3"
      >
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
        <p
          :if={@account?}
          id="agent-env-provider-hint"
          class="flex items-start gap-1.5 text-caption text-fg-muted"
        >
          <.icon name="lucide-info" class="mt-0.5 size-3.5 shrink-0" />
          {env_hint(@p["provider"])}
        </p>
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

  defp access_options(form) do
    owner = {dgettext("ui", "仅所属用户"), "owner_only"}
    workspace = {dgettext("ui", "工作区成员"), "workspace"}

    if draft?(form),
      do: [owner, workspace],
      else: [owner, {dgettext("ui", "指定成员"), "members"}, workspace]
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :placeholder, :any, default: nil
  attr :errors, :list, default: []

  defp choice_or_text(%{options: []} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      label={@label}
      value={@value}
      placeholder={@placeholder || dgettext("ui", "CLI 缺省")}
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

    selected = form.params["runtime_id"]

    current =
      case form.base do
        _ when form.mode in @draft_modes ->
          if selected in ["", nil] or Enum.any?(bindable, &(elem(&1, 1) == selected)),
            do: [],
            else: [{dgettext("ui", "运行时 #%{id}（不可用）", id: selected), selected}]

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

  attr :form, :map, required: true
  attr :errors, :list, default: []

  defp account_select(assigns) do
    form = assigns.form
    provider = form.params["provider"]

    assigns =
      assign(assigns,
        options: account_options(form),
        provider: provider,
        none?: form.accounts == [],
        gone?:
          form.missing_account != nil and
            to_string(form.missing_account.id) == form.params["provider_account_id"]
      )

    ~H"""
    <div id="agent-provider-account-field" class="flex flex-col gap-1">
      <.input
        id="agent-provider-account"
        name="agent[provider_account_id]"
        type="select"
        label={dgettext("ui", "供应商账号")}
        value={@form.params["provider_account_id"]}
        options={@options}
        errors={@errors}
      />
      <p :if={@gone?} id="agent-provider-account-gone" class="text-caption text-warning-fg">
        {dgettext("ui", "该账号已不存在")}
      </p>
      <p :if={@form.configure?} id="agent-provider-account-help" class="text-caption text-fg-muted">
        <span :if={@none?}>
          {dgettext("ui", "还没有 %{cli} 的供应商账号", cli: provider_label(@provider))}
          <.link
            id="agent-provider-account-add"
            href={accounts_path(panel: "new")}
            target="_blank"
            rel="noopener"
            class="ml-1 font-medium text-brand-fg hover:underline"
          >
            {dgettext("ui", "添加供应商账号")}
          </.link>
        </span>
        <span :if={!@none?}>
          {dgettext("ui", "为这个 Agent 使用另一家供应商的地址、密钥与模型")}
          <.link
            id="agent-provider-account-manage"
            href={accounts_path()}
            target="_blank"
            rel="noopener"
            class="ml-1 font-medium text-brand-fg hover:underline"
          >
            {dgettext("ui", "管理供应商账号")}
          </.link>
        </span>
      </p>
    </div>
    """
  end

  # "CLI 默认登录", the user's accounts of the CLI, and the selected account when it is
  # not among them: the current binding (deleted, or listed for an admin who may not
  # change it) or an account deleted while the panel is open.
  defp account_options(form) do
    listed =
      form.accounts
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(&{"#{&1.name} · #{host(&1.base_url)}", to_string(&1.id)})

    selected = form.params["provider_account_id"]

    extra =
      cond do
        selected in ["", nil] or Enum.any?(listed, &(elem(&1, 1) == selected)) ->
          []

        form.mode in @draft_modes ->
          [{dgettext("ui", "账号 #%{id}（不可用）", id: selected), selected}]

        match?(%{provider_account: %{}}, form.base) and
            to_string(form.base.provider_account.id) == selected ->
          [{current_account_label(form), selected}]

        form.missing_account && to_string(form.missing_account.id) == selected ->
          [{dgettext("ui", "%{name}（当前）", name: form.missing_account.name), selected}]

        true ->
          []
      end

    [{dgettext("ui", "CLI 默认登录"), ""} | listed ++ extra]
  end

  defp current_account_label(%{configure?: false, base: %{provider_account: a}}),
    do: "#{a.name} · #{a.host}"

  defp current_account_label(%{base: %{provider_account: a}}),
    do: dgettext("ui", "%{name}（当前）", name: a.name)

  defp selected_account(form) do
    selected = form.params["provider_account_id"]
    Enum.find(form.accounts, &(to_string(&1.id) == selected))
  end

  defp model_hint(%{models: models}) when is_map(models) do
    others =
      models
      |> Map.delete("default")
      |> Enum.sort()
      |> Enum.map_join("、", fn {k, v} -> "#{k} → #{v}" end)

    case {models["default"], others} do
      {nil, ""} -> dgettext("ui", "留空使用 CLI 的缺省")
      {nil, others} -> others
      {default, ""} -> dgettext("ui", "留空使用 %{model}", model: default)
      {default, others} -> dgettext("ui", "留空使用 %{model}", model: default) <> "；" <> others
    end
  end

  defp model_hint(_account), do: dgettext("ui", "留空使用账号的缺省模型")

  defp env_hint("codex"),
    do:
      dgettext(
        "ui",
        "要切换模型供应商请使用供应商账号：CLI 的用户配置会覆盖这里的 %{vars} 变量。",
        vars: "OPENAI_*"
      )

  defp env_hint(_provider),
    do:
      dgettext(
        "ui",
        "要切换模型供应商请使用供应商账号：CLI 的用户配置会覆盖这里的 %{vars} 变量。",
        vars: "ANTHROPIC_*"
      )

  defp existing_env(%{base: %{env_names: names}}) when is_list(names), do: names
  defp existing_env(_form), do: []

  defp existing_mcp(%{base: %{extra_mcp_server_names: names}}) when is_list(names), do: names
  defp existing_mcp(_form), do: []
end
