defmodule HelmsmanWeb.Admin.GitHubLive do
  @moduledoc """
  `/admin/github` (add-github-ui D14): the instance's GitHub App. Instance
  administrators only; other users get the 403 page.

  Not configured: the App manifest form. The manifest flow's `state` is
  signed when the form is submitted (not when the page opens), and the
  form is then posted to GitHub with `phx-trigger-action`, so a page left
  open for a long time still yields a valid state.

  Configured: the App's public overview. No secret is read or shown.
  """

  use HelmsmanWeb, :live_view

  alias Helmsman.GitHub
  alias HelmsmanWeb.GitHubState

  @default_name "Helmsman"

  @impl true
  def mount(_params, _session, socket) do
    case GitHub.app_overview(socket.assigns.current_scope) do
      {:ok, overview} ->
        {:ok,
         socket
         |> assign(page_title: dgettext("ui", "GitHub App"))
         |> assign_overview(overview)}

      {:error, :forbidden} ->
        raise HelmsmanWeb.ForbiddenError
    end
  end

  defp assign_overview(socket, %{configured?: true} = overview),
    do: assign(socket, overview: overview, form: nil)

  defp assign_overview(socket, %{configured?: false}) do
    assign(socket,
      overview: nil,
      form: %{
        input: %{name: @default_name, owner_org: "", public?: false},
        error: nil,
        action_url: nil,
        manifest: nil,
        trigger_action: false
      }
    )
  end

  defp reload(socket) do
    case GitHub.app_overview(socket.assigns.current_scope) do
      {:ok, overview} -> assign_overview(socket, overview)
      {:error, :forbidden} -> forbidden(socket)
    end
  end

  @impl true
  def handle_event("validate", %{"app" => params}, %{assigns: %{form: %{}}} = socket) do
    input = form_input(params)

    case manifest(socket, input) do
      {:ok, _manifest} -> {:noreply, put_form(socket, input, nil)}
      {:error, :invalid_params} -> {:noreply, put_form(socket, input, :invalid_params)}
      {:error, reason} -> {:noreply, unavailable(socket, reason)}
    end
  end

  def handle_event("create", %{"app" => params}, %{assigns: %{form: %{}}} = socket) do
    input = form_input(params)

    case manifest(socket, input) do
      {:ok, %{action_url: action_url, manifest_json: manifest}} ->
        state = GitHubState.sign_manifest(socket.assigns.current_scope.user.id)

        form = %{
          input: input,
          error: nil,
          action_url: action_url <> "?" <> URI.encode_query(%{state: state}),
          manifest: manifest,
          trigger_action: true
        }

        {:noreply, assign(socket, form: form)}

      {:error, :invalid_params} ->
        {:noreply, put_form(socket, input, :invalid_params)}

      {:error, reason} ->
        {:noreply, unavailable(socket, reason)}
    end
  end

  # The App got configured meanwhile (form events of a stale page).
  def handle_event(event, _params, socket) when event in ["validate", "create"],
    do: {:noreply, socket}

  defp form_input(params) do
    %{
      name: params |> Map.get("name", "") |> to_string(),
      owner_org: params |> Map.get("owner_org", "") |> to_string(),
      public?: Map.get(params, "public") == "true"
    }
  end

  defp manifest(socket, input) do
    GitHub.manifest(socket.assigns.current_scope, %{
      name: String.trim(input.name),
      owner_org: input.owner_org,
      public?: input.public?,
      base_url: url(~p"/")
    })
  end

  defp put_form(socket, input, error) do
    assign(socket,
      form: %{input: input, error: error, action_url: nil, manifest: nil, trigger_action: false}
    )
  end

  defp unavailable(socket, :already_configured) do
    socket
    |> put_flash(:info, dgettext("ui", "GitHub App 已经配置过了。"))
    |> reload()
  end

  defp unavailable(socket, _reason), do: forbidden(socket)

  defp forbidden(socket) do
    socket
    |> put_flash(:error, dgettext("ui", "只有实例管理员可以管理 GitHub App"))
    |> push_navigate(to: ~p"/")
  end

  defp app_title(overview), do: overview.name || overview.slug || dgettext("ui", "GitHub App")

  defp source_label(:env), do: dgettext("ui", "环境变量")
  defp source_label(_source), do: dgettext("ui", "GitHub 上创建（manifest）")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.instance_admin flash={@flash} current_scope={@current_scope} active={:github}>
      <div class="min-w-0">
        <h2 class="text-title font-semibold text-fg">{dgettext("ui", "GitHub App")}</h2>
        <p class="mt-1 text-body text-fg-muted">
          {dgettext("ui", "Agent 的提交以 PR 交付到 GitHub，独立验收后自动合并；本实例的所有工作区共用这个 App。")}
        </p>
      </div>

      <section
        :if={@overview}
        id="github-app-overview"
        class="mt-6 max-w-[640px] rounded-box border border-border p-4"
      >
        <div class="mb-3 flex items-center gap-2">
          <.icon name="lucide-git-branch" class="size-4 text-fg-muted" />
          <span class="text-body font-medium text-fg">{app_title(@overview)}</span>
          <.badge tone={:success}>{dgettext("ui", "已配置")}</.badge>
        </div>
        <.property_list>
          <.property_row
            id="github-app-source"
            label={dgettext("ui", "来源")}
            value={source_label(@overview.source)}
          />
          <.property_row id="github-app-id" label={dgettext("ui", "App ID")}>
            <span class="font-mono text-fg">{@overview.app_id}</span>
          </.property_row>
          <.property_row label={dgettext("ui", "名称")} value={@overview.name} />
          <.property_row label={dgettext("ui", "slug")}>
            <span :if={@overview.slug} class="font-mono text-fg">{@overview.slug}</span>
            <span :if={!@overview.slug} class="text-fg-subtle">—</span>
          </.property_row>
          <.property_row label={dgettext("ui", "所有者")} value={@overview.owner_login} />
          <.property_row label={dgettext("ui", "主页")}>
            <a
              :if={@overview.html_url}
              id="github-app-homepage"
              href={@overview.html_url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex min-w-0 items-center gap-1 truncate text-fg underline-offset-2 hover:underline"
            >
              <span class="truncate">{@overview.html_url}</span>
              <.icon name="lucide-external-link" class="size-3.5 shrink-0 text-fg-muted" />
            </a>
            <span :if={!@overview.html_url} class="text-fg-subtle">—</span>
          </.property_row>
        </.property_list>
        <p
          :if={@overview.source == :env}
          id="github-app-env-note"
          class="mt-3 flex items-start gap-1.5 text-caption text-fg-muted"
        >
          <.icon name="lucide-info" class="mt-0.5 size-3.5 shrink-0" />
          {dgettext("ui", "由环境变量配置；修改请更新环境变量并重启服务")}
        </p>
      </section>

      <section :if={@form} id="github-app-create" class="mt-6 max-w-[480px]">
        <p class="text-body text-fg-muted">
          {dgettext(
            "ui",
            "为本实例创建一个 GitHub App：Agent 的提交将以 PR 交付，验收后自动合并。创建后，各工作区的管理员在工作区设置里连接 GitHub。"
          )}
        </p>
        <form
          id="github-manifest-form"
          method="post"
          action={@form.action_url}
          phx-change="validate"
          phx-submit="create"
          phx-trigger-action={@form.trigger_action}
          class="mt-4 flex flex-col gap-4"
        >
          <.input
            name="app[name]"
            id="github-app-name"
            label={dgettext("ui", "App 名称")}
            value={@form.input.name}
            maxlength="34"
            phx-debounce="300"
          />
          <.input
            name="app[owner_org]"
            id="github-app-org"
            label={dgettext("ui", "组织")}
            help={dgettext("ui", "留空表示创建在你的个人账号下")}
            value={@form.input.owner_org}
            phx-debounce="300"
          />
          <.input
            type="checkbox"
            name="app[public]"
            id="github-app-public"
            checked={@form.input.public?}
            label={dgettext("ui", "允许安装到其他账号")}
          />
          <input
            :if={@form.manifest}
            type="hidden"
            name="manifest"
            id="github-manifest"
            value={@form.manifest}
          />
          <p
            :if={@form.error}
            id="github-manifest-error"
            class="flex items-center gap-1 text-caption text-danger-fg"
          >
            <.icon name="lucide-circle-alert" class="size-3.5" />
            {dgettext("ui", "名称或组织无效")}
          </p>
          <div>
            <.button
              type="submit"
              variant="primary"
              id="github-manifest-submit"
              disabled={@form.error != nil}
              phx-disable-with={dgettext("ui", "正在前往 GitHub…")}
            >
              <.icon name="lucide-external-link" class="size-4" />
              {dgettext("ui", "在 GitHub 上创建 App")}
            </.button>
          </div>
        </form>
      </section>
    </Layouts.instance_admin>
    """
  end
end
