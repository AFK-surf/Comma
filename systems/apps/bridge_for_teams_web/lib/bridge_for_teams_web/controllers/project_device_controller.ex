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
  alias BridgeForTeams.{Orgs, Projects}
  alias BridgeForTeams.Schema.{MacMiniProvisioner, Organization}
  alias BridgeForTeamsWeb.{LimitParams, ProjectScope}
  alias SalixStore.RuntimeIds

  def runtime_auth_management(conn, %{"project_id" => project_id} = params) do
    user = ProjectScope.current_user(conn)

    with {:ok, project} <- Projects.get_project(project_id),
         {:ok, org} <- Orgs.get_org(project.org_id),
         :ok <- ProjectScope.authorize_org(user, org, "member"),
         :ok <- ProjectScope.authorize_project(user, project, :read) do
      query = runtime_auth_management_query(params)

      suffix = if query == "", do: "", else: "?" <> query
      redirect(conn, to: "/orgs/#{org.slug}/projects/#{project.id}/devices" <> suffix)
    else
      _ -> conn |> send_resp(404, "not found") |> halt()
    end
  end

  defp runtime_auth_management_query(%{"target" => target} = params)
       when is_binary(target) and byte_size(target) in 1..256 do
    %{"runtime_auth_target" => target}
    |> then(fn query ->
      case params["request"] do
        request when is_binary(request) and byte_size(request) in 1..256 ->
          Map.put(query, "runtime_auth_request", request)

        _ ->
          query
      end
    end)
    |> URI.encode_query()
  end

  defp runtime_auth_management_query(_params), do: ""

  def runtime_auth_requests(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :read),
         {:ok, page} <-
           RuntimeAuth.list_requests(
             ProjectScope.current_user(conn).id,
             project.id,
             cursor: params["cursor"]
           ) do
      send_ok(conn, %{
        "runtime_auth_requests" => page["requests"],
        "next_cursor" => page["next_cursor"]
      })
    else
      error ->
        send_runtime_auth_error(conn, error, "Could not list runtime authentication requests.")
    end
  end

  def complete_runtime_auth_request(conn, %{"request_id" => request_id} = params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with %{"outcome" => outcome} <- conn.body_params,
         true <- Map.keys(conn.body_params) == ["outcome"],
         {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, request} <-
           RuntimeAuth.complete_request(
             ProjectScope.current_user(conn).id,
             project.id,
             request_id,
             outcome
           ) do
      send_ok(conn, %{"runtime_auth_request" => request})
    else
      false ->
        send_error(conn, 400, "invalid_runtime_auth_request", "Invalid completion.", %{})

      %{} ->
        send_error(conn, 400, "invalid_runtime_auth_request", "Invalid completion.", %{})

      error ->
        send_runtime_auth_error(conn, error, "Could not complete runtime authentication request.")
    end
  end

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

      requests =
        project.id
        |> Environments.list_device_provision_requests(limit: limit)
        |> Enum.map(&public_device_request/1)

      devices =
        devices
        |> Enum.map(&public_device/1)
        |> filter_text(filter)
        |> Enum.take(limit)

      requests =
        requests
        |> filter_text(filter)
        |> Enum.take(limit)

      send_ok(conn, %{
        "mode" => "project_devices_list",
        "org" => public_org(org),
        "project" => public_project(project),
        "devices" => devices,
        "device_requests" => requests,
        "limit" => limit,
        "filter" => empty_nil(filter),
        "summary" => device_summary(devices, requests),
        "next_action" => devices_next_action(org, project, devices, requests)
      })
    else
      {:error, :invalid_limit} ->
        send_error(conn, 400, "invalid_limit", "Limit must be a positive integer.", %{})

      error ->
        send_project_error(conn, error, "Could not list project devices.")
    end
  end

  def create(conn, params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, attrs} <- device_attrs(org, params),
         {:ok, request} <-
           Environments.create_device_provision_request(
             project.id,
             attrs,
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_device_create",
        "org" => public_org(org),
        "project" => public_project(project),
        "device_request" => public_device_request(request),
        "next_action" =>
          "Wait for the selected runner to claim this request, then list project devices again."
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, 400, "invalid_device_request", "Could not create the project device.", %{
          "errors" => changeset_errors(changeset)
        })

      {:error, :runner_required} ->
        send_error(
          conn,
          400,
          "runner_required",
          "Pass runner.",
          %{}
        )

      {:error, :runner_not_found} ->
        send_error(conn, 404, "runner_not_found", "Runner not found.", %{})

      {:error, :runner_ambiguous} ->
        send_error(
          conn,
          409,
          "runner_ambiguous",
          "Runner name is ambiguous. Pass the runner id or stable id.",
          %{}
        )

      {:error, :provisioner_offline} ->
        send_error(conn, 409, "runner_offline", "Runner is offline.", %{})

      error ->
        send_project_error(conn, error, "Could not create project device.")
    end
  end

  def stop_request(conn, %{"request_id" => request_id} = params) do
    with {:ok, org} <- require_org(params["org"]),
         :ok <- ProjectScope.authorize_org_for_conn(conn, org, "member"),
         {:ok, project} <- require_project(conn, org, params["project"]),
         :ok <- ProjectScope.authorize_project_for_conn(conn, project, :write),
         {:ok, request} <-
           Environments.request_device_provision_stop(
             project.id,
             request_id,
             request_audit_opts(conn)
           ) do
      send_ok(conn, %{
        "mode" => "project_device_request_stop",
        "org" => public_org(org),
        "project" => public_project(project),
        "device_request" => public_device_request(request),
        "next_action" => "Wait for the runner to stop this device request."
      })
    else
      {:error, :not_found} ->
        send_error(conn, 404, "device_request_not_found", "Device request not found.", %{})

      {:error, :not_stoppable} ->
        send_error(
          conn,
          409,
          "device_request_not_stoppable",
          "Device request cannot be stopped in its current state.",
          %{}
        )

      error ->
        send_project_error(conn, error, "Could not stop project device request.")
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
        "next_action" => "The device's current connector run has been disconnected."
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
    do: "The Connector is disconnected."

  defp runtime_auth_error_message(:runtime_auth_unsupported),
    do: "This Connector does not support runtime authentication."

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

  defp device_attrs(%Organization{} = org, params) do
    runner_ref = params["runner"] || params["runner_id"]

    with {:ok, %MacMiniProvisioner{} = runner} <-
           resolve_runner(org, runner_ref) do
      %{}
      |> put_present("name", params["name"])
      |> put_present("alias", params["alias"])
      |> Map.put("provisioner_id", runner.id)
      |> then(&{:ok, &1})
    end
  end

  defp resolve_runner(%Organization{} = org, ref) do
    runners = Environments.list_mac_mini_provisioners(org.id)
    ref = trim(ref)

    if ref == "" do
      {:error, :runner_required}
    else
      runners
      |> select_runner(ref)
      |> case do
        {:ok, runner} -> ensure_runner_online(runner)
        error -> error
      end
    end
  end

  defp select_runner(runners, ref) do
    case Enum.find(runners, &(ref in [&1.id, &1.stable_id])) do
      %MacMiniProvisioner{} = runner ->
        {:ok, runner}

      nil ->
        case Enum.filter(runners, &(&1.name == ref)) do
          [runner] -> {:ok, runner}
          [] -> {:error, :runner_not_found}
          _many -> {:error, :runner_ambiguous}
        end
    end
  end

  defp ensure_runner_online(%MacMiniProvisioner{} = runner) do
    if runner_online?(runner), do: {:ok, runner}, else: {:error, :provisioner_offline}
  end

  defp runner_online?(%MacMiniProvisioner{} = runner) do
    (runner.effective_status || runner.status) == "online"
  end

  defp public_device_request(request) do
    %{
      "id" => request.id,
      "name" => request.name,
      "alias" => request.env_alias,
      "status" => request.status,
      "connector_run_id" => request.connector_run_id,
      "failure_code" => request.failure_code,
      "failure_message" => request.failure_message,
      "progress" => request.progress || %{},
      "runner" => public_request_runner(request),
      "stoppable" =>
        request.status in ~w(preflight_complete starting_connector waiting_for_attach connected failed stopped),
      "created_at" => iso8601_or_nil(request.created_at),
      "updated_at" => iso8601_or_nil(request.updated_at)
    }
  end

  defp public_request_runner(%{provisioner: %MacMiniProvisioner{} = runner}) do
    %{
      "id" => runner.id,
      "stable_id" => runner.stable_id,
      "name" => runner.name,
      "status" => runner.status,
      "effective_status" => runner.effective_status || runner.status
    }
  end

  defp public_request_runner(%{provisioner_id: provisioner_id}) do
    %{"id" => provisioner_id}
  end

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

  defp device_summary(devices, requests) do
    %{
      "device_count" => length(devices),
      "connected_count" => Enum.count(devices, &(&1["status"] == "connected")),
      "device_request_count" => length(requests),
      "active_request_count" =>
        Enum.count(
          requests,
          &(Map.get(&1, "status") in ~w(pending preflight preflight_complete starting_connector waiting_for_attach stop_requested stopping))
        )
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

  defp devices_next_action(org, project, devices, requests) do
    cond do
      devices != [] ->
        "Use `bft agents list --org #{org.slug} --project #{project.slug}` to inspect external agent runtime status."

      Enum.any?(
        requests,
        &(Map.get(&1, "status") in ~w(pending preflight preflight_complete starting_connector waiting_for_attach))
      ) ->
        "Wait for the selected runner to attach the connector, then list project devices again."

      true ->
        "List runners, then create a project device from the selected runner."
    end
  end

  defp request_audit_opts(conn) do
    user = ProjectScope.current_user(conn)

    [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: List.first(get_req_header(conn, "x-request-id")) || Ecto.UUID.generate()
    ]
  end

  defp actor_label(user) do
    cond do
      present?(Map.get(user, :email)) -> String.trim(user.email)
      present?(Map.get(user, :name)) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(safe_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(_), do: nil

  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
