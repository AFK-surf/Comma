defmodule BridgeForTeamsWeb.MacMiniProvisionerController do
  @moduledoc """
  Org-scoped runner API.

  These endpoints are called by the host-side runner process with an org API
  key. User-facing dashboard flows create device requests elsewhere; this
  controller lets a runner register, heartbeat, claim one pending request,
  and report non-secret lifecycle status back.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  require Logger

  import BridgeForTeamsWeb.JSON

  alias BridgeForTeams.{Compute, Environments}
  alias BridgeForTeamsWeb.MacMiniRelease

  @write_scopes [
    "*",
    "runners:*",
    "runners:write"
  ]

  @doc "POST /v1/orgs/:org_id/runners"
  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, %{"org_id" => org_id} = params) do
    with :ok <- authorize_provisioner_api(conn, org_id, params["stable_id"]),
         {:ok, provisioner} <-
           Environments.register_mac_mini_provisioner(
             org_id,
             provisioner_attrs(params),
             request_opts(conn)
           ) do
      send_json(conn, %{"runner" => render_provisioner(provisioner)}, 201)
    else
      {:error, :forbidden} -> send_error(conn, :forbidden, 403)
      {:error, :not_found} -> send_error(conn, :not_found, 404)
      {:error, %Ecto.Changeset{} = changeset} -> send_error(conn, changeset, 422)
      {:error, reason} -> send_error(conn, reason, 400)
    end
  end

  @doc "POST /v1/orgs/:org_id/runners/:provisioner_id/heartbeat"
  @spec heartbeat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def heartbeat(conn, %{"org_id" => org_id, "provisioner_id" => provisioner_id} = params) do
    with :ok <- authorize_provisioner_api(conn, org_id, provisioner_id),
         {:ok, provisioner} <-
           Environments.heartbeat_mac_mini_provisioner(
             org_id,
             provisioner_id,
             provisioner_attrs(params),
             request_opts(conn)
           ),
         {:ok, install_failure_acks} <-
           Compute.report_agent_vmm_install_failures(
             provisioner,
             Map.get(params, "agent_vmm_install_failures", [])
           ) do
      response = %{
        "agent_vmm_install_failure_acks" => install_failure_acks,
        "runner" => render_provisioner(provisioner),
        "updates" => MacMiniRelease.updates(conn, provisioner)
      }

      response =
        case Compute.agent_vmm_control_page(
               provisioner,
               Map.get(params, "agent_vmm_control_cursor")
             ) do
          {:ok, page} -> Map.put(response, "agent_vmm_controls", render_control_page(page))
          {:error, _reason} -> response
        end

      response =
        case Compute.deliver_agent_vmm_install(provisioner) do
          {:ok, descriptor} ->
            Map.put(response, "agent_vmm_install", render_install_descriptor(conn, descriptor))

          {:error, :no_pending_operation} ->
            response

          {:error, _reason} ->
            response
        end

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_json(response)
    else
      {:error, :forbidden} -> send_error(conn, :forbidden, 403)
      {:error, :provisioner_not_found} -> send_error(conn, :provisioner_not_found, 404)
      {:error, %Ecto.Changeset{} = changeset} -> send_error(conn, changeset, 422)
      {:error, reason} -> send_error(conn, reason, 400)
    end
  end

  @doc "POST /v1/orgs/:org_id/runners/:provisioner_id/claim"
  @spec claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim(conn, %{"org_id" => org_id, "provisioner_id" => provisioner_id} = params) do
    with :ok <- authorize_provisioner_api(conn, org_id, provisioner_id),
         {:ok, %{action: action, request: request, connect: connect, launch: launch}} <-
           Environments.claim_device_provision_request(
             org_id,
             provisioner_id,
             put_request_id(params, conn)
           ) do
      send_json(
        conn,
        render_claim(%{action: action, request: request, connect: connect, launch: launch})
      )
    else
      {:error, :no_pending_request} ->
        send_resp(conn, 204, "")

      {:error, :forbidden} ->
        send_error(conn, :forbidden, 403)

      {:error, :provisioner_not_found} ->
        send_error(conn, :provisioner_not_found, 404)

      {:error, :provisioner_offline} ->
        send_error(conn, :provisioner_offline, 409)

      {:error, :device_connection_create_failed} ->
        send_error(conn, :device_connection_failed, 502)

      {:error, :token_mint_failed} ->
        send_error(conn, :device_connection_failed, 502)

      {:error, reason} ->
        send_error(conn, reason, 400)
    end
  end

  @doc """
  POST /v1/orgs/:org_id/runners/:provisioner_id/provision-requests/:request_id/status
  """
  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(
        conn,
        %{
          "org_id" => org_id,
          "provisioner_id" => provisioner_id,
          "request_id" => request_id
        } = params
      ) do
    attrs = Map.take(params, ["failure_code", "failure_message", "connector_run_id", "progress"])

    with :ok <- authorize_provisioner_api(conn, org_id, provisioner_id),
         {:ok, status} <- fetch_nonblank(params, "status"),
         {:ok, request} <-
           Environments.update_device_provision_request_from_provisioner(
             org_id,
             provisioner_id,
             request_id,
             status,
             attrs,
             request_opts(conn)
           ) do
      send_json(conn, %{"provision_request" => render_provision_request(request)})
    else
      {:error, :missing_status} ->
        send_error(conn, :missing_status, 422)

      {:error, :forbidden} ->
        send_error(conn, :forbidden, 403)

      {:error, :provision_request_not_found} ->
        send_error(conn, :provision_request_not_found, 404)

      {:error, :not_found} ->
        send_error(conn, :provision_request_not_found, 404)

      {:error, :unsupported_provisioner_status} ->
        send_error(conn, :unsupported_provisioner_status, 422)

      {:error, :invalid_provisioner_status_transition} ->
        send_error(conn, :invalid_provisioner_status_transition, 409)

      {:error, %Ecto.Changeset{} = changeset} ->
        send_error(conn, changeset, 422)

      {:error, reason} ->
        send_error(conn, reason, 400)
    end
  end

  @doc """
  GET /v1/orgs/:org_id/runners/:provisioner_id/provision-requests/:request_id
  """
  @spec show_request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_request(
        conn,
        %{
          "org_id" => org_id,
          "provisioner_id" => provisioner_id,
          "request_id" => request_id
        }
      ) do
    with :ok <- authorize_provisioner_api(conn, org_id, provisioner_id),
         {:ok, request} <-
           Environments.get_device_provision_request_for_provisioner(
             org_id,
             provisioner_id,
             request_id
           ) do
      send_json(conn, %{"provision_request" => render_provision_request(request)})
    else
      {:error, :forbidden} ->
        send_error(conn, :forbidden, 403)

      {:error, :provision_request_not_found} ->
        send_error(conn, :provision_request_not_found, 404)

      {:error, :not_found} ->
        send_error(conn, :provision_request_not_found, 404)
    end
  end

  defp authorize_provisioner_api(conn, org_id, runner_ref) do
    with true <- conn.assigns[:current_org] == org_id,
         true <- Enum.any?(conn.assigns[:auth_scopes] || [], &(&1 in @write_scopes)),
         :ok <- authorize_bound_runner(conn.assigns[:auth_runner_stable_id], runner_ref) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  # Installer-minted keys are capabilities for one stable runner. Unbound
  # legacy/admin org keys retain their explicitly org-scoped authority.
  defp authorize_bound_runner(nil, _runner_ref), do: :ok
  defp authorize_bound_runner(stable_id, stable_id), do: :ok

  defp authorize_bound_runner(stable_id, provisioner_id)
       when is_binary(stable_id) and is_binary(provisioner_id) do
    case Environments.get_mac_mini_provisioner(provisioner_id) do
      {:ok, %{stable_id: ^stable_id}} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp request_opts(conn) do
    %{"request_id" => request_id(conn)}
  end

  defp put_request_id(params, conn) do
    Map.put(params, "request_id", request_id(conn))
  end

  defp request_id(conn) do
    body_params = conn.body_params || %{}

    cond do
      is_binary(body_params["request_id"]) and body_params["request_id"] != "" ->
        body_params["request_id"]

      true ->
        case get_req_header(conn, "x-request-id") do
          [request_id | _] when is_binary(request_id) and request_id != "" ->
            request_id

          _ ->
            case Logger.metadata()[:request_id] do
              value when is_binary(value) and value != "" -> value
              _ -> Ecto.UUID.generate()
            end
        end
    end
  end

  defp provisioner_attrs(params) do
    Map.take(params || %{}, [
      "stable_id",
      "name",
      "status",
      "host_identity",
      "os_summary",
      "version",
      "capabilities",
      "capacity",
      "current_connector_count"
    ])
  end

  defp render_provisioner(provisioner) do
    %{
      "id" => provisioner.id,
      "org_id" => provisioner.org_id,
      "stable_id" => provisioner.stable_id,
      "name" => provisioner.name,
      "status" => provisioner.status,
      "host_identity" => provisioner.host_identity,
      "os_summary" => provisioner.os_summary,
      "version" => provisioner.version,
      "capabilities" => provisioner.capabilities || %{},
      "capacity" => provisioner.capacity,
      "current_connector_count" => provisioner.current_connector_count,
      "last_seen_at" => provisioner.last_seen_at,
      "created_at" => provisioner.created_at,
      "updated_at" => provisioner.updated_at
    }
  end

  defp render_install_descriptor(_conn, descriptor) do
    %{
      "version" => 1,
      "operation_id" => descriptor.operation.id,
      "exchange_url" => install_operation_exchange_url(),
      "one_time_secret" => descriptor.one_time_secret,
      "expires_at" => DateTime.to_iso8601(descriptor.expires_at)
    }
  end

  defp install_operation_exchange_url do
    uri = :salix_web |> Application.fetch_env!(:public_base_url) |> URI.parse()

    %URI{
      uri
      | path: "/v1/compute/agent-vmm/install-operations/exchange",
        query: nil,
        fragment: nil
    }
    |> URI.to_string()
  end

  defp render_control_page(page) do
    %{
      "version" => 1,
      "items" =>
        Enum.map(page.controls, fn control ->
          %{
            "operation_id" => control.operation_id,
            "registration_id" => control.registration_id,
            "registration_revision" => control.registration_revision,
            "state" => control.state
          }
        end),
      "next_cursor" => page.next_cursor
    }
  end

  defp render_provision_request(request) do
    %{
      "id" => request.id,
      "org_id" => request.org_id,
      "project_id" => request.project_id,
      "provisioner_id" => request.provisioner_id,
      "name" => request.name,
      "alias" => request.env_alias,
      "status" => request.status,
      "failure_code" => request.failure_code,
      "failure_message" => request.failure_message,
      "connector_run_id" => request.connector_run_id,
      "spec" => render_request_spec(request.spec),
      "progress" => request.progress || %{},
      "created_at" => request.created_at,
      "updated_at" => request.updated_at
    }
  end

  defp render_claim(%{action: action, request: request, connect: connect, launch: launch}) do
    %{
      "action" => action,
      "device_request" => render_provision_request(request),
      "connect" => render_connect(connect),
      "launch" => launch
    }
  end

  defp render_request_spec(spec) when is_map(spec), do: Map.drop(spec, ["salix_group_id"])
  defp render_request_spec(_spec), do: %{}

  defp render_connect(connect) do
    Map.take(connect || %{}, [
      "token",
      "server",
      "connect_url",
      "env",
      "name",
      "alias"
    ])
  end

  defp fetch_nonblank(params, key) do
    case params[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_status}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_status}
    end
  end
end
