defmodule SalixCluster.Timers do
  @moduledoc """
  The timers singleton: durable one-shot timer notifications
  for agents. Timer markers are indexed by minute bucket and carry their own
  delivery source id and payload.

  `fire_due/1` sweeps the current and previous N minute buckets
  (`:lookback_minutes`, default 5) via `SalixStore.Timers.sweep/2` and, for
  each due marker, delivers the stored payload with the stored deterministic
  source id. A refire after a crash dedupes on the target session's ledger,
  which commits under that deterministic id. The timer marker is cleared ONLY
  after `SalixAgent.deliver/3` acks — i.e. after the session-ledger commit is
  durable (A2, rpc-direct-delivery.md); a transient delivery failure leaves
  the marker armed for the next pass. A
  target-state refusal (the agent is archived, or has no control record) is
  terminal instead: the marker is settled, see `settle_undeliverable/5`.

  `catch_up/1` is the second pass, on a slower cadence: anything that keeps a
  bucket unswept for longer than the firing window — an outage, a lost lease,
  a deploy gap, repeated transient delivery failures — leaves that bucket
  behind the window, where `fire_due/1` will never look again (#758). The
  catch-up asks the store which buckets are still there, takes the ones behind
  the window, and fires them exactly as the firing tick would. It is bounded
  in both dimensions — buckets AND markers — and rotates: a bucket it cannot
  drain must not hold up the backlog behind it. That fairness argument is
  modeled in `tla/salix/TimerCatchUpRotation.tla`.

  The GenServer half mirrors `SalixCluster.Recovery`: it ticks `fire_due/1`
  on an interval while holding the `:timers` S3 singleton lease, dropping
  leadership and skipping both passes when lease renewal fails.

  The marker protocol — result classification, retain vs settle, failed
  clears, crash/replay under the deterministic source id, and the
  session-work backstop that keeps a settled marker from losing an owed
  wake — is modeled in `tla/salix/TimerMarkerSettlement.tla`. Catch-up
  fairness over a backlog — that a bucket which cannot be drained does not
  starve the healthy buckets behind it, under either bound — is modeled
  separately in `tla/salix/TimerCatchUpRotation.tla`.
  """

  use GenServer
  require Logger

  alias SalixStore.Timers, as: StoreTimers
  alias SalixCluster.S3Lease

  @interval_ms 5_000
  @default_lookback_minutes 5
  # The catch-up costs one delimited LIST plus whatever it finds, so it runs on
  # its own slower cadence rather than on the 5s firing tick.
  @catchup_interval_ticks 12
  @default_catchup_buckets 10
  # Buckets bound the probe; markers bound the actual work. A bucket holds
  # however many waits happened to expire in one minute, so without this a
  # single pass could read and deliver an unbounded number of them.
  @default_catchup_markers 100

  @type fired :: %{
          agent: String.t(),
          session: String.t(),
          timer_id: String.t(),
          bucket: integer(),
          source_message_id: String.t(),
          status: :created | :duplicate
        }

  # ---- API ----

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run one firing pass. Returns `{:ok, fired_list}` with one entry per marker
  whose synthetic wake was durably delivered (and whose marker was then
  cleared). Options:

    * `:now` — clock injection (unix ms).
    * `:lookback_minutes` — how many buckets before the current one to sweep
      (default #{@default_lookback_minutes}).

  Does not require the singleton lease (the GenServer gates on it; direct
  callers are responsible). A transient delivery failure skips that marker —
  it stays armed and refires on a later pass with the same deterministic
  source id. A target-state refusal settles the marker instead
  (`settle_undeliverable/5`); either way the marker is absent from the
  returned list, which reports fired wakes only.
  """
  @spec fire_due(keyword()) :: {:ok, [fired()]} | {:error, term()}
  def fire_due(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)
    current = StoreTimers.minute_bucket(now)
    sweep_buckets((current - lookback(opts))..current, now)
  end

  @doc """
  Run one catch-up pass over the buckets the firing window has already passed.

  `fire_due/1` reaches a fixed number of buckets behind the current minute, so
  any pause longer than that window — an outage, a lost lease, a deploy gap, a
  marker held armed by repeated transient delivery failures — leaves its
  buckets behind the window, where no later pass will ever look again (#758).
  This pass asks the store which buckets are actually still there, takes the
  ones behind the window, and fires them exactly as the firing tick would.

  The wake itself is not what this rescues: a durable wait is also indexed in
  the session-work projection under its own deadline, and
  `SalixAgent.SessionWorkRecovery` fires it from there with no window at all.
  What a stranded bucket costs is the fast path plus an object that can never
  be swept again, which is how staging came to carry two `wait_timeout` markers
  for 36 days (#839).

  Firing late is the whole terminal semantics here, deliberately: a timeout
  whose wait is gone is refused at the session's own wait-identity check and
  settles the marker anyway (`commit_inbound_wait_timeout/3`), so a dead-letter
  state would add a surface without adding an answer.

  ## Rotation, and why a backlog cannot starve behind a stuck bucket

  Returns `{:ok, %{fired: [...], next: cursor}}`. `next` is a cursor past the
  last bucket this pass ATTEMPTED — attempted, not drained — and the caller
  hands it back as `:after` so the following pass resumes behind it. A pass
  that finds nothing stranded after its cursor answers `next: nil`, which wraps
  the next pass back to the oldest bucket.

  Advancing on attempt rather than on success is the whole point. Retaining a
  marker whose delivery or clear failed is deliberate (see `fire/3`), so a
  stuck bucket never empties; taking the oldest N every time would mean a pass
  that finds N stuck buckets does nothing else for as long as they stay stuck,
  and everything behind them — healthy, deliverable, overdue — would never be
  reached. Rotation costs one wasted probe per cycle and buys the property the
  model checks: every deliverable bucket is eventually attempted, however many
  undrainable ones sit in front of it. Eventually is the whole claim — nothing
  here bounds how long a cycle takes. The wrap is what brings the stuck ones
  back once they are deliverable again.

  Options: `:now` and `:lookback_minutes` as in `fire_due/1`, plus

    * `:after` — resume cursor from a previous pass's `next`;
    * `:max_buckets` — how many stranded buckets one pass may take;
    * `:max_markers` — how many markers one pass may read and deliver, across
      those buckets. Buckets alone do not bound the work: a bucket holds
      however many waits expired in that minute. When the marker budget runs
      out inside a bucket, the cursor still advances past it, so the pass stays
      bounded and cannot be monopolized; the rest of that bucket waits for the
      cursor to come back around. That is a revisit, not a schedule: a bucket
      can be revisited without draining — a large one needs as many cycles as
      it has budgets' worth of markers, and one whose markers keep failing to
      settle drains none of them. The guarantee is the negative one, and it is
      the only one the model checks: a bucket this pass cannot finish does not
      hold up the buckets behind it.
  """
  @spec catch_up(keyword()) ::
          {:ok, %{fired: [fired()], next: String.t() | nil}} | {:error, term()}
  def catch_up(opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)
    window_start = StoreTimers.minute_bucket(now) - lookback(opts)
    max_buckets = opts[:max_buckets] || @default_catchup_buckets
    max_markers = opts[:max_markers] || @default_catchup_markers

    with {:ok, buckets} <-
           StoreTimers.stranded_buckets(window_start,
             limit: max_buckets,
             after: opts[:after]
           ),
         {:ok, fired, attempted} <- sweep_within_budget(buckets, now, max_markers) do
      {:ok, %{fired: fired, next: resume_cursor(attempted)}}
    end
  end

  defp lookback(opts), do: opts[:lookback_minutes] || @default_lookback_minutes

  defp resume_cursor([]), do: nil
  defp resume_cursor(attempted), do: attempted |> List.last() |> StoreTimers.bucket_cursor()

  defp sweep_buckets(buckets, now) do
    Enum.reduce_while(buckets, {:ok, []}, fn bucket, {:ok, acc} ->
      case StoreTimers.sweep(bucket, now) do
        {:ok, entries} ->
          {:cont, {:ok, acc ++ Enum.flat_map(entries, &fire(&1, bucket, now))}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # The budget counts markers READ, not markers fired: a retained marker cost
  # the same read and delivery attempt as a settled one, and a pass full of
  # retries is exactly the case this bound exists for.
  defp sweep_within_budget(_buckets, _now, budget) when budget <= 0, do: {:ok, [], []}

  defp sweep_within_budget(buckets, now, budget) do
    buckets
    |> Enum.reduce_while({:ok, [], [], budget}, fn bucket, {:ok, fired, attempted, left} ->
      case StoreTimers.sweep(bucket, now, limit: left) do
        {:ok, entries} ->
          acc =
            {:ok, fired ++ Enum.flat_map(entries, &fire(&1, bucket, now)), attempted ++ [bucket],
             left - length(entries)}

          if elem(acc, 3) > 0, do: {:cont, acc}, else: {:halt, acc}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, fired, attempted, _left} -> {:ok, fired, attempted}
      {:error, _} = err -> err
    end
  end

  # ---- firing one marker ----

  defp fire(
         %{
           "agent_id" => agent,
           "session_id" => session,
           "timer_id" => timer_id,
           "source_message_id" => source_id,
           "payload" => payload,
           "key" => key
         } = record,
         bucket,
         _now
       ) do
    with {:ok, status} <-
           deliver_timer(record, agent, payload, source_id) do
      # Marker cleared ONLY after the session-ledger commit is durable (the
      # deliver ack). A failed clear is benign: the next pass redelivers
      # (the ledger answers :duplicate) and retries the clear.
      case StoreTimers.clear(key) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("timers: clear of #{key} failed (#{inspect(reason)}); will retry")
      end

      [
        %{
          agent: agent,
          session: session,
          timer_id: timer_id,
          bucket: bucket,
          source_message_id: source_id,
          status: status
        }
      ]
    else
      {:error, reason} = error ->
        # A location request can outlive an archived target, or its timer can
        # beat async-call admission. Neither refusal cancels the owed result.
        if record["kind"] != "location_timeout" and SalixAgent.target_state_refusal?(error) do
          settle_undeliverable(key, agent, session, bucket, reason)
        else
          Logger.warning(
            "timers: wake delivery for #{agent}/#{session} (bucket #{bucket}) failed " <>
              "(#{inspect(reason)}); marker left armed"
          )
        end

        []
    end
  end

  defp deliver_timer(%{"kind" => "location_timeout"}, _agent, payload, _source_id) do
    case SalixAgent.CapabilityRequests.expire_location(
           payload["group_id"],
           payload["request_id"],
           payload["tenant_id"]
         ) do
      :ok -> {:ok, :created}
      {:error, _} = error -> error
    end
  end

  defp deliver_timer(_record, agent, payload, source_id) do
    SalixAgent.deliver(agent, timer_payload(payload),
      source_message_id: source_id,
      create: false,
      session_check: :staging,
      surface: "timer"
    )
  end

  # A refusal that is a property of the TARGET — archived, or no control
  # record — is terminal for this marker, not a transient failure, because
  # keeping it armed cannot pay off. Archive is reversible, so the question is
  # whether settling can lose a timeout owed after an unarchive: it cannot,
  # because the marker is only the fast path. The wait itself lives in durable
  # session state and is indexed in the session-work projection under its own
  # deadline, which `SalixAgent.SessionWorkRecovery` fires with no window at
  # all (SessionWorkProjection.tla; TimerMarkerSettlement.tla makes that
  # backstop load-bearing rather than decorative). All the armed marker buys
  # is one failed delivery per pass, and then an object that outlives everyone
  # who wanted it: staging carried two `wait_timeout` markers for an archived
  # agent for 36 days (#839). Settle it and say so at :info — the wake is
  # genuinely not owed to anyone here, and a warning would be
  # indistinguishable from a real outage.
  #
  # Note this is the one place `catch_up/1` deliberately does not change the
  # answer. It reopens the window, so a marker COULD now survive to see an
  # unarchive — but it is settled on the first terminal refusal and never gets
  # that far, and retaining it to wait for an unarchive that may never come is
  # exactly the leak #839 was.
  #
  # A failed clear falls back to today's behavior on its own: the marker
  # stays, the next pass reaches this same terminal branch and retries it.
  defp settle_undeliverable(key, agent, session, bucket, reason) do
    case StoreTimers.clear(key) do
      :ok ->
        Logger.info(
          "timers: wake for #{agent}/#{session} (bucket #{bucket}) is undeliverable " <>
            "(#{inspect(reason)}); marker settled"
        )

      {:error, clear_reason} ->
        Logger.warning(
          "timers: clear of undeliverable #{key} failed " <>
            "(#{inspect(clear_reason)}); will retry"
        )
    end
  end

  defp timer_payload(payload) when is_map(payload) do
    payload
    |> Map.new(fn
      {"content", value} -> {:content, value}
      {"session_id", value} -> {:session_id, value}
      {"kind", value} -> {:kind, value}
      {"wait_id", value} -> {:wait_id, value}
      {"wait", value} -> {:wait, value}
      {key, value} when is_atom(key) -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp timer_payload(_payload), do: %{}

  # ---- GenServer (lease-gated periodic firing) ----

  @impl true
  def init(opts) do
    state = %{
      node: Keyword.get(opts, :node, to_string(node())),
      interval: Keyword.get(opts, :interval_ms, @interval_ms),
      catchup_interval: Keyword.get(opts, :catchup_interval_ticks, @catchup_interval_ticks),
      catchup_after: nil,
      ticks: 0,
      lease: nil
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  defp tick(state) do
    state = acquire_or_renew(state)

    state =
      if state.lease do
        log_fired("fired", fire_due([]))

        # Tick 0 runs one, so a node that has just taken the lease looks for
        # what the gap it was elected across left behind before it starts
        # drifting on the slow cadence.
        if rem(state.ticks, state.catchup_interval) == 0,
          do: run_catchup(state),
          else: state
      else
        state
      end

    Process.send_after(self(), :tick, state.interval)
    %{state | ticks: state.ticks + 1}
  end

  # The rotation cursor is process-local on purpose: it is a fairness hint, not
  # a correctness one. Losing it on restart or on a lease handover only means
  # the next pass starts from the oldest bucket again, which is where a fresh
  # holder should start anyway.
  defp run_catchup(state) do
    case catch_up(after: state.catchup_after) do
      {:ok, %{fired: fired, next: next}} ->
        log_fired("caught up stranded", {:ok, fired})
        %{state | catchup_after: next}

      {:error, _reason} = error ->
        log_fired("caught up stranded", error)
        state
    end
  end

  defp log_fired(what, {:ok, [_ | _] = fired}),
    do: Logger.info("timers: #{what} #{inspect(Enum.map(fired, & &1.source_message_id))}")

  defp log_fired(what, {:error, reason}),
    do: Logger.warning("timers: #{what} pass failed (#{inspect(reason)})")

  defp log_fired(_what, {:ok, []}), do: :ok

  defp acquire_or_renew(%{lease: nil} = state) do
    case S3Lease.acquire(:timers, state.node) do
      {:ok, token} -> %{state | lease: token}
      _ -> state
    end
  end

  defp acquire_or_renew(%{lease: token} = state) do
    case S3Lease.renew(token) do
      {:ok, token} -> %{state | lease: token}
      # Fail-closed: drop leadership; a later tick re-acquires if eligible.
      _ -> %{state | lease: nil}
    end
  end
end
