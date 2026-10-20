defmodule SalixWeb.ComputeRuntimeSocket do
  @moduledoc """
  Workload-scoped WebSocket carrier for Runtime Agent input and event delivery.

  The socket owns transport state only. ComputeRuntimeCarrier owns durable input
  state, cursors, and ACK fencing. The socket authenticates once per
  connection and sends at most one unacknowledged frame, so reconnect recovery
  is the same durable claim path as a lost response rather than a second
  in-memory queue. A meeting runtime (`meeting.meetnative`) is its one
  Workload kind.
  """

  @behaviour WebSock

  alias SalixStore.{Compute, ComputeRuntimeCarrier}

  @claim_retry_ms 1_000
  # The route adapter applies the same limit before this callback receives a
  # frame.
  @max_event_frame_bytes 8 * 1024 * 1024

  defstruct [
    :token,
    :credential,
    :runtime_instance_id,
    :workload_id,
    :tenant_id,
    :environment_id,
    :generation,
    :connection_epoch,
    :runtime_kind,
    :features,
    :in_flight,
    input_cursor: "",
    event_cursor: "",
    status: :awaiting_handshake
  ]

  @impl true
  def init(%{token: token}) when is_binary(token) and token != "" do
    {:ok, %__MODULE__{token: token}}
  end

  @impl true
  def handle_in({frame, [opcode: :text]}, %__MODULE__{} = state) do
    if byte_size(frame) > @max_event_frame_bytes do
      {:stop, {:shutdown, :runtime_event_too_large}, state}
    else
      case Jason.decode(frame) do
        {:ok, %{"type" => "runtime.hello"} = hello} ->
          handle_hello(hello, state)

        {:ok, %{"type" => "runtime.input_ack"} = ack} ->
          handle_ack(ack, state)

        # Salix sends a runtime no requests, so a response owns no state.
        {:ok, %{"type" => type, "id" => id}}
        when type in ["response", "error"] and is_binary(id) ->
          {:ok, state}

        {:ok, %{"type" => "request", "id" => id} = request} when is_binary(id) ->
          handle_runtime_request(request, state)

        _ ->
          {:stop, {:shutdown, :invalid_runtime_frame}, state}
      end
    end
  end

  def handle_in({_frame, [opcode: _]}, state),
    do: {:stop, {:shutdown, :invalid_runtime_frame}, state}

  @impl true
  def handle_info(:claim, %__MODULE__{status: :ready, in_flight: nil} = state) do
    case ComputeRuntimeCarrier.claim_inputs(
           state.runtime_instance_id,
           state.connection_epoch,
           claim_cursor_for(state),
           1
         ) do
      {:ok, [input]} ->
        frame = %{
          "type" => "runtime.input",
          "input_id" => input["id"],
          "payload" => input["payload"],
          "generation" => input["generation"],
          "connection_epoch" => input["connection_epoch"]
        }

        {:push, {:text, Jason.encode!(frame)}, %{state | in_flight: input["id"]}}

      {:ok, []} ->
        schedule_claim()
        {:ok, state}

      {:error, :unavailable} ->
        schedule_claim()
        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info(:claim, state), do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}

  defp handle_hello(hello, %__MODULE__{status: :awaiting_handshake} = state) do
    case Compute.open_runtime_carrier(state.token, hello) do
      {:ok, opened} ->
        runtime = opened.runtime

        next_state = %{
          state
          | credential: opened.credential["token"],
            runtime_instance_id: runtime.id,
            workload_id: opened.workload.id,
            tenant_id: opened.tenant_id,
            environment_id: opened.environment_id,
            generation: runtime.generation,
            connection_epoch: runtime.connection_epoch,
            runtime_kind: opened.workload.kind,
            features: opened.features,
            input_cursor: opened.input_cursor,
            event_cursor: opened.event_cursor,
            status: :ready
        }

        schedule_claim()

        {:push, {:text, Jason.encode!(ready_frame(next_state, opened.features))}, next_state}

      {:error, reason} ->
        {:push,
         {:text, Jason.encode!(%{"type" => "runtime.error", "error" => reason_string(reason)})},
         %{state | status: :rejected}}
    end
  end

  defp handle_hello(_hello, state), do: {:stop, {:shutdown, :duplicate_runtime_handshake}, state}

  defp handle_ack(
         %{"input_id" => input_id},
         %__MODULE__{status: :ready, in_flight: input_id} = state
       )
       when is_binary(input_id) do
    case ComputeRuntimeCarrier.ack(
           input_id,
           state.runtime_instance_id,
           state.connection_epoch
         ) do
      {:ok, _input} ->
        next_state = put_cursor(state, input_id)
        send(self(), :claim)

        {:push,
         {:text,
          Jason.encode!(%{
            "type" => "runtime.input_acked",
            "input_id" => input_id
          })}, %{next_state | in_flight: nil}}

      {:error, :unavailable} ->
        # Reconnect reclaims the durable in-flight input. Leaving this socket
        # open would keep the frame in-flight without a retry path.
        {:stop, {:shutdown, :unavailable}, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, state}
    end
  end

  defp handle_ack(_ack, state), do: {:stop, {:shutdown, :invalid_runtime_ack}, state}

  defp handle_runtime_request(
         %{"method" => method, "params" => params} = request,
         %__MODULE__{status: :ready} = state
       )
       when method in ["runtime_proxy", "meeting_runtime_event"] and is_map(params) do
    result = dispatch_runtime_request(method, params, state)

    case result do
      {:ok, value} ->
        {:push,
         {:text,
          Jason.encode!(%{"id" => request["id"], "type" => "response", "result" => value})},
         state}

      {:error, reason} ->
        {:push,
         {:text,
          Jason.encode!(%{
            "id" => request["id"],
            "type" => "error",
            "error" => reason_string(reason)
          })}, state}
    end
  end

  defp handle_runtime_request(_request, state),
    do: {:stop, {:shutdown, :invalid_runtime_request}, state}

  defp dispatch_runtime_request("runtime_proxy", params, state) do
    SalixWeb.RuntimeProxy.handle(nil, params, %{"tenant_id" => state.tenant_id})
  end

  defp dispatch_runtime_request("meeting_runtime_event", params, state) do
    if state.runtime_kind == "meeting_runtime" and "runtime.event.v1" in state.features do
      SalixWeb.MeetingRuntime.handle_compute_event(params, state.environment_id)
    else
      {:error, :unsupported_runtime_request}
    end
  end

  defp ready_frame(state, features) do
    %{
      "type" => "runtime.ready",
      "runtime_instance_id" => state.runtime_instance_id,
      "workload_id" => state.workload_id,
      "generation" => state.generation,
      "runtime_kind" => state.runtime_kind,
      "connection_epoch" => state.connection_epoch,
      "features" => features,
      "execution_target" => %{},
      "input_cursor" => state.input_cursor,
      "event_cursor" => state.event_cursor,
      "token" => state.credential
    }
  end

  defp cursor_for(%__MODULE__{runtime_kind: "meeting_runtime", event_cursor: cursor}), do: cursor
  defp cursor_for(%__MODULE__{input_cursor: cursor}), do: cursor

  defp claim_cursor_for(state) do
    case cursor_for(state) do
      "" -> nil
      cursor -> cursor
    end
  end

  defp put_cursor(%__MODULE__{runtime_kind: "meeting_runtime"} = state, cursor),
    do: %{state | event_cursor: cursor}

  defp put_cursor(state, cursor), do: %{state | input_cursor: cursor}

  defp schedule_claim, do: SystemsClock.send_after(self(), :claim, @claim_retry_ms)

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "runtime_handshake_rejected"
end
