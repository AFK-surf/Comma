defmodule BridgeForTeamsWeb.ProjectAPIResponse do
  @moduledoc """
  Shared JSON shapes for authenticated project-scoped HTTP APIs.

  Business logic stays in BridgeForTeams contexts. This module only keeps
  response projection, redaction, and backend-error mapping consistent across
  CLI transport endpoints and project resource endpoints.
  """

  alias BridgeForTeams.Schema.{Agent, Organization, Project}
  alias BridgeForTeamsWeb.{JSON, ResponseSanitizer}

  def public_org(%Organization{} = org) do
    %{
      "id" => org.id,
      "slug" => org.slug,
      "name" => org.name,
      "status" => org.status,
      "salix_tenant_id" => org.salix_tenant_id
    }
  end

  def public_project(%Project{} = project) do
    %{
      "id" => project.id,
      "slug" => project.slug,
      "name" => project.name,
      "status" => project.status
    }
  end

  def public_agent(%Agent{} = agent) do
    salix_agent = agent.salix

    %{
      "id" => agent.id,
      "salix_agent_id" => agent.salix_agent_id,
      "name" => agent.salix["name"],
      "role" => agent.role,
      "status" => BridgeForTeams.Schema.Agent.lifecycle(agent),
      "runtime" => public_agent_runtime(salix_agent),
      "station_binding" => normalize_map(salix_agent["station_binding"]) |> empty_to_nil(),
      "provisioned" => is_nil(agent.provisioning) and salix_agent != %{},
      "created_at" => timestamp(agent.created_at),
      "updated_at" => timestamp(agent.updated_at)
    }
    |> drop_nil_values()
  end

  def public_connect(nil), do: nil

  def public_connect(connect) when is_map(connect) do
    connect
    |> sanitize()
    |> put_slack_install_status(connect)
  end

  def public_connect(connect), do: sanitize(connect)

  def send_ok(conn, data, status \\ 200) do
    JSON.send_json(conn, %{"ok" => true, "data" => sanitize(data)}, status)
  end

  def send_cli_error(conn, {:error, status, code, message, details}) do
    send_error(conn, status, code, message, details)
  end

  def send_cli_error(conn, reason) do
    send_backend_error(conn, reason, "BFT CLI API request failed.")
  end

  def send_project_error(conn, {:error, status, code, message, details}, _fallback_message) do
    send_error(conn, status, code, message, details)
  end

  def send_project_error(conn, {:error, reason}, fallback_message),
    do: send_backend_error(conn, reason, fallback_message)

  def send_project_error(conn, reason, fallback_message),
    do: send_backend_error(conn, reason, fallback_message)

  def send_backend_error(conn, reason, message) do
    send_error(conn, error_status(reason), error_code(reason), message, %{
      "reason" => safe_reason(reason)
    })
  end

  def send_error(conn, status, code, message, details) do
    JSON.send_json(
      conn,
      %{
        "ok" => false,
        "error" => %{
          "code" => code,
          "message" => message,
          "details" => sanitize(details)
        }
      },
      status
    )
  end

  def safe_reason(reason), do: sanitize(reason)

  def sanitize(value), do: ResponseSanitizer.sanitize(value)

  def sanitize_url(value), do: ResponseSanitizer.sanitize_url(value)

  # A Worker bound to a station runs its Tasks there; every other Agent is internal.
  defp public_agent_runtime(%{"station_binding" => %{"runs_on" => %{} = runs_on} = binding}) do
    %{
      "kind" => "station",
      "runs_on" => runs_on,
      "provider" => get_in(binding, ["model", "provider"]),
      "model" => get_in(binding, ["model", "model"])
    }
    |> drop_nil_values()
  end

  defp public_agent_runtime(_record), do: %{"kind" => "internal"}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map(_), do: %{}

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp timestamp(value), do: value

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp put_slack_install_status(public, connect) do
    if connect_field(connect, "provider") == "slack" do
      Map.put(public, "install_status", slack_install_status(connect))
    else
      public
    end
  end

  defp slack_install_status(connect) do
    cond do
      present?(connect_field(connect, "disabled_at")) ->
        "disabled"

      present?(connect_field(connect, "oauth_completed_at")) or
          present?(connect_field(connect, "workspace_id")) ->
        "installed"

      present?(connect_field(connect, "oauth_url")) ->
        "pending_oauth"

      true ->
        "unknown"
    end
  end

  defp connect_field(map, key) when is_map(map), do: Map.get(map, key)
  defp connect_field(_map, _key), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: value not in [nil, false]

  def error_status(reason)
      when reason in [
             :unavailable,
             :timeout,
             :read_unavailable,
             :audit_unavailable,
             :mutation_outcome_unknown,
             :group_not_ready,
             :agent_provisioning,
             :agent_configuration_transfer_in_progress,
             :agent_configuration_transfer_required,
             :agent_configuration_rollout_pending
           ],
      do: 503

  def error_status(reason)
      when reason in [
             :not_found,
             :connect_not_found,
             :org_not_found,
             :project_not_found,
             :station_not_found
           ],
      do: 404

  def error_status(reason)
      when reason in [
             :provider_app_in_use,
             :runtime_unavailable,
             :not_provisioned,
             :agent_role_immutable
           ],
      do: 409

  def error_status(reason)
      when reason in [
             :stale_binding_revision,
             :binding_conflict,
             :binding_revision_conflict
           ],
      do: 409

  def error_status(reason)
      when reason in [
             :connect_rejected,
             :feishu_app_mismatch,
             :feishu_app_secret_missing,
             :unsupported_provider,
             :unsupported_action,
             :invalid_inbound_agent,
             :runtime_required,
             :agent_ambiguous,
             :agent_not_in_project,
             :use_runtime_rebind,
             :unsupported_agent_role,
             :unsupported_runtime_binding,
             :invalid_station_target,
             :external_runtime_retired,
             :station_required,
             :device_needs_station,
             :station_outdated,
             :cloud_vm_disabled,
             :invalid_runtime_model,
             :invalid_expected_binding_revision,
             :raw_runtime_config_forbidden
           ],
      do: 400

  def error_status(:workers_retired), do: 410
  def error_status(:model_not_allowed), do: 422
  def error_status(:use_model_choice), do: 400
  def error_status({:bad_request, _}), do: 400
  def error_status({:missing_credentials, _}), do: 400
  def error_status({:missing_bot_secret, _}), do: 400
  def error_status({:sso_provider_conflict, _}), do: 409
  def error_status(_reason), do: 500

  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_code({:missing_credentials, _}), do: "missing_credentials"
  def error_code({:missing_bot_secret, _}), do: "missing_bot_secret"
  def error_code({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  def error_code(_reason), do: "backend_error"
end
