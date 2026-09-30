defmodule BridgeForTeamsWeb.OrgComputeController do
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse
  alias BridgeForTeams.Compute
  alias BridgeForTeamsWeb.ProjectScope

  def create_pool(conn, params) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "admin"),
         {:ok, pool} <- Compute.create_pool(org, params) do
      send_ok(conn, %{"mode" => "org_compute", "pool" => pool})
    else
      {:error, :revision_conflict} ->
        send_error(conn, 409, "revision_conflict", "Compute pool changed.", %{})

      error ->
        send_project_error(conn, error, "Compute pool request failed.")
    end
  end

  def update_pool(conn, %{"pool_id" => pool_id} = params) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "admin"),
         {:ok, pool} <- Compute.update_pool(org, pool_id, params) do
      send_ok(conn, %{"mode" => "org_compute", "pool" => pool})
    else
      {:error, :revision_conflict} ->
        send_error(conn, 409, "revision_conflict", "Compute pool changed.", %{})

      error ->
        send_project_error(conn, error, "Compute pool request failed.")
    end
  end

  def configure_provider(conn, %{"pool_id" => pool_id} = params) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "admin"),
         {:ok, provider} <- Compute.configure_provider(org, pool_id, params) do
      send_ok(conn, %{"mode" => "org_compute", "provider" => provider})
    else
      error -> send_project_error(conn, error, "Compute provider request failed.")
    end
  end

  def configure_default_provider(conn, params) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "admin"),
         {:ok, result} <- Compute.configure_default_provider(org, params) do
      send_ok(conn, %{
        "mode" => "org_compute",
        "pool" => result.pool,
        "provider" => result.provider
      })
    else
      error -> send_project_error(conn, error, "Compute provider request failed.")
    end
  end

  def update_provider(conn, %{"provider_id" => provider_id} = params) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "admin"),
         {:ok, provider} <- Compute.update_provider(org, provider_id, params) do
      send_ok(conn, %{"mode" => "org_compute", "provider" => provider})
    else
      {:error, :revision_conflict} ->
        send_error(conn, 409, "revision_conflict", "Compute provider changed.", %{})

      error ->
        send_project_error(conn, error, "Compute provider request failed.")
    end
  end
end
