defmodule BridgeForTeamsWeb.Dashboard do
  @moduledoc """
  Phoenix entrypoint conventions for the BridgeForTeams dashboard LiveView UI.

  Use one of the macros below in dashboard modules:

      use BridgeForTeamsWeb.Dashboard, :live_view
      use BridgeForTeamsWeb.Dashboard, :controller
      use BridgeForTeamsWeb.Dashboard, :html

  `html_helpers/0` imports `BridgeForTeamsWeb.Dashboard.CoreComponents` (the design
  system) and the verified-routes sigil, and is shared by LiveViews, components,
  and HTML controllers.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

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
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: BridgeForTeamsWeb.Dashboard.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {BridgeForTeamsWeb.Dashboard.Layouts, :app}

      unquote(html_helpers())
    end
  end

  # Full-screen LiveViews without the sidebar app shell (first-run onboarding).
  def onboarding_live_view do
    quote do
      use Phoenix.LiveView,
        layout: {BridgeForTeamsWeb.Dashboard.Layouts, :onboarding}

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

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      # Translation macros (gettext/1,2, dgettext/3, ngettext/3, …) for every
      # LiveView, component, and HTML controller. See I18n design doc.
      use Gettext, backend: BridgeForTeamsWeb.Gettext

      import BridgeForTeamsWeb.Dashboard.CoreComponents

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: BridgeForTeamsWeb.DashboardEndpoint,
        router: BridgeForTeamsWeb.DashboardRouter,
        statics: BridgeForTeamsWeb.Dashboard.static_paths()
    end
  end

  @doc "When used, dispatch to the appropriate macro."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
