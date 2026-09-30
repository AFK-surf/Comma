defmodule SalixMCP.RemoteClient do
  @moduledoc false

  alias SalixMCP.JSONRPC

  @protocol_version "2025-06-18"

  def initialize(config) do
    with {:ok, result, headers} <- request(config, "initialize", initialize_params(), %{}) do
      session_headers = session_headers(headers)
      {:ok, result, session_headers}
    end
  end

  def request(
        config,
        method,
        params,
        session_headers \\ %{},
        receive_timeout \\ 30_000,
        opts \\ []
      ) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(config["url"]) do
      id =
        Keyword.get(opts, :request_id) ||
          "mcp-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      body = JSONRPC.request(id, method, params)
      progress_callback = Keyword.get(opts, :progress_callback)

      headers =
        config
        |> Map.get("headers", %{})
        |> Map.merge(session_headers)
        |> Map.put_new("accept", "application/json, text/event-stream")
        |> Map.put_new("content-type", "application/json")
        |> Map.put_new("mcp-protocol-version", @protocol_version)
        |> target_headers(target)

      case Req.request(
             method: :post,
             url: target.url,
             json: body,
             headers: headers,
             into: stream_into(progress_callback),
             decode_body: false,
             receive_timeout: receive_timeout,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: response_body, headers: response_headers}}
        when status in 200..299 ->
          with {:ok, response} <- decode_response(response_body, id),
               {:ok, result} <- JSONRPC.response_result(response) do
            {:ok, result, response_headers}
          end

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, {:http_error, status, headers || %{}, body || ""}}

        {:error, reason} ->
          {:error, {:request_failed, request_error(reason)}}
      end
    end
  end

  def notify(config, method, params, session_headers \\ %{}) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(config["url"]) do
      headers =
        config
        |> Map.get("headers", %{})
        |> Map.merge(session_headers)
        |> Map.put_new("accept", "application/json, text/event-stream")
        |> Map.put_new("content-type", "application/json")
        |> Map.put_new("mcp-protocol-version", @protocol_version)
        |> target_headers(target)

      case Req.request(
             method: :post,
             url: target.url,
             json: JSONRPC.notification(method, params),
             headers: headers,
             receive_timeout: 10_000,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, {:http_error, status, headers || %{}, body || ""}}

        {:error, reason} ->
          {:error, {:request_failed, request_error(reason)}}
      end
    end
  end

  def start_sse(config, owner) when is_pid(owner) do
    Task.start(fn -> sse_loop(config, owner) end)
  end

  def sse_post(config, endpoint, message, timeout \\ 30_000) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(endpoint) do
      headers =
        config
        |> Map.get("headers", %{})
        |> Map.put_new("accept", "application/json, text/event-stream")
        |> Map.put_new("content-type", "application/json")
        |> Map.put_new("mcp-protocol-version", @protocol_version)
        |> target_headers(target)

      case Req.request(
             method: :post,
             url: target.url,
             json: message,
             headers: headers,
             receive_timeout: timeout,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, {:http_error, status, headers || %{}, body || ""}}

        {:error, reason} ->
          {:error, {:request_failed, request_error(reason)}}
      end
    end
  end

  def decode_response(body, request_id \\ nil)
  def decode_response(%{} = body, _request_id), do: {:ok, body}

  def decode_response(body, request_id) when is_binary(body) do
    case sse_json_messages(body) do
      [] ->
        Jason.decode(body)

      messages ->
        {:ok, response_message(messages, request_id)}
    end
  end

  def decode_response(body, _request_id), do: {:error, {:bad_response_body, body}}

  def session_headers(headers) do
    case header_value(headers, "mcp-session-id") do
      "" -> %{}
      value -> %{"mcp-session-id" => value}
    end
  end

  def sse_json_messages(body) when is_binary(body) do
    {messages, rest} = sse_messages_from_buffer(body)
    messages ++ decode_sse_event(rest)
  end

  def sse_json_messages(_body), do: []

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"roots" => %{"listChanged" => true}},
      "clientInfo" => %{"name" => "salix", "version" => "0.1.0"}
    }
  end

  defp stream_into(progress_callback) do
    fn {:data, data}, {request, response} ->
      response =
        response
        |> update_response_body(data)
        |> emit_stream_progress(data, progress_callback)

      {:cont, {request, response}}
    end
  end

  defp update_response_body(response, data) do
    body = (response.body || "") <> data
    %{response | body: body}
  end

  defp emit_stream_progress(response, data, progress_callback)
       when is_function(progress_callback, 1) do
    buffer = Map.get(response.private, :salix_mcp_sse_buffer, "") <> data
    {messages, rest} = sse_messages_from_buffer(buffer)
    Enum.each(messages, progress_callback)
    put_in(response.private[:salix_mcp_sse_buffer], rest)
  end

  defp emit_stream_progress(response, _data, _progress_callback), do: response

  defp response_message(messages, request_id) do
    request_id = nonempty(request_id)

    if request_id == "" do
      Enum.find(messages, &Map.has_key?(&1, "id")) || List.last(messages)
    else
      Enum.find(messages, &(to_string(Map.get(&1, "id")) == request_id)) ||
        Enum.find(messages, &Map.has_key?(&1, "id")) ||
        List.last(messages)
    end
  end

  defp sse_messages_from_buffer(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    {events, rest} =
      if String.ends_with?(normalized, "\n\n") do
        {Enum.reject(parts, &(&1 == "")), ""}
      else
        rest = List.last(parts) || ""
        complete_count = max(length(parts) - 1, 0)
        {parts |> Enum.take(complete_count) |> Enum.reject(&(&1 == "")), rest}
      end

    {Enum.flat_map(events, &decode_sse_event/1), rest}
  end

  defp decode_sse_event(""), do: []

  defp decode_sse_event(raw) do
    data =
      raw
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(String.replace_prefix(&1, "data:", "")))
      |> Enum.join("\n")

    cond do
      data == "" or data == "[DONE]" ->
        []

      true ->
        case Jason.decode(data) do
          {:ok, %{} = message} -> [message]
          _ -> []
        end
    end
  end

  defp header_value(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value("", fn {header_key, value} ->
      if String.downcase(to_string(header_key)) == key do
        value |> List.wrap() |> List.first() |> header_value_to_string()
      end
    end)
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value("", fn
      {header_key, value} ->
        if String.downcase(to_string(header_key)) == key do
          value |> List.wrap() |> List.first() |> header_value_to_string()
        end

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _key), do: ""

  defp header_value_to_string(nil), do: ""
  defp header_value_to_string(value), do: to_string(value)

  defp request_error(%{reason: reason}), do: inspect(reason)
  defp request_error(reason) when is_binary(reason), do: reason
  defp request_error(reason), do: inspect(reason)

  defp target_headers(headers, target) do
    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "host" end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("host", target.host_header)
  end

  defp sse_loop(config, owner) do
    do_sse_loop(config, owner)
  rescue
    e -> send(owner, {:mcp_sse_error, self(), Exception.message(e)})
  catch
    kind, reason -> send(owner, {:mcp_sse_error, self(), {kind, reason}})
  end

  defp do_sse_loop(config, owner) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(config["url"]) do
      headers =
        config
        |> Map.get("headers", %{})
        |> Map.put_new("accept", "text/event-stream")
        |> Map.put_new("mcp-protocol-version", @protocol_version)
        |> target_headers(target)

      case Req.get(
             target.url,
             headers: headers,
             into: sse_stream_into(config, owner, self()),
             receive_timeout: 86_400_000,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          send(owner, {:mcp_sse_closed, self()})

        {:ok, %Req.Response{status: status}} ->
          send(owner, {:mcp_sse_error, self(), {:http_error, status}})

        {:error, reason} ->
          send(owner, {:mcp_sse_error, self(), {:request_failed, request_error(reason)}})
      end
    else
      {:error, reason} -> send(owner, {:mcp_sse_error, self(), reason})
    end
  end

  defp sse_stream_into(config, owner, stream_pid) do
    fn {:data, data}, {request, response} ->
      buffer = Map.get(response.private, :salix_mcp_sse_buffer, "")
      rest = parse_sse_chunk(buffer <> data, config, owner, stream_pid)
      response = put_in(response.private[:salix_mcp_sse_buffer], rest)
      {:cont, {request, response}}
    end
  end

  defp parse_sse_chunk(buffer, config, owner, stream_pid) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    {events, rest} =
      if String.ends_with?(normalized, "\n\n") do
        {Enum.reject(parts, &(&1 == "")), ""}
      else
        rest = List.last(parts) || ""
        complete_count = max(length(parts) - 1, 0)
        {parts |> Enum.take(complete_count) |> Enum.reject(&(&1 == "")), rest}
      end

    Enum.each(events, &emit_sse_event(&1, config, owner, stream_pid))
    rest
  end

  defp emit_sse_event(raw, config, owner, stream_pid) do
    event =
      raw
      |> String.split("\n")
      |> Enum.reduce(%{"event" => "message", "data" => []}, fn line, acc ->
        cond do
          String.starts_with?(line, "event:") ->
            Map.put(acc, "event", String.trim(String.replace_prefix(line, "event:", "")))

          String.starts_with?(line, "data:") ->
            Map.update!(
              acc,
              "data",
              &[String.trim_leading(String.replace_prefix(line, "data:", "")) | &1]
            )

          true ->
            acc
        end
      end)

    data = event["data"] |> Enum.reverse() |> Enum.join("\n")

    case event["event"] do
      "endpoint" ->
        case absolute_sse_endpoint(config["url"], data) do
          {:ok, endpoint} -> send(owner, {:mcp_sse_endpoint, stream_pid, endpoint})
          {:error, reason} -> send(owner, {:mcp_sse_error, stream_pid, reason})
        end

      _ ->
        case Jason.decode(data) do
          {:ok, %{} = message} -> send(owner, {:mcp_sse_response, stream_pid, message})
          _ -> :ok
        end
    end
  end

  defp absolute_sse_endpoint(base, endpoint) do
    endpoint = String.trim(endpoint || "")
    base_uri = URI.parse(base)
    endpoint_uri = URI.merge(base_uri, endpoint)

    if same_origin?(base_uri, endpoint_uri) do
      {:ok, URI.to_string(endpoint_uri)}
    else
      {:error, {:bad_request, "legacy SSE endpoint must stay on the MCP server origin"}}
    end
  end

  defp same_origin?(base, endpoint) do
    base.scheme == endpoint.scheme and base.host == endpoint.host and
      normalized_port(base) == normalized_port(endpoint)
  end

  defp normalized_port(%URI{port: port}) when is_integer(port),
    do: port

  defp normalized_port(%URI{scheme: scheme}), do: URI.default_port(scheme)

  defp nonempty(nil), do: ""
  defp nonempty(value), do: String.trim(to_string(value))
end
