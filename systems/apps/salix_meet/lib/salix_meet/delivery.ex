defmodule SalixMeet.Delivery do
  @moduledoc """
  Periodic terminal-meeting delivery runner.

  This is the meeting-agent model replacement for the old bridge-link delivery
  loop. It scans durable meeting state, claims terminal meetings through the
  meeting state itself, and publishes results through the provider boundary.
  """

  use GenServer
  require Logger

  alias SalixMeet.{OwnerAttributionSnapshot, Runtime, RuntimeEvents, SlackThreadIndex, Store}
  alias SalixStore.Lease

  @interval 5_000
  @lease_key "ctl/meet/delivery/lease.json"

  @status_refresh_ms 90_000
  @status_refresh_retry_ms 5_000
  @summary_derivation_version 2
  @summary_derivation_kind "meeting_summary"
  @duplicate_slack_error "duplicate Slack thread meeting; canonical owner retained"

  @delivery_telemetry_outcomes %{
    published: "ok",
    terminal_failed: "unavailable",
    failed: "error",
    # A delivery parked on a disabled connect is a known blocked state, not a
    # failure: it is deliberately exempt from the retry budget so it can catch
    # up when the connect is re-enabled. Reporting it as `error` would keep
    # the delivery error-rate condition permanently breached for a connect
    # nobody intends to fix, which is exactly how an alert stops meaning
    # anything.
    blocked_waiting: "retained",
    summary_waiting: "retained",
    lost: "conflict"
  }

  # How long a delivery parked on a disabled connect waits before its next
  # attempt. Without it the sweep re-claims every 5 seconds forever; the wait
  # itself is intended, the spin is not.
  @disabled_connect_backoff_ms 5 * 60 * 1000

  # Bounded-retry convergence: an unclassifiable delivery failure keeps
  # retrying until BOTH gates open — enough claims and enough wall-clock time
  # since the first failure — and the final round converges to a terminal
  # failure instead of another silent retry. Never expressed as a claim
  # refusal: that would create an invisible dead state with no terminal
  # marker, no activation, and no operator signal.
  @delivery_retry_max_attempts 12
  @delivery_retry_min_elapsed_ms 24 * 60 * 60 * 1000

  @type outcome ::
          :published
          | :failed
          | :terminal_failed
          | :skipped
          | :not_claimable
          | :lost
          | :activated
          | :activation_skipped
          | :activation_failed
          | :watchdog_terminalized
          | :watchdog_duplicate_retired
          | :blocked_waiting
          | :summary_waiting

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Run one deterministic delivery pass."
  @spec sweep_once(keyword()) :: [{String.t(), outcome()}] | {:error, term()}
  def sweep_once(opts \\ []) do
    case Store.list() do
      {:ok, ids} -> Enum.map(ids, fn id -> {id, deliver_one(id, opts)} end)
      {:error, _} = err -> err
    end
  end

  @doc "Claim and publish one terminal meeting."
  @spec deliver_one(String.t(), keyword()) :: outcome()
  def deliver_one(meeting_id, opts \\ []) do
    node = opts[:node] || to_string(node())

    case Store.claim_terminal_work(
           meeting_id,
           node,
           Keyword.take(opts, [:now, :reclaim_after_ms])
         ) do
      {:ok, :delivery, doc, _etag, claim} ->
        publish_claimed_observed(meeting_id, doc, claim)

      {:ok, :activation, %{"state" => state}, _etag, claim} ->
        activate_claimed(meeting_id, stringify(state || %{}), claim)

      {:ok, :activation, _doc, _etag, claim} ->
        fail_activation(meeting_id, claim, :invalid_meeting_state)

      {:error, {:not_terminal, doc}} ->
        watchdog_check(meeting_id, doc, opts)

      {:error, :not_claimable} ->
        :not_claimable

      {:error, :lost} ->
        :lost

      {:error, {:activation, reason}} ->
        Logger.warning(
          "meeting router activation claim failed for #{meeting_id}: #{inspect(reason)}"
        )

        :activation_failed

      {:error, reason} ->
        # A claim-stage failure (storage read/CAS trouble) used to be silently
        # folded into :skipped, indistinguishable from an ordinary non-terminal
        # meeting. Surface it: during a storage outage this is the only signal.
        Logger.warning("meeting delivery claim failed for #{meeting_id}: #{inspect(reason)}")

        Salix.Telemetry.emit_operation(
          "salix_meet",
          "meeting_delivery_claim",
          "system",
          "error",
          0
        )

        :skipped
    end
  end

  # ---- summary watchdog (RFC contract two) ----
  #
  # The cutoff is a product policy — the accepted maximum overtime — never
  # evidence that the meeting ended. When the runtime is reachable the
  # three-valued live-session read decides first: definitely-live extends the
  # anchor and we keep waiting; definitely-none confirms only the terminal
  # event was lost; unavailable (a dead connector — exactly the case the
  # watchdog exists for) leaves the decision to the time cutoff alone. The
  # predicate is re-validated inside the terminalizing CAS, and the PR2
  # terminal one-way valve guarantees the verdict cannot be overwritten by a
  # late runtime event afterward.
  defp watchdog_check(meeting_id, doc, opts) do
    now_s = opts[:watchdog_now_s] || System.system_time(:second)
    cutoff_s = opts[:watchdog_cutoff_s] || Store.watchdog_cutoff_s()

    case Store.watchdog_eligibility(doc, now_s, cutoff_s) do
      {:eligible, _deadline} ->
        watchdog_decide(meeting_id, stringify(doc["state"] || %{}), now_s, opts)

      :no_anchor ->
        # Eligible-shaped but unterminalizable: no timestamp anchor at all.
        # This is the stuck population the alert watches.
        Salix.Telemetry.emit_operation(
          "salix_meet",
          "meeting_stuck_nonterminal",
          "system",
          "retained",
          0
        )

        :skipped

      _verdict ->
        :skipped
    end
  end

  # The probe-then-decide sequence is serialized per meeting through a
  # claimed probe generation: without it, two sweeps overlapping across a
  # lost global lease could both probe, and an `unavailable` answer landing
  # its CAS first would permanently terminalize a meeting whose other probe
  # had just confirmed a live bot. Only the claim holder probes; both
  # decision writes are fenced on the claimed generation. The whole
  # sequence is checked as tla/salix/MeetingWatchdogProbe.tla
  # (NoKillOverCurrentLiveAnswer / NoKillAfterAnchor / EventuallySettled).
  defp watchdog_decide(meeting_id, state, now_s, opts) do
    case canonical_slack_thread_owner(meeting_id, state) do
      :current_or_unindexed ->
        watchdog_probe_decide(meeting_id, state, now_s, opts)

      {:duplicate, canonical_meeting_id} ->
        retire_duplicate_slack_meeting(meeting_id, canonical_meeting_id, state, now_s, opts)

      {:error, reason} ->
        Logger.warning(
          "meeting watchdog Slack thread owner lookup failed meeting=#{meeting_id}: " <>
            inspect(reason)
        )

        emit_watchdog("error")
        :skipped
    end
  end

  # Current Slack ingestion claims this immutable owner before creating a
  # meeting. Older deployments could create a message + app_mention twin on
  # separate nodes before that fence shipped. Only the indexed owner may ever
  # write to the shared provider thread; a legacy non-owner is retired before
  # the modeled runtime probe protocol starts. The owner/canonical reads and
  # shadow retrying CAS are checked by
  # tla/salix/MeetingWatchdogDuplicateRetirement.tla
  # (RetiredOnlyWithAuthority / TerminalWinnerNotRetired /
  # PublishedWinnerNotRetired).
  defp canonical_slack_thread_owner(meeting_id, %{"provider" => "slack"} = state) do
    case slack_thread_ref(state) do
      :missing ->
        :current_or_unindexed

      {:ok, channel, thread} ->
        case SlackThreadIndex.fetch(state, channel, thread) do
          {:ok, %{"meeting_id" => ^meeting_id}} ->
            :current_or_unindexed

          {:ok, %{"meeting_id" => canonical_meeting_id}}
          when is_binary(canonical_meeting_id) and canonical_meeting_id != "" ->
            validate_canonical_slack_meeting(canonical_meeting_id, state, channel, thread)

          {:error, :not_found} ->
            :current_or_unindexed

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_slack_thread_owner, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical_slack_thread_owner(_meeting_id, _state), do: :current_or_unindexed

  defp slack_thread_ref(%{"slack_ref" => slack_ref} = state) when is_map(slack_ref) do
    with {:ok, _tenant_id} <- normalize_slack_scope_value(state["tenant_id"]),
         {:ok, _group_id} <- normalize_slack_scope_value(state["group_id"]),
         {:ok, _connect_id} <- normalize_slack_scope_value(state["connect_id"]),
         {:ok, channel} <- normalize_slack_scope_value(slack_ref["channel_id"]),
         {:ok, thread} <- normalize_slack_scope_value(slack_ref["thread_ts"]) do
      {:ok, channel, thread}
    else
      :error -> {:error, :invalid_slack_thread_scope}
    end
  end

  defp slack_thread_ref(state) when is_map(state) do
    if Map.has_key?(state, "slack_ref"),
      do: {:error, :invalid_slack_thread_scope},
      else: :missing
  end

  defp normalize_slack_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_slack_scope_value(_value), do: :error

  defp validate_canonical_slack_meeting(canonical_meeting_id, state, channel, thread) do
    case Store.get(canonical_meeting_id) do
      {:ok, %{"state" => canonical_state}, _etag} ->
        canonical_state = stringify(canonical_state || %{})

        if same_slack_conversation?(canonical_state, state, channel, thread),
          do: {:duplicate, canonical_meeting_id},
          else: {:error, {:canonical_slack_scope_mismatch, canonical_meeting_id}}

      {:error, reason} ->
        {:error, {:canonical_slack_meeting_unavailable, reason}}

      other ->
        {:error, {:canonical_slack_meeting_unavailable, other}}
    end
  end

  defp same_slack_conversation?(candidate, state, channel, thread)
       when is_map(candidate) and is_map(state) do
    candidate_ref = candidate["slack_ref"]

    is_map(candidate_ref) and
      candidate["tenant_id"] == state["tenant_id"] and
      candidate["group_id"] == state["group_id"] and
      candidate["connect_id"] == state["connect_id"] and
      candidate["provider"] == "slack" and
      candidate_ref["channel_id"] == channel and
      candidate_ref["thread_ts"] == thread
  end

  defp same_slack_conversation?(_candidate, _state, _channel, _thread), do: false

  defp retire_duplicate_slack_meeting(
         meeting_id,
         canonical_meeting_id,
         expected_state,
         now_s,
         opts
       ) do
    now_ms = opts[:now] || now_s * 1_000

    case Store.update_state_retrying(meeting_id, fn live_state ->
           live_state = stringify(live_state || %{})
           delivery = stringify(live_state["delivery"] || %{})
           channel = trim(get_in(expected_state, ["slack_ref", "channel_id"]))
           thread = trim(get_in(expected_state, ["slack_ref", "thread_ts"]))

           cond do
             live_state["status"] in RuntimeEvents.terminal_statuses() ->
               live_state

             not same_slack_conversation?(live_state, expected_state, channel, thread) ->
               live_state

             delivery["published_at"] not in [nil, "", false] or
                 trim(delivery["summary_message_ts"]) != "" ->
               live_state

             true ->
               next_delivery =
                 Map.merge(delivery, %{
                   "status" => "failed_terminal",
                   "failure_kind" => "duplicate_slack_thread",
                   "error" => @duplicate_slack_error,
                   "updated_at" => now_ms
                 })

               live_state
               |> Map.put("status", "cancelled")
               |> Map.put("error", @duplicate_slack_error)
               |> Map.put("watchdog", %{
                 "reason" => "duplicate_slack_thread",
                 "canonical_meeting_id" => canonical_meeting_id,
                 "terminalized_at" => now_s
               })
               |> Map.put("delivery", next_delivery)
           end
         end) do
      {:ok, %{"state" => state}, _etag} ->
        state = stringify(state || %{})

        if get_in(state, ["watchdog", "reason"]) == "duplicate_slack_thread" and
             get_in(state, ["watchdog", "canonical_meeting_id"]) == canonical_meeting_id do
          Logger.info(
            "meeting watchdog retired duplicate Slack meeting=#{meeting_id} " <>
              "canonical=#{canonical_meeting_id}"
          )

          emit_watchdog("ignored")
          :watchdog_duplicate_retired
        else
          :skipped
        end

      {:error, reason} ->
        Logger.warning(
          "meeting watchdog duplicate retirement failed meeting=#{meeting_id}: #{inspect(reason)}"
        )

        emit_watchdog("error")
        :skipped
    end
  end

  defp watchdog_probe_decide(meeting_id, state, now_s, opts) do
    node = opts[:node] || to_string(node())
    cas_opts = watchdog_cas_opts(opts, now_s)

    case Store.claim_watchdog_probe(meeting_id, node, cas_opts) do
      {:ok, generation} ->
        watchdog_act(meeting_id, state, now_s, generation, cas_opts)

      {:error, :probe_held} ->
        # Another sweep's probe is in flight; its answer decides.
        :skipped

      {:error, {:watchdog_ineligible, _verdict}} ->
        :skipped

      {:error, reason} ->
        Logger.warning(
          "meeting watchdog probe claim failed meeting=#{meeting_id}: #{inspect(reason)}"
        )

        emit_watchdog("error")
        :skipped
    end
  end

  defp watchdog_act(meeting_id, state, now_s, generation, cas_opts) do
    case runtime_liveness(meeting_id, state) do
      :live ->
        case Store.refresh_runtime_liveness(meeting_id, now_s, generation) do
          {:ok, _doc, _etag} ->
            emit_watchdog("retained")

          {:error, :fenced} ->
            # A newer probe stole the claim; its answer decides.
            :ok

          {:error, reason} ->
            Logger.warning(
              "meeting watchdog liveness refresh failed meeting=#{meeting_id}: #{inspect(reason)}"
            )

            emit_watchdog("error")
        end

        :skipped

      answer when answer in [:none, :unavailable, :unavailable_idempotent] ->
        case Store.mark_runtime_lost(meeting_id, cas_opts ++ [generation: generation]) do
          {:ok, _doc, _etag} ->
            Logger.warning(
              "meeting watchdog terminalized meeting=#{meeting_id} " <>
                "liveness=#{answer} reason=runtime_lost"
            )

            emit_watchdog("ok")
            :watchdog_terminalized

          {:error, :fenced} ->
            # A newer probe stole the claim; its answer decides.
            :skipped

          {:error, {:watchdog_ineligible, _verdict}} ->
            # A racing terminal event or liveness refresh won; that is the
            # valve working as intended.
            :skipped

          {:error, reason} ->
            Logger.warning(
              "meeting watchdog terminalization failed meeting=#{meeting_id}: #{inspect(reason)}"
            )

            emit_watchdog("error")
            :skipped
        end
    end
  end

  defp watchdog_cas_opts(opts, now_s) do
    base = Keyword.take(opts, [:now]) ++ [now_s: now_s]

    case Keyword.fetch(opts, :watchdog_cutoff_s) do
      {:ok, cutoff} -> base ++ [cutoff_s: cutoff]
      :error -> base
    end
  end

  defp runtime_liveness(meeting_id, state) do
    case SalixMeet.Ports.MeetingDispatch.session_status(%{
           "meeting_id" => meeting_id,
           "group_id" => state["group_id"],
           "connect_id" => state["connect_id"],
           "runtime_source" => state["runtime_source"]
         }) do
      {:ok, answer} when answer in [:live, :none, :unavailable, :unavailable_idempotent] ->
        answer

      _other ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp emit_watchdog(outcome) do
    Salix.Telemetry.emit_operation("salix_meet", "meeting_watchdog", "system", outcome, 0)
  end

  @impl true
  def init(opts) do
    interval = opts[:interval_ms] || @interval
    state = %{interval: interval, lease: nil, node: opts[:node] || to_string(node())}
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = tick(state)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  defp tick(%{lease: nil} = state) do
    case Lease.acquire(@lease_key, state.node) do
      {:ok, lease} ->
        _ = sweep_once(node: state.node)
        %{state | lease: lease}

      {:error, {:held_by, _, _}} ->
        state

      {:error, reason} ->
        Logger.warning("meeting delivery lease acquire failed: #{inspect(reason)}")
        state
    end
  end

  defp tick(%{lease: lease} = state) do
    case Lease.renew(lease) do
      {:ok, lease} ->
        _ = sweep_once(node: state.node)
        %{state | lease: lease}

      {:error, :lost} ->
        %{state | lease: nil}

      {:error, reason} ->
        Logger.warning("meeting delivery lease renew failed: #{inspect(reason)}")
        %{state | lease: nil}
    end
  end

  defp publish_claimed(meeting_id, %{"state" => state}, claim) do
    state = stringify(state || %{})
    refresher = start_claim_refresher(meeting_id, claim)

    try do
      publish_claimed_with_refresh(meeting_id, state, claim)
    after
      stop_refresher(refresher)
    end
  end

  defp publish_claimed(meeting_id, _doc, claim) do
    fail_claimed(meeting_id, claim, "invalid meeting state")
  end

  defp publish_claimed_observed(meeting_id, doc, claim) do
    started_at = System.monotonic_time()

    try do
      outcome = publish_claimed(meeting_id, doc, claim)
      emit_delivery_telemetry(delivery_telemetry_outcome(outcome), started_at)
      outcome
    rescue
      exception ->
        emit_delivery_telemetry("error", started_at)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_delivery_telemetry("error", started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_delivery_telemetry(outcome, started_at) do
    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_delivery",
      "system",
      outcome,
      System.monotonic_time() - started_at
    )
  end

  defp delivery_telemetry_outcome(outcome),
    do: Map.get(@delivery_telemetry_outcomes, outcome, "other")

  defp publish_claimed_with_refresh(meeting_id, state, claim) do
    with :ok <- Store.check_delivery_claim(meeting_id, claim),
         {:ok, summary} <- prepare_summary_for_delivery(meeting_id, state, claim) do
      publish_after_attribution_gate(meeting_id, state, summary, claim)
    else
      {:error, :fenced} ->
        :lost

      {:error, :router_summary_pending} ->
        case Store.fail_delivery_retrying(meeting_id, claim, "waiting for Router summary",
               retry_after_ms: 5_000
             ) do
          {:ok, _, _} -> :summary_waiting
          {:error, :fenced} -> :lost
          _ -> :failed
        end

      {:error, :router_summary_timeout} ->
        terminal_failed_outcome(
          meeting_id,
          claim,
          "router_summary_timeout",
          "Router summary attempts exhausted"
        )

      {:error, reason} ->
        maybe_terminal_fail(meeting_id, claim, reason, state)
    end
  end

  defp publish_after_attribution_gate(meeting_id, state, summary, claim) do
    with :ok <- Store.check_delivery_claim(meeting_id, claim),
         {:ok, %{"state" => live_state}, _etag} <- Store.get(meeting_id) do
      live_state = stringify(live_state || %{})

      if live_state["status"] in ["failed", "cancelled"] do
        publish_after_attribution_gate_with_refresh(meeting_id, live_state, summary, claim)
      else
        publish_with_generating_status(meeting_id, live_state, summary, claim)
      end
    else
      {:error, :fenced} -> :lost
      {:error, reason} -> maybe_terminal_fail(meeting_id, claim, reason, state)
    end
  end

  defp publish_with_generating_status(meeting_id, state, summary, claim) do
    _ = set_generating_status(meeting_id, state, claim)
    status_refresher = start_status_refresher(meeting_id, state, claim)

    try do
      publish_after_attribution_gate_with_refresh(meeting_id, state, summary, claim)
    after
      stop_refresher(status_refresher)
    end
  end

  defp publish_after_attribution_gate_with_refresh(meeting_id, state, summary, claim) do
    with :ok <- Store.check_delivery_claim(meeting_id, claim),
         {:ok, meeting_agent} <-
           Runtime.status_for_group(state["tenant_id"], state["group_id"]),
         {:ok, _result} <-
           Runtime.publish(meeting_agent, %{
             "provider" => state["provider"],
             "kind" => "summary",
             "meeting_id" => meeting_id,
             "delivery_claim" => claim
           }) do
      state = Map.put(state, "meeting_id", meeting_id)
      _ = deliver_activation(meeting_id, claim["claim_node"], [])
      _ = project_memory(state, summary)
      :published
    else
      {:error, :fenced} ->
        :lost

      {:error, {:terminal, {:canvas_unavailable, reason}}} ->
        case fail_claimed_terminal(meeting_id, claim, "canvas_unavailable", reason) do
          {:terminal_failed, terminal_state} ->
            delivery = stringify(terminal_state["delivery"] || %{})

            if Store.activation_delivery_ready?(delivery, meeting_id) do
              _ = deliver_activation(meeting_id, claim["claim_node"], [])
              _ = project_memory(Map.put(terminal_state, "meeting_id", meeting_id), summary)
            end

            :terminal_failed

          outcome ->
            outcome
        end

      # An abandoned message post is the provider's own permanent conclusion
      # (message_post_failed already classified: not rate limiting, not an
      # ambiguous write). Retrying it every sweep was the silent infinite
      # loop; converge through the existing terminal channel. No extra
      # provider post is attempted — posting is exactly what just proved
      # impossible.
      {:error, {:message_post_abandoned, reason}} ->
        terminal_failed_outcome(meeting_id, claim, "message_post_abandoned", reason)

      # A deleted connect can never publish again; a merely disabled one
      # keeps the existing wait-and-catch-up behavior (handled by the gate
      # exemption in maybe_terminal_fail/4).
      {:error, {:connect_terminal, reason}} ->
        terminal_failed_outcome(meeting_id, claim, "connect_deleted", reason)

      {:error, reason} ->
        maybe_terminal_fail(meeting_id, claim, reason, state)

      other ->
        maybe_terminal_fail(meeting_id, claim, other, state)
    end
  end

  defp terminal_failed_outcome(meeting_id, claim, failure_kind, reason) do
    case fail_claimed_terminal(meeting_id, claim, failure_kind, reason) do
      {:terminal_failed, _terminal_state} -> :terminal_failed
      outcome -> outcome
    end
  end

  defp fail_claimed(meeting_id, claim, reason) do
    blocked? = connect_disabled_reason?(reason)
    opts = if blocked?, do: [retry_after_ms: @disabled_connect_backoff_ms], else: []
    failed_outcome = if blocked?, do: :blocked_waiting, else: :failed

    case Store.fail_delivery_retrying(meeting_id, claim, inspect(reason), opts) do
      {:ok, _doc, _etag} ->
        failed_outcome

      {:error, :fenced} ->
        :lost

      # The blocked outcome may only be reported once the blocked state is
      # durably recorded. When the checkpoint write itself fails the delivery
      # is still `delivering` with no backoff, so reporting `retained` would
      # mask a storage error behind a benign label — the opposite of what
      # this outcome exists for.
      {:error, _} ->
        :failed
    end
  end

  # Bounded-retry convergence: when both gates are open — attempt count AND
  # elapsed time since the first failure — the round that just failed becomes
  # the last one and converges to a terminal failure. A disabled connect is
  # exempt: waiting out a disable and catching up on re-enable is existing,
  # intentional behavior.
  defp maybe_terminal_fail(meeting_id, claim, reason, state) do
    if retry_budget_exhausted?(state) and not connect_disabled_reason?(reason) do
      terminal_failed_outcome(meeting_id, claim, "retry_budget_exhausted", reason)
    else
      fail_claimed(meeting_id, claim, reason)
    end
  end

  defp retry_budget_exhausted?(state) do
    delivery = stringify(stringify(state || %{})["delivery"] || %{})
    attempts = delivery["attempt_count"]
    first_failed_at = delivery["first_failed_at"]

    is_integer(attempts) and attempts >= @delivery_retry_max_attempts and
      is_integer(first_failed_at) and
      System.system_time(:millisecond) - first_failed_at >= @delivery_retry_min_elapsed_ms
  end

  # Structural, provider-neutral exemption: both providers now report a
  # disabled connect as {:connect_unavailable, :disabled}. The legacy string
  # match stays as a belt-and-braces hedge for any other producer.
  defp connect_disabled_reason?({:connect_unavailable, :disabled}), do: true

  defp connect_disabled_reason?(reason),
    do: is_binary(reason) and String.contains?(reason, "connect disabled")

  defp fail_claimed_terminal(meeting_id, claim, failure_kind, reason) do
    case Store.fail_delivery_terminal(
           meeting_id,
           claim,
           failure_kind,
           terminal_reason(reason)
         ) do
      {:ok, %{"state" => state}, _etag} -> {:terminal_failed, stringify(state || %{})}
      {:ok, _doc, _etag} -> :failed
      {:error, :fenced} -> :lost
      {:error, _} -> :failed
    end
  end

  defp terminal_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp terminal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp terminal_reason(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 500)

  # Summary text is runtime-owned and therefore untrusted. Attribution context
  # and the resolved-id snapshot are product-owned delivery checkpoints. The
  # provider may run only after both the sanitized summary and an immutable
  # complete snapshot have durably landed.
  @doc false
  def prepare_summary_for_delivery(meeting_id, state, claim) do
    state = stringify(state || %{}) |> Map.put("meeting_id", meeting_id)
    summary = OwnerAttributionSnapshot.sanitize_summary(state["summary"])
    delivery = stringify(state["delivery"] || %{})

    case OwnerAttributionSnapshot.fetch_from_delivery(delivery) do
      {:ok, snapshot} ->
        frozen_summary = OwnerAttributionSnapshot.bound_summary(snapshot, summary)

        with {:ok, persisted_state} <-
               ensure_owner_snapshot_storage(meeting_id, state, snapshot, claim) do
          persist_sanitized_summary(
            meeting_id,
            persisted_state,
            summary,
            frozen_summary,
            claim
          )
        end

      :missing ->
        with {:ok, context} <- canonical_context(state),
             {:ok, summary_result} <- generate_summary(state, summary, context, delivery, claim),
             {:ok, prepared_state, attribution_allowed?} <-
               checkpoint_summary_context(meeting_id, state, summary_result, context, claim),
             persisted_context =
               get_in(prepared_state, ["delivery", "owner_attribution_context"]) || context,
             {:ok, final_state} <-
               checkpoint_owner_attribution(
                 meeting_id,
                 prepared_state,
                 persisted_context,
                 attribution_allowed?,
                 claim
               ) do
          final_snapshot = OwnerAttributionSnapshot.current(final_state)

          {:ok, OwnerAttributionSnapshot.bound_summary(final_snapshot, final_state["summary"])}
        end

      {:error, _reason} = error ->
        error
    end
  rescue
    e ->
      Logger.warning(
        "meeting summary/owner attribution preparation crashed for #{meeting_id}: #{inspect(e)}"
      )

      {:error, {:owner_attribution_exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning(
        "meeting summary/owner attribution preparation exited for #{meeting_id}: " <>
          inspect({kind, reason})
      )

      {:error, {:owner_attribution_exit, kind, reason}}
  end

  defp persist_sanitized_summary(meeting_id, state, summary, frozen_summary, claim) do
    if state["summary"] == summary do
      {:ok, frozen_summary}
    else
      case Store.update_delivery_state(meeting_id, claim, fn live ->
             Map.update(live, "summary", summary, &OwnerAttributionSnapshot.sanitize_summary/1)
           end) do
        {:ok, %{"state" => _persisted}, _etag} ->
          {:ok, frozen_summary}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_owner_snapshot_storage(meeting_id, state, snapshot, claim) do
    delivery = stringify(state["delivery"] || %{})

    if OwnerAttributionSnapshot.rolling_storage_complete?(delivery),
      do: {:ok, state},
      else: persist_owner_snapshot(meeting_id, claim, snapshot)
  end

  defp canonical_context(state) do
    case SalixMeet.RouterSummary.cached_context(state) do
      context when is_map(context) -> normalize_context(context)
      _ -> legacy_canonical_context(state)
    end
  end

  defp legacy_canonical_context(state) do
    delivery = stringify(state["delivery"] || %{})
    stored = stringify(delivery["owner_attribution_context"] || %{})

    with true <- stored["version"] == 2,
         {:ok, context} <- normalize_context(stored),
         true <- reusable_context_source?(state, delivery, context) do
      {:ok, context}
    else
      _ -> prepare_canonical_context(state)
    end
  end

  defp reusable_context_source?(state, delivery, context) do
    marker = stringify(delivery["summary_derivation"] || %{})

    marker["version"] == @summary_derivation_version and
      marker["kind"] == @summary_derivation_kind and
      marker["input_fingerprint"] == summary_source_fingerprint(state, context)
  end

  defp prepare_canonical_context(state) do
    context =
      case SalixMeet.Ports.Summary.prepare_context(state) do
        {:ok, prepared} when is_map(prepared) -> prepared
        _ -> %{"source" => "unavailable", "transcript" => ""}
      end

    normalize_context(context)
  end

  defp normalize_context(context) do
    context = stringify(context || %{})
    transcript = if is_binary(context["transcript"]), do: context["transcript"], else: ""
    captions = text_or_empty(context["captions_transcript"])
    asr = text_or_empty(context["asr_transcript"])
    duration_seconds = positive_integer_or_zero(context["duration_seconds"])
    version = if context["version"] == 2 or captions != "" or asr != "", do: 2, else: 1

    normalized =
      %{
        "version" => version,
        "source" => trim(context["source"]) |> blank_default("unavailable"),
        "transcript" => transcript,
        "transcript_fingerprint" => OwnerAttributionSnapshot.fingerprint(transcript)
      }
      |> maybe_put_dual_source_context(version, captions, asr)
      |> put_calibration_metadata(context["calibration"])
      |> Map.put("duration_seconds", duration_seconds)
      |> put_valid_summary_fingerprint(context["summary_fingerprint"])

    {:ok, normalized}
  end

  defp maybe_put_dual_source_context(context, 2, captions, asr) do
    context
    |> Map.put("captions_transcript", captions)
    |> Map.put("captions_fingerprint", OwnerAttributionSnapshot.fingerprint(captions))
    |> Map.put("asr_transcript", asr)
    |> Map.put("asr_fingerprint", OwnerAttributionSnapshot.fingerprint(asr))
  end

  defp maybe_put_dual_source_context(context, _version, _captions, _asr), do: context

  defp put_calibration_metadata(context, metadata) when is_map(metadata) do
    metadata = stringify(metadata)
    mode = trim(metadata["mode"])

    if mode in ["direct", "chunked", "chunked_unavailable", "not_applicable"] do
      Map.put(context, "calibration", %{
        "mode" => mode,
        "complete" => metadata["complete"] == true,
        "planned_chunks" => non_negative_integer_or_zero(metadata["planned_chunks"]),
        "calibrated_chunks" => non_negative_integer_or_zero(metadata["calibrated_chunks"]),
        "fallback_chunks" => non_negative_integer_or_zero(metadata["fallback_chunks"])
      })
    else
      context
    end
  end

  defp put_calibration_metadata(context, _metadata), do: context

  defp text_or_empty(value) when is_binary(value), do: value
  defp text_or_empty(_value), do: ""

  defp positive_integer_or_zero(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_zero(_value), do: 0

  defp non_negative_integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer_or_zero(_value), do: 0

  defp generate_summary(state, runtime_summary, context, delivery, claim) do
    if SalixMeet.RouterSummary.enabled?(state) do
      with {:ok, summary} <- SalixMeet.RouterSummary.generate(state, context, claim) do
        {:ok, {:generated, summary, build_summary_derivation(state, context, summary)}}
      end
    else
      generate_legacy_summary(state, runtime_summary, context, delivery)
    end
  end

  defp generate_legacy_summary(state, runtime_summary, context, delivery) do
    if reusable_summary_derivation?(state, delivery, context, runtime_summary) do
      {:ok, {:reused, runtime_summary}}
    else
      case SalixMeet.Ports.Summary.summarize(state, context) do
        {:ok, summary} when is_map(summary) and map_size(summary) > 0 ->
          summary = OwnerAttributionSnapshot.sanitize_summary(summary)
          {:ok, {:generated, summary, build_summary_derivation(state, context, summary)}}

        _ ->
          {:ok, {:fallback, runtime_summary}}
      end
    end
  end

  defp reusable_summary_derivation?(state, delivery, context, summary) do
    expected = build_summary_derivation(state, context, summary)
    marker = stringify(delivery["summary_derivation"] || %{})

    is_map(expected) and marker == expected and
      context["summary_fingerprint"] == expected["summary_fingerprint"]
  end

  defp build_summary_derivation(state, %{"version" => 2} = context, summary)
       when is_map(summary) and map_size(summary) > 0 do
    %{
      "version" => @summary_derivation_version,
      "kind" => @summary_derivation_kind,
      "input_fingerprint" => summary_source_fingerprint(state, context),
      "canonical_fingerprint" => OwnerAttributionSnapshot.fingerprint(context["transcript"]),
      "captions_fingerprint" =>
        OwnerAttributionSnapshot.fingerprint(context["captions_transcript"]),
      "asr_fingerprint" => OwnerAttributionSnapshot.fingerprint(context["asr_transcript"]),
      "summary_fingerprint" => OwnerAttributionSnapshot.fingerprint(summary)
    }
  end

  defp build_summary_derivation(_state, _context, _summary), do: nil

  # A summary produced by this claim replaces unknown runtime output and lands
  # atomically with its v2 evidence marker. A skipped generation preserves the
  # newest sanitized runtime summary, but removes any marker that no longer has
  # a matching derivation.
  defp checkpoint_summary_context(
         _meeting_id,
         state,
         {:reused, _summary},
         _context,
         _claim
       ) do
    {:ok, state, true}
  end

  defp checkpoint_summary_context(
         meeting_id,
         state,
         {:generated, summary, derivation},
         context,
         claim
       ) do
    context = bind_context_to_summary(context, summary)
    source_fingerprint = summary_source_fingerprint(state, context)

    case Store.update_delivery_state(meeting_id, claim, fn live ->
           live = stringify(live || %{})

           if summary_source_fingerprint(live, context) == source_fingerprint do
             delivery = stringify(live["delivery"] || %{})

             delivery =
               delivery
               |> Map.put("owner_attribution_context", context)
               |> put_optional_summary_derivation(derivation)

             live
             |> put_optional_summary(summary)
             |> Map.put("delivery", delivery)
           else
             live
           end
         end) do
      {:ok, %{"state" => persisted}, _etag} ->
        persisted = stringify(persisted || %{})

        if summary_source_fingerprint(persisted, context) == source_fingerprint do
          {:ok, persisted, true}
        else
          {:error, :summary_source_changed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp checkpoint_summary_context(
         meeting_id,
         state,
         {:fallback, runtime_summary},
         context,
         claim
       ) do
    source_fingerprint = summary_source_fingerprint(state, context)

    case Store.update_delivery_state(meeting_id, claim, fn live ->
           live = stringify(live || %{})

           if summary_source_fingerprint(live, context) == source_fingerprint do
             delivery = stringify(live["delivery"] || %{})

             live_summary =
               if summary_present?(live["summary"]),
                 do: OwnerAttributionSnapshot.sanitize_summary(live["summary"]),
                 else: runtime_summary

             context = bind_context_to_summary(context, live_summary)

             live
             |> put_optional_summary(live_summary)
             |> Map.put(
               "delivery",
               delivery
               |> Map.put("owner_attribution_context", context)
               |> Map.delete("summary_derivation")
             )
           else
             live
           end
         end) do
      {:ok, %{"state" => persisted}, _etag} ->
        persisted = stringify(persisted || %{})

        if summary_source_fingerprint(persisted, context) == source_fingerprint do
          {:ok, persisted, persisted["summary"] == runtime_summary}
        else
          {:error, :summary_source_changed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp checkpoint_owner_attribution(_meeting_id, state, _context, _allowed?, _claim)
       when not is_map(state),
       do: {:error, :invalid_meeting_state}

  defp checkpoint_owner_attribution(meeting_id, state, context, attribution_allowed?, claim) do
    summary = OwnerAttributionSnapshot.sanitize_summary(state["summary"])
    delivery = stringify(state["delivery"] || %{})
    source_fingerprint = summary_source_fingerprint(state, context)

    case OwnerAttributionSnapshot.fetch_from_delivery(delivery) do
      {:ok, existing} ->
        {:ok,
         Map.put(state, "summary", OwnerAttributionSnapshot.bound_summary(existing, summary))}

      {:error, _reason} = error ->
        error

      :missing ->
        if summary_present?(summary) do
          enriched_result =
            if attribution_allowed? and context_matches_summary?(context, summary) do
              run_owner_attribution(meeting_id, state, summary, context)
            else
              if not context_matches_summary?(context, summary) do
                Logger.warning(
                  "meeting owner attribution context no longer matches live summary for #{meeting_id}"
                )
              end

              {:ok, summary}
            end

          with {:ok, enriched} <- enriched_result do
            candidate =
              OwnerAttributionSnapshot.build(summary, enriched,
                completed_at: System.system_time(:millisecond)
              )

            persist_owner_snapshot(meeting_id, claim, candidate, context, source_fingerprint)
          end
        else
          empty_snapshot =
            OwnerAttributionSnapshot.build(%{}, %{},
              completed_at: System.system_time(:millisecond)
            )

          persist_owner_snapshot(
            meeting_id,
            claim,
            empty_snapshot,
            context,
            source_fingerprint
          )
        end
    end
  end

  defp run_owner_attribution(meeting_id, state, summary, context) do
    state = Map.put(state, "meeting_id", meeting_id)

    case SalixMeet.Ports.OwnerAttribution.attribute(state, summary, context) do
      {:ok, enriched} when is_map(enriched) -> {:ok, enriched}
      :skip -> {:ok, summary}
      {:error, _reason} = error -> error
      _ -> {:ok, summary}
    end
  rescue
    e ->
      Logger.warning("meeting owner attribution step crashed for #{meeting_id}: #{inspect(e)}")
      {:error, {:owner_attribution_exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning(
        "meeting owner attribution step exited for #{meeting_id}: #{inspect({kind, reason})}"
      )

      {:error, {:owner_attribution_exit, kind, reason}}
  end

  defp persist_owner_snapshot(meeting_id, claim, candidate),
    do: persist_owner_snapshot(meeting_id, claim, candidate, nil, nil)

  defp persist_owner_snapshot(meeting_id, claim, candidate, context, source_fingerprint) do
    result =
      Store.update_delivery_state(meeting_id, claim, fn live ->
        live = stringify(live || %{})

        if summary_source_guard_matches?(live, context, source_fingerprint) do
          delivery = stringify(live["delivery"] || %{})

          {updated_delivery, persisted_summary} =
            case OwnerAttributionSnapshot.fetch_from_delivery(delivery) do
              {:ok, current} ->
                {OwnerAttributionSnapshot.put_in_delivery(delivery, current),
                 OwnerAttributionSnapshot.sanitize_summary(live["summary"])}

              :missing ->
                {OwnerAttributionSnapshot.put_in_delivery(delivery, candidate),
                 OwnerAttributionSnapshot.bound_summary(candidate, live["summary"])}

              {:error, _reason} ->
                {delivery, OwnerAttributionSnapshot.sanitize_summary(live["summary"])}
            end

          live
          |> put_optional_summary(persisted_summary)
          |> Map.put("delivery", updated_delivery)
        else
          live
        end
      end)

    case result do
      {:ok, %{"state" => persisted}, _etag} ->
        verify_persisted_snapshot_or_source_change(persisted, context, source_fingerprint)

      {:error, _} = error ->
        # A conditional write can be ambiguous. Accept it only after a live read
        # proves a complete snapshot landed; a definite failure remains fatal
        # and therefore cannot cross into Slack provider side effects.
        case Store.get(meeting_id) do
          {:ok, %{"state" => persisted}, _etag} ->
            case verify_persisted_snapshot_or_source_change(
                   persisted,
                   context,
                   source_fingerprint
                 ) do
              {:ok, _state} = ok -> ok
              _ -> error
            end

          _ ->
            error
        end
    end
  end

  defp verify_persisted_snapshot_or_source_change(persisted, context, source_fingerprint) do
    case verify_persisted_snapshot(persisted) do
      {:ok, _state} = ok ->
        ok

      error ->
        if summary_source_guard_matches?(persisted, context, source_fingerprint),
          do: error,
          else: {:error, :summary_source_changed}
    end
  end

  defp summary_source_guard_matches?(_state, nil, nil), do: true

  defp summary_source_guard_matches?(state, context, source_fingerprint)
       when is_map(context) and is_binary(source_fingerprint) do
    summary_source_fingerprint(state, context) == source_fingerprint
  end

  defp summary_source_guard_matches?(_state, _context, _source_fingerprint), do: false

  defp verify_persisted_snapshot(persisted) do
    persisted = stringify(persisted || %{})

    case OwnerAttributionSnapshot.fetch_from_delivery(persisted["delivery"]) do
      {:ok, _snapshot} -> {:ok, persisted}
      :missing -> {:error, :owner_attribution_checkpoint_missing}
      {:error, _reason} = error -> error
    end
  end

  defp put_optional_summary(state, nil), do: Map.delete(state, "summary")
  defp put_optional_summary(state, summary), do: Map.put(state, "summary", summary)

  defp put_optional_summary_derivation(delivery, nil),
    do: Map.delete(delivery, "summary_derivation")

  defp put_optional_summary_derivation(delivery, derivation),
    do: Map.put(delivery, "summary_derivation", derivation)

  defp summary_source_fingerprint(state, context) do
    state = stringify(state || %{})
    artifacts = stringify(state["artifacts"] || %{})

    OwnerAttributionSnapshot.fingerprint(%{
      "title" => trim(state["title"]),
      "meeting_agent_id" => trim(state["meeting_agent_id"]),
      "captions" => List.wrap(state["captions"]),
      "chats" => List.wrap(state["chats"]),
      "artifacts" => Map.take(artifacts, ~w(audio transcript)),
      "joined_at" => state["joined_at"],
      "left_at" => state["left_at"],
      "duration_seconds" => positive_integer_or_zero(context["duration_seconds"])
    })
  end

  defp bind_context_to_summary(context, summary) when is_map(summary) do
    Map.put(context, "summary_fingerprint", OwnerAttributionSnapshot.fingerprint(summary))
  end

  defp bind_context_to_summary(context, _summary), do: context

  defp context_matches_summary?(context, summary) when is_map(context) and is_map(summary) do
    context["summary_fingerprint"] == OwnerAttributionSnapshot.fingerprint(summary)
  end

  defp context_matches_summary?(_context, _summary), do: false

  defp put_valid_summary_fingerprint(context, "sha256:" <> digest = fingerprint)
       when byte_size(digest) == 64,
       do: Map.put(context, "summary_fingerprint", fingerprint)

  defp put_valid_summary_fingerprint(context, _fingerprint), do: context

  defp start_status_refresher(meeting_id, state, claim) do
    spawn_link(fn -> wait_for_status_refresh(meeting_id, state, claim, @status_refresh_ms) end)
  end

  defp start_claim_refresher(meeting_id, claim) do
    spawn_link(fn ->
      wait_for_claim_refresh(meeting_id, claim, claim_refresh_ms())
    end)
  end

  defp stop_refresher(pid) when is_pid(pid), do: send(pid, :stop)

  defp status_refresh_loop(meeting_id, state, claim) do
    case set_generating_status(meeting_id, state, claim) do
      {:error, :fenced} ->
        :ok

      _ ->
        wait_for_status_refresh(meeting_id, state, claim, @status_refresh_ms)
    end
  end

  defp wait_for_status_refresh(meeting_id, state, claim, delay) do
    receive do
      :stop -> :ok
    after
      delay -> status_refresh_loop(meeting_id, state, claim)
    end
  end

  defp claim_refresh_loop(meeting_id, claim) do
    case Store.heartbeat_delivery(meeting_id, claim) do
      {:ok, _doc, _etag} ->
        wait_for_claim_refresh(meeting_id, claim, claim_refresh_ms())

      {:error, :fenced} ->
        :ok

      {:error, reason} ->
        Logger.warning("meeting delivery heartbeat failed for #{meeting_id}: #{inspect(reason)}")
        wait_for_claim_refresh(meeting_id, claim, claim_refresh_retry_ms())
    end
  rescue
    e ->
      Logger.warning("meeting delivery heartbeat crashed for #{meeting_id}: #{inspect(e)}")
      wait_for_claim_refresh(meeting_id, claim, claim_refresh_retry_ms())
  catch
    kind, reason ->
      Logger.warning(
        "meeting delivery heartbeat exited for #{meeting_id}: #{inspect({kind, reason})}"
      )

      wait_for_claim_refresh(meeting_id, claim, claim_refresh_retry_ms())
  end

  defp wait_for_claim_refresh(meeting_id, claim, delay) do
    receive do
      :stop -> :ok
    after
      delay -> claim_refresh_loop(meeting_id, claim)
    end
  end

  defp claim_refresh_ms do
    positive_refresh_ms(:delivery_claim_refresh_ms, @status_refresh_ms)
  end

  defp claim_refresh_retry_ms do
    positive_refresh_ms(:delivery_claim_refresh_retry_ms, @status_refresh_retry_ms)
  end

  defp positive_refresh_ms(key, fallback) do
    case Application.get_env(:salix_meet, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _ -> fallback
    end
  end

  defp set_generating_status(meeting_id, state, claim) do
    with {:ok, meeting_agent} <-
           Runtime.status_for_group(state["tenant_id"], state["group_id"]) do
      Runtime.publish(meeting_agent, %{
        "provider" => state["provider"],
        "kind" => "summary_generating",
        "meeting_id" => meeting_id,
        "delivery_claim" => claim
      })
    end
  rescue
    e ->
      Logger.warning("meeting generating-status refresh crashed for #{meeting_id}: #{inspect(e)}")
      :skip
  catch
    kind, reason ->
      Logger.warning(
        "meeting generating-status refresh exited for #{meeting_id}: #{inspect({kind, reason})}"
      )

      :skip
  end

  defp project_memory(_state, summary) when not is_map(summary), do: :skip

  defp project_memory(state, summary) do
    SalixMeet.Ports.Memory.project(Map.put(state, "summary", summary))
  rescue
    e ->
      Logger.warning("meeting memory project crashed: #{inspect(e)}")
      :skip
  end

  defp deliver_activation(meeting_id, node, opts) do
    claim_opts = Keyword.take(opts, [:now, :reclaim_after_ms])

    case Store.claim_activation(meeting_id, node, claim_opts) do
      {:ok, %{"state" => state}, _etag, claim} ->
        activate_claimed(meeting_id, stringify(state || %{}), claim)

      {:ok, _doc, _etag, claim} ->
        fail_activation(meeting_id, claim, :invalid_meeting_state)

      {:error, :not_claimable} ->
        :not_claimable

      {:error, :lost} ->
        :lost

      {:error, reason} ->
        Logger.warning(
          "meeting router activation claim failed for #{meeting_id}: #{inspect(reason)}"
        )

        :activation_failed
    end
  end

  defp activate_claimed(meeting_id, state, claim) do
    state = Map.put(state, "meeting_id", meeting_id)
    summary = state["summary"]

    case safe_activation_handoff(state, summary) do
      :ok ->
        complete_activation(meeting_id, claim, :queued, :activated)

      :skip ->
        complete_activation(meeting_id, claim, :skipped, :activation_skipped)

      {:error, :meeting_activation_capability_expired} ->
        complete_activation(meeting_id, claim, :skipped, :activation_skipped)

      {:error, reason} ->
        fail_activation(meeting_id, claim, reason)
    end
  end

  defp safe_activation_handoff(state, summary) do
    case SalixMeet.Ports.Activation.handoff(state, summary) do
      result when result in [:ok, :skip] -> result
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_activation_result, other}}
    end
  rescue
    e ->
      Logger.warning("meeting router activation crashed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning("meeting router activation exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  defp complete_activation(meeting_id, claim, status, outcome) do
    case Store.complete_activation(meeting_id, claim, status) do
      {:ok, _doc, _etag} ->
        outcome

      {:error, :fenced} ->
        :lost

      {:error, reason} ->
        Logger.warning(
          "meeting router activation completion failed for #{meeting_id}: #{inspect(reason)}"
        )

        :activation_failed
    end
  end

  defp fail_activation(meeting_id, claim, reason) do
    case Store.fail_activation_retrying(meeting_id, claim, inspect(reason)) do
      {:ok, _doc, _etag} ->
        :activation_failed

      {:error, :fenced} ->
        :lost

      {:error, checkpoint_reason} ->
        Logger.warning(
          "meeting router activation failure checkpoint failed for #{meeting_id}: " <>
            inspect(checkpoint_reason)
        )

        :activation_failed
    end
  end

  defp summary_present?(summary) when is_map(summary), do: map_size(summary) > 0
  defp summary_present?(_), do: false

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)

  defp trim(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  defp trim(_), do: ""

  def terminal_statuses, do: RuntimeEvents.terminal_statuses()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
