defmodule SystemsObservability.RouteCatalog do
  @moduledoc "Maps an endpoint and matched route/path to a bounded operational family."

  @routes %{
    "comma_product_api" => MapSet.new(~w(
      /health
      /v1/comma/admin/*
      /v1/comma/auth/*
      /v1/comma/billing/*
      /v1/comma/groups/*
      /v1/comma/integrations/*
      /v1/comma/me/*
      /v1/comma/public/*
      /v1/comma/workspaces
      /v1/comma/workspaces/*
    )),
    "salix_api" => MapSet.new(~w(
      /health
      /site/:id/*
      /site-api/*
      /site-content/*
      /dash/*
      /v1/admin/*
      /v1/agent-defaults
      /v1/agent-groups/*
      /v1/cloud-vm/*
      /v1/connect
      /v1/e2e-report-sessions/*
      /v1/im/*
      /v1/initial-agents
      /v1/initial-agents/*
      /v1/integrations/*
      /v1/loop-webhooks/*
      /v1/composio-webhooks/*
      /v1/oauth/*
      /v1/runtime/*
    ))
  }

  def classify("bft_dashboard", path) when is_binary(path) do
    if bft_dashboard_route?(path), do: "/dashboard/*", else: "unmatched"
  end

  def classify(endpoint, path)
      when endpoint in ["comma_product_api", "salix_api"] and is_binary(path) do
    route = route_group(path)
    if MapSet.member?(@routes[endpoint], route), do: route, else: "unmatched"
  end

  def classify(_endpoint, _path), do: "unmatched"

  defp route_group("/health"), do: "/health"
  defp route_group("/v1/agent-defaults"), do: "/v1/agent-defaults"
  defp route_group("/v1/connect"), do: "/v1/connect"
  defp route_group("/v1/initial-agents"), do: "/v1/initial-agents"
  defp route_group("/_site/api"), do: "/site-api/*"
  defp route_group("/_site/content"), do: "/site-content/*"
  defp route_group("/dash" <> _rest), do: "/dash/*"
  defp route_group("/site/" <> _rest), do: "/site/:id/*"

  # The Comma API is one namespace; its families are one level below it.
  defp route_group("/v1/comma/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [first] -> "/v1/comma/#{first}"
      [first, _rest] -> "/v1/comma/#{first}/*"
    end
  end

  defp route_group("/v1/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [first] -> "/v1/#{first}"
      [first, _rest] -> "/v1/#{first}/*"
    end
  end

  defp route_group(_path), do: "unmatched"

  defp bft_dashboard_route?(path) do
    not String.contains?(path, ["?", "#"]) and
      not Regex.match?(
        ~r/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i,
        path
      ) and
      (path == "/" or
         Regex.match?(
           ~r{^/(?:locale|login|signup|auth|logout|dev|v1|dashboard|orgs|impersonate|onboarding|new-home|cli|live|tasks)(?:/|$)},
           path
         ))
  end
end
