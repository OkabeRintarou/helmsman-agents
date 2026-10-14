defmodule HelmsmanWeb.Router do
  use HelmsmanWeb, :router

  import HelmsmanWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HelmsmanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug HelmsmanWeb.Plugs.SecurityHeaders
    plug :fetch_current_scope_for_user
  end

  # LiveDashboard's layout has an inline script: allowed by a nonce.
  pipeline :dashboard_csp do
    plug HelmsmanWeb.Plugs.SecurityHeaders, nonce: true
  end

  # add-workspace-settings-ui D2 / D4
  pipeline :workspace_page do
    plug :remember_workspace
  end

  pipeline :invitation_page do
    plug :store_invitation_return_to
  end

  # REST (`add-rest-api` decision 1): JSON in and out, an API token, the
  # token's workspace in the path. Reads accept api:read or api:write.
  # 406 for an Accept header JSON does not satisfy, with the REST error body.
  pipeline :api do
    plug HelmsmanWeb.API.Accepts, ["json"]
    plug HelmsmanWeb.API.RequireJSONBody
  end

  pipeline :api_markdown do
    plug HelmsmanWeb.API.Accepts, ["json", "md"]
  end

  pipeline :api_read do
    plug HelmsmanWeb.Plugs.BearerAuth, scope: ["api:read", "api:write"], via: :api
    plug HelmsmanWeb.API.WorkspaceSlug
  end

  pipeline :api_write do
    plug HelmsmanWeb.Plugs.BearerAuth, scope: ["api:write"], via: :api
    plug HelmsmanWeb.API.WorkspaceSlug
  end

  # `add-actor-avatars` decisions 5 and 13: the one REST read that also
  # accepts the `mcp` scope (the MCP views' avatar addresses); any Accept
  # header (an image is not JSON).
  pipeline :api_avatar do
    plug HelmsmanWeb.Plugs.BearerAuth, scope: ["mcp", "api:read", "api:write"], via: :api
    plug HelmsmanWeb.API.WorkspaceSlug
  end

  # `add-actor-avatars` decision 5: the browser's avatar images. The
  # session's user only: no CSRF or flash (GET only), any Accept header,
  # and the page CSP is replaced by the image's own.
  pipeline :avatar_image do
    plug :fetch_session
    plug :fetch_current_scope_for_user
  end

  pipeline :api_public do
    plug HelmsmanWeb.API.PublicRateLimit
    plug OpenApiSpex.Plug.PutApiSpec, module: HelmsmanWeb.API.ApiSpec
  end

  # Errors on unknown /api paths are JSON whatever the Accept header.
  pipeline :api_fallback do
    plug :put_format, "json"
  end

  pipeline :daemon_api do
    plug :accepts, ["json"]
  end

  scope "/daemon", HelmsmanWeb do
    pipe_through :daemon_api
    post "/device/code", DaemonDeviceController, :code
    post "/device/token", DaemonDeviceController, :token
    post "/logout", DaemonDeviceController, :logout
  end

  scope "/", HelmsmanWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # MCP over Streamable HTTP (designs/08 §1): token auth, no session or
  # CSRF, and no `:accepts` (the SSE GET asks for text/event-stream).
  pipeline :mcp do
    plug HelmsmanWeb.Plugs.BearerAuth, scope: "mcp", via: :mcp
    plug HelmsmanWeb.Plugs.MCPSessionGuard
    plug HelmsmanWeb.Plugs.MCPMethod
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: HelmsmanMCP.Server
  end

  scope "/api/v1", HelmsmanWeb.API do
    pipe_through [:api_markdown, :api_public]

    get "/workflow.md", PublicController, :workflow
  end

  scope "/api/v1", HelmsmanWeb.API do
    pipe_through [:api, :api_public]

    get "/openapi.json", PublicController, :openapi
  end

  scope "/api/v1/w/:slug", HelmsmanWeb.API do
    pipe_through [:api, :api_read]

    get "/me", MeController, :show
    get "/me/tasks", MeController, :tasks
    get "/actors", ActorsController, :index
    get "/agents", ActorsController, :agents
    get "/projects", ProjectsController, :index
    get "/projects/:key", ProjectsController, :show
    get "/projects/:key/tasks", TasksController, :index
    get "/tasks/:id", TasksController, :show
    get "/tasks/:id/feedback", FeedbackController, :index
    get "/tasks/:id/feedback/:seq", FeedbackController, :show
    get "/tasks/:id/runs", TasksController, :runs
    get "/search", SearchController, :index
    get "/runs/:id", RunsController, :show
    get "/runs/:id/events", RunsController, :events
    get "/query", QueryController, :index
    get "/filters", FiltersController, :index
    get "/filters/:id", FiltersController, :show
    get "/filters/:id/run", FiltersController, :run
    get "/exports/:id", BackupController, :show
    get "/imports/:id", BackupController, :import_status
  end

  scope "/api/v1/w/:slug", HelmsmanWeb.API do
    pipe_through :api_avatar

    get "/avatars/:key", AvatarsController, :show
  end

  # Binary snapshot download; bearer authentication and workspace checks still apply.
  scope "/api/v1/w/:slug", HelmsmanWeb.API do
    pipe_through :api_read

    get "/exports/:id/download", BackupController, :download
  end

  scope "/api/v1/w/:slug", HelmsmanWeb.API do
    pipe_through [:api, :api_write]

    post "/projects", ProjectsController, :create
    patch "/projects/:key", ProjectsController, :update
    post "/projects/:key/tasks", TasksController, :create
    patch "/tasks/:id", TasksController, :update
    post "/tasks/:id/transition", TasksController, :transition
    post "/tasks/:id/feedback", FeedbackController, :create
    patch "/tasks/:id/feedback/:seq", FeedbackController, :update
    post "/tasks/:id/links", LinksController, :create
    delete "/tasks/:id/links/:type/:to", LinksController, :delete
    post "/runs", RunsController, :create
    post "/runs/:id/cancel", RunsController, :cancel
    post "/runs/:id/retry", RunsController, :retry
    post "/filters", FiltersController, :create
    patch "/filters/:id", FiltersController, :update
    delete "/filters/:id", FiltersController, :delete
    post "/autopilots/:id/run", AutopilotsController, :run
    post "/exports", BackupController, :create
  end

  scope "/api", HelmsmanWeb.API do
    pipe_through :api_fallback

    match :*, "/*path", FallbackController, :not_found
  end

  import Phoenix.LiveDashboard.Router

  # LiveDashboard for instance administrators (`add-release-distribution`
  # decision 5); everyone else gets 404. Only variables without secrets are
  # shown.
  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :dashboard_csp]

    live_dashboard "/dashboard",
      live_session_name: :admin_dashboard,
      metrics: HelmsmanWeb.Telemetry,
      ecto_repos: [Helmsman.Repo],
      env_keys: ["PHX_HOST", "PHX_URL_SCHEME", "HELMSMAN_SIGNUP", "HELMSMAN_LOG_FORMAT"],
      csp_nonce_assign_key: %{script: :csp_nonce},
      on_mount: [
        {HelmsmanWeb.UserAuth, :require_authenticated},
        {HelmsmanWeb.UserAuth, :require_instance_admin}
      ]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:helmsman, :dev_routes) do
    scope "/dev" do
      pipe_through [:browser, :dashboard_csp]

      live_dashboard "/dashboard",
        metrics: HelmsmanWeb.Telemetry,
        csp_nonce_assign_key: %{script: :csp_nonce}
    end

    # The mailbox frames its own HTML preview, which the site's CSP
    # (`frame-ancestors 'none'`) would refuse.
    pipeline :dev_mailbox do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :protect_from_forgery
      plug :put_secure_browser_headers
    end

    scope "/dev" do
      pipe_through :dev_mailbox

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # Component showcase (spec web-components); also hosts the shell tests.
    scope "/dev", HelmsmanWeb.Dev do
      pipe_through :browser

      live_session :dev_ui,
        on_mount: [{HelmsmanWeb.Dev.UiLive, :demo_scope}, HelmsmanWeb.Shell] do
        live "/ui", UiLive, :index
        live "/ui/projects", UiLive, :projects
      end
    end
  end

  scope "/", HelmsmanWeb do
    pipe_through :avatar_image

    get "/w/:slug/avatars/:key", AvatarController, :workspace
    get "/users/avatar/:key", AvatarController, :own
  end

  ## Authentication routes

  scope "/", HelmsmanWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{HelmsmanWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/settings/provider-accounts", UserLive.ProviderAccounts, :index
      live "/workspaces/new", WorkspaceLive.New, :new
      live "/device", DeviceLive, :show
      live "/admin/github", Admin.GitHubLive, :show
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## GitHub (designs/15 §1): the return of the App's manifest flow started on
  ## `/admin/github` (Admin.GitHubLive) and the installation flow. Plain
  ## controller routes behind login: they only redirect to and from GitHub.
  ## `POST /webhooks/github` is served by HelmsmanWeb.GitHubWebhookPlug in
  ## the endpoint.

  scope "/", HelmsmanWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/admin/github/callback", GitHubController, :manifest_callback
    get "/w/:slug/settings/github/connect", GitHubController, :connect
    get "/github/setup", GitHubController, :setup
  end

  ## Workspace routes

  scope "/", HelmsmanWeb do
    pipe_through [:browser, :require_authenticated_user, :workspace_page]

    get "/w/:slug/exports/:id/download", ExportController, :download

    live_session :workspace,
      on_mount: [
        {HelmsmanWeb.UserAuth, :require_authenticated},
        {HelmsmanWeb.UserAuth, :require_workspace},
        HelmsmanWeb.Shell
      ] do
      live "/w/:slug", WorkspaceLive.Home, :show
      live "/w/:slug/projects", ProjectLive.Index, :index
      live "/w/:slug/p/:key", TaskLive.Index, :index
      live "/w/:slug/t/:ident", TaskLive.Show, :show
      live "/w/:slug/query", QueryLive, :show
      live "/w/:slug/settings", SettingsLive.General, :show
      live "/w/:slug/settings/members", SettingsLive.Members, :index
      live "/w/:slug/settings/tokens", SettingsLive.Tokens, :index
      live "/w/:slug/settings/github", SettingsLive.GitHub, :show
      live "/w/:slug/settings/data", SettingsLive.Data, :show
      live "/w/:slug/settings/runtimes", SettingsLive.Runtimes, :index
      live "/w/:slug/agents", AgentLive.Index, :index
      live "/w/:slug/agents/*name", AgentLive.Show, :show
      live "/w/:slug/agent-design", AgentDesignLive, :show
      live "/w/:slug/squads", SquadLive.Index, :index
      live "/w/:slug/squads/*name", SquadLive.Show, :show
      live "/w/:slug/autopilots", AutopilotLive.Index, :index
      live "/w/:slug/autopilots/:id", AutopilotLive.Show, :show
      live "/w/:slug/runs/:id", RunLive.Show, :show
    end
  end

  # A separate live_session: moving between it and the login page is a full page
  # load, so :store_invitation_return_to always runs (design D4).
  scope "/", HelmsmanWeb do
    pipe_through [:browser, :invitation_page]

    live_session :invitation, on_mount: [{HelmsmanWeb.UserAuth, :mount_current_scope}] do
      live "/invite/:token", InvitationLive, :show
    end
  end

  scope "/", HelmsmanWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{HelmsmanWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
