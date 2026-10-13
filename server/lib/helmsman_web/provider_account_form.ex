defmodule HelmsmanWeb.ProviderAccountForm do
  @moduledoc """
  The new / edit panel of provider accounts (add-provider-accounts-ui D5; spec
  web-provider-accounts 新建与编辑供应商账号, 密钥只写). The state is a plain map kept by
  `HelmsmanWeb.UserLive.ProviderAccounts`, which forwards the `account_form_*` events.

  The API key is write-only: its input is a password field rendered empty inside a
  `phx-update="ignore"` container whose id carries the panel generation (`gen`), the
  `phx-change` params lose it before anything else (so `change/3` of the domain never
  sees it) and `submit/3` hands the raw value to `create/2` / `update/3` without
  keeping it. The state holds only the non-secret params, errors and the view the
  panel opened with.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]

  import HelmsmanWeb.ProviderAccountComponents,
    only: [aliases: 1, clis: 0, model_alias_label: 1]

  alias Helmsman.ProviderAccounts
  alias HelmsmanWeb.{FormErrors, Url}

  @config_keys ~w(name cli base_url models updated_at)a

  ## State

  @doc "A new-account panel of generation `gen`."
  def new(gen) do
    %{
      mode: :new,
      gen: gen,
      id: nil,
      base: nil,
      agents: [],
      params: %{"name" => "", "cli" => "claude", "base_url" => "", "models" => %{}},
      errors: %{},
      error: nil,
      notice: nil
    }
  end

  @doc "An edit panel of generation `gen` for the account `view` (`ProviderAccounts.get/2`)."
  def edit(gen, view) do
    %{
      mode: :edit,
      gen: gen,
      id: view.id,
      base: view,
      agents: view.agents,
      params: %{
        "name" => view.name,
        "cli" => view.cli,
        "base_url" => view.base_url,
        "models" => view.models || %{}
      },
      errors: %{},
      error: nil,
      notice: nil
    }
  end

  ## Events

  @doc """
  Handles the `account_form_*` events for a page that keeps the form in
  `socket.assigns.account_form`: `{:noreply, socket}`, or `{:saved, view, socket}` after
  a successful submit.
  """
  def handle_event(event, params, %{assigns: %{account_form: %{} = form}} = socket) do
    scope = socket.assigns.current_scope

    case event do
      "account_form_change" ->
        {:noreply, put(socket, change(form, scope, params))}

      "account_form_submit" ->
        case submit(form, scope, params) do
          {:ok, view} -> {:saved, view, socket}
          {:error, form} -> {:noreply, put(socket, form)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp put(socket, form), do: Phoenix.Component.assign(socket, :account_form, form)

  @doc """
  `phx-change`: keeps the non-secret input and shows the domain's field errors of the
  inputs already used. The key is dropped first and never validated here; a new
  account's missing key is not reported until submit.
  """
  def change(form, scope, raw_params) do
    raw = Map.get(raw_params, "account", raw_params)
    params = merge(form, raw)
    form = %{form | params: params}

    case ProviderAccounts.change(scope, form.base, attrs(form, %{})) do
      {:ok, cs} ->
        errors =
          cs
          |> FormErrors.messages()
          |> Map.delete(:api_key)
          |> Map.filter(fn {field, _} -> used?(raw, field) end)

        %{form | errors: errors}

      {:error, _reason} ->
        form
    end
  end

  # LiveView marks the inputs not yet touched with `_unused_<name>` until the form is
  # submitted.
  defp used?(raw, :models) do
    models = raw["models"] || %{}
    Enum.any?(Map.keys(models), &(not String.starts_with?(&1, "_unused_")))
  end

  defp used?(raw, field), do: not Map.has_key?(raw, "_unused_#{field}")

  # The non-secret params only. A new account's CLI change keeps the one alias both
  # CLIs share (`default`); the CLI of an existing account is read-only.
  defp merge(form, raw) do
    cli =
      if form.mode == :new and raw["cli"] in clis(), do: raw["cli"], else: form.params["cli"]

    models =
      raw
      |> Map.get("models", form.params["models"])
      |> case do
        %{} = models -> models
        _ -> %{}
      end
      |> Map.take(aliases(cli))

    models =
      if cli != form.params["cli"], do: Map.take(models, ["default"]), else: models

    %{
      "name" => string(raw, "name", form.params["name"]),
      "cli" => cli,
      "base_url" => string(raw, "base_url", form.params["base_url"]),
      "models" => models
    }
  end

  defp string(raw, key, default) do
    case raw[key] do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  @doc """
  `phx-submit`: `{:ok, view}` or `{:error, form}` (field errors kept in place, other
  errors at the top). The key in `raw_params` goes to the domain and nowhere else.
  """
  def submit(%{notice: :deleted} = form, _scope, _raw_params), do: {:error, form}

  def submit(form, scope, raw_params) do
    raw = Map.get(raw_params, "account", raw_params)
    form = %{form | params: merge(form, raw)}
    attrs = attrs(form, raw)

    result =
      case form.mode do
        :new -> ProviderAccounts.create(scope, attrs)
        :edit -> ProviderAccounts.update(scope, form.id, attrs)
      end

    case result do
      {:ok, view} ->
        {:ok, view}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, %{form | errors: FormErrors.messages(cs), error: dgettext("ui", "请修正下列错误")}}

      {:error, :not_found} when form.mode == :edit ->
        {:error, %{form | errors: %{}, error: nil, notice: :deleted}}

      {:error, reason} ->
        {:error, %{form | errors: %{}, error: error_text(reason)}}
    end
  end

  @doc """
  The attrs to submit: name, address and the non-empty model mappings of the CLI's
  aliases; the CLI only for a new account; the key only when one was typed (an empty
  key keeps the stored one). `raw` are the submitted params.
  """
  def attrs(form, raw) do
    models =
      form.params["models"]
      |> Map.take(aliases(form.params["cli"]))
      |> Enum.map(fn {k, v} -> {k, String.trim(v || "")} end)
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    attrs = %{
      "name" => form.params["name"],
      "base_url" => form.params["base_url"],
      "models" => models
    }

    attrs = if form.mode == :new, do: Map.put(attrs, "cli", form.params["cli"]), else: attrs

    case raw["api_key"] do
      key when is_binary(key) and key != "" -> Map.put(attrs, "api_key", key)
      _ -> attrs
    end
  end

  @doc "Text of a domain error of the account functions."
  def error_text(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  def error_text(:not_found), do: dgettext("ui", "供应商账号不存在")

  def error_text(:limit_reached),
    do: dgettext("ui", "最多 %{n} 个供应商账号", n: ProviderAccounts.max_accounts())

  def error_text(_reason), do: dgettext("ui", "操作失败，请重试")

  @doc """
  The user's accounts changed elsewhere (`views` is the fresh list): an edit panel whose
  account changed shows a notice, keeps its input and its diff base; one whose account
  is gone cannot be submitted. The list of agents using the account is refreshed.
  """
  def refreshed(%{mode: :edit} = form, views) do
    case Enum.find(views, &(&1.id == form.id)) do
      nil ->
        %{form | notice: :deleted}

      fresh ->
        form = %{form | agents: fresh.agents}
        if config(fresh) != config(form.base), do: %{form | notice: :modified}, else: form
    end
  end

  def refreshed(form, _views), do: form

  defp config(view), do: Map.take(view, @config_keys)

  ## Rendering

  attr :form, :map, required: true
  attr :close_path, :string, required: true

  def panel(assigns) do
    ~H"""
    <.side_panel
      id="provider-account-panel"
      show={@form != nil}
      title={panel_title(@form)}
      dirty={@form != nil}
      patch_on_close={@close_path}
    >
      <:error :if={@form && @form.error}>
        <span id="provider-account-form-error">{@form.error}</span>
      </:error>
      <div
        :if={@form && @form.notice}
        id="provider-account-form-notice"
        role="status"
        class="mb-4 flex items-start gap-2 rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-triangle-alert" class="mt-0.5 size-4 shrink-0" />
        {notice_text(@form)}
      </div>
      <.account_form :if={@form} form={@form} />
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="provider-account-form-submit"
            type="submit"
            form="provider-account-form"
            variant="primary"
            disabled={@form != nil and @form.notice == :deleted}
            phx-disable-with={dgettext("ui", "正在保存…")}
          >
            {if(@form && @form.mode == :new, do: dgettext("ui", "创建"), else: dgettext("ui", "保存"))}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp panel_title(%{mode: :new}), do: dgettext("ui", "新建供应商账号")

  defp panel_title(%{mode: :edit, base: base}),
    do: dgettext("ui", "编辑 %{name}", name: base.name)

  defp panel_title(_), do: ""

  defp notice_text(%{notice: :modified, base: base}),
    do: dgettext("ui", "%{name} 已被修改，提交仍以面板中的值为准", name: base.name)

  defp notice_text(%{notice: :deleted, base: base}),
    do: dgettext("ui", "%{name} 已被删除", name: base.name)

  attr :form, :map, required: true

  defp account_form(assigns) do
    p = assigns.form.params

    assigns =
      assign(assigns,
        p: p,
        e: assigns.form.errors,
        gen: assigns.form.gen,
        aliases: aliases(p["cli"])
      )

    ~H"""
    <.form
      for={%{}}
      as={:account}
      id="provider-account-form"
      phx-change="account_form_change"
      phx-submit="account_form_submit"
      class="flex flex-col gap-5"
    >
      <.input
        id="provider-account-name"
        name="account[name]"
        label={dgettext("ui", "名称")}
        value={@p["name"]}
        maxlength="64"
        autocomplete="off"
        placeholder="zai"
        errors={Map.get(@e, :name, [])}
      />

      <.input
        :if={@form.mode == :new}
        id="provider-account-cli"
        name="account[cli]"
        type="select"
        label="CLI"
        value={@p["cli"]}
        options={Enum.map(clis(), &{provider_label(&1), &1})}
        errors={Map.get(@e, :cli, [])}
      />
      <div :if={@form.mode == :edit} id="provider-account-cli-readonly" class="flex flex-col gap-1">
        <span class="text-label font-medium text-fg">CLI</span>
        <span class="text-body text-fg" data-cli={@p["cli"]}>{provider_label(@p["cli"])}</span>
        <span class="text-caption text-fg-muted">{dgettext("ui", "创建后不能修改")}</span>
      </div>

      <.input
        id="provider-account-base-url"
        name="account[base_url]"
        type="url"
        label={dgettext("ui", "地址")}
        value={@p["base_url"]}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        placeholder={url_placeholder(@p["cli"])}
        help={dgettext("ui", "https；本机地址（localhost、127.x、[::1]）可用 http；不能包含用户名、密码或查询串")}
        errors={Map.get(@e, :base_url, [])}
      />

      <div class="flex flex-col gap-1">
        <div class="flex items-center gap-2">
          <label for="provider-account-api-key" class="text-label font-medium text-fg">
            {dgettext("ui", "密钥")}
          </label>
          <.badge :if={@form.mode == :edit} tone={:success} data-api-key-set>
            {dgettext("ui", "已设置")}
          </.badge>
        </div>
        <div id={"provider-account-form-#{@gen}-api-key"} phx-update="ignore">
          <input
            id="provider-account-api-key"
            type="password"
            name="account[api_key]"
            value=""
            autocomplete="new-password"
            spellcheck="false"
            placeholder={
              if(@form.mode == :edit,
                do: dgettext("ui", "留空则不修改"),
                else: dgettext("ui", "必填")
              )
            }
            class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 text-body text-fg"
          />
        </div>
        <p :for={msg <- Map.get(@e, :api_key, [])} class="text-caption text-danger-fg">{msg}</p>
        <p class="text-caption text-fg-muted">{dgettext("ui", "密钥加密保存，保存后不能查看")}</p>
      </div>

      <fieldset id="provider-account-models" class="flex flex-col gap-3">
        <legend class="mb-1 text-label font-semibold text-fg">{dgettext("ui", "模型映射")}</legend>
        <p class="text-caption text-fg-muted">
          {dgettext("ui", "选这些别名时实际使用的模型；留空的别名不映射")}
        </p>
        <div
          :if={Map.get(@e, :models, []) != []}
          id="provider-account-models-error"
          role="alert"
          class="text-caption text-danger-fg"
        >
          <p :for={msg <- @e.models}>{msg}</p>
        </div>
        <div class="grid grid-cols-[minmax(0,10rem)_1fr] items-center gap-x-3 gap-y-2">
          <%= for a <- @aliases do %>
            <label for={"provider-account-model-#{a}"} class="truncate text-label text-fg">
              {alias_label(a, @p["cli"])}
            </label>
            <input
              id={"provider-account-model-#{a}"}
              type="text"
              name={"account[models][#{a}]"}
              value={@p["models"][a] || ""}
              autocomplete="off"
              spellcheck="false"
              class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 font-mono text-label text-fg"
            />
          <% end %>
        </div>
      </fieldset>

      <section :if={@form.mode == :edit} id="provider-account-agents" class="flex flex-col gap-2">
        <h3 class="text-label font-semibold text-fg">{dgettext("ui", "使用中的 Agent")}</h3>
        <p :if={@form.agents == []} class="text-caption text-fg-muted">{dgettext("ui", "未使用")}</p>
        <ul :if={@form.agents != []} class="flex flex-col gap-1">
          <li :for={a <- @form.agents}>
            <.link
              navigate={Url.agent_path(a.workspace_slug, a.name)}
              class="font-mono text-label text-fg hover:underline"
              data-account-agent
            >
              {a.workspace_slug}/{a.name}
            </.link>
          </li>
        </ul>
        <p class="text-caption text-fg-muted">
          {dgettext("ui", "修改地址、密钥或模型映射只影响之后开始的运行")}
        </p>
      </section>
    </.form>
    """
  end

  defp alias_label("default", "codex"),
    do: dgettext("ui", "%{label}（必填）", label: model_alias_label("default"))

  defp alias_label(a, _cli), do: model_alias_label(a)

  defp url_placeholder("codex"), do: "https://api.example.com/v1"
  defp url_placeholder(_cli), do: "https://api.example.com/anthropic"
end
