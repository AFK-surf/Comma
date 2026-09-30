defmodule SalixEnv.FrameStream do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def chunk(pid, data, timeout \\ :infinity), do: GenServer.call(pid, {:chunk, data}, timeout)
  def eof(pid, timeout \\ :infinity), do: GenServer.call(pid, :eof, timeout)
  def fail(pid, reason), do: GenServer.cast(pid, {:fail, reason})
  def cancel(pid, reason), do: GenServer.cast(pid, {:cancel, reason})

  def stream(pid) do
    Stream.resource(
      fn -> pid end,
      fn pid ->
        case GenServer.call(pid, :next, :infinity) do
          {:chunk, chunk} -> {[chunk], pid}
          :eof -> {:halt, pid}
          {:error, reason} -> raise "connector stream failed: #{inspect(reason)}"
        end
      end,
      fn pid -> GenServer.cast(pid, :close) end
    )
  end

  @impl true
  def init(opts) do
    state = %{
      waiting: nil,
      queue: [],
      blocked: nil,
      eof: false,
      closed: false,
      error: nil,
      close_reason: nil,
      max_buffered_chunks: Keyword.get(opts, :max_buffered_chunks, 1),
      idle_timeout: Keyword.get(opts, :idle_timeout, :infinity),
      idle_timer: nil,
      idle_lease: nil,
      owner: Keyword.get(opts, :owner),
      id: Keyword.get(opts, :id)
    }

    {:ok, renew_idle(state)}
  end

  @impl true
  def handle_call({:chunk, _data}, _from, %{closed: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:chunk, data}, _from, %{waiting: waiting} = state) when not is_nil(waiting) do
    GenServer.reply(waiting, {:chunk, data})
    {:reply, :ok, renew_idle(%{state | waiting: nil})}
  end

  def handle_call(
        {:chunk, data},
        _from,
        %{queue: queue, max_buffered_chunks: max_buffered_chunks} = state
      )
      when length(queue) < max_buffered_chunks,
      do: {:reply, :ok, renew_idle(%{state | queue: state.queue ++ [data]})}

  def handle_call({:chunk, data}, from, %{blocked: nil} = state),
    do: {:noreply, renew_idle(%{state | blocked: {from, data}})}

  def handle_call(:eof, _from, %{closed: true} = state), do: {:reply, :ok, state}

  def handle_call(:eof, _from, %{waiting: waiting} = state) when not is_nil(waiting) do
    GenServer.reply(waiting, :eof)
    {:stop, :normal, :ok, %{state | waiting: nil, closed: true, close_reason: :completed}}
  end

  def handle_call(:eof, _from, state), do: {:reply, :ok, renew_idle(%{state | eof: true})}

  def handle_call(:next, _from, %{error: reason} = state) when not is_nil(reason),
    do: {:stop, :normal, {:error, reason}, %{state | close_reason: {:error, reason}}}

  def handle_call(:next, _from, %{queue: [data | rest], blocked: {producer, next_data}} = state) do
    GenServer.reply(producer, :ok)
    {:reply, {:chunk, data}, renew_idle(%{state | queue: rest ++ [next_data], blocked: nil})}
  end

  def handle_call(:next, _from, %{queue: [data | rest]} = state) do
    {:reply, {:chunk, data}, renew_idle(%{state | queue: rest})}
  end

  def handle_call(:next, _from, %{eof: true} = state),
    do: {:stop, :normal, :eof, %{state | closed: true, close_reason: :completed}}

  def handle_call(:next, _from, %{closed: true} = state), do: {:stop, :normal, :eof, state}
  def handle_call(:next, from, state), do: {:noreply, renew_idle(%{state | waiting: from})}

  @impl true
  def handle_cast({:fail, reason}, %{waiting: waiting, blocked: blocked} = state) do
    if waiting, do: GenServer.reply(waiting, {:error, reason})
    if blocked, do: GenServer.reply(elem(blocked, 0), {:error, reason})

    next = %{
      state
      | waiting: nil,
        blocked: nil,
        queue: [],
        error: reason,
        closed: true,
        close_reason: {:error, reason}
    }

    if waiting, do: {:stop, :normal, next}, else: {:noreply, renew_idle(next)}
  end

  def handle_cast({:cancel, reason}, %{waiting: waiting, blocked: blocked} = state) do
    if waiting, do: GenServer.reply(waiting, {:error, reason})
    if blocked, do: GenServer.reply(elem(blocked, 0), {:error, reason})

    {:stop, :normal,
     %{
       state
       | waiting: nil,
         blocked: nil,
         queue: [],
         error: reason,
         closed: true,
         close_reason: {:cancelled, reason}
     }}
  end

  def handle_cast(:close, %{blocked: blocked} = state) do
    if blocked, do: GenServer.reply(elem(blocked, 0), {:error, :closed})
    if state.waiting, do: GenServer.reply(state.waiting, {:error, :closed})

    {:stop, :normal,
     %{
       state
       | closed: true,
         blocked: nil,
         queue: [],
         waiting: nil,
         close_reason: :consumer_closed
     }}
  end

  @impl true
  def handle_info({:idle_timeout, lease}, %{idle_lease: lease} = state) do
    if state.waiting, do: GenServer.reply(state.waiting, {:error, :stream_idle_timeout})
    if state.blocked, do: GenServer.reply(elem(state.blocked, 0), {:error, :stream_idle_timeout})

    {:stop, :normal,
     %{state | closed: true, error: :stream_idle_timeout, close_reason: :stream_idle_timeout}}
  end

  def handle_info({:idle_timeout, _stale_lease}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{owner: owner, id: id, close_reason: close_reason})
      when is_pid(owner) and is_binary(id) do
    send(owner, {:frame_stream_closed, id, self(), close_reason})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp renew_idle(%{idle_timeout: :infinity} = state), do: state

  defp renew_idle(%{idle_timeout: timeout} = state) when is_integer(timeout) and timeout > 0 do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    lease = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, lease}, timeout)
    %{state | idle_timer: timer, idle_lease: lease}
  end

  defp renew_idle(state), do: state
end
