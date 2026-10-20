defmodule SalixMeetNative.FakeSession do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def emit(pid, msg), do: GenServer.cast(pid, {:emit, msg})
  def send_chat(pid, text, message_id), do: GenServer.call(pid, {:send_chat, text, message_id})

  def set_caption_lang(pid, display, spoken),
    do: GenServer.call(pid, {:set_caption_lang, display, spoken})

  def leave(pid), do: GenServer.call(pid, :leave)

  @impl true
  def init(opts) do
    send(opts[:test_pid], {:fake_session, self(), Keyword.drop(opts, [:test_pid, :subscriber])})
    {:ok, %{subscriber: opts[:subscriber], test: opts[:test_pid]}}
  end

  @impl true
  def handle_cast({:emit, {:crash, reason}}, state), do: {:stop, reason, state}

  def handle_cast({:emit, msg}, state) do
    send(state.subscriber, {:meet_native, self(), msg})
    {:noreply, state}
  end

  @impl true
  def handle_call(request, _from, state) do
    send(state.test, {:fake_call, request})

    case request do
      :leave ->
        send(state.subscriber, {:meet_native, self(), {:ended, :left}})
        {:stop, :normal, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end
end
