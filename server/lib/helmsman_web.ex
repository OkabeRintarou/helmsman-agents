defmodule HelmsmanWeb do
  use Boundary, deps: [Helmsman, HelmsmanMCP], exports: [Endpoint, Telemetry]

  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use HelmsmanWeb, :controller
      use HelmsmanWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: HelmsmanWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      @before_compile HelmsmanWeb.LiveFallback

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: HelmsmanWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components (daisyUI classes may only appear in these modules)
      import HelmsmanWeb.CoreComponents
      import HelmsmanWeb.Components.Actor
      import HelmsmanWeb.Components.DataTable
      import HelmsmanWeb.Components.FilterBar
      import HelmsmanWeb.Components.Layout
      import HelmsmanWeb.Components.Markdown
      import HelmsmanWeb.Components.Menu
      import HelmsmanWeb.Components.Overlay
      import HelmsmanWeb.Components.Status
      import HelmsmanWeb.Components.Text

      # Common modules used in templates
      alias HelmsmanWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: HelmsmanWeb.Endpoint,
        router: HelmsmanWeb.Router,
        statics: HelmsmanWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
