defmodule SalixEnv.Transfer.StreamSender do
  @moduledoc false
  use GenServer

  def start_link(url) do
    GenServer.start_link(__MODULE__, url)
  end

  def chunk(pid, data), do: GenServer.call(pid, {:chunk, data}, :infinity)
  def eof(pid), do: GenServer.call(pid, :eof, :infinity)
  def result(pid), do: GenServer.call(pid, :result, :infinity)

  def stream(pid) do
    Stream.resource(
      fn -> pid end,
      fn pid ->
        case GenServer.call(pid, :next, :infinity) do
          {:chunk, chunk} -> {[chunk], pid}
          :eof -> {:halt, pid}
        end
      end,
      fn _ -> :ok end
    )
  end

  @impl true
  def init(url) do
    parent = self()

    {:ok, task} =
      Task.start(fn ->
        result = SalixEnv.Transfer.send_stream(url, stream(parent))
        send(parent, {:upload_result, result})
      end)

    {:ok,
     %{
       task: task,
       waiting: nil,
       producer: nil,
       pending: nil,
       eof_from: nil,
       result: nil,
       result_waiters: []
     }}
  end

  @impl true
  def handle_call({:chunk, data}, _from, %{waiting: waiting} = state) when not is_nil(waiting) do
    GenServer.reply(waiting, {:chunk, data})
    {:reply, :ok, %{state | waiting: nil}}
  end

  def handle_call({:chunk, data}, from, state),
    do: {:noreply, %{state | producer: from, pending: data}}

  def handle_call(:eof, _from, %{waiting: waiting} = state) when not is_nil(waiting) do
    GenServer.reply(waiting, :eof)
    {:reply, :ok, %{state | waiting: nil}}
  end

  def handle_call(:eof, from, state), do: {:noreply, %{state | eof_from: from}}

  def handle_call(:next, _from, %{pending: data, producer: producer} = state)
      when not is_nil(producer) do
    GenServer.reply(producer, :ok)
    {:reply, {:chunk, data}, %{state | pending: nil, producer: nil}}
  end

  def handle_call(:next, _from, %{eof_from: eof_from} = state) when not is_nil(eof_from) do
    GenServer.reply(eof_from, :ok)
    {:reply, :eof, %{state | eof_from: nil}}
  end

  def handle_call(:next, from, state), do: {:noreply, %{state | waiting: from}}

  def handle_call(:result, from, %{result: nil} = state),
    do: {:noreply, %{state | result_waiters: [from | state.result_waiters]}}

  def handle_call(:result, _from, %{result: result} = state), do: {:reply, result, state}

  @impl true
  def handle_info({:upload_result, result}, state) do
    for waiter <- state.result_waiters, do: GenServer.reply(waiter, result)
    {:noreply, %{state | result: result, result_waiters: []}}
  end
end
