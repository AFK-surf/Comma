defmodule SalixWeb.ConnectorSocket do
  require SystemsClock

  @moduledoc """
  The connector-side of the bridge — a `WebSock` handler that owns one
  `salix-connect` WebSocket.

  This process is the socket owner registered in `SalixEnv.Bridge` (the local
  `SalixEnv.Bridges` registry) under the live connector run id. The underlying
  storage key is still named `env_id` in `SalixEnv.Registry`, but connector wire
  frames use `connector_run_id`.

  `SalixEnv.Bridge.rpc/3` — invoked locally or via `:erpc` from the node running
  the agent — delivers a request envelope as `{:env_rpc, ref, from, message}`; we
  push it to the connector, correlate the connector's response by envelope `id`,
  and reply `{:env_rpc_reply, ref, outcome}`.

  Lifecycle:

    * `init/1` — register as the connector-run socket owner, greet with
      `{"type":"connected","connector_run_id":…}`, start the heartbeat.
    * `handle_in/2` — `response`/`error` frames complete a pending RPC;
      `metadata` frames refresh the durable record's capabilities/skills;
      `heartbeat` frames are liveness only.
    * `handle_info/2` — `:env_rpc` pushes a request; `:heartbeat` pings.
    * `terminate/2` — flip the durable record to `disconnected` and fail every
      in-flight RPC so no caller hangs past the socket.

  Write-stream ownership is modeled
  in `tla/salix/ConnectorWriteStream.tla`; pending RPCs have an independent
  bounded map, and read-stream ownership is modeled in
  `tla/salix/ConnectorReadStream.tla`.

  Meeting callback admission deduplicates the business `event_id` across the
  active request and bounded FIFO as modeled in
  `tla/salix/MeetingRuntimeEventQueue.tla`.
  """
  @behaviour WebSock

  require Logger
  alias SalixEnv.{FrameStream, Protocol, Registry, RuntimeProxy}
  alias SalixWeb.ConnectorResponseChunks
  alias SalixStore.RuntimeIds

  @max_meeting_artifacts 2
  @max_meeting_artifact_bytes 30 * 1024 * 1024
  @max_meeting_event_bytes 32 * 1024 * 1024
  @tunnel_channels ~w(tcp tcp_ack)
  @max_chunked_response_bytes 4 * 1024 * 1024
  # A gateway's longest HTTP timeout, for a request that names none.
  @default_chunked_http_seconds 30
  # A Mini App deploy reads up to ~90 MB from its station and uploads it.
  @app_deploy_timeout_ms 300_000

  defmodule State do
    @moduledoc false
    # pending: %{request_id => %{from: pid, ref: reference, caller_monitor: reference,
    #                            timer: reference, chunks: ConnectorResponseChunks | nil,
    #                            chunk_idle: {timer, lease} | nil,
    #                            chunk_wait_ms: pos_integer | nil}}
    # read_streams: %{request_id => %{receiver: pid, from: pid, ref: reference,
    #                                 caller_monitor: reference, absolute_timer: reference,
    #                                 absolute_token: reference}}
    defstruct [
      :env_id,
      :connector_run_id,
      :device_id,
      :connector_id,
      :credential_generation,
      :token_expires_at,
      :process_instance_id,
      :connection_generation,
      :tenant_id,
      :group_id,
      :managed_compute,
      :workload_id,
      :workload_generation,
      :workload_owner,
      :owner_user_id,
      :scope,
      :last_peer_heartbeat_ms,
      :disconnect_error,
      control_pending: nil,
      control_job: nil,
      control_retry_timer: nil,
      request_tasks: %{},
      stream_tasks: %{},
      meeting_events: %{
        active: nil,
        active_event_id: nil,
        event_ids: MapSet.new(),
        queue: {[], []}
      },
      pending: %{},
      read_streams: %{},
      read_stream_cancellations: %{},
      write_streams: %{},
      tunnels: %{},
      relay_challenge: nil,
      relay: nil,
      task_index_window: nil
    ]
  end

  @impl true
  def init(opts) do
    env_id = Keyword.fetch!(opts, :env_id)
    connection_generation = Keyword.fetch!(opts, :connection_generation)

    state = %State{
      env_id: env_id,
      disconnect_error: Keyword.get(opts, :disconnect_error, :disconnected),
      connector_run_id: Keyword.fetch!(opts, :connector_run_id),
      device_id: Keyword.get(opts, :device_id),
      connector_id: Keyword.get(opts, :connector_id),
      credential_generation: Keyword.get(opts, :credential_generation),
      token_expires_at: Keyword.get(opts, :token_expires_at),
      process_instance_id: Keyword.get(opts, :process_instance_id),
      connection_generation: connection_generation,
      tenant_id: Keyword.get(opts, :tenant_id),
      group_id: Keyword.get(opts, :group_id),
      managed_compute: Keyword.get(opts, :managed_compute, false),
      workload_id: Keyword.get(opts, :workload_id),
      workload_generation: Keyword.get(opts, :workload_generation),
      workload_owner: Keyword.get(opts, :workload_owner),
      owner_user_id: Keyword.get(opts, :owner_user_id),
      scope: Keyword.get(opts, :scope),
      last_peer_heartbeat_ms: monotonic_ms()
    }

    owner_scope =
      cond do
        state.managed_compute and
            Enum.all?([state.tenant_id, state.group_id, state.device_id], &is_binary/1) ->
          Map.take(state, [
            :tenant_id,
            :group_id,
            :device_id,
            :workload_id,
            :workload_generation,
            :connector_run_id
          ])

        state.managed_compute ->
          :invalid_managed_scope

        true ->
          :unmanaged
      end

    case SalixEnv.Bridge.register_owner(env_id, owner_scope) do
      :ok ->
        # Admission recheck AFTER owner registration.  Revocation first
        # advances the device's durable generation fence, so every
        # interleaving either stops this exact registered owner or observes
        # the fenced generation here and never serves.
        token_hash = Keyword.get(opts, :token_hash)

        cond do
          SalixCluster.NodeLifecycle.draining?() ->
            {:stop, {:shutdown, :connector_draining}, state}

          is_binary(token_hash) and not socket_credential_active?(token_hash, state) ->
            {:stop, {:shutdown, :connector_token_revoked}, state}

          true ->
            finish_admitted_init(env_id, opts, state)
        end

      {:error, reason} ->
        Logger.warning(
          "connector socket owner registration failed: env=#{env_id} #{inspect(reason)}"
        )

        {:stop, {:shutdown, {:owner_not_replaced, env_id, reason}}, state}
    end
  end

  defp socket_credential_active?(token_hash, state) do
    SalixEnv.ConnectorTokens.credential_active?(token_hash) and
      match?({:ok, true}, run_active(state))
  end

  defp run_active(state) do
    Registry.connector_run_active?(
      state.tenant_id,
      state.group_id,
      state.device_id,
      state.connector_run_id,
      state.connection_generation
    )
  end

  # It may invite the station to its Task, which waits on the station: not here.
  # The station takes the Task with the account it is lent, so it is sent its
  # profiles first.
  defp sandbox_connected(state) do
    connection = station_connection(state)

    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
      case SalixWeb.StationProfiles.push(connection) do
        :ok ->
          :ok

        error ->
          Logger.warning(
            "station profiles not sent: run=#{connection.connector_run_id} #{inspect(error)}"
          )
      end

      SalixWeb.CodingSandboxes.connected(connection)
    end)
  end

  defp finish_admitted_init(env_id, opts, state) do
    schedule_heartbeat()
    schedule_token_expiry(state.token_expires_at)

    SalixWeb.ConnectorRecovery.notify_ready(%{
      connector_run_id: state.connector_run_id,
      tenant_id: state.tenant_id,
      group_id: state.group_id,
      device_id: state.device_id,
      process_instance_id: state.process_instance_id
    })

    Logger.info("connector socket up: env=#{env_id} group=#{state.group_id} node=#{node()}")

    # The station proves its iroh endpoint id against this challenge to use Salix as its relay of last resort.
    challenge = SalixWeb.StationRelay.challenge()

    # A Workload's station is given the workspace's accounts it runs with, once it is connected,
    # and is placed in its Group's station roster (SalixWeb.StationPlace).
    if state.managed_compute do
      # A coding Task's sandbox is reached through Salix only, not placed in a
      # roster; its Task is told it is up (`SalixWeb.CodingSandboxes`).
      if state.workload_owner == "coding_task" do
        sandbox_connected(state)
      else
        send(self(), :push_station_profiles)
        send(self(), :push_station_place)
      end
    end

    {:push,
     {:text,
      Protocol.encode(%{
        "type" => "connected",
        "connector_run_id" => state.connector_run_id,
        "device_id" => state.device_id,
        "connector_id" => state.connector_id,
        "owner_user_id" => state.owner_user_id,
        "connection_generation" => state.connection_generation,
        "relay_challenge" => challenge,
        # A run admitted by a connector credential may present the device's next one.
        "credential_renewal" => is_binary(Keyword.get(opts, :token_hash))
      })}, %{state | relay_challenge: challenge}}
  end

  defp push_station_profiles(state) do
    connection = station_connection(state)
    run = connection.connector_run_id

    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.ConnectorRequestTaskSupervisor, fn ->
      case SalixWeb.StationProfiles.push(connection) do
        :ok -> :ok
        error -> Logger.warning("station profiles not sent: run=#{run} #{inspect(error)}")
      end
    end)
  end

  # The station of this run, as SalixWeb.StationProfiles lends to it: a Workload's, or its owner's device station.
  defp station_connection(%State{managed_compute: true} = state),
    do:
      Map.take(state, [
        :tenant_id,
        :group_id,
        :device_id,
        :connector_run_id,
        :workload_id,
        :workload_generation
      ])

  defp station_connection(state),
    do: Map.take(state, [:tenant_id, :group_id, :device_id, :connector_run_id, :owner_user_id])

  defp push_station_place(state) do
    connection =
      Map.take(state, [
        :tenant_id,
        :group_id,
        :connector_run_id,
        :connector_id,
        :workload_id,
        :workload_generation,
        :device_id
      ])

    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.ConnectorRequestTaskSupervisor, fn ->
      SalixWeb.StationPlace.push(connection)
    end)
  end

  # ---- frames from the connector ----

  @impl true
  def handle_in({frame, [opcode: :text]}, state) do
    case Protocol.decode(frame) do
      {:ok, message} -> handle_message(message, state)
      {:error, _} -> {:ok, state}
    end
  end

  # Binary frames are iroh packets for Salix to forward (SalixWeb.StationRelay).
  def handle_in({data, [opcode: :binary]}, state),
    do: {:ok, %{state | relay: SalixWeb.StationRelay.outgoing(state.relay, data)}}

  def handle_in({_data, [opcode: _other]}, state), do: {:ok, state}

  defp handle_message(%{"type" => "metadata"} = m, state) do
    # Refresh the durable record's surface (capabilities / skills / system info)
    # so env.list, /v1/environments, and the dashboards reflect what the
    # connector advertises. System info also stamps its own last-update time.
    case metadata_patch(m, state) do
      {:ok, patch} ->
        {:ok, enqueue_control(%{kind: :metadata, patch: patch}, state)}

      {:error, _invalid_metadata} ->
        Salix.Telemetry.emit_operation("salix_env", "connector_metadata", "system", "error", 0)
        {:ok, state}
    end
  end

  defp handle_message(%{"type" => "heartbeat"}, state) do
    state = %{state | last_peer_heartbeat_ms: monotonic_ms()}
    {:ok, enqueue_control(%{kind: :heartbeat}, state)}
  end

  # Connector-originated runtime/meeting lanes are refused for scoped runs
  # before any specific handler can match: a local_file_read connector may
  # exchange metadata, heartbeats, and read_ref stream frames — nothing else.
  defp handle_message(
         %{"type" => "request", "method" => method, "id" => id},
         %State{scope: "local_file_read"} = state
       )
       when is_binary(id) and
              method in ~w(runtime_subscription_access runtime_proxy agent_runtime_catchup meeting_runtime_event meeting_runtime_capabilities task.post task.hello task.file task.index task.app_deploy task.app_logs relay_register) do
    reply = %{
      "id" => id,
      "type" => "error",
      "error" => "connector scope forbids #{method}"
    }

    {:push, {:text, Protocol.encode(reply)}, state}
  end

  defp handle_message(
         %{"type" => "request", "method" => "runtime_proxy", "id" => id} = m,
         state
       )
       when is_binary(id) do
    params = m["params"] || %{}
    view = task_view(state)
    start_request_reply(id, state, fn -> runtime_proxy_reply(id, params, view) end)
  end

  # A Connector still asks for external-runtime input catch-up after it
  # connects. External Sessions are retired, so there is no input to catch up.
  defp handle_message(
         %{"type" => "request", "method" => "agent_runtime_catchup", "id" => id},
         state
       )
       when is_binary(id) do
    reply = %{"id" => id, "type" => "response", "result" => %{"accepted" => true}}
    {:push, {:text, Protocol.encode(reply)}, state}
  end

  defp handle_message(
         %{"type" => "request", "method" => "relay_register", "id" => id} = m,
         state
       )
       when is_binary(id) do
    scope = {state.tenant_id, state.group_id}

    case SalixWeb.StationRelay.register(
           state.connector_run_id,
           state.relay_challenge,
           m["params"] || %{},
           scope
         ) do
      {:ok, relay} ->
        reply = %{"id" => id, "type" => "response", "result" => %{"ok" => true}}

        # A device's run is a station's once it proves one: it is given the workspace's accounts then, without
        # placement. A Workload's station was given them at connect.
        if is_nil(state.relay) and state.managed_compute != true,
          do: send(self(), :push_station_profiles)

        # The proven endpoint id is the station's id: the Device records which station it runs.
        patch = %{"station_id" => SalixWeb.StationTaskIndex.station_id(relay)}

        SalixStore.StationDeviceLookup.record(
          state.tenant_id,
          state.group_id,
          state.device_id,
          patch["station_id"],
          state.owner_user_id
        )

        state = enqueue_control(%{kind: :metadata, patch: patch}, %{state | relay: relay})
        {:push, {:text, Protocol.encode(reply)}, state}

      {:error, reason} ->
        reply = %{"id" => id, "type" => "error", "error" => to_string(reason)}
        {:push, {:text, Protocol.encode(reply)}, state}
    end
  end

  # The station presents the device's next connector credential on this socket
  # before the one the run holds expires. Electron Main minted it with the
  # user's Session, as for a new connection; the run, its socket and its work
  # stay, and the socket then closes when the new credential expires.
  defp handle_message(
         %{"type" => "request", "method" => "connector_credential_renew", "id" => id} = m,
         state
       )
       when is_binary(id) do
    {reply, state} =
      case renew_credential(get_in(m, ["params", "token"]), state) do
        {:ok, state} ->
          {%{
             "id" => id,
             "type" => "response",
             "result" => %{"expires_at" => state.token_expires_at}
           }, state}

        {:error, reason} ->
          Logger.warning(
            "connector credential not renewed: env=#{state.env_id} reason=#{renewal_reason(reason)}"
          )

          {%{"id" => id, "type" => "error", "error" => "connector credential not renewed"}, state}
      end

    {:push, {:text, Protocol.encode(reply)}, state}
  end

  # A Workload's station, or a station this device's run proved, asks for what Salix lends it of the workspace's
  # accounts (SalixWeb.StationProfiles).
  defp handle_message(
         %{"type" => "request", "method" => "share." <> _ = method, "id" => id} = m,
         %State{managed_compute: managed, relay: relay} = state
       )
       when is_binary(id) and (managed == true or not is_nil(relay)) do
    connection = station_connection(state)

    start_request_reply(id, state, fn owner ->
      result =
        if managed do
          SalixWeb.StationProfiles.handle(connection, owner, method, m["params"] || %{})
        else
          SalixWeb.StationProfiles.handle(connection, method, m["params"] || %{})
        end

      case result do
        {:ok, result} -> %{"id" => id, "type" => "response", "result" => result}
        {:error, reason} -> %{"id" => id, "type" => "error", "error" => reason}
      end
    end)
  end

  # A Task kept here that a Session of this device's station takes part in
  # (`SalixWeb.StationTasks`).
  defp handle_message(
         %{"type" => "request", "method" => method, "id" => id} = m,
         state
       )
       when is_binary(id) and method in ["task.post", "task.hello", "task.file"] do
    params = m["params"] || %{}
    # A post's files are read back over this connection (`task.posted_file`).
    view = station_connection(state)

    start_request_reply(id, state, fn ->
      result =
        case method do
          "task.hello" -> SalixWeb.StationTasks.hello(view, params)
          "task.file" -> SalixWeb.StationTasks.file(view, params)
          "task.post" -> SalixWeb.StationTasks.post(view, params)
        end

      case result do
        {:ok, result} -> %{"id" => id, "type" => "response", "result" => result}
        {:error, reason} -> %{"id" => id, "type" => "error", "error" => inspect(reason)}
      end
    end)
  end

  # A Mini App build Task's Session deploys its app, or reads its logs
  # (`SalixWeb.StationTasks.app_deploy/2`). A deploy reads its files back over
  # this connection (`task.posted_file`) and uploads them, so it has longer.
  defp handle_message(
         %{"type" => "request", "method" => method, "id" => id} = m,
         state
       )
       when is_binary(id) and method in ["task.app_deploy", "task.app_logs"] do
    params = m["params"] || %{}
    view = station_connection(state)

    start_request_reply(
      id,
      state,
      fn ->
        result =
          case method do
            "task.app_deploy" -> SalixWeb.StationTasks.app_deploy(view, params)
            "task.app_logs" -> SalixWeb.StationTasks.app_logs(view, params)
          end

        case result do
          {:ok, result} -> %{"id" => id, "type" => "response", "result" => result}
          {:error, reason} -> %{"id" => id, "type" => "error", "error" => inspect(reason)}
        end
      end,
      if(method == "task.app_deploy", do: @app_deploy_timeout_ms)
    )
  end

  # A page of the station's Task index (`SalixWeb.StationTaskIndex`), from
  # the station this run proved with `relay_register`.
  defp handle_message(%{"type" => "request", "method" => "task.index", "id" => id} = m, state)
       when is_binary(id) do
    case SalixWeb.StationTaskIndex.admit(state.task_index_window, monotonic_ms()) do
      {:ok, window} ->
        station_id = SalixWeb.StationTaskIndex.station_id(state.relay)
        view = station_connection(state)
        params = m["params"] || %{}

        start_request_reply(id, %{state | task_index_window: window}, fn ->
          case SalixWeb.StationTaskIndex.receive_page(station_id, view, params) do
            {:ok, held} -> %{"id" => id, "type" => "response", "result" => held}
            {:error, reason} -> %{"id" => id, "type" => "error", "error" => to_string(reason)}
          end
        end)

      {:error, reason} ->
        reply = %{"id" => id, "type" => "error", "error" => to_string(reason)}
        {:push, {:text, Protocol.encode(reply)}, state}
    end
  end

  defp handle_message(
         %{"type" => "request", "method" => "meeting_runtime_event", "id" => id} = m,
         state
       )
       when is_binary(id) do
    enqueue_meeting_event(id, m["params"] || %{}, state)
  end

  defp handle_message(
         %{"type" => "request", "method" => "meeting_runtime_capabilities", "id" => id},
         state
       )
       when is_binary(id) do
    {:push,
     {:text,
      Protocol.encode(%{
        "id" => id,
        "type" => "response",
        "result" => %{"artifact_transport_versions" => ["opaque-v1"]}
      })}, state}
  end

  defp handle_message(
         %{"type" => "stream", "id" => id, "stream" => %{"channel" => channel} = stream} = m,
         state
       )
       when is_binary(id) and channel in @tunnel_channels do
    case state.tunnels[id] do
      %{relay: relay} = tunnel ->
        frame = Map.take(stream, ~w(channel data eof seq))
        frame = if present?(m["error"]), do: Map.put(frame, "error", m["error"]), else: frame
        send(relay, {:env_tunnel_frame, id, frame})

        if frame["eof"] == true,
          do: {:ok, drop_tunnel(state, id, tunnel)},
          else: {:ok, state}

      nil ->
        {:ok, state}
    end
  end

  defp handle_message(%{"type" => "stream", "id" => id, "stream" => stream} = m, state)
       when is_binary(id) and is_map(stream) do
    handle_stream_frame(id, stream, m["error"], state)
  end

  defp handle_message(
         %{"type" => "request", "method" => "runtime_subscription_access", "id" => id} = m,
         state
       ) do
    view = task_view(state)

    start_request_reply(id, state, fn ->
      # Only fixed errors leave this boundary. Never serialize credential exceptions.
      result =
        try do
          SalixWeb.SubscriptionRuntimeAuth.access(view, m["params"] || %{})
        rescue
          _ -> {:error, :subscription_access_unavailable}
        catch
          _, _ -> {:error, :subscription_access_unavailable}
        end

      case result do
        {:ok, access} -> %{"id" => id, "type" => "response", "result" => access}
        _ -> %{"id" => id, "type" => "error", "error" => "subscription_access_unavailable"}
      end
    end)
  end

  defp handle_message(%{"type" => "response_chunk", "id" => id} = m, state) when is_binary(id) do
    case state.pending[id] do
      %{chunks: %ConnectorResponseChunks{} = chunks} = entry ->
        case ConnectorResponseChunks.add(chunks, m["seq"], m["data_b64"]) do
          {:ok, chunks} ->
            entry = entry |> Map.put(:chunks, chunks) |> renew_chunk_idle(id)
            {:ok, %{state | pending: Map.put(state.pending, id, entry)}}

          {:error, reason} ->
            complete_pending(id, {:error, reason}, state, false)
        end

      # A late frame of a request that already ended.
      _ ->
        {:ok, state}
    end
  end

  defp handle_message(%{"id" => id} = m, state) when is_binary(id) do
    cond do
      Map.has_key?(state.write_streams, id) and (m["type"] == "error" or present?(m["error"])) ->
        complete_write_stream_error(id, m["error"] || "connector error", state)

      Map.has_key?(state.read_streams, id) and (m["type"] == "error" or present?(m["error"])) ->
        complete_read_stream_error(id, m["error"] || "connector error", state)

      Map.has_key?(state.write_streams, id) ->
        complete_write_stream_success(id, state)

      Map.has_key?(state.read_streams, id) ->
        {:ok, state}

      Map.has_key?(state.tunnels, id) and (m["type"] == "error" or present?(m["error"])) ->
        state = drop_tunnel(state, id, state.tunnels[id])
        complete_pending(id, Protocol.outcome(m), state, true)

      true ->
        complete_pending(
          id,
          chunked_outcome(state.pending[id], m),
          state,
          m["type"] in ["response", "error"]
        )
    end
  end

  defp handle_message(_other, state), do: {:ok, state}

  # The final frame of a chunked request carries the body's checks.
  defp chunked_outcome(%{chunks: %ConnectorResponseChunks{} = chunks}, m) do
    case Protocol.outcome(m) do
      {:ok, result} -> ConnectorResponseChunks.finish(chunks, result)
      error -> error
    end
  end

  defp chunked_outcome(_entry, m), do: Protocol.outcome(m)

  defp runtime_proxy_reply(id, params, state) do
    safe_request_reply(id, fn ->
      meta = %{"tenant_id" => state.tenant_id, "group_id" => state.group_id}
      RuntimeProxy.handle(state.connector_run_id, params, meta)
    end)
  end

  defp safe_request_reply(id, reply_fun) do
    case reply_fun.() do
      {:ok, result} ->
        %{"id" => id, "type" => "response", "result" => result}

      {:error, reason} ->
        %{"id" => id, "type" => "error", "error" => format_error(reason)}
    end
  rescue
    e -> %{"id" => id, "type" => "error", "error" => format_error(Exception.message(e))}
  catch
    kind, reason -> %{"id" => id, "type" => "error", "error" => format_error({kind, reason})}
  end

  # Request and control tasks read the connection identity. They get the
  # state without this actor's bookkeeping of other requests and streams.
  defp task_view(%State{} = state) do
    %State{
      state
      | control_pending: nil,
        control_job: nil,
        control_retry_timer: nil,
        request_tasks: %{},
        stream_tasks: %{},
        meeting_events: %State{}.meeting_events,
        pending: %{},
        read_streams: %{},
        read_stream_cancellations: %{},
        write_streams: %{}
    }
  end

  defp start_request_reply(id, state, reply_fun, timeout_ms \\ nil) do
    if map_size(state.request_tasks) >= socket_request_task_limit() do
      push_request_overload(id, state)
    else
      # Admission happens in the operation worker, not when its asynchronous
      # callback was queued. Pass one snapshot to grant-producing handlers.
      guarded = fn ->
        result =
          if state.managed_compute do
            SalixEnv.StationConnection.with_current(station_connection(state), fn owner ->
              invoke_reply(reply_fun, owner)
            end)
          else
            invoke_reply(reply_fun, :unmanaged)
          end

        case result do
          {:error, reason} -> %{"id" => id, "type" => "error", "error" => inspect(reason)}
          reply -> reply
        end
      end

      {:ok, next_state, _token} = start_request_task(id, :request, state, guarded, timeout_ms)
      {:ok, next_state}
    end
  end

  defp invoke_reply(reply_fun, owner) when is_function(reply_fun, 1), do: reply_fun.(owner)
  defp invoke_reply(reply_fun, _owner), do: reply_fun.()

  defp start_request_task(id, kind, state, reply_fun, timeout_ms) do
    token = SystemsRuntime.Proc.make_ref()
    socket = self()

    starter =
      start_socket_task(
        SalixWeb.ConnectorRequestTaskSupervisor,
        :request,
        token,
        fn ->
          encoded = encode_request_reply(id, reply_fun)
          send(socket, {:request_task_complete, token, encoded})
        end
      )

    timer =
      SystemsClock.send_after(
        self(),
        {:connector_task_timeout, :request, token},
        timeout_ms || request_task_timeout_ms(kind)
      )

    task =
      Map.merge(starter, %{pid: nil, monitor: nil, timer: timer, id: id, kind: kind})

    {:ok, %{state | request_tasks: Map.put(state.request_tasks, token, task)}, token}
  end

  defp encode_request_reply(id, reply_fun) do
    reply_fun.() |> Protocol.encode()
  rescue
    error ->
      Protocol.encode(%{
        "id" => id,
        "type" => "error",
        "error" => "server reply encoding failed: #{Exception.message(error)}"
      })
  catch
    kind, reason ->
      Protocol.encode(%{
        "id" => id,
        "type" => "error",
        "error" => "server reply encoding failed: #{format_error({kind, reason})}"
      })
  end

  defp enqueue_meeting_event(id, params, state) do
    event_id = meeting_runtime_event_id(params)
    item = %{request_id: id, params: params, event_id: event_id}
    lane = state.meeting_events

    cond do
      is_binary(event_id) and MapSet.member?(lane.event_ids, event_id) ->
        push_meeting_event_duplicate(id, state)

      not is_nil(lane.active) ->
        if :queue.len(lane.queue) >= meeting_event_queue_limit() do
          push_request_overload(id, state)
        else
          lane =
            lane
            |> put_meeting_event_id(event_id)
            |> Map.put(:queue, :queue.in(item, lane.queue))

          {:ok, put_meeting_event_lane(state, lane)}
        end

      true ->
        start_meeting_event(item, state)
    end
  end

  defp start_meeting_event(%{request_id: id, params: params, event_id: event_id}, state) do
    if map_size(state.request_tasks) >= socket_request_task_limit() do
      push_request_overload(id, state)
    else
      {:ok, next_state, token} =
        start_request_task(
          id,
          :meeting_event,
          state,
          fn ->
            meeting_runtime_event_reply(id, params, meeting_ctx(state))
          end,
          meeting_event_timeout_ms(params)
        )

      lane = next_state.meeting_events

      lane =
        lane
        |> put_meeting_event_id(event_id)
        |> Map.put(:active, token)
        |> Map.put(:active_event_id, event_id)

      {:ok, put_meeting_event_lane(next_state, lane)}
    end
  end

  defp advance_meeting_events(state) do
    lane = state.meeting_events

    lane =
      lane
      |> drop_meeting_event_id(lane.active_event_id)
      |> Map.put(:active, nil)
      |> Map.put(:active_event_id, nil)

    state = put_meeting_event_lane(state, lane)

    case :queue.out(lane.queue) do
      {{:value, item}, queue} ->
        lane =
          lane
          |> drop_meeting_event_id(item.event_id)
          |> Map.put(:queue, queue)

        state = put_meeting_event_lane(state, lane)

        case start_meeting_event(item, state) do
          {:ok, next_state} ->
            next_state

          {:push, {:text, encoded}, next_state} ->
            send(self(), {:push_encoded_frame, encoded})
            advance_meeting_events(next_state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp put_meeting_event_lane(state, lane), do: %{state | meeting_events: lane}

  defp put_meeting_event_id(lane, event_id) when is_binary(event_id),
    do: %{lane | event_ids: MapSet.put(lane.event_ids, event_id)}

  defp put_meeting_event_id(lane, _event_id), do: lane

  defp drop_meeting_event_id(lane, event_id) when is_binary(event_id),
    do: %{lane | event_ids: MapSet.delete(lane.event_ids, event_id)}

  defp drop_meeting_event_id(lane, _event_id), do: lane

  defp meeting_runtime_event_id(%{"event" => %{"event_id" => event_id}})
       when is_binary(event_id) do
    if String.trim(event_id) == "", do: nil, else: event_id
  end

  defp meeting_runtime_event_id(_params), do: nil

  defp request_task_timeout_ms(:meeting_event),
    do: SystemsRuntime.get_env(:salix_web, :connector_meeting_event_task_timeout_ms, 120_000)

  defp request_task_timeout_ms(_kind),
    do: SystemsRuntime.get_env(:salix_web, :connector_request_task_timeout_ms, 60_000)

  @doc false
  def meeting_event_timeout_ms(params) do
    configured = request_task_timeout_ms(:meeting_event)
    contract = SalixEnv.Protocol.meeting_artifact_timeout_contract()

    child_budgets =
      Enum.map(bounded_meeting_artifact_sizes(params), fn size ->
        SalixEnv.Protocol.meeting_artifact_request_timeout(%{"expected_size" => size})
      end)

    max(configured, contract.finalize_ms + contract.server_slop_ms + Enum.sum(child_budgets))
  end

  defp meeting_event_queue_limit,
    do: SystemsRuntime.get_env(:salix_web, :connector_meeting_event_queue_limit, 64)

  defp push_request_overload(id, state) do
    reply = %{"id" => id, "type" => "error", "error" => "server request capacity exhausted"}
    {:push, {:text, Protocol.encode(reply)}, state}
  end

  defp push_meeting_event_duplicate(id, state) do
    reply = %{
      "id" => id,
      "type" => "error",
      "error" => "meeting runtime event already queued"
    }

    {:push, {:text, Protocol.encode(reply)}, state}
  end

  defp start_socket_task(supervisor, lane, token, fun) do
    socket = self()

    case SalixWeb.ConnectorTaskAdmission.acquire(lane, socket) do
      {:ok, admission} ->
        {starter_pid, starter_monitor} =
          spawn_monitor(fn ->
            result =
              start_supervised_task(supervisor, fn ->
                await_task_authorization(socket, {:socket_task_ready, lane, token}, token, fun)
              end)

            send(socket, {:socket_task_started, lane, token, result})
          end)

        SalixWeb.ConnectorTaskAdmission.track(admission, starter_pid)

        %{
          starter_pid: starter_pid,
          starter_monitor: starter_monitor,
          admission: admission
        }

      {:error, :overloaded} ->
        send(socket, {:socket_task_started, lane, token, {:error, :overloaded}})
        %{starter_pid: nil, starter_monitor: nil, admission: nil}
    end
  end

  defp socket_request_task_limit,
    do: SystemsRuntime.get_env(:salix_web, :connector_socket_request_task_limit, 8)

  # A socket may accept `read_stream_limit/0` independent streams. Give each
  # accepted stream one frame-consumer slot by default so an ordinary burst is
  # not rejected by a lower, contradictory per-socket limit. The app-wide
  # admission counter remains the hard cross-socket bound.
  defp socket_stream_task_limit,
    do:
      SystemsRuntime.get_env(:salix_web, :connector_socket_stream_task_limit, read_stream_limit())

  defp drop_tunnel(state, id, %{monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    %{state | tunnels: Map.delete(state.tunnels, id)}
  end

  defp tunnel_limit, do: SystemsRuntime.get_env(:salix_web, :connector_socket_tunnel_limit, 8)

  # Server-authoritative capability gate derived from the connector token's
  # scope at connect time. A local_file_read connector may only serve the
  # read_ref transport; every other inbound method is refused here regardless
  # of what the connector binary would accept.
  defp scope_permits_method?("local_file_read", method), do: method == "read_ref"
  defp scope_permits_method?(_scope, _method), do: true

  defp read_stream_credential_active?(
         %State{scope: "local_file_read", credential_generation: generation} = state,
         %{"method" => "read_ref"}
       )
       when is_integer(generation) and generation > 0 do
    case run_active(state) do
      {:ok, active?} -> active?
      {:error, _} -> false
    end
  end

  defp read_stream_credential_active?(%State{scope: "local_file_read"}, %{"method" => "read_ref"}),
       do: false

  defp read_stream_credential_active?(_state, _message), do: true

  # The credential a run holds bounds it, not only future connects: the socket
  # closes itself when that credential expires, so a WebSocket cannot keep
  # serving without a credential minted with the user's Session at least once
  # per credential lifetime. A renewal moves the bound to the new credential.
  defp schedule_token_expiry(expires_at) when is_integer(expires_at) do
    delay_ms = max(expires_at - SystemsClock.system_time(:second), 0) * 1_000
    SystemsClock.send_after(self(), {:connector_token_expired, expires_at}, delay_ms)
    :ok
  end

  defp schedule_token_expiry(_expires_at), do: :ok

  # Only the device's newest credential, for this run's own device and scope,
  # replaces the one the run holds; `SalixEnv.Registry.renew_run_credential/6`
  # checks both against the device record in one write.
  defp renew_credential(
         token,
         %State{managed_compute: false, credential_generation: held} = state
       )
       when is_binary(token) and token != "" and is_integer(held) do
    with {:ok, tenant_id, record} <- SalixEnv.ConnectorTokens.validate_connector_token(token),
         :ok <- same_device_credential(tenant_id, record, state),
         :ok <- SalixEnv.ConnectorTokens.admit_registration(record["token_hash"]),
         {:ok, _device} <-
           Registry.renew_run_credential(
             state.tenant_id,
             state.group_id,
             state.device_id,
             state.connector_run_id,
             state.connection_generation,
             record
           ) do
      schedule_token_expiry(record["expires_at"])

      {:ok,
       %{
         state
         | connector_id: record["connector_id"],
           credential_generation: record["credential_generation"],
           token_expires_at: record["expires_at"]
       }}
    end
  end

  defp renew_credential(_token, _state), do: {:error, :credential_not_renewable}

  defp same_device_credential(tenant_id, record, state) do
    if tenant_id == state.tenant_id and record["group_id"] == state.group_id and
         record["device_id"] == state.device_id and
         (record["scope"] || "") == (state.scope || ""),
       do: :ok,
       else: {:error, :credential_not_renewable}
  end

  # Never log what came with the frame: only this module's own reasons.
  defp renewal_reason(reason) when is_atom(reason), do: reason
  defp renewal_reason({:ambiguous, _}), do: :ambiguous
  defp renewal_reason(_reason), do: :other

  defp pending_rpc_limit do
    case SystemsRuntime.get_env(:salix_web, :connector_socket_pending_rpc_limit, 256) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 256
    end
  end

  defp chunked_request?(%{"method" => method, "params" => %{"response_mode" => "chunks"}}),
    do: method in ["http_request", "lan_http_request"]

  defp chunked_request?(_message), do: false

  defp chunked_pending_count(state),
    do: Enum.count(state.pending, fn {_id, entry} -> entry[:chunks] != nil end)

  # A chunked request buffers up to 4 MiB until its final frame, so only a few
  # may be open on one socket at a time.
  defp chunked_response_limit do
    case SystemsRuntime.get_env(:salix_web, :connector_chunked_response_limit, 2) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 2
    end
  end

  # The gap allowed between frames.
  defp chunk_idle_timeout_ms do
    case SystemsRuntime.get_env(:salix_web, :connector_chunk_idle_timeout_ms, 20_000) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 20_000
    end
  end

  defp put_chunks(entry, message, id) do
    if chunked_request?(message) do
      max_bytes =
        case message["params"]["max_bytes"] do
          n when is_integer(n) and n > 0 -> min(n, @max_chunked_response_bytes)
          _ -> @max_chunked_response_bytes
        end

      entry
      |> Map.put(:chunks, ConnectorResponseChunks.new(max_bytes))
      |> renew_chunk_idle(id, first_chunk_timeout_ms(message["params"]))
    else
      entry
    end
  end

  # The gateway sends its first frame only after it has read the whole HTTP
  # body, so the wait for it is the request's own budget, as
  # `SalixEnv.Protocol.timeout/2` counts it for `timeout_seconds`, and at least
  # the gap allowed between frames.
  defp first_chunk_timeout_ms(%{"timeout_seconds" => secs}) when is_integer(secs) and secs > 0,
    do: max(chunk_idle_timeout_ms(), secs * 1000 + 5_000)

  defp first_chunk_timeout_ms(_params),
    do: max(chunk_idle_timeout_ms(), @default_chunked_http_seconds * 1000 + 5_000)

  defp renew_chunk_idle(entry, id, ms \\ chunk_idle_timeout_ms()) do
    case entry[:chunk_idle] do
      {timer, _lease} -> SystemsClock.cancel_timer(timer)
      nil -> :ok
    end

    lease = SystemsRuntime.Proc.make_ref()

    timer =
      SystemsClock.send_after(
        self(),
        {:connector_chunk_idle_timeout, id, lease},
        ms
      )

    entry |> Map.put(:chunk_idle, {timer, lease}) |> Map.put(:chunk_wait_ms, ms)
  end

  defp pending_rpc_timeout_ms(message) do
    configured =
      SystemsRuntime.get_env(:salix_web, :connector_pending_rpc_absolute_timeout_ms, 120_000)

    method = message["method"] || ""
    params = if is_map(message["params"]), do: message["params"], else: %{}
    protocol_timeout = Protocol.timeout(method, params)

    case configured do
      value when is_integer(value) and value > 0 -> min(value, protocol_timeout)
      _ -> protocol_timeout
    end
  end

  defp read_stream_limit do
    case SystemsRuntime.get_env(:salix_web, :connector_socket_read_stream_limit, 16) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 16
    end
  end

  defp read_stream_absolute_timeout_ms(message) do
    configured =
      case SystemsRuntime.get_env(:salix_web, :connector_read_stream_absolute_timeout_ms, 300_000) do
        value when is_integer(value) and value > 0 -> value
        _invalid -> 300_000
      end

    case message["method"] do
      "read_ref" -> min(configured, Protocol.timeout("read_ref", message["params"] || %{}))
      _ -> configured
    end
  end

  defp write_stream_limit do
    case SystemsRuntime.get_env(:salix_web, :connector_socket_write_stream_limit, 16) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 16
    end
  end

  defp write_stream_timeout_ms do
    case SystemsRuntime.get_env(:salix_web, :connector_write_stream_idle_timeout_ms, 180_000) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 180_000
    end
  end

  defp start_supervised_task(supervisor, fun) do
    case SystemsRuntime.TaskSupervisor.start_child(supervisor, fun) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, :overloaded}
      {:error, reason} -> log_task_start_error(supervisor, reason)
    end
  catch
    :exit, reason -> log_task_start_error(supervisor, reason)
  end

  defp log_task_start_error(supervisor, reason) do
    Logger.warning(
      "connector task unavailable: supervisor=#{inspect(supervisor)} #{inspect(reason)}"
    )

    {:error, :overloaded}
  end

  defp meeting_ctx(state) do
    # Meeting artifact streaming uses the storage env id to route back to this
    # socket owner. Public connector identity still flows through connector_run_id.
    %{storage_env_id: state.env_id, tenant_id: state.tenant_id, group_id: state.group_id}
  end

  defp meeting_runtime_event_reply(id, params, ctx) do
    safe_request_reply(id, fn ->
      meta = %{"tenant_id" => ctx.tenant_id, "group_id" => ctx.group_id}

      handler =
        SystemsRuntime.get_env(
          :salix_web,
          :connector_meeting_runtime_handler,
          SalixWeb.MeetingRuntime
        )

      handler.handle_connector_event(ctx.storage_env_id, params, meta)
    end)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp complete_pending(id, outcome, state, count_late_reply?) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        if count_late_reply?, do: Salix.Telemetry.emit_connector_pending_rpc(:late_reply)
        {:ok, state}

      {%{from: from, ref: ref} = entry, rest} ->
        clear_pending_tracking(entry, true)
        send(from, {:env_rpc_reply, ref, outcome})
        Salix.Telemetry.emit_connector_pending_rpc(:completed)
        {:ok, %{state | pending: rest}}
    end
  end

  defp pop_pending_by_ref(pending, ref, from) do
    case Enum.find(pending, fn {_id, entry} -> entry.ref == ref and entry.from == from end) do
      nil ->
        {nil, pending}

      {id, entry} ->
        clear_pending_tracking(entry, true)
        {entry, Map.delete(pending, id)}
    end
  end

  defp pop_pending_by_monitor(pending, monitor) do
    case Enum.find(pending, fn {_id, entry} -> entry.caller_monitor == monitor end) do
      nil ->
        {nil, pending}

      {id, entry} ->
        clear_pending_tracking(entry, false)
        {entry, Map.delete(pending, id)}
    end
  end

  defp clear_pending_tracking(entry, demonitor?) do
    if entry.timer, do: SystemsClock.cancel_timer(entry.timer)

    case entry[:chunk_idle] do
      {timer, _lease} -> SystemsClock.cancel_timer(timer)
      nil -> :ok
    end

    if demonitor? and entry.caller_monitor,
      do: Process.demonitor(entry.caller_monitor, [:flush])

    :ok
  end

  defp complete_write_stream_error(id, reason, state) do
    case state.write_streams[id] do
      nil ->
        {:ok, state}

      info ->
        fail_write_stream_info(info, reason)
        Salix.Telemetry.emit_connector_write_stream(:error)
        {:ok, %{state | write_streams: Map.delete(state.write_streams, id)}}
    end
  end

  defp complete_write_stream_success(id, state) do
    case state.write_streams[id] do
      nil ->
        {:ok, state}

      %{begin: begin} = info when not is_nil(begin) ->
        info =
          info
          |> complete_write_phase(:begin, {:ok, %{"id" => id}})
          |> reset_write_stream_timeout(id)

        {:ok, %{state | write_streams: Map.put(state.write_streams, id, info)}}

      _info ->
        {:ok, state}
    end
  end

  defp complete_read_stream_error(id, reason, state) do
    case state.read_streams[id] do
      nil ->
        {:ok, state}

      info ->
        FrameStream.fail(info.receiver, reason)
        clear_read_stream_tracking(info)
        Salix.Telemetry.emit_connector_read_stream(:error)
        {:ok, %{state | read_streams: Map.delete(state.read_streams, id)}}
    end
  end

  defp handle_stream_frame(id, %{"channel" => "data"} = stream, _err, state) do
    case state.read_streams[id] do
      nil ->
        case Map.pop(state.read_stream_cancellations, id) do
          {nil, _rest} ->
            {:ok, state}

          {_closed_at, rest} ->
            state = %{state | read_stream_cancellations: rest}
            push_read_stream_error_ack(id, stream, "server stream consumer closed", state)
        end

      %{receiver: sender} ->
        if map_size(state.stream_tasks) >= socket_stream_task_limit() do
          fail_overloaded_read_stream(id, sender, stream, state)
        else
          token = SystemsRuntime.Proc.make_ref()
          socket = self()

          starter =
            start_socket_task(
              SalixWeb.ConnectorStreamTaskSupervisor,
              :stream,
              token,
              fn ->
                result = consume_read_stream_frame(sender, stream)
                send(socket, {:read_stream_frame_complete, token, result})
              end
            )

          timer =
            SystemsClock.send_after(
              self(),
              {:connector_task_timeout, :stream, token},
              read_stream_idle_timeout_ms()
            )

          task =
            Map.merge(starter, %{
              pid: nil,
              monitor: nil,
              timer: timer,
              id: id,
              sender: sender,
              stream: stream
            })

          {:ok, %{state | stream_tasks: Map.put(state.stream_tasks, token, task)}}
        end
    end
  end

  defp handle_stream_frame(id, %{"channel" => "ack"} = stream, err, state) do
    case state.write_streams[id] do
      nil ->
        {:ok, state}

      info ->
        error = stream_error(err, stream)

        reply =
          if is_nil(error) do
            :ok
          else
            {:error, error}
          end

        info = info |> complete_write_phase(:chunk, reply) |> reset_write_stream_timeout(id)
        {:ok, %{state | write_streams: Map.put(state.write_streams, id, info)}}
    end
  end

  defp handle_stream_frame(id, %{"channel" => "done"} = stream, err, state) do
    case state.write_streams[id] do
      nil ->
        {:ok, state}

      info ->
        case stream_error(err, stream) do
          nil ->
            info =
              complete_write_phase(
                info,
                :finish,
                {:ok, Map.merge(%{"ok" => true}, done_payload(stream))}
              )

            clear_write_stream_tracking(info)
            Salix.Telemetry.emit_connector_write_stream(:completed)
            {:ok, %{state | write_streams: Map.delete(state.write_streams, id)}}

          reason ->
            complete_write_stream_error(id, reason, state)
        end
    end
  end

  defp handle_stream_frame(_id, _stream, _err, state), do: {:ok, state}

  defp fail_overloaded_read_stream(id, sender, stream, state) do
    FrameStream.fail(sender, :connector_stream_capacity_exhausted)
    state = remove_read_stream(state, id, sender)
    Salix.Telemetry.emit_connector_read_stream(:saturated)
    push_read_stream_error_ack(id, stream, "server stream capacity exhausted", state)
  end

  # Durable connector metadata is owned and serialized by this socket actor.
  # The small starter process keeps a stalled Task.Supervisor call out of the
  # WebSocket reader; at most one starter/worker exists for this connection.
  defp enqueue_control(operation, state) do
    pending = merge_control(state.control_pending, operation)
    state |> Map.put(:control_pending, pending) |> start_control_if_idle()
  end

  defp start_control_if_idle(
         %State{control_job: nil, control_retry_timer: nil, control_pending: operation} = state
       )
       when not is_nil(operation) do
    token = SystemsRuntime.Proc.make_ref()
    socket = self()
    view = task_view(state)

    {starter, starter_monitor, admission} =
      case SalixWeb.ConnectorTaskAdmission.acquire(:control, socket) do
        {:ok, admission} ->
          {starter, starter_monitor} =
            spawn_monitor(fn ->
              result =
                start_supervised_task(SalixWeb.ConnectorControlTaskSupervisor, fn ->
                  await_task_authorization(socket, {:control_task_ready, token}, token, fn ->
                    result = safe_execute_control(operation, view)
                    send(socket, {:control_task_complete, token, self(), result})
                  end)
                end)

              send(socket, {:control_task_started, token, result})
            end)

          SalixWeb.ConnectorTaskAdmission.track(admission, starter)
          {starter, starter_monitor, admission}

        {:error, :overloaded} ->
          send(socket, {:control_task_started, token, {:error, :overloaded}})
          {nil, nil, nil}
      end

    timer =
      SystemsClock.send_after(
        self(),
        {:connector_task_timeout, :control, token},
        control_task_timeout_ms()
      )

    job = %{
      token: token,
      operation: operation,
      starter: starter,
      starter_monitor: starter_monitor,
      admission: admission,
      worker: nil,
      worker_monitor: nil,
      timer: timer
    }

    %{state | control_pending: nil, control_job: job}
  end

  defp start_control_if_idle(state), do: state

  defp merge_control(nil, incoming), do: incoming
  defp merge_control(current, nil), do: current
  defp merge_control(%{kind: :metadata} = current, %{kind: :heartbeat}), do: current
  defp merge_control(%{kind: :heartbeat}, %{kind: :metadata} = incoming), do: incoming
  defp merge_control(%{kind: :heartbeat}, %{kind: :heartbeat} = incoming), do: incoming

  defp merge_control(%{kind: :metadata} = current, %{kind: :metadata} = incoming) do
    %{incoming | patch: Map.merge(current.patch, incoming.patch)}
  end

  defp safe_execute_control(operation, state) do
    started = SystemsClock.monotonic_time()

    result =
      try do
        execute_control(operation, state)
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    kind = if operation.kind == :metadata, do: "connector_metadata", else: "connector_heartbeat"
    outcome = if control_success?(result), do: "ok", else: "error"

    Salix.Telemetry.emit_operation(
      "salix_env",
      kind,
      "system",
      outcome,
      SystemsClock.monotonic_time() - started
    )

    result
  end

  defp execute_control(operation, state) do
    case SystemsRuntime.get_env(:salix_web, :connector_control_executor) do
      fun when is_function(fun, 1) ->
        fun.(
          operation
          |> Map.put(:connector_run_id, state.connector_run_id)
          |> Map.put(:generation, state.connection_generation)
          |> Map.put(:owner_node, to_string(node()))
        )

      _ ->
        execute_registry_control(operation, state)
    end
  end

  defp execute_registry_control(%{kind: :metadata, patch: patch}, state) do
    result =
      Registry.update_meta(
        state.connector_run_id,
        &Map.merge(&1, patch),
        control_registry_opts(state)
      )

    if control_persisted?(result) and get_in(patch, ["capabilities", "runtime_auth_v1"]) == true do
      SalixWeb.SubscriptionRuntimeAuth.reconnect(state)
    end

    result
  end

  defp execute_registry_control(%{kind: :heartbeat}, state) do
    Registry.update_meta(state.connector_run_id, & &1, control_registry_opts(state))
  end

  defp control_registry_opts(state) do
    [connection_generation: state.connection_generation, owner_node: to_string(node())]
  end

  defp control_success?(:ok), do: true
  defp control_success?({:ok, _}), do: true
  defp control_success?({:error, :not_found}), do: true
  defp control_success?(_), do: false

  defp control_persisted?(:ok), do: true
  defp control_persisted?({:ok, _}), do: true
  defp control_persisted?(_), do: false

  defp control_task_timeout_ms,
    do: SystemsRuntime.get_env(:salix_web, :connector_control_task_timeout_ms, 30_000)

  defp control_retry_ms,
    do: SystemsRuntime.get_env(:salix_web, :connector_control_retry_ms, 1_000)

  # ---- messages from SalixEnv.Bridge / the heartbeat timer ----

  @impl true
  def handle_info(:push_station_profiles, state) do
    _ = push_station_profiles(state)
    {:ok, state}
  end

  def handle_info(:push_station_place, state) do
    _ = push_station_place(state)
    {:ok, state}
  end

  def handle_info({:station_relay_packet, from, scope, packet}, state) do
    case SalixWeb.StationRelay.incoming(state.relay, from, scope, packet) do
      nil -> {:ok, state}
      frame -> {:push, {:binary, frame}, state}
    end
  end

  def handle_info({:env_read_stream, ref, from, message}, state) do
    id = message["id"] || Protocol.new_id()
    message = Map.put(message, "id", id) |> Map.delete("transfer")

    cond do
      not scope_permits_method?(state.scope, message["method"]) ->
        send(from, {:env_read_stream_reply, ref, {:error, :connector_scope_forbidden}})
        {:ok, state}

      not read_stream_credential_active?(state, message) ->
        send(from, {:env_read_stream_reply, ref, {:error, :connector_credential_revoked}})
        {:stop, {:shutdown, :connector_token_revoked}, state}

      Map.has_key?(state.read_streams, id) or
          Map.has_key?(state.read_stream_cancellations, id) ->
        send(from, {:env_read_stream_reply, ref, {:error, :connector_read_stream_id_conflict}})
        Salix.Telemetry.emit_connector_read_stream(:conflict)
        {:ok, state}

      map_size(state.read_streams) >= read_stream_limit() ->
        send(
          from,
          {:env_read_stream_reply, ref, {:error, :connector_read_stream_capacity_exhausted}}
        )

        Salix.Telemetry.emit_connector_read_stream(:saturated)
        {:ok, state}

      true ->
        case FrameStream.start_link(
               max_buffered_chunks: 64,
               idle_timeout: read_stream_idle_timeout_ms(),
               owner: self(),
               id: id
             ) do
          {:ok, receiver} ->
            info = new_read_stream_info(id, receiver, from, ref, message)
            send(from, {:env_read_stream_reply, ref, {:ok, FrameStream.stream(receiver), nil}})

            state = %{
              state
              | read_streams: Map.put(state.read_streams, id, info),
                read_stream_cancellations: Map.delete(state.read_stream_cancellations, id)
            }

            Salix.Telemetry.emit_connector_read_stream(:accepted)
            {:push, {:text, Protocol.encode(message)}, state}

          {:error, reason} ->
            send(from, {:env_read_stream_reply, ref, {:error, reason}})
            Salix.Telemetry.emit_connector_read_stream(:error)
            {:ok, state}
        end
    end
  end

  def handle_info({:env_read_stream_cancel, ref, from}, state) do
    case pop_read_stream_by_ref(state.read_streams, ref, from) do
      {nil, nil, _read_streams} ->
        {:ok, state}

      {id, info, read_streams} ->
        FrameStream.cancel(info.receiver, :caller_cancelled)
        clear_read_stream_tracking(info)
        Salix.Telemetry.emit_connector_read_stream(:cancelled)

        {:ok,
         state
         |> Map.put(:read_streams, read_streams)
         |> remember_read_stream_cancellation(id)}
    end
  end

  def handle_info({:connector_read_stream_absolute_timeout, id, ref, token}, state) do
    case state.read_streams[id] do
      %{ref: ^ref, absolute_token: ^token} = info ->
        FrameStream.cancel(info.receiver, :stream_absolute_timeout)
        clear_read_stream_tracking(info)
        Salix.Telemetry.emit_connector_read_stream(:timeout)

        {:ok,
         state
         |> Map.put(:read_streams, Map.delete(state.read_streams, id))
         |> remember_read_stream_cancellation(id)}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:env_rpc, ref, from, message}, state) do
    id = message["id"] || Protocol.new_id()
    message = Map.put(message, "id", id) |> Map.delete("transfer")

    cond do
      not scope_permits_method?(state.scope, message["method"]) ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_scope_forbidden}})
        {:ok, state}

      map_size(state.pending) >= pending_rpc_limit() ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_pending_capacity_exhausted}})
        Salix.Telemetry.emit_connector_pending_rpc(:saturated)
        {:ok, state}

      Map.has_key?(state.pending, id) ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_pending_id_conflict}})
        Salix.Telemetry.emit_connector_pending_rpc(:conflict)
        {:ok, state}

      chunked_request?(message) and chunked_pending_count(state) >= chunked_response_limit() ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_chunked_capacity_exhausted}})
        Salix.Telemetry.emit_connector_pending_rpc(:saturated)
        {:ok, state}

      true ->
        caller_monitor = Process.monitor(from)

        timer =
          SystemsClock.send_after(
            self(),
            {:connector_pending_rpc_timeout, id, ref},
            pending_rpc_timeout_ms(message)
          )

        entry =
          %{from: from, ref: ref, caller_monitor: caller_monitor, timer: timer}
          |> put_chunks(message, id)

        pending = Map.put(state.pending, id, entry)

        Salix.Telemetry.emit_connector_pending_rpc(:accepted)
        {:push, {:text, Protocol.encode(message)}, %{state | pending: pending}}
    end
  end

  # A tunnel opens through an ordinary pending RPC (`lan_tcp_dial`) that
  # replies to `from`; its frames then pass between the connector and `relay`
  # by id. The relay owns flow control: this process only forwards frames.
  def handle_info({:env_tunnel_open, ref, from, relay, message}, state) do
    id = message["id"]

    cond do
      not is_binary(id) or Map.has_key?(state.tunnels, id) or Map.has_key?(state.pending, id) ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_tunnel_id_conflict}})
        {:ok, state}

      map_size(state.tunnels) >= tunnel_limit() ->
        send(from, {:env_rpc_reply, ref, {:error, :connector_tunnel_capacity_exhausted}})
        {:ok, state}

      true ->
        tunnel = %{relay: relay, monitor: Process.monitor(relay)}
        state = %{state | tunnels: Map.put(state.tunnels, id, tunnel)}

        case handle_info({:env_rpc, ref, from, message}, state) do
          {:push, _frame, _state} = pushed -> pushed
          {:ok, state} -> {:ok, drop_tunnel(state, id, tunnel)}
        end
    end
  end

  def handle_info({:env_tunnel_send, relay, id, frame}, state) when is_map(frame) do
    case state.tunnels[id] do
      %{relay: ^relay} = tunnel ->
        frame = Map.take(frame, ~w(channel data eof seq))
        push = {:text, Protocol.encode(%{"id" => id, "type" => "stream", "stream" => frame})}

        if frame["eof"] == true,
          do: {:push, push, drop_tunnel(state, id, tunnel)},
          else: {:push, push, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:env_rpc_cancel, ref, from}, state) do
    case pop_pending_by_ref(state.pending, ref, from) do
      {nil, _pending} ->
        {:ok, state}

      {_entry, pending} ->
        Salix.Telemetry.emit_connector_pending_rpc(:cancelled)
        {:ok, %{state | pending: pending}}
    end
  end

  def handle_info({:connector_chunk_idle_timeout, id, lease}, state) do
    case state.pending[id] do
      %{chunk_idle: {_timer, ^lease}} = entry ->
        Salix.Telemetry.emit_connector_pending_rpc(:timeout)

        complete_pending(
          id,
          {:error, "chunked response stalled: no frame for #{entry.chunk_wait_ms} ms"},
          state,
          false
        )

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:connector_pending_rpc_timeout, id, ref}, state) do
    case state.pending[id] do
      %{ref: ^ref, from: from} = entry ->
        pending = Map.delete(state.pending, id)
        clear_pending_tracking(entry, true)
        send(from, {:env_rpc_reply, ref, {:error, :timeout}})
        Salix.Telemetry.emit_connector_pending_rpc(:timeout)
        {:ok, %{state | pending: pending}}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:env_write_stream, :begin, ref, from, message}, state) do
    id = message["id"] || Protocol.new_id()
    message = Map.put(message, "id", id) |> Map.delete("transfer")

    cond do
      not scope_permits_method?(state.scope, message["method"]) ->
        send(from, {:env_write_stream_reply, ref, {:error, :connector_scope_forbidden}})
        {:ok, state}

      map_size(state.write_streams) >= write_stream_limit() ->
        send(
          from,
          {:env_write_stream_reply, ref, {:error, :connector_write_stream_capacity_exhausted}}
        )

        Salix.Telemetry.emit_connector_write_stream(:saturated)
        {:ok, state}

      Map.has_key?(state.write_streams, id) ->
        send(from, {:env_write_stream_reply, ref, {:error, :connector_write_stream_id_conflict}})
        Salix.Telemetry.emit_connector_write_stream(:conflict)
        {:ok, state}

      true ->
        info =
          %{
            begin: new_write_waiter(from, ref),
            chunk: nil,
            finish: nil,
            seq: 0,
            timeout_token: nil,
            timeout_timer: nil
          }
          |> reset_write_stream_timeout(id)

        Salix.Telemetry.emit_connector_write_stream(:accepted)

        {:push, {:text, Protocol.encode(message)},
         %{state | write_streams: Map.put(state.write_streams, id, info)}}
    end
  end

  def handle_info({:env_write_stream, :chunk, ref, from, id, chunk}, state) do
    case state.write_streams[id] do
      nil ->
        send(from, {:env_write_stream_reply, ref, {:error, :unknown_write_stream}})
        {:ok, state}

      %{chunk: chunk, finish: finish} when not is_nil(chunk) or not is_nil(finish) ->
        send(from, {:env_write_stream_reply, ref, {:error, :write_stream_phase_in_progress}})
        {:ok, state}

      info ->
        seq = Map.get(info, :seq, 0) + 1

        frame = %{
          "id" => id,
          "type" => "stream",
          "stream" => %{
            "channel" => "data",
            "data" => Base.encode64(chunk),
            "seq" => seq
          }
        }

        write_streams =
          Map.put(
            state.write_streams,
            id,
            info
            |> Map.put(:chunk, new_write_waiter(from, ref))
            |> Map.put(:seq, seq)
            |> reset_write_stream_timeout(id)
          )

        {:push, {:text, Protocol.encode(frame)}, %{state | write_streams: write_streams}}
    end
  end

  def handle_info({:env_write_stream, :eof, ref, from, id}, state) do
    case state.write_streams[id] do
      nil ->
        send(from, {:env_write_stream_reply, ref, {:error, :unknown_write_stream}})
        {:ok, state}

      %{chunk: chunk, finish: finish} when not is_nil(chunk) or not is_nil(finish) ->
        send(from, {:env_write_stream_reply, ref, {:error, :write_stream_phase_in_progress}})
        {:ok, state}

      info ->
        seq = Map.get(info, :seq, 0) + 1

        frame = %{
          "id" => id,
          "type" => "stream",
          "stream" => %{"channel" => "data", "eof" => true, "seq" => seq}
        }

        write_streams =
          Map.put(
            state.write_streams,
            id,
            info
            |> Map.put(:finish, new_write_waiter(from, ref))
            |> Map.put(:seq, seq)
            |> reset_write_stream_timeout(id)
          )

        {:push, {:text, Protocol.encode(frame)}, %{state | write_streams: write_streams}}
    end
  end

  def handle_info({:env_write_stream_abort, id, reason}, state) do
    case state.write_streams[id] do
      nil ->
        {:ok, state}

      info ->
        fail_write_stream_info(info, reason)
        Salix.Telemetry.emit_connector_write_stream(:aborted)

        {:stop, {:shutdown, {:write_stream_abandoned, id, :explicit_abort}},
         %{state | write_streams: Map.delete(state.write_streams, id)}}
    end
  end

  def handle_info({:env_write_stream_cancel, ref, from}, state) do
    case pop_write_stream_by_ref(state.write_streams, ref, from) do
      {nil, nil, _write_streams} ->
        {:ok, state}

      {id, info, write_streams} ->
        clear_write_stream_tracking(info)
        Salix.Telemetry.emit_connector_write_stream(:cancelled)

        {:stop, {:shutdown, {:write_stream_abandoned, id, :caller_cancelled}},
         %{state | write_streams: write_streams}}
    end
  end

  def handle_info({:connector_write_stream_timeout, id, timeout_token}, state) do
    case state.write_streams[id] do
      %{timeout_token: ^timeout_token} = info ->
        fail_write_stream_info(info, :timeout)
        Salix.Telemetry.emit_connector_write_stream(:timeout)

        {:stop, {:shutdown, {:write_stream_abandoned, id, :idle_timeout}},
         %{state | write_streams: Map.delete(state.write_streams, id)}}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:read_stream_frame_complete, token, result}, state) do
    case pop_tracked_task(state.stream_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        state = %{state | stream_tasks: tasks}

        case state.read_streams[task.id] do
          %{receiver: sender} when sender == task.sender ->
            complete_read_stream_frame(task.id, task.sender, task.stream, result, state)

          _ ->
            complete_cancelled_read_stream_frame(task, state)
        end
    end
  end

  def handle_info({:frame_stream_closed, id, receiver}, state) do
    handle_info({:frame_stream_closed, id, receiver, :consumer_closed}, state)
  end

  def handle_info({:frame_stream_closed, id, receiver, close_reason}, state) do
    case state.read_streams[id] do
      %{receiver: ^receiver} = info ->
        clear_read_stream_tracking(info)
        Salix.Telemetry.emit_connector_read_stream(read_stream_close_outcome(close_reason))

        {:ok,
         state
         |> Map.put(:read_streams, Map.delete(state.read_streams, id))
         |> remember_read_stream_cancellation(id)}

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:control_task_started, token, {:ok, worker}}, state) do
    case state.control_job do
      %{token: ^token} = job ->
        {:ok, %{state | control_job: activate_control_worker(job, worker)}}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:control_task_ready, token, worker}, state) do
    case state.control_job do
      %{token: ^token} = job ->
        job = activate_control_worker(job, worker)
        send(worker, {:run_connector_task, token})
        {:ok, %{state | control_job: job}}

      _stale ->
        Process.exit(worker, :kill)
        {:ok, state}
    end
  end

  def handle_info({:control_task_started, token, {:error, reason}}, state) do
    case state.control_job do
      %{token: ^token} = job ->
        {:ok, retry_control_job(state, job, {:start_failed, reason})}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:control_task_complete, token, _worker, result}, state) do
    case state.control_job do
      %{token: ^token} = job ->
        state = clear_control_job(state, job)

        if control_success?(result) do
          {:ok, start_control_if_idle(state)}
        else
          {:ok, retry_control_job(state, job, result)}
        end

      _stale ->
        {:ok, state}
    end
  end

  def handle_info({:connector_task_timeout, :control, token}, state) do
    case state.control_job do
      %{token: ^token} = job ->
        if is_pid(job.starter), do: Process.exit(job.starter, :kill)
        if is_pid(job.worker), do: Process.exit(job.worker, :kill)
        {:ok, retry_control_job(state, job, :timeout)}

      _stale ->
        {:ok, state}
    end
  end

  def handle_info(:retry_connector_control, state) do
    {:ok, state |> Map.put(:control_retry_timer, nil) |> start_control_if_idle()}
  end

  def handle_info({:socket_task_started, :request, token, {:ok, worker}}, state) do
    {:ok, activate_socket_task(state, :request_tasks, token, worker)}
  end

  def handle_info({:socket_task_started, :stream, token, {:ok, worker}}, state) do
    {:ok, activate_socket_task(state, :stream_tasks, token, worker)}
  end

  def handle_info({:socket_task_ready, :request, token, worker}, state) do
    {:ok, authorize_socket_task(state, :request_tasks, token, worker)}
  end

  def handle_info({:socket_task_ready, :stream, token, worker}, state) do
    {:ok, authorize_socket_task(state, :stream_tasks, token, worker)}
  end

  def handle_info({:socket_task_started, :request, token, {:error, _reason}}, state) do
    case pop_tracked_task(state.request_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        state = %{state | request_tasks: tasks}
        state = maybe_advance_meeting_events(task, state)

        {:push, {:text, request_task_error(task.id, "server request capacity exhausted")}, state}
    end
  end

  def handle_info({:socket_task_started, :stream, token, {:error, _reason}}, state) do
    case pop_tracked_task(state.stream_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        state = %{state | stream_tasks: tasks}

        case state.read_streams[task.id] do
          %{receiver: sender} when sender == task.sender ->
            fail_overloaded_read_stream(task.id, task.sender, task.stream, state)

          _stale ->
            complete_cancelled_read_stream_frame(task, state)
        end
    end
  end

  def handle_info({:request_task_complete, token, encoded}, state) do
    case pop_tracked_task(state.request_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        state = %{state | request_tasks: tasks}
        state = maybe_advance_meeting_events(task, state)

        {:push, {:text, encoded}, state}
    end
  end

  def handle_info({:connector_task_timeout, :request, token}, state) do
    case pop_tracked_task(state.request_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        terminate_task(task)
        state = %{state | request_tasks: tasks}
        state = maybe_advance_meeting_events(task, state)

        {:push, {:text, request_task_error(task.id, "server request timed out")}, state}
    end
  end

  def handle_info({:connector_task_timeout, :stream, token}, state) do
    case pop_tracked_task(state.stream_tasks, token) do
      {nil, _tasks} ->
        {:ok, state}

      {task, tasks} ->
        terminate_task(task)
        state = %{state | stream_tasks: tasks}

        case state.read_streams[task.id] do
          %{receiver: sender} when sender == task.sender ->
            complete_read_stream_frame(
              task.id,
              task.sender,
              task.stream,
              {:error, :stream_idle_timeout},
              state
            )

          _stale ->
            complete_cancelled_read_stream_frame(task, state)
        end
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.tunnels, fn {_id, tunnel} -> tunnel.monitor == monitor end) do
      {id, tunnel} ->
        eof = %{"id" => id, "type" => "stream", "stream" => %{"channel" => "tcp", "eof" => true}}
        {:push, {:text, Protocol.encode(eof)}, drop_tunnel(state, id, tunnel)}

      nil ->
        handle_down(monitor, reason, state)
    end
  end

  def handle_info(:heartbeat, state) do
    if monotonic_ms() - state.last_peer_heartbeat_ms >= heartbeat_timeout_ms() do
      {:stop, {:shutdown, :connector_heartbeat_timeout}, state}
    else
      schedule_heartbeat()
      {:push, {:text, Protocol.encode(%{"type" => "heartbeat"})}, state}
    end
  end

  def handle_info({:env_owner_takeover, env_id, _new_owner}, %State{env_id: env_id} = state) do
    {:stop, {:shutdown, {:connector_replaced, env_id}}, state}
  end

  def handle_info({:connector_drain, from, ref}, state) when is_pid(from) do
    context =
      Map.take(state, [
        :tenant_id,
        :group_id,
        :device_id,
        :connector_id,
        :connector_run_id,
        :credential_generation,
        :connection_generation
      ])

    send(from, {:connector_drain, ref, context})
    {:stop, {:shutdown, :connector_draining}, state}
  end

  def handle_info(
        {:connector_token_expired, expires_at},
        %State{token_expires_at: expires_at} = state
      ) do
    {:stop, {:shutdown, :connector_token_expired}, state}
  end

  # The timer of a credential this run no longer holds.
  def handle_info({:connector_token_expired, _expires_at}, state), do: {:ok, state}

  def handle_info({:push_encoded_frame, encoded}, state), do: {:push, {:text, encoded}, state}

  def handle_info(_other, state), do: {:ok, state}

  defp handle_down(monitor, reason, state) do
    case pop_pending_by_monitor(state.pending, monitor) do
      {entry, pending} when not is_nil(entry) ->
        Salix.Telemetry.emit_connector_pending_rpc(:caller_down)
        {:ok, %{state | pending: pending}}

      {nil, _pending} ->
        case pop_write_stream_by_monitor(state.write_streams, monitor) do
          {id, info, write_streams} when not is_nil(info) ->
            fail_write_stream_info(info, :caller_down)
            Salix.Telemetry.emit_connector_write_stream(:caller_down)

            {:stop, {:shutdown, {:write_stream_abandoned, id, :caller_down}},
             %{state | write_streams: write_streams}}

          {nil, nil, _write_streams} ->
            case pop_read_stream_by_monitor(state.read_streams, monitor) do
              {id, info, read_streams} when not is_nil(info) ->
                FrameStream.cancel(info.receiver, :caller_down)
                clear_read_stream_tracking(info, false)
                Salix.Telemetry.emit_connector_read_stream(:caller_down)

                {:ok,
                 state
                 |> Map.put(:read_streams, read_streams)
                 |> remember_read_stream_cancellation(id)}

              {nil, nil, _read_streams} ->
                case handle_control_task_down(monitor, reason, state) do
                  {:handled, state} ->
                    {:ok, state}

                  :unhandled ->
                    case pop_tracked_task_by_monitor(state.request_tasks, monitor) do
                      {nil, _token, _tasks} ->
                        handle_stream_task_down(monitor, reason, state)

                      {task, _token, tasks} ->
                        state = %{state | request_tasks: tasks}
                        state = maybe_advance_meeting_events(task, state)

                        {:push,
                         {:text,
                          request_task_error(
                            task.id,
                            "server request task exited: #{format_error(reason)}"
                          )}, state}
                    end
                end
            end
        end
    end
  end

  defp maybe_advance_meeting_events(%{kind: :meeting_event}, state),
    do: advance_meeting_events(state)

  defp maybe_advance_meeting_events(_task, state), do: state

  defp activate_socket_task(state, tasks_key, token, worker) do
    tasks = Map.fetch!(state, tasks_key)

    case tasks[token] do
      nil ->
        state

      %{pid: ^worker} ->
        state

      task ->
        if task.starter_monitor, do: Process.demonitor(task.starter_monitor, [:flush])
        monitor = Process.monitor(worker)
        Map.put(state, tasks_key, Map.put(tasks, token, %{task | pid: worker, monitor: monitor}))
    end
  end

  defp authorize_socket_task(state, tasks_key, token, worker) do
    tasks = Map.fetch!(state, tasks_key)

    if Map.has_key?(tasks, token) do
      state = activate_socket_task(state, tasks_key, token, worker)
      send(worker, {:run_connector_task, token})
      state
    else
      Process.exit(worker, :kill)
      state
    end
  end

  defp activate_control_worker(%{worker: worker} = job, worker), do: job

  defp activate_control_worker(job, worker) do
    if job.starter_monitor, do: Process.demonitor(job.starter_monitor, [:flush])
    %{job | worker: worker, worker_monitor: Process.monitor(worker)}
  end

  defp await_task_authorization(socket, ready, token, fun) do
    monitor = Process.monitor(socket)
    send(socket, Tuple.insert_at(ready, tuple_size(ready), self()))

    SystemsClock.vreceive do
      {:run_connector_task, ^token} ->
        Process.link(socket)
        Process.demonitor(monitor, [:flush])
        fun.()

      {:DOWN, ^monitor, :process, ^socket, _reason} ->
        :ok
    after
      task_authorization_timeout_ms() -> :ok
    end
  end

  defp task_authorization_timeout_ms,
    do: SystemsRuntime.get_env(:salix_web, :connector_task_authorization_timeout_ms, 5_000)

  defp handle_control_task_down(monitor, reason, state) do
    case state.control_job do
      %{starter_monitor: ^monitor, worker: nil} = job ->
        {:handled, retry_control_job(state, job, {:starter_exit, reason})}

      %{worker_monitor: ^monitor} = job ->
        {:handled, retry_control_job(state, job, {:task_exit, reason})}

      _ ->
        :unhandled
    end
  end

  defp retry_control_job(state, job, reason) do
    Logger.warning(
      "connector control operation failed; retrying kind=#{job.operation.kind} " <>
        "run=#{state.connector_run_id} reason=#{inspect(reason)}"
    )

    state = clear_control_job(state, job)
    pending = merge_control(job.operation, state.control_pending)

    if state.control_retry_timer do
      %{state | control_pending: pending}
    else
      timer = SystemsClock.send_after(self(), :retry_connector_control, control_retry_ms())
      %{state | control_pending: pending, control_retry_timer: timer}
    end
  end

  defp clear_control_job(state, job) do
    SystemsClock.cancel_timer(job.timer)
    if job.starter_monitor, do: Process.demonitor(job.starter_monitor, [:flush])
    if job.worker_monitor, do: Process.demonitor(job.worker_monitor, [:flush])
    SalixWeb.ConnectorTaskAdmission.release(job.admission)
    %{state | control_job: nil}
  end

  defp pop_tracked_task(tasks, token) do
    case Map.pop(tasks, token) do
      {nil, rest} ->
        {nil, rest}

      {task, rest} ->
        cancel_task_tracking(task, true)
        {task, rest}
    end
  end

  defp pop_tracked_task_by_monitor(tasks, monitor) do
    case Enum.find(tasks, fn {_token, task} ->
           task.monitor == monitor or task.starter_monitor == monitor
         end) do
      nil ->
        {nil, nil, tasks}

      {token, task} ->
        cancel_task_tracking(task, false)
        {task, token, Map.delete(tasks, token)}
    end
  end

  defp cancel_task_tracking(task, demonitor?) do
    SystemsClock.cancel_timer(task.timer)

    if demonitor? do
      if task.starter_monitor, do: Process.demonitor(task.starter_monitor, [:flush])
      if task.monitor, do: Process.demonitor(task.monitor, [:flush])
    end

    SalixWeb.ConnectorTaskAdmission.release(task.admission)

    :ok
  end

  defp terminate_task(task) do
    if is_pid(task.starter_pid), do: Process.exit(task.starter_pid, :kill)
    if is_pid(task.pid), do: Process.exit(task.pid, :kill)
    :ok
  end

  defp handle_stream_task_down(monitor, reason, state) do
    case pop_tracked_task_by_monitor(state.stream_tasks, monitor) do
      {nil, _token, _tasks} ->
        {:ok, state}

      {task, _token, tasks} ->
        state = %{state | stream_tasks: tasks}

        case state.read_streams[task.id] do
          %{receiver: sender} when sender == task.sender ->
            complete_read_stream_frame(
              task.id,
              task.sender,
              task.stream,
              {:error, {:stream_task_exit, reason}},
              state
            )

          _ ->
            complete_cancelled_read_stream_frame(task, state)
        end
    end
  end

  defp request_task_error(id, reason) do
    Protocol.encode(%{"id" => id, "type" => "error", "error" => reason})
  end

  # ---- control frames (pong keepalive) ----

  @impl true
  def handle_control({_payload, [opcode: :pong]}, state), do: {:ok, state}
  def handle_control({_payload, [opcode: :ping]}, state), do: {:ok, state}
  def handle_control(_other, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    # Fail every in-flight RPC immediately (so callers don't wait out the
    # timeout), then flip the durable record. A backend blip during teardown
    # must not crash the connection process — the recovery sweep is the
    # backstop that reconciles the durable record either way.
    for {_id, %{from: from, ref: ref} = entry} <- state.pending do
      clear_pending_tracking(entry, true)
      send(from, {:env_rpc_reply, ref, {:error, state.disconnect_error}})
      Salix.Telemetry.emit_connector_pending_rpc(:socket_closed)
    end

    for {_id, info} <- state.write_streams do
      fail_write_stream_info(info, state.disconnect_error)
      Salix.Telemetry.emit_connector_write_stream(:socket_closed)
    end

    for {_id, info} <- state.read_streams do
      clear_read_stream_tracking(info)
      FrameStream.cancel(info.receiver, state.disconnect_error)
      Salix.Telemetry.emit_connector_read_stream(:socket_closed)
    end

    # Submit durable disconnect before best-effort local cleanup. The retry
    # queue is asynchronous, so a stalled task supervisor cannot hold teardown.
    SalixWeb.ConnectorDisconnectQueue.submit(
      state.connector_run_id,
      state.connection_generation,
      to_string(node())
    )

    for {_token, task} <- state.request_tasks do
      cancel_task_tracking(task, true)
      terminate_task(task)
    end

    for {_token, task} <- state.stream_tasks do
      cancel_task_tracking(task, true)
      terminate_task(task)
    end

    if state.control_job do
      SystemsClock.cancel_timer(state.control_job.timer)
      if is_pid(state.control_job.starter), do: Process.exit(state.control_job.starter, :kill)
      if is_pid(state.control_job.worker), do: Process.exit(state.control_job.worker, :kill)
      SalixWeb.ConnectorTaskAdmission.release(state.control_job.admission)
    end

    if state.control_retry_timer, do: SystemsClock.cancel_timer(state.control_retry_timer)

    Logger.info("connector socket down: env=#{state.env_id} reason=#{disconnect_reason(reason)}")
    :ok
  end

  # Never log arbitrary socket errors, which can carry request or frame data.
  defp disconnect_reason({:error, {:shutdown, reason}}),
    do: disconnect_reason({:shutdown, reason})

  defp disconnect_reason({:shutdown, reason})
       when reason in [
              :connector_draining,
              :connector_token_expired,
              :connector_token_revoked,
              :connector_heartbeat_timeout
            ],
       do: reason

  defp disconnect_reason({:shutdown, {:connector_replaced, _}}), do: :connector_replaced
  defp disconnect_reason(:normal), do: :normal
  defp disconnect_reason(_), do: :other

  defp schedule_heartbeat, do: SystemsClock.send_after(self(), :heartbeat, heartbeat_ms())

  defp heartbeat_ms,
    do: SystemsRuntime.get_env(:salix_web, :connector_heartbeat_ms, 15_000)

  defp heartbeat_timeout_ms,
    do: SystemsRuntime.get_env(:salix_web, :connector_heartbeat_timeout_ms, 45_000)

  defp monotonic_ms, do: SystemsClock.monotonic_time(:millisecond)

  defp metadata_patch(message, state) do
    with {:ok, agent_runtimes} <- agent_runtimes_from_metadata(message, state) do
      patch =
        %{}
        |> maybe_put("capabilities", metadata_capabilities(message["capabilities"]))
        |> maybe_put_connector_scope(message, state)
        |> maybe_put("skills", message["skills"])
        |> maybe_put("agent_runtimes", agent_runtimes)
        |> maybe_put_runtime_auth_generation(message, agent_runtimes, state)
        |> maybe_put_connector_health(message["connector_health"])
        |> maybe_put_system_info(message["system_info"])

      {:ok, patch}
    end
  end

  defp metadata_capabilities(capabilities) when is_map(capabilities),
    do: Map.delete(capabilities, "agent_runtimes")

  defp metadata_capabilities(capabilities), do: capabilities

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_connector_scope(
         patch,
         %{"capabilities" => capabilities},
         %State{
           scope: token_scope,
           connection_generation: generation
         }
       )
       when is_map(capabilities) and token_scope != "local_file_read" do
    # The bearer is intentionally full for Comma desktop. Only an explicit
    # connector scope update changes its connector-owned readiness state;
    # unrelated partial metadata must preserve the last reported scope. Every
    # accepted transition is stamped to this exact socket generation so a
    # delayed predecessor cannot widen routing.
    case Map.fetch(capabilities, "scope") do
      :error ->
        patch

      {:ok, scope} ->
        connector_scope =
          if scope in ["", "local_file_read"], do: scope, else: "local_file_read"

        patch
        |> Map.put("connector_scope", connector_scope)
        |> Map.put("connector_scope_generation", generation)
    end
  end

  defp maybe_put_connector_scope(patch, _message, _state), do: patch

  # A reconnect reuses the stable device record. Fence auth capability/state to
  # metadata accepted from this exact connector generation so an older full
  # Connector cannot make a replacement/attachment-only Connector appear able
  # to serve runtime-auth control calls.
  defp maybe_put_runtime_auth_generation(
         patch,
         %{"capabilities" => capabilities},
         runtimes,
         state
       )
       when is_map(capabilities) do
    has_auth_snapshot =
      is_list(runtimes) and Enum.any?(runtimes, &is_map(&1["auth"]))

    generation =
      if (capabilities["runtime_auth_v1"] == true and is_list(runtimes)) or has_auth_snapshot,
        do: state.connection_generation,
        else: nil

    Map.put(patch, "runtime_auth_generation", generation)
  end

  defp maybe_put_runtime_auth_generation(patch, _message, _runtimes, _state), do: patch

  @connector_health_required_fields ~w(
    schema_version observed_at process_started_at request_inflight request_capacity
    runtime_proxy_inflight runtime_proxy_capacity managed_processes
  )
  @connector_health_fields @connector_health_required_fields

  @connector_health_max_count 1_000_000_000
  @connector_health_max_timestamp 9_999_999_999_999

  defp maybe_put_connector_health(meta, health) when is_map(health) do
    case health |> stringify_keys() |> Map.take(@connector_health_fields) do
      %{"schema_version" => 1} = snapshot ->
        if Enum.all?(@connector_health_required_fields, &Map.has_key?(snapshot, &1)) and
             Enum.all?(snapshot, &valid_connector_health_field?/1) do
          meta
          |> Map.put("connector_health", snapshot)
          |> Map.put("connector_health_updated_at", SystemsClock.system_time(:millisecond))
        else
          meta
        end

      _ ->
        meta
    end
  end

  defp maybe_put_connector_health(meta, _health), do: meta

  defp valid_connector_health_field?({field, value})
       when field in ["observed_at", "process_started_at"],
       do: is_integer(value) and value > 0 and value <= @connector_health_max_timestamp

  defp valid_connector_health_field?({"schema_version", 1}), do: true

  defp valid_connector_health_field?({_field, value}),
    do: is_integer(value) and value >= 0 and value <= @connector_health_max_count

  defp agent_runtimes_from_metadata(%{"capabilities" => capabilities}, state)
       when is_map(capabilities) do
    case Map.fetch(capabilities, "agent_runtimes") do
      {:ok, runtimes} when is_list(runtimes) ->
        with :ok <- validate_agent_runtimes(runtimes) do
          {:ok, normalize_agent_runtimes(runtimes, state)}
        end

      {:ok, _invalid} ->
        {:error, :invalid_agent_runtimes}

      :error ->
        {:ok, nil}
    end
  end

  defp agent_runtimes_from_metadata(_metadata, _state), do: {:ok, nil}

  @max_agent_runtimes 32
  @max_runtime_identity_bytes 4_096
  @runtime_fields ~w(
    kind provider command identity_material version version_detected auth_ready
    app_server_startable native_server_startable ready status readiness_issue
    readiness_message readiness_checked_at readiness_valid_until protocol_versions transports last_error
    model model_provider reasoning_effort id probe_trigger probe_duration_ms auth
  )

  @runtime_string_fields ~w(
    kind provider command identity_material version status readiness_issue readiness_message last_error
    model model_provider reasoning_effort id probe_trigger
  )
  @runtime_boolean_fields ~w(
    version_detected auth_ready app_server_startable native_server_startable ready
  )
  @runtime_integer_fields ~w(
    readiness_checked_at readiness_valid_until probe_duration_ms
  )
  @runtime_string_list_fields ~w(protocol_versions transports)

  defp validate_agent_runtimes(runtimes) when length(runtimes) <= @max_agent_runtimes do
    runtimes
    |> Enum.reduce_while(MapSet.new(), &validate_agent_runtime/2)
    |> case do
      :error -> {:error, :invalid_agent_runtimes}
      _targets -> :ok
    end
  end

  defp validate_agent_runtimes(_runtimes), do: {:error, :invalid_agent_runtimes}

  defp validate_agent_runtime(runtime, targets) when is_map(runtime) do
    runtime = stringify_keys(runtime)

    with true <- valid_runtime_field_types?(runtime),
         {:ok, target} <- runtime_target(runtime),
         false <- not is_nil(target) and MapSet.member?(targets, target) do
      {:cont, if(target, do: MapSet.put(targets, target), else: targets)}
    else
      _ -> {:halt, :error}
    end
  end

  defp validate_agent_runtime(_runtime, _acc), do: {:halt, :error}

  defp valid_runtime_field_types?(runtime) do
    fields_have_type?(runtime, @runtime_string_fields, &is_binary/1) and
      fields_have_type?(runtime, @runtime_boolean_fields, &is_boolean/1) and
      fields_have_type?(runtime, @runtime_integer_fields, &(is_integer(&1) and &1 >= 0)) and
      fields_have_type?(runtime, @runtime_string_list_fields, fn value ->
        is_list(value) and Enum.all?(value, &is_binary/1)
      end) and
      Enum.all?([runtime["command"], runtime["last_error"]], fn
        value when is_binary(value) -> byte_size(value) <= @max_runtime_identity_bytes
        nil -> true
      end) and valid_public_runtime_message?(runtime["readiness_message"]) and
      valid_runtime_auth_snapshot?(runtime["auth"])
  end

  defp valid_runtime_auth_snapshot?(nil), do: true

  defp valid_runtime_auth_snapshot?(snapshot),
    do: match?({:ok, _safe}, SalixEnv.RuntimeAuth.validate_snapshot(snapshot))

  defp valid_public_runtime_message?(nil), do: true

  defp valid_public_runtime_message?(message) when is_binary(message),
    do:
      String.valid?(message) and String.trim(message) != "" and byte_size(message) <= 300 and
        not Regex.match?(~r/[\x00-\x1F\x7F]/u, message)

  defp valid_public_runtime_message?(_message), do: false

  defp fields_have_type?(runtime, fields, predicate) do
    Enum.all?(fields, fn field ->
      case Map.fetch(runtime, field) do
        {:ok, nil} -> true
        {:ok, value} -> predicate.(value)
        :error -> true
      end
    end)
  end

  defp runtime_target(runtime) do
    provider = runtime["provider"]
    identity_material = runtime["identity_material"]

    cond do
      not is_binary(provider) or String.trim(provider) == "" or byte_size(provider) > 32 ->
        :error

      is_binary(identity_material) and String.trim(identity_material) != "" and
          byte_size(identity_material) <= @max_runtime_identity_bytes ->
        {:ok, {String.trim(provider), RuntimeIds.trim_identity_material(identity_material)}}

      runtime["kind"] == "meeting" and provider == "meetnative" and
          is_binary(runtime["id"]) ->
        {:ok, nil}

      true ->
        :error
    end
  end

  defp normalize_agent_runtimes(runtimes, state) do
    normalized =
      runtimes
      |> Enum.flat_map(&normalize_agent_runtime(&1, state))

    probed = Enum.filter(normalized, &is_integer(&1["probe_duration_ms"]))

    probed =
      if Enum.any?(probed, &(&1["probe_trigger"] == "operator")),
        do: Enum.filter(probed, &(&1["probe_trigger"] == "operator")),
        else: probed

    Enum.each(probed, &Salix.Telemetry.emit_runtime_probe/1)
    normalized
  end

  defp normalize_agent_runtime(runtime, %{device_id: device_id}) do
    runtime = runtime |> stringify_keys() |> Map.take(@runtime_fields)
    provider = trim(runtime["provider"])
    identity_material = RuntimeIds.trim_identity_material(runtime["identity_material"] || "")

    cond do
      provider == "" or trim(device_id) == "" or identity_material == "" ->
        []

      byte_size(provider) > 32 or byte_size(identity_material) > @max_runtime_identity_bytes ->
        []

      Enum.any?([runtime["command"], runtime["last_error"]], fn
        value when is_binary(value) -> byte_size(value) > @max_runtime_identity_bytes
        nil -> false
        _other -> true
      end) ->
        []

      true ->
        runtime_id = RuntimeIds.runtime_id(identity_material)
        device_runtime_id = RuntimeIds.device_runtime_id(device_id, provider, runtime_id)

        [
          runtime
          |> Map.put("id", device_runtime_id)
          |> Map.put("kind", runtime["kind"] || "external")
          |> Map.put("provider", provider)
          |> Map.put("identity_material", identity_material)
          |> Map.put("runtime_id", runtime_id)
          |> Map.put("device_runtime_id", device_runtime_id)
          |> Map.put("device_id", device_id)
          |> Map.put("updated_at", SystemsClock.system_time(:second))
        ]
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # Persist the connector's reported host facts plus the time we last received
  # them, so the dashboards can show "system info, as of …".
  defp maybe_put_system_info(meta, info) when is_map(info) and map_size(info) > 0 do
    meta
    |> Map.put("system_info", info)
    |> Map.put("system_info_updated_at", SystemsClock.system_time(:millisecond))
  end

  defp maybe_put_system_info(meta, _info), do: meta

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp stream_error(err, stream) do
    cond do
      present?(err) -> err
      present?(stream["error"]) -> stream["error"]
      true -> nil
    end
  end

  defp consume_read_stream_frame(sender, stream) do
    try do
      with {:ok, ack?} <- consume_read_stream_data(sender, stream["data"]),
           :ok <- maybe_finish_read_stream(sender, stream["eof"] == true) do
        {:ok, ack?}
      else
        {:error, reason} -> {:error, format_error(reason)}
      end
    rescue
      e -> {:error, format_error(Exception.message(e))}
    catch
      kind, reason -> {:error, format_error({kind, reason})}
    end
  end

  defp consume_read_stream_data(_sender, nil), do: {:ok, false}

  defp consume_read_stream_data(sender, data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, chunk} ->
        case FrameStream.chunk(sender, chunk, read_stream_idle_timeout_ms()) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp consume_read_stream_data(_sender, _data), do: {:error, :invalid_stream_data}

  defp maybe_finish_read_stream(sender, true),
    do: FrameStream.eof(sender, read_stream_idle_timeout_ms())

  defp maybe_finish_read_stream(_sender, false), do: :ok

  defp read_stream_idle_timeout_ms do
    case SystemsRuntime.get_env(:salix_web, :connector_read_stream_idle_timeout_ms, 30_000) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 30_000
    end
  end

  defp complete_read_stream_frame(id, sender, stream, {:ok, ack?}, state) do
    state =
      if stream["eof"] == true do
        state = remove_read_stream(state, id, sender)
        Salix.Telemetry.emit_connector_read_stream(:completed)
        state
      else
        state
      end

    maybe_push_read_stream_ack(id, stream, ack?, state)
  end

  defp complete_read_stream_frame(id, sender, stream, {:error, reason}, state) do
    FrameStream.fail(sender, reason)
    state = remove_read_stream(state, id, sender)
    Salix.Telemetry.emit_connector_read_stream(read_stream_error_outcome(reason))
    push_read_stream_error_ack(id, stream, reason, state)
  end

  defp push_read_stream_error_ack(id, stream, reason, state),
    do: push_read_stream_ack(id, stream, format_error(reason), state)

  defp maybe_push_read_stream_ack(id, stream, true, state),
    do: push_read_stream_ack(id, stream, nil, state)

  defp maybe_push_read_stream_ack(_id, _stream, _ack?, state), do: {:ok, state}

  defp push_read_stream_ack(id, stream, error, state) do
    ack =
      %{
        "id" => id,
        "type" => "stream",
        "stream" => %{"channel" => "ack", "seq" => stream["seq"]}
      }
      |> maybe_put("error", error)

    {:push, {:text, Protocol.encode(ack)}, state}
  end

  defp complete_cancelled_read_stream_frame(task, state) do
    case Map.pop(state.read_stream_cancellations, task.id) do
      {nil, _rest} ->
        {:ok, state}

      {_closed_at, rest} ->
        state = %{state | read_stream_cancellations: rest}
        push_read_stream_error_ack(task.id, task.stream, "server stream consumer closed", state)
    end
  end

  defp new_read_stream_info(id, receiver, from, ref, message) do
    absolute_token = SystemsRuntime.Proc.make_ref()

    absolute_timer =
      SystemsClock.send_after(
        self(),
        {:connector_read_stream_absolute_timeout, id, ref, absolute_token},
        read_stream_absolute_timeout_ms(message)
      )

    %{
      receiver: receiver,
      from: from,
      ref: ref,
      caller_monitor: Process.monitor(from),
      absolute_timer: absolute_timer,
      absolute_token: absolute_token
    }
  end

  defp remove_read_stream(state, id, receiver) do
    case state.read_streams[id] do
      %{receiver: ^receiver} = info ->
        clear_read_stream_tracking(info)
        %{state | read_streams: Map.delete(state.read_streams, id)}

      _stale ->
        state
    end
  end

  defp remember_read_stream_cancellation(state, id) do
    cancellations =
      state.read_stream_cancellations
      |> Map.put(id, monotonic_ms())
      |> trim_read_stream_cancellations()

    %{state | read_stream_cancellations: cancellations}
  end

  defp clear_read_stream_tracking(info, demonitor? \\ true) do
    if info[:absolute_timer], do: SystemsClock.cancel_timer(info.absolute_timer)

    if demonitor? and info[:caller_monitor] do
      Process.demonitor(info.caller_monitor, [:flush])
    end

    :ok
  end

  defp pop_read_stream_by_ref(read_streams, ref, from) do
    case Enum.find(read_streams, fn {_id, info} ->
           info.ref == ref and info.from == from
         end) do
      nil -> {nil, nil, read_streams}
      {id, info} -> {id, info, Map.delete(read_streams, id)}
    end
  end

  defp pop_read_stream_by_monitor(read_streams, monitor) do
    case Enum.find(read_streams, fn {_id, info} -> info.caller_monitor == monitor end) do
      nil -> {nil, nil, read_streams}
      {id, info} -> {id, info, Map.delete(read_streams, id)}
    end
  end

  defp read_stream_close_outcome(:stream_idle_timeout), do: :timeout
  defp read_stream_close_outcome({:error, :stream_idle_timeout}), do: :timeout
  defp read_stream_close_outcome(:completed), do: :completed
  defp read_stream_close_outcome({:error, _reason}), do: :error
  defp read_stream_close_outcome(_reason), do: :cancelled

  defp read_stream_error_outcome(:stream_idle_timeout), do: :timeout
  defp read_stream_error_outcome("stream_idle_timeout"), do: :timeout
  defp read_stream_error_outcome(_reason), do: :error

  defp bounded_meeting_artifact_sizes(%{"event" => %{"artifacts" => artifacts}})
       when is_list(artifacts) do
    artifacts
    |> Enum.reduce_while({[], 0}, fn
      %{} = artifact, {sizes, total} ->
        source_ref = artifact["source_ref"]
        size = artifact["source_size"]

        cond do
          not (is_binary(source_ref) and source_ref != "") ->
            {:cont, {sizes, total}}

          length(sizes) >= @max_meeting_artifacts ->
            {:halt, :invalid}

          not (is_integer(size) and size >= 0 and size <= @max_meeting_artifact_bytes) ->
            {:halt, :invalid}

          total + size > @max_meeting_event_bytes ->
            {:halt, :invalid}

          true ->
            {:cont, {[size | sizes], total + size}}
        end

      _malformed, _acc ->
        {:halt, :invalid}
    end)
    |> case do
      {sizes, _total} -> Enum.reverse(sizes)
      :invalid -> []
    end
  end

  defp bounded_meeting_artifact_sizes(%{"event" => %{} = _event}), do: []
  defp bounded_meeting_artifact_sizes(_params), do: []

  defp trim_read_stream_cancellations(cancellations) when map_size(cancellations) <= 128,
    do: cancellations

  defp trim_read_stream_cancellations(cancellations) do
    {oldest_id, _closed_at} = Enum.min_by(cancellations, fn {_id, closed_at} -> closed_at end)
    Map.delete(cancellations, oldest_id)
  end

  defp done_payload(%{"data" => data}) when is_binary(data) and data != "" do
    case Jason.decode(data) do
      {:ok, %{} = payload} -> payload
      _ -> %{}
    end
  end

  defp done_payload(_stream), do: %{}

  defp new_write_waiter(from, ref) do
    %{from: from, ref: ref, caller_monitor: Process.monitor(from)}
  end

  defp complete_write_phase(info, phase, reply) do
    case info[phase] do
      %{from: from, ref: ref} = waiter ->
        clear_write_waiter(waiter)
        send(from, {:env_write_stream_reply, ref, reply})
        Map.put(info, phase, nil)

      _not_waiting ->
        info
    end
  end

  defp fail_write_stream_info(info, reason) do
    info = complete_write_phase(info, :begin, {:error, reason})
    info = complete_write_phase(info, :chunk, {:error, reason})
    info = complete_write_phase(info, :finish, {:error, reason})
    clear_write_stream_tracking(info)
  end

  defp clear_write_stream_tracking(info) do
    if info[:timeout_timer], do: SystemsClock.cancel_timer(info.timeout_timer)
    Enum.each([:begin, :chunk, :finish], &clear_write_waiter(info[&1]))
    :ok
  end

  defp clear_write_waiter(%{caller_monitor: monitor}) when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp clear_write_waiter(_waiter), do: :ok

  defp reset_write_stream_timeout(info, id) do
    if info[:timeout_timer], do: SystemsClock.cancel_timer(info.timeout_timer)

    timeout_token = SystemsRuntime.Proc.make_ref()

    timeout_timer =
      SystemsClock.send_after(
        self(),
        {:connector_write_stream_timeout, id, timeout_token},
        write_stream_timeout_ms()
      )

    %{info | timeout_token: timeout_token, timeout_timer: timeout_timer}
  end

  defp pop_write_stream_by_ref(write_streams, ref, from) do
    case Enum.find(write_streams, fn {_id, info} ->
           Enum.any?([:begin, :chunk, :finish], fn phase ->
             match?(%{ref: ^ref, from: ^from}, info[phase])
           end)
         end) do
      nil -> {nil, nil, write_streams}
      {id, info} -> {id, info, Map.delete(write_streams, id)}
    end
  end

  defp pop_write_stream_by_monitor(write_streams, monitor) do
    case Enum.find(write_streams, fn {_id, info} ->
           Enum.any?([:begin, :chunk, :finish], fn phase ->
             match?(%{caller_monitor: ^monitor}, info[phase])
           end)
         end) do
      nil -> {nil, nil, write_streams}
      {id, info} -> {id, info, Map.delete(write_streams, id)}
    end
  end
end
