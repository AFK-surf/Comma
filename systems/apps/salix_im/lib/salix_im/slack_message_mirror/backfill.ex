defmodule SalixIM.SlackMessageMirror.Backfill do
  @moduledoc """
  Walks one Slack installation's channels backward through history and writes
  what it finds into the mirror.

  The live webhook path records every message from the moment a bot joins a
  channel. This fills in everything before that. One pass over an installation
  lists the channels its bot is a member of and round-robins one
  `conversations.history` page at a time — parents, then that page's complete
  reply chains — lowering each channel's watermark behind the page. A pass
  keeps issuing paced requests until every listed channel is at Slack's end
  or the floor; it does not idle while a member channel still has history.

  ## One number per channel

  `SalixStore.SlackMirrorBackfillLedger` holds `indexed_from_ts_us` per
  channel. Its meaning is: every thread parent with `ts` between it and the
  first walk's start, and every reply to one, is in ClickHouse. A walk resumes
  from it with `latest = indexed_from, inclusive: false`. The number only
  moves down. Channel order is scheduling, not coverage: the watermark
  argument is the one `tla/salix/SlackMirrorBackfill.tla` checks, and it does
  not depend on which member channel is next.

  ## Write, then commit — and nothing else needs to be in order

  A page is written — its parents and the complete reply chain of every thread
  rooted in it — and only then is the watermark lowered to the page's oldest
  timestamp. That single ordering is the whole correctness argument: the
  watermark never describes a message that is not there. It holds for a walker
  that is killed at any point, and it holds for two walkers on one channel at
  once, because each can only ever report a timestamp it has itself written
  down to, and `LEAST` of two true reports is true. The claim on a channel is
  therefore a courtesy between two bots that share it, not a fence. The
  installation's claim is renewed as the walk goes, including on reply pages;
  losing it stops the pass at once, because another Pod owns this token's
  budget now. The channel claim is renewed on every Slack request of the
  visit so a reply-heavy page cannot look abandoned to another bot.

  ## Threads are read to the end or not at all

  `conversations.history` returns thread parents and never their replies. A
  parent with `reply_count > 0` has its `conversations.replies` chain followed
  until the cursor comes back empty, and the page is not committed if the
  chain does not end within the runaway guard. Committing anything less would
  put a watermark over replies the walk never read, and a later pass resumes
  below the page, so they would be unreachable for good.

  ## Rate limits are per installation

  Slack limits each method per workspace and bot token. A pass is therefore
  the unit of parallelism: two bots in one workspace walk concurrently on two
  budgets, and one pass paces itself at `pace_ms` between requests so it can
  never delay a live tool call by more than one request.

  Modeled in `tla/salix/SlackMirrorBackfill.tla`.
  """

  require Logger

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.SlackMessageMirror
  alias SalixIM.SlackMessageMirror.Row
  alias SalixStore.SlackMirrorBackfillLedger

  # History/replies pages are 1000: one request fills as much as Slack will
  # return, so the paced request budget is not spent on 200-row slices.
  # `conversations.list` stays at 200. `pace_ms` still spaces requests so the
  # walk does not crowd out live tool calls.
  @page_limit 1_000
  @thread_page_limit 1_000
  @channel_page_limit 200

  # History pages per channel per pass. The pass round-robins one page at a
  # time, then yields with `:more` so a skipped or newly joined channel is
  # retried on the next claim (due at once), instead of waiting for every
  # other member channel to hit Slack's end. `:infinity` is a test drain.
  @default_page_budget 40

  # Not budgets. Cursor pagination is complete only when the cursor comes back
  # empty; stopping early would commit a watermark over replies never read, or
  # skip channels the bot is in. These are runaway guards for a chain that
  # never terminates, and reaching one fails the pass rather than passing for
  # complete.
  @thread_page_cap 5_000
  @channel_page_cap 200

  @default_pace_ms 1_500
  @default_lease_ttl_ms 120_000
  @max_rate_limit_waits 5

  @channel_types ~w(public_channel private_channel mpim im)

  @ineligible_errors ~w(
    not_in_channel channel_not_found
    missing_scope not_allowed_token_type restricted_action
  )

  @type outcome :: :more | :retry | :idle

  @doc """
  Runs one pass over every channel the installation's bot is a member of.

  `{:ok, :more}` means at least one channel still has history below its
  watermark after this pass's page budget. The installation is due at once.
  `{:ok, :retry}` means a channel stopped on a failure of its own — Slack
  refusing it, ClickHouse refusing a page — or was held by another walker,
  and is worth trying again soon. `{:ok, :idle}` means every reachable
  channel is indexed to the floor or to its beginning. `{:error, reason}` is
  a failure that stopped the pass before it could visit every channel —
  losing the installation's claim, or Slack refusing the token.
  """
  @spec run_pass(map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run_pass(connect, opts \\ []) when is_map(connect) do
    with {:ok, context} <- context(connect, opts),
         {:ok, channels} <- list_channels(context) do
      visit_all(context, channels, :idle)
    end
  end

  defp context(connect, opts) do
    identity = Map.take(connect, ~w(tenant_id workspace_id connect_id))

    if Enum.all?(
         ~w(tenant_id workspace_id connect_id),
         &(is_binary(identity[&1]) and identity[&1] != "")
       ) do
      {:ok,
       %{
         connect: connect,
         credential: SlackAPI.installation(connect),
         connect_id: identity["connect_id"],
         key_base: Map.take(identity, ~w(tenant_id workspace_id)),
         now_us: opts[:now_us] || System.os_time(:microsecond),
         floor_us: opts[:floor_ts_us] || 0,
         page_limit: opts[:page_limit] || @page_limit,
         page_budget: page_budget(opts),
         thread_page_limit: opts[:thread_page_limit] || @thread_page_limit,
         thread_page_cap: opts[:thread_page_cap] || @thread_page_cap,
         channel_page_cap: opts[:channel_page_cap] || @channel_page_cap,
         pace_ms: Keyword.get(opts, :pace_ms, @default_pace_ms),
         lease_ttl_ms: opts[:lease_ttl_ms] || @default_lease_ttl_ms,
         reader: opts[:reader] || __MODULE__.SlackReader,
         channel_observer: opts[:channel_observer] || SalixIM.ProviderConnects,
         writer: opts[:writer] || SlackMessageMirror,
         ledger: opts[:ledger] || SlackMirrorBackfillLedger,
         sleep: opts[:sleep] || (&Process.sleep/1),
         snapshot_cut: opts[:snapshot_cut] || fn -> System.os_time(:microsecond) end
       }}
    else
      {:error, :invalid_backfill_connect}
    end
  end

  defp page_budget(opts) do
    case Keyword.fetch(opts, :page_budget) do
      {:ok, :infinity} -> :infinity
      {:ok, n} when is_integer(n) and n >= 0 -> n
      _missing_or_nil -> @default_page_budget
    end
  end

  ## Channels

  defp list_channels(context), do: list_channels(context, nil, context.channel_page_cap, [])

  defp list_channels(_context, _cursor, 0, _acc),
    do: {:error, :slack_mirror_channel_cursor_runaway}

  defp list_channels(context, cursor, remaining, acc) do
    with :ok <- renew(context),
         {:ok, channels, next_cursor} <-
           paced(context, fn ->
             context.reader.conversations(context.credential,
               cursor: cursor,
               limit: @channel_page_limit,
               types: @channel_types,
               exclude_archived: false
             )
           end) do
      observe_member_channels(context, channels)

      ids =
        for channel <- channels,
            is_map(channel),
            id = channel["id"],
            is_binary(id) and id != "",
            do: id

      acc = acc ++ ids

      if next_cursor in [nil, ""],
        do: {:ok, acc},
        else: list_channels(context, next_cursor, remaining - 1, acc)
    end
  end

  # Discovery is shared, but Triage configuration failure must not stop archival.
  # The next existing discovery pass retries projection; history never triggers
  # Triage and its write-before-watermark protocol is unchanged.
  defp observe_member_channels(context, channels) do
    # users.conversations is installation-specific membership evidence. The
    # search data domain includes retained private/DM/archive context too;
    # Triage's separate listening policy below remains unchanged.
    _ = SalixStore.SlackSearchCatalog.remember_connects([context.connect])

    _ =
      SalixStore.SlackSearchCatalog.remember_channels(
        context.connect,
        Enum.map(channels, & &1["id"])
      )

    case context.channel_observer.observe_slack_member_channels(context.connect, channels) do
      :ok -> :ok
      _error -> Logger.warning("Slack member channel listening projection unavailable")
    end
  rescue
    _error -> Logger.warning("Slack member channel listening projection unavailable")
  catch
    :exit, _reason -> Logger.warning("Slack member channel listening projection unavailable")
  end

  defp visit_all(context, channels, outcome) do
    channels
    |> Enum.map(&{&1, context.page_budget})
    |> then(&:queue.from_list/1)
    |> drain_queue(context, outcome)
  end

  # One history page per dequeue, then the channel goes to the back if it
  # still has history. A reply-heavy page still has to finish its threads
  # before the watermark can move — that is the TLA write-then-commit rule —
  # but the next history page belongs to the next member channel, not to
  # this one. `:skipped` is another walker holding the courtesy lease; that
  # is not "this install is done", so it cannot become `:idle`.
  defp drain_queue(queue, context, outcome) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {:ok, outcome}

      {{:value, {_channel_id, 0}}, rest} ->
        drain_queue(rest, context, :more)

      {{:value, {channel_id, remaining}}, rest} ->
        case visit_channel(context, channel_id) do
          :more ->
            case remaining do
              :infinity ->
                drain_queue(:queue.in({channel_id, :infinity}, rest), context, outcome)

              1 ->
                # This visit's budget for the channel is spent and the
                # channel still has history. Leave it for the next pass.
                drain_queue(rest, context, :more)

              n when is_integer(n) and n > 1 ->
                drain_queue(:queue.in({channel_id, n - 1}, rest), context, outcome)
            end

          :done ->
            drain_queue(rest, context, outcome)

          :skipped ->
            drain_queue(rest, context, worst(outcome, :retry))

          {:error, :claim_lost} ->
            {:error, :claim_lost}

          {:error, _reason} ->
            drain_queue(rest, context, worst(outcome, :retry))
        end
    end
  end

  defp worst(:more, _new), do: :more
  defp worst(_current, new), do: new

  defp visit_channel(context, channel_id) do
    key = Map.put(context.key_base, "channel_id", channel_id)

    case context.ledger.claim_channel(key, context.lease_ttl_ms) do
      {:ok, watermark} ->
        result =
          if finished?(watermark, context.floor_us),
            do: :done,
            else: walk(context, key, watermark)

        _ = context.ledger.release_channel(key)
        settle(context, key, result)

      :busy ->
        :skipped

      {:error, reason} ->
        Logger.warning("slack mirror backfill could not claim a channel: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp settle(_context, _key, result) when result in [:more, :done], do: result

  defp settle(context, key, {:error, reason} = error) do
    _ = context.ledger.record_channel_error(key, reason)
    error
  end

  # Slack said there is nothing older, or the walk has passed the operator's
  # floor. The floor is not a permanent answer: lowering it makes the channel
  # unfinished again and the next pass resumes from the same watermark.
  defp finished?(watermark, floor_us) do
    watermark["exhausted"] == true or
      (is_integer(watermark["indexed_from_ts_us"]) and watermark["indexed_from_ts_us"] <= floor_us)
  end

  ## The walk

  # One history page and the complete reply chains rooted in it. Returning
  # `:more` here is how the pass round-robins: the queue puts this channel
  # behind the others rather than descending the rest of its history now.
  defp walk(context, key, watermark) do
    from_us = watermark["indexed_from_ts_us"]
    walk_start_us = watermark["indexed_to_ts_us"] || context.now_us

    state = %{
      key: key,
      walk_start_us: walk_start_us,
      latest_us: from_us || context.now_us
    }

    with :ok <- renew(context),
         :ok <- renew_channel(context, state.key),
         {:ok, messages, observed_ts_us} <- history_page(context, state) do
      apply_page(context, state, messages, observed_ts_us)
    end
  end

  # Slack answered with nothing older. This is the only definitive end of a
  # channel, and it is why the walk does not read `has_more`: an empty page is
  # true whether or not the flag agrees, and it costs one extra request once
  # per completed channel.
  defp apply_page(context, state, [], _observed_ts_us) do
    with :ok <- context.ledger.mark_exhausted(state.key) do
      :done
    end
  end

  defp apply_page(context, state, messages, observed_ts_us) do
    with {:ok, oldest_us} <- page_oldest(messages),
         :ok <- write_rows(context, state, history_rows(context, state, messages, observed_ts_us)),
         :ok <- write_threads(context, state, messages),
         :ok <- context.ledger.lower_watermark(state.key, oldest_us, state.walk_start_us) do
      if oldest_us <= context.floor_us, do: :done, else: :more
    end
  end

  defp page_oldest(messages) do
    oldest =
      Enum.reduce(messages, nil, fn message, acc ->
        case Row.slack_ts_micros(message["ts"]) do
          {:ok, ts_us} when acc == nil or ts_us < acc -> ts_us
          _other -> acc
        end
      end)

    # Every message in a real page has a parseable ts. None of them having one
    # means the response is not what this walk thinks it is, and continuing
    # would move `latest` to a boundary derived from nothing.
    if oldest, do: {:ok, oldest}, else: {:error, :invalid_history_page}
  end

  defp history_rows(context, state, messages, observed_ts_us) do
    Enum.flat_map(messages, fn message ->
      case Row.from_history(
             context.connect,
             state.key["channel_id"],
             message,
             observed_ts_us
           ) do
        {:ok, row} -> [row]
        :ignore -> []
      end
    end)
  end

  defp write_rows(_context, _state, []), do: :ok

  defp write_rows(context, _state, rows) do
    owner = Map.take(context.connect, ~w(group_id connect_id connect_generation))
    context.writer.write_batch(Enum.map(rows, &Map.put(&1, "_semantic_context", owner)))
  end

  defp write_threads(context, state, messages) do
    messages
    |> Enum.filter(&thread_root?/1)
    |> Enum.reduce_while(:ok, fn root, :ok ->
      case walk_thread(context, state, root["ts"], nil, context.thread_page_cap) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A history page returns thread parents with their current reply count, and
  # broadcasts with a `thread_ts` pointing elsewhere. Only the parent is worth
  # a replies walk: a broadcast's own thread is walked from the page that
  # carries its parent.
  defp thread_root?(message) do
    is_map(message) and is_binary(message["ts"]) and message["thread_ts"] == message["ts"] and
      replies_possible?(message)
  end

  # Slack parents normally carry `reply_count`. If the field is missing, walk
  # anyway: skipping would commit a watermark over replies we never read.
  defp replies_possible?(%{"reply_count" => count}) when is_integer(count), do: count > 0
  defp replies_possible?(%{"reply_count" => _unknown}), do: true
  defp replies_possible?(_message), do: true

  defp walk_thread(_context, _state, root_ts, _cursor, 0),
    do: {:error, {:slack_mirror_thread_cursor_runaway, root_ts}}

  defp walk_thread(context, state, root_ts, cursor, remaining) do
    with :ok <- renew(context),
         :ok <- renew_channel(context, state.key),
         {:ok, messages, next_cursor, observed_ts_us} <-
           replies_page(context, state, root_ts, cursor),
         :ok <-
           write_rows(
             context,
             state,
             history_rows(context, state, messages, observed_ts_us)
           ) do
      if next_cursor in [nil, ""],
        do: :ok,
        else: walk_thread(context, state, root_ts, next_cursor, remaining - 1)
    end
  end

  ## Slack

  defp history_page(context, state) do
    paced(context, fn ->
      observed_ts_us = context.snapshot_cut.()

      case context.reader.history(context.credential, state.key["channel_id"],
             latest: slack_ts(state.latest_us),
             inclusive: false,
             include_all_metadata: true,
             limit: context.page_limit
           ) do
        {:ok, messages} -> {:ok, messages, observed_ts_us}
        other -> other
      end
    end)
  end

  defp replies_page(context, state, root_ts, cursor) do
    paced(context, fn ->
      observed_ts_us = context.snapshot_cut.()

      case context.reader.replies(context.credential, state.key["channel_id"], root_ts,
             cursor: cursor,
             include_all_metadata: true,
             limit: context.thread_page_limit
           ) do
        {:ok, messages, next_cursor} -> {:ok, messages, next_cursor, observed_ts_us}
        other -> other
      end
    end)
  end

  # Every Slack request goes through here: sleep `pace_ms` first, and when
  # Slack answers with a `Retry-After`, wait exactly that long and ask again, a
  # bounded number of times. Pacing belongs to this walk; other callers may
  # issue the same Slack method concurrently.
  defp paced(context, request, waits \\ 0) do
    pace(context)

    case request.() do
      {:error, {:rate_limited, retry_ms}} when waits < @max_rate_limit_waits ->
        context.sleep.(retry_ms)
        paced(context, request, waits + 1)

      result ->
        result
    end
  end

  defp pace(%{pace_ms: pace_ms, sleep: sleep}) when is_integer(pace_ms) and pace_ms > 0,
    do: sleep.(pace_ms)

  defp pace(_context), do: :ok

  # The boundary is carried as Slack's own string format. `slack_ts_micros/1`
  # accepts short fractions, but Slack matches `latest` exactly, so it is
  # rendered with all six digits every time.
  defp slack_ts(micros) do
    seconds = div(micros, 1_000_000)
    fraction = micros |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  ## Claims

  # The installation's claim is what another Pod checks before taking this
  # token; a walk over a channel with thousands of threads outlives any TTL
  # worth setting, so it is renewed as the walk proceeds. Losing it stops the
  # pass: not because a stale commit could hurt — it cannot — but because two
  # Pods on one token only split its budget.
  defp renew(context) do
    case context.ledger.renew_connect(context.connect_id, context.lease_ttl_ms) do
      :ok -> :ok
      {:error, :claim_lost} -> {:error, :claim_lost}
      {:error, reason} -> {:error, reason}
    end
  end

  # The channel claim is only a dedupe between bots; losing it mid-walk is not
  # worth stopping for, so it is extended on a best-effort basis. History and
  # reply pages both renew it: a thread-heavy page outlives the TTL.
  defp renew_channel(context, key) do
    _ = context.ledger.renew_channel(key, context.lease_ttl_ms)
    :ok
  end

  @doc false
  @spec ineligible_error?(String.t()) :: boolean()
  def ineligible_error?(message), do: message in @ineligible_errors

  defmodule SlackReader do
    @moduledoc """
    Default Slack transport for a backfill pass.

    `SalixIM.Provider.Slack.API` signals failure by raising, which is right for
    a request/response tool call and wrong here: a pass has durable state to
    settle before it stops. This converts the raise into the classification the
    pass acts on — retryable rate limit, terminal loss of access, or an
    unknown provider failure.
    """

    alias SalixIM.Provider.Slack.API, as: SlackAPI
    alias SalixIM.SlackMessageMirror.Backfill

    @spec conversations(SlackAPI.credential(), keyword()) ::
            {:ok, [map()], String.t() | nil} | {:error, term()}
    def conversations(credential, opts) do
      page = SlackAPI.list_user_conversation_page(credential, opts)
      {:ok, Map.get(page, "channels", []), Map.get(page, "next_cursor")}
    rescue
      error in SlackAPI.Error -> {:error, classify(error)}
    end

    @spec history(SlackAPI.credential(), String.t(), keyword()) ::
            {:ok, [map()]} | {:error, term()}
    def history(credential, channel_id, opts) do
      {messages, _next_cursor} = SlackAPI.conversation_history(credential, channel_id, opts)
      {:ok, messages}
    rescue
      error in SlackAPI.Error -> {:error, classify(error)}
    end

    @spec replies(SlackAPI.credential(), String.t(), String.t(), keyword()) ::
            {:ok, [map()], String.t()} | {:error, term()}
    def replies(credential, channel_id, root_ts, opts) do
      {messages, next_cursor} =
        SlackAPI.conversation_replies(credential, channel_id, root_ts, opts)

      {:ok, messages, next_cursor}
    rescue
      error in SlackAPI.Error -> {:error, classify(error)}
    end

    defp classify(%SlackAPI.Error{retry_after: seconds}) when is_integer(seconds) and seconds > 0,
      do: {:rate_limited, seconds * 1_000}

    defp classify(%SlackAPI.Error{message: message}) when is_binary(message) do
      if Backfill.ineligible_error?(message),
        do: :ineligible,
        else: {:slack, message}
    end

    defp classify(_error), do: {:slack, :unknown}
  end
end
