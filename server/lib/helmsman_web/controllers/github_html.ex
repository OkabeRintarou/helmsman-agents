defmodule HelmsmanWeb.GitHubHTML do
  @moduledoc """
  The minimal `/admin/github` page (design decision 9) until
  `Admin.GitHubLive` replaces it: the manifest form, or the configured
  App's overview. Never shows a secret.
  """

  use HelmsmanWeb, :html

  def admin(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main id="admin-github" class="mx-auto max-w-2xl space-y-6 px-6 py-10">
      <h1 class="text-heading font-semibold text-fg">{dgettext("ui", "GitHub App")}</h1>

      <%= if @overview do %>
        <dl id="github-app-overview" class="space-y-2 text-body text-fg">
          <div>
            <dt class="text-fg-muted">{dgettext("ui", "来源")}</dt>
            <dd>
              {if @overview.source == :env,
                do: dgettext("ui", "环境变量"),
                else: dgettext("ui", "数据库（manifest 创建）")}
            </dd>
          </div>
          <div>
            <dt class="text-fg-muted">{dgettext("ui", "App ID")}</dt>
            <dd>{@overview.app_id}</dd>
          </div>
          <div :if={@overview.name}>
            <dt class="text-fg-muted">{dgettext("ui", "名称")}</dt>
            <dd>{@overview.name}</dd>
          </div>
          <div :if={@overview.html_url}>
            <dt class="text-fg-muted">{dgettext("ui", "主页")}</dt>
            <dd><a href={@overview.html_url} class="underline">{@overview.html_url}</a></dd>
          </div>
        </dl>
      <% else %>
        <form id="github-manifest-settings" method="get" action={~p"/admin/github"} class="space-y-4">
          <.input
            name="name"
            id="github-app-name"
            label={dgettext("ui", "App 名称")}
            value={@form.input.name}
          />
          <.input
            name="owner_org"
            id="github-app-org"
            label={dgettext("ui", "组织（留空表示创建在个人账号下）")}
            value={@form.input.owner_org}
          />
          <.input
            type="checkbox"
            name="public"
            id="github-app-public"
            value="true"
            checked={@form.input.public?}
            label={dgettext("ui", "允许安装到其他账号")}
          />
          <p :if={@form.error} id="github-manifest-error" class="text-body text-danger">
            {dgettext("ui", "名称或组织无效。")}
          </p>
          <.button type="submit" id="github-manifest-apply">{dgettext("ui", "更新")}</.button>
        </form>

        <form
          :if={@form.action_url}
          id="github-manifest-form"
          method="post"
          action={@form.action_url}
        >
          <input type="hidden" name="manifest" id="github-manifest" value={@form.manifest} />
          <.button type="submit" variant="primary" id="github-manifest-submit">
            {dgettext("ui", "在 GitHub 上创建 App")}
          </.button>
        </form>
      <% end %>
    </main>
    """
  end
end
