defmodule SalixEnv.WriteFrameSink do
  @moduledoc false
  use GenServer

  alias SalixEnv.Transfer.Tokens

  @default_absolute_timeout_ms 305_000

  def start(owner, id, timeout, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())

    absolute_timeout =
      opts
      |> Keyword.get(:absolute_timeout_ms, configured_absolute_timeout())
      |> positive_timeout(@default_absolute_timeout_ms)

    GenServer.start(__MODULE__, {owner, id, timeout, caller, absolute_timeout})
  end

  def url(pid), do: GenServer.call(pid, :url)

  @impl true
  def init({owner, id, timeout, caller, absolute_timeout}) do
    token = Tokens.register(owner: self())
    absolute_token = make_ref()

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       caller: caller,
       caller_monitor: if(is_pid(caller), do: Process.monitor(caller)),
       id: id,
       timeout: timeout,
       token: token,
       error: nil,
       handler: nil,
       handler_monitor: nil,
       absolute_token: absolute_token,
       absolute_timer:
         Process.send_after(
           self(),
           {:remote_write_stream_absolute_timeout, absolute_token},
           absolute_timeout
         )
     }}
  end

  @impl true
  def handle_call(:url, _from, %{token: token} = state) do
    {:reply, SalixEnv.Transfer.advertise_url(token), state}
  end

  @impl true
  def handle_info({:transfer_chunk, token, handler, chunk}, %{token: token} = state) do
    state = track_handler(state, handler)

    state =
      case state.error do
        nil ->
          case call_owner_write(state.owner, :chunk, [state.id, chunk], state.timeout) do
            :ok -> state
            {:error, reason} -> %{state | error: reason}
          end

        _reason ->
          state
      end

    send(handler, {:transfer_ack, token})
    {:noreply, state}
  end

  def handle_info({:transfer_eof, token, handler}, %{token: token} = state) do
    state = track_handler(state, handler)

    reply =
      case state.error do
        nil -> call_owner_write(state.owner, :eof, [state.id], state.timeout)
        reason -> {:error, reason}
      end

    envelope =
      case reply do
        {:ok, result} when is_map(result) -> result
        :ok -> %{"ok" => true}
        {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
      end

    send(handler, {:transfer_ack, token})
    send(handler, {:transfer_complete, token, envelope})
    {:stop, :normal, state}
  end

  def handle_info(
        {:remote_write_stream_absolute_timeout, token},
        %{absolute_token: token} = state
      ) do
    stop_with_abort(state, :remote_write_stream_absolute_timeout)
  end

  def handle_info({:remote_write_stream_absolute_timeout, _stale}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    {:noreply, %{state | owner_monitor: nil, error: state.error || :disconnected}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{caller_monitor: monitor} = state
      ) do
    stop_with_abort(state, {:remote_write_stream_caller_down, reason})
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{handler_monitor: monitor} = state
      ) do
    stop_with_abort(state, {:remote_write_stream_transfer_down, reason})
  end

  @impl true
  def terminate(_reason, state) do
    if state.absolute_timer, do: Process.cancel_timer(state.absolute_timer)
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    if state.caller_monitor, do: Process.demonitor(state.caller_monitor, [:flush])
    if state.handler_monitor, do: Process.demonitor(state.handler_monitor, [:flush])
    Tokens.revoke(state.token)
    :ok
  end

  defp call_owner_write(owner, op, args, timeout) do
    ref = Process.monitor(owner)
    send(owner, List.to_tuple([:env_write_stream, op, ref, self() | args]))

    receive do
      {:env_write_stream_reply, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        {:error, :disconnected}
    after
      timeout ->
        send(owner, {:env_write_stream_cancel, ref, self()})
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp track_handler(%{handler: nil} = state, handler) when is_pid(handler) do
    %{state | handler: handler, handler_monitor: Process.monitor(handler)}
  end

  defp track_handler(%{handler: handler} = state, handler), do: state

  defp track_handler(state, _different_handler), do: state

  defp stop_with_abort(state, reason) do
    send(state.owner, {:env_write_stream_abort, state.id, reason})
    stop_with_transfer_error(state, reason)
  end

  defp stop_with_transfer_error(state, reason) do
    if is_pid(state.handler) do
      send(
        state.handler,
        {:transfer_complete, state.token, %{"ok" => false, "error" => inspect(reason)}}
      )
    end

    {:stop, :normal, %{state | error: state.error || reason}}
  end

  defp positive_timeout(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, fallback), do: fallback

  defp configured_absolute_timeout do
    Application.get_env(
      :salix_env,
      :connector_remote_write_stream_timeout_ms,
      @default_absolute_timeout_ms
    )
  end
end
