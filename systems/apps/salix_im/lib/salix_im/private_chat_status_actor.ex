defmodule SalixIM.PrivateChatStatusActor do
  @moduledoc """
  One ephemeral activity surface per managed private chat/topic on the Router
  owner. Like SlackRouterStatusActor, reads canonical SessionActivity and gates
  it by accepted source IDs. Never consumes participant drafts/private reasoning.

  Only the native typing indicator is published, never status text or drafts. No new
  durable protocol is introduced: a crash/owner change loses presentation only;
  the next accepted input recreates it. Input delivery and answers are unchanged.
  """
  use GenServer

  alias SalixIM.Ports.SessionActivity

  alias SalixIM.{
    GroupDirectory,
    ProviderConnects,
    PrivateChatStatusPlacement,
    SignalStatusTransport,
    TelegramStatusTransport,
    WeChatStatusTransport
  }

  @refresh_ms 4_000
  @signal_refresh_ms 10_000
  @idle_ms 60_000
  @max_age_ms 30 * 60_000

  def key(connect, metadata),
    do:
      {connect["group_id"], connect["connect_id"], metadata["chat_id"] || metadata["wechat_id"],
       metadata["message_thread_id"] || ""}

  def child_spec(opts),
    do: %{
      id: {__MODULE__, key(opts[:connect], opts[:metadata])},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  def start_link(opts) do
    name =
      {:via, Registry, {SalixIM.PrivateChatStatusRegistry, key(opts[:connect], opts[:metadata])}}

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def activate(pid, source_id, session_id),
    do: GenServer.cast(pid, {:activate, source_id, session_id})

  def reply_sent(pid), do: GenServer.cast(pid, :reply_sent)

  @impl true
  def init(opts) do
    connect = Keyword.fetch!(opts, :connect)
    Process.send_after(self(), :unactivated, @idle_ms)

    {:ok,
     %{
       provider: connect["provider"],
       transport: transport(connect["provider"]),
       typing_ticket: nil,
       typing?: false,
       group_id: connect["group_id"],
       connect_id: connect["connect_id"],
       agent_id: Keyword.fetch!(opts, :agent_id),
       session_id: nil,
       target:
         Map.take(
           Keyword.fetch!(opts, :metadata),
           ~w(chat_id chat_type message_thread_id wechat_id)
         ),
       sources: [],
       subscribed?: false,
       timer: nil,
       next_at: now(),
       idle_until: now() + @idle_ms,
       expires_at: now() + @max_age_ms,
       refresh_ms: Keyword.get(opts, :refresh_ms, refresh_ms(connect["provider"]))
     }}
  end

  defp transport("wechat"), do: WeChatStatusTransport
  defp transport("signal"), do: SignalStatusTransport
  defp transport(_provider), do: TelegramStatusTransport

  # Each Signal typing indicator is an encrypted message to the peer, and
  # Signal clients keep one visible for 15 seconds.
  defp refresh_ms("signal"), do: @signal_refresh_ms
  defp refresh_ms(_provider), do: @refresh_ms

  @impl true
  def handle_cast(:reply_sent, state), do: {:noreply, state}

  def handle_cast({:activate, source_id, session_id}, state) do
    prefix = "im_provider:#{state.provider}:#{state.connect_id}:"

    if is_binary(source_id) and String.starts_with?(source_id, prefix) and
         is_binary(session_id) and session_id != "" do
      state = switch_session(state, session_id)
      sources = [source_id | Enum.reject(state.sources, &(&1 == source_id))] |> Enum.take(32)
      {:noreply, schedule(%{state | sources: sources, idle_until: now() + @idle_ms})}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:unactivated, %{session_id: nil} = state), do: {:stop, :normal, state}

  def handle_info({:session_activity_updated, agent_id, session_id}, state)
      when agent_id == state.agent_id and session_id == state.session_id,
      do: {:noreply, schedule(state)}

  def handle_info({:tick, token}, %{timer: {_, token}} = state) do
    state = %{state | timer: nil}

    with true <- SalixIM.PrivateChatStatus.enabled?(),
         true <- PrivateChatStatusPlacement.local_owner?(state.agent_id),
         {:ok, %{"router_agent_id" => agent_id}} when agent_id == state.agent_id <-
           GroupDirectory.get_group(state.group_id),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             state.group_id,
             state.connect_id,
             state.provider
           ),
         true <- state.transport.authorized?(connect, state.target) do
      if now() >= state.expires_at or now() >= state.idle_until do
        clear_typing(state, connect)
        {:stop, :normal, state}
      else
        state = subscribe(state)
        projection = read_projection(state)
        state = %{state | next_at: now() + state.refresh_ms}

        case render(state, connect, projection) do
          {:ok, state} -> {:noreply, schedule(state)}
          :revoked -> {:stop, :normal, state}
        end
      end
    else
      _ -> {:stop, :normal, state}
    end
  rescue
    _ -> {:stop, :normal, state}
  catch
    _, _ -> {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.subscribed?, do: SessionActivity.unsubscribe(state.agent_id, state.session_id)
    :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def project(activity, sources) when is_map(activity) do
    scoped? = Enum.any?(List.wrap(activity["_active_source_message_ids"]), &(&1 in sources))

    cond do
      activity["state"] == "stopped" ->
        :idle

      activity["state"] not in ["active", "error"] or
          not is_list(activity["_active_source_message_ids"]) ->
        :unknown

      not scoped? ->
        :idle

      activity["state"] == "error" ->
        {:error, "Comma couldn't finish this request. Please try again."}

      is_map(activity["wait"]) ->
        :waiting

      activity["state"] == "active" and is_binary(activity["status"]) and activity["status"] != "" ->
        {:thinking, "Comma " <> String.slice(activity["status"], 0, 160)}

      true ->
        :unknown
    end
  end

  def project(_activity, _sources), do: :unknown

  defp read_projection(state) do
    case SessionActivity.get(state.agent_id, state.session_id) do
      {:ok, activity} -> project(activity, state.sources)
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp render(state, connect, {:thinking, _}), do: send_typing(state, connect)

  # An active WeChat wait still belongs to the current request.
  defp render(%{provider: "wechat"} = state, connect, :waiting),
    do: send_typing(state, connect)

  # Telegram retains its silent wait presentation.
  defp render(state, connect, :waiting),
    do: clear_typing(%{state | idle_until: now() + @idle_ms}, connect)

  defp render(state, connect, _projection), do: clear_typing(state, connect)

  defp send_typing(state, connect) do
    state = %{state | idle_until: now() + @idle_ms}

    case state.transport.send(connect, state.target, :typing, state.typing_ticket, "") do
      :ok -> {:ok, %{state | typing?: true}}
      {:ok, ticket} -> {:ok, %{state | typing_ticket: ticket, typing?: true}}
      {:error, :revoked} -> :revoked
      error -> {:ok, backoff(state, error)}
    end
  end

  defp clear_typing(%{provider: provider, typing?: true} = state, connect)
       when provider in ["wechat", "signal"] do
    case state.transport.send(connect, state.target, :cancel, state.typing_ticket, "") do
      {:ok, _} -> {:ok, %{state | typing?: false}}
      {:error, :revoked} -> :revoked
      error -> {:ok, backoff(state, error)}
    end
  end

  defp clear_typing(state, _connect), do: {:ok, state}

  defp backoff(state, {:error, {:retry_after, ms}}),
    do: %{state | next_at: now() + max(ms, state.refresh_ms)}

  defp backoff(state, _error), do: state

  defp switch_session(%{session_id: session_id} = state, session_id), do: state

  defp switch_session(state, session_id) do
    if state.subscribed?, do: SessionActivity.unsubscribe(state.agent_id, state.session_id)
    %{state | session_id: session_id, sources: [], subscribed?: false}
  end

  defp subscribe(%{subscribed?: true} = state), do: state

  defp subscribe(state) do
    case SessionActivity.subscribe(state.agent_id, state.session_id) do
      :ok -> %{state | subscribed?: true}
      _ -> state
    end
  end

  defp schedule(%{timer: nil} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:tick, token}, max(state.next_at - now(), 0))
    %{state | timer: {timer, token}}
  end

  defp schedule(state), do: state

  defp now, do: System.monotonic_time(:millisecond)
end
