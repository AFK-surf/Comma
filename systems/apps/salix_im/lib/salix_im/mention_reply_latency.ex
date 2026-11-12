defmodule SalixIM.MentionReplyLatency do
  @moduledoc """
  Observes how long a person's Slack, Feishu or Lark @mention of the bot
  waits for its first visible reply, and how old the oldest unanswered one is.

  Ingress calls `mention/2` as soon as the callback is verified, before the
  message is admitted, so that admission waits and failures count. The
  provider send paths call `reply/4` after the provider confirmed a message: an
  edit, a reaction, a typing status or a failed or unknown send never arrives
  here, so its mention stays pending.

  A reply answers a mention only on causal evidence, never by time or place
  alone: it answers the mention's own message (Feishu, Lark), it is the
  mention's Task card, it is a Conversation message that an activation holding
  the mention wrote, or the activation that sent it holds the mention's source
  and it lands in the mention's thread. An activation holds a mention by its
  provider source (Router) or by the Conversation message ingress appended for
  it (a Worker or Task thread). Several mentions of one activation are answered
  one by one. A message in the thread with no evidence at all is counted as
  uncertain and answers nothing.

  A send can be confirmed before its link arrives, so a reply that answered
  nothing but carries evidence is kept for a few minutes and tried again on
  each link.

  A Router that settles `end_turn` with `no_reply` chose silence, so the mentions
  its activation held leave the table, counted as `no_reply` with no latency
  sample and no gap. A reply arriving later answers nothing.

  This is a bounded observation of a retained hour, not a delivery ledger:
  ingress and the reply run on different pods, so every pod keeps the same
  in-memory table of hashed identities. A mention's first pod records its
  telemetry, or the lowest live pod once that one is gone, so one mention gives
  one sample however many pods hold it. A restarted pod copies the table from a
  peer: a complete peer makes it complete, and an incomplete peer hands on the
  table and the start of its window, so a rolling restart usually keeps both.
  This transfer is best effort: a peer of an older release has no window to
  give, and a timeout or a peer lost before the pull completes misses it. Then
  the mentions it held are lost with no signal and a new window starts. A pod
  reports `coverage` 0 until its window has run for `@retention_ms`, and missing
  telemetry never shows that a mention was answered. Nothing here is read by
  delivery.

  The table holds at most `:capacity` identities on every path. Answered ones
  leave first; a pending one that has no room is lost.

  A lost measurement opens a gap: a mention with no usable source time, a reply
  with no usable time or place, a mention with no room or no reply within the
  retention. The invalid counter records it once, and the provider's `coverage`
  stays 0 for `@retention_ms` after it, so a quiet table never reads as a
  covered zero.

  A mention's first pod holds it before any reply can exist, so it records every
  reply it lives to see. A replica can see a reply before the mention; it keeps
  nothing from that reply and settles on the first pod's word. Other losses
  remain. A mention that reaches two pods within one cast counts on both. When
  the first pod dies, a reply that reached it alone gives no sample, and a
  mention left pending on a replica ends as `expired`. Pods that disagree on who
  is live can each record one sample.

  Per pod, `observed_at` moves only while the provider's `coverage` is 1. Join
  the two on the pod to choose fresh complete pods, and read the pending age
  from those.
  """
  use SystemsRuntime.Server

  alias SalixAgent.DeliveryTelemetry

  @providers ~w(slack feishu lark)
  @retention_ms 3_600_000
  @capacity 16_384
  @future_tolerance_ms 300_000
  # A provider message create or reply, not a reaction, pin or forward.
  @message_path ~r{\A/im/v1/messages(\?|/[^/]+/reply\z)}
  @card {__MODULE__, :card}
  @recent_replies 64
  @recent_reply_ms 300_000
  @no_reply_handler {__MODULE__, :no_reply}

  def providers, do: @providers

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def attach_no_reply do
    SystemsRuntime.Telemetry.detach(@no_reply_handler)

    SystemsRuntime.Telemetry.attach(
      @no_reply_handler,
      [:salix, :turn, :no_reply],
      &__MODULE__.handle_no_reply/4,
      nil
    )
  end

  @doc false
  def handle_no_reply(_event, _measurements, %{source_ids: source_ids}, _config),
    do: no_reply(source_ids)

  @doc "The activation that held `source_ids` settled without replying, on purpose."
  def no_reply(source_ids, server \\ __MODULE__) do
    case source_keys(source_ids) do
      [] -> :ok
      keys -> SystemsRuntime.Server.cast(server, {:no_reply, keys})
    end
  catch
    _, _ -> :ok
  end

  @doc """
  Records one eligible mention. `:place` is the channel or chat and `:thread`
  the ids a reply in the same thread names, the mention's own message first.
  """
  def mention(mention, server \\ __MODULE__) when is_map(mention) do
    SystemsRuntime.Server.cast(server, {:mention, mention})
  catch
    _, _ -> :ok
  end

  @doc "A Feishu or Lark message being received, if a person mentioned the bot in it."
  def provider_mention(source_id, metadata, command_text \\ nil)

  def provider_mention(
        source_id,
        %{"bot_mentioned" => true, "sender_type" => "user"} = metadata,
        command_text
      ) do
    if SalixIM.ControlCommand.parse(command_text) == :none do
      mention(%{
        provider: metadata["provider"],
        connect_id: metadata["connect_id"],
        source_message_id: source_id,
        place: metadata["chat_id"],
        message: metadata["message_id"],
        thread: [metadata["message_root_id"], metadata["message_thread_id"]],
        source_sent_at_ms: metadata["source_sent_at_ms"]
      })
    else
      :ok
    end
  end

  def provider_mention(_source_id, _metadata, _command_text), do: :ok

  @doc "The Task card of `conversation_id` was requested by the current activation."
  def card_requested(conversation_id, server \\ __MODULE__) do
    keys = activation_sources()

    if keys != [] and is_binary(conversation_id),
      do: SystemsRuntime.Server.cast(server, {:link, keys, card(conversation_id)}),
      else: :ok
  catch
    _, _ -> :ok
  end

  @doc "The current activation wrote the Conversation message `message_id`."
  def message_sent(message_id, server \\ __MODULE__) do
    keys = activation_sources()

    if keys != [] and is_binary(message_id),
      do: SystemsRuntime.Server.cast(server, {:link, keys, message(message_id)}),
      else: :ok
  catch
    _, _ -> :ok
  end

  @doc "Ingress appended the Conversation message `message_id` for this source."
  def conversation_message(source_id, message_id, server \\ __MODULE__) do
    key = DeliveryTelemetry.source_key(source_id)

    if key && is_binary(message_id),
      do: SystemsRuntime.Server.cast(server, {:link, [key], message(message_id)}),
      else: :ok
  catch
    _, _ -> :ok
  end

  @doc "Runs the send of the Task card of `conversation_id`."
  def with_card(conversation_id, fun), do: with_evidence(card(conversation_id), fun)

  @doc "Runs the provider delivery of the Conversation message `message_id`."
  def with_message(message_id, fun) when is_binary(message_id),
    do: with_evidence(message(message_id), fun)

  def with_message(_message_id, fun), do: fun.()

  defp with_evidence(token, fun) do
    previous = Process.put(@card, token)

    try do
      fun.()
    after
      if previous, do: Process.put(@card, previous), else: Process.delete(@card)
    end
  end

  @doc "Records one provider-confirmed visible message of `connect`."
  def reply(provider, connect, reply, server \\ __MODULE__) when is_map(reply) do
    place = scope(provider, connect["connect_id"], reply[:place])

    reply = %{
      provider: provider,
      scope: place,
      thread: tokens(place, [reply[:parent] | List.wrap(reply[:thread])]),
      parent: tokens(place, [reply[:parent]]),
      sources: activation_sources(),
      card: Process.get(@card),
      at_ms: reply[:at_ms]
    }

    SystemsRuntime.Server.cast(server, {:reply, reply})
  catch
    _, _ -> :ok
  end

  defp card(conversation_id), do: DeliveryTelemetry.source_key("card\n" <> conversation_id)
  defp message(message_id), do: DeliveryTelemetry.source_key("message\n" <> message_id)

  # A redelivery replays the same source under a suffixed id. A Conversation
  # delivery names its Message (`SalixIM.ConversationSourceIdentity`). A
  # provider call names only its current source for authorization; the
  # activation's other sources come separately.
  defp activation_sources do
    context = SalixIM.Provider.current_tool_context()

    source_keys(
      [context["source_message_id"] | List.wrap(context["source_message_ids"])] ++
        List.wrap(context["activation_source_message_ids"])
    )
  end

  defp source_keys(source_ids) do
    source_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn
      "groupconv:" <> rest = id ->
        case String.split(rest, ":") do
          [_conversation, message_id | _] -> [id, "message\n" <> message_id]
          _ -> [id]
        end

      id ->
        [id]
    end)
    |> Enum.map(fn id ->
      id |> String.split(":redelivery:") |> hd() |> DeliveryTelemetry.source_key()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "A Slack message the bot posted, from its `chat.postMessage` result."
  def slack_reply(connect, thread_ts, {:ok, %{"channel" => channel, "ts" => ts}}) do
    at =
      case SalixIM.SlackMessageMirror.Row.slack_ts_micros(ts) do
        {:ok, micros} -> div(micros, 1_000)
        _ -> nil
      end

    reply("slack", connect, %{place: channel, thread: [thread_ts], at_ms: at})
  end

  def slack_reply(_connect, _thread_ts, _result), do: :ok

  @doc "A Slack file post, whose answer carries no message time."
  def slack_upload(connect, channel, thread_ts, {:ok, _result}) do
    reply("slack", connect, %{
      place: channel,
      thread: [thread_ts],
      at_ms: SystemsClock.system_time(:millisecond)
    })
  end

  def slack_upload(_connect, _channel, _thread_ts, _result), do: :ok

  @doc "A Feishu or Lark `POST` that may have created a message of the bot."
  def provider_post(provider, connect, path, {:ok, %{"message_id" => _} = message})
      when is_binary(path) do
    if Regex.match?(@message_path, path) do
      reply(provider, connect, %{
        place: message["chat_id"],
        parent: message["parent_id"],
        thread: [message["root_id"], message["thread_id"]],
        at_ms: millis(message["create_time"])
      })
    else
      :ok
    end
  end

  def provider_post(_provider, _connect, _path, _result), do: :ok

  @doc "This pod's table and window, for a restarted peer."
  def window(server \\ __MODULE__), do: SystemsRuntime.Server.call(server, :window, 5_000)

  @doc false
  def sample(server \\ __MODULE__), do: SystemsRuntime.Server.call(server, :sample)

  defp millis(value) when is_integer(value), do: value

  defp millis(value) when is_binary(value) do
    case Integer.parse(value) do
      {millis, ""} -> millis
      _ -> nil
    end
  end

  defp millis(_value), do: nil

  defp scope(provider, connect_id, place),
    do:
      if(
        Enum.all?([provider, connect_id, place], &(is_binary(&1) and &1 != "")),
        do: DeliveryTelemetry.source_key(Enum.join([provider, connect_id, place], "\n"))
      )

  defp tokens(scope, ids) do
    ids
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&DeliveryTelemetry.source_key(to_string(scope) <> "\n" <> &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.get(opts, :id, node()),
      pending: %{},
      answered: %{},
      copied?: false,
      overflowed_at: nil,
      gaps: %{},
      recent_replies: [],
      pulled: MapSet.new(),
      peers:
        Keyword.get(opts, :peers, fn ->
          Enum.map(Node.list(:visible), &{__MODULE__, &1})
        end),
      live: Keyword.get(opts, :live, fn -> [node() | Node.list(:visible)] end),
      clock: Keyword.get(opts, :clock, fn -> SystemsClock.system_time(:millisecond) end),
      interval: Keyword.get(opts, :interval, 15_000),
      pull: Keyword.get(opts, :pull, &pull/1),
      capacity: Keyword.get(opts, :capacity, @capacity)
    }

    state = Map.put(state, :started_at, state.clock.())
    if Keyword.get(opts, :name, __MODULE__) == __MODULE__, do: attach_no_reply()

    for provider <- @providers do
      event([:observation], %{coverage: 0}, %{provider: provider})
    end

    ask_peers(state)
    pull_windows(state)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sample, state.interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:mention, mention}, state) do
    provider = mention[:provider]
    now = state.clock.()
    place = scope(provider, mention[:connect_id], mention[:place])
    key = DeliveryTelemetry.source_key(mention[:source_message_id])

    cond do
      is_nil(key) or is_nil(place) ->
        {:noreply, lost(state, provider, :missing_correlation, now)}

      known?(state, key) ->
        {:noreply, state}

      true ->
        event([:mention], %{count: 1}, %{provider: provider})

        case source_time(mention[:source_sent_at_ms], now) do
          {:ok, sent_at} ->
            entry = %{
              key: key,
              provider: provider,
              scope: place,
              message: tokens(place, [mention[:message]]),
              thread: tokens(place, [mention[:message] | List.wrap(mention[:thread])]),
              cards: [],
              uncertain?: false,
              sent_at_ms: sent_at,
              origin: state.id
            }

            cast_peers(state, {:observed, entry})
            {:noreply, admit(state, entry, now)}

          {:error, reason} ->
            {:noreply, lost(state, provider, reason, now)}
        end
    end
  end

  def handle_cast({:observed, entry}, state) do
    if known?(state, entry.key),
      do: {:noreply, state},
      else: {:noreply, admit(state, entry, state.clock.())}
  end

  def handle_cast({:gap, provider, at}, state), do: {:noreply, gap(state, provider, at)}

  def handle_cast({:reply, %{scope: nil} = reply}, state),
    do: {:noreply, lost(state, reply.provider, :missing_correlation, state.clock.())}

  def handle_cast({:reply, reply}, state) do
    cast_peers(state, {:peer_reply, reply})
    {:noreply, apply_reply(state, reply)}
  end

  def handle_cast({:peer_reply, reply}, state), do: {:noreply, apply_reply(state, reply)}

  def handle_cast({:settled, settled}, state) do
    keys = Enum.map(settled, &elem(&1, 0))

    {:noreply,
     bound(
       %{
         state
         | pending: Map.drop(state.pending, keys),
           answered: Map.merge(Map.new(settled), state.answered)
       },
       state.clock.()
     )}
  end

  def handle_cast({:no_reply, keys}, state) do
    cast_peers(state, {:peer_no_reply, keys})
    {:noreply, close_no_reply(state, keys)}
  end

  def handle_cast({:peer_no_reply, keys}, state), do: {:noreply, close_no_reply(state, keys)}

  def handle_cast({:link, keys, card}, state) do
    cast_peers(state, {:peer_link, keys, card})
    {:noreply, link(state, keys, card)}
  end

  def handle_cast({:peer_link, keys, card}, state), do: {:noreply, link(state, keys, card)}

  # A pod of the release before Worker and Task threads were matched.
  def handle_cast({:unsupported, key, provider, at}, state) do
    state = state |> Map.update!(:answered, &Map.put(&1, key, at)) |> gap(provider, at)
    {:noreply, bound(state, state.clock.())}
  end

  def handle_cast({:copy_to, peer}, state) do
    if complete?(state, state.clock.()) do
      SystemsRuntime.Server.cast(
        peer,
        {:copy, state.pending, state.answered, state.gaps}
      )
    end

    {:noreply, state}
  end

  # An incomplete peer's table: it proves nothing, and the receiver stays
  # incomplete until the window they share has run.
  def handle_cast({:window, peer, window}, state) do
    state = %{state | pulled: MapSet.put(state.pulled, peer)}
    answered = Map.merge(window.answered, state.answered)

    {:noreply,
     bound(
       %{
         state
         | pending: window.pending |> Map.merge(state.pending) |> Map.drop(Map.keys(answered)),
           answered: answered,
           gaps: Map.merge(window.gaps, state.gaps, fn _, a, b -> max(a, b) end),
           started_at: min(window.started_at, state.started_at),
           overflowed_at: later(window.overflowed_at, state.overflowed_at)
       },
       state.clock.()
     )}
  end

  def handle_cast({:copy, pending, answered, gaps}, state) do
    answered = Map.merge(answered, state.answered)

    {:noreply,
     bound(
       %{
         state
         | pending: pending |> Map.merge(state.pending) |> Map.drop(Map.keys(answered)),
           answered: answered,
           gaps: Map.merge(gaps, state.gaps, fn _, a, b -> max(a, b) end),
           copied?: true
       },
       state.clock.()
     )}
  end

  # A peer of another release.
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:sample, _from, state), do: {:reply, :ok, publish(state)}
  def handle_call(:window, _from, state), do: {:reply, partial_window(state), state}

  @impl true
  def handle_info(:sample, state) do
    state = publish(state)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :sample, state.interval)
    {:noreply, state}
  end

  defp gap(state, provider, at),
    do: %{state | gaps: Map.update(state.gaps, provider, at, &max(&1, at))}

  defp lost(state, provider, reason, now) do
    invalid(provider, reason)
    cast_peers(state, {:gap, provider, now})
    gap(state, provider, now)
  end

  # A call of this function, so that a peer without it answers `undef` here and
  # nothing reaches its server: a cast of a new shape would stop a release that
  # has no clause for it.
  defp pull_windows(state) do
    owner = SystemsRuntime.Proc.self()

    for peer <- state.peers.(), not MapSet.member?(state.pulled, peer) do
      SystemsRuntime.Proc.spawn(fn ->
        case state.pull.(peer) do
          %{started_at: _} = window ->
            SystemsRuntime.Server.cast(owner, {:window, peer, window})

          _ ->
            :ok
        end
      end)
    end

    :ok
  end

  defp pull({_name, node}) do
    :erpc.call(node, __MODULE__, :window, [], 5_000)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp pull(_peer), do: nil

  defp partial_window(state),
    do: Map.take(state, [:pending, :answered, :gaps, :started_at, :overflowed_at])

  defp later(nil, at), do: at
  defp later(at, nil), do: at
  defp later(left, right), do: max(left, right)

  defp known?(state, key),
    do: Map.has_key?(state.pending, key) or Map.has_key?(state.answered, key)

  defp link(state, keys, card) do
    pending =
      Map.new(state.pending, fn {key, entry} ->
        if key in keys or overlap?(entry.cards, keys),
          do: {key, %{entry | cards: Enum.uniq([card | entry.cards])}},
          else: {key, entry}
      end)

    # The send can be confirmed before its link arrives here.
    Enum.reduce(state.recent_replies, %{state | pending: pending}, &settle_reply(&2, &1.reply))
  end

  defp apply_reply(state, reply) do
    before = map_size(state.pending)
    state = settle_reply(state, reply)

    if map_size(state.pending) == before and (reply.card != nil or reply.sources != []) do
      recent = %{reply: reply, seen_at: state.clock.()}
      %{state | recent_replies: Enum.take([recent | state.recent_replies], @recent_replies)}
    else
      state
    end
  end

  defp settle_reply(state, reply) do
    now = state.clock.()
    candidates = state.pending |> Map.values() |> Enum.filter(&after_mention?(&1, reply))
    answered = Enum.filter(candidates, &causal?(&1, reply))
    uncertain = Enum.filter(candidates -- answered, &uncertain?(&1, reply))
    recording = Enum.filter(answered, &recorder?(state, &1))

    state = Enum.reduce(recording, state, &observe_reply(&2, &1, reply, now))

    uncertain
    |> Enum.filter(&recorder?(state, &1))
    |> Enum.each(&invalid(&1.provider, :uncertain_correlation))

    if recording != [] do
      cast_peers(state, {:settled, Enum.map(recording, &{&1.key, &1.sent_at_ms})})
    end

    pending =
      Enum.reduce(uncertain, state.pending, fn entry, pending ->
        Map.put(pending, entry.key, %{entry | uncertain?: true})
      end)

    settle(%{state | pending: pending}, answered)
  end

  # A reply older than the mention answered something else.
  defp after_mention?(entry, reply) do
    entry.scope == reply.scope and (is_nil(reply.at_ms) or reply.at_ms >= entry.sent_at_ms)
  end

  defp causal?(entry, reply) do
    overlap?(entry.message, reply.parent) or reply.card in entry.cards or
      ((entry.key in reply.sources or overlap?(entry.cards, reply.sources)) and
         (reply.thread == [] or overlap?(entry.thread, reply.thread)))
  end

  # A send of another activation in the thread is simply another turn's.
  defp uncertain?(entry, reply) do
    not entry.uncertain? and reply.sources == [] and is_nil(reply.card) and
      overlap?(entry.thread, reply.thread)
  end

  defp overlap?(left, right), do: Enum.any?(left, &(&1 in right))

  defp recorder?(state, entry) do
    live = state.live.()
    if entry.origin in live, do: entry.origin == state.id, else: Enum.min(live) == state.id
  end

  defp source_time(value, now) when is_integer(value) and value > 0 do
    if value > now + @future_tolerance_ms, do: {:error, :invalid_clock}, else: {:ok, value}
  end

  defp source_time(nil, _now), do: {:error, :missing_source_time}
  defp source_time(_value, _now), do: {:error, :invalid_clock}

  defp admit(state, entry, now), do: bound(put_in(state.pending[entry.key], entry), now)

  # Answered identities leave first, a batch at a time so that a full table does
  # not sort on every mention. The newest pending ones then give way: the oldest
  # are what the gauge exists for.
  defp bound(state, now) do
    over = map_size(state.pending) + map_size(state.answered) - state.capacity

    if over <= 0 do
      state
    else
      evicted = min(map_size(state.answered), over + div(state.capacity, 16))

      answered =
        state.answered |> Enum.sort_by(&elem(&1, 1)) |> Enum.drop(evicted) |> Map.new()

      drop_pending(%{state | answered: answered}, over - evicted, now)
    end
  end

  defp drop_pending(state, over, _now) when over <= 0, do: state

  defp drop_pending(state, over, now) do
    {kept, dropped} =
      state.pending
      |> Map.values()
      |> Enum.sort_by(& &1.sent_at_ms)
      |> Enum.split(map_size(state.pending) - over)

    for entry <- dropped, recorder?(state, entry), do: invalid(entry.provider, :overflow)
    %{state | pending: Map.new(kept, &{&1.key, &1}), overflowed_at: now}
  end

  defp observe_reply(state, entry, %{at_ms: nil}, now),
    do: lost(state, entry.provider, :missing_receipt, now)

  defp observe_reply(state, entry, %{at_ms: at}, now) when at > now + @future_tolerance_ms,
    do: lost(state, entry.provider, :invalid_clock, now)

  defp observe_reply(state, entry, %{at_ms: at}, _now) do
    event([:reply], %{latency: at - entry.sent_at_ms}, %{provider: entry.provider})
    state
  end

  defp close_no_reply(state, keys) do
    closed =
      state.pending
      |> Map.values()
      |> Enum.filter(&(&1.key in keys or overlap?(&1.cards, keys)))

    for entry <- closed, recorder?(state, entry) do
      event([:no_reply], %{count: 1}, %{provider: entry.provider})
    end

    settle(state, closed)
  end

  defp settle(state, answered) do
    Enum.reduce(answered, state, fn entry, acc ->
      %{
        acc
        | pending: Map.delete(acc.pending, entry.key),
          answered: Map.put(acc.answered, entry.key, entry.sent_at_ms)
      }
    end)
  end

  defp publish(state) do
    now = state.clock.()
    state = expire(state, now)
    complete? = complete?(state, now)

    if not complete? do
      ask_peers(state)
      pull_windows(state)
    end

    for provider <- @providers do
      oldest =
        state.pending
        |> Map.values()
        |> Enum.filter(&(&1.provider == provider))
        |> Enum.map(& &1.sent_at_ms)
        |> Enum.min(fn -> nil end)

      if (complete? and not Map.has_key?(state.gaps, provider)) or oldest do
        age = if oldest, do: max(now - oldest, 0), else: 0
        event([:pending], %{oldest_age: age}, %{provider: provider})
      end

      covered? = complete? and not Map.has_key?(state.gaps, provider)
      event([:observation], %{coverage: if(covered?, do: 1, else: 0)}, %{provider: provider})
      if covered?, do: event([:observed], %{observed_at: now / 1_000}, %{provider: provider})
    end

    state
  end

  defp expire(state, now) do
    cutoff = now - @retention_ms
    {expired, pending} = Enum.split_with(state.pending, fn {_, e} -> e.sent_at_ms <= cutoff end)

    for {_key, entry} <- expired, recorder?(state, entry) do
      invalid(entry.provider, :expired)
    end

    state =
      Enum.reduce(expired, state, fn {_key, entry}, acc -> gap(acc, entry.provider, now) end)

    answered = state.answered |> Enum.reject(fn {_, at} -> at <= cutoff end) |> Map.new()

    overflowed_at =
      if state.overflowed_at && state.overflowed_at > cutoff, do: state.overflowed_at

    gaps =
      state.gaps |> Enum.filter(fn {_, at} -> at > cutoff end) |> Map.new()

    %{
      state
      | pending: Map.new(pending),
        answered: answered,
        overflowed_at: overflowed_at,
        gaps: gaps,
        recent_replies: Enum.filter(state.recent_replies, &(&1.seen_at > now - @recent_reply_ms))
    }
  end

  defp complete?(state, now) do
    is_nil(state.overflowed_at) and
      (state.copied? or now - state.started_at >= @retention_ms)
  end

  defp ask_peers(state), do: cast_peers(state, {:copy_to, SystemsRuntime.Proc.self()})

  defp cast_peers(state, message) do
    Enum.each(state.peers.(), &SystemsRuntime.Server.cast(&1, message))
  end

  defp invalid(provider, reason),
    do: event([:invalid], %{count: 1}, %{provider: provider, reason: reason})

  defp event(suffix, measurements, metadata),
    do:
      SystemsRuntime.Telemetry.execute([:salix, :agent_message | suffix], measurements, metadata)
end
