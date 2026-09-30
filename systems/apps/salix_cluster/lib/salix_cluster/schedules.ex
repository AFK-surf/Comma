defmodule SalixCluster.Schedules do
  @moduledoc """
  Recurring schedules: definitions in the Postgres `schedules` table and
  **insert-once run claims** in `schedule_runs`
  (docs/storage-search.md). The composite primary key
  `(schedule_id, scheduled_for_ms)` IS the firing claim —
  `INSERT ... ON CONFLICT DO NOTHING` — so `UNIQUE(schedule_id, scheduled_for)`
  holds by construction, exactly as the retired create-once S3 run objects did.
  Concurrent sweepers on different nodes race harmlessly — exactly one wins the
  claim's durable `dispatch` or `skipped_stale` disposition, and every loser
  reads and follows that decision.

  ## Definition shape (string-keyed record)

      {
        "id": "...",
        "interval_minutes": 5, # or cron + timezone, or one-shot run_at
        "receiver": "agent" | "task" | "triage_follow_up" | "meeting_publication" | "comma_recommendation",
        "payload": {...},
        "created_at": unix_ms,
        "last_run": unix_ms | null
      }

  A schedule is exactly one of **interval**, **cron** (fixed-time), or a
  one-shot **run_at** unix millisecond timestamp. Interval next-fire
  is deterministic and simple: `(last_run || created_at) + interval_minutes *
  60_000`. Cron next-fire is the first occurrence strictly after the anchor,
  computed in `timezone` (see `SalixCluster.Cron`). Either way a pass fires at
  most one run per schedule and `last_run` advances monotonically, moving the
  anchor.

  The recurrence math stays here; `SalixStore.Schedules` persists a
  `next_fire_at` **lower bound** that indexes the due scan. `due/1` selects
  candidates through that index, re-derives the exact next fire, and heals a
  stale bound — the sweep never lists or hydrates the full definition set. An
  explicitly `"paused"` definition is excluded by the scan, so pause gates
  firing (it never did in the S3 scanner). Archiving an agent pauses its
  agent-receiver definitions through the same status (`paused_by: "archive"`,
  `SalixAgent.AgentControl.delete/1`) and unarchiving resumes exactly those,
  so "an archived agent's schedules do not fire" is a lifecycle invariant,
  not a per-sweep discovery.

  Interval schedules backfill missed windows one per pass. Cron schedules
  instead **skip-stale**: when the due occurrence is older than `@stale_grace_ms`
  the anchor jumps past it without delivering, so only the next future
  occurrence fires (no replay of yesterday's fixed-time run after an outage).

  ## Firing pipeline (`fire/3`)

  1. Claim: insert-once run row. Conflict ⇒ another node won.
  2. Dispatch the stored payload to the definition's receiver. Receivers must be
     idempotent for `(schedule_id, scheduled_for_ms)`.
  3. Advance: monotonic `last_run = scheduled_for_ms` into the definition.

  ## Singleton usage

  `run_once/1` is the testable unit: one sweep of due schedules. In production
  the periodic tick is gated behind the `:schedules` S3 singleton lease exactly
  like `SalixCluster.Recovery`: `acquire_or_renew` on every tick, sweep only
  while holding, fail closed when a renewal is lost. The optional GenServer
  below implements that pattern; correctness never depends on it being a true
  singleton (the run claim is the safety mechanism), the lease only avoids
  wasted duplicate sweeps. The lease holder also retention-prunes old run
  claims (`@runs_retention_days`) — the audit trail the S3 prefix accumulated
  forever.

  Agent and Task definitions live in the same table and are swept together.
  Their only execution difference is the receiver and payload.

  The insert-once disposition, receiver ACK, crash recovery, and monotonic
  advance protocol is modeled in `tla/salix/ScheduleDispatch.tla`.
  """

  use GenServer
  require Logger

  alias SalixStore.{Ids, ScheduleRuns}
  alias SalixCluster.{S3Lease, Cron}

  @interval_ms 30_000
  @store SalixStore.Schedules

  # RESOLVED run claims older than this are audit trail and are pruned by the
  # lease holder. An unresolved dispatch claim (blocked target, anchor held) is
  # load-bearing regardless of age and survives retention — see
  # `ScheduleRuns.prune_older_than/1`.
  @runs_retention_days 30
  @runs_prune_every_ms :timer.hours(1)

  # Cron fixed-time schedules whose next due occurrence is older than this are
  # "stale": the anchor is advanced past the missed windows without delivering,
  # so only the next future occurrence fires (no backfill after an outage).
  # Overridable per-call via `opts[:stale_grace_ms]` (clock injection in tests).
  @stale_grace_ms :timer.minutes(10)

  # Far-future offset for an unsatisfiable/invalid cron spec, so `due/1` never
  # selects it and the sweep never raises. Validation rejects these at create
  # time; this only guards drift.
  @century_ms 100 * 365 * 24 * 60 * 60 * 1000

  @type schedule :: %{optional(String.t()) => term()}
  @receivers %{
    "agent" => __MODULE__,
    "task" => SalixCluster.TaskSchedules,
    # `tla/salix/TriageFollowUpSchedule.tla` composes this shared one-shot
    # ACK/delete boundary with Triage's context-authority settlement.
    "triage_follow_up" => SalixIM.Triage.FollowUpReceiver,
    # The deterministic meeting base card (RFC PR6): the sweeper process
    # direct-posts through the idempotent participant outbox — no LLM turn.
    "meeting_publication" => Salix.Bindings.MeetingPublicationReceiver,
    "comma_mail" => Salix.Bindings.CommaMailReceiver,
    "comma_recommendation" => Salix.Bindings.CommaRecommendationReceiver
  }

  # ---- definition CRUD ----

  @doc """
  Create one Agent or Task receiver definition. Legacy Agent callers may omit
  `receiver`; they are normalized to the Agent receiver.
  """
  @spec create(String.t(), map(), keyword()) ::
          {:ok, schedule()}
          | {:error, :already_exists}
          | {:error, :invalid_schedule}
          | {:error, term()}
  def create(id, params, opts \\ []) do
    now = opts[:now] || System.system_time(:millisecond)
    params = stringify(params)

    with true <- Ids.valid_schedule_id?(id),
         :ok <- validate(params) do
      sched =
        params
        |> Map.take([
          "agent_id",
          "session_id",
          "interval_minutes",
          "cron",
          "timezone",
          "run_at",
          "status",
          "prompt",
          "receiver",
          "payload",
          # Who this schedule acts for, and what its prompt was written from.
          # Recorded once, at creation, because a fire has no one to ask
          # (docs/verification.md).
          "ifc_creator",
          "ifc_label",
          "meeting_preparation"
        ])
        |> Map.put_new("receiver", "agent")
        |> Map.merge(%{"id" => id, "created_at" => now, "last_run" => nil})

      case @store.create(sched, next_fire_ms(sched)) do
        {:ok, record} -> {:ok, record}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :invalid_schedule}
      {:error, _} = error -> error
    end
  end

  @doc false
  def validate_definition(params) when is_map(params), do: validate(stringify(params))

  @doc false
  def validate_definition_update(schedule, changes)
      when is_map(schedule) and is_map(changes),
      do: schedule |> merge_changes(stringify(changes)) |> validate()

  @doc "Fetch a schedule definition."
  @spec get(String.t()) :: {:ok, schedule()} | {:error, :not_found} | {:error, term()}
  def get(id), do: @store.get(id)

  @doc """
  Merge `changes` into the definition under a serialized row update.
  `"id"` cannot be changed.
  """
  @spec update(String.t(), map()) ::
          {:ok, schedule()} | {:error, :not_found} | {:error, term()}
  def update(id, changes) do
    changes = stringify(changes)

    @store.update(id, fn current ->
      merged = merge_changes(current, changes)

      case validate(merged) do
        :ok -> {:ok, merged, next_fire_ms(merged)}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Delete a schedule definition (idempotent). Unscoped — callers that have an
  owner must use `delete_agent_owned/2` or `delete_task_owned/2`.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id), do: @store.delete(id)

  @doc "Point read scoped to an Agent owner (never a Task row)."
  @spec get_agent_owned(String.t(), String.t()) ::
          {:ok, schedule()} | {:error, :not_found} | {:error, term()}
  def get_agent_owned(id, agent_id), do: @store.get_agent_owned(id, agent_id)

  @doc "Atomic delete scoped to an Agent owner (never a Task row)."
  @spec delete_agent_owned(String.t(), String.t()) ::
          :ok | {:error, :not_found} | {:error, term()}
  def delete_agent_owned(id, agent_id), do: @store.delete_agent_owned(id, agent_id)

  @doc "Atomic delete scoped to a Task's group owner."
  @spec delete_task_owned(String.t(), String.t()) ::
          :ok | {:error, :not_found} | {:error, term()}
  def delete_task_owned(id, group_id), do: @store.delete_task_owned(id, group_id)

  @doc """
  List all schedule definitions. Admin/audit surface only — request paths
  (agent tools, BFT dashboards) must use the owner-filtered `list_by_agents/1`.
  """
  @spec list() :: {:ok, [schedule()]} | {:error, term()}
  def list, do: @store.list()

  @doc "Owner-filtered listing: definitions owned by any of `agent_ids`."
  @spec list_by_agents([String.t()]) :: {:ok, [schedule()]} | {:error, term()}
  def list_by_agents(agent_ids) when is_list(agent_ids), do: @store.list_by_agents(agent_ids)

  @doc """
  Owner-filtered listing across both receiver shapes: agent-owned definitions
  plus Task definitions bound to `group_id`.
  """
  @spec list_for_owners([String.t()], String.t() | nil) :: {:ok, [schedule()]} | {:error, term()}
  def list_for_owners(agent_ids, group_id) when is_list(agent_ids),
    do: @store.list_for_owners(agent_ids, group_id)

  # ---- due math ----

  @doc """
  Next fire time for a schedule, as unix ms.

  Interval schedules: deterministic `(last_run || created_at) + interval_minutes
  * 60_000`. Cron schedules: the first occurrence **strictly after** the anchor
  `(last_run || created_at)`, computed in the schedule's `timezone` (default
  `"UTC"`). Strictly-after is required — an at-or-after occurrence equal to
  `last_run` would recompute to itself and wedge the schedule.
  """
  @spec next_fire_ms(schedule()) :: integer()
  def next_fire_ms(%{"interval_minutes" => mins} = sched) when is_integer(mins) do
    (sched["last_run"] || sched["created_at"]) + mins * 60_000
  end

  def next_fire_ms(%{"run_at" => run_at}) when is_integer(run_at), do: run_at

  def next_fire_ms(%{"cron" => expr} = sched) do
    anchor = sched["last_run"] || sched["created_at"]

    case Cron.next_after_ms(expr, anchor, sched["timezone"] || "UTC") do
      {:ok, ms} -> ms
      {:error, _} -> anchor + @century_ms
    end
  end

  @doc """
  Schedules whose next fire time is ≤ `now_ms`.

  Selects candidates through the `next_fire_at` lower-bound index (never the
  full definition set), then re-derives the exact next fire here — the index
  column may be stale-early (e.g. the cutover imported anchors). A candidate
  that is not actually due gets its bound healed so it stops surfacing.
  """
  @spec due(integer()) :: {:ok, [schedule()]} | {:error, term()}
  def due(now_ms) do
    with {:ok, candidates} <- @store.due_candidates(now_ms) do
      {due, stale_bounds} = Enum.split_with(candidates, &(next_fire_ms(&1) <= now_ms))

      Enum.each(stale_bounds, fn sched ->
        @store.recompute_next_fire(sched["id"], &next_fire_ms/1)
      end)

      {:ok, due}
    end
  end

  # ---- firing ----

  @doc """
  Claim one window, dispatch to the stored receiver, then advance `last_run`.
  An existing claim is re-dispatched through the receiver's idempotent target
  path before advancing, so a crash between delivery and advance can recover.
  """
  @spec fire(schedule(), integer(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def fire(%{"id" => id} = schedule, scheduled_for_ms, opts \\ []) do
    with {:ok, receiver} <- receiver_module(schedule) do
      claim =
        schedule
        |> claim_attributes()
        |> Map.put("disposition", "dispatch")
        |> Map.put("fired_at", opts[:now] || System.system_time(:millisecond))

      claim_result = claim_window(id, scheduled_for_ms, claim)

      case claim_result do
        :claimed ->
          dispatch_and_advance(
            schedule,
            receiver,
            :claimed,
            scheduled_for_ms,
            opts,
            frozen_target(claim["session_id"])
          )

        :exists ->
          resume_claim(schedule, receiver, scheduled_for_ms, opts)

        {:error, reason} = error ->
          emit_schedule_diagnostic(schedule, scheduled_for_ms, "failed", "claim", reason, opts)
          error
      end
    end
  end

  @doc """
  Re-dispatch one exact, already-claimed window without creating a new claim.

  This is the bounded repair path for a legacy scheduler that advanced
  `last_run` after the receiver failed. Receiver idempotency prevents duplicate
  effects, and the monotonic advance fence never moves the schedule anchor
  backward.
  """
  @spec recover_claim(String.t(), integer(), keyword()) :: {:ok, atom()} | {:error, term()}
  def recover_claim(schedule_id, scheduled_for_ms, opts \\ [])
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) do
    with {:ok, schedule} <- get(schedule_id) do
      case ScheduleRuns.claim_state(schedule_id, scheduled_for_ms) do
        {:ok, %{disposition: :dispatch, target: target}} ->
          with {:ok, receiver} <- receiver_module(schedule) do
            dispatch_and_advance(schedule, receiver, :exists, scheduled_for_ms, opts, target)
          end

        {:ok, %{disposition: :skipped_stale}} ->
          {:error, :claim_not_dispatch}

        # Terminal decision already durable: nothing to re-dispatch.
        {:ok, %{disposition: :undeliverable}} ->
          {:error, :claim_not_dispatch}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Sweep the single Schedule table once. Agent and Task definitions differ only
  by receiver and payload.
  """
  @spec run_once(keyword()) ::
          {:ok,
           %{
             fired: [String.t()],
             already_fired: [String.t()],
             pending: [String.t()],
             skipped: [String.t()],
             settled: [String.t()],
             blocked: [String.t()],
             undeliverable: [String.t()],
             inactive: [String.t()],
             failed: [{String.t(), term()}]
           }}
          | {:error, term()}
  def run_once(opts \\ []) do
    started = System.monotonic_time()
    now = opts[:now] || System.system_time(:millisecond)
    grace = opts[:stale_grace_ms] || @stale_grace_ms

    result =
      with {:ok, schedules} <- due(now) do
        results =
          Enum.map(schedules, fn schedule ->
            scheduled_for = next_fire_ms(schedule)

            result =
              if stale?(schedule, scheduled_for, now, grace),
                do: resume_claim_or_skip(schedule, scheduled_for, now, opts),
                else: fire(schedule, scheduled_for, opts)

            {schedule["id"], result}
          end)

        {:ok,
         %{
           fired: for({id, {:ok, :fired}} <- results, do: id),
           already_fired: for({id, {:ok, :already_fired}} <- results, do: id),
           pending: for({id, {:ok, :pending}} <- results, do: id),
           skipped: for({id, {:ok, :skipped}} <- results, do: id),
           settled: for({id, {:ok, :settled}} <- results, do: id),
           blocked: for({id, {:ok, :blocked}} <- results, do: id),
           undeliverable: for({id, {:ok, :undeliverable}} <- results, do: id),
           inactive: for({id, {:ok, :inactive}} <- results, do: id),
           failed: for({id, {:error, reason}} <- results, do: {id, reason})
         }}
      end

    emit_schedule_operation(result, started)
    result
  end

  defp emit_schedule_operation(result, started) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_cluster",
        operation: "schedule",
        surface: "system",
        outcome: schedule_outcome(result)
      }
    )
  end

  defp schedule_outcome({:ok, %{failed: []}}), do: "ok"
  defp schedule_outcome(_result), do: "error"

  @doc false
  def receive(payload, status, opts) when status in [:claimed, :exists] do
    payload
    |> apply_claimed_target(Keyword.get(opts, :claimed_target, :legacy_snapshot))
    |> deliver_schedule_payload(opts)
    |> classify_delivery_result()
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}

  # The occurrence authority (#871 round-3 escalation, owner 2026-08-15):
  # the claim froze the delivery target at insert-once time, and every
  # dispatcher uses THAT — a stale sweeper cannot redirect the occurrence
  # to a retargeted definition, and the undeliverable classification is a
  # pure function of the frozen target and the role, computed identically
  # by every sweeper at any time. :legacy_snapshot (a pre-migration claim
  # with no frozen target) keeps the old snapshot-driven dispatch.
  defp apply_claimed_target(payload, {:session, session_id}),
    do: Map.put(payload, "session_id", session_id)

  defp apply_claimed_target(payload, :sessionless), do: Map.put(payload, "session_id", nil)
  defp apply_claimed_target(payload, :legacy_snapshot), do: payload

  defp deliver_schedule_payload(payload, opts) do
    id = Keyword.fetch!(opts, :schedule_id)
    scheduled_for_ms = Keyword.fetch!(opts, :scheduled_for)
    source = "schedule:#{id}:#{scheduled_for_ms}"

    inbox_payload =
      %{
        content: payload["prompt"],
        session_id: payload["session_id"],
        kind: "schedule",
        role: "user",
        source_sent_at_ms: scheduled_for_ms,
        source_timezone: payload["timezone"]
      }
      |> put_ifc_origin(id, payload)
      |> put_meeting_origin(id, payload, scheduled_for_ms)

    delivery_opts =
      [source_message_id: source]
      |> Keyword.put(:create, false)
      |> Keyword.put(:session_check, :staging)
      |> Keyword.put(:surface, "schedule")

    SalixAgent.deliver(payload["agent_id"], inbox_payload, delivery_opts)
  end

  # A fire acts with its creator's authority
  # (`docs/verification.md` §8). The principal is
  # `{:schedule, id, creator}`, which the kernel keys by the creator — so every
  # effect this fire causes is decided against the creator's *current*
  # membership, not against whatever was true when the schedule was made. The
  # schedule id is carried alongside so a decision, and its archive row, can
  # say which schedule acted.
  #
  # Sealed on the delivery, next to the label the prompt was written under, so
  # the model can neither supply it nor change it — the same seal an inbound
  # provider message gets. A schedule made before this existed, or while its
  # Group was `off`, carries nothing and authorizes nothing, which is the
  # fail-closed reading.
  defp put_ifc_origin(inbox_payload, id, payload) do
    case SalixAgent.IFC.schedule_origin(id, payload["ifc_creator"], payload["ifc_label"]) do
      nil -> inbox_payload
      origin -> Map.put(inbox_payload, :trusted_origin, origin)
    end
  end

  defp put_meeting_origin(inbox_payload, id, payload, scheduled_for_ms) do
    module = Application.get_env(:salix_agent, :meeting_preparation_mod)

    if is_map(payload["meeting_preparation"]) and module do
      case module.seal_schedule(id, payload, scheduled_for_ms) do
        {:ok, content, origin} ->
          inbox_payload |> Map.put(:content, content) |> Map.put(:trusted_origin, origin)

        :none ->
          inbox_payload
      end
    else
      inbox_payload
    end
  end

  defp classify_delivery_result(result) do
    case result do
      {:ok, _status} ->
        {:ok, :fired}

      # Blocked, not failed and never deleted: archive is reversible
      # (AgentControl.unarchive/2), so the definition and the claimed window
      # are preserved with the anchor unmoved. Every sweep re-attempts this
      # same occurrence; after unarchive the claim's :exists path delivers the
      # stable-id occurrence exactly once and only then advances
      # (ScheduleDispatch.tla's receiver-ACK-before-advance).
      #
      # Since #849 this is the BACKSTOP, not the steady state: archive pauses
      # the agent's definitions (they leave the due scan) and unarchive
      # resumes them. A blocked fire only happens in the gap between the
      # archive record (S3) and the pause (Postgres), or for an agent
      # archived before the pause existed and not yet swept
      # (`SalixAgent.ArchivedScheduleSweep`).
      {:error, :not_found} ->
        {:ok, :blocked, :target_missing}

      {:error, {:bad_request, "agent is archived"}} ->
        {:ok, :blocked, :archived}

      # A frozen-session-less occurrence whose target role cannot resolve a
      # session (#871 — only routers resolve one at stage time): a pure
      # function of the CLAIM's frozen target and the role, so every
      # sweeper computes the same terminal answer at any time. Advance with
      # a visible diagnostic; blocking would re-attempt forever, and the
      # staged path reached the same loss silently.
      {:error, :missing_session_id} ->
        {:ok, :undeliverable, :missing_session_id}

      {:error, _reason} = error ->
        error

      other ->
        {:error, other}
    end
  end

  defp dispatch_and_advance(schedule, receiver, claim_status, scheduled_for_ms, opts, target) do
    receiver_opts =
      opts
      |> Keyword.put(:schedule_id, schedule["id"])
      |> Keyword.put(:scheduled_for, scheduled_for_ms)
      |> Keyword.put(:claimed_target, target)

    result = apply(receiver, :receive, [receiver_payload(schedule), claim_status, receiver_opts])

    case result do
      # A bounded receiver batch left durable work. Keep this same claim and
      # definition for the next sweep. This is not a terminal receiver ACK.
      {:ok, :continue} ->
        {:ok, :pending}

      # Delivery target is blocked (archived / control record missing): keep
      # the definition, the claim, and the anchor untouched so the SAME
      # occurrence is re-attempted next sweep and delivers after unarchive.
      {:ok, :blocked, reason} ->
        emit_schedule_diagnostic(schedule, scheduled_for_ms, "blocked", "receiver", reason, opts)
        {:ok, :blocked}

      # Permanently undeliverable occurrence (definition defect): first make
      # the truthful outcome DURABLE on the run claim, then advance, then —
      # strictly after the durable settle — emit the diagnostic. The order
      # is load-bearing twice over: AdvanceRequiresDurableOutcome
      # (ScheduleDispatch.tla) forbids advancing past a claim whose durable
      # disposition still reads "dispatch", and a diagnostic sink must
      # never gate the sweep. A failure of either write leaves the claim
      # open; the next sweep resumes it and converges.
      {:ok, :undeliverable, reason} ->
        with :ok <- ScheduleRuns.resolve_undeliverable(schedule["id"], scheduled_for_ms),
             :ok <- advance(schedule, scheduled_for_ms, opts) do
          emit_schedule_diagnostic(
            schedule,
            scheduled_for_ms,
            "undeliverable",
            "receiver",
            reason,
            opts
          )

          {:ok, :undeliverable}
        end

      {:ok, receiver_status} ->
        with :ok <- advance(schedule, scheduled_for_ms, opts) do
          if claim_status == :exists,
            do: {:ok, :already_fired},
            else: {:ok, receiver_status}
        end

      {:error, reason} = error ->
        emit_schedule_diagnostic(schedule, scheduled_for_ms, "failed", "receiver", reason, opts)
        error
    end
  end

  defp advance(%{"id" => id, "run_at" => _run_at}, _scheduled_for_ms, _opts) do
    delete(id)
  end

  defp advance(schedule, scheduled_for_ms, opts) do
    case advance_last_run(schedule, scheduled_for_ms) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} = error ->
        emit_schedule_diagnostic(schedule, scheduled_for_ms, "failed", "advance", reason, opts)
        error
    end
  end

  # Monotonic anchor advance. The recurrence math is passed as a derivation
  # closure and evaluated by the store against the CURRENT locked row (with
  # the advanced anchor applied) — never against this sweep's snapshot — so a
  # dispatch that resumes after a concurrent recurrence update cannot raise
  # the bound past the true next occurrence. `:unchanged` means a racing
  # sweeper already advanced past this window — converged, not an error.
  defp advance_last_run(%{"id" => id}, scheduled_for_ms) do
    case @store.advance(id, scheduled_for_ms, &next_fire_ms/1) do
      :ok -> :ok
      :unchanged -> :ok
      {:error, _} = error -> error
    end
  end

  defp receiver_module(schedule) do
    case Map.fetch(@receivers, schedule["receiver"] || "agent") do
      {:ok, receiver} -> {:ok, receiver}
      :error -> {:error, :unknown_schedule_receiver}
    end
  end

  defp receiver_payload(%{"receiver" => "task", "payload" => payload}), do: payload
  defp receiver_payload(schedule), do: schedule["payload"] || schedule

  defp claim_attributes(schedule) do
    %{"receiver" => schedule["receiver"] || "agent"}
    |> put_claim_target(schedule)
  end

  defp put_claim_target(claim, %{"receiver" => "task", "payload" => payload}) do
    claim
    |> Map.put("agent_group_id", payload["agent_group_id"])
    |> Map.put("conversation_id", payload["conversation_id"])
  end

  defp put_claim_target(claim, %{"receiver" => "triage_follow_up"}), do: claim
  defp put_claim_target(claim, %{"receiver" => "meeting_publication"}), do: claim
  defp put_claim_target(claim, %{"receiver" => "comma_recommendation"}), do: claim

  defp put_claim_target(claim, schedule) do
    claim
    |> Map.put("agent_id", schedule["agent_id"])
    # Freeze the occurrence's delivery target at insert-once time (#871
    # occurrence authority): "" is the explicit claimed-session-less
    # sentinel. Definition retargets/deletions affect only FUTURE windows.
    |> Map.put("session_id", nonblank(schedule["session_id"]) || "")
  end

  @doc false
  def claim_window(schedule_id, scheduled_for_ms, attrs)
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) and is_map(attrs) do
    claim =
      attrs
      |> stringify()
      |> Map.put_new("node", to_string(node()))

    ScheduleRuns.claim(schedule_id, scheduled_for_ms, claim)
  end

  # Only cron schedules are skip-stale'd; interval schedules keep their existing
  # backfill contract. A cron target older than `now - grace` is a missed window.
  defp stale?(%{"cron" => _}, target, now, grace), do: target < now - grace
  defp stale?(_sched, _target, _now, _grace), do: false

  defp resume_claim_or_skip(schedule, scheduled_for_ms, now, opts) do
    claim =
      schedule
      |> claim_attributes()
      |> Map.put("disposition", "skipped_stale")
      |> Map.put("fired_at", now)

    case claim_window(schedule["id"], scheduled_for_ms, claim) do
      :claimed ->
        skip_stale(schedule, now)

      :exists ->
        with {:ok, receiver} <- receiver_module(schedule) do
          resume_claim(schedule, receiver, scheduled_for_ms, Keyword.put(opts, :now, now))
        end

      {:error, reason} = error ->
        emit_schedule_diagnostic(schedule, scheduled_for_ms, "failed", "claim", reason, opts)
        error
    end
  end

  defp resume_claim(schedule, receiver, scheduled_for_ms, opts) do
    case ScheduleRuns.claim_state(schedule["id"], scheduled_for_ms) do
      # Every loser/resumer dispatches to the CLAIM's frozen target — never
      # its own definition snapshot (occurrence authority, #871).
      {:ok, %{disposition: :dispatch, target: target}} ->
        dispatch_and_advance(schedule, receiver, :exists, scheduled_for_ms, opts, target)

      {:ok, %{disposition: :skipped_stale}} ->
        skip_stale(schedule, opts[:now] || System.system_time(:millisecond))

      # Follow the durable terminal decision: never re-dispatch, advance if
      # the anchor has not caught up (a crash between resolve and advance
      # recovers here — the monotonic advance is a no-op once caught up).
      {:ok, %{disposition: :undeliverable}} ->
        with :ok <- advance(schedule, scheduled_for_ms, opts) do
          {:ok, :undeliverable}
        end

      {:error, reason} = error ->
        emit_schedule_diagnostic(schedule, scheduled_for_ms, "failed", "claim_read", reason, opts)
        error
    end
  end

  defp frozen_target(nil), do: :sessionless
  defp frozen_target(""), do: :sessionless
  defp frozen_target(session_id) when is_binary(session_id), do: {:session, session_id}

  # Follow a durable skipped-stale claim by advancing the anchor to the latest
  # past occurrence at or before `now` without delivering. Racing sweepers
  # converge through the monotonic `last_run` CAS.
  defp skip_stale(%{"cron" => expr} = sched, now) do
    case Cron.latest_at_or_before_ms(expr, now, sched["timezone"] || "UTC") do
      {:ok, latest} ->
        case advance_last_run(sched, latest) do
          :ok ->
            emit_schedule_diagnostic(
              sched,
              latest,
              "skipped",
              "stale_window",
              :stale_window,
              now: now
            )

            {:ok, :skipped}

          # Deleted concurrently — nothing to advance, treat as a no-op skip.
          {:error, :not_found} ->
            {:ok, :skipped}

          {:error, reason} = err ->
            emit_schedule_diagnostic(sched, latest, "failed", "advance", reason, now: now)
            err
        end

      {:error, _} = err ->
        emit_schedule_diagnostic(sched, now, "failed", "stale_window", elem(err, 1), now: now)
        err
    end
  end

  # ---- internal: CRUD plumbing ----

  defp merge_changes(schedule, changes) do
    # Whose authority a schedule fires with is fixed when it is created and is
    # never editable afterwards: an update that could rewrite it would be a way
    # to retarget someone else's schedule onto your own permissions, or your
    # own onto theirs (docs/verification.md).
    changes =
      Map.drop(changes, [
        "id",
        "receiver",
        "payload",
        "ifc_creator",
        "ifc_label",
        "meeting_preparation"
      ])

    schedule =
      cond do
        Map.has_key?(changes, "interval_minutes") ->
          Map.drop(schedule, ["cron", "timezone", "run_at"])

        Map.has_key?(changes, "cron") ->
          Map.drop(schedule, ["interval_minutes", "run_at"])

        Map.has_key?(changes, "run_at") ->
          Map.drop(schedule, ["interval_minutes", "cron", "timezone"])

        true ->
          schedule
      end

    schedule
    |> Map.merge(changes)
    |> Map.put("id", schedule["id"])
    |> Map.put("receiver", schedule["receiver"] || "agent")
  end

  # ---- internal: helpers ----

  defp emit_schedule_diagnostic(sched, scheduled_for_ms, status, stage, reason, opts) do
    diagnostic =
      %{
        provider: "salix_cluster",
        domain: "schedule",
        source: "salix.schedule",
        event_type: schedule_event_type(status),
        severity: schedule_severity(status),
        status: status,
        reason_class: schedule_reason_class(reason),
        summary: schedule_summary(status, stage),
        schedule_id: sched["id"],
        agent_id: sched["agent_id"],
        agent_group_id: get_in(sched, ["payload", "agent_group_id"]),
        conversation_id: get_in(sched, ["payload", "conversation_id"]),
        session_id_configured: configured?(sched["session_id"]),
        scheduled_for_ms: scheduled_for_ms,
        scheduled_for: iso(scheduled_for_ms),
        stage: stage,
        correlation_id: diagnostic_correlation_id(opts, sched["id"], scheduled_for_ms),
        node: to_string(node()),
        observed_at_ms: opts[:now] || System.system_time(:millisecond)
      }
      |> maybe_put_diagnostic_option(:request_id, opts)
      |> maybe_put_diagnostic_option(:client_request_id, opts)
      |> maybe_put_diagnostic_option(:invocation_id, opts)

    case Application.get_env(:salix_cluster, :schedule_diagnostic_sink) do
      nil ->
        # Without a configured sink every blocked/undeliverable/failed dispatch
        # used to vanish completely. The log line is the observability floor:
        # schedule losses must never be silent. Logging is bounded, so unlike
        # an arbitrary sink it runs synchronously.
        log_schedule_diagnostic(diagnostic)

      sink when is_function(sink, 1) ->
        safe_emit_schedule_diagnostic(sink, diagnostic)

      sink when is_atom(sink) ->
        safe_emit_schedule_diagnostic(
          fn payload -> apply(sink, :record, [payload]) end,
          diagnostic
        )
    end
  end

  # Diagnostics run strictly AFTER the durable settle and in their own
  # process: a slow or stuck sink must never gate the sweep or the anchor
  # (telemetry failure must not change scheduling results). Task.start is
  # unlinked — a sink crash dies alone and is logged here — and the sink's
  # lifetime is BOUNDED so a permanently hung sink cannot accumulate one
  # stuck process per diagnostic.
  @diagnostic_sink_timeout_ms 30_000

  defp log_schedule_diagnostic(diagnostic) do
    Logger.warning(
      "schedule dispatch #{diagnostic.status} (stage=#{diagnostic.stage} " <>
        "reason=#{diagnostic.reason_class}) schedule_id=#{diagnostic.schedule_id} " <>
        "agent_id=#{diagnostic.agent_id} scheduled_for=#{diagnostic.scheduled_for}"
    )

    :ok
  end

  defp safe_emit_schedule_diagnostic(sink, diagnostic) do
    {:ok, _pid} =
      Task.start(fn ->
        inner =
          Task.async(fn ->
            try do
              sink.(diagnostic)
            rescue
              error ->
                Logger.warning("schedule diagnostic sink failed: #{Exception.message(error)}")
            catch
              kind, reason ->
                Logger.warning("schedule diagnostic sink failed: #{inspect({kind, reason})}")
            end
          end)

        Task.yield(inner, @diagnostic_sink_timeout_ms) || Task.shutdown(inner, :brutal_kill)
      end)

    :ok
  end

  defp maybe_put_diagnostic_option(diagnostic, key, opts) do
    case diagnostic_option(opts, key) do
      value when value in [nil, ""] -> diagnostic
      value -> Map.put(diagnostic, key, value)
    end
  end

  defp diagnostic_option(opts, key) when is_list(opts) and is_atom(key) do
    Keyword.get(opts, key)
  end

  defp diagnostic_option(%{} = opts, key) when is_atom(key) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp diagnostic_option(_opts, _key), do: nil

  defp diagnostic_correlation_id(opts, schedule_id, scheduled_for_ms) do
    diagnostic_option(opts, :correlation_id) ||
      diagnostic_option(opts, :request_id) ||
      diagnostic_option(opts, :client_request_id) ||
      diagnostic_option(opts, :invocation_id) ||
      "schedule:#{schedule_id}:#{scheduled_for_ms}"
  end

  defp schedule_event_type("skipped"), do: "schedule.fire.skipped"
  defp schedule_event_type("blocked"), do: "schedule.fire.blocked"
  defp schedule_event_type("undeliverable"), do: "schedule.fire.undeliverable"
  defp schedule_event_type(_status), do: "schedule.fire.failed"

  defp schedule_severity("skipped"), do: "warning"
  defp schedule_severity("blocked"), do: "warning"
  defp schedule_severity("undeliverable"), do: "warning"
  defp schedule_severity(_status), do: "error"

  defp schedule_summary("skipped", _stage), do: "Schedule fire skipped stale window"

  defp schedule_summary("blocked", _stage),
    do: "Schedule blocked: target archived or missing; will retry after restore"

  defp schedule_summary("undeliverable", _stage),
    do: "Schedule occurrence undeliverable: no session id and the target role cannot resolve one"

  defp schedule_summary(_status, stage), do: "Schedule fire failed at #{stage}"

  defp schedule_reason_class(:stale_window), do: "stale_window"
  defp schedule_reason_class(:archived), do: "archived"
  defp schedule_reason_class(:target_missing), do: "target_missing"
  defp schedule_reason_class(:not_found), do: "not_found"
  defp schedule_reason_class(:conflict), do: "conflict"
  defp schedule_reason_class(:precondition_failed), do: "conflict"
  defp schedule_reason_class(:timeout), do: "timeout"
  defp schedule_reason_class(:unavailable), do: "unavailable"
  defp schedule_reason_class({:ambiguous, _reason}), do: "ambiguous"
  defp schedule_reason_class({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp schedule_reason_class(reason) when is_atom(reason), do: to_string(reason)
  defp schedule_reason_class(_reason), do: "runtime"

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(_value), do: false

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil

  # ISO 8601 basic format (no colons — S3-key-safe), deterministic from unix ms.
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(:basic)

  defp stringify(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify(value), else: value)}
    end)
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp validate(params) do
    recurrence_valid? =
      (valid_interval?(params) and not Map.has_key?(params, "cron") and
         not Map.has_key?(params, "run_at")) or
        (valid_cron?(params) and not Map.has_key?(params, "interval_minutes") and
           not Map.has_key?(params, "run_at") and valid_tz?(params)) or
        (valid_run_at?(params) and not Map.has_key?(params, "interval_minutes") and
           not Map.has_key?(params, "cron"))

    if recurrence_valid? and valid_receiver_binding?(params),
      do: :ok,
      else: {:error, :invalid_schedule}
  end

  defp valid_receiver_binding?(%{"receiver" => "comma_mail", "payload" => payload} = params) do
    is_map(payload) and exact_keys?(payload, ~w(group_id conversation_id key generation)) and
      configured?(payload["group_id"]) and configured?(payload["conversation_id"]) and
      configured?(payload["key"]) and is_integer(payload["generation"]) and
      payload["generation"] > 0 and
      not Map.has_key?(params, "agent_id") and not Map.has_key?(params, "session_id") and
      not Map.has_key?(params, "prompt")
  end

  defp valid_receiver_binding?(
         %{"receiver" => "comma_recommendation", "payload" => %{"profile_id" => id}} = params
       ) do
    exact_keys?(params["payload"], ~w(profile_id)) and configured?(id) and
      not Map.has_key?(params, "agent_id") and not Map.has_key?(params, "session_id") and
      not Map.has_key?(params, "prompt")
  end

  defp valid_receiver_binding?(%{"receiver" => "task", "payload" => payload} = params) do
    # A Task definition's owner is its group binding, never an agent: an
    # `agent_id` on a Task row would make it selectable through the agent
    # owner branch of `list_by_agents`/`list_for_owners` and mutable by a
    # foreign project (cross-tenant authorization escape). Reject at the
    # source; the read predicates receiver-fence both branches as defense in
    # depth for pre-existing rows.
    is_map(payload) and configured?(payload["agent_group_id"]) and
      configured?(payload["conversation_id"]) and not Map.has_key?(params, "agent_id")
  end

  defp valid_receiver_binding?(
         %{
           "receiver" => "triage_follow_up",
           "payload" => %{
             "entry_id" => entry_id,
             "authority_generation" => authority_generation
           }
         } = params
       ) do
    exact_keys?(params["payload"], ~w(entry_id authority_generation)) and
      configured?(entry_id) and configured?(authority_generation) and
      not Map.has_key?(params, "agent_id") and not Map.has_key?(params, "session_id") and
      not Map.has_key?(params, "prompt")
  end

  defp valid_receiver_binding?(
         %{
           "receiver" => "meeting_publication",
           "payload" => %{
             "group_id" => group_id,
             "meeting_plan_id" => meeting_plan_id
           }
         } = params
       ) do
    (exact_keys?(params["payload"], ~w(group_id meeting_plan_id)) or
       (exact_keys?(params["payload"], ~w(group_id meeting_plan_id kind)) and
          params["payload"]["kind"] in ~w(card personal)) or
       (exact_keys?(params["payload"], ~w(group_id meeting_plan_id kind dispatch_revision)) and
          params["payload"]["kind"] == "deadline_fence" and
          configured?(params["payload"]["dispatch_revision"]))) and
      configured?(group_id) and configured?(meeting_plan_id) and
      not Map.has_key?(params, "agent_id") and not Map.has_key?(params, "session_id") and
      not Map.has_key?(params, "prompt")
  end

  defp valid_receiver_binding?(
         %{
           "receiver" => receiver,
           "agent_id" => agent_id,
           "prompt" => prompt
         } = params
       )
       when receiver in [nil, "agent"] do
    configured?(agent_id) and is_binary(prompt) and
      valid_optional_session_id?(params["session_id"])
  end

  defp valid_receiver_binding?(%{"agent_id" => agent_id, "prompt" => prompt} = params) do
    configured?(agent_id) and is_binary(prompt) and
      valid_optional_session_id?(params["session_id"])
  end

  defp valid_receiver_binding?(_params), do: false

  defp valid_interval?(%{"interval_minutes" => minutes}),
    do: is_integer(minutes) and minutes > 0

  defp valid_interval?(_params), do: false

  defp valid_cron?(%{"cron" => cron}), do: match?({:ok, _}, Cron.parse(cron))
  defp valid_cron?(_params), do: false

  defp valid_run_at?(%{"run_at" => run_at}), do: is_integer(run_at) and run_at > 0
  defp valid_run_at?(_params), do: false

  defp valid_optional_session_id?(value) when value in [nil, ""], do: true
  defp valid_optional_session_id?(value), do: Ids.valid_session_id?(value)

  defp valid_tz?(%{"timezone" => timezone}) when is_binary(timezone),
    do: match?({:ok, _}, DateTime.now(timezone))

  defp valid_tz?(%{"timezone" => nil}), do: true
  defp valid_tz?(params), do: not Map.has_key?(params, "timezone")

  # ---- GenServer (optional lease-gated periodic sweep) ----

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      node: Keyword.get(opts, :node, to_string(node())),
      interval: Keyword.get(opts, :interval_ms, @interval_ms),
      lease: nil,
      # nil = never pruned in this process; monotonic ms afterwards (a zero
      # default would compare against BEAM's negative monotonic clock).
      last_runs_prune_ms: nil
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
        case run_once() do
          {:ok, %{fired: fired, failed: failed}} ->
            if fired != [], do: Logger.info("schedules: fired=#{inspect(fired)}")

            if failed != [] do
              safe_failures =
                Enum.map(failed, fn {id, reason} -> {id, schedule_reason_class(reason)} end)

              Logger.warning("schedules: failed=#{inspect(safe_failures)}")
            end

            maybe_prune_runs(state)

          {:error, reason} ->
            Logger.warning("schedule sweep failed: #{inspect(reason)}")
            state
        end
      else
        state
      end

    Process.send_after(self(), :tick, state.interval)
    state
  end

  # Lease-holder-only retention prune of old run claims; low frequency and
  # best-effort — a failed prune never affects the sweep.
  defp maybe_prune_runs(state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.last_runs_prune_ms) or
         now - state.last_runs_prune_ms >= @runs_prune_every_ms do
      case ScheduleRuns.prune_older_than(@runs_retention_days) do
        {:ok, count} when count > 0 ->
          Logger.info("schedules: pruned #{count} run claims older than #{@runs_retention_days}d")

        _ ->
          :ok
      end

      %{state | last_runs_prune_ms: now}
    else
      state
    end
  end

  defp acquire_or_renew(%{lease: nil} = state) do
    case S3Lease.acquire(:schedules, state.node) do
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
