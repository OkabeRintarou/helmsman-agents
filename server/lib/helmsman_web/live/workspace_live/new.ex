defmodule HelmsmanWeb.WorkspaceLive.New do
  @moduledoc """
  New workspace page `/workspaces/new` (spec web-workspace-entry 新建工作区页, design D6).

  Until the user edits the slug it follows the name (`derive_slug/1`). Format and
  length errors show while typing; a taken slug only on submit (the unique constraint).
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanWeb.FormErrors

  @slug_max 39

  @doc """
  Derives a slug from a workspace name: lower case ASCII letters and digits, every other
  run of characters becomes one `-`, no leading or trailing `-`, at most 39 characters.
  Results shorter than 2 characters are empty.

      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug("Acme Inc.")
      "acme-inc"
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug("海港")
      ""
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug("a")
      ""
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug("  --Hello,  World!!--  ")
      "hello-world"
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug("海港 Ops 2")
      "ops-2"
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug(String.duplicate("a", 38) <> " bc")
      String.duplicate("a", 38)
      iex> HelmsmanWeb.WorkspaceLive.New.derive_slug(String.duplicate("a", 41))
      String.duplicate("a", 39)
  """
  @spec derive_slug(String.t()) :: String.t()
  def derive_slug(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, @slug_max)
      |> String.trim_trailing("-")

    if String.length(slug) < 2, do: "", else: slug
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "新建工作区"),
       has_workspaces?: Workspaces.list_for_user(user) != [],
       slug_touched?: false,
       params: %{"name" => "", "slug" => ""},
       used: MapSet.new(),
       errors: %{}
     )}
  end

  @impl true
  def handle_event("validate", %{"workspace" => params} = event, socket) do
    params = Map.take(params, ~w(name slug))
    target = event["_target"]
    slug_touched? = socket.assigns.slug_touched? or target == ["workspace", "slug"]

    params =
      if target == ["workspace", "name"] and not slug_touched?,
        do: Map.put(params, "slug", derive_slug(params["name"] || "")),
        else: params

    used =
      case target do
        ["workspace", field] when field in ~w(name slug) -> MapSet.put(socket.assigns.used, field)
        _ -> socket.assigns.used
      end

    {:noreply,
     assign(socket,
       params: params,
       slug_touched?: slug_touched?,
       used: used,
       errors: validate(params, used)
     )}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    params = Map.take(params, ~w(name slug))
    user = socket.assigns.current_scope.user

    case Workspaces.create(user, params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "工作区已创建"))
         |> redirect(to: "/w/#{workspace.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           params: params,
           used: MapSet.new(~w(name slug)),
           errors: messages(changeset, params)
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("ui", "操作失败，请稍后重试"))}
    end
  end

  # Errors of a field show once the user has typed into it (all of them after a submit).
  # Only format and length: whether the slug is taken is checked on submit.
  defp validate(params, used) do
    %Workspace{}
    |> Workspace.changeset(params)
    |> messages(params)
    |> Map.filter(fn {field, _} -> MapSet.member?(used, to_string(field)) end)
  end

  # A blank slug fails only the format check; ask for it instead.
  defp messages(changeset, params) do
    errors = FormErrors.messages(changeset)

    if String.trim(params["slug"] || "") == "",
      do: Map.put(errors, :slug, [dgettext("ui", "不能为空")]),
      else: errors
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={dgettext("ui", "新建工作区")}>
      <p :if={!@has_workspaces?} id="new-workspace-intro" class="mb-4 text-body text-fg-muted">
        {dgettext("ui", "创建你的第一个工作区；收到邀请的话，直接打开邀请链接即可加入")}
      </p>
      <.form
        for={%{}}
        as={:workspace}
        id="new-workspace-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-4"
      >
        <.input
          id="workspace-name"
          name="workspace[name]"
          label={dgettext("ui", "名称")}
          value={@params["name"]}
          errors={Map.get(@errors, :name, [])}
          maxlength="200"
          autocomplete="off"
          phx-mounted={JS.focus()}
        />
        <div class="flex flex-col gap-1">
          <label for="workspace-slug" class="text-label font-medium text-fg">
            {dgettext("ui", "地址")}
          </label>
          <div class="flex items-center gap-1">
            <span class="shrink-0 text-body text-fg-muted">{url_prefix()}</span>
            <div class="min-w-0 flex-1">
              <.input
                id="workspace-slug"
                name="workspace[slug]"
                value={@params["slug"]}
                errors={Map.get(@errors, :slug, [])}
                maxlength="39"
                autocomplete="off"
                spellcheck="false"
                class="font-mono"
              />
            </div>
          </div>
          <p class="text-caption text-fg-muted">
            {dgettext("ui", "2–39 位小写字母、数字或 -，以字母或数字开头")}
          </p>
        </div>
        <div class="flex items-center justify-end gap-2">
          <.button :if={@has_workspaces?} id="new-workspace-cancel" href={~p"/"}>
            {dgettext("ui", "取消")}
          </.button>
          <.button
            type="submit"
            variant="primary"
            phx-disable-with={dgettext("ui", "正在创建…")}
          >
            {dgettext("ui", "创建工作区")}
          </.button>
        </div>
      </.form>
      <div class="mt-6 flex items-center justify-between border-t border-border pt-4 text-label">
        <.link navigate={~p"/users/settings"} class="text-fg-muted hover:text-fg">
          {dgettext("ui", "账号设置")}
        </.link>
        <.link href={~p"/users/log-out"} method="delete" class="text-fg-muted hover:text-fg">
          {dgettext("ui", "退出登录")}
        </.link>
      </div>
    </Layouts.auth>
    """
  end

  defp url_prefix do
    %URI{host: host, port: port} = URI.parse(HelmsmanWeb.Endpoint.url())
    host = if port in [80, 443, nil], do: host, else: "#{host}:#{port}"
    "#{host}/w/"
  end
end
