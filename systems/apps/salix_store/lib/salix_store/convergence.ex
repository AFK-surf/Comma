defmodule SalixStore.Convergence do
  @moduledoc """
  The generic engine for converging derived storage (an index, a working
  set, a projection) onto its canonical source prefix.

  Every derived-data design in this codebase repeats the same skeleton:
  lifecycle writes maintain the derived record inline, and a background pass
  walks the canonical prefix to converge whatever those writes missed —
  pre-existing records, entries drifted by documented-ambiguous S3 writes,
  releases that never landed. This module owns that skeleton once, with the
  correctness requirements that were review-hardened into the first
  implementations built in:

    * **Paged and bounded** — one `ensure/2` call walks at most
      `pages_per_run` pages and returns `{:ok, :partial}` with the cursor
      durably persisted after every page; it never drains an unbounded
      corpus in one invocation.
    * **Checkpoints are honored** — a cursor write failure aborts the run
      (`{:error, {:progress_persist_failed, _}}`); progress is never
      silently lost.
    * **Fail-closed per record** — a record the callback cannot converge
      counts as `failed` and fails the pass; the pass never records
      completion over unread data.
    * **Durable, monotonic convergence** — a completed pass writes
      `completed_at`/`completed_ever` to the marker; `converged?/1` caches a
      true result in `:persistent_term`, so post-convergence checks are
      free. Passes re-run once `completed_at` exceeds `reconcile_ms/0`,
      healing drift forever.
    * **FIXED-DELAY cadence** (owner-selected contract) — the reconcile
      interval is measured from the PERSISTED COMPLETION ANCHOR:
      `completed_at`, sampled at LOGICAL pass completion, before the
      completion writes settle. Every scheduling decision derives from
      that one persisted value: staleness/remaining are computed from a
      wall-clock sample taken after the marker read, an uninterrupted
      `Worker` reschedules via `next_due_in/2` (so completion I/O counts
      TOWARD the interval — slow persistence shortens the wait), and a
      restarted `Worker` aligns to the same value via `{:ok, :fresh,
      remaining_ms}`. With pre-anchor pass runtime `P`, completion
      persistence `W`, and interval `R`, the zero-jitter start-to-start
      period is therefore approximately `P + max(W, R)` — not
      `P + W + R`. When the anchor is SUCCESSFULLY READ, both paths
      derive the same base delay from the same marker; they deliberately
      diverge when it cannot be read (`next_due_in/2` degrades to one
      full interval, a restarted Worker's failed ensure takes the retry
      path) and in which jitter budget applies (steady vs boot). This is
      a steady-state healing floor, not a hard rate guarantee.
    * **Honest telemetry** — every pass that RUNS emits
      `[:salix, :store, :convergence]` with its true final outcome
      (`ok` / `partial` / `error`), including marker read faults and a
      completion-marker write that fails after a clean walk. A call
      short-circuited by a fresh completed marker runs no pass and emits
      nothing — pass counts measure work done, not calls made. The
      `converged` measurement counts UNITS OF CONVERGENCE WORK that
      actually mutated derived state (one per record in per-record mode,
      implementation-defined units in page mode); work verified
      already-correct reports `unchanged`, so a clean scan exports zero
      healing volume. Exception: a FAILED page exports the page's record
      count as failed units — the engine's only available measure of the
      lost work.

  Implementations provide the *what* (which prefix, what to do per record);
  the engine owns the *how*. Drive it with `SalixStore.Convergence.Worker`
  or call `ensure/2` from an existing scheduler.
  """

  alias SalixStore.S3

  @default_page_size 500
  @default_pages_per_run 4
  @default_reconcile_ms :timer.hours(1)

  @type outcome ::
          {:ok, :complete} | {:ok, :fresh, non_neg_integer()} | {:ok, :partial} | {:error, term()}
  @type stats :: %{
          converged: non_neg_integer(),
          unchanged: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Short machine name for telemetry/logs (finite, catalog-listed)."
  @callback name() :: String.t()

  @doc "The canonical source prefix this convergence walks."
  @callback source_prefix() :: String.t()

  @doc "Durable marker key holding the cursor / completion state."
  @callback marker_key() :: String.t()

  @doc """
  Converge one canonical object. `:changed` means the derived state was
  actually mutated (drift healed / bootstrap progress); `:unchanged` means
  the record was verified already correct (a clean scan MUST report this,
  never `:changed` — the exported converged volume is healing work, and
  sustained nonzero values after the first pass mean drift keeps appearing
  and warrant investigation); `:skip` is intentionally out of scope.
  `{:error, reason}` counts as failed and fails the pass — return it for
  anything unread or unwritten, never swallow.

  In this per-record mode each record is exactly one UNIT OF WORK, so the
  exported counters happen to partition the walked records. That is a
  property of this mode, not of the counters — see `converge_page/1`.
  """
  @callback converge_record(key :: String.t()) ::
              :changed | :unchanged | :skip | {:error, term()}

  @doc """
  Optional page-batch alternative to `converge_record/1`: converge one LIST
  page of keys in a single call, returning per-page counts. Implement this
  when converging into shared state (e.g. one `SalixStore.CasDirectory`
  object) so a page costs one CAS instead of one per record.

  The counters are UNITS OF CONVERGENCE WORK, implementation-defined (for
  a directory-backed index: directory mutations for `converged`, slots
  verified already-correct for `unchanged`). They are volume signals — they
  need not partition, or be bounded by, the page's record count. The
  changed/verified split still binds: `converged` MUST count only work that
  actually mutated derived state, so a clean verification pass reports zero
  `converged`. Any error fails the whole page (the engine then counts the
  page's records as failed units — its only available measure of the lost
  work) — same fail-closed rule as `converge_record/1`.
  """
  @callback converge_page(keys :: [String.t()]) ::
              {:ok,
               %{
                 optional(:unchanged) => non_neg_integer(),
                 converged: non_neg_integer(),
                 skipped: non_neg_integer()
               }}
              | {:error, term()}

  @doc """
  Steady-state interval between full passes, measured FIXED-DELAY from the
  previous pass's persisted completion anchor (`completed_at`, sampled at
  logical pass completion). Optional; defaults to 1h.
  """
  @callback reconcile_ms() :: pos_integer()

  @optional_callbacks converge_record: 1, converge_page: 1, reconcile_ms: 0

  # ---- public API ----

  @doc """
  True once at least one full pass has ever completed for `impl`.
  Monotonic: a true result is cached process-wide and never re-read.
  """
  @spec converged?(module()) :: boolean()
  def converged?(impl) do
    :persistent_term.get({__MODULE__, impl}, false) or read_converged(impl)
  end

  @doc "Test hook: drop the monotonic converged cache (backing store was reset)."
  @spec reset_converged_cache(module()) :: :ok
  def reset_converged_cache(impl) do
    _ = :persistent_term.erase({__MODULE__, impl})
    :ok
  end

  @doc """
  Advance convergence by a bounded amount: resume an in-progress pass from
  its persisted cursor, start a fresh pass when none ran yet or the last
  completed pass is stale (a FUTURE completed_at is anomalous and treated
  as stale), and no-op with one GET otherwise — returning
  `{:ok, :fresh, remaining_ms}` so schedulers can align to the durable
  marker's remaining deadline instead of restarting a whole interval.
  """
  @spec ensure(module(), keyword()) :: outcome()
  def ensure(impl, opts \\ []) do
    reconcile_ms = opts[:reconcile_ms] || impl_reconcile_ms(impl)

    # FIXED-DELAY cadence (the selected contract): the interval is measured
    # from the durable completed_at, which records the pass's actual
    # COMPLETION time. One wall-clock source feeds every decision — staleness
    # and remaining-deadline are computed from a sample taken AFTER the
    # marker read (a slow GET cannot inflate the remaining deadline), and
    # completion re-samples it (a slow pass cannot age the next deadline
    # before it even starts). Tests inject a fixed `now`.
    now_fn =
      case opts[:now] do
        nil -> fn -> System.system_time(:millisecond) end
        fixed -> fn -> fixed end
      end

    budget = %{
      pages: opts[:pages_per_run] || @default_pages_per_run,
      page_size: opts[:page_size] || @default_page_size
    }

    started = System.monotonic_time(:millisecond)

    case read_marker(impl) do
      {:error, :not_found} ->
        converge(impl, nil, now_fn, false, budget, started, :create)

      {:ok, %{"completed_at" => at}, etag} when is_integer(at) ->
        now = now_fn.()

        cond do
          # A future completed_at (cross-node skew, a backward wall-clock
          # correction) is anomalous durable state: fail SAFE to a pass —
          # trusting it would suppress healing until wall time catches up.
          at > now ->
            converge(impl, nil, now_fn, true, budget, started, etag)

          now - at >= reconcile_ms ->
            converge(impl, nil, now_fn, true, budget, started, etag)

          # Marker still fresh: no-op, reporting the REMAINING deadline so a
          # scheduler can align to the durable cadence instead of restarting
          # a whole interval from now.
          true ->
            {:ok, :fresh, reconcile_ms - (now - at)}
        end

      {:ok, %{"cursor" => cursor} = marker, etag} when is_binary(cursor) and cursor != "" ->
        converge(impl, cursor, now_fn, marker["completed_ever"] == true, budget, started, etag)

      {:ok, marker, etag} when is_map(marker) ->
        converge(impl, nil, now_fn, marker["completed_ever"] == true, budget, started, etag)

      # A marker read fault is a failed attempt too — visible in telemetry.
      {:error, reason} ->
        emit(impl, :error, zero_stats(), started)
        {:error, reason}
    end
  end

  @doc """
  Milliseconds until the next pass is due, derived from the PERSISTED
  completion anchor — the same source a restarted scheduler would read.
  `0` means due now (no marker, an in-progress cursor, an expired or
  anomalous-future `completed_at`). A marker read fault returns the full
  `reconcile_ms` (waiting a whole interval is the safe degradation; the
  next attempt re-reads).

  This is how a scheduler accounts for completion I/O: `completed_at` is
  sampled before the completion writes are settled, so deriving the delay
  from the durable value (instead of "interval from when ensure returned")
  keeps an uninterrupted scheduler and a restarted one on the same anchor.
  """
  @spec next_due_in(module(), pos_integer()) :: non_neg_integer()
  def next_due_in(impl, reconcile_ms) do
    case read_marker(impl) do
      {:ok, %{"completed_at" => at}, _etag} when is_integer(at) ->
        now = System.system_time(:millisecond)

        cond do
          at > now -> 0
          now - at >= reconcile_ms -> 0
          true -> reconcile_ms - (now - at)
        end

      {:ok, _marker, _etag} ->
        0

      {:error, :not_found} ->
        0

      {:error, _reason} ->
        reconcile_ms
    end
  end

  @doc "The effective steady-state reconcile interval for `impl`."
  @spec impl_reconcile_ms(module()) :: pos_integer()
  def impl_reconcile_ms(impl) do
    # On a fresh BEAM the consumer module may not be loaded yet;
    # function_exported?/3 alone would silently pin the default interval.
    _ = Code.ensure_loaded(impl)

    if function_exported?(impl, :reconcile_ms, 0),
      do: impl.reconcile_ms(),
      else: @default_reconcile_ms
  end

  # ---- engine ----

  defp converge(impl, cursor, now_fn, completed_ever, budget, started, marker_etag) do
    case converge_pages(impl, cursor, zero_stats(), completed_ever, budget, marker_etag) do
      {:complete, stats, chain_etag} ->
        # Completion is durable before it is reported, in two writes with
        # distinct roles: the create-once completed_ever record first (the
        # monotonic truth converged? reads — immune to concurrent workers
        # overwriting the mutable marker), then the marker's completed_at,
        # CAS-chained like every other marker write in this pass so a
        # superseded pass cannot clobber a newer one's state. completed_at
        # is RE-SAMPLED here (fixed-delay: the anchor is the pass's actual
        # completion — a slow pass must not durably age the next deadline).
        completion = %{"completed_at" => now_fn.(), "completed_ever" => true, "stats" => stats}

        with :ok <- put_completed_ever(impl),
             {:ok, _etag} <- put_marker(impl, completion, chain_etag) do
          emit(impl, :ok, stats, started)
          {:ok, :complete}
        else
          {:error, :superseded} ->
            emit(impl, :error, stats, started)
            {:error, {:superseded_pass, impl.name()}}

          {:error, reason} ->
            emit(impl, :error, stats, started)
            {:error, {:completion_marker_failed, reason}}
        end

      {:partial, stats, _chain_etag} ->
        emit(impl, :partial, stats, started)
        {:ok, :partial}

      {:error, reason, stats} ->
        emit(impl, :error, stats, started)
        {:error, reason}
    end
  end

  defp put_completed_ever(impl) do
    body = Jason.encode!(%{"completed_at" => System.system_time(:millisecond)})

    case S3.put(completed_key(impl), body, if_none_match: "*") do
      {:ok, _} ->
        :ok

      # Another pass completed first — monotonic, theirs stands.
      {:error, :precondition_failed} ->
        :ok

      {:error, {:ambiguous, _}} ->
        case S3.head(completed_key(impl)) do
          {:ok, _} -> :ok
          {:error, :not_found} -> {:error, {:ambiguous, :completed_ever_lost}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Page budget spent mid-pass: the cursor for the next page is already
  # persisted, so the next ensure resumes exactly here.
  defp converge_pages(_impl, _cursor, stats, _completed_ever, %{pages: 0}, chain_etag),
    do: {:partial, stats, chain_etag}

  defp converge_pages(impl, cursor, stats, completed_ever, budget, chain_etag) do
    list_opts = [max_keys: budget.page_size] ++ if cursor, do: [start_after: cursor], else: []

    case S3.list(impl.source_prefix(), list_opts) do
      {:ok, %{objects: objects, next: next}} ->
        stats = converge_objects(impl, objects, stats)

        cond do
          stats.failed > 0 ->
            # Best-effort progress note; the run is already failing and a
            # rerun from the previous cursor is idempotent.
            _ = put_progress(impl, cursor, completed_ever, chain_etag)
            {:error, {:convergence_failed, impl.name(), stats}, stats}

          is_nil(next) or objects == [] ->
            {:complete, stats, chain_etag}

          true ->
            last_key = List.last(objects).key

            # Cursor writes are CAS-chained on the marker state this pass
            # observed: a 412 means another worker advanced the shared marker
            # — this pass is superseded and stops rather than overwriting
            # newer progress. A lost cursor write likewise aborts the run
            # (progress is never silently dropped).
            case put_progress(impl, last_key, completed_ever, chain_etag) do
              {:ok, next_etag} ->
                converge_pages(
                  impl,
                  last_key,
                  stats,
                  completed_ever,
                  %{budget | pages: budget.pages - 1},
                  next_etag
                )

              {:error, :superseded} ->
                {:error, {:superseded_pass, impl.name()}, stats}

              {:error, reason} ->
                {:error, {:progress_persist_failed, reason}, stats}
            end
        end

      {:error, reason} ->
        {:error, reason, stats}
    end
  end

  defp converge_objects(impl, objects, stats) do
    keys = Enum.map(objects, & &1.key)

    if function_exported?(impl, :converge_page, 1) do
      # Implementations are internal typed behaviours, but a malformed
      # result must degrade to a failed page (visible in telemetry), never
      # corrupt durable stats or crash the Worker. The counters are volume
      # signals — they need not partition the page's records.
      case impl.converge_page(keys) do
        {:ok, %{converged: converged, skipped: skipped} = page}
        when is_integer(converged) and converged >= 0 and is_integer(skipped) and skipped >= 0 ->
          unchanged = Map.get(page, :unchanged, 0)

          if is_integer(unchanged) and unchanged >= 0 do
            stats
            |> Map.update!(:converged, &(&1 + converged))
            |> Map.update!(:unchanged, &(&1 + unchanged))
            |> Map.update!(:skipped, &(&1 + skipped))
          else
            fail_page(impl, keys, stats, {:invalid_page_result, page})
          end

        {:error, reason} ->
          fail_page(impl, keys, stats, reason)

        other ->
          fail_page(impl, keys, stats, {:invalid_page_result, other})
      end
    else
      Enum.reduce(keys, stats, fn key, acc -> converge_one(impl, key, acc) end)
    end
  end

  defp fail_page(impl, keys, stats, reason) do
    CommaLog.log("store_convergence_page_failed", %{
      name: impl.name(),
      keys: length(keys),
      reason: inspect(reason)
    })

    Map.update!(stats, :failed, &(&1 + length(keys)))
  end

  defp converge_one(impl, key, stats) do
    case impl.converge_record(key) do
      :changed ->
        bump(stats, :converged)

      :unchanged ->
        bump(stats, :unchanged)

      :skip ->
        bump(stats, :skipped)

      {:error, reason} ->
        CommaLog.log("store_convergence_record_failed", %{
          name: impl.name(),
          key: key,
          reason: inspect(reason)
        })

        bump(stats, :failed)

      # A malformed callback result (e.g. the legacy :ok) counts as a
      # failed record — visible in telemetry, never a Worker crash.
      other ->
        CommaLog.log("store_convergence_record_invalid_result", %{
          name: impl.name(),
          key: key,
          result: inspect(other)
        })

        bump(stats, :failed)
    end
  end

  # ---- marker IO ----

  # The monotonic completed-ever fact lives in its own create-once object,
  # never touched by progress writes: a slow worker overwriting the mutable
  # cursor marker with a stale view cannot regress converged?.
  defp completed_key(impl), do: impl.marker_key() <> ".completed_ever"

  defp read_converged(impl) do
    case S3.head(completed_key(impl)) do
      {:ok, _} -> cache_converged(impl)
      _ -> false
    end
  end

  defp cache_converged(impl) do
    :persistent_term.put({__MODULE__, impl}, true)
    true
  end

  defp read_marker(impl) do
    case S3.get(impl.marker_key()) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, marker} when is_map(marker) -> {:ok, marker, etag}
          _ -> {:ok, %{}, etag}
        end

      {:error, :not_found} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_progress(impl, cursor, completed_ever, chain_etag) do
    put_marker(impl, %{"cursor" => cursor || "", "completed_ever" => completed_ever}, chain_etag)
  end

  # Every marker write in a pass is CAS-chained on the marker state that
  # pass last observed: `:create` for a fresh marker (create-once — two
  # fresh passes racing collapse to one), an ETag otherwise. A 412 anywhere
  # in the chain means another worker advanced the marker: this pass is
  # superseded (`{:error, :superseded}`) and must stop rather than clobber
  # newer progress. An ambiguous PUT settles by exact read-back.
  #
  # Byte-comparison settlement is sufficient HERE (unlike CasDirectory,
  # which settles by op token): marker bodies are pure position statements,
  # so both misreadings are safe. Adopting another pass's byte-twin cursor
  # continues from the same position with idempotent page work; mistaking
  # our own landed-but-superseded write for a conflict yields :superseded,
  # which STOPS this pass — never re-runs work over newer progress.
  defp put_marker(impl, marker, chain_etag) do
    body = Jason.encode!(marker)

    put_opts =
      case chain_etag do
        :create -> [if_none_match: "*"]
        etag -> [if_match: etag]
      end

    case S3.put(impl.marker_key(), body, put_opts) do
      {:ok, %{etag: etag}} ->
        {:ok, etag}

      {:error, :precondition_failed} = error ->
        case S3.get(impl.marker_key()) do
          {:ok, %{body: ^body, etag: etag}} -> {:ok, etag}
          {:ok, _} -> {:error, :superseded}
          _ -> error
        end

      {:error, {:ambiguous, _}} = error ->
        case S3.get(impl.marker_key()) do
          {:ok, %{body: ^body, etag: etag}} -> {:ok, etag}
          {:ok, _} -> {:error, :superseded}
          _ -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit(impl, outcome, stats, started) do
    duration_ms = System.monotonic_time(:millisecond) - started

    CommaLog.log(
      "store_convergence",
      stats
      |> Map.put(:name, impl.name())
      |> Map.put(:outcome, outcome)
      |> Map.put(:duration_ms, duration_ms)
    )

    :telemetry.execute(
      [:salix, :store, :convergence],
      Map.put(stats, :duration_ms, duration_ms),
      %{name: impl.name(), outcome: to_string(outcome)}
    )
  end

  defp zero_stats, do: %{converged: 0, unchanged: 0, skipped: 0, failed: 0}
  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))
end
