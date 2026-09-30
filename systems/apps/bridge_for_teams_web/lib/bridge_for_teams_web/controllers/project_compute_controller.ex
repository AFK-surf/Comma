defmodule BridgeForTeamsWeb.ProjectComputeController do
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse
  alias BridgeForTeams.{Compute, Subscriptions}
  alias BridgeForTeamsWeb.ProjectScope

  def index(conn, params), do: with_scope(conn, params, :read, &Compute.project/2)

  def grant(conn, params),
    do: with_scope(conn, params, :write, &Compute.issue_grant(&1, &2, params))

  def create_environment(conn, params),
    do: with_scope(conn, params, :write, &Compute.create_environment(&1, &2, params))

  def create_workload(conn, params),
    do: with_scope(conn, params, :write, &Compute.create_workload(&1, &2, params))

  def managed_auth(conn, params) do
    operation =
      case conn.method do
        "GET" -> :read
        "PUT" -> :bind
        "DELETE" -> :unbind
      end

    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <-
           ProjectScope.require_project_for_conn(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         configure = managed_auth_configure?(conn, org, project),
         :ok <- require_managed_auth_write(operation, configure),
         {:ok, result} <-
           managed_auth_operation(org, project, operation, params),
         {:ok, result} <- add_managed_auth_accounts(result, org, conn, configure, params) do
      result = managed_auth_projection(result, configure)

      result =
        if Map.has_key?(params, "device_id"),
          do:
            Map.put(
              result,
              "can_self_configure",
              ProjectScope.authorize_project_for_conn(conn, project, :write) == :ok
            ),
          else: result

      status =
        if operation != :read and result["state"] in ["installing", "revoking", "failed"],
          do: 202,
          else: 200

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_ok(%{"mode" => "managed_auth", "managed_auth" => result}, status)
    else
      {:error, :conflict} ->
        send_error(
          conn,
          409,
          "configuration_changed",
          "The managed authentication selection changed.",
          %{}
        )

      {:error, reason} when reason in [:invalid_input, :unsupported_binding] ->
        send_error(
          conn,
          422,
          "unsupported_managed_auth",
          "This account cannot configure the selected runtime.",
          %{}
        )

      {:error, reason} when reason in [:account_unavailable, :account_in_use] ->
        send_error(
          conn,
          409,
          Atom.to_string(reason),
          "The organization account is not available for this change.",
          %{}
        )

      error ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_project_error(error, "Managed authentication is unavailable.")
    end
  end

  defp managed_auth_operation(
         org,
         project,
         operation,
         %{"device_id" => device, "runtime_id" => runtime} = params
       ) do
    BridgeForTeams.Salix.Client.impl().device_managed_auth_operation(
      org.salix_tenant_id,
      project.salix_group_id,
      device,
      runtime,
      operation,
      managed_auth_attrs(operation, params)
    )
  end

  defp managed_auth_operation(org, project, operation, %{"id" => workload} = params) do
    Compute.managed_auth(org, project, workload, operation, managed_auth_attrs(operation, params))
  end

  def request_agent_vmm_install(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    request_id = conn |> get_req_header("idempotency-key") |> List.first()

    with_scope(
      conn,
      Map.put(params, "request_id", request_id),
      :write,
      &Compute.request_agent_vmm_install(&1, &2, Map.put(params, "request_id", request_id))
    )
  end

  def get_agent_vmm_install(conn, %{"operation_id" => operation_id} = params),
    do:
      with_scope(
        put_resp_header(conn, "cache-control", "no-store"),
        params,
        :read,
        &Compute.get_agent_vmm_install(&1, &2, operation_id)
      )

  def retry_agent_vmm_install(conn, %{"operation_id" => operation_id} = params),
    do:
      with_scope(
        put_resp_header(conn, "cache-control", "no-store"),
        params,
        :write,
        &Compute.retry_agent_vmm_install(&1, &2, operation_id)
      )

  def revoke_agent_vmm_install(conn, %{"operation_id" => operation_id} = params),
    do:
      with_scope(
        put_resp_header(conn, "cache-control", "no-store"),
        params,
        :write,
        &Compute.revoke_agent_vmm_install(&1, &2, operation_id)
      )

  def enable_agent_vmm_install(conn, %{"operation_id" => operation_id} = params),
    do:
      with_scope(
        put_resp_header(conn, "cache-control", "no-store"),
        params,
        :write,
        &Compute.configure_agent_vmm_install(&1, &2, operation_id, true)
      )

  def disable_agent_vmm_install(conn, %{"operation_id" => operation_id} = params),
    do:
      with_scope(
        put_resp_header(conn, "cache-control", "no-store"),
        params,
        :write,
        &Compute.configure_agent_vmm_install(&1, &2, operation_id, false)
      )

  def retain(conn, %{"environment_id" => id} = params),
    do: with_scope(conn, params, :write, &Compute.retain(&1, &2, id, params))

  def drain(conn, %{"environment_id" => id} = params),
    do: with_scope(conn, params, :write, &Compute.drain(&1, &2, id, params))

  def revoke(conn, %{"environment_id" => id} = params),
    do: with_scope(conn, params, :write, &Compute.revoke(&1, &2, id, params))

  defp with_scope(conn, params, action, operation) do
    with {:ok, org} <- ProjectScope.require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- ProjectScope.require_project_for_conn(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, action),
         {:ok, result} <- operation.(org, project) do
      send_ok(conn, %{"mode" => "project_compute", "compute" => result})
    else
      {:error, :not_found} ->
        send_error(conn, 404, "not_found", "Compute resource not found.", %{})

      {:error, :revision_conflict} ->
        send_error(conn, 409, "revision_conflict", "Compute state changed.", %{})

      {:error, :already_exists} ->
        send_error(conn, 409, "already_exists", "Compute resource already exists.", %{})

      {:error, :operation_not_retryable} ->
        send_error(
          conn,
          409,
          "operation_not_retryable",
          "This install operation is terminal; start a new install operation.",
          %{}
        )

      {:error, :unavailable} ->
        send_error(conn, 503, "compute_unavailable", "Compute is unavailable.", %{})

      error ->
        send_project_error(conn, error, "Compute request failed.")
    end
  end

  defp managed_auth_configure?(conn, org, project) do
    ProjectScope.authorize_org_for_conn(conn, org, "admin") == :ok and
      ProjectScope.authorize_project_for_conn(conn, project, :write) == :ok
  end

  defp require_managed_auth_write(:read, _configure), do: :ok
  defp require_managed_auth_write(_operation, true), do: :ok

  defp require_managed_auth_write(_operation, false),
    do:
      {:error, 403, "forbidden",
       "Organization administrator and project write access are required.", %{}}

  defp managed_auth_attrs(:read, _params), do: %{}

  defp managed_auth_attrs(:bind, params),
    do: Map.take(params, ~w(account_id expected_account_version expected_binding))

  defp managed_auth_attrs(:unbind, params), do: Map.take(params, ~w(expected_binding))

  defp add_managed_auth_accounts(result, _org, _conn, false, _params), do: {:ok, result}

  defp add_managed_auth_accounts(result, org, conn, true, params) do
    cursor = params["account_cursor"] || ""
    user = ProjectScope.current_user(conn)

    with {:ok, page} <- Subscriptions.list({org.id, user.id}, cursor) do
      accounts =
        Enum.filter(
          page["accounts"],
          &managed_auth_compatible?(&1, result["provider"], Map.has_key?(params, "device_id"))
        )

      {:ok, Map.merge(result, %{"accounts" => accounts, "accounts_next" => page["next"]})}
    else
      {:error, _} ->
        {:ok,
         Map.merge(result, %{
           "accounts" => [],
           "accounts_next" => "",
           "accounts_unavailable" => true
         })}
    end
  end

  defp managed_auth_compatible?(account, "claude", true) do
    managed_auth_compatible?(account, "claude") or
      (account["credential_kind"] == "subscription_oauth" and account["provider"] == "claude" and
         account["status"] == "active" and account["disabled"] == false)
  end

  defp managed_auth_compatible?(account, provider, _device),
    do: managed_auth_compatible?(account, provider)

  defp managed_auth_compatible?(account, "codex"),
    do:
      account["credential_kind"] == "subscription_oauth" and account["provider"] == "codex" and
        account["status"] == "active" and account["disabled"] == false

  defp managed_auth_compatible?(account, provider) when provider in ["pi", "claude"],
    do:
      account["credential_kind"] == "provider_api_key" and account["disabled"] == false and
        provider in (account["compatible_runtimes"] || [])

  defp managed_auth_compatible?(_, _), do: false

  defp managed_auth_projection(result, true), do: Map.put(result, "can_configure", true)

  defp managed_auth_projection(result, false) do
    result |> Map.take(~w(source state provider issue)) |> Map.put("can_configure", false)
  end
end
