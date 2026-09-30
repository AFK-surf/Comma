defmodule SalixWeb.RuntimeProxy do
  @moduledoc """
  Connector-originated runtime capability gateway.

  `salix-connect` exposes a loopback URL to a hosted external runtime. Calls to
  that local URL arrive here as `runtime_proxy` connector frames. The connector
  only forwards bytes; this module validates the server-issued capability token,
  resolves the bound Salix agent/session, and then either returns the current
  tool policy or executes one allowed tool through the external runtime gateway.
  """

  alias SalixAgent.ExternalAgentRuntime

  # This preserves the direct HTTP tool-call fast path without putting the
  # wait back in a session or role actor. The connector request task may wait
  # for the exact admitted call for the legacy synchronous window; a user-owned
  # dependency which outlives that finite budget remains an async call.
  @default_tool_terminal_wait_ms 3_000
  @tool_terminal_poll_ms 25

  def handle(connector_run_id, params, meta \\ %{})

  def handle(connector_run_id, params, meta) when is_map(params) do
    result =
      with {:ok, capability} <-
             ExternalAgentRuntime.validate_runtime_capability(params["capability_token"]),
           :ok <-
             ExternalAgentRuntime.validate_runtime_capability_scope(
               capability,
               connector_run_id,
               meta
             ) do
        dispatch(params, capability)
      end

    {:ok, response_for(result)}
  end

  def handle(_connector_run_id, _params, _meta),
    do: {:ok, json_response(400, %{"error" => "invalid runtime proxy request"})}

  defp dispatch(params, capability) do
    method = params |> string_param("method") |> String.upcase()
    path = params |> string_param("route_path") |> URI.decode()

    case {method, split_path(path)} do
      {"GET", ["tools"]} ->
        with {:ok, tools} <- ExternalAgentRuntime.runtime_capability_tools(capability) do
          {:ok, json_response(200, %{"tools" => tools})}
        end

      {"POST", ["tool", tool_name]} ->
        with {:ok, body} <- decode_json_body(params),
             {:ok, result} <-
               ExternalAgentRuntime.execute_runtime_capability_tool(capability, tool_name, body),
             {:ok, result} <- await_tool_terminal(capability, result) do
          {:ok, tool_response(result)}
        end

      {"POST", ["llm", "chat"]} ->
        handle_llm_chat(capability, params)

      {_method, ["tool", _tool_name]} ->
        {:ok, json_response(405, %{"error" => "method not allowed"})}

      _ ->
        {:ok, json_response(404, %{"error" => "not found"})}
    end
  end

  defp handle_llm_chat(capability, params) do
    with :ok <- capability_llm_allowed?(capability),
         {:ok, body} <- decode_json_body(params),
         {:ok, llm} when is_map(llm) <- SalixWeb.LLMProxy.resolve_llm(capability["agent_id"]) do
      opts = %{
        entrypoint: "connector_llm",
        actor_type: "connector",
        skip_metering: Application.get_env(:salix_web, :connector_llm_skip_metering, false)
      }

      case SalixWeb.LLMProxy.complete(capability["agent_id"], llm, body, opts) do
        {:ok, resp} ->
          {:ok, json_response(200, resp)}

        {:error, {:billing_unavailable, _decision}} ->
          {:ok, json_response(402, %{"error" => "billing unavailable"})}

        {:error, reason} ->
          {:ok, json_response(502, %{"error" => format_llm_error(reason)})}
      end
    else
      {:error, :llm_not_allowed} ->
        {:ok, json_response(403, %{"error" => "llm not permitted for this capability"})}

      {:ok, nil} ->
        {:ok, json_response(503, %{"error" => "no llm configured"})}

      {:error, _} = err ->
        err
    end
  end

  defp capability_llm_allowed?(capability) do
    scopes = capability["scopes"] || capability["scope"] || []

    if capability["llm_allowed"] == true or "llm" in List.wrap(scopes) do
      :ok
    else
      {:error, :llm_not_allowed}
    end
  end

  defp format_llm_error(reason) when is_binary(reason), do: reason
  defp format_llm_error(reason), do: inspect(reason)

  defp response_for({:ok, response}), do: response
  defp response_for({:error, :unauthorized}), do: json_response(401, %{"error" => "unauthorized"})

  defp response_for({:error, :stale_connector_transport_generation}),
    do: json_response(401, %{"error" => "unauthorized"})

  defp response_for({:error, :busy}), do: json_response(409, %{"error" => "agent is busy"})
  defp response_for({:error, :not_found}), do: json_response(404, %{"error" => "not found"})

  defp response_for({:error, {:bad_request, message}}),
    do: json_response(400, %{"error" => message})

  defp response_for({:error, reason}), do: json_response(500, %{"error" => inspect(reason)})

  defp decode_json_body(params) do
    raw =
      params
      |> string_param("body_base64")
      |> Base.decode64()

    case raw do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _} -> {:error, {:bad_request, "request body must be a JSON object"}}
          {:error, _} -> {:error, {:bad_request, "request body must be valid JSON"}}
        end

      :error ->
        {:error, {:bad_request, "body_base64 must be valid base64"}}
    end
  end

  defp await_tool_terminal(capability, result) do
    if result_value(result, "status") == "async_running" do
      deadline = System.monotonic_time(:millisecond) + tool_terminal_wait_ms()
      poll_tool_terminal(capability, result, deadline)
    else
      {:ok, result}
    end
  end

  defp poll_tool_terminal(capability, initial_result, deadline) do
    agent_id = capability["agent_id"]
    session_id = capability["session_id"]
    tool_call_id = result_value(initial_result, "id")

    case ExternalAgentRuntime.get_async_tool_call(agent_id, session_id, tool_call_id) do
      {:ok, %{"status" => status, "result" => result}}
      when status in ["completed", "failed"] and is_map(result) ->
        {:ok, result}

      {:ok, %{"status" => "cancelled"}} ->
        {:ok, initial_result}

      {:ok, _running} ->
        poll_tool_terminal_again(capability, initial_result, deadline)

      {:error, :not_found} ->
        # The start event is committed before execute returns, but tolerate a
        # read-after-write lag without losing the exact call identity.
        poll_tool_terminal_again(capability, initial_result, deadline)

      {:error, _lookup_failure} ->
        # Polling is only a bounded compatibility fast path. The accepted call
        # remains owned by its session actor and will complete asynchronously.
        {:ok, initial_result}
    end
  end

  defp poll_tool_terminal_again(capability, initial_result, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.sleep(min(@tool_terminal_poll_ms, remaining))
      poll_tool_terminal(capability, initial_result, deadline)
    else
      {:ok, initial_result}
    end
  end

  defp tool_terminal_wait_ms do
    case Application.get_env(
           :salix_web,
           :runtime_proxy_tool_terminal_wait_ms,
           @default_tool_terminal_wait_ms
         ) do
      timeout when is_integer(timeout) and timeout >= 0 ->
        min(timeout, @default_tool_terminal_wait_ms)

      _invalid ->
        @default_tool_terminal_wait_ms
    end
  end

  defp tool_response(result) when is_map(result) do
    content = result_value(result, "content")

    cond do
      result_value(result, "error") == true ->
        json_response(500, %{"error" => content, "tool_error" => true})

      is_binary(content) ->
        case Jason.decode(content) do
          {:ok, %{"status" => "guidance", "error" => "tool is not callable in this session"}} ->
            json_response(404, %{"error" => "not found"})

          {:ok, decoded} ->
            json_response(200, decoded)

          {:error, _} ->
            json_response(200, %{"result" => content})
        end

      true ->
        json_response(200, %{"result" => content})
    end
  end

  defp result_value(result, key) when is_map(result) do
    Map.get(result, key) || Map.get(result, String.to_existing_atom(key))
  end

  defp json_response(status, body) do
    %{
      "status" => status,
      "headers" => %{"content-type" => "application/json"},
      "body_base64" => body |> Jason.encode!() |> Base.encode64()
    }
  end

  defp split_path(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
  end

  defp string_param(map, "method"), do: trim(map["method"] || map[:method] || "")
  defp string_param(map, "route_path"), do: trim(map["route_path"] || map[:route_path] || "")
  defp string_param(map, "body_base64"), do: trim(map["body_base64"] || map[:body_base64] || "")
  defp string_param(map, key), do: trim(map[key] || "")

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
