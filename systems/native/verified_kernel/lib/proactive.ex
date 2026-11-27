defmodule SalixVerifiedKernel.Proactive do
  @moduledoc """
  Verified proactive attention kernel decisions over explicit ETF data:
  station-task stop monotonicity and urgent system-card pool routing,
  bounded meeting/budget deferral liveness, active-worker strong-anchor
  absorption, and calibrated System-1 pre-gate thresholds.
  """

  @type observation :: {1..3, integer()}
  @type track :: :unseen | {:open | :handled | :left, integer(), integer()}
  @type phase :: :working | :done | :failed | :need | {:need, atom() | String.t()}

  @doc """
  Advances `track` against `(phase, at_ms)` with recent cutoff `since_ms`.

  Returns `{next_track, transition}` where `transition` is:
  - `:noop`
  - `{:present, {tag, at_ms}, :ordinary | :reserve | :code, :high | :normal}`
  - `{:close, {tag, at_ms}}`
  """
  def step_stop(track, phase, at_ms, since_ms)
      when is_integer(at_ms) and is_integer(since_ms) do
    call(:step_stop, {track, phase, at_ms, since_ms})
  end

  @doc """
  Transitions `{:open, tag, at_ms}` to `{{:handled, tag, at_ms}, true}` when the
  Router forwards a reply into the station-hosted Task; leaves all other states
  unchanged with `false`.
  """
  def router_replied(track), do: call(:router_replied, track)

  @doc """
  Returns the effective meeting busy-until timestamp (`integer() | nil`) for
  `pool` (`:ordinary | :reserve | :code`). `:code` and `:reserve` always bypass
  calendar meeting deferral (`nil`).
  """
  def effective_busy_until(pool, meeting_busy_until_ms)
      when pool in [:ordinary, :reserve, :code] and
             (is_integer(meeting_busy_until_ms) or is_nil(meeting_busy_until_ms)) do
    call(:effective_busy_until, {pool, meeting_busy_until_ms})
  end

  @doc """
  Computes `{next_at_ms, due_wake_ms | nil}` for a deferred proactive matter.
  """
  def schedule_deferral(
        opens_at_ms,
        now_ms,
        lead_ms,
        busy_until_ms,
        due_ms,
        reserve_window_at_ms,
        is_act?
      )
      when is_integer(opens_at_ms) and is_integer(now_ms) and is_integer(lead_ms) and
             is_boolean(is_act?) do
    call(
      :schedule_deferral,
      {opens_at_ms, now_ms, lead_ms, busy_until_ms, due_ms, reserve_window_at_ms, is_act?}
    )
  end

  @doc """
  Returns `true` iff a passive arrival (`direct_human? == false`, `code_hint? == false`,
  `incomplete? == false`) shares at least one strong resource anchor with an active
  `in_progress` station worker.
  """
  def absorb_by_worker?(direct_human?, code_hint?, incomplete?, item_anchors, worker_anchors)
      when is_boolean(direct_human?) and is_boolean(code_hint?) and is_boolean(incomplete?) and
             is_list(item_anchors) and is_list(worker_anchors) do
    call(
      :absorb_by_worker,
      {direct_human?, code_hint?, incomplete?, Enum.map(item_anchors, &to_string/1),
       Enum.map(worker_anchors, &to_string/1)}
    )
  end

  @doc """
  Calibrated System-1 Jev gate: returns `:quiet` or `:escalate_to_llm`.
  """
  def gate_jev(is_quiet_choice?, prob_bp, raw_threshold_bp)
      when is_boolean(is_quiet_choice?) and is_integer(prob_bp) and is_integer(raw_threshold_bp) do
    call(:gate_jev, {is_quiet_choice?, prob_bp, raw_threshold_bp})
  end

  @doc """
  Computes the normalized CFT Triage target route (`:none | :self | :mixed | :other | :invalid`)
  for `source_mode`, syntactic `addressee`, and `actor_is_agent?`.
  """
  def triage_target_route(source_mode, addressee, actor_is_agent?)
      when is_boolean(actor_is_agent?) do
    call(:triage_target_route, {source_mode || :other, addressee || :invalid, actor_is_agent?})
  end

  @doc """
  Returns the system-owned recipient boundary action for `route`:
  `:allow | :force_silence_outside_authority | :force_silence_duplicate | :reject_target`.
  """
  def triage_boundary_action(route) do
    call(:triage_boundary_action, route || :invalid)
  end

  @doc """
  Returns `true` iff `(source_mode, addressee, actor_is_agent?)` qualifies for
  ordinary single-Worker Triage intake (`worker_pending`).
  """
  def triage_intake?(source_mode, addressee, actor_is_agent?)
      when is_boolean(actor_is_agent?) do
    call(:triage_is_intake, {source_mode || :other, addressee || :invalid, actor_is_agent?})
  end

  @doc """
  Evaluates the double-freshness & authority fence around Triage delegation preparation.

  - `first` / `second`: `{:fresh, authority_binary}` | `:stale` | `:transient_error` | `:permanent_error`
  - `prep`: `:prepared` | `:retryable_error` | `:non_retryable_error`

  Returns `:commit | :suppress_stale | :suppress_authority_drift | :retry_later | :block_permanent`.
  """
  def decide_delegation_effect(first, prep, second) do
    call(:decide_delegation_effect, {first, prep, second})
  end

  @doc """
  Computes the next Triage investigation lifecycle state (`:completed | :retry | :failed`)
  from effect `outcome` (`:applied | :stale | :failed`) and `attempts` (`integer()`).
  """
  def settle_investigation_outcome(outcome, attempts)
      when outcome in [:applied, :stale, :failed] and is_integer(attempts) do
    call(:settle_investigation_outcome, {outcome, attempts})
  end

  @doc """
  Returns the CFT Triage ↔ `still.fail` coordination disposition:
  `:no_overlap | :defer_silence_already_handled | :surface_blocker_with_follow_up | :verify_public_evidence`.
  """
  def triage_stillfail_guidance(
        same_slack_thread?,
        shares_artifact_anchor?,
        asks_status_or_help?,
        phase
      )
      when is_boolean(same_slack_thread?) and is_boolean(shares_artifact_anchor?) and
             is_boolean(asks_status_or_help?) do
    call(
      :triage_stillfail_guidance,
      {same_slack_thread?, shares_artifact_anchor?, asks_status_or_help?, phase}
    )
  end

  @doc """
  Clamps a Triage `follow_up` `recheck_after_hours` interval into `1..720`.
  """
  def clamp_follow_up_hours(raw_hours) when is_integer(raw_hours) do
    call(:clamp_follow_up_hours, raw_hours)
  end

  defp call(operation, payload) do
    case SalixVerifiedKernel.invoke(:proactive, operation, payload) do
      {:ok, result} -> result
      {:error, owner, code} -> raise ArgumentError, "verified kernel #{owner}: #{code}"
    end
  end
end
