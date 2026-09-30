defmodule SalixCluster.SessionWorkNotificationListener do
  @moduledoc """
  Per-Pod Postgres notification listener for durable Session work candidates.

  The listener subscribes before requesting a durable catch-up sweep. It then
  routes address hints on the current ring owner and requests catch-up for
  runtime-ready hints. A broken
  connection is re-established with bounded backoff and repeats the same
  subscribe-then-catch-up sequence. Correctness remains with the durable
  candidate projection and lease-driven recovery sweep.

  Notification loss and reconnect ordering are covered by implementation tests.
  The retired notification model is not a current machine-checked guarantee.
  """

  use GenServer
  require Logger

  alias SalixStore.SessionWorkNotifications

  @default_reconnect_backoff_ms 250
  @default_reconnect_backoff_max_ms 5_000
  @connection_keys [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :socket_dir,
    :ssl,
    :ssl_opts,
    :parameters,
    :connect_timeout,
    :timeout,
    :types,
    :socket_options
  ]

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    backoff_ms = positive_integer(opts[:reconnect_backoff_ms], @default_reconnect_backoff_ms)

    state = %{
      notifications_mod: Keyword.get(opts, :notifications_mod, Postgrex.Notifications),
      connection_opts: Keyword.get_lazy(opts, :connection_opts, &default_connection_opts/0),
      connection: nil,
      listen_ref: nil,
      reconnect_timer: nil,
      reconnect_backoff_ms: backoff_ms,
      reconnect_backoff_base_ms: backoff_ms,
      reconnect_backoff_max_ms:
        positive_integer(
          opts[:reconnect_backoff_max_ms],
          @default_reconnect_backoff_max_ms
        ),
      owner_node_fn: Keyword.get(opts, :owner_node_fn, &SalixCluster.Ring.owner/1),
      catch_up_fn:
        Keyword.get(
          opts,
          :catch_up_fn,
          &SalixCluster.Recovery.request_session_work_catchup/0
        ),
      wake_fn:
        Keyword.get(opts, :wake_fn, fn agent_id, target, candidate_token ->
          SalixAgent.SessionWorkRecovery.request_wake(agent_id, target,
            candidate_token: candidate_token
          )
        end)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{connection: nil} = state) do
    state = %{state | reconnect_timer: nil}

    case connect_and_listen(state) do
      {:ok, state} ->
        emit_connection("ok", 0)
        emit_catch_up(run_catch_up(state.catch_up_fn))
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("session-work notification connection failed: #{inspect(reason)}")
        emit_connection("unavailable", 0)
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, %{state | reconnect_timer: nil}}

  def handle_info(
        {:notification, connection, listen_ref, channel, payload},
        %{connection: connection, listen_ref: listen_ref} = state
      ) do
    if channel == SessionWorkNotifications.channel(), do: dispatch_notification(payload, state)
    {:noreply, state}
  end

  def handle_info({:EXIT, connection, reason}, %{connection: connection} = state) do
    Logger.warning("session-work notification connection exited: #{inspect(reason)}")
    emit_connection("unavailable", 0)

    state = %{state | connection: nil, listen_ref: nil}
    {:noreply, schedule_reconnect(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connect_and_listen(state) do
    case safe_apply(state.notifications_mod, :start_link, [state.connection_opts]) do
      {:ok, connection} ->
        case safe_apply(state.notifications_mod, :listen, [
               connection,
               SessionWorkNotifications.channel()
             ]) do
          {:ok, listen_ref} ->
            {:ok,
             %{
               state
               | connection: connection,
                 listen_ref: listen_ref,
                 reconnect_backoff_ms: state.reconnect_backoff_base_ms
             }}

          {:error, reason} ->
            stop_failed_connection(connection)
            {:error, reason}

          other ->
            stop_failed_connection(connection)
            {:error, {:invalid_listen_result, other}}
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_connection_result, other}}
    end
  end

  defp stop_failed_connection(connection) do
    Process.unlink(connection)

    if Process.alive?(connection) do
      Process.exit(connection, :shutdown)
    end
  end

  defp schedule_reconnect(%{reconnect_timer: timer} = state) when is_reference(timer),
    do: state

  defp schedule_reconnect(state) do
    timer = Process.send_after(self(), :connect, state.reconnect_backoff_ms)

    next_backoff =
      min(state.reconnect_backoff_ms * 2, state.reconnect_backoff_max_ms)

    %{state | reconnect_timer: timer, reconnect_backoff_ms: next_backoff}
  end

  defp dispatch_notification(payload, state) do
    case SessionWorkNotifications.decode(payload) do
      {:ok, notification} ->
        dispatch_valid_notification(notification, state)

      {:error, :invalid} ->
        emit_dispatch("rejected")
    end
  end

  defp dispatch_valid_notification(:runtime_ready, state),
    do: emit_catch_up(run_catch_up(state.catch_up_fn))

  defp dispatch_valid_notification(notification, state) do
    case safe_fun(state.owner_node_fn, [notification.agent_id]) do
      {:ok, owner} when owner == node() ->
        target = %{runtime: notification.runtime, session_id: notification.session_id}

        case safe_fun(state.wake_fn, [
               notification.agent_id,
               target,
               notification.candidate_token
             ]) do
          {:ok, :ok} -> emit_dispatch("ok")
          {:ok, {:error, _reason}} -> emit_dispatch("error")
          {:ok, _other} -> emit_dispatch("error")
          {:error, _reason} -> emit_dispatch("error")
        end

      {:ok, _other_owner} ->
        emit_dispatch("ignored")

      {:error, _reason} ->
        emit_dispatch("unroutable")
    end
  end

  defp run_catch_up(fun) do
    case safe_fun(fun, []) do
      {:ok, :ok} -> "ok"
      {:ok, {:error, _reason}} -> "error"
      {:ok, _other} -> "error"
      {:error, _reason} -> "error"
    end
  end

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_fun(fun, args) do
    {:ok, apply(fun, args)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp default_connection_opts do
    SalixStore.Repo.config()
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:auto_reconnect, false)
    |> Keyword.put(:sync_connect, true)
  end

  defp emit_connection(outcome, duration) do
    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_notification_connection",
      "system",
      outcome,
      duration
    )
  end

  defp emit_catch_up(outcome) do
    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_notification_catch_up",
      "system",
      outcome,
      0
    )
  end

  defp emit_dispatch(outcome) do
    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_notification_dispatch",
      "system",
      outcome,
      0
    )
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
