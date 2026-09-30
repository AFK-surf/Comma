defmodule SalixMCP.Gateway do
  @moduledoc false

  alias SalixMCP.{Config, Connection, Credentials, RemoteOAuth, Store}

  @tool_call_timeout_ms 600_000

  def create_binding(tenant_id, group_id, attrs) do
    with {:ok, binding} <- Store.create_binding(tenant_id, group_id, attrs) do
      maybe_refresh_created_binding(tenant_id, group_id, binding)
    end
  end

  def refresh_binding(tenant_id, group_id, binding_id) do
    with {:ok, binding, definition, previous_connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id) do
      redactions = Config.redaction_values(definition, binding)

      do_refresh_binding(
        tenant_id,
        group_id,
        binding_id,
        binding,
        definition,
        previous_connection,
        redactions
      )
    end
  end

  defp do_refresh_binding(
         tenant_id,
         group_id,
         binding_id,
         binding,
         definition,
         previous_connection,
         redactions
       ) do
    with _ <- Connection.stop(binding),
         :ok <- enabled(binding),
         {:ok, _config} <- Config.resolve(definition, binding),
         {:ok, initialize_info} <- Connection.initialize(binding, definition),
         {:ok, discovered, discovery_errors} <-
           discover(binding, definition, initialize_info, redactions),
         discovered <-
           previous_connection
           |> stable_discovery(discovered, discovery_errors)
           |> redact_value(redactions),
         {:ok, connection} <-
           Store.put_connection(binding, %{
             "status" => discovery_status(discovery_errors),
             "last_error" => discovery_error_payload(discovery_errors),
             "protocol_version" => initialize_info["protocol_version"],
             "capabilities" => initialize_info["capabilities"] || %{},
             "server_info" => initialize_info["server_info"] || %{},
             "discovered" => discovered,
             "discovery_revision" => discovery_revision(discovered),
             "health_timestamp" => now()
           }) do
      {:ok, Store.public_connection(connection)}
    else
      {:error, {:missing_config, missing}} ->
        put_error(
          tenant_id,
          group_id,
          binding_id,
          "missing_config",
          %{"missing" => missing},
          redactions
        )

      {:error, {:missing_oauth, reason}} ->
        put_error(
          tenant_id,
          group_id,
          binding_id,
          "missing_oauth",
          %{
            "reason" => to_string(reason)
          },
          redactions
        )

      {:error, :disabled} ->
        put_error(tenant_id, group_id, binding_id, "disabled", %{}, redactions)

      {:error, reason} ->
        stop_connection_after_refresh_error(tenant_id, group_id, binding_id)
        maybe_mark_remote_oauth_reauthorization_required(reason, binding)

        put_error(
          tenant_id,
          group_id,
          binding_id,
          status_for_error(reason),
          error_payload(reason, redactions),
          redactions
        )
    end
  end

  def stop_binding(tenant_id, group_id, binding_id) do
    with {:ok, binding} <- Store.get_binding(tenant_id, group_id, binding_id) do
      _ = Connection.stop(binding)

      with {:ok, conn} <-
             Store.update_connection(
               binding["tenant_id"],
               binding["group_id"],
               binding["binding_id"],
               fn conn ->
                 conn
                 |> Map.put("binding_id", binding["binding_id"])
                 |> Map.put("tenant_id", binding["tenant_id"])
                 |> Map.put("group_id", binding["group_id"])
                 |> Map.put("mcp_id", binding["mcp_id"])
                 |> Map.put("placement", binding["placement"])
                 |> Map.put("device_runtime_id", binding["device_runtime_id"])
                 |> Map.put(
                   "status",
                   if(binding["enabled"] == false, do: "disabled", else: "stopped")
                 )
                 |> Map.put("last_error", nil)
               end
             ) do
        {:ok, Store.public_connection(conn)}
      end
    end
  end

  def update_binding(tenant_id, group_id, binding_id, attrs) do
    with {:ok, binding} <- Store.update_binding(tenant_id, group_id, binding_id, attrs) do
      _ = Connection.stop(binding)
      {:ok, binding}
    end
  end

  def delete_binding(tenant_id, group_id, binding_id) do
    case Store.get_binding(tenant_id, group_id, binding_id) do
      {:ok, binding} ->
        _ = Connection.stop(binding)
        Store.delete_binding(tenant_id, group_id, binding_id)

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
  end

  def set_binding_enabled(tenant_id, group_id, binding_id, enabled) do
    enabled? = enabled in [true, "true", 1, "1"]

    with {:ok, binding} <-
           update_binding(tenant_id, group_id, binding_id, %{"enabled" => enabled?}) do
      if enabled? do
        _ = refresh_binding(tenant_id, group_id, binding_id)

        case Store.get_binding(tenant_id, group_id, binding_id) do
          {:ok, rec} -> {:ok, Store.public_binding_with_connection(rec)}
          _ -> {:ok, binding}
        end
      else
        {:ok, binding}
      end
    end
  end

  def restart_binding(tenant_id, group_id, binding_id) do
    with {:ok, binding} <- Store.get_binding(tenant_id, group_id, binding_id) do
      _ = Connection.stop(binding)
      refresh_binding(tenant_id, group_id, binding_id)
    end
  end

  def call_tool(tenant_id, group_id, binding_id, tool_name, args, opts \\ []) do
    with {:ok, binding, definition, connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- enabled(binding),
         :ok <- require_connection_callable(tenant_id, group_id, binding_id, connection) do
      redactions = Config.redaction_values(definition, binding)

      case Connection.request(
             binding,
             definition,
             "tools/call",
             %{
               "name" => tool_name,
               "arguments" => args || %{}
             },
             @tool_call_timeout_ms,
             opts
           ) do
        {:ok, result} ->
          {:ok, normalize_tool_result(result, redactions)}

        {:error, {:mcp_error, error}} ->
          {:ok, mcp_tool_error(error, redactions)}

        {:error, :cancelled} ->
          {:ok,
           %{"status" => "cancelled", "content" => Jason.encode!(%{"status" => "cancelled"})}}

        {:error, reason} ->
          status = status_for_error(reason)
          payload = error_payload(reason, redactions)
          maybe_mark_remote_oauth_reauthorization_required(reason, binding)
          _ = put_error(tenant_id, group_id, binding_id, status, payload, redactions)
          {:ok, unavailable(status, unavailable_reason(payload))}
      end
    else
      {:error, :disabled} ->
        {:ok, unavailable("disabled", "MCP binding is disabled")}

      {:error, {:unavailable, status, reason}} ->
        {:ok, unavailable(status, reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_tool_call(tenant_id, group_id, binding_id, tool_call_id, reason) do
    with {:ok, binding, definition, _connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id) do
      Connection.cancel_request(binding, definition, tool_call_id, reason)
    else
      _ -> :ok
    end
  end

  def list_resources(tenant_id, group_id, binding_id) do
    with {:ok, binding, definition, connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- enabled(binding),
         :ok <- require_connection_callable(tenant_id, group_id, binding_id, connection) do
      redactions = Config.redaction_values(definition, binding)

      case Connection.request(binding, definition, "resources/list", %{}) do
        {:ok, result} -> {:ok, redact_value(result["resources"] || [], redactions)}
        {:error, reason} -> {:error, error_payload(reason, redactions)}
      end
    end
  end

  def read_resource(tenant_id, group_id, binding_id, uri) do
    with {:ok, binding, definition, connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- enabled(binding),
         :ok <- require_connection_callable(tenant_id, group_id, binding_id, connection) do
      redactions = Config.redaction_values(definition, binding)

      case Connection.request(binding, definition, "resources/read", %{"uri" => uri}) do
        {:ok, result} -> {:ok, redact_value(result, redactions)}
        {:error, reason} -> {:error, error_payload(reason, redactions)}
      end
    end
  end

  def list_prompts(tenant_id, group_id, binding_id) do
    with {:ok, binding, definition, connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- enabled(binding),
         :ok <- require_connection_callable(tenant_id, group_id, binding_id, connection) do
      redactions = Config.redaction_values(definition, binding)

      case Connection.request(binding, definition, "prompts/list", %{}) do
        {:ok, result} -> {:ok, redact_value(result["prompts"] || [], redactions)}
        {:error, reason} -> {:error, error_payload(reason, redactions)}
      end
    end
  end

  def get_prompt(tenant_id, group_id, binding_id, name, arguments) do
    with {:ok, binding, definition, connection} <-
           Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- enabled(binding),
         :ok <- require_connection_callable(tenant_id, group_id, binding_id, connection) do
      redactions = Config.redaction_values(definition, binding)

      case Connection.request(binding, definition, "prompts/get", %{
             "name" => name,
             "arguments" => arguments || %{}
           }) do
        {:ok, result} -> {:ok, redact_value(result, redactions)}
        {:error, reason} -> {:error, error_payload(reason, redactions)}
      end
    end
  end

  defp discover(binding, definition, initialize_info, redactions) do
    capabilities = initialize_info["capabilities"] || %{}

    {tools, tool_error} =
      request_discovery_list(capabilities, "tools", binding, definition, "tools/list", "tools")

    {resources, resource_error} =
      request_discovery_list(
        capabilities,
        "resources",
        binding,
        definition,
        "resources/list",
        "resources"
      )

    {prompts, prompt_error} =
      request_discovery_list(
        capabilities,
        "prompts",
        binding,
        definition,
        "prompts/list",
        "prompts"
      )

    Enum.each([tool_error, resource_error, prompt_error], fn reason ->
      maybe_mark_remote_oauth_reauthorization_required(reason, binding)
    end)

    errors =
      [
        discovery_error("tools", tool_error, redactions),
        discovery_error("resources", resource_error, redactions),
        discovery_error("prompts", prompt_error, redactions)
      ]
      |> Enum.reject(&is_nil/1)

    {:ok, %{"tools" => tools, "resources" => resources, "prompts" => prompts}, errors}
  end

  defp request_list(binding, definition, method, key) do
    case Connection.request(binding, definition, method, %{}) do
      {:ok, result} when is_map(result) -> {:ok, result[key] || []}
      {:ok, _result} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_discovery_list(capabilities, capability, binding, definition, method, key) do
    if discovery_capability_enabled?(capabilities, capability) do
      case request_list(binding, definition, method, key) do
        {:ok, list} -> {list, nil}
        {:error, reason} -> {[], reason}
      end
    else
      {[], nil}
    end
  end

  defp discovery_capability_enabled?(capabilities, capability)
       when is_map(capabilities) and map_size(capabilities) > 0 do
    case Map.get(capabilities, capability) do
      false -> false
      nil -> false
      _value -> true
    end
  end

  defp discovery_capability_enabled?(_capabilities, _capability), do: true

  defp discovery_error(_capability, nil, _redactions), do: nil

  defp discovery_error(capability, reason, redactions) do
    %{
      "capability" => capability,
      "status" => status_for_error(reason),
      "error" => error_payload(reason, redactions)
    }
  end

  defp discovery_error_payload([]), do: nil
  defp discovery_error_payload(errors), do: %{"discovery_errors" => errors}

  defp discovery_status([]), do: "running"

  defp discovery_status(errors) do
    statuses = Enum.map(errors, & &1["status"])

    cond do
      "reauthorization_required" in statuses -> "reauthorization_required"
      "authorization_pending" in statuses -> "authorization_pending"
      "not_authorized" in statuses -> "not_authorized"
      "auth_failed" in statuses -> "auth_failed"
      "missing_oauth_client" in statuses -> "missing_oauth_client"
      "missing_oauth" in statuses -> "missing_oauth"
      "disabled" in statuses -> "disabled"
      true -> "degraded"
    end
  end

  defp stable_discovery(_previous_connection, discovered, []), do: discovered

  defp stable_discovery(previous_connection, discovered, errors) do
    previous = previous_connection["discovered"] || %{}

    Enum.reduce(errors, discovered, fn %{"capability" => capability}, acc ->
      Map.put(acc, capability, previous[capability] || acc[capability] || [])
    end)
  end

  defp require_connection_callable(tenant_id, group_id, binding_id, connection) do
    case connection["status"] do
      "running" -> :ok
      "degraded" -> :ok
      _ -> refresh_then_check(tenant_id, group_id, binding_id)
    end
  end

  defp refresh_then_check(tenant_id, group_id, binding_id) do
    case refresh_binding(tenant_id, group_id, binding_id) do
      {:ok, %{"status" => status}} when status in ["running", "degraded"] ->
        :ok

      {:ok, %{"status" => status, "last_error" => reason}} ->
        {:error, {:unavailable, status, unavailable_reason(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_tool_result(result, redactions) when is_map(result) do
    cond do
      result["isError"] == true ->
        %{
          "status" => "error",
          "content" => result |> result_content() |> redact_values(redactions),
          "raw" => redact_value(result, redactions)
        }

      true ->
        %{
          "status" => "completed",
          "content" => result |> result_content() |> redact_values(redactions),
          "raw" => redact_value(result, redactions)
        }
    end
  end

  defp normalize_tool_result(result, redactions),
    do: %{
      "status" => "completed",
      "content" => result |> inspect() |> redact_values(redactions),
      "raw" => redact_value(result, redactions)
    }

  defp mcp_tool_error(error, redactions) when is_map(error) do
    safe_error = redact_value(error, redactions)

    %{
      "status" => "error",
      "content" => Jason.encode!(%{"mcp_error" => safe_error}),
      "raw" => %{"error" => safe_error}
    }
  end

  defp mcp_tool_error(error, redactions),
    do: mcp_tool_error(%{"message" => inspect(error)}, redactions)

  defp result_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&content_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp result_content(result), do: Jason.encode!(result)

  defp content_part(%{"type" => "text", "text" => text}), do: to_string(text)
  defp content_part(%{"text" => text}), do: to_string(text)
  defp content_part(part) when is_map(part), do: Jason.encode!(part)
  defp content_part(part), do: to_string(part)

  defp redact_value(value, redactions) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, redact_value(nested, redactions)} end)
  end

  defp redact_value(value, redactions) when is_list(value),
    do: Enum.map(value, &redact_value(&1, redactions))

  defp redact_value(value, redactions) when is_binary(value), do: redact_values(value, redactions)

  defp redact_value(value, redactions)
       when is_integer(value) or is_float(value) or is_boolean(value) do
    if to_string(value) in redactions, do: "[redacted]", else: value
  end

  defp redact_value(value, _redactions), do: value

  defp redact_values(value, redactions) when is_binary(value) do
    Enum.reduce(redactions, value, fn secret, acc ->
      secret = to_string(secret || "")

      if secret == "" do
        acc
      else
        String.replace(acc, secret, "[redacted]")
      end
    end)
  end

  defp redact_values(value, _redactions), do: value

  defp unavailable(status, reason) do
    %{"status" => status, "content" => Jason.encode!(%{"status" => status, "error" => reason})}
  end

  defp put_error(tenant_id, group_id, binding_id, status, error, redactions) do
    error = redact_value(error, redactions)

    with {:ok, binding} <- Store.get_binding(tenant_id, group_id, binding_id),
         {:ok, conn} <-
           Store.update_connection(
             binding["tenant_id"],
             binding["group_id"],
             binding["binding_id"],
             fn conn ->
               conn
               |> Map.put("binding_id", binding["binding_id"])
               |> Map.put("tenant_id", binding["tenant_id"])
               |> Map.put("group_id", binding["group_id"])
               |> Map.put("mcp_id", binding["mcp_id"])
               |> Map.put("placement", binding["placement"])
               |> Map.put("device_runtime_id", binding["device_runtime_id"])
               |> Map.put("status", status)
               |> Map.put("last_error", error)
               |> Map.put("health_timestamp", now())
             end
           ) do
      {:ok, Store.public_connection(conn)}
    end
  end

  defp stop_connection_after_refresh_error(tenant_id, group_id, binding_id) do
    with {:ok, binding} <- Store.get_binding(tenant_id, group_id, binding_id) do
      _ = Connection.stop(binding)
    end

    :ok
  end

  defp enabled(%{"enabled" => false}), do: {:error, :disabled}
  defp enabled(_binding), do: :ok

  defp maybe_mark_remote_oauth_reauthorization_required(nil, _binding), do: :ok

  defp maybe_mark_remote_oauth_reauthorization_required(reason, binding) do
    if RemoteOAuth.reauthorization_challenge?(reason) do
      _ =
        Credentials.mark_remote_oauth_reauthorization_required(
          binding,
          "remote MCP rejected OAuth token"
        )
    end

    :ok
  end

  defp status_for_error(reason) do
    cond do
      RemoteOAuth.reauthorization_challenge?(reason) ->
        "reauthorization_required"

      RemoteOAuth.oauth_challenge?(reason) ->
        "not_authorized"

      true ->
        status_for_non_oauth_error(reason)
    end
  end

  defp status_for_non_oauth_error({:not_runnable, _reason}), do: "not_runnable"
  defp status_for_non_oauth_error({:missing_root, _reason}), do: "missing_root"

  defp status_for_non_oauth_error({:device_runtime_required, _reason}), do: "device_offline"

  defp status_for_non_oauth_error({:device_runtime_not_found, _reason}), do: "device_offline"

  defp status_for_non_oauth_error({:device_runtime_unavailable, _reason}), do: "device_offline"

  defp status_for_non_oauth_error({:bad_request, message}) when is_binary(message),
    do: "not_runnable"

  defp status_for_non_oauth_error({:oauth_disabled, _reason}), do: "disabled"

  defp status_for_non_oauth_error({:reauthorization_required, _reason}),
    do: "reauthorization_required"

  defp status_for_non_oauth_error({:missing_oauth_client, _reason}), do: "missing_oauth_client"

  defp status_for_non_oauth_error({:http_error, status}) when status in [401, 403],
    do: "auth_failed"

  defp status_for_non_oauth_error({:http_error, status, _headers, _body})
       when status in [401, 403],
       do: "auth_failed"

  defp status_for_non_oauth_error({:http_error, _status}), do: "protocol_error"

  defp status_for_non_oauth_error({:http_error, _status, _headers, _body}),
    do: "protocol_error"

  defp status_for_non_oauth_error({:mcp_error, _error}), do: "protocol_error"
  defp status_for_non_oauth_error({:protocol_error, _reason}), do: "protocol_error"
  defp status_for_non_oauth_error({:request_failed, _reason}), do: "protocol_error"
  defp status_for_non_oauth_error({:missing_config, _missing}), do: "missing_config"
  defp status_for_non_oauth_error({:missing_oauth, _reason}), do: "missing_oauth"
  defp status_for_non_oauth_error(:disconnected), do: "device_offline"

  defp status_for_non_oauth_error(reason) when is_binary(reason) do
    reason = String.downcase(reason)

    cond do
      String.contains?(reason, "unauthorized") or String.contains?(reason, "forbidden") or
        String.contains?(reason, "http 401") or String.contains?(reason, "http 403") ->
        "auth_failed"

      true ->
        "process_failed"
    end
  end

  defp status_for_non_oauth_error(:timeout), do: "protocol_error"
  defp status_for_non_oauth_error(_reason), do: "process_failed"

  defp error_payload({tag, message})
       when tag in [
              :not_runnable,
              :missing_root,
              :device_runtime_required,
              :device_runtime_not_found,
              :device_runtime_unavailable,
              :oauth_disabled,
              :reauthorization_required,
              :missing_oauth_client
            ] and
              is_binary(message),
       do: %{"reason" => message}

  defp error_payload({:bad_request, message}) when is_binary(message), do: %{"reason" => message}
  defp error_payload({:http_error, status}), do: %{"http_status" => status}

  defp error_payload({:http_error, status, headers, body} = reason) do
    case SalixMCP.RemoteOAuth.challenge_from_http_error(reason) do
      nil ->
        %{"http_status" => status, "body_summary" => body_summary(body)}

      challenge ->
        %{"http_status" => status, "oauth" => challenge}
    end
    |> maybe_put_header_hint(headers)
  end

  defp error_payload({:mcp_error, error}) when is_map(error), do: %{"mcp_error" => error}
  defp error_payload({:mcp_error, error}), do: %{"mcp_error" => %{"message" => inspect(error)}}
  defp error_payload({:protocol_error, reason}), do: %{"reason" => to_string(reason)}
  defp error_payload({:request_failed, reason}), do: %{"reason" => to_string(reason)}
  defp error_payload(:timeout), do: %{"reason" => "timeout"}
  defp error_payload(reason) when is_binary(reason), do: %{"reason" => reason}
  defp error_payload(reason), do: %{"reason" => inspect(reason)}

  defp error_payload(reason, redactions),
    do: reason |> error_payload() |> redact_value(redactions)

  defp maybe_put_header_hint(payload, headers) do
    case SalixMCP.RemoteOAuth.header_values(headers, "www-authenticate") do
      [] -> payload
      values -> Map.put(payload, "www_authenticate", Enum.map(values, &String.slice(&1, 0, 512)))
    end
  end

  defp body_summary(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        decoded
        |> public_error_payload()
        |> Jason.encode!()
        |> String.slice(0, 512)

      _ ->
        "[omitted]"
    end
  end

  defp body_summary(body) when is_map(body),
    do: body |> public_error_payload() |> Jason.encode!() |> String.slice(0, 512)

  defp body_summary(_body), do: ""

  defp public_error_payload(map) when is_map(map) do
    map
    |> Map.new(fn {key, value} -> {to_string(key), public_error_payload(value)} end)
    |> Map.drop([
      "access_token",
      "refresh_token",
      "authorization_code",
      "code",
      "code_verifier",
      "client_secret",
      "registration_access_token"
    ])
  end

  defp public_error_payload(list) when is_list(list), do: Enum.map(list, &public_error_payload/1)
  defp public_error_payload(value), do: value

  defp unavailable_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp unavailable_reason(%{"http_status" => status}), do: "MCP HTTP #{status}"
  defp unavailable_reason(reason) when is_binary(reason), do: reason
  defp unavailable_reason(reason), do: inspect(reason)

  defp discovery_revision(discovered) do
    :crypto.hash(:sha256, Jason.encode!(discovered))
    |> Base.encode16(case: :lower)
  end

  defp now, do: System.system_time(:second)

  defp maybe_refresh_created_binding(
         _tenant_id,
         _group_id,
         %{"binding_id" => _binding_id, "enabled" => false} = binding
       ),
       do: {:ok, binding}

  defp maybe_refresh_created_binding(tenant_id, group_id, %{"binding_id" => binding_id} = binding) do
    _ = refresh_binding(tenant_id, group_id, binding_id)

    case Store.get_binding(tenant_id, group_id, binding_id) do
      {:ok, rec} -> {:ok, Store.public_binding_with_connection(rec)}
      _ -> {:ok, binding}
    end
  end
end
