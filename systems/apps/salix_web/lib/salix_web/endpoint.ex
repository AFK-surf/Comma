defmodule SalixWeb.Endpoint do
  @moduledoc """
  Top-level HTTP entry point — the Salix port of willow's `api.Server.Handler`
  routing branch. When a sites domain is configured
  (`config :salix_agent, :sites_domain`), requests whose Host header matches

      {site-name}-{base32-agent-id}.{sites-domain}

  are served from the agent's VFS: `/_api/...` goes to the site API
  (`SalixWeb.SiteAPI` — LLM proxy + document storage), everything else to
  static serving (`SalixWeb.Site.serve_host/3`). Site traffic is public and
  never reaches the bearer-auth API router, exactly like willow. All other
  requests fall through to `SalixWeb.Router`.
  """

  @behaviour Plug

  alias SalixAgent.SiteId

  @impl true
  def init(opts), do: SalixWeb.Router.init(opts)

  @impl true
  def call(conn, opts) do
    with domain when is_binary(domain) <- SiteId.sites_domain(),
         {:ok, site_name, agent_id} <- SiteId.extract_site_info(host_header(conn), domain) do
      if conn.request_path == "/_api" or String.starts_with?(conn.request_path, "/_api/") do
        conn
        |> instrument_site("/_site/api")
        |> SalixWeb.SiteAPI.call(agent_id, site_name)
      else
        conn
        |> instrument_site("/_site/content")
        |> SalixWeb.Site.serve_host(agent_id, site_name)
      end
    else
      _ -> route_non_site(conn, opts)
    end
  end

  defp instrument_site(conn, route) do
    SystemsObservability.HTTPPlug.call(conn, endpoint: :salix_api, route: route)
  end

  # Normal-host (non-site) traffic. The admin dashboard is a Phoenix LiveView
  # endpoint served on THIS same Bandit listener: `/dash/*` is handed to
  # `SalixWeb.DashboardEndpoint` (started with `server: false`, so it owns no
  # listener of its own) and never reaches the bearer-auth `SalixWeb.Router`.
  # The LiveView websocket upgrade at `/dash/live/websocket` rides this request's
  # Bandit adapter, so it works despite the endpoint not opening a socket itself.
  defp route_non_site(conn, opts) do
    cond do
      SalixWeb.LocalOAuthMock.public_path?(conn.request_path) ->
        conn
        |> SystemsObservability.HTTPPlug.call(
          endpoint: :salix_api,
          route: "/v1/local-oauth/:provider/:action"
        )
        |> SalixWeb.LocalOAuthMock.call([])

      dashboard_path?(conn.request_path) ->
        SalixWeb.DashboardEndpoint.call(conn, [])

      true ->
        SalixWeb.Router.call(conn, opts)
    end
  end

  defp dashboard_path?("/dash"), do: true
  defp dashboard_path?("/dash/" <> _rest), do: true
  defp dashboard_path?(_path), do: false

  # The raw Host header (with port) — conn.host already strips the port, but
  # extract_site_info mirrors willow and handles both.
  defp host_header(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] -> host
      _ -> conn.host || ""
    end
  end
end
