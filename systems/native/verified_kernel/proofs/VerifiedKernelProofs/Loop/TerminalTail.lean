import VerifiedKernelProofs.Loop.ActivationGate
import VerifiedKernelProofs.Loop.RoundFrames
import VerifiedKernelProofs.Session.AppendOnly.SessionEvent
import VerifiedKernelProofs.Session.WorkRetirement
import VerifiedKernelProofs.Order
import VerifiedKernelProofs.Session.WorkAllocation
import VerifiedKernelProofs.Session.WorkArchiveCommit

/-! # The terminal tail stops the continuation (property C)

A settlement that ends a turn writes `terminal_reply_ack_hwm`. Then
`terminal_reply_tail?` holds until the transcript moves, and
`continuation_runnable?` answers `false`.

* `tail_holds`: the tail holds on a state whose terminal ACK position is the
  last message id, and whose ACK reaches that position.
* `tail_blocks_continuation`: while the tail holds,
  `needs_transcript_continuation?` answers `false`.
* `settlement_tail`: after the settlement events apply (a `session_event` of
  a terminal kind with `settled_ack_hwm`, `wait_clear`, `ack`, and `status`),
  the tail holds. A blocking card obligation can fence the ACK. Then the ACK
  position stays below the tail position.
* `local_settlement_stops_continuation`,
  `runaway_retirement_stops_continuation`: `guard_notice` commits the local
  guard settlement or the runaway retirement after a guard parks the session.
  Each ends with such a batch. After it applies,
  `needs_transcript_continuation?` answers `false`.
* `failureAck_final`: `llm_failure_ack?` answers `true` only for a source
  that a notice already reached, or when `failure_reason` gives a reason.

The tail does not stop `has_unprocessed_stable_work?` from other work, such
as queued input, a retry deadline or a pending repair.
-/

namespace VerifiedKernel.Session.Loop.TerminalTail
open Data
open VerifiedKernel.Session.WorkConservation
open VerifiedKernel.Session.Loop.Gate (SatA SatA.bind SatA.pure SatA.fail SatA.ite SatA.dite)
open VerifiedKernel.Session.Loop.RoundFrames (Prepared resident_prepared field_value)
set_option Elab.async false
set_option maxHeartbeats 1000000

/-! ## Term facts -/

theorem isMap_of_get {v k x : Term} (h : v.get k = x) (ne : x ≠ nil) : v.isMap = true := by
  cases v <;> simp_all [Term.get, Term.isMap, nil]

theorem has_of_get {v k x : Term} (h : v.get k = x) (ne : x ≠ nil) : v.has k = true := by
  cases v with
  | map entries =>
    simp only [Term.get, Term.has] at h ⊢
    cases found : entries.find? (fun entry => entry.1 == k) with
    | none => rw [found] at h; exact absurd h.symm ne
    | some entry =>
      rw [List.any_eq_true]
      have key : (entry.1 == k) = true := by
        have := List.find?_some found
        simpa using this
      exact ⟨entry, List.mem_of_find?_eq_some found, key⟩
  | _ => simp_all [Term.get, nil]

theorem integer_ne_nil (n : Int) : Term.integer n ≠ nil := by simp [nil]

theorem field_integer {s : Term} {name : String} {n : Int} (h : s.get (a name) = .integer n) (j : List Term) :
    field s name j = .ok (.integer n, j) := by
  have map := isMap_of_get h (integer_ne_nil n)
  have has := has_of_get h (integer_ne_nil n)
  simp only [field, fetch, map, has, Bool.not_true, Bool.false_eq_true, if_false, if_true, h]
  rfl

theorem sub_integer (x y : Int) (j : List Term) : sub (.integer x) (.integer y) j = .ok (.integer (x - y), j) := by
  simp [sub, Number.calculate, Pure.pure, StateT.pure, Except.pure]

theorem atMost_integer (x y : Int) (j : List Term) :
    atMost (.integer x) (.integer y) j = .ok (decide (x ≤ y), j) := by
  simp only [atMost, order_integer, Bind.bind, StateT.bind, Except.bind, Pure.pure, StateT.pure, Except.pure]
  cases cmp : compare x y with
  | lt => simp [Int.le_of_lt (Int.compare_eq_lt.mp cmp)]
  | eq => simp [Int.le_of_eq (Int.compare_eq_eq.mp cmp)]
  | gt => simp [Int.not_le.mpr (Int.compare_eq_gt.mp cmp)]

theorem numericEq_integer (x : Int) : (Term.integer x).numericEq (.integer x) = true := by
  simp [Term.numericEq, Term.depth, Term.numericEqFuel, Term.number]

/-! ## The tail -/

/-- The fields of a terminal tail: the terminal ACK position `h` is the last
message id, and the ACK reaches it. -/
structure TailFields (t : Term) (h k : Int) : Prop where
  terminal : t.get (a "terminal_reply_ack_hwm") = .integer h
  positive : 0 < h
  next : t.get (a "next_message_id") = .integer (h + 1)
  acked : t.get (a "last_ack_message_id") = .integer k
  reached : h ≤ k

