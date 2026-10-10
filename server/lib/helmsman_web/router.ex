defmodule HelmsmanWeb.Router do
  use HelmsmanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HelmsmanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HelmsmanWeb do
    pipe_through :browser

    get "/", PageController, :home
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
end
