defmodule AlertRouter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add(oidc_enabled?(), oidc_child())
      |> maybe_add(Application.get_env(:alert_router, :start_repo, true), AlertRouter.Repo)
      |> maybe_add(
        Application.get_env(:alert_router, :start_oban, true),
        {Oban, Application.fetch_env!(:alert_router, Oban)}
      )
      |> maybe_add(Application.get_env(:alert_router, :start_http, true), http_child())

    Supervisor.start_link(children, strategy: :one_for_one, name: AlertRouter.Supervisor)
  end

  defp maybe_add(children, true, child), do: children ++ [child]
  defp maybe_add(children, _enabled, _child), do: children

  defp http_child do
    {Bandit,
     plug: AlertRouter.Web.Router,
     port: port(),
     startup_log: false,
     http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false],
     thousand_island_options: [supervisor_options: [name: AlertRouter.HTTPServer]]}
  end

  defp port, do: Application.get_env(:alert_router, :port, 4300)

  defp oidc_enabled? do
    Application.get_env(:alert_router, :gcp_push, [])
    |> Keyword.get(:oidc_provider_enabled, false)
  end

  defp oidc_child do
    {Oidcc.ProviderConfiguration.Worker,
     %{issuer: "https://accounts.google.com", name: AlertRouter.GCPOIDCProvider}}
  end
end
