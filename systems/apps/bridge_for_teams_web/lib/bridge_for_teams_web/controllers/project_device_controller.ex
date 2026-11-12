defmodule BridgeForTeamsWeb.ProjectDeviceController do
  @moduledoc """
  Project-scoped device API used by BFT clients.

  The dashboard LiveView and this HTTP surface both use
  `BridgeForTeams.Environments`; this controller only owns transport,
  authorization, response shape, and redaction.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  import BridgeForTeamsWeb.ProjectAPIResponse

  alias BridgeForTeams.Environments
  alias BridgeForTeams.RuntimeAuth
  alias BridgeForTeamsWeb.{LimitParams, ProjectScope}
  alias SalixStore.RuntimeIds

  def private_runtime_auth(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, result} <-
           RuntimeAuth.call(ProjectScope.current_user(conn).id, project.id, conn.body_params) do
      send_ok(conn, %{"runtime_auth" => result})
    else
      {:error, :invalid_runtime_auth_request} ->
        send_error(
          conn,
          400,
          "invalid_runtime_auth_request",
          "Invalid authentication input.",
          %{}
        )

      {:error, :forbidden} ->
        send_error(conn, 403, "forbidden", "Project administrator access is required.", %{})

      {:error, :managed_auth_conflict} ->
        send_error(
          conn,
          409,
          "managed_auth_conflict",
          "Unbind the organization account before changing runtime credentials.",
          %{}
        )

      error ->
        send_runtime_auth_error(conn, error, "Could not update runtime authentication.")
    end
  end

  def index(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, limit} <- read_limit(params),
         {:ok, devices} <-
           Environments.list_projected_environments(project.id, limit: limit) do
      filter = trim(params["filter"])

      devices =
        devices
        |> Enum.map(&public_device/1)
        |> filter_text(filter)
        |> Enum.take(limit)

      send_ok(conn, %{
        "mode" => "project_devices_list",
        "org" => public_org(org),
        "project" => public_project(project),
        "devices" => devices,
        "limit" => limit,
        "filter" => empty_nil(filter),
        "summary" => device_summary(devices),
        "next_action" => devices_next_action(org, project, devices)
      })
    else
      {:error, :invalid_limit} ->
        send_error(conn, 400, "invalid_limit", "Limit must be a positive integer.", %{})

      error ->
        send_project_error(conn, error, "Could not list project devices.")
    end
  end

  def disconnect(conn, %{"device_id" => device_id} = params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, record} <-
           Environments.disconnect_environment(
             project.id,
             device_id,
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_device_disconnect",
        "org" => public_org(org),
        "project" => public_project(project),
        "device" => public_device(record),
        "next_action" => "The device's station has been disconnected."
      })
    else
      {:error, :not_found} ->
        send_error(conn, 404, "device_not_found", "Device not found.", %{})

      error ->
        send_project_error(conn, error, "Could not disconnect project device.")
    end
  end

  def runtime_auth(
        conn,
        %{"device_id" => device_id, "device_runtime_id" => device_runtime_id} = params
      ) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, runtime_auth} <-
           Environments.read_runtime_auth(project.id, device_id, device_runtime_id) do
      send_ok(conn, %{
        "mode" => "project_device_runtime_auth",
        "device_id" => device_id,
        "device_runtime_id" => device_runtime_id,
        "runtime_auth" => runtime_auth
      })
    else
      error -> send_runtime_auth_error(conn, error, "Could not read runtime authentication.")
    end
  end

  def start_runtime_login(
        conn,
        %{"device_id" => device_id, "device_runtime_id" => device_runtime_id} = params
      ) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, runtime_auth} <-
           Environments.start_runtime_login(
             project.id,
             device_id,
             device_runtime_id,
             params["flow"],
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_device_runtime_login_start",
        "device_id" => device_id,
        "device_runtime_id" => device_runtime_id,
        "runtime_auth" => runtime_auth
      })
    else
      error -> send_runtime_auth_error(conn, error, "Could not start runtime login.")
    end
  end

  def cancel_runtime_login(
        conn,
        %{
          "device_id" => device_id,
          "device_runtime_id" => device_runtime_id
        } = params
      ) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    attempt_id = params["attempt_id"]

    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, runtime_auth} <-
           Environments.cancel_runtime_login(
             project.id,
             device_id,
             device_runtime_id,
             attempt_id,
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_device_runtime_login_cancel",
        "device_id" => device_id,
        "device_runtime_id" => device_runtime_id,
        "runtime_auth" => runtime_auth
      })
    else
      error -> send_runtime_auth_error(conn, error, "Could not cancel runtime login.")
    end
  end

  defp send_runtime_auth_error(conn, {:error, status, code, message, details}, _fallback),
    do: send_error(conn, status, code, message, details)

  defp send_runtime_auth_error(conn, {:error, reason}, fallback),
    do: send_runtime_auth_reason(conn, reason, fallback)

  defp send_runtime_auth_error(conn, reason, fallback),
    do: send_runtime_auth_reason(conn, reason, fallback)

  defp send_runtime_auth_reason(conn, :not_found, _fallback),
    do: send_error(conn, 404, "runtime_auth_not_found", "Runtime not found.", %{})

  defp send_runtime_auth_reason(conn, reason, _fallback)
       when reason in [
              :connector_disconnected,
              :runtime_auth_unsupported,
              :runtime_auth_conflict,
              :runtime_auth_target_changed
            ],
       do: send_error(conn, 409, Atom.to_string(reason), runtime_auth_error_message(reason), %{})

  defp send_runtime_auth_reason(conn, reason, _fallback)
       when reason in [
              :invalid_runtime_auth_request,
              :invalid_runtime_auth_flow,
              :invalid_runtime_auth_attempt_id
            ],
       do: send_error(conn, 400, Atom.to_string(reason), runtime_auth_error_message(reason), %{})

  defp send_runtime_auth_reason(conn, :runtime_auth_timeout, _fallback),
    do: send_error(conn, 504, "runtime_auth_timeout", "Runtime authentication timed out.", %{})

  defp send_runtime_auth_reason(conn, :unavailable, _fallback),
    do:
      send_error(
        conn,
        503,
        "runtime_auth_unavailable",
        "Runtime authentication is temporarily unavailable.",
        %{}
      )

  defp send_runtime_auth_reason(conn, _reason, fallback),
    do: send_error(conn, 502, "runtime_auth_failed", fallback, %{})

  defp runtime_auth_error_message(:connector_disconnected),
    do: "The station is disconnected."

  defp runtime_auth_error_message(:runtime_auth_unsupported),
    do: "This station does not support runtime authentication."

  defp runtime_auth_error_message(:runtime_auth_conflict),
    do: "Another runtime login attempt is already active."

  defp runtime_auth_error_message(:runtime_auth_target_changed),
    do: "The runtime target changed. Refresh and try again."

  defp runtime_auth_error_message(:invalid_runtime_auth_request),
    do: "The runtime authentication request is invalid."

  defp runtime_auth_error_message(:invalid_runtime_auth_flow),
    do: "Only the device_code runtime login flow is supported."

  defp runtime_auth_error_message(:invalid_runtime_auth_attempt_id),
    do: "The runtime login attempt id is invalid."

  defp require_org(ref) do
    ProjectScope.require_org(ref, missing_message: "Pass an org id or slug.")
  end

  defp require_project(conn, org, ref) do
    ProjectScope.require_project_for_conn(conn, org, ref,
      missing_message: "Pass a project id or slug."
    )
  end

  defp read_limit(params), do: LimitParams.read(params, "limit", 100)

  defp public_device(record) when is_map(record) do
    runtimes =
      record["device_runtimes"]
      |> List.wrap()
      |> Enum.filter(fn runtime ->
        is_map(runtime) and RuntimeIds.external_runtime_provider?(runtime["provider"])
      end)

    %{
      "id" => record["device_id"],
      "connector_run_id" => record["connector_run_id"],
      "device_id" => record["device_id"],
      "connector_id" => record["connector_id"],
      "name" => record["name"],
      "status" => record["status"] || "unknown",
      "last_seen_at" => record["updated_at"],
      "updated_at" => record["updated_at"],
      "runtime_count" => length(runtimes),
      "runtimes" =>
        runtimes
        |> Enum.map(&public_device_runtime/1)
        |> Enum.reject(&(&1 == %{}))
    }
  end

  defp public_device_runtime(runtime) when is_map(runtime) do
    %{
      "provider" => runtime["provider"],
      "runtime_id" => runtime["runtime_id"],
      "device_runtime_id" => runtime["device_runtime_id"],
      "status" => runtime["status"],
      "issue" => runtime["issue"],
      "auth" => public_device_runtime_auth(runtime["auth"]),
      "readiness" => public_device_runtime_readiness(runtime)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp public_device_runtime(_runtime), do: %{}

  defp public_device_runtime_auth(auth) do
    case RuntimeAuth.snapshot(auth) do
      {:ok, safe} -> safe
      {:error, _reason} -> nil
    end
  end

  defp public_device_runtime_readiness(runtime) do
    %{
      "status" => runtime["status"],
      "issue" => runtime["issue"],
      "version" => runtime["version"],
      "model" => runtime["model"],
      "model_provider" => runtime["model_provider"],
      "reasoning_effort" => runtime["reasoning_effort"],
      "readiness_checked_at" => runtime["readiness_checked_at"],
      "readiness_valid_until" => runtime["readiness_valid_until"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp device_summary(devices) do
    %{
      "device_count" => length(devices),
      "connected_count" => Enum.count(devices, &(&1["status"] == "connected"))
    }
  end

  defp filter_text(rows, ""), do: rows

  defp filter_text(rows, filter) do
    needle = String.downcase(filter)

    Enum.filter(rows, fn row ->
      row
      |> flatten_values()
      |> Enum.any?(fn value ->
        value
        |> to_string()
        |> String.downcase()
        |> String.contains?(needle)
      end)
    end)
  end

  defp flatten_values(%{} = map) do
    Enum.flat_map(map, fn {_key, value} -> flatten_values(value) end)
  end

  defp flatten_values(values) when is_list(values), do: Enum.flat_map(values, &flatten_values/1)
  defp flatten_values(nil), do: []
  defp flatten_values(value), do: [value]

  defp devices_next_action(org, project, []),
    do:
      "Connect a station to the Agent Swarm, then run `bft devices list --org #{org.slug} --project #{project.slug}` again."

  defp devices_next_action(org, project, _devices),
    do:
      "Use `bft agents list --org #{org.slug} --project #{project.slug}` to inspect the agents bound to these stations."

  defp request_audit_opts(conn) do
    user = ProjectScope.current_user(conn)

    [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: List.first(get_req_header(conn, "x-request-id")) || SystemsRuntime.Proc.uuid()
    ]
  end

  defp actor_label(user) do
    cond do
      present?(Map.get(user, :email)) -> String.trim(user.email)
      present?(Map.get(user, :name)) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
