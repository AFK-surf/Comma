defmodule BridgeForTeamsWeb.ProjectAPIResponse do
  @moduledoc """
  Shared JSON shapes for authenticated project-scoped HTTP APIs.

  Business logic stays in BridgeForTeams contexts. This module only keeps
  response projection, redaction, and backend-error mapping consistent across
  CLI transport endpoints and project resource endpoints.
  """

  alias BridgeForTeams.Schema.{Agent, Organization, Project}
  alias BridgeForTeamsWeb.{JSON, ResponseSanitizer}

  @public_external_runtime_config_keys ~w(
    binding_revision
    kind
    owner_scope
    provider
    device_id
    runtime_id
    device_runtime_id
    model
    model_provider
    reasoning_effort
    runtime_spec
    workload_id
  )

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

  def public_agent(%Agent{} = agent, environments \\ []) do
    salix_agent = agent.salix
    runtime_config = normalize_map(salix_agent["runtime_config"])
    vm = normalize_map(agent.salix["vm"])

    %{
      "id" => agent.id,
      "salix_agent_id" => agent.salix_agent_id,
      "name" => agent.salix["name"],
      "role" => agent.role,
      "status" => BridgeForTeams.Schema.Agent.lifecycle(agent),
      "runtime_config" => public_runtime_config(runtime_config),
      "runtime" => public_agent_runtime(runtime_config, environments),
      "provisioned" => is_nil(agent.provisioning) and salix_agent != %{},
      "vm" => public_vm(vm),
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

  defp public_runtime_config(config) do
    config
    |> Map.take(@public_external_runtime_config_keys)
    |> drop_nil_values()
    |> empty_to_nil()
  end

  defp public_vm(config) do
    config
    |> Map.take(~w(enabled provider))
    |> drop_nil_values()
    |> empty_to_nil()
  end

  defp public_agent_runtime(%{"kind" => "internal"}, _environments), do: %{"kind" => "internal"}

  defp public_agent_runtime(%{"kind" => "external"} = config, environments),
    do: public_connected_runtime(config, environments)

  defp public_agent_runtime(%{"kind" => "connected_runtime"} = config, environments),
    do: public_connected_runtime(config, environments)

  defp public_agent_runtime(config, _environments) do
    %{"kind" => nonblank(config["kind"], "unknown"), "status" => "unknown"}
  end

  defp public_connected_runtime(config, environments) do
    device_id = trim(config["device_id"])
    device_runtime_id = trim(config["device_runtime_id"])

    environment = current_device_environment(environments, device_id)

    runtime = environment && find_agent_runtime(environment, device_runtime_id)

    %{
      "kind" => config["kind"],
      "provider" => config["provider"],
      "device_id" => device_id,
      "runtime_id" => trim(config["runtime_id"]),
      "device_runtime_id" => device_runtime_id,
      "connector_run_id" => environment && map_value(environment, "connector_run_id"),
      "device_name" => device_name(environment),
      "device_status" => environment && nonblank(map_value(environment, "status"), "unknown"),
      "status" => external_runtime_status(environment, runtime),
      "issue" => runtime && map_value(runtime, "issue"),
      "runtime_status" => runtime && map_value(runtime, "status"),
      "version" => runtime && map_value(runtime, "version"),
      "model" => runtime && map_value(runtime, "model"),
      "model_provider" => runtime && map_value(runtime, "model_provider"),
      "reasoning_effort" => runtime && map_value(runtime, "reasoning_effort"),
      "readiness_checked_at" => runtime && map_value(runtime, "readiness_checked_at")
    }
    |> drop_nil_values()
  end

  defp find_agent_runtime(environment, device_runtime_id) do
    environment
    |> device_runtimes()
    |> Enum.find(&(trim(map_value(&1, "device_runtime_id")) == device_runtime_id))
  end

  defp current_device_environment(_environments, ""), do: nil

  defp current_device_environment(environments, device_id) do
    environments
    |> Enum.filter(&(trim(map_value(&1, "device_id")) == device_id))
    |> Enum.max_by(&environment_sort_key/1, fn -> nil end)
  end

  defp environment_sort_key(environment) do
    connected = if map_value(environment, "status") == "connected", do: 1, else: 0

    {connected,
     integer(map_value(environment, "updated_at") || map_value(environment, "connected_at"))}
  end

  defp device_runtimes(environment) do
    case map_value(environment, "device_runtimes") do
      runtimes when is_list(runtimes) ->
        runtimes
        |> Enum.filter(&is_map/1)
        |> Enum.map(&normalize_map/1)

      _other ->
        []
    end
  end

  defp external_runtime_status(nil, _runtime), do: "missing"

  defp external_runtime_status(_environment, nil), do: "missing"

  defp external_runtime_status(_environment, runtime) do
    case map_value(runtime, "status") do
      status when status in ~w(ready unavailable stale disconnected missing unknown) -> status
      _other -> "unknown"
    end
  end

  defp device_name(nil), do: nil

  defp device_name(environment) do
    meta = normalize_map(map_value(environment, "meta"))
    nonblank(meta["name"] || map_value(environment, "name"), nil)
  end

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

  defp connect_field(map, key) when is_map(map), do: map_value(map, key)
  defp connect_field(_map, _key), do: nil

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)

  defp map_value(_map, _key), do: nil

  defp nonblank(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonblank(value, fallback), do: value || fallback

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> 0
    end
  end

  defp integer(_value), do: 0

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
             :target_not_found
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
             :binding_revision_conflict,
             :selection_changed
           ],
      do: 409

  def error_status(reason)
      when reason in [
             :connect_rejected,
             :unsupported_provider,
             :unsupported_action,
             :invalid_inbound_agent,
             :runtime_required,
             :runtime_ambiguous,
             :agent_ambiguous,
             :agent_not_in_project,
             :use_runtime_rebind,
             :unsupported_agent_role,
             :unsupported_runtime_binding,
             :provider_unsupported,
             :target_required,
             :invalid_external_target,
             :invalid_expected_binding_revision,
             :raw_runtime_config_forbidden
           ],
      do: 400

  def error_status(reason) when reason in [:runtime_not_found], do: 404

  def error_status(:use_template_catalog), do: 400
  def error_status({:bad_request, _}), do: 400
  def error_status({:missing_credentials, _}), do: 400
  def error_status({:missing_bot_secret, _}), do: 400
  def error_status({:sso_provider_conflict, _}), do: 409
  def error_status({:target_unavailable, _}), do: 409
  def error_status(_reason), do: 500

  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_code({:missing_credentials, _}), do: "missing_credentials"
  def error_code({:missing_bot_secret, _}), do: "missing_bot_secret"
  def error_code({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  def error_code(_reason), do: "backend_error"
end
