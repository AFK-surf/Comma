defmodule SalixWeb.StationLLM do
  @moduledoc """
  The platform's `worker` model for the Sessions of a Workload's station (a
  Cloud VM), as Salix lends it (`SalixWeb.StationProfiles`): a profile of the
  station whose endpoint is here and whose key is a token of the station's
  current connection (`token/3`).

  `POST /v1/station-llm/responses` takes what Codex sends a Responses
  endpoint and passes it, with the model the platform tier names, to the
  tier's own endpoint; what comes back (streamed or not) goes back as it
  came. The station never holds the platform's key. Each call is metered
  against the workspace's billing owner from the usage the provider reports,
  and refused (402) when billing is unavailable.

  A token opens this route only while the connection it was made for is the
  device's current one: it ends when the station disconnects.
  """

  import Plug.Conn

  require Logger

  alias Salix.Control.Groups
  alias SalixAgent.{LLMMetering, PlatformModels, SubscriptionStore}

  @tier "worker"
  @prefix "slm1."
  @seal_id "station-llm"
  @receive_timeout_ms 600_000

  @doc "The path of the route: `<base>/responses`, as Codex asks a Responses endpoint."
  def base_path, do: "/v1/station-llm"

  def path?(path), do: path == base_path() <> "/responses"

  @doc "The platform tier a station is lent, when it is configured for Codex (`responses`)."
  def tier do
    with {:ok, template} <- PlatformModels.record(@tier),
         "responses" <- get_in(template, ["provider_config", "protocol"]) do
      {:ok, template}
    else
      {:error, _} = error -> error
      _ -> {:error, :platform_model_not_responses}
    end
  end

  @doc "A key for the station of connection `run` (device `device` of `group`)."
  def token(tenant, group, device, run) do
    with {:ok, sealed} <-
           SubscriptionStore.seal(tenant, @seal_id, %{
             "group" => group,
             "device" => device,
             "run" => run
           }) do
      {:ok, @prefix <> tenant <> "." <> Base.url_encode64(sealed, padding: false)}
    end
  end

  @doc "Lets the request in when its key is a token of a connection that is still the device's own."
  def admit(conn, @prefix <> rest) do
    with [tenant, encoded] <- String.split(rest, ".", parts: 2),
         {:ok, sealed} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"group" => group, "device" => device, "run" => run}} <-
           SubscriptionStore.open(tenant, @seal_id, sealed),
         {:ok, %{"status" => "connected", "connector_run_id" => ^run} = current} <-
           SalixEnv.Registry.get_device(tenant, group, device),
         {:ok, _owner} <-
           SalixEnv.StationConnection.authorize(
             SalixStore.ComputeStation.connection(tenant, group, current)
           ) do
      conn
      |> assign(:auth_role, :station_llm)
      |> assign(:station_llm, %{tenant_id: tenant, group_id: group, device_id: device})
    else
      _ -> deny(conn)
    end
  end

  def admit(conn, _token), do: deny(conn)

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end

  @doc "Serves `POST /v1/station-llm/responses` for the admitted station."
  def serve(%{assigns: %{station_llm: station}} = conn) do
    with {:ok, template} <- tier(),
         %{} = body <- conn.body_params do
      proxy(conn, station, template, Map.put(body, "model", template["model"]))
    else
      {:error, reason} ->
        Logger.warning("station llm unavailable: #{inspect(reason)}")
        error(conn, 503, "the platform model is not available")

      _ ->
        error(conn, 400, "a JSON body is required")
    end
  end

  defp proxy(conn, station, template, body) do
    ctx = meter_context(station, template)

    case LLMMetering.before_llm_call(ctx) do
      {:error, {:billing_unavailable, _decision}} ->
        error(conn, 402, "billing unavailable")

      _ ->
        started = SystemsClock.monotonic_time(:millisecond)
        {conn, usage, status, reason} = forward(conn, template, body)

        _ = LLMMetering.after_llm_call(meter_result(ctx, usage, started, status, reason))
        conn
    end
  end

  # What the provider answers goes back as it comes: its status, its content
  # type and its bytes. The usage is read from the answer (the last
  # `response.*` event of a stream, or the body) to meter the call.
  defp forward(conn, template, body) do
    config = template["provider_config"]
    url = String.trim_trailing(config["base_url"], "/") <> "/responses"
    state = %{conn: conn, sent: false, buffer: "", usage: nil, body: ""}
    Process.put(:station_llm, state)

    into = fn {:data, data}, {req, resp} ->
      Process.put(:station_llm, relay(Process.get(:station_llm), resp, data))
      {:cont, {req, resp}}
    end

    result =
      Req.post(url,
        json: body,
        headers: headers(config),
        into: into,
        receive_timeout: @receive_timeout_ms,
        retry: false,
        decode_body: false
      )

    state = Process.delete(:station_llm)

    case {result, state} do
      {{:ok, resp}, %{sent: false} = state} ->
        # Nothing came: the answer is empty.
        conn = state.conn |> put_content_type(resp) |> send_resp(resp.status, "")
        {conn, nil, status(resp), nil}

      {{:ok, resp}, state} ->
        {state.conn, state.usage || body_usage(state.body), status(resp), nil}

      {{:error, reason}, %{sent: false}} ->
        {error(conn, 502, "the platform model did not answer"), nil, "error", reason}

      {{:error, reason}, state} ->
        {state.conn, state.usage, "error", reason}
    end
  end

  defp relay(state, resp, data) do
    conn =
      if state.sent,
        do: state.conn,
        else: state.conn |> put_content_type(resp) |> send_chunked(resp.status)

    conn =
      case chunk(conn, data) do
        {:ok, conn} -> conn
        {:error, _closed} -> conn
      end

    {buffer, usage} = stream_usage(state.buffer <> data, state.usage)
    # A body that is not a stream is kept (bounded) to read its usage at the end.
    body = if byte_size(state.body) < 1_048_576, do: state.body <> data, else: state.body
    %{state | conn: conn, sent: true, buffer: buffer, usage: usage, body: body}
  end

  defp put_content_type(conn, resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _] -> put_resp_header(conn, "content-type", type)
      [] -> conn
    end
  end

  # Complete lines of an SSE stream; the usage of its last `response.*` event that has one.
  defp stream_usage(buffer, usage) do
    lines = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(lines, -1)

    usage =
      Enum.reduce(complete, usage, fn
        "data: " <> json, acc ->
          case Jason.decode(json) do
            {:ok, %{"response" => %{"usage" => %{} = found}}} -> found
            _ -> acc
          end

        _line, acc ->
          acc
      end)

    {rest, usage}
  end

  defp body_usage(body) do
    case Jason.decode(body) do
      {:ok, %{"usage" => %{} = usage}} -> usage
      _ -> nil
    end
  end

  defp status(%{status: status}) when status in 200..299, do: "ok"
  defp status(_resp), do: "error"

  defp headers(config) do
    auth =
      case config["api_key"] do
        key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
        _ -> []
      end

    auth ++
      Enum.map(config["default_headers"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message}}))
  end

  # ---- metering ----

  defp meter_context(station, template) do
    %{
      entrypoint: "station_llm",
      actor_type: "station",
      provider: template["provider"] || "openai",
      credential_scope: "platform",
      model: template["model"],
      started_at_ms: SystemsClock.system_time(:millisecond)
    }
    |> Map.merge(billing_owner(station))
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp billing_owner(%{tenant_id: tenant, group_id: group}) do
    with {:ok, record} <- Groups.get(group, tenant),
         owner when is_map(owner) <- record["billing_owner"] do
      %{
        billing_account_id: owner["billing_account_id"],
        surface: owner["surface"],
        product_owner_type: owner["product_owner_type"],
        product_owner_id: owner["product_owner_id"],
        tenant_id: owner["salix_tenant_id"] || tenant,
        group_id: owner["salix_group_id"] || group,
        salix_tenant_id: owner["salix_tenant_id"] || tenant,
        salix_group_id: owner["salix_group_id"] || group,
        charge_policy: owner["charge_policy"]
      }
    else
      _ -> %{tenant_id: tenant, group_id: group, quality: ["billing_owner_missing"]}
    end
  end

  defp meter_result(ctx, usage, started, status, reason) do
    ctx
    |> Map.merge(%{
      status: status,
      duration_ms: SystemsClock.monotonic_time(:millisecond) - started,
      completed_at_ms: SystemsClock.system_time(:millisecond),
      response_kind: "station_llm",
      usage: normalize_usage(usage),
      error: if(reason, do: inspect(reason))
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The Responses API's usage, as the meter counts it.
  defp normalize_usage(nil), do: %{}

  defp normalize_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => usage["total_tokens"] || input + output,
      "cache_read_input_tokens" => get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
      "cache_write_input_tokens" => 0
    }
  end
end
