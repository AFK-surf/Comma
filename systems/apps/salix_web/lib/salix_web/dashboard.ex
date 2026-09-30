defmodule SalixWeb.Dashboard do
  @moduledoc """
  Phoenix entrypoint conventions for the Salix admin dashboard — the LiveView UI
  served under `/dash` on the SAME Bandit listener as the JSON API (port 4000),
  authenticated with the system-wide admin token.

  Use one of the macros below in dashboard modules:

      use SalixWeb.Dashboard, :live_view
      use SalixWeb.Dashboard, :controller
      use SalixWeb.Dashboard, :html

  `html_helpers/0` imports `SalixWeb.Dashboard.CoreComponents` (the design system)
  and the verified-routes sigil, shared by LiveViews, components, and HTML
  controllers.
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: SalixWeb.Dashboard.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {SalixWeb.Dashboard.Layouts, :app}

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

      import SalixWeb.Dashboard.CoreComponents

      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SalixWeb.DashboardEndpoint,
        router: SalixWeb.Dashboard.Router,
        statics: SalixWeb.Dashboard.static_paths()
    end
  end

  @doc "When used, dispatch to the appropriate macro."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
