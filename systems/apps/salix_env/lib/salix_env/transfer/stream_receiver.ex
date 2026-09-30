defmodule SalixEnv.Transfer.StreamReceiver do
  @moduledoc """
  Caller-owned receiver for bounded cross-node byte forwarding.

  Connector remote-read worker ownership is modeled in
  `tla/salix/ConnectorReadStream.tla`.
  """
  use GenServer

  alias SalixEnv.Transfer.Tokens

  @default_idle_timeout_ms 30_000
  @default_absolute_timeout_ms 305_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def attach_worker(pid, worker), do: GenServer.call(pid, {:attach_worker, worker})

  def register!(pid) do
    token = Tokens.register(owner: pid)
    GenServer.call(pid, {:token, token})
    {token, SalixEnv.Transfer.advertise_url(token), stream(pid)}
  end

  def fail(pid, reason), do: GenServer.cast(pid, {:fail, reason})

  def stream(pid) do
    Stream.resource(
      fn -> pid end,
      fn pid ->
        case GenServer.call(pid, :next, :infinity) do
          {:chunk, chunk} -> {[chunk], pid}
          :eof -> {:halt, pid}
          {:error, reason} -> raise "transfer stream failed: #{inspect(reason)}"
        end
      end,
      fn pid -> GenServer.cast(pid, :close) end
    )
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner)

    idle_timeout =
      positive_timeout(Keyword.get(opts, :idle_timeout_ms), @default_idle_timeout_ms)

    absolute_timeout =
      positive_timeout(Keyword.get(opts, :absolute_timeout_ms), @default_absolute_timeout_ms)

    absolute_token = make_ref()

    state = %{
      token: nil,
      waiting: nil,
      pending: nil,
      eof: nil,
      closed: false,
      error: nil,
      owner_monitor: if(is_pid(owner), do: Process.monitor(owner)),
      worker: nil,
      worker_monitor: nil,
      idle_timeout: idle_timeout,
      idle_timer: nil,
      idle_token: nil,
      absolute_timer:
        Process.send_after(
          self(),
          {:remote_read_stream_absolute_timeout, absolute_token},
          absolute_timeout
        ),
      absolute_token: absolute_token
    }

    {:ok, renew_idle(state)}
  end

  @impl true
  def handle_call({:token, token}, _from, state),
    do: {:reply, :ok, renew_idle(%{state | token: token})}

  def handle_call({:attach_worker, worker}, _from, state) when is_pid(worker) do
    monitor = Process.monitor(worker)
    {:reply, :ok, renew_idle(%{state | worker: worker, worker_monitor: monitor})}
  end

  def handle_call(:next, _from, %{pending: {handler, chunk}, token: token} = state) do
    send(handler, {:transfer_ack, token})
    {:reply, {:chunk, chunk}, renew_idle(%{state | pending: nil})}
  end

  def handle_call(:next, _from, %{eof: handler, token: token} = state) when not is_nil(handler) do
    send(handler, {:transfer_ack, token})
    send(handler, {:transfer_complete, token, %{"ok" => true}})
    {:stop, :normal, :eof, %{state | eof: nil, closed: true}}
  end

  def handle_call(:next, _from, %{error: reason} = state) when not is_nil(reason),
    do: {:stop, :normal, {:error, reason}, state}

  def handle_call(:next, _from, %{closed: true} = state), do: {:reply, :eof, state}
  def handle_call(:next, from, state), do: {:noreply, %{state | waiting: from}}

  @impl true
  def handle_info(
        {:transfer_chunk, token, handler, chunk},
        %{token: token, waiting: waiting} = state
      )
      when not is_nil(waiting) do
    GenServer.reply(waiting, {:chunk, chunk})
    send(handler, {:transfer_ack, token})
    {:noreply, renew_idle(%{state | waiting: nil})}
  end

  def handle_info({:transfer_chunk, token, handler, chunk}, %{token: token} = state) do
    {:noreply, renew_idle(%{state | pending: {handler, chunk}})}
  end

  def handle_info({:transfer_eof, token, handler}, %{token: token, waiting: waiting} = state)
      when not is_nil(waiting) do
    GenServer.reply(waiting, :eof)
    send(handler, {:transfer_ack, token})
    send(handler, {:transfer_complete, token, %{"ok" => true}})
    {:noreply, renew_idle(%{state | waiting: nil, closed: true})}
  end

  def handle_info({:transfer_eof, token, handler}, %{token: token} = state) do
    {:noreply, renew_idle(%{state | eof: handler})}
  end

  def handle_info({:remote_read_stream_idle_timeout, token}, %{idle_token: token} = state) do
    stop_for_deadline(state, :remote_read_stream_idle_timeout)
  end

  def handle_info({:remote_read_stream_idle_timeout, _stale}, state), do: {:noreply, state}

  def handle_info(
        {:remote_read_stream_absolute_timeout, token},
        %{absolute_token: token} = state
      ) do
    stop_for_deadline(state, :timeout)
  end

  def handle_info({:remote_read_stream_absolute_timeout, _stale}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, {:shutdown, :owner_down}, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{worker_monitor: monitor} = state
      ) do
    state = %{state | worker: nil, worker_monitor: nil}

    if state.closed or not is_nil(state.eof) or not is_nil(state.error) do
      {:noreply, state}
    else
      fail_state(state, {:remote_read_stream_exit, reason})
    end
  end

  @impl true
  def handle_cast({:fail, reason}, state), do: fail_state(state, reason)

  def handle_cast(:close, state), do: {:stop, :normal, %{state | closed: true}}

  @impl true
  def terminate(_reason, state) do
    abort_waiting_transfer(state, state.error || :remote_read_stream_receiver_closed)
    if is_pid(state.worker), do: Process.exit(state.worker, :kill)
    if state.worker_monitor, do: Process.demonitor(state.worker_monitor, [:flush])
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.absolute_timer, do: Process.cancel_timer(state.absolute_timer)
    if is_binary(state.token), do: Tokens.revoke(state.token)
    :ok
  end

  defp fail_state(%{waiting: waiting} = state, reason) do
    if waiting, do: GenServer.reply(waiting, {:error, reason})

    {:noreply, renew_idle(%{state | waiting: nil, error: reason, closed: true})}
  end

  defp stop_for_deadline(state, reason) do
    if state.waiting, do: GenServer.reply(state.waiting, {:error, reason})

    {:stop, :normal, %{state | waiting: nil, error: reason, closed: true, idle_timer: nil}}
  end

  defp abort_waiting_transfer(%{token: token, pending: {handler, _chunk}}, reason)
       when is_binary(token) and is_pid(handler) do
    send(handler, {:transfer_ack, token})
    send(handler, {:transfer_complete, token, transfer_error(reason)})
    :ok
  end

  defp abort_waiting_transfer(%{token: token, eof: handler}, reason)
       when is_binary(token) and is_pid(handler) do
    send(handler, {:transfer_ack, token})
    send(handler, {:transfer_complete, token, transfer_error(reason)})
    :ok
  end

  defp abort_waiting_transfer(_state, _reason), do: :ok

  defp transfer_error(reason), do: %{"ok" => false, "error" => inspect(reason)}

  defp renew_idle(%{idle_timeout: timeout} = state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    token = make_ref()

    timer =
      Process.send_after(self(), {:remote_read_stream_idle_timeout, token}, timeout)

    %{state | idle_timer: timer, idle_token: token}
  end

  defp positive_timeout(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, fallback), do: fallback
end
