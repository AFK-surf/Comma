defmodule SalixEnv.VM.Providers.Cloudflare.Attachment do
  @moduledoc "Cloudflare WebSocket transport; ConnectorSocket owns protocol, bounded RPC and runtime semantics."
  use WebSockex
  require Logger
  alias SalixEnv.Registry, as: EnvRecords
  alias SalixEnv.VM.Providers.Cloudflare.Client

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :env_id)},
      start: {__MODULE__, :start_link, [opts]},
      # handle_disconnect/2 decides whether to reconnect. A supervisor restart
      # would bypass reconnect?: false, loop on an unreachable Gateway, claim a
      # gateway attempt each time and exhaust the Attachments supervisor.
      # Sweep, reconcile and dispatch repair start a new attachment.
      restart: :temporary
    }
  end

  def start_link(opts) do
    state = %{
      env_id: Keyword.fetch!(opts, :env_id),
      client: Keyword.fetch!(opts, :client),
      sandbox_id: Keyword.fetch!(opts, :sandbox_id),
      meta: Keyword.get(opts, :meta, %{}),
      protocol: nil,
      run: nil,
      gateway_attempt: nil,
      gateway_attempt_settled?: false,
      archive_repair: false,
      reconnect?: true
    }

    async? = Keyword.get(opts, :async, false)

    with {:ok, operation_id, archive_repair} <- claim_attachment(state) do
      state = %{state | gateway_attempt: operation_id, archive_repair: archive_repair}

      case WebSockex.start_link(connect_conn(state), __MODULE__, state,
             name:
               {:via, Registry,
                {SalixEnv.VM.Providers.Cloudflare.AttachmentRegistry, state.env_id}},
             async: async?,
             handle_initial_conn_failure: async?
           ) do
        {:ok, _pid} = ok ->
          ok

        {:error, reason} = error ->
          _ = settle_failed_connection(state, reason)
          error
      end
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    Process.flag(:trap_exit, true)
    state = finish_gateway_attempt(%{state | gateway_attempt_settled?: true})

    case Client.finish_gateway_starting(state.client, state.sandbox_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Cloudflare attachment pending start did not settle: #{inspect(reason)}")
    end

    # Start the protocol before receiving frames. Each connection has its own
    # process, so reconnect cannot retain timers, pending calls or runtime jobs.
    register = fn ->
      EnvRecords.connect(
        to_string(node()),
        state.meta
        |> Map.put("provider", "cloudflare")
        |> Map.put("archive_repair", state.archive_repair),
        transport_id: state.env_id
      )
    end

    registration =
      if state.meta["managed_compute"] == true do
        SalixStore.Compute.with_group_provider(
          state.meta["group_id"],
          "cloudflare",
          %{"name" => state.sandbox_id, "profile_key" => state.meta["profile_key"]},
          register
        )
      else
        register.()
      end

    with {:ok, _, record} <- registration,
         {:ok, protocol} <- start_protocol(state, record) do
      {:ok, %{state | protocol: protocol, run: record, reconnect?: true}}
    else
      {:error, :managed_provider_changed} ->
        send(self(), :registration_failed)
        {:ok, %{state | reconnect?: false}}

      _ ->
        send(self(), :registration_failed)
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:text, frame}, %{protocol: pid} = state) when is_pid(pid) do
    send(pid, {:connector_frame, self(), frame})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:connector_push, pid, frame}, %{protocol: pid} = state),
    do: {:reply, {:text, frame}, state}

  def handle_info({:connector_push, _, _}, state), do: {:ok, state}

  def handle_info({:EXIT, pid, reason}, %{protocol: pid} = state) do
    reconnect? =
      case reason do
        {:shutdown, kind}
        when kind in [:connector_draining, :connector_token_revoked, :connector_token_expired] ->
          false

        {:shutdown, {:connector_replaced, _}} ->
          false

        {:shutdown, {:owner_not_replaced, _, _}} ->
          false

        _ ->
          true
      end

    {:close, {4001, "connector_closed"}, %{state | protocol: nil, reconnect?: reconnect?}}
  end

  def handle_info(:registration_failed, state), do: {:close, {4001, "registration_failed"}, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    stop_protocol(state)
    disconnect_current(state)
    state = %{state | protocol: nil, run: nil}

    if state.gateway_attempt != nil do
      state = settle_failed_connection(state, status.reason)
      {:ok, %{state | reconnect?: false}}
    else
      reconnect_after_disconnect(status, state)
    end
  end

  defp reconnect_after_disconnect(status, state) do
    if state.reconnect? do
      delay = min(50 * Integer.pow(2, min(max(status.attempt_number - 1, 0), 5)), 1_000)
      Process.sleep(delay)

      case claim_attachment(state) do
        {:ok, operation_id, archive_repair} ->
          state = %{
            state
            | gateway_attempt: operation_id,
              gateway_attempt_settled?: false,
              archive_repair: archive_repair
          }

          {:reconnect, connect_conn(state), state}

        {:error, _reason} ->
          {:ok, %{state | reconnect?: false}}
      end
    else
      {:ok, state}
    end
  end

  defp claim_attachment(state) do
    case Client.begin_gateway_attempt(state.client, :normal, state.sandbox_id, "connect") do
      {:ok, operation_id} ->
        {:ok, operation_id, false}

      {:error, {:vm_service_upgrading, %{"phase" => "prepared"}}} = error ->
        if state.meta["managed_compute"] == true do
          case Client.begin_gateway_attempt(
                 state.client,
                 :archive,
                 state.sandbox_id,
                 "connect_repair"
               ) do
            {:ok, operation_id} -> {:ok, operation_id, true}
            _ -> error
          end
        else
          error
        end

      error ->
        error
    end
  end

  @impl true
  def terminate(reason, state) do
    _ = settle_failed_connection(state, reason)
    stop_protocol(state)
    disconnect_current(state)
    :ok
  end

  defp start_protocol(state, record) do
    # Fixed composition seam; there is no selectable protocol implementation.
    apply(SalixWeb.CloudVM.ConnectorSession, :start_link, [
      [
        transport: self(),
        env_id: state.env_id,
        connector_run_id: record["connector_run_id"],
        connection_generation: record["connection_generation"],
        device_id: record["device_id"],
        connector_id: record["connector_id"],
        tenant_id: state.meta["tenant_id"],
        group_id: state.meta["group_id"],
        managed_compute: state.meta["managed_compute"] == true,
        archive_repair: state.archive_repair,
        scope: "",
        disconnect_error: %{
          "error_class" => "vm_reconnecting",
          "env_id" => state.env_id,
          "sandbox_id" => state.sandbox_id,
          "connection_generation" => record["connection_generation"],
          "retryable" => true,
          "message" => "VM attachment disconnected; command outcome may be unknown"
        }
      ]
    ])
  end

  defp stop_protocol(%{protocol: pid}) when is_pid(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp stop_protocol(_), do: :ok

  defp disconnect_current(%{run: record}) when is_map(record) do
    EnvRecords.mark_disconnected(record["connector_run_id"],
      connection_generation: record["connection_generation"],
      owner_node: to_string(node())
    )
  end

  defp disconnect_current(_), do: :ok

  defp connect_conn(state) do
    connect =
      Client.connect_request(state.client, state.sandbox_id,
        claim_id: state.gateway_attempt,
        archive_repair: state.archive_repair
      )

    WebSockex.Conn.new(connect.url, extra_headers: connect.headers)
  end

  defp finish_gateway_attempt(%{gateway_attempt: nil} = state), do: state

  defp finish_gateway_attempt(state) do
    case Client.finish_gateway_attempt(state.client, state.gateway_attempt) do
      :ok ->
        %{state | gateway_attempt: nil}

      {:error, reason} ->
        Logger.error("Cloudflare attachment attempt did not settle: #{inspect(reason)}")
        state
    end
  end

  defp settle_failed_connection(%{gateway_attempt: nil} = state, _reason), do: state

  defp settle_failed_connection(state, reason) do
    if state.gateway_attempt_settled? or settled_connection_failure?(reason) do
      finish_gateway_attempt(%{state | gateway_attempt_settled?: true})
    else
      # The request may have started the Container. Keep one exact-target claim
      # until a ready response or successful connection confirms that start.
      case Client.mark_gateway_starting(state.client, state.gateway_attempt, state.sandbox_id) do
        :ok ->
          %{state | gateway_attempt: nil}

        {:error, reason} ->
          Logger.error(
            "Cloudflare attachment uncertain start did not persist: #{inspect(reason)}"
          )

          state
      end
    end
  end

  defp settled_connection_failure?({:error, reason}), do: settled_connection_failure?(reason)
  defp settled_connection_failure?({:already_started, _pid}), do: true
  defp settled_connection_failure?(%WebSockex.URLError{}), do: true
  defp settled_connection_failure?(%WebSockex.ApplicationError{}), do: true

  defp settled_connection_failure?(%WebSockex.ConnError{original: reason})
       when reason in [:econnrefused, :nxdomain], do: true

  defp settled_connection_failure?(%WebSockex.RequestError{code: code})
       when code in 400..499 and code not in [408, 429], do: true

  defp settled_connection_failure?(_reason), do: false
end
