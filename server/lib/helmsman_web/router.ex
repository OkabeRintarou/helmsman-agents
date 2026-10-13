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
    plug :fetch_current_scope_for_user
  end

  # add-workspace-settings-ui D2 / D4
  pipeline :workspace_page do
    plug :remember_workspace
  end

  pipeline :invitation_page do
    plug :store_invitation_return_to
  end

  pipeline :api do
    plug :accepts, ["json"]
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
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: HelmsmanMCP.Server
  end

  # Other scopes may use custom stacks.
  # scope "/api", HelmsmanWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:helmsman, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HelmsmanWeb.Telemetry
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
      live "/w/:slug/settings", SettingsLive.General, :show
      live "/w/:slug/settings/members", SettingsLive.Members, :index
      live "/w/:slug/settings/tokens", SettingsLive.Tokens, :index
      live "/w/:slug/settings/github", SettingsLive.GitHub, :show
      live "/w/:slug/settings/runtimes", SettingsLive.Runtimes, :index
      live "/w/:slug/agents", AgentLive.Index, :index
      live "/w/:slug/agents/*name", AgentLive.Show, :show
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
