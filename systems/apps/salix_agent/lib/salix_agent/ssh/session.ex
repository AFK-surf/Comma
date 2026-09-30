defmodule SalixAgent.SSH.Session do
  @moduledoc """
  One outbound SSH session: an SSH connection with one interactive PTY shell,
  owned by one Agent session (`{agent_id, session_id}`).

  The process owns the connection and the shell channel. Remote output goes
  into a bounded byte ring (`SalixAgent.SSH.Output`) for `ssh.read` and
  through a VT100 emulator (`SalixVerifiedKernel.Terminal`, in Lean) for
  `ssh.screen`. The
  SSH window is refilled only after the emulator has processed a chunk, so a
  flood of output slows the remote side instead of this node.

  Callers that wait for output (`ssh.open`, `ssh.write`, `ssh.read`) are kept
  as waiters and answered when their condition holds: the text they expect
  appeared, output went quiet, the session closed, or their deadline passed.

  The session is not durable and is never reconnected or replayed. It closes
  on `ssh.close`, when the remote shell ends or the connection drops, after
  #{30} minutes without a tool call, and after #{8} hours. It is supervised
  under its session actor (`SalixAgent.SSH.Sessions`), so it also ends when
  that actor ends. A closed session answers with its final output and close
  reason for #{5} minutes, then exits.
  """

  use GenServer, restart: :temporary, shutdown: 5_000

  alias SalixAgent.SSH.{Connection, Output}
  alias SalixVerifiedKernel.Terminal

  @registry SalixAgent.SSH.Registry
  @window 262_144
  @packet 32_768
  @channel_timeout_ms 10_000
  @output_bytes 1_048_576
  @idle_ms :timer.minutes(30)
  @lifetime_ms :timer.hours(8)
  @closed_grace_ms :timer.minutes(5)
  @failed_grace_ms :timer.minutes(1)
  @check_ms :timer.seconds(30)
  @tick_ms 100
  @settle_ms 500
  @open_wait_ms 3_000
  @until_overlap 512

  @keys %{
    "enter" => "\r",
    "tab" => "\t",
    "esc" => "\e",
    "backspace" => <<0x7F>>,
    "delete" => "\e[3~",
    "page_up" => "\e[5~",
    "page_down" => "\e[6~"
  }
  @cursor_keys %{
    "up" => "A",
    "down" => "B",
    "right" => "C",
    "left" => "D",
    "home" => "H",
    "end" => "F"
  }

  @doc "Named keys `ssh.write` accepts."
  def key_names do
    Map.keys(@keys) ++ Map.keys(@cursor_keys) ++ for(c <- ?a..?z, do: "ctrl_" <> <<c>>)
  end

  def start_link(spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "Call a session; a session that is gone answers `{:error, :not_found}`."
  def request(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :busy}
    :exit, _ -> {:error, :not_found}
  end

  # ---- lifecycle -----------------------------------------------------------------

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)
    now = now_ms()

    state = %{
      spec: spec,
      status: :connecting,
      conn: nil,
      channel: nil,
      ref: make_ref(),
      host_key: nil,
      open_error: nil,
      close_reason: nil,
      close_detail: nil,
      exit_status: nil,
      exit_signal: nil,
      term: Terminal.new(spec.cols, spec.rows),
      out: Output.new(@output_bytes),
      waiters: [],
      tick: false,
      started_at: now,
      opened_at: nil,
      last_activity: now,
      last_data_at: now
    }

    case Registry.register(@registry, key(spec), registry_value(state)) do
      {:ok, _} -> {:ok, state, {:continue, :connect}}
      {:error, {:already_registered, pid}} -> {:stop, {:already_started, pid}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case Connection.connect(state.spec, state.ref) do
      {:ok, conn, host_key, spec} ->
        state = %{state | conn: conn, host_key: host_key, spec: spec}

        case start_shell(state) do
          {:ok, channel} ->
            Process.send_after(self(), :check, @check_ms)
            now = now_ms()

            state =
              update_registry(%{
                state
                | status: :open,
                  channel: channel,
                  opened_at: now,
                  last_data_at: now
              })

            {:noreply, state}

          {:error, reason} ->
            safe_close(conn)

            {:noreply,
             fail(
               state,
               Connection.diagnostic(
                 "shell_refused",
                 "The host accepted the connection but refused an interactive shell.",
                 %{"host" => state.spec.host, "reason" => inspect(reason)}
               )
             )}
        end

      {:error, diagnostic} ->
        {:noreply, fail(state, diagnostic)}
    end
  end

  defp start_shell(state) do
    spec = state.spec

    with {:ok, channel} <-
           :ssh_connection.session_channel(state.conn, @window, @packet, @channel_timeout_ms),
         :success <-
           :ssh_connection.ptty_alloc(
             state.conn,
             channel,
             [term: String.to_charlist(spec.term), width: spec.cols, height: spec.rows],
             @channel_timeout_ms
           ),
         :ok <- :ssh_connection.shell(state.conn, channel) do
      {:ok, channel}
    else
      other -> {:error, other}
    end
  end

  defp fail(state, diagnostic) do
    Process.send_after(self(), :expire, @failed_grace_ms)
    update_registry(%{state | status: :failed, open_error: diagnostic})
  end

  @impl true
  def terminate(_reason, state) do
    safe_close(state.conn)
    :ok
  end

  # ---- calls -----------------------------------------------------------------------

  @impl true
  def handle_call(:await_open, _from, %{status: :failed} = state),
    do: {:reply, {:error, state.open_error}, state}

  def handle_call(:await_open, from, state) do
    waiter = waiter(from, :open, 0, %{wait_ms: @open_wait_ms})
    {:noreply, state |> touch() |> add_waiter(waiter)}
  end

  def handle_call(_request, _from, %{status: :failed} = state),
    do: {:reply, {:error, state.open_error}, state}

  def handle_call({:write, input, keys, opts}, from, %{status: :open} = state) do
    state = touch(state)
    bytes = [input | Enum.map(keys, &encode_key(&1, state.term))]
    offset = state.out.next

    case :ssh_connection.send(state.conn, state.channel, bytes, @channel_timeout_ms) do
      :ok ->
        {:noreply, add_waiter(state, waiter(from, :write, offset, opts))}

      {:error, reason} ->
        {:reply, {:error, write_failed(state, reason)}, state}
    end
  end

  def handle_call({:write, _input, _keys, _opts}, _from, state),
    do: {:reply, {:error, closed_error(state)}, state}

  def handle_call({:read, opts}, from, state) do
    state = touch(state)

    offset =
      case opts do
        %{tail_bytes: tail} when is_integer(tail) -> Output.tail_start(state.out, tail)
        %{from_offset: from_offset} when is_integer(from_offset) -> from_offset
        _ -> state.out.base
      end

    waiter = waiter(from, :read, offset, opts)

    if waiter.deadline <= now_ms() or state.status != :open do
      {:reply, {:ok, result(state, waiter)}, state}
    else
      {:noreply, add_waiter(state, waiter)}
    end
  end

  def handle_call(:screen, _from, state) do
    state = touch(state)

    screen =
      state.term
      |> Terminal.snapshot()
      |> Map.merge(summary(state))
      |> Map.put("next_offset", state.out.next)

    {:reply, {:ok, screen}, state}
  end

  def handle_call({:resize, cols, rows}, _from, %{status: :open} = state) do
    state = touch(state)
    {cols, rows} = Terminal.clamp_size(cols, rows)
    term = Terminal.resize(state.term, cols, rows)
    :ssh_connection.window_change(state.conn, state.channel, cols, rows)

    {:reply, {:ok, Map.merge(summary(state), %{"cols" => cols, "rows" => rows})},
     %{state | term: term}}
  end

  def handle_call({:resize, _cols, _rows}, _from, state),
    do: {:reply, {:error, closed_error(state)}, state}

  def handle_call({:close, reason}, _from, state) do
    state = close(state, reason, nil)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:connection, _from, %{status: :open} = state) do
    state = touch(state)
    {:reply, {:ok, state.conn, summary(state)}, state}
  end

  def handle_call(:connection, _from, state), do: {:reply, {:error, closed_error(state)}, state}

  def handle_call(:info, _from, state), do: {:reply, {:ok, summary(state)}, state}

  # ---- remote traffic ----------------------------------------------------------------

  @impl true
  def handle_info({:ssh_cm, conn, message}, %{conn: conn} = state) do
    {:noreply, channel_message(message, state)}
  end

  def handle_info({ref, {:disconnected, reason}}, %{ref: ref} = state),
    do: {:noreply, close(state, "disconnected", reason_text(reason))}

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) when conn != nil,
    do: {:noreply, close(%{state | conn: nil}, "disconnected", reason_text(reason))}

  # The supervisor's exit is handled by gen_server itself.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, evaluate_waiters(%{state | tick: false})}

  def handle_info(:check, %{status: :open} = state) do
    now = now_ms()

    cond do
      now - state.last_activity >= @idle_ms ->
        {:noreply, close(state, "idle_timeout", nil)}

      now - state.opened_at >= @lifetime_ms ->
        {:noreply, close(state, "max_lifetime", nil)}

      true ->
        Process.send_after(self(), :check, @check_ms)
        {:noreply, state}
    end
  end

  def handle_info(:check, state), do: {:noreply, state}
  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp channel_message({:data, channel, _type, data}, %{channel: channel} = state) do
    {term, replies} = Terminal.feed(state.term, data)

    if replies != "",
      do: :ssh_connection.send(state.conn, channel, replies, @channel_timeout_ms)

    # Refill the window only after the emulator caught up.
    :ssh_connection.adjust_window(state.conn, channel, byte_size(data))

    %{state | term: term, out: Output.append(state.out, data), last_data_at: now_ms()}
    |> search_waiters()
    |> evaluate_waiters()
  end

  defp channel_message({:exit_status, channel, status}, %{channel: channel} = state),
    do: %{state | exit_status: status}

  defp channel_message(
         {:exit_signal, channel, signal, _message, _lang},
         %{channel: channel} = state
       ),
       do: %{state | exit_signal: to_string(signal)}

  defp channel_message({:closed, channel}, %{channel: channel} = state),
    do: close(state, "shell_exited", nil)

  defp channel_message(_message, state), do: state

  # ---- closing ---------------------------------------------------------------------------

  defp close(%{status: status} = state, _reason, _detail) when status in [:closed, :failed],
    do: state

  defp close(state, reason, detail) do
    safe_close(state.conn)
    Process.send_after(self(), :expire, @closed_grace_ms)

    %{state | status: :closed, close_reason: reason, close_detail: detail}
    |> update_registry()
    |> evaluate_waiters()
  end

  # ---- waiters -------------------------------------------------------------------------------

  defp waiter(from, kind, offset, opts) do
    %{
      from: from,
      kind: kind,
      offset: offset,
      deadline: now_ms() + Map.get(opts, :wait_ms, 0),
      until: Map.get(opts, :until_text),
      max_bytes: Map.get(opts, :max_bytes, 65_536),
      raw: Map.get(opts, :raw, false),
      searched: offset,
      matched: false
    }
  end

  defp add_waiter(state, waiter) do
    state = %{state | waiters: [search(waiter, state.out) | state.waiters]}
    evaluate_waiters(state)
  end

  defp search_waiters(state),
    do: %{state | waiters: Enum.map(state.waiters, &search(&1, state.out))}

  # Search only output the waiter has not seen, plus a short overlap so a
  # match split across chunks is found. Raw bytes and escape-free text both
  # count, so a colored prompt still matches.
  defp search(%{until: nil} = waiter, _out), do: waiter
  defp search(%{matched: true} = waiter, _out), do: waiter

  defp search(waiter, out) do
    from = Enum.max([waiter.searched - @until_overlap, waiter.offset, out.base])

    if out.next <= from do
      waiter
    else
      {_start, bytes} = Output.slice(out, from, out.next - from)

      matched =
        String.contains?(bytes, waiter.until) or
          String.contains?(Output.text(bytes), waiter.until)

      %{waiter | searched: out.next, matched: matched}
    end
  end

  defp evaluate_waiters(%{waiters: []} = state), do: state

  defp evaluate_waiters(state) do
    now = now_ms()

    {done, waiting} = Enum.split_with(state.waiters, &done?(&1, state, now))
    Enum.each(done, &GenServer.reply(&1.from, {:ok, result(state, &1)}))
    state = %{state | waiters: waiting}

    if waiting != [] and not state.tick do
      Process.send_after(self(), :tick, @tick_ms)
      %{state | tick: true}
    else
      state
    end
  end

  defp done?(waiter, state, now) do
    cond do
      state.status != :open -> true
      waiter.matched -> true
      now >= waiter.deadline -> true
      waiter.until != nil -> false
      state.out.next > waiter.offset and now - state.last_data_at >= @settle_ms -> true
      true -> false
    end
  end

  defp result(state, waiter) do
    {start, bytes} = Output.slice(state.out, waiter.offset, waiter.max_bytes)

    output =
      if waiter.raw,
        do: %{"output_base64" => Base.encode64(bytes)},
        else: %{"output" => Output.text(bytes)}

    state
    |> summary()
    |> Map.merge(output)
    |> Map.merge(%{
      "offset" => start,
      "next_offset" => start + byte_size(bytes),
      "truncated" => start > waiter.offset,
      "more" => start + byte_size(bytes) < state.out.next
    })
    |> then(fn result ->
      if waiter.until, do: Map.put(result, "matched", waiter.matched), else: result
    end)
    |> then(fn result ->
      if waiter.kind == :open, do: Map.put(result, "host_key", state.host_key), else: result
    end)
  end

  # ---- helpers ----------------------------------------------------------------------------------

  defp encode_key("ctrl_" <> <<c>>, _term) when c in ?a..?z, do: <<c - ?a + 1>>

  defp encode_key(name, term) do
    case @cursor_keys do
      %{^name => final} ->
        if Terminal.application_cursor?(term), do: "\eO" <> final, else: "\e[" <> final

      _ ->
        Map.fetch!(@keys, name)
    end
  end

  defp summary(state) do
    spec = state.spec

    %{
      "ssh_session_id" => spec.id,
      "status" => to_string(state.status),
      "host" => spec.host,
      "port" => spec.port,
      "user" => spec.user,
      "term" => spec.term
    }
    |> put_present("close_reason", state.close_reason)
    |> put_present("close_detail", state.close_detail)
    |> put_present("exit_status", state.exit_status)
    |> put_present("exit_signal", state.exit_signal)
  end

  defp closed_error(%{status: :connecting} = state) do
    Connection.diagnostic(
      "session_connecting",
      "The SSH session is still connecting.",
      summary(state)
    )
  end

  defp closed_error(state) do
    Connection.diagnostic(
      "session_closed",
      "The SSH session is closed (#{state.close_reason}). Open a new session with ssh.open; commands are never replayed automatically.",
      summary(state)
    )
  end

  defp write_failed(state, reason) do
    Connection.diagnostic(
      "write_failed",
      "Input could not be sent; it may have been partly delivered. Check the screen before retrying.",
      Map.put(summary(state), "reason", inspect(reason))
    )
  end

  defp touch(state), do: %{state | last_activity: now_ms()}

  defp safe_close(nil), do: :ok

  defp safe_close(conn) do
    :ssh.close(conn)
  catch
    _, _ -> :ok
  end

  defp key(spec), do: {spec.agent_id, spec.session_id, spec.id}

  defp registry_value(state) do
    %{
      status: state.status,
      host: state.spec.host,
      port: state.spec.port,
      user: state.spec.user,
      started_at: state.started_at
    }
  end

  defp update_registry(state) do
    Registry.update_value(@registry, key(state.spec), fn _ -> registry_value(state) end)
    state
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reason_text(reason) when is_list(reason), do: List.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
