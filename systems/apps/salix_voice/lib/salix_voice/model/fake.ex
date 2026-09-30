defmodule SalixVoice.Model.Fake do
  @moduledoc """
  Test double for `SalixVoice.Model`.

  The fake reports every command to the process registered in
  `Application.get_env(:salix_voice, :fake_model_observer)` (or to
  `opts[:observer]`) as `{:fake_model, pid, command}`, where `command` is
  `{:started, opts}`, `{:audio, binary}`, `{:append, kind, delegation_id, text}`
  or `:close`. A test drives the model with `emit/2`, which delivers a
  normalized event to the owning call.

  `close/1` answers with `{:closed, "close_requested", %{"seconds" => n}}`,
  where `n` is `Application.get_env(:salix_voice, :fake_model_seconds, 0)`.
  """

  @behaviour SalixVoice.Model

  use GenServer

  @impl SalixVoice.Model
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl SalixVoice.Model
  def send_audio(pid, audio), do: GenServer.cast(pid, {:audio, audio})

  @impl SalixVoice.Model
  def append(pid, kind, delegation_id, text),
    do: GenServer.cast(pid, {:append, kind, delegation_id, text})

  @impl SalixVoice.Model
  def close(pid), do: GenServer.cast(pid, :close)

  @doc "Deliver a normalized model event to the owning call."
  def emit(pid, event), do: GenServer.cast(pid, {:emit, event})

  @impl GenServer
  def init(opts) do
    observer = opts[:observer] || Application.get_env(:salix_voice, :fake_model_observer)
    state = %{opts: opts, observer: observer}
    notify(state, {:started, Map.drop(opts, [:settings])})
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:emit, event}, state) do
    send(state.opts.owner, {:voice_model, state.opts.ref, event})
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    notify(state, :close)
    seconds = Application.get_env(:salix_voice, :fake_model_seconds, 0)

    send(
      state.opts.owner,
      {:voice_model, state.opts.ref, {:closed, "close_requested", %{"seconds" => seconds}}}
    )

    {:stop, :normal, state}
  end

  def handle_cast(command, state) do
    notify(state, command)
    {:noreply, state}
  end

  defp notify(%{observer: observer}, command) when is_pid(observer),
    do: send(observer, {:fake_model, self(), command})

  defp notify(%{observer: observer}, command) when is_atom(observer) and not is_nil(observer) do
    case Process.whereis(observer) do
      pid when is_pid(pid) -> send(pid, {:fake_model, self(), command})
      _ -> :ok
    end
  end

  defp notify(_state, _command), do: :ok
end
