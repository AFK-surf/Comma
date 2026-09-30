defmodule CommaSSH.Channel do
  @moduledoc "One supervised TUI per verified SSH connection."
  @behaviour :ssh_server_channel
  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    {model, _} = CommaSSH.Model.init(%{})
    Process.send_after(self(), :check, 30_000)

    {:ok,
     %{
       connection: nil,
       channel: nil,
       pty: false,
       started: false,
       size: {80, 24},
       model: model,
       input: %CommaTUI.Input{},
       frame: [],
       render: nil,
       backend: nil,
       pending: nil
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel, connection}, state),
    do: {:ok, %{state | channel: channel, connection: connection}}

  def handle_msg({:ui, event}, state) do
    {model, _} = CommaSSH.Model.update(event, state.model)
    {:ok, schedule(%{state | model: %{model | busy: state.pending != nil}})}
  end

  def handle_msg(:done, state) do
    if state.pending, do: Process.cancel_timer(state.pending)
    {model, []} = CommaSSH.Model.update(:ready, state.model)
    {:ok, schedule(%{state | pending: nil, model: model})}
  end

  def handle_msg(:check, %{started: true, pending: nil} = state) do
    Process.send_after(self(), :check, 30_000)
    GenServer.cast(state.backend, :check)

    {:ok,
     schedule(%{
       state
       | pending: :erlang.start_timer(20_000, self(), :operation_timeout),
         model: %{state.model | busy: true}
     })}
  end

  def handle_msg(:check, state) do
    Process.send_after(self(), :check, 1_000)
    {:ok, state}
  end

  def handle_msg({:timeout, timer, :operation_timeout}, %{pending: timer} = state) do
    stop(
      state,
      1,
      "Operation timed out. Reconnect and check history before resending; accepted work may continue."
    )
  end

  def handle_msg({:timeout, _stale, :operation_timeout}, state), do: {:ok, state}

  def handle_msg(:service_unavailable, state),
    do:
      stop(
        state,
        1,
        "Service unavailable. Reconnect and check history before resending; accepted work may continue."
      )

  def handle_msg(:close, state), do: stop(state)

  def handle_msg({:EXIT, pid, _}, %{backend: pid} = state),
    do: stop(state, 1, "Service connection ended. Reconnect and check history before resending.")

  def handle_msg(:render, state) do
    {bytes, frame} =
      CommaTUI.Screen.render(CommaSSH.Model.view(state.model), state.size, state.frame)

    if queue_ok?() and send_bytes(state, bytes) == :ok do
      {:ok, %{state | frame: frame, render: nil}}
    else
      stop(state)
    end
  end

  def handle_msg(_, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg({:ssh_cm, _, {:pty, _, reply, {term, width, height, _, _, _}}}, state) do
    width = if width == 0, do: 80, else: width
    height = if height == 0, do: 24, else: height
    accepted = not state.started and term != ~c"dumb" and width >= 20 and height >= 8
    reply(state, reply, if(accepted, do: :success, else: :failure))
    size = CommaTUI.Screen.size(width, height)
    {model, []} = CommaSSH.Model.update({:resize, size}, state.model)
    {:ok, %{state | pty: accepted, size: size, model: model}}
  end

  def handle_ssh_msg({:ssh_cm, _, {:shell, _, wants_reply}}, %{pty: true, started: false} = state) do
    case CommaSSH.Connections.claim(state.connection) do
      {:ok, context} ->
        reply(state, wants_reply, :success)
        :ok = send_bytes(state, CommaTUI.Screen.enter())
        {:ok, backend} = CommaSSH.Session.start_link(Map.put(context, :ui, self()))

        {:ok,
         schedule(%{
           state
           | backend: backend,
             started: true,
             pending: :erlang.start_timer(20_000, self(), :operation_timeout)
         })}

      _ ->
        stop(state)
    end
  end

  def handle_ssh_msg({:ssh_cm, _, {:shell, _, wants_reply}}, state) do
    reply(state, wants_reply, :failure)
    stop(state)
  end

  def handle_ssh_msg({:ssh_cm, _, {:window_change, _, width, height, _, _}}, state) do
    size = CommaTUI.Screen.size(width, height)
    {model, []} = CommaSSH.Model.update({:resize, size}, state.model)
    {:ok, schedule(%{state | size: size, model: model, frame: []})}
  end

  def handle_ssh_msg({:ssh_cm, _, {:data, _, 0, bytes}}, %{started: true} = state) do
    case CommaTUI.Input.feed(state.input, bytes) do
      {:ok, events, input} ->
        state = %{state | input: input}

        Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
          {model, effects} = CommaSSH.Model.update(event, current.model)
          next = %{current | model: model}

          cond do
            :quit in effects ->
              {:halt, stop(next, 0)}

            effects != [] and next.pending == nil ->
              Enum.each(effects, &GenServer.cast(next.backend, &1))

              {:cont,
               {:ok,
                schedule(%{
                  next
                  | pending: :erlang.start_timer(20_000, self(), :operation_timeout)
                })}}

            true ->
              {:cont, {:ok, schedule(next)}}
          end
        end)

      _ ->
        stop(state)
    end
  end

  def handle_ssh_msg({:ssh_cm, _, {kind, _}}, state) when kind in [:eof, :closed], do: stop(state)

  def handle_ssh_msg({:ssh_cm, _, request}, state)
      when elem(request, 0) in [:exec, :subsystem, :env, :shell] do
    reply(state, elem(request, 2), :failure)
    {:ok, state}
  end

  def handle_ssh_msg(_, state), do: {:ok, state}

  @impl true
  def terminate(_, state) do
    try do
      if state.backend && Process.alive?(state.backend),
        do: GenServer.stop(state.backend, :normal, 2_000)
    catch
      :exit, _ -> if state.backend, do: Process.exit(state.backend, :kill)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp reply(state, wants_reply, result),
    do: :ssh_connection.reply_request(state.connection, wants_reply, result, state.channel)

  defp send_bytes(_, ""), do: :ok

  defp send_bytes(state, bytes),
    do: :ssh_connection.send(state.connection, state.channel, bytes, 2_000)

  defp stop(state, status \\ 1, message \\ nil) do
    # OTP closes the channel before invoking terminate/2. Restore terminal modes
    # and send the exit status here, while the peer can still receive them.
    if state.started do
      send_bytes(state, CommaTUI.Screen.leave())
      if message, do: send_bytes(state, "\r\nComma: " <> message <> "\r\n")
    end

    :ssh_connection.exit_status(state.connection, state.channel, status)
    :ssh_connection.send_eof(state.connection, state.channel)
    {:stop, state.channel, %{state | started: false}}
  end

  defp schedule(%{render: nil} = state),
    do: %{state | render: Process.send_after(self(), :render, 50)}

  defp schedule(state), do: state
  defp queue_ok?, do: elem(Process.info(self(), :message_queue_len), 1) < 256
end
