defmodule BridgeForTeamsWeb.MacMiniProvisionerController do
  @moduledoc """
  Org-scoped runner API.

  These endpoints are called by the host-side runner process with an org API
  key: a runner registers and heartbeats, and the heartbeat answers with its
  Agent VMM installs, controls and updates.
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
             Map.get(params, "agent_vmm_registration_failures", [])
           ) do
      response = %{
        "agent_vmm_registration_failure_acks" => install_failure_acks,
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
            Map.put(
              response,
              "agent_vmm_registration",
              render_install_descriptor(conn, descriptor)
            )

          {:error, :no_pending_registration} ->
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
              _ -> SystemsRuntime.Proc.uuid()
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
      "capabilities"
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
      "last_seen_at" => provisioner.last_seen_at,
      "created_at" => provisioner.created_at,
      "updated_at" => provisioner.updated_at
    }
  end

  defp render_install_descriptor(_conn, descriptor) do
    %{
      "version" => 1,
      "registration_id" => descriptor.registration.id,
      "request_id" => descriptor.registration.client_request_id,
      "claim_url" => install_operation_exchange_url(),
      "ticket" => descriptor.ticket,
      "expires_at" => DateTime.to_iso8601(descriptor.expires_at)
    }
  end

  defp install_operation_exchange_url do
    uri = :salix_web |> SystemsRuntime.fetch_env!(:public_base_url) |> URI.parse()

    %URI{
      uri
      | path: "/v1/compute/agent-vmm/registrations/claim",
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
            "registration_id" => control.registration_id,
            "registration_revision" => control.registration_revision,
            "state" => control.state
          }
        end),
      "next_cursor" => page.next_cursor
    }
  end
end
