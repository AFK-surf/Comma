defmodule SalixWeb.RuntimeProxy do
  @moduledoc """
  The meeting bot's LLM gateway.

  A Connector that joined a meeting sends `/llm/chat` requests as
  `runtime_proxy` frames. The Connector only forwards bytes; this module
  checks the meeting LLM capability (`SalixAgent.MeetingLLMCapability`) and
  completes the request with the Agent's LLM.
  """

  alias SalixAgent.MeetingLLMCapability

  def handle(connector_run_id, params, meta \\ %{})

  def handle(connector_run_id, params, meta) when is_map(params) do
    result =
      with {:ok, capability} <-
             MeetingLLMCapability.validate(params["capability_token"]),
           :ok <- MeetingLLMCapability.validate_scope(capability, connector_run_id, meta) do
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
      {"POST", ["llm", "chat"]} ->
        handle_llm_chat(capability, params)

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
        skip_metering: SystemsRuntime.get_env(:salix_web, :connector_llm_skip_metering, false)
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
