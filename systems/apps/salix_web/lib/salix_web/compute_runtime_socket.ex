defmodule SalixWeb.ComputeRuntimeSocket do
  @moduledoc """
  Workload-scoped WebSocket carrier for Runtime Agent input and event delivery.

  The socket owns transport state only. ComputeRuntimeCarrier owns durable input
  state, cursors, and ACK fencing. The socket authenticates once per
  connection and sends at most one unacknowledged frame, so reconnect recovery
  is the same durable claim path as a lost response rather than a second
  in-memory queue. Provider-native auth RPC fencing is modeled in
  `tla/salix/ComputeProviderAuth.tla`.
  """

  @behaviour WebSock

  alias SalixStore.{Compute, ComputeRuntimeCarrier}

  @claim_retry_ms 1_000
  # Match the Connector's bounded external event batch (8 MiB). The route
  # adapter applies the same limit before this callback receives a frame.
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
    :execution_target,
    :in_flight,
    rpc_requests: %{},
    subscription_requests: %{},
    execution_requests: %{},
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

        {:ok, %{"type" => type, "id" => id} = response}
        when type in ["response", "error"] and is_binary(id) ->
          handle_rpc_response(response, state)

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

  def handle_info(
        {:compute_runtime_rpc, ref, caller, request},
        %__MODULE__{status: :ready, rpc_requests: pending} = state
      )
      when is_reference(ref) and is_pid(caller) and is_map(request) do
    class = runtime_rpc_class(request)

    if runtime_rpc_count(pending, class) >= 2 do
      send(caller, {:compute_runtime_rpc_reply, ref, {:error, :runtime_rpc_capacity_exhausted}})
      {:ok, state}
    else
      feature =
        cond do
          request["method"] == "runtime_subscription_sync" ->
            "runtime.subscription.v1"

          request["method"] in ["agent_runtime_stop", "agent_runtime_quiet"] ->
            "runtime.agent_stop.v1"

          true ->
            "runtime.auth.v1"
        end

      if state.runtime_kind == "external_worker" and feature in state.features do
        id = Ecto.UUID.generate()

        frame = %{
          "type" => "request",
          "id" => id,
          "method" => request["method"],
          "params" => request["params"]
        }

        {:push, {:text, Jason.encode!(frame)},
         %{state | rpc_requests: Map.put(pending, id, {ref, caller, class, request})}}
      else
        send(caller, {:compute_runtime_rpc_reply, ref, {:error, :runtime_transport_unavailable}})
        {:ok, state}
      end
    end
  end

  def handle_info(
        {:compute_runtime_rpc_cancel, ref, caller},
        %__MODULE__{rpc_requests: pending} = state
      ) do
    pending =
      Map.reject(pending, fn {_id, {pending_ref, pending_caller, _class, _request}} ->
        pending_ref == ref and pending_caller == caller
      end)

    {:ok, %{state | rpc_requests: pending}}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.subscription_requests, ref) do
      {nil, _} ->
        case Map.pop(state.execution_requests, ref) do
          {nil, _} ->
            {:ok, state}

          {{id, _pid, timer, _class}, pending} ->
            Process.demonitor(ref, [:flush])
            Process.cancel_timer(timer)
            runtime_execution_reply(id, result, %{state | execution_requests: pending})
        end

      {{id, _pid, timer}, pending} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(timer)
        subscription_reply(id, result, %{state | subscription_requests: pending})
    end
  end

  def handle_info({:subscription_timeout, ref}, state) do
    case Map.pop(state.subscription_requests, ref) do
      {nil, _} ->
        {:ok, state}

      {{id, pid, _timer}, pending} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        subscription_reply(id, :error, %{state | subscription_requests: pending})
    end
  end

  def handle_info({:runtime_execution_timeout, ref}, state) do
    case Map.pop(state.execution_requests, ref) do
      {nil, _} ->
        {:ok, state}

      {{id, pid, _timer, _class}, pending} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        runtime_execution_reply(id, {:error, :runtime_execution_timeout}, %{
          state
          | execution_requests: pending
        })
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.subscription_requests, ref) do
      {nil, _} ->
        case Map.pop(state.execution_requests, ref) do
          {nil, _} ->
            {:ok, state}

          {{id, _pid, timer, _class}, pending} ->
            Process.cancel_timer(timer)

            runtime_execution_reply(id, {:error, :runtime_execution_unavailable}, %{
              state
              | execution_requests: pending
            })
        end

      {{id, _pid, timer}, pending} ->
        Process.cancel_timer(timer)
        subscription_reply(id, :error, %{state | subscription_requests: pending})
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp runtime_rpc_class(%{"method" => "session_migration_prepare", "params" => params})
       when is_map(params),
       do: if(params["cancel"] == true, do: :control, else: :operation)

  defp runtime_rpc_class(%{"method" => method})
       when method in [
              "agent_runtime_stop",
              "agent_runtime_quiet",
              "runtime_auth_read",
              "runtime_auth_status",
              "runtime_auth_login_cancel",
              "runtime_auth_input_cancel",
              "session_migration_status"
            ],
       do: :control

  defp runtime_rpc_class(_request), do: :operation

  defp runtime_rpc_count(pending, class) do
    Enum.count(pending, fn {_id, {_ref, _caller, pending_class, _request}} ->
      pending_class == class
    end)
  end

  @impl true
  def terminate(_reason, %__MODULE__{
        status: :ready,
        rpc_requests: pending,
        subscription_requests: incoming,
        execution_requests: execution_requests
      }) do
    Enum.each(incoming, fn {ref, {_id, pid, timer}} ->
      Process.cancel_timer(timer)
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
    end)

    Enum.each(pending, fn {_id, {ref, caller, _class, _request}} ->
      send(caller, {:compute_runtime_rpc_reply, ref, {:error, :runtime_transport_unavailable}})
    end)

    Enum.each(execution_requests, fn {ref, {_id, pid, timer, _class}} ->
      Process.cancel_timer(timer)
      Process.exit(pid, :kill)
      Process.demonitor(ref, [:flush])
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handle_hello(hello, %__MODULE__{status: :awaiting_handshake} = state) do
    case Compute.open_runtime_carrier(state.token, hello) do
      {:ok, opened} ->
        runtime = opened.runtime
        credential = opened.credential

        with {:ok, execution_target} <- runtime_execution_target(runtime, opened.workload) do
          next_state = %{
            state
            | credential: credential["token"],
              runtime_instance_id: runtime.id,
              workload_id: opened.workload.id,
              tenant_id: opened.tenant_id,
              environment_id: opened.environment_id,
              generation: runtime.generation,
              connection_epoch: runtime.connection_epoch,
              runtime_kind: opened.workload.kind,
              features: opened.features,
              execution_target: execution_target,
              input_cursor: opened.input_cursor,
              event_cursor: opened.event_cursor,
              status: :ready
          }

          :ok = maybe_join_runtime_auth(next_state)

          if "runtime.subscription.v1" in next_state.features,
            do: SalixWeb.ComputeSubscriptionAuth.reconnect(next_state)

          schedule_claim()

          {:push, {:text, Jason.encode!(ready_frame(next_state, opened.features))}, next_state}
        else
          {:error, reason} ->
            {:push,
             {:text,
              Jason.encode!(%{"type" => "runtime.error", "error" => reason_string(reason)})},
             %{state | status: :rejected}}
        end

      {:error, reason} ->
        {:push,
         {:text, Jason.encode!(%{"type" => "runtime.error", "error" => reason_string(reason)})},
         %{state | status: :rejected}}
    end
  end

  defp handle_hello(_hello, state), do: {:stop, {:shutdown, :duplicate_runtime_handshake}, state}

  defp runtime_execution_target(runtime, %{kind: "external_worker"} = workload),
    do: Compute.runtime_execution_target(runtime, workload)

  defp runtime_execution_target(_runtime, _workload), do: {:ok, %{}}

  defp maybe_join_runtime_auth(%{
         runtime_kind: "external_worker",
         features: features,
         runtime_instance_id: runtime_instance_id,
         connection_epoch: connection_epoch
       }) do
    if "runtime.auth.v1" in features do
      SalixWeb.ComputeRuntimeRPC.join(runtime_instance_id, connection_epoch)
    else
      :ok
    end
  end

  defp maybe_join_runtime_auth(_state), do: :ok

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

  defp handle_rpc_response(
         %{"id" => id, "type" => type} = response,
         %__MODULE__{rpc_requests: pending} = state
       ) do
    case Map.pop(pending, id) do
      {nil, _pending} ->
        # Cancellation removes the request before a provider response can be
        # recalled from the wire. A late response owns no state and is inert;
        # closing the carrier here would disconnect unrelated runtime work.
        {:ok, state}

      {{ref, caller, _class, _request}, pending} ->
        reply =
          if type == "response" and is_map(response["result"]),
            do: {:ok, response["result"]},
            else: {:error, :runtime_auth_failed}

        send(caller, {:compute_runtime_rpc_reply, ref, reply})
        {:ok, %{state | rpc_requests: pending}}
    end
  end

  defp handle_runtime_execution_request(
         %{"method" => "runtime_execution", "id" => id, "params" => params},
         %__MODULE__{status: :ready} = state
       ) do
    class = runtime_execution_class(params)

    if state.runtime_kind == "external_worker" and
         "runtime.execution.v1" in state.features and is_map(params) and
         runtime_execution_count(state.execution_requests, class) < 2 do
      case authorize_runtime_execution_request(state, params) do
        :ok ->
          start_runtime_execution_request_authorized(state, id, class, params)

        {:error, reason} ->
          runtime_execution_reply(id, {:error, reason}, state)
      end
    else
      runtime_execution_reply(id, {:error, :runtime_execution_capacity_exhausted}, state)
    end
  end

  defp start_runtime_execution_request_authorized(state, id, class, params) do
    case start_runtime_execution_request(state, params) do
      {:ok, task} ->
        timer = Process.send_after(self(), {:runtime_execution_timeout, task.ref}, 95_000)

        {:ok,
         %{
           state
           | execution_requests:
               Map.put(state.execution_requests, task.ref, {id, task.pid, timer, class})
         }}

      :error ->
        runtime_execution_reply(id, {:error, :runtime_execution_unavailable}, state)
    end
  end

  defp authorize_runtime_execution_request(_state, %{"action" => "list"}), do: :ok

  defp authorize_runtime_execution_request(
         _state,
         %{"kind" => "main_execution", "action" => action}
       )
       when action in ["acquire", "release"],
       do: :ok

  defp authorize_runtime_execution_request(
         %__MODULE__{rpc_requests: pending},
         %{
           "operation_request_id" => request_id,
           "execution_id" => activity_id,
           "kind" => kind,
           "action" => action
         }
       )
       when is_binary(request_id) and is_binary(activity_id) and
              action in ["acquire", "release"] do
    with {_ref, _caller, _class, request} <- pending[request_id],
         {:ok, expected_kind, expected_activity} <- runtime_operation_context(request, request_id),
         true <- kind == expected_kind,
         true <- activity_id == expected_activity do
      :ok
    else
      _ -> {:error, :runtime_execution_context_mismatch}
    end
  end

  defp authorize_runtime_execution_request(_state, _params),
    do: {:error, :runtime_execution_context_mismatch}

  defp runtime_operation_context(
         %{"method" => method, "params" => %{"target" => target}},
         request_id
       )
       when method in [
              "runtime_auth_login_start",
              "runtime_auth_login_cancel",
              "runtime_auth_status",
              "runtime_auth_verify",
              "runtime_auth_input_begin",
              "runtime_auth_input_submit",
              "runtime_auth_input_cancel"
            ] and is_map(target) do
    with runtime_instance when is_binary(runtime_instance) and runtime_instance != "" <-
           target["runtime_instance_id"],
         provider when is_binary(provider) and provider != "" <- target["provider"] do
      digest =
        :crypto.hash(:sha256, runtime_instance <> <<0>> <> provider)
        |> binary_part(0, 16)
        |> Base.encode16(case: :lower)

      family = "auth:" <> digest

      activity =
        if method == "runtime_auth_verify", do: family <> ":verify:" <> request_id, else: family

      {:ok, "auth_operation", activity}
    else
      _ -> :error
    end
  end

  defp runtime_operation_context(
         %{"method" => "session_migration_" <> action, "params" => params},
         _request_id
       )
       when action in ["export", "import"] and is_map(params) do
    case params["operation_id"] do
      operation_id when is_binary(operation_id) and operation_id != "" ->
        kind = "migration_" <> action
        {:ok, kind, kind <> ":" <> operation_id}

      _ ->
        :error
    end
  end

  defp runtime_operation_context(_request, _request_id), do: :error

  defp handle_runtime_request(
         %{"method" => "runtime_execution"} = request,
         %__MODULE__{} = state
       ),
       do: handle_runtime_execution_request(request, state)

  defp handle_runtime_request(
         %{"method" => "runtime_subscription_access", "id" => id, "params" => params},
         %__MODULE__{status: :ready} = state
       ) do
    if state.runtime_kind == "external_worker" and "runtime.subscription.v1" in state.features and
         map_size(state.subscription_requests) < 2 and is_map(params) do
      case start_subscription_request(state, params) do
        {:ok, task} ->
          timer = Process.send_after(self(), {:subscription_timeout, task.ref}, 11_000)

          {:ok,
           %{
             state
             | subscription_requests:
                 Map.put(state.subscription_requests, task.ref, {id, task.pid, timer})
           }}

        :error ->
          subscription_reply(id, :error, state)
      end
    else
      subscription_reply(id, :error, state)
    end
  end

  defp handle_runtime_request(
         %{"method" => method, "params" => params} = request,
         %__MODULE__{status: :ready} = state
       )
       when method in [
              "runtime_proxy",
              "external_runtime_event",
              "external_runtime_events",
              "meeting_runtime_event"
            ] and
              is_map(params) do
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

  defp runtime_execution_class(%{"action" => action}) when action in ["release", "list"],
    do: :control

  defp runtime_execution_class(_params), do: :operation

  defp runtime_execution_count(pending, class) do
    Enum.count(pending, fn {_ref, {_id, _pid, _timer, pending_class}} ->
      pending_class == class
    end)
  end

  # A shared supervisor can reject this socket's first request. Handle startup
  # failure here so capacity loss cannot tear down the input/event carrier.
  defp start_subscription_request(state, params) do
    task =
      Task.Supervisor.async_nolink(SalixWeb.ConnectorRequestTaskSupervisor, fn ->
        try do
          SalixWeb.ComputeSubscriptionAuth.access(state, params)
        rescue
          _ -> {:error, :subscription_access_unavailable}
        catch
          _, _ -> {:error, :subscription_access_unavailable}
        end
      end)

    {:ok, task}
  rescue
    RuntimeError -> :error
  catch
    :exit, _ -> :error
  end

  defp subscription_reply(id, result, state) do
    frame =
      case result do
        {:ok, envelope} -> %{"id" => id, "type" => "response", "result" => envelope}
        _ -> %{"id" => id, "type" => "error", "error" => "subscription_access_unavailable"}
      end

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  defp start_runtime_execution_request(state, params) do
    task =
      Task.Supervisor.async_nolink(SalixWeb.ConnectorRequestTaskSupervisor, fn ->
        action = params["action"]

        Compute.runtime_execution(action, params, %{
          runtime_instance_id: state.runtime_instance_id,
          workload_id: state.workload_id,
          generation: state.generation,
          connection_epoch: state.connection_epoch
        })
      end)

    {:ok, task}
  rescue
    RuntimeError -> :error
  catch
    :exit, _ -> :error
  end

  defp runtime_execution_reply(id, result, state) do
    frame =
      case result do
        {:ok, value} -> %{"id" => id, "type" => "response", "result" => value}
        {:error, reason} -> %{"id" => id, "type" => "error", "error" => reason_string(reason)}
        _ -> %{"id" => id, "type" => "error", "error" => "runtime_execution_unavailable"}
      end

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  defp dispatch_runtime_request("external_runtime_event", params, state) do
    if state.runtime_kind == "external_worker" and "runtime.event.v1" in state.features do
      SalixWeb.ExternalRuntime.handle_connector_event(
        nil,
        params,
        %{"tenant_id" => state.tenant_id}
      )
    else
      {:error, :unsupported_runtime_request}
    end
  end

  defp dispatch_runtime_request("runtime_proxy", params, state) do
    SalixWeb.RuntimeProxy.handle(nil, params, %{"tenant_id" => state.tenant_id})
  end

  defp dispatch_runtime_request("external_runtime_events", %{"events" => events}, state)
       when is_list(events) and events != [] and length(events) <= 64 do
    if state.runtime_kind != "external_worker" or
         "runtime.event.v1" not in state.features do
      {:error, :unsupported_runtime_request}
    else
      outcomes =
        SalixWeb.ExternalRuntime.handle_connector_events(
          nil,
          events,
          %{"tenant_id" => state.tenant_id}
        )

      if length(outcomes) == length(events) do
        {accepted, rejected} =
          Enum.zip(events, outcomes)
          |> Enum.reduce({[], []}, fn {event, outcome}, {accepted, rejected} ->
            case outcome do
              {:ok, _} ->
                {[event["event_id"] | accepted], rejected}

              {:error, reason} ->
                if permanent_runtime_event_error?(reason) do
                  {accepted,
                   [
                     %{
                       "event_id" => event["event_id"],
                       "error_code" => reason_string(reason)
                     }
                     | rejected
                   ]}
                else
                  {accepted, rejected}
                end
            end
          end)

        {:ok,
         %{
           "accepted_event_ids" => Enum.reverse(accepted),
           "permanently_rejected_events" => Enum.reverse(rejected)
         }}
      else
        {:error, :invalid_external_runtime_event_response}
      end
    end
  end

  defp dispatch_runtime_request("external_runtime_events", _params, _state),
    do: {:error, :invalid_external_runtime_event_batch}

  defp dispatch_runtime_request("meeting_runtime_event", params, state) do
    if state.runtime_kind == "meeting_runtime" and "runtime.event.v1" in state.features do
      SalixWeb.MeetingRuntime.handle_compute_event(params, state.environment_id)
    else
      {:error, :unsupported_runtime_request}
    end
  end

  defp permanent_runtime_event_error?({:bad_request, _}), do: true

  defp permanent_runtime_event_error?(reason) when reason in [:unauthorized, :scope_mismatch],
    do: true

  defp permanent_runtime_event_error?(_), do: false

  defp ready_frame(state, features) do
    %{
      "type" => "runtime.ready",
      "runtime_instance_id" => state.runtime_instance_id,
      "workload_id" => state.workload_id,
      "generation" => state.generation,
      "runtime_kind" => state.runtime_kind,
      "connection_epoch" => state.connection_epoch,
      "features" => features,
      "execution_target" => state.execution_target,
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

  defp schedule_claim, do: Process.send_after(self(), :claim, @claim_retry_ms)

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "runtime_handshake_rejected"
end