/-- `tail_holds`: `terminal_reply_tail?` answers `true` on every journal. -/
theorem tail_holds {t : Term} {h k : Int} (fields : TailFields t h k) (j : List Term) :
    StateQuery.terminalReplyTail t j = .ok (true, j) := by
  have hp : decide (0 < h) = true := decide_eq_true fields.positive
  have hr : decide (h ≤ k) = true := decide_eq_true fields.reached
  unfold StateQuery.terminalReplyTail
  simp only [Bind.bind, StateT.bind, Except.bind, field_integer fields.terminal, Term.isInteger, integerValue,
    gt_iff_lt, hp, Bool.true_and, Bool.not_true, Bool.false_eq_true, if_false]
  simp only [field_integer fields.next, i, sub_integer, Int.add_sub_cancel, numericEq_integer, Bool.not_true,
    Bool.false_eq_true, if_false]
  simp only [StateT.bind, field_integer fields.acked]
  show atMost (Term.integer h) (Term.integer k) j = _
  rw [atMost_integer, hr]

theorem tail_answer {t : Term} {h k : Int} (fields : TailFields t h k) {j j' : List Term} {v : Bool}
    (run : StateQuery.terminalReplyTail t j = .ok (v, j')) : v = true := by
  rw [tail_holds fields] at run
  cases run
  rfl

/-- While the tail holds, `continuation_runnable?` answers `false`. -/
theorem tail_blocks_runnable {t : Term} {h k : Int} (fields : TailFields t h k) :
    SatA (· = false) (StateQuery.continuationRunnable t) := by
  unfold StateQuery.continuationRunnable
  sata_walk
  all_goals first
    | rfl
    | exact absurd (tail_answer fields ‹_›) (by simp_all)

/-- `tail_blocks_continuation`: while the tail holds,
`needs_transcript_continuation?` answers `false`. -/
theorem tail_blocks_continuation {t : Term} {h k : Int} (fields : TailFields t h k) :
    SatA (· = false) (StateQuery.needsContinuation t) := by
  unfold StateQuery.needsContinuation
  sata_walk
  all_goals first
    | rfl
    | exact tail_blocks_runnable fields

/-! ## The settlement batch -/

/-- The keys that `sessionEvent` selects from its event. -/
def selectedKeys : List String := ["event_id", "kind", "source", "method", "event", "stale", "created_at"]

/-- A session-event kind that records `settled_ack_hwm` as the terminal ACK position. -/
def TerminalKind (kind : Term) : Prop :=
  kind = b "terminal_reply_delivered" ∨ kind = b "channel_onboarding_settled" ∨
    kind = b "runtime_failure_reply_settled" ∨ kind = b "runtime_failure_disposed" ∨
    kind = b "runtime_runaway_retired"

theorem event_bind_sat {α : Type} {v : Term} {name : String} {k : Term → KernelM α}
    {Q : α → Prop} (h : Gate.SatA Q (k (v.get (b name)))) : Gate.SatA Q (Data.event v name >>= k) := by
  intro j out j' run
  obtain ⟨x, j1, first, second⟩ := bind_ok run
  obtain ⟨rfl, rfl⟩ := access_ok first
  exact h _ _ _ second

theorem field_bind_sat {α : Type} {v : Term} {name : String} {k : Term → KernelM α}
    {Q : α → Prop} (h : Gate.SatA Q (k (v.get (a name)))) : Gate.SatA Q (field v name >>= k) := by
  intro j out j' run
  obtain ⟨x, j1, first, second⟩ := bind_ok run
  simp only [field, fetch_ok_iff] at first
  obtain ⟨_, _, rfl, rfl⟩ := first
  exact h _ _ _ second

open Lean Elab Tactic Meta in
/-- One step of a walk that tracks read values: a bind whose first action
reads a field or an event field continues with the value that it reads. -/
elab "track_step" : tactic => withMainContext do
  let target ← instantiateMVars (← getMainTarget)
  unless target.isAppOf ``Gate.SatA do throwError "not a SatA goal"
  let t := target.appArg!.consumeMData.headBeta
  if t.getAppFn.consumeMData.isConstOf ``Bind.bind then
    let first := (t.getArg! 4).consumeMData.headBeta
    let head := first.getAppFn.consumeMData
    if head.isConstOf ``VerifiedKernel.Data.event then
      evalTactic (← `(tactic| apply event_bind_sat)); return
    if head.isConstOf ``VerifiedKernel.Data.field then
      evalTactic (← `(tactic| apply field_bind_sat)); return
  evalTactic (← `(tactic| sata_step))

macro "track_walk" : tactic => `(tactic| repeat' track_step)

theorem terminal_kind_beq {kind : Term} (terminal : TerminalKind kind) :
    (kind == b "terminal_reply_delivered" || kind == b "channel_onboarding_settled" ||
      kind == b "runtime_failure_reply_settled" || kind == b "runtime_failure_disposed" ||
      kind == b "runtime_runaway_retired") = true := by
  rcases terminal with h | h | h | h | h <;> rw [h] <;> simp [binary_key_beq]

/-- `sessionEvent` of a terminal kind stores the `settled_ack_hwm` of its
payload as the terminal ACK position. -/
theorem sessionEvent_terminal {s e : Term}
    (terminal : TerminalKind ((select e selectedKeys true).get (b "kind"))) :
    Gate.SatA (fun t => t.get (a "terminal_reply_ack_hwm") =
        ((select e selectedKeys true).get (b "event")).get (b "settled_ack_hwm"))
      (sessionEvent s e) := by
  unfold selectedKeys at terminal ⊢
  unfold sessionEvent
  track_walk
  all_goals first
    | (intro j out j' written
       rw [write_get_key "terminal_reply_ack_hwm" written rfl,
         get_put_binary_other _ _ (show "seq" ≠ "event" by decide)])
    | (exfalso
       simp only [get_put_binary_other _ _ (show "seq" ≠ "kind" by decide)] at *
       exact absurd (terminal_kind_beq terminal) (by assumption))

/-! ## Reducer frames -/

/-- The keys that `sessionAck` writes. -/
def ackKeys : List String := ["last_ack_message_id", "provider_reply_obligations", "active_source_message_ids",
  "visible_reply_activation_scope", "visible_reply_egress_facts", "runaway_unsettled_streak", "input_round_streak",
  "runtime_failure_reply"]

theorem sessionAck_field {s e : Term} {key : String} (outside : ackKeys.all (· != key) = true) :
    Gate.SatA (fun t => t.get (a key) = s.get (a key)) (sessionAck s e) := by
  unfold sessionAck
  track_walk
  all_goals first
    | rfl
    | (intro j out j' written
       exact write_field_frame written (by simpa [ackKeys] using outside))
    | (intro j out j' done
       rw [pure_ok done])

theorem default_integer' (n : Int) (fallback : Term) : (Term.integer n).default fallback = .integer n := by
  simp [Term.default, Term.truthy]

/-- An `ack` event at `h` on a state acknowledged through `p`: the ACK
position becomes `max p h`, or a blocking card obligation fences the ACK and
the state stays the same. -/
theorem sessionAck_position {s e : Term} {p h : Int} (before : s.get (a "last_ack_message_id") = .integer p)
    (position : e.get (b "last_ack_message_id") = .integer h) :
    Gate.SatA (fun t => t.get (a "last_ack_message_id") = .integer (max p h) ∨ t = s) (sessionAck s e) := by
  unfold sessionAck
  track_walk
  all_goals first
    | exact Or.inr rfl
    | (intro j out j' written
       left
       rw [write_get_key "last_ack_message_id" written rfl]
       simp only [before, position, default_integer', maximum_integer, Except.ok.injEq, Prod.mk.injEq] at *
       obtain ⟨hx, -⟩ := ‹i (max p h) = _ ∧ _›
       rw [← hx])

theorem waitClear_field {s e : Term} {key : String} (notWait : key ≠ "wait") (notRefs : key ≠ "async_result_refs") :
    Gate.SatA (fun t => t.get (a key) = s.get (a key)) (waitClear s e) := by
  unfold waitClear
  track_walk
  all_goals first
    | rfl
    | (intro j out j' run
       rw [ArchivePublication.pruneResultRefs_field notRefs run,
         write_field_frame (hyp% write _ _ _ = _) (by simpa using Ne.symm notWait)])

theorem statusTransition_field {s e : Term} {key : String} (notStatus : key ≠ "status")
    (notActivity : key ≠ "activity_status") :
    Gate.SatA (fun t => t.get (a key) = s.get (a key)) (statusTransition s e) := by
  unfold statusTransition
  track_walk
  all_goals first
    | rfl
    | (intro j out j' written
       exact write_field_frame written (by simp [Ne.symm notStatus, Ne.symm notActivity]))
    | (intro j out j' failed
       simp only [inspectedError, fail_ok_iff] at failed)

/-! ## The settlement batch applies -/

/-- The events of a settlement that ends a turn (`Settlement.terminalEvents`):
a `session_event` of `kind` with `settled_ack_hwm`, `wait_clear`, `ack` and
`status idle`. -/
def settlementEvents (sid hwm kind details : Term) : List Term :=
  [.map [(b "type", b "session_event"), (b "session_id", sid), (b "kind", kind),
     (b "event", details.put (b "settled_ack_hwm") hwm)],
   .map [(b "type", b "wait_clear"), (b "session_id", sid)],
   .map [(b "type", b "ack"), (b "session_id", sid), (b "last_ack_message_id", hwm)],
   .map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]]

theorem settlementEvents_native (sid hwm kind details : Term) :
    (native_decl% "VerifiedKernel.Session.Settlement.terminalEvents" : Term → Term → Term → Term → List Term)
      sid hwm kind details = settlementEvents sid hwm kind details := rfl

theorem terminal_ne_nil {kind : Term} (terminal : TerminalKind kind) : (kind != nil) = true := by
  rcases terminal with h | h | h | h | h <;> rw [h] <;> rfl

theorem put_ne_nil (v k x : Term) : (v.put k x != nil) = true := by
  cases v <;> rfl

theorem select_settlement {sid kind ev : Term} (hk : (kind != nil) = true) (he : (ev != nil) = true) :
    (select (.map [(b "type", b "session_event"), (b "session_id", sid), (b "kind", kind), (b "event", ev)])
      selectedKeys true).get (b "kind") = kind ∧
    (select (.map [(b "type", b "session_event"), (b "session_id", sid), (b "kind", kind), (b "event", ev)])
      selectedKeys true).get (b "event") = ev := by
  simp [select, selectedKeys, Term.has, Term.get, List.filterMap, binary_key_beq, hk, he]

theorem map_get_session (x sid : Term) (rest : List (Term × Term)) :
    (Term.map ((b "type", x) :: (b "session_id", sid) :: rest)).get (b "session_id") = sid := by
  simp [Term.get, binary_key_beq]

/-- A resident batch of four events, one step at a time. -/
theorem batch_four {s t e₁ e₂ e₃ e₄ : Term} (batch : ResidentBatch s [e₁, e₂, e₃, e₄] t) :
    ∃ s₁ s₂ s₃, Prepared s e₁ s₁ ∧ Prepared s₁ e₂ s₂ ∧ Prepared s₂ e₃ s₃ ∧ Prepared s₃ e₄ t := by
  cases batch with
  | cons one rest =>
    cases rest with
    | cons two rest =>
      cases rest with
      | cons three rest =>
        cases rest with
        | cons four rest =>
          cases rest with
          | nil => exact ⟨_, _, _, resident_prepared one, resident_prepared two, resident_prepared three,
              resident_prepared four⟩

/-- A resident step of a canonical event of the same session runs the
reducer once, then changes only the activity fields. -/
theorem prepared_reduce {s raw t : Term} (step : Prepared s raw t) (keys : BinaryKeys raw)
    (target : raw.get (b "session_id") = s.get (a "session_id")) :
    ∃ next j r, inner s raw j = .ok (next, r) ∧ ActivityFrame next t := by
  obtain ⟨next, normalized, j, r, prepared, frame⟩ := step
  cases normalized with
  | none => exact (prepareTrusted_canonical_not_skipped keys target prepared).elim
  | some event =>
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys keys read
    subst same
    exact ⟨next, _, _, reduced, frame⟩

/-- The four fields that the tail reads. -/
structure Watched (t : Term) (sid terminal next acked : Term) : Prop where
  session : t.get (a "session_id") = sid
  terminal : t.get (a "terminal_reply_ack_hwm") = terminal
  next : t.get (a "next_message_id") = next
  acked : t.get (a "last_ack_message_id") = acked

theorem Watched.activity {s t sid terminal next acked : Term} (w : Watched s sid terminal next acked)
    (frame : ActivityFrame s t) : Watched t sid terminal next acked :=
  ⟨(frame _ (by decide) (by decide)).trans w.session, (frame _ (by decide) (by decide)).trans w.terminal,
    (frame _ (by decide) (by decide)).trans w.next, (frame _ (by decide) (by decide)).trans w.acked⟩

/-- `settlement_tail`: after the settlement events of a terminal kind apply
to a state whose last message id is `h`, the terminal tail holds at `h`.
Only a blocking card obligation can fence the ACK. Then the ACK position
stays below `h`. -/
theorem settlement_tail {s t kind details : Term} {h p : Int}
    (terminal : TerminalKind kind) (positive : 0 < h)
    (next : s.get (a "next_message_id") = .integer (h + 1))
    (acked : s.get (a "last_ack_message_id") = .integer p)
    (land : ResidentBatch s (settlementEvents (s.get (a "session_id")) (.integer h) kind details) t) :
    TailFields t h (max p h) ∨ (t.get (a "last_ack_message_id") = .integer p ∧ p < h) := by
  obtain ⟨s₁, s₂, s₃, one, two, three, four⟩ := batch_four land
  have w₀ : Watched s (s.get (a "session_id")) (s.get (a "terminal_reply_ack_hwm")) (.integer (h + 1))
      (.integer p) := ⟨rfl, rfl, next, acked⟩
  -- The session event stores the terminal ACK position.
  obtain ⟨n₁, j₁, r₁, reduced₁, frame₁⟩ := prepared_reduce one (by simp [BinaryKeys, b, Term.text, Term.isBinary])
    (map_get_session _ _ _)
  have call₁ : sessionEvent s (.map [(b "type", b "session_event"), (b "session_id", s.get (a "session_id")),
      (b "kind", kind), (b "event", details.put (b "settled_ack_hwm") (.integer h))]) j₁ = .ok (n₁, r₁) := by
    have ty : (Term.get (.map [(b "type", b "session_event"), (b "session_id", s.get (a "session_id")),
      (b "kind", kind), (b "event", details.put (b "settled_ack_hwm") (.integer h))]) (b "type")) = b "session_event" := by
      simp [Term.get, binary_key_beq]
    simpa +decide [inner, ty] using reduced₁
  obtain ⟨kindSel, eventSel⟩ := select_settlement (sid := s.get (a "session_id")) (terminal_ne_nil terminal)
    (put_ne_nil details (b "settled_ack_hwm") (.integer h))
  have stored := sessionEvent_terminal (by rw [kindSel]; exact terminal) _ _ _ call₁
  rw [eventSel, WorkConservation.get_put_binary_same] at stored
  have fields₁ := (sessionEvent_fields call₁).2
  have w₁ : Watched s₁ (s.get (a "session_id")) (.integer h) (.integer (h + 1)) (.integer p) :=
    Watched.activity ⟨(fields₁ "session_id" (by decide)).trans w₀.session, stored,
      (fields₁ "next_message_id" (by decide)).trans w₀.next,
      (fields₁ "last_ack_message_id" (by decide)).trans w₀.acked⟩ frame₁
  -- `wait_clear` keeps the watched fields.
  obtain ⟨n₂, j₂, r₂, reduced₂, frame₂⟩ := prepared_reduce two (by simp [BinaryKeys, b, Term.text, Term.isBinary])
    ((map_get_session _ _ _).trans w₁.session.symm)
  have call₂ : waitClear s₁ (.map [(b "type", b "wait_clear"), (b "session_id", s.get (a "session_id"))]) j₂ =
      .ok (n₂, r₂) := by
    have ty : (Term.get (.map [(b "type", b "wait_clear"), (b "session_id", s.get (a "session_id"))]) (b "type")) = b "wait_clear" := by
      simp [Term.get, binary_key_beq]
    simpa +decide [inner, ty] using reduced₂
  have keep₂ := fun (key : String) (hw : key ≠ "wait") (hr : key ≠ "async_result_refs") =>
    waitClear_field (e := .map [(b "type", b "wait_clear"), (b "session_id", s.get (a "session_id"))]) hw hr _ _ _ call₂
  have w₂ : Watched s₂ (s.get (a "session_id")) (.integer h) (.integer (h + 1)) (.integer p) :=
    Watched.activity ⟨(keep₂ _ (by decide) (by decide)).trans w₁.session,
      (keep₂ _ (by decide) (by decide)).trans w₁.terminal, (keep₂ _ (by decide) (by decide)).trans w₁.next,
      (keep₂ _ (by decide) (by decide)).trans w₁.acked⟩ frame₂
  -- The ACK moves the ACK position to `max p h`, unless a card fences it.
  obtain ⟨n₃, j₃, r₃, reduced₃, frame₃⟩ := prepared_reduce three (by simp [BinaryKeys, b, Term.text, Term.isBinary])
    ((map_get_session _ _ _).trans w₂.session.symm)
  have call₃ : sessionAck s₂ (.map [(b "type", b "ack"), (b "session_id", s.get (a "session_id")),
      (b "last_ack_message_id", .integer h)]) j₃ = .ok (n₃, r₃) := by
    have ty : (Term.get (.map [(b "type", b "ack"), (b "session_id", s.get (a "session_id")),
      (b "last_ack_message_id", .integer h)]) (b "type")) = b "ack" := by
      simp [Term.get, binary_key_beq]
    simpa +decide [inner, ty] using reduced₃
  have keep₃ := fun (key : String) (outside : ackKeys.all (· != key) = true) =>
    sessionAck_field (e := .map [(b "type", b "ack"), (b "session_id", s.get (a "session_id")),
      (b "last_ack_message_id", .integer h)]) outside _ _ _ call₃
  have moved := sessionAck_position (p := p) (h := h) w₂.acked (by simp [Term.get, binary_key_beq]) _ _ _ call₃
  have ackAfter : n₃.get (a "last_ack_message_id") = .integer (max p h) ∨
      (n₃.get (a "last_ack_message_id") = .integer p ∧ p < h) := by
    rcases moved with advanced | same
    · exact Or.inl advanced
    · rw [same, w₂.acked]
      by_cases below : p < h
      · exact Or.inr ⟨rfl, below⟩
      · left; rw [Int.max_eq_left (Int.not_lt.mp below)]
  have frame₃' := fun (key : String) (one : key ≠ "activity_status") (two : key ≠ "activity_status_updated_at") =>
    frame₃ key one two
  -- `status` keeps the watched fields.
  obtain ⟨n₄, j₄, r₄, reduced₄, frame₄⟩ := prepared_reduce four (by simp [BinaryKeys, b, Term.text, Term.isBinary])
    ((map_get_session _ _ _).trans (by rw [frame₃ _ (by decide) (by decide), keep₃ _ (by decide), w₂.session]))
  have call₄ : statusTransition s₃ (.map [(b "type", b "status"), (b "session_id", s.get (a "session_id")),
      (b "status", b "idle")]) j₄ = .ok (n₄, r₄) := by
    have ty : (Term.get (.map [(b "type", b "status"), (b "session_id", s.get (a "session_id")),
      (b "status", b "idle")]) (b "type")) = b "status" := by
      simp [Term.get, binary_key_beq]
    simpa +decide [inner, ty] using reduced₄
  have keep₄ := fun (key : String) (hs : key ≠ "status") (ha : key ≠ "activity_status") =>
    statusTransition_field (e := .map [(b "type", b "status"), (b "session_id", s.get (a "session_id")),
      (b "status", b "idle")]) hs ha _ _ _ call₄
  have terminalT : t.get (a "terminal_reply_ack_hwm") = .integer h := by
    rw [frame₄ _ (by decide) (by decide), keep₄ _ (by decide) (by decide), frame₃ _ (by decide) (by decide),
      keep₃ _ (by decide), w₂.terminal]
  have nextT : t.get (a "next_message_id") = .integer (h + 1) := by
    rw [frame₄ _ (by decide) (by decide), keep₄ _ (by decide) (by decide), frame₃ _ (by decide) (by decide),
      keep₃ _ (by decide), w₂.next]
  have ackT : t.get (a "last_ack_message_id") = n₃.get (a "last_ack_message_id") := by
    rw [frame₄ _ (by decide) (by decide), keep₄ _ (by decide) (by decide), frame₃ _ (by decide) (by decide)]
  rw [← ackT] at ackAfter
  rcases ackAfter with advanced | fenced
  · exact Or.inl ⟨terminalT, positive, nextT, advanced, Int.le_max_right p h⟩
  · exact Or.inr fenced

/-! ## The local guard settlement -/

/-- The local guard settlement answers `nil` or the settlement events at the
last message id, of kind `runtime_failure_disposed`. -/
theorem localSettlement_shape {s : Term} :
    Gate.SatA (fun out => out = nil ∨ ∃ hwm details, (∃ j j', sub (s.get (a "next_message_id")) (i 1) j = .ok (hwm, j')) ∧
        out = list (settlementEvents (s.get (a "session_id")) hwm (b "runtime_failure_disposed") details))
      (Settlement.guardLocalSettlement s) := by
  unfold Settlement.guardLocalSettlement
  track_walk
  all_goals first
    | exact Or.inl rfl
    | (rw [settlementEvents_native]
       exact Or.inr ⟨_, _, ⟨_, _, (hyp% sub _ _ _ = _)⟩, rfl⟩)

theorem lookup_local_settlement :
    lookupOp queryTable (a "guard_failure_local_settlement") = some (fun state _ => Settlement.guardLocalSettlement state) :=
  rfl

theorem queryAsk_local_settlement (state x : Term) :
    Loop.queryAsk state "guard_failure_local_settlement" x = Settlement.guardLocalSettlement state := by
  unfold Loop.queryAsk
  rw [lookup_local_settlement]

/-- `local_settlement_stops_continuation`: `guard_notice` commits the answer
of `guard_failure_local_settlement` when it is a list. After those events
apply to the state that the step read, `needs_transcript_continuation?`
answers `false`, unless a blocking card obligation fenced the ACK. -/
theorem local_settlement_stops_continuation {s t : Term} {events : List Term} {h p : Int} {j j' : List Term}
    (settle : Loop.queryAsk s "guard_failure_local_settlement" nil j = .ok (list events, j'))
    (positive : 0 < h) (next : s.get (a "next_message_id") = .integer (h + 1))
    (acked : s.get (a "last_ack_message_id") = .integer p)
    (land : ResidentBatch s events t) :
    Gate.SatA (· = false) (StateQuery.needsContinuation t) ∨
      (t.get (a "last_ack_message_id") = .integer p ∧ p < h) := by
  rw [queryAsk_local_settlement] at settle
  rcases localSettlement_shape _ _ _ settle with none | ⟨hwm, details, ⟨k, k', position⟩, same⟩
  · cases none
  · rw [next, i, sub_integer, Int.add_sub_cancel] at position
    cases position
    cases same
    rcases settlement_tail (Or.inr (Or.inr (Or.inr (Or.inl rfl)))) positive next acked land with tail | fenced
    · exact Or.inl (tail_blocks_continuation tail)
    · exact Or.inr fenced

/-! ## The runaway retirement -/

/-- The fields that a settlement prefix must keep. -/
def watchedKeys : List String := ["next_message_id", "last_ack_message_id", "session_id"]

/-- The step keeps the watched fields. -/
def Keeps (s t : Term) : Prop := ∀ key ∈ watchedKeys, t.get (a key) = s.get (a key)

theorem keeps_trans {s t u : Term} (first : Keeps s t) (second : Keeps t u) : Keeps s u :=
  fun key mem => (second key mem).trans (first key mem)

theorem keeps_activity {s t u : Term} (kept : Keeps s t) (frame : ActivityFrame t u) : Keeps s u := by
  intro key mem
  have outside : key ≠ "activity_status" ∧ key ≠ "activity_status_updated_at" := by
    simp only [watchedKeys, List.mem_cons, List.not_mem_nil, or_false] at mem
    rcases mem with rfl | rfl | rfl <;> decide
  exact (frame key outside.1 outside.2).trans (kept key mem)

theorem write_keeps {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r)) (outside : ∀ key ∈ watchedKeys, entries.all (·.1 != key) = true) :
    Keeps s t :=
  fun key mem => write_field_frame h (outside key mem)

theorem obligationResolve_keeps {s key : Term} : Gate.SatA (Keeps s) (obligationResolve s key) := by
  unfold obligationResolve
  track_walk
  all_goals first
    | exact fun _ _ => rfl
    | (intro j out j' written
       exact write_keeps written (by simp [watchedKeys]))

theorem retireIntent_keeps {s e : Term} : Gate.SatA (Keeps s) (retireIntent s e) := by
  unfold retireIntent
  track_walk
  all_goals first
    | exact fun _ _ => rfl
    | (intro j out j' written
       exact write_keeps written (by simp [watchedKeys]))

theorem replyRepair_keeps {s e : Term} : Gate.SatA (Keeps s) (replyRepair s e) := by
  unfold replyRepair
  track_walk
  all_goals
    intro j out j' written
    exact keeps_trans (write_keeps (hyp% write s _ _ = _) (by simp [watchedKeys]))
      (write_keeps written (by simp [watchedKeys]))

/-- The events that `retireRunaway` puts before the settlement events. -/
def PrefixEvent (sid e : Term) : Prop :=
  (∃ key, e = .map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", sid),
      (b "obligation_key", key), (b "outcome", b "blocked")]) ∨
  (∃ key, e = .map [(b "type", b "visible_reply_aborted"), (b "session_id", sid), (b "idempotency_key", key)]) ∨
  e = .map [(b "type", b "visible_reply_repair"), (b "session_id", sid), (b "status", b "aborted")]

theorem prefix_keeps {s e t : Term} (step : Prepared s e t) (shape : PrefixEvent (s.get (a "session_id")) e) :
    Keeps s t := by
  rcases shape with ⟨key, rfl⟩ | ⟨key, rfl⟩ | rfl
  · obtain ⟨n, j, r, reduced, frame⟩ := prepared_reduce step (by simp [BinaryKeys, b, Term.text, Term.isBinary])
      (map_get_session _ _ _)
    have ty : (Term.get (.map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", s.get (a "session_id")),
        (b "obligation_key", key), (b "outcome", b "blocked")]) (b "type")) = b "provider_reply_obligation_resolved" := by
      simp [Term.get, binary_key_beq]
    have hasKey : (Term.map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", s.get (a "session_id")),
        (b "obligation_key", key), (b "outcome", b "blocked")]).has (b "obligation_key") = true := by
      simp [Term.has, binary_key_beq]
    have getKey : (Term.map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", s.get (a "session_id")),
        (b "obligation_key", key), (b "outcome", b "blocked")]).get (b "obligation_key") = key := by
      simp [Term.get, binary_key_beq]
    have call : obligationResolve s key j = .ok (n, r) := by simpa +decide [inner, ty, hasKey, getKey] using reduced
    exact keeps_activity (obligationResolve_keeps _ _ _ call) frame
  · obtain ⟨n, j, r, reduced, frame⟩ := prepared_reduce step (by simp [BinaryKeys, b, Term.text, Term.isBinary])
      (map_get_session _ _ _)
    have ty : (Term.get (.map [(b "type", b "visible_reply_aborted"), (b "session_id", s.get (a "session_id")),
        (b "idempotency_key", key)]) (b "type")) = b "visible_reply_aborted" := by
      simp [Term.get, binary_key_beq]
    have call : retireIntent s (.map [(b "type", b "visible_reply_aborted"), (b "session_id", s.get (a "session_id")),
        (b "idempotency_key", key)]) j = .ok (n, r) := by simpa +decide [inner, ty] using reduced
    exact keeps_activity (retireIntent_keeps _ _ _ call) frame
  · obtain ⟨n, j, r, reduced, frame⟩ := prepared_reduce step (by simp [BinaryKeys, b, Term.text, Term.isBinary])
      (map_get_session _ _ _)
    have ty : (Term.get (.map [(b "type", b "visible_reply_repair"), (b "session_id", s.get (a "session_id")),
        (b "status", b "aborted")]) (b "type")) = b "visible_reply_repair" := by
      simp [Term.get, binary_key_beq]
    have call : replyRepair s (.map [(b "type", b "visible_reply_repair"), (b "session_id", s.get (a "session_id")),
        (b "status", b "aborted")]) j = .ok (n, r) := by simpa +decide [inner, ty] using reduced
    exact keeps_activity (replyRepair_keeps _ _ _ call) frame

theorem batch_split {s t : Term} {xs ys : List Term} (batch : ResidentBatch s (xs ++ ys) t) :
    ∃ u, ResidentBatch s xs u ∧ ResidentBatch u ys t := by
  induction xs generalizing s with
  | nil => exact ⟨s, .nil s, batch⟩
  | cons x rest ih =>
    cases batch with
    | cons head tail =>
      obtain ⟨u, left, right⟩ := ih tail
      exact ⟨u, .cons head left, right⟩

/-- A prefix of settlement-prefix events keeps the watched fields. -/
theorem batch_prefix {s u sid : Term} {pre : List Term} (batch : ResidentBatch s pre u)
    (same : s.get (a "session_id") = sid) (shape : ∀ e ∈ pre, PrefixEvent sid e) : Keeps s u := by
  induction batch with
  | nil => exact fun _ _ => rfl
  | cons head tail ih =>
    have step := resident_prepared head
    have kept := prefix_keeps step (by rw [same]; exact shape _ List.mem_cons_self)
    have sameNext : _ = sid := (kept "session_id" (by simp [watchedKeys])).trans same
    exact keeps_trans kept (ih sameNext (fun e mem => shape e (List.mem_cons_of_mem _ mem)))

/-- `retireRunaway` answers `nil`, or settlement-prefix events and then the
settlement events at the last message id, of kind `runtime_runaway_retired`. -/
theorem retireRunaway_shape {s : Term} :
    Gate.SatA (fun out => out = nil ∨ ∃ pre hwm details, (∀ e ∈ pre, PrefixEvent (s.get (a "session_id")) e) ∧
        (∃ j j', sub (s.get (a "next_message_id")) (i 1) j = .ok (hwm, j')) ∧
        out = list (pre ++ settlementEvents (s.get (a "session_id")) hwm (b "runtime_runaway_retired") details))
      (Settlement.retireRunaway s) := by
  unfold Settlement.retireRunaway
  track_walk
  all_goals first
    | exact Or.inl rfl
    | (rw [settlementEvents_native]
       refine Or.inr ⟨_, _, _, ?_, ⟨_, _, (hyp% sub _ _ _ = _)⟩, rfl⟩
       intro e mem
       simp only [List.mem_append, List.mem_map] at mem
       rcases mem with (⟨target, _, rfl⟩ | abort) | repair
       · exact Or.inl ⟨_, rfl⟩
       · split at abort
         · simp only [List.mem_singleton] at abort
           exact Or.inr (Or.inl ⟨_, abort⟩)
         · simp at abort
       · split at repair
         · simp only [List.mem_singleton] at repair
           exact Or.inr (Or.inr repair)
         · simp at repair)

theorem lookup_runaway_retirement :
    lookupOp queryTable (a "runaway_retirement") = some (fun state _ => Settlement.retireRunaway state) := rfl

theorem queryAsk_runaway_retirement (state x : Term) :
    Loop.queryAsk state "runaway_retirement" x = Settlement.retireRunaway state := by
  unfold Loop.queryAsk
  rw [lookup_runaway_retirement]

/-- `runaway_retirement_stops_continuation`: `guard_notice` commits the
answer of `runaway_retirement` when it is a list. After those events apply
to the state that the step read, `needs_transcript_continuation?` answers
`false`, unless a blocking card obligation fenced the ACK. -/
theorem runaway_retirement_stops_continuation {s t : Term} {events : List Term} {h p : Int} {j j' : List Term}
    (retire : Loop.queryAsk s "runaway_retirement" nil j = .ok (list events, j'))
    (positive : 0 < h) (next : s.get (a "next_message_id") = .integer (h + 1))
    (acked : s.get (a "last_ack_message_id") = .integer p)
    (land : ResidentBatch s events t) :
    Gate.SatA (· = false) (StateQuery.needsContinuation t) ∨
      (t.get (a "last_ack_message_id") = .integer p ∧ p < h) := by
  rw [queryAsk_runaway_retirement] at retire
  rcases retireRunaway_shape _ _ _ retire with none | ⟨pre, hwm, details, shape, ⟨k, k', position⟩, same⟩
  · cases none
  · rw [next, i, sub_integer, Int.add_sub_cancel] at position
    cases position
    cases same
    obtain ⟨u, first, rest⟩ := batch_split land
    have kept := batch_prefix first rfl shape
    have sid : u.get (a "session_id") = s.get (a "session_id") := kept "session_id" (by simp [watchedKeys])
    rw [← sid] at rest
    rcases settlement_tail (Or.inr (Or.inr (Or.inr (Or.inr rfl)))) positive
        ((kept "next_message_id" (by simp [watchedKeys])).trans next)
        ((kept "last_ack_message_id" (by simp [watchedKeys])).trans acked) rest with tail | fenced
    · exact Or.inl (tail_blocks_continuation tail)
    · exact Or.inr fenced

/-! ## The model-failure ACK -/

/-- `failureAck_final`: `llm_failure_ack?` answers `true` only for a source
that a notice already reached, or when `failure_reason` answered a reason:
a final model failure, or an exhausted model guard. A retryable failure
below the failure cap has no reason, so its source stays unacknowledged. -/
theorem failureAck_final {s : Term} :
    Gate.SatA (fun v => v = true →
        (((s.get (a "runtime_failure_reply")).get (b "notification_outcome")).isBinary = true) ∨
        ∃ reason j j', RoundQuery.failureReason s j = .ok (reason, j') ∧ (reason == nil) = false)
      (RoundQuery.llmFailureAck s) := by
  unfold RoundQuery.llmFailureAck
  track_walk
  all_goals first
    | (intro h; cases h)
    | (intro _; exact Or.inl ‹_›)
    | (intro _
       right
       exact ⟨_, _, _, (hyp% RoundQuery.failureReason s _ = _), by simpa using ‹¬(_ == nil) = true›⟩)

end VerifiedKernel.Session.Loop.TerminalTail
