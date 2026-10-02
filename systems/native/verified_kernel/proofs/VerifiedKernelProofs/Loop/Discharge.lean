import VerifiedKernelProofs.Loop.Shape
import VerifiedKernelProofs.Loop.WorkEmbedding
import VerifiedKernelProofs.Loop.DischargeFrame
import VerifiedKernel.Session.PendingRevision

/-!
# Property A: no false completion

A commit discharges when it moves the ack watermark or removes an obligation
key. `DischargeFrame` shows that a discharge needs an `ack` event or a
`provider_reply_obligation_resolved` event in the batch. This module shows
where such events come from in the running loop, and which facts hold there.

* Producer lemmas: one for each settlement query of `Settlement.lean`, for
  `finish_output`, and for the provider-wait yield. Each names the facts that
  the producer checks before it emits an ack or a resolution.
* `Justified`: the permitted reasons. This list is product policy.
* `loop_discharge_justified`: every discharge event of a commit of `Loop.step`
  has one of these reasons.
* M4: stored obligation targets carry only binary keys, so the two `kind`
  checks agree on them.

External assumptions stay in theorem hypotheses. H1: the commit applies to the
state that the step read. H2: the host-built events are the host's real
results; the kernel checks only their kind (`Justified.host`). H3: the round
snapshot is the transcript that the model request read (`failureAck`). The
host returns the machine that the kernel produced (`LoopChain`, see
`loop_chain_discharge_justified`).
-/

namespace VerifiedKernel.Session.LoopDischarge
open Data WorkConservation LoopProof

set_option Elab.async false
set_option maxHeartbeats 1000000

/-! ## Computations and kernel-built events -/

/-- A Boolean kernel computation returns `v` for some observations. -/
def Decides (m : KernelM Bool) (v : Bool) : Prop := ∃ j j', m j = .ok (v, j')

/-- A kernel computation returns a truthy term for some observations. -/
def Truthy (m : KernelM Term) : Prop := ∃ v, Returns m v ∧ v.truthy = true

/-- The private `Settlement.terminalEvents`: the settlement fact, `wait_clear`, `ack`, and idle. -/
def terminalEventsOf : Term → Term → Term → Term → List Term :=
  native_decl% "VerifiedKernel.Session.Settlement.terminalEvents"

/-- The settlement fact that `terminalEventsOf` puts first. -/
def settlementFact (sid hwm kind details : Term) : Term :=
  .map [(b "type", b "session_event"), (b "session_id", sid), (b "kind", kind),
    (b "event", details.put (b "settled_ack_hwm") hwm)]

def waitClearEvent (sid : Term) : Term := .map [(b "type", b "wait_clear"), (b "session_id", sid)]

theorem terminalEventsOf_eq (sid hwm kind details : Term) :
    terminalEventsOf sid hwm kind details =
      [settlementFact sid hwm kind details, waitClearEvent sid, ackEvent sid hwm, statusIdle sid] := by
  unfold terminalEventsOf
  unfold_native "VerifiedKernel.Session.Settlement.terminalEvents"
  rfl

/-! ## Events that cannot discharge -/

theorem get_type_head (v : Term) (rest : List (Term × Term)) :
    (Term.map ((b "type", v) :: rest)).get (b "type") = v := by
  simp only [Term.get, List.find?_cons]
  rfl

theorem not_discharge {e : Term} (ack : (e.get (b "type") == b "ack") = false)
    (resolve : (e.get (b "type") == b "provider_reply_obligation_resolved") = false) : ¬DischargeEvent e := by
  rintro (found | ⟨found, _⟩)
  · unfold AckEvent at found; rw [ack] at found; exact Bool.false_ne_true found
  · rw [resolve] at found; exact Bool.false_ne_true found

/-- A binary-keyed map whose first entry is a literal type other than the two discharge types. -/
theorem literal_quiet {t : String} {rest : List (Term × Term)}
    (keys : rest.all (fun pair => pair.1.isBinary) = true)
    (ack : (b t == b "ack") = false) (resolve : (b t == b "provider_reply_obligation_resolved") = false) :
    RawQuiet (Term.map ((b "type", b t) :: rest)) := by
  intro event j r read
  have binary : BinaryKeys (Term.map ((b "type", b t) :: rest)) := by
    simp only [BinaryKeys, List.all_cons, keys, Bool.and_true]
    rfl
  rw [shallowStringify_binary_keys binary read]
  exact not_discharge (by rw [get_type_head]; exact ack) (by rw [get_type_head]; exact resolve)

theorem ackEvent_keys (sid hwm : Term) : BinaryKeys (ackEvent sid hwm) := by
  simp [ackEvent, BinaryKeys, b, Term.text, Term.isBinary]

theorem ackEvent_ack (sid hwm : Term) : AckEvent (ackEvent sid hwm) := by
  unfold AckEvent ackEvent
  rw [get_type_head]
  decide

theorem statusIdle_quiet (sid : Term) : RawQuiet (statusIdle sid) :=
  literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

theorem waitClear_quiet (sid : Term) : RawQuiet (waitClearEvent sid) :=
  literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

theorem settlementFact_quiet (sid hwm kind details : Term) : RawQuiet (settlementFact sid hwm kind details) :=
  literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

/-- The only event of a settlement that can discharge is its ack. -/
theorem terminalEvents_discharge {sid hwm kind details raw : Term}
    (member : raw ∈ terminalEventsOf sid hwm kind details) (normal : NormalizesTo raw DischargeEvent) :
    raw = ackEvent sid hwm := by
  rw [terminalEventsOf_eq] at member
  obtain ⟨event, j, r, read, found⟩ := normal
  simp only [List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with same | same | same | same <;> subst raw
  · exact absurd found (settlementFact_quiet _ _ _ _ _ _ _ read)
  · exact absurd found (waitClear_quiet _ _ _ _ read)
  · rfl
  · exact absurd found (statusIdle_quiet _ _ _ _ read)

/-! ## Runaway retirement -/

/-- The facts behind one discharge event of `retireRunaway`. The retirement is
pending. The event is the ack at `next_message_id - 1`, or the resolution of a
key that the obligation table holds. -/
def Retired (s raw : Term) : Prop :=
  Decides (RoundQuery.runawayRetirementPending s) true ∧
  ((∃ sid nid hwm, FieldIs s "session_id" sid ∧ FieldIs s "next_message_id" nid ∧
      Returns (sub nid (i 1)) hwm ∧ raw = ackEvent sid hwm) ∨
   (∃ xs v, obligationMap s = .map xs ∧ (raw.get (b "obligation_key"), v) ∈ xs))

theorem retire_discharge {s output : Term} {j r : List Term}
    (call : Settlement.retireRunaway s j = .ok (output, r)) :
    output = nil ∨ ∃ events, output = list events ∧
      ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Retired s raw := by
  unfold Settlement.retireRunaway at call
  obtain ⟨pending, j1, hp, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  · right
    rename_i notPending
    have isPending : pending = true := by simpa using notPending
    subst pending
    obtain ⟨sid, j2, hs, call⟩ := bind_ok call
    obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨xs, j4, hx, call⟩ := bind_ok call
    obtain ⟨intent, _, _, call⟩ := bind_ok call
    obtain ⟨repair, _, _, call⟩ := bind_ok call
    obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨nid, j8, hn, call⟩ := bind_ok call
    obtain ⟨hwm, j9, hh, call⟩ := bind_ok call
    refine ⟨_, pure_ok call, ?_⟩
    intro raw member normal
    refine ⟨⟨_, _, hp⟩, ?_⟩
    have table : obligationMap s = .map xs := by
      have := obligationMap_isMap s
      revert hx
      cases obligationMap s <;> simp [entries, pure_ok_iff, fail_ok_iff]
      intro same _
      exact same.symm
    simp only [List.mem_append] at member
    rcases member with ((retire | abort) | repaired) | settled
    · right
      obtain ⟨target, present, rfl⟩ := List.mem_map.mp retire
      have key : (Term.map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", sid),
          (b "obligation_key", target.1), (b "outcome", b "blocked")]).get (b "obligation_key") = target.1 := by
        simp only [Term.get, List.find?_cons, show (b "type" == b "obligation_key") = false by decide,
          show (b "session_id" == b "obligation_key") = false by decide,
          show (b "obligation_key" == b "obligation_key") = true by decide]
        rfl
      exact ⟨xs, target.2, table, by rw [key]; exact present⟩
    · exfalso
      split at abort
      · simp only [List.mem_cons, List.not_mem_nil, or_false] at abort
        subst raw
        obtain ⟨event, _, _, read, found⟩ := normal
        exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
      · simp at abort
    · exfalso
      split at repaired
      · simp only [List.mem_cons, List.not_mem_nil, or_false] at repaired
        subst raw
        obtain ⟨event, _, _, read, found⟩ := normal
        exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
      · simp at repaired
    · left
      exact ⟨sid, nid, hwm, ⟨_, _, hs⟩, ⟨_, _, hn⟩, ⟨_, _, hh⟩, terminalEvents_discharge settled normal⟩

/-! ## Local settlement of a runtime failure -/

/-- The facts behind the ack of `guardLocalSettlement`. No retirement is
pending, a failure disposition is pending, and a destination exists only if the
guard failed with foreign work. The ack is at `next_message_id - 1`, and the
settlement fact records `notification_outcome = unavailable` with its reason. -/
def Disposed (s : Term) (events : List Term) : Prop :=
  Decides (RoundQuery.runawayRetirementPending s) false ∧
  Decides (RoundQuery.guardDispositionPending s) true ∧
  ∃ sid nid binding reason targets hwm details,
    FieldIs s "session_id" sid ∧ FieldIs s "next_message_id" nid ∧
    Returns (RoundQuery.guardDispositionBinding s nid) binding ∧
    Returns (RoundQuery.failureReason s) reason ∧ Returns (RoundQuery.guardCleanupTargets s) targets ∧
    (binding.isMap = true → reason = b "guard" ∧ targets.isList = false) ∧
    Returns (sub nid (i 1)) hwm ∧
    details.get (b "notification_outcome") = b "unavailable" ∧
    details.get (b "notification_reason") =
      b (if binding.isMap then "foreign_work_prevents_safe_notification" else "no_destination") ∧
    events = terminalEventsOf sid hwm (b "runtime_failure_disposed") details

theorem guardLocal_discharge {s output : Term} {j r : List Term}
    (call : Settlement.guardLocalSettlement s j = .ok (output, r)) :
    output = nil ∨ ∃ events, output = list events ∧ Disposed s events := by
  unfold Settlement.guardLocalSettlement at call
  obtain ⟨retire, _, hretire, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  rename_i notRetire
  simp only [Bool.not_eq_true] at notRetire
  subst retire
  obtain ⟨pending, _, hpending, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  rename_i isPending
  simp only [Bool.not_eq_true', Bool.not_eq_false] at isPending
  subst pending
  obtain ⟨nid, _, hnid, call⟩ := bind_ok call
  obtain ⟨binding, _, hbinding, call⟩ := bind_ok call
  obtain ⟨reason, _, hreason, call⟩ := bind_ok call
  obtain ⟨targets, _, htargets, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  rename_i cond
  obtain ⟨nid', _, hnid', call⟩ := bind_ok call
  obtain ⟨hwm, _, hhwm, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨sid, _, hsid, call⟩ := bind_ok call
  right
  refine ⟨_, pure_ok call, ⟨_, _, hretire⟩, ⟨_, _, hpending⟩, ?_⟩
  have same : nid' = nid := by
    simp only [field, fetch_ok_iff] at hnid hnid'
    rw [hnid.2.2.1, hnid'.2.2.1]
  subst nid'
  refine ⟨sid, nid, binding, reason, targets, hwm, _, ⟨_, _, hsid⟩, ⟨_, _, hnid⟩, ⟨_, _, hbinding⟩,
    ⟨_, _, hreason⟩, ⟨_, _, htargets⟩, fun map => ?_, ⟨_, _, hhwm⟩, ?_, ?_, rfl⟩
  · rw [map] at cond
    simp only [Bool.true_and, Bool.or_eq_true, not_or, Bool.not_eq_true] at cond
    have guard : (reason == b "guard") = true := by
      have := cond.1
      unfold bne at this
      cases h : (reason == b "guard") <;> simp_all
    exact ⟨beq_binary guard, cond.2⟩
  · simp +decide only [Term.get, List.find?_cons]
    rfl
  · simp +decide only [Term.get, List.find?_cons]
    rfl

/-! ## Terminal reply settlement -/

/-- The private `Settlement.validBinding`. -/
def validBindingOf : Term → Bool := native_decl% "VerifiedKernel.Session.Settlement.validBinding"

/-- The private `Settlement.successful`. -/
def successfulOf : Term → Bool := native_decl% "VerifiedKernel.Session.Settlement.successful"

/-- The binding is a channel-onboarding binding. -/
def onboardingBinding (binding : Term) : Bool :=
  binding.isMap && binding.get (b "kind") == b "channel_onboarding"

/-- The result that `Settlement.terminal` accepts as terminal for `binding`. -/
def terminalResult (binding result : Term) : Bool :=
  successfulOf result || (onboardingBinding binding &&
    [b "guidance", b "error", b "failed", b "completed"].contains (RoundQuery.valueOf result "status"))

/-- The facts that `Settlement.terminal` checks before it acks. The binding is
valid and still owns the activation, before and after the batch `pre`. After
`pre` the reply phase is clean, the session is ready (no blocking card, no
pending visible reply, empty materialization), and no reply call runs. The ack
is at the post-state `next_message_id - 1`. -/
def Delivered (s record result : Term) (pre : List Term) (raw : Term) : Prop :=
  validBindingOf (RoundQuery.valueOf record "terminal_reply") = true ∧
  terminalResult (RoundQuery.valueOf record "terminal_reply") result = true ∧
  Truthy (RoundQuery.bindingMatches s (RoundQuery.valueOf record "terminal_reply")) ∧
  ∃ sid next nid hwm, FieldIs s "session_id" sid ∧ Returns (Command.project s pre) next ∧
    Truthy (RoundQuery.bindingMatches next (RoundQuery.valueOf record "terminal_reply")) ∧
    Returns (ReplyQuery.phase next) (a "clean") ∧ Decides (Settlement.ready next) true ∧
    (∃ running, Returns (RoundQuery.replyRunning next) running ∧ running.truthy = false) ∧
    FieldIs next "next_message_id" nid ∧ Returns (sub nid (i 1)) hwm ∧ raw = ackEvent sid hwm

/-- The private `Settlement.completedRepair`. -/
def completedRepairOf : Term → Term := native_decl% "VerifiedKernel.Session.Settlement.completedRepair"

theorem completedRepair_quiet (sid : Term) : RawQuiet (completedRepairOf sid) := by
  unfold completedRepairOf
  unfold_native "VerifiedKernel.Session.Settlement.completedRepair"
  exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

theorem withoutWake_sub {events : List Term} {id raw : Term} (member : raw ∈ Settlement.withoutWake events id) :
    raw ∈ events := (List.mem_filter.mp member).1

theorem terminal_discharge {s record result output : Term} {input j r : List Term}
    (call : Settlement.terminal s record result input j = .ok (output, r)) :
    output = nil ∨ ∃ events, output = list events ∧ ∀ raw ∈ events, NormalizesTo raw DischargeEvent →
      raw ∈ input ∨ ∃ pre, Delivered s record result pre raw := by
  unfold Settlement.terminal at call
  obtain ⟨owned, _, hmatches, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  rename_i first
  obtain ⟨sid, _, hsid, call⟩ := bind_ok call
  obtain ⟨next, _, hnext, call⟩ := bind_ok call
  obtain ⟨after, _, hafter, call⟩ := bind_ok call
  obtain ⟨phase, _, hphase, call⟩ := bind_ok call
  obtain ⟨ready, _, hready, call⟩ := bind_ok call
  obtain ⟨running, _, hrunning, call⟩ := bind_ok call
  split at call
  · left; exact pure_ok call
  rename_i second
  obtain ⟨nid, _, hnid, call⟩ := bind_ok call
  obtain ⟨hwm, _, hhwm, call⟩ := bind_ok call
  right
  refine ⟨_, pure_ok call, ?_⟩
  intro raw member normal
  simp only [Bool.not_eq_true', Bool.and_eq_true, Bool.not_eq_false] at first second
  rcases List.mem_append.mp member with pre | settled
  · rcases List.mem_append.mp pre with kept | repair
    · exact Or.inl (withoutWake_sub kept)
    · exfalso
      split at repair
      · simp only [List.mem_cons, List.not_mem_nil, or_false] at repair
        subst raw
        obtain ⟨event, _, _, read, found⟩ := normal
        exact completedRepair_quiet _ _ _ _ read found
      · simp at repair
  · right
    refine ⟨_, first.1.1, first.1.2, ⟨_, ⟨_, _, hmatches⟩, first.2⟩, sid, next, nid, hwm, ⟨_, _, hsid⟩,
      ⟨_, _, hnext⟩, ⟨_, ⟨_, _, hafter⟩, second.1.1.1⟩, ?_, ⟨_, _, by rw [← second.1.2]; exact hready⟩,
      ⟨_, ⟨_, _, hrunning⟩, second.2⟩, ⟨_, _, hnid⟩, ⟨_, _, hhwm⟩, terminalEvents_discharge settled normal⟩
    have clean := atom_beq_true second.1.1.2
    subst clean
    exact ⟨_, _, hphase⟩

/-! ## Runtime failure settlement -/

theorem foldl_min_le {f : Term → Int} {init : Int} {xs : List Term} :
    xs.foldl (fun high m => min high (f m)) init ≤ init ∧
      ∀ m ∈ xs, xs.foldl (fun high m => min high (f m)) init ≤ f m := by
  induction xs generalizing init with
  | nil => simp
  | cons x rest ih =>
    simp only [List.foldl_cons, List.mem_cons]
    obtain ⟨le, each⟩ := ih (init := min init (f x))
    refine ⟨Int.le_trans le (Int.min_le_left _ _), fun m member => ?_⟩
    rcases member with same | later
    · subst same; exact Int.le_trans le (Int.min_le_right _ _)
    · exact each m later

/-- The facts behind the ack of `guardSettlement`. The committed failure attempt
is valid and not yet settled. The ack is below every later input and at or
above the attempt's assistant id, so this failure receipt acks no new input. -/
def FailureSettled (s : Term) (input : List Term) (raw : Term) : Prop :=
  ∃ binding, FieldIs s "runtime_failure_reply" binding ∧ validBindingOf binding = true ∧
    (binding.get (b "notification_outcome")).isBinary = false ∧
    ∃ (next acked msgs : Term) (messages : List Term) (sid : Term) (n : Int),
      Returns (Command.project s input) next ∧
      FieldIs next "last_ack_message_id" acked ∧
      integerValue acked < integerValue (binding.get (b "assistant_id")) ∧
      FieldIs next "messages" msgs ∧
      (∃ j j', StateQuery.properList (msgs.default (list [])) j = .ok (messages, j')) ∧
      integerValue (binding.get (b "assistant_id")) ≤ n ∧
      (∀ m ∈ messages, integerValue (RoundQuery.valueOf m "id") > integerValue (binding.get (b "assistant_id")) →
         [b "user", b "runtime", b "assistant"].contains (RoundQuery.valueOf m "role") = true →
         n ≤ integerValue (RoundQuery.valueOf m "id") - 1) ∧
      FieldIs s "session_id" sid ∧ raw = ackEvent sid (i n)

theorem integerValue_i (n : Int) : integerValue (i n) = n := rfl

set_option backward.split false in
theorem guardSettlement_discharge {s result output : Term} {input j r : List Term}
    (call : Settlement.guardSettlement s result input j = .ok (output, r)) :
    output = nil ∨ ∃ events, output = list events ∧ ∀ raw ∈ events, NormalizesTo raw DischargeEvent →
      raw ∈ input ∨ FailureSettled s input raw := by
  unfold Settlement.guardSettlement at call
  obtain ⟨binding, _, hbinding, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  rename_i validCond
  have valid : validBindingOf binding = true := by
    cases invalid : validBindingOf binding
    · exfalso
      apply validCond
      unfold validBindingOf at invalid
      simp [invalid]
    · rfl
  split at call
  · exact Or.inl (pure_ok call)
  rename_i unsettled
  try dsimp only at call
  split at call
  · exact Or.inl (pure_ok call)
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨next, _, hnext, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  try dsimp only at call
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨acked, _, hacked, call⟩ := bind_ok call
  split at call
  · right
    refine ⟨_, pure_ok call, fun raw member _ => Or.inl member⟩
  rename_i below
  obtain ⟨msgs, _, hmsgs, call⟩ := bind_ok call
  obtain ⟨messages, _, hmessages, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  try dsimp only at call
  split at call <;> (split at call; · exact Or.inl (pure_ok call)) <;>
    (rename_i high; obtain ⟨sid, _, hsid, call⟩ := bind_ok call; right) <;> split at call
  all_goals first
    | (obtain ⟨own, _, hown, call⟩ := bind_ok call
       split at call
       · -- Work remains: no ack.
         refine ⟨_, pure_ok call, fun raw member normal => ?_⟩
         simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at member
         rcases member with (kept | wait) | receipt | idle
         · exact Or.inl (withoutWake_sub kept)
         · exfalso
           split at wait
           · simp only [List.mem_cons, List.not_mem_nil, or_false] at wait
             subst raw
             obtain ⟨event, _, _, read, found⟩ := normal
             exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
           · simp at wait
         · exfalso
           subst raw
           obtain ⟨event, _, _, read, found⟩ := normal
           exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
         · exfalso
           subst raw
           obtain ⟨event, _, _, read, found⟩ := normal
           exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
       · refine ⟨_, pure_ok call, fun raw member normal => ?_⟩
         rcases List.mem_append.mp member with kept | settled
         · exact Or.inl (withoutWake_sub kept)
         · refine Or.inr ⟨binding, ⟨_, _, hbinding⟩, valid, by simpa using unsettled, next, acked, msgs, messages,
             sid, _, ⟨_, _, hnext⟩, ⟨_, _, hacked⟩, by omega, ⟨_, _, hmsgs⟩, ⟨_, _, hmessages⟩, ?_, ?_,
             ⟨_, _, hsid⟩, terminalEvents_discharge settled normal⟩
           · simp only [integerValue_i] at high
             omega
           · intro m present later role
             exact foldl_min_le.2 m (List.mem_filter.mpr ⟨present, by simp [later, role]⟩))
    | (refine ⟨_, pure_ok call, fun raw member normal => ?_⟩
       simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at member
       rcases member with (kept | repair) | settled
       · exact Or.inl kept
       · exfalso
         subst raw
         obtain ⟨event, _, _, read, found⟩ := normal
         exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
       · refine Or.inr ⟨binding, ⟨_, _, hbinding⟩, valid, by simpa using unsettled, next, acked, msgs, messages,
           sid, _, ⟨_, _, hnext⟩, ⟨_, _, hacked⟩, by omega, ⟨_, _, hmsgs⟩, ⟨_, _, hmessages⟩, ?_, ?_,
           ⟨_, _, hsid⟩, terminalEvents_discharge settled normal⟩
         · simp only [integerValue_i] at high
           omega
         · intro m present later role
           exact foldl_min_le.2 m (List.mem_filter.mpr ⟨present, by simp [later, role]⟩))
/-! ## Channel onboarding settlement -/

/-- The facts behind the ack of `Settlement.onboarding`. The source scope is a
channel-onboarding origin and the Router has authority. After the batch the
scope is unchanged, the session is ready, and no reply call runs. The ack is at
the post-state `next_message_id - 1`. -/
def OnboardingSettled (s : Term) (input : List Term) (router : Bool) (raw : Term) : Prop :=
  router = true ∧
  ∃ scope, Returns (RoundQuery.sourceScope s) scope ∧ scope.isMap = true ∧
    Decides (RoundQuery.channelOnboardingOrigin (scope.get (b "trusted_origin"))) true ∧
    ∃ next nextId scope' running sid hwm,
      Returns (Command.project s input) next ∧ FieldIs next "next_message_id" nextId ∧
      Returns (RoundQuery.sourceScope next) scope' ∧ (scope' != scope) = false ∧
      Decides (Settlement.ready next) true ∧ Returns (RoundQuery.replyRunning next) running ∧
      running.truthy = false ∧ FieldIs s "session_id" sid ∧ Returns (sub nextId (i 1)) hwm ∧
      raw = ackEvent sid hwm

set_option backward.split false in
theorem onboarding_discharge {s output : Term} {results input j r : List Term} {router : Bool}
    (call : Settlement.onboarding s results input router j = .ok (output, r)) :
    output = nil ∨ ∃ events, output = list events ∧ ∀ raw ∈ events, NormalizesTo raw DischargeEvent →
      raw ∈ input ∨ OnboardingSettled s input router raw := by
  unfold Settlement.onboarding at call
  obtain ⟨scope, _, hscope, call⟩ := bind_ok call
  obtain ⟨origin, _, horigin, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  rename_i entry
  obtain ⟨⟨map, onboard⟩, routed⟩ : (scope.isMap = true ∧ origin = true) ∧ router = true := by
    simpa only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_false] using entry
  rw [onboard] at horigin
  obtain ⟨source, _, hsource, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨next, _, hnext, call⟩ := bind_ok call
  obtain ⟨nextId, _, hnextId, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  try dsimp only at call
  obtain ⟨scope', _, hscope', call⟩ := bind_ok call
  obtain ⟨ready, _, hready, call⟩ := bind_ok call
  obtain ⟨running, _, hrunning, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  rename_i settle
  simp only [Bool.or_eq_true, Bool.not_eq_true', not_or, Bool.not_eq_true, Bool.not_eq_false] at settle
  obtain ⟨⟨⟨_, same⟩, isReady⟩, idle⟩ := settle
  rw [isReady] at hready
  obtain ⟨sid, _, hsid, call⟩ := bind_ok call
  obtain ⟨hwm, _, hhwm, call⟩ := bind_ok call
  right
  refine ⟨_, pure_ok call, fun raw member normal => ?_⟩
  simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with (kept | repair) | settled
  · exact Or.inl kept
  · exfalso
    subst raw
    obtain ⟨event, _, _, read, found⟩ := normal
    exact completedRepair_quiet _ _ _ _ read found
  · exact Or.inr ⟨routed, scope, ⟨_, _, hscope⟩, map, ⟨_, _, horigin⟩, next, nextId, scope', running, sid, hwm,
      ⟨_, _, hnext⟩, ⟨_, _, hnextId⟩, ⟨_, _, hscope'⟩, same, ⟨_, _, hready⟩, ⟨_, _, hrunning⟩, idle,
      ⟨_, _, hsid⟩, ⟨_, _, hhwm⟩, terminalEvents_discharge settled normal⟩
/-! ## Tool batch settlement -/

/-- The kernel justification of one settlement ack. -/
def SettleJustified (s : Term) (router : Bool) (raw : Term) : Prop :=
  (∃ record result pre, Delivered s record result pre raw) ∨ (∃ pre, FailureSettled s pre raw) ∨
    (∃ pre, OnboardingSettled s pre router raw)

/-- Every discharge event of `events` satisfies `Q`. -/
def AllQ (Q : Term → Prop) (events : List Term) : Prop :=
  ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Q raw

theorem allQ_append {Q : Term → Prop} {xs ys : List Term} (left : AllQ Q xs) (right : AllQ Q ys) :
    AllQ Q (xs ++ ys) := by
  intro raw member normal
  rcases List.mem_append.mp member with here | there
  · exact left raw here normal
  · exact right raw there normal

theorem allQ_quiet {Q : Term → Prop} {xs : List Term} (quiet : ∀ raw ∈ xs, RawQuiet raw) : AllQ Q xs := by
  intro raw member normal
  obtain ⟨event, _, _, read, found⟩ := normal
  exact absurd found (quiet raw member event _ _ read)

theorem guard_quiet {track unsettled reset : Term} {results : List Term}
    (unsettledQuiet : RawQuiet unsettled) (resetQuiet : RawQuiet reset) :
    ∀ raw ∈ (if track.truthy = true then
        [if (results.all fun result => result.get (a "status") == b "guidance") = true then unsettled else reset]
        else []), RawQuiet raw := by
  intro raw member
  split at member
  · simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    subst raw
    split
    · exact unsettledQuiet
    · exact resetQuiet
  · simp at member

theorem idle_quiet {c : Bool} {sid : Term} :
    ∀ raw ∈ (if c = true then [Term.map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]]
      else []), RawQuiet raw := by
  intro raw member
  split at member
  · simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    subst raw
    exact statusIdle_quiet sid
  · simp at member

theorem default_step {Q : Term → Prop} {x : Term} {events : List Term}
    (shape : x = nil ∨ ∃ out, x = list out ∧ AllQ Q out) (base : AllQ Q events) :
    ∃ out, x.default (list events) = list out ∧ AllQ Q out := by
  rcases shape with same | ⟨out, same, all⟩ <;> subst x
  · exact ⟨events, rfl, base⟩
  · exact ⟨out, rfl, all⟩

/-- A settlement producer's result: nil, or a list whose discharge events satisfy `Q`. -/
def Produced (Q : Term → Prop) (x : Term) : Prop := x = nil ∨ ∃ out, x = list out ∧ AllQ Q out

theorem terminal_produced {Q : Term → Prop} {s record result output : Term} {input j r : List Term}
    (base : AllQ Q input) (justify : ∀ pre raw, Delivered s record result pre raw → Q raw)
    (call : Settlement.terminal s record result input j = .ok (output, r)) : Produced Q output := by
  rcases terminal_discharge call with same | ⟨out, same, all⟩
  · exact Or.inl same
  · refine Or.inr ⟨out, same, fun raw member normal => ?_⟩
    rcases all raw member normal with kept | ⟨pre, facts⟩
    · exact base raw kept normal
    · exact justify pre raw facts

theorem guardSettlement_produced {Q : Term → Prop} {s result output : Term} {input j r : List Term}
    (base : AllQ Q input) (justify : ∀ raw, FailureSettled s input raw → Q raw)
    (call : Settlement.guardSettlement s result input j = .ok (output, r)) : Produced Q output := by
  rcases guardSettlement_discharge call with same | ⟨out, same, all⟩
  · exact Or.inl same
  · refine Or.inr ⟨out, same, fun raw member normal => ?_⟩
    rcases all raw member normal with kept | facts
    · exact base raw kept normal
    · exact justify raw facts

theorem onboarding_produced {Q : Term → Prop} {s output : Term} {results input j r : List Term} {router : Bool}
    (base : AllQ Q input) (justify : ∀ raw, OnboardingSettled s input router raw → Q raw)
    (call : Settlement.onboarding s results input router j = .ok (output, r)) : Produced Q output := by
  rcases onboarding_discharge call with same | ⟨out, same, all⟩
  · exact Or.inl same
  · refine Or.inr ⟨out, same, fun raw member normal => ?_⟩
    rcases all raw member normal with kept | facts
    · exact base raw kept normal
    · exact justify raw facts

/-- The tail of `Settlement.batch` after the first settlement choice. -/
theorem batch_tail {Q : Term → Prop} {s router output : Term} {events rest : List Term} {j r : List Term}
    (all : AllQ Q events) (justify : ∀ pre raw, OnboardingSettled s pre router.truthy raw → Q raw)
    (call : (if Settlement.settled events = true then pure (list events)
      else do
        let x ← Settlement.onboarding s rest events router.truthy
        pure (x.default (list events))) j = .ok (output, r)) :
    ∃ out, output = list out ∧ AllQ Q out := by
  split at call
  · exact ⟨events, pure_ok call, all⟩
  · obtain ⟨x, _, hx, call⟩ := bind_ok call
    rw [pure_ok call]
    exact default_step (onboarding_produced all (justify events) hx) all

set_option backward.split false in
theorem batch_discharge {s hostEvents stored track unsettled reset router output : Term} {j r : List Term}
    (unsettledQuiet : RawQuiet unsettled) (resetQuiet : RawQuiet reset)
    (call : Settlement.batch s (.tuple [hostEvents, stored, track, unsettled, reset, router]) j = .ok (output, r)) :
    ∃ events, output = list events ∧ AllQ (fun raw =>
      (∃ xs, hostEvents = .list xs ∧ raw ∈ xs) ∨ SettleJustified s router.truthy raw) events := by
  unfold Settlement.batch at call
  try dsimp only at call
  obtain ⟨host, _, hhost, call⟩ := bind_ok call
  have hostIs := (asList_ok_iff.mp hhost).1
  obtain ⟨results, _, hresults, call⟩ := bind_ok call
  try dsimp only at call
  obtain ⟨next, _, hnext, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨sid, _, hsid, call⟩ := bind_ok call
  try dsimp only at call
  have hostQ : AllQ (fun raw => (∃ xs, hostEvents = .list xs ∧ raw ∈ xs) ∨ SettleJustified s router.truthy raw) host :=
    fun raw member _ => Or.inl ⟨host, hostIs, member⟩
  have base := fun c => allQ_append (allQ_append hostQ (allQ_quiet (guard_quiet (track := track)
    (results := results) unsettledQuiet resetQuiet))) (allQ_quiet (idle_quiet (c := c) (sid := sid)))
  have justify : ∀ pre raw, OnboardingSettled s pre router.truthy raw →
      (∃ xs, hostEvents = .list xs ∧ raw ∈ xs) ∨ SettleJustified s router.truthy raw :=
    fun pre raw facts => Or.inr (Or.inr (Or.inr ⟨pre, facts⟩))
  split at call
  · obtain ⟨te, _, hte, call⟩ := bind_ok call
    have tp := terminal_produced (base _) (fun pre raw facts => Or.inr (Or.inl ⟨_, _, pre, facts⟩)) hte
    split at call
    · rename_i present
      obtain ⟨ev, _, hev, call⟩ := bind_ok call
      obtain ⟨evs, _, hevs, call⟩ := bind_ok call
      have same := pure_ok hev
      subst ev
      rcases tp with none | ⟨out, listed, all⟩
      · rw [none] at present
        exact absurd present (by decide)
      · subst te
        have := (asList_ok_iff.mp hevs).1
        cases this
        exact batch_tail all justify call
    · obtain ⟨g, _, hg, call⟩ := bind_ok call
      have gp := guardSettlement_produced (base _) (fun raw facts => Or.inr (Or.inr (Or.inl ⟨_, facts⟩))) hg
      obtain ⟨ev, _, hev, call⟩ := bind_ok call
      have same := pure_ok hev
      subst ev
      obtain ⟨evs, _, hevs, call⟩ := bind_ok call
      obtain ⟨out, listed, all⟩ := default_step gp (base _)
      rw [listed] at hevs
      have := (asList_ok_iff.mp hevs).1
      cases this
      exact batch_tail all justify call
  · obtain ⟨ev, _, hev, call⟩ := bind_ok call
    obtain ⟨evs, _, hevs, call⟩ := bind_ok call
    have same := pure_ok hev
    subst ev
    have := (asList_ok_iff.mp hevs).1
    cases this
    exact batch_tail (base _) justify call


/-! ## Final output -/

/-- The private `Presentation.finishOutput`. -/
def finishOutputOf : Term → Term → KernelM Term := native_decl% "VerifiedKernel.Session.Presentation.finishOutput"

theorem binaryKeys_put {m v : Term} {k : String} (keys : BinaryKeys m) : BinaryKeys (m.put (b k) v) := by
  cases m with
  | map entries =>
    unfold BinaryKeys at keys
    unfold BinaryKeys Term.put
    simp only [List.all_cons, Bool.and_eq_true, List.all_eq_true] at keys ⊢
    exact ⟨rfl, fun x member => keys x (List.mem_filter.mp member).1⟩
  | _ => rfl

theorem typed_quiet {e : Term} {t : String} (keys : BinaryKeys e) (typed : e.get (b "type") = b t)
    (ack : (b t == b "ack") = false) (resolve : (b t == b "provider_reply_obligation_resolved") = false) :
    RawQuiet e := by
  intro event j r read
  rw [shallowStringify_binary_keys keys read]
  exact not_discharge (by rw [typed]; exact ack) (by rw [typed]; exact resolve)

theorem bne_false_atom {t : Term} {k : String} (h : ¬(t != a k) = true) : t = a k := by
  unfold bne at h
  exact atom_beq_true (by simpa using h)

set_option backward.split false in
theorem transitionEvents_discharge {decision sid hwm : Term} {out : List Term} {j r : List Term}
    (call : Presentation.transitionEvents decision sid hwm j = .ok (out, r)) :
    ∀ raw ∈ out, NormalizesTo raw DischargeEvent →
      raw = ackEvent sid hwm ∧ ∃ attempts, decision = .tuple [a "exhausted", attempts] := by
  unfold Presentation.transitionEvents at call
  repeat' first
    | (execution_head_is call "Pure.pure"; have same := pure_ok call; subst out)
    | (execution_head_is call "Bind.bind"; obtain ⟨_, _, prior, call⟩ := bind_ok call
       try (execution_head_is prior "VerifiedKernel.fail"; exact (fail_ok prior).elim))
    | (execution_head_is call "VerifiedKernel.fail"; exact (fail_ok call).elim)
    | split at call
    | dsimp only at call
  all_goals intro raw member normal
  all_goals simp only [List.mem_cons, List.not_mem_nil, or_false] at member
  all_goals first
    | (subst raw
       exfalso
       obtain ⟨event, _, _, read, found⟩ := normal
       refine typed_quiet (t := "visible_reply_repair") ?_ ?_ (by decide) (by decide) _ _ _ read found
       · repeat' apply binaryKeys_put
         simp [BinaryKeys, b, Term.text, Term.isBinary]
       · simp +decide only [Term.put, Term.get, List.filter_cons, List.filter_nil, List.find?_cons]
         rfl)
    | (have negated := ‹¬(_ != a "exhausted") = true›
       have exhausted := bne_false_atom negated
       rcases member with same | same | same | same <;> subst raw
       · exfalso
         obtain ⟨event, _, _, read, found⟩ := normal
         refine typed_quiet (t := "visible_reply_repair") ?_ ?_ (by decide) (by decide) _ _ _ read found
         · repeat' apply binaryKeys_put
           simp [BinaryKeys, b, Term.text, Term.isBinary]
         · simp +decide only [Term.put, Term.get, List.filter_cons, List.filter_nil,
             List.find?_cons]
           rfl
       · exfalso
         obtain ⟨event, _, _, read, found⟩ := normal
         exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found
       · exact ⟨rfl, _, by rw [exhausted]⟩
       · exfalso
         obtain ⟨event, _, _, read, found⟩ := normal
         exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read found)

/-- The facts behind an ack of `finish_output`. Either the model settled the
turn in a clean phase with no blocking card, or a repair phase ran out of its
repair budget. The ack is at the record's `hwm` argument. -/
def FinalSettled (s hwm phase terminal raw : Term) : Prop :=
  ∃ sid, FieldIs s "session_id" sid ∧ raw = ackEvent sid hwm ∧
    ((Presentation.required phase = false ∧ terminal.truthy = true ∧
        ∃ count, Returns (ReplyQuery.blockingObligationCount s) count ∧ ¬integerValue count > 0) ∨
     (Presentation.required phase = true ∧ ∃ decision attempts,
        Returns (Presentation.policy (.tuple [a "no_tool_transition", phase])) decision ∧
        decision = .tuple [a "exhausted", attempts]))

theorem ite_cases {c : Prop} [Decidable c] {x y : Term} {P : Term → Prop} (hx : c → P x) (hy : ¬c → P y) :
    P (if c then x else y) := by
  split
  · exact hx ‹_›
  · exact hy ‹_›

theorem mem_ite_nil {c : Prop} [Decidable c] {x raw : Term} (member : raw ∈ (if c then [] else [x])) : raw = x := by
  split at member
  · simp at member
  · simpa using member

set_option backward.split false in
theorem finishOutput_discharge {s leading assistant hwm phase terminal unsettled output : Term} {j r : List Term}
    (unsettledQuiet : RawQuiet unsettled)
    (call : finishOutputOf s (.tuple [leading, assistant, hwm, phase, terminal, unsettled]) j = .ok (output, r)) :
    ∃ events fopts plan, output = .tuple [a "ok", list events, fopts, plan] ∧
      AllQ (fun raw => (∃ xs, leading = .list xs ∧ raw ∈ xs) ∨ raw = assistant ∨
        FinalSettled s hwm phase terminal raw) events := by
  revert call
  unfold finishOutputOf
  unfold_native "VerifiedKernel.Session.Presentation.finishOutput"
  intro call
  try dsimp only at call
  obtain ⟨sid, _, hsid, call⟩ := bind_ok call
  obtain ⟨xs, _, hxs, call⟩ := bind_ok call
  have leadingIs := (asList_ok_iff.mp hxs).1
  have baseQ : AllQ (fun raw => (∃ xs, leading = .list xs ∧ raw ∈ xs) ∨ raw = assistant ∨
      FinalSettled s hwm phase terminal raw) (xs ++ [assistant]) := by
    intro raw member _
    rcases List.mem_append.mp member with here | there
    · exact Or.inl ⟨xs, leadingIs, here⟩
    · simp only [List.mem_cons, List.not_mem_nil, or_false] at there
      exact Or.inr (Or.inl there)
  try dsimp only at call
  split at call
  · rename_i clean
    obtain ⟨count, _, hcount, call⟩ := bind_ok call
    refine ⟨_, _, _, pure_ok call, allQ_append baseQ ?_⟩
    intro raw member normal
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with same | same <;> subst raw
    · revert normal
      refine ite_cases (P := fun t => NormalizesTo t DischargeEvent → (∃ xs, leading = .list xs ∧ t ∈ xs) ∨
        t = assistant ∨ FinalSettled s hwm phase terminal t) (fun settled normal => ?_) (fun _ normal => ?_)
      · refine Or.inr (Or.inr ⟨sid, ⟨_, _, hsid⟩, rfl, Or.inl ⟨?_, ?_, count, ⟨_, _, hcount⟩, ?_⟩⟩)
        · simpa using clean
        · simp only [Bool.and_eq_true, Bool.not_eq_true'] at settled
          exact settled.1
        · simp only [Bool.and_eq_true, Bool.not_eq_true', Bool.and_eq_false_iff, decide_eq_false_iff_not] at settled
          rcases settled.2 with notTerminal | small
          · rw [settled.1] at notTerminal; exact absurd notTerminal (by decide)
          · exact small
      · obtain ⟨event, _, _, read, found⟩ := normal
        exact absurd found (unsettledQuiet event _ _ read)
    · obtain ⟨event, _, _, read, found⟩ := normal
      exact absurd found (literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) _ _ _ read)
  · rename_i repair
    obtain ⟨decision, _, hdecision, call⟩ := bind_ok call
    obtain ⟨extra, _, hextra, call⟩ := bind_ok call
    refine ⟨_, _, _, pure_ok call, allQ_append (allQ_append baseQ ?_) ?_⟩
    · intro raw member normal
      obtain ⟨same, attempts, exhausted⟩ := transitionEvents_discharge hextra raw member normal
      exact Or.inr (Or.inr ⟨sid, ⟨_, _, hsid⟩, same, Or.inr ⟨by simpa using repair, decision, attempts,
        ⟨_, _, hdecision⟩, exhausted⟩⟩)
    · apply allQ_quiet
      intro raw member
      rw [mem_ite_nil member]
      exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

/-! ## Query registrations and quiet producers -/

/-- The private `Settlement.guardPrepare`. -/
def guardPrepareOf : Term → Term → KernelM Term := native_decl% "VerifiedKernel.Session.Settlement.guardPrepare"
/-- The private `Settlement.guardCleanupEvents`. -/
def guardCleanupEventsOf : Term → Term → KernelM Term :=
  native_decl% "VerifiedKernel.Session.Settlement.guardCleanupEvents"

-- These equations restate the `WorkEmbedding` answers. Each proof by `rfl` looks the query up
-- in the whole query table again.
theorem ask_retire (s : Term) : Loop.queryAsk s "runaway_retirement" nil = Settlement.retireRunaway s :=
  ask_runaway_retirement s nil
theorem ask_local (s : Term) :
    Loop.queryAsk s "guard_failure_local_settlement" nil = Settlement.guardLocalSettlement s :=
  ask_guard_local s nil
theorem ask_prepare (s x : Term) : Loop.queryAsk s "guard_failure_prepare" x = guardPrepareOf s x :=
  ask_guard_prepare s x
theorem ask_cleanup (s x : Term) : Loop.queryAsk s "guard_failure_cleanup_events" x = guardCleanupEventsOf s x :=
  ask_guard_cleanup s x
theorem ask_finish (s x : Term) : Loop.queryAsk s "finish_output" x = finishOutputOf s x :=
  ask_finish_output s x
theorem ask_batch (s x : Term) : Loop.queryAsk s "settle_tool_batch" x = Settlement.batch s x :=
  ask_settle s x
theorem ask_timeout (s x : Term) : Loop.queryAsk s "wait_timeout_event" x = Command.waitTimeout s x :=
  ask_wait_timeout s x
theorem ask_failure (s : Term) :
    Loop.queryAsk s "llm_failure_ack?" nil = (do return Term.bool (← RoundQuery.llmFailureAck s)) := by rfl
theorem ask_onboarding (s results events router : Term) :
    Loop.queryAsk s "onboarding_settlement" (.tuple [results, events, router]) =
      (do Settlement.onboarding s (← asList results) (← asList events) router.truthy) :=
  ask_onboarding_eq s _

syntax "leaf_walk" ident : tactic
macro_rules
  | `(tactic| leaf_walk $h:ident) => `(tactic|
    repeat' first
      | (execution_head_is $h "Pure.pure"; have same := pure_ok $h; subst same)
      | (execution_head_is $h "Bind.bind"; obtain ⟨_, _, prior, $h:ident⟩ := bind_ok $h
         try (execution_head_is prior "VerifiedKernel.fail"; exact (fail_ok prior).elim))
      | (execution_head_is $h "VerifiedKernel.fail"; exact (fail_ok $h).elim)
      | split at $h:ident
      | dsimp only at $h:ident)

set_option backward.split false in
theorem guardPrepare_quiet {s x out : Term} {j r : List Term} (call : guardPrepareOf s x j = .ok (out, r))
    (map : out.isMap = true) : RawQuiet out := by
  revert call
  unfold guardPrepareOf
  unfold_native "VerifiedKernel.Session.Settlement.guardPrepare"
  intro call
  leaf_walk call
  all_goals first
    | exact absurd map (by decide)
    | exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

set_option backward.split false in
theorem guardCleanup_quiet {s x out : Term} {j r : List Term} (call : guardCleanupEventsOf s x j = .ok (out, r)) :
    out = nil ∨ ∃ xs, out = list xs ∧ ∀ raw ∈ xs, RawQuiet raw := by
  revert call
  unfold guardCleanupEventsOf
  unfold_native "VerifiedKernel.Session.Settlement.guardCleanupEvents"
  intro call
  leaf_walk call
  all_goals first
    | exact Or.inl rfl
    | (right; refine ⟨_, rfl, fun raw member => ?_⟩
       first
         | (simp at member; done)
         | (simp only [List.mem_cons, List.not_mem_nil, or_false] at member
            subst raw
            split
            · exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)
            · exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide))
         | (obtain ⟨id, _, same⟩ := List.mem_map.mp member
            subst raw
            split
            · exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)
            · exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)))

set_option backward.split false in
theorem waitTimeout_quiet {s x out : Term} {j r : List Term} (call : Command.waitTimeout s x j = .ok (out, r))
    (present : (out == nil) = false) : RawQuiet out := by
  unfold Command.waitTimeout at call
  leaf_walk call
  all_goals first
    | exact absurd present (by decide)
    | exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)

/-- Why `llm_failure_ack?` answers true. Either an earlier failure notice
already has an outcome and no reply work remains, or the model failure is final
(`failureReason` is present), it has no destination for a notice, and no send
is pending. A retryable failure keeps its source. -/
def FailureAckReason (s : Term) : Prop :=
  ∃ attempt, FieldIs s "runtime_failure_reply" attempt ∧
    (((attempt.get (b "notification_outcome")).isBinary = true ∧
        (∃ running, Returns (RoundQuery.replyRunning s) running ∧ running.truthy = false) ∧
        (∃ count, Returns (ReplyQuery.blockingObligationCount s) count ∧ integerValue count = 0) ∧
        Decides (StateQuery.pendingVisibleReply s) false) ∨
     ((attempt.get (b "notification_outcome")).isBinary = false ∧ ∃ nid binding,
        FieldIs s "next_message_id" nid ∧ Returns (RoundQuery.guardDispositionBinding s nid) binding ∧
        binding.isMap = false ∧
        (∃ reason, Returns (RoundQuery.failureReason s) reason ∧ (reason == nil) = false) ∧
        Decides (StateQuery.pendingVisibleReply s) false))

theorem failureAck_reason {s answer : Term} (answered : Answers s "llm_failure_ack?" nil answer)
    (truthy : answer.truthy = true) : FailureAckReason s := by
  obtain ⟨j, j', call⟩ := answered
  rw [ask_failure] at call
  obtain ⟨decided, _, hdecided, call⟩ := bind_ok call
  have same := pure_ok call
  subst answer
  have yes : decided = true := by cases decided <;> simp_all [Term.bool, Term.truthy]
  subst yes
  unfold RoundQuery.llmFailureAck at hdecided
  obtain ⟨attempt, _, hattempt, hdecided⟩ := bind_ok hdecided
  refine ⟨attempt, ⟨_, _, hattempt⟩, ?_⟩
  split at hdecided
  · rename_i notified
    obtain ⟨running, _, hrunning, hdecided⟩ := bind_ok hdecided
    obtain ⟨count, _, hcount, hdecided⟩ := bind_ok hdecided
    obtain ⟨pending, _, hpending, hdecided⟩ := bind_ok hdecided
    have result := (pure_ok hdecided).symm
    simp only [Bool.and_eq_true, Bool.not_eq_true', beq_iff_eq] at result
    obtain ⟨⟨idle, zero⟩, none⟩ := result
    rw [none] at hpending
    exact Or.inl ⟨notified, ⟨running, ⟨_, _, hrunning⟩, idle⟩, ⟨count, ⟨_, _, hcount⟩, zero⟩,
      ⟨_, _, hpending⟩⟩
  · rename_i unnotified
    obtain ⟨nid, _, hnid, hdecided⟩ := bind_ok hdecided
    obtain ⟨binding, _, hbinding, hdecided⟩ := bind_ok hdecided
    split at hdecided
    · have result := pure_ok hdecided
      simp at result
    rename_i unbound
    obtain ⟨reason, _, hreason, hdecided⟩ := bind_ok hdecided
    split at hdecided
    · have result := pure_ok hdecided
      simp at result
    rename_i present
    obtain ⟨pending, _, hpending, hdecided⟩ := bind_ok hdecided
    have result := (pure_ok hdecided).symm
    simp only [Bool.not_eq_true'] at result
    rw [result] at hpending
    exact Or.inr ⟨by simpa using unnotified, nid, binding, ⟨_, _, hnid⟩, ⟨_, _, hbinding⟩,
      by simpa using unbound, ⟨reason, ⟨_, _, hreason⟩, by simpa using present⟩, ⟨_, _, hpending⟩⟩
/-! ## Justification of a loop commit -/

/-- An event that the host built and the kernel committed after it checked only
the event kind. -/
def HostBuilt (event raw : Term) : Prop :=
  (∃ record, event = .tuple [a "record", record] ∧
    (raw ∈ wrap (mkey record "leading") ∨ raw = mkey record "assistant" ∨ raw ∈ intentEvents record)) ∨
  (∃ hostEvents hwm base stored, event = .tuple [a "results_stored", hostEvents, hwm, base, stored] ∧
    raw ∈ wrap hostEvents)

/-- The permitted reasons for one discharge event of a loop commit. This list
is product policy and needs owner review. -/
inductive Justified (s machine event raw : Term) : Prop where
  /-- H2: the host built the event and the kernel checks only its kind. The
  host sends two such discharge events. First, the `results_stored` events and
  the planned admission events come from the kernel query `finish_tool_batch`,
  which the host runs in `store_results` and in the planned admission
  (`round.ex` near lines 1827 and 2316). That query acks for a contained
  scheduled-task failure (`Presentation.finishToolBatch`) and for an exhausted
  repair (`Presentation.transitionEvents`). Second, the host adds a
  resolution for each Slack visible send (`ProviderReplyObligation.resolution_events`). -/
  | host (built : HostBuilt event raw)
  /-- A model failure acks the snapshot transcript because `llm_failure_ack?`
  holds after the failure is recorded. -/
  | failureAck (sid hwm eventId info created projected answer : Term)
      (project : Returns (Command.project s [failedEvent eventId info hwm created, statusIdle sid]) projected)
      (answered : Answers projected "llm_failure_ack?" nil answer) (truthy : answer.truthy = true)
      (reason : FailureAckReason projected) (is : raw = failureAckEvent sid hwm)
      (snapshot : hwm = i (ackHwmOf (failureRound machine event)))
  /-- A runaway guard retires the activation. -/
  | retired (facts : Retired s raw)
  /-- A stopped activation settles without a provider destination. -/
  | disposed (events : List Term) (facts : Disposed s events) (member : raw ∈ events)
      (ack : ∃ sid hwm, raw = ackEvent sid hwm)
  /-- The terminal reply was delivered to the binding that owns the activation. -/
  | delivered (record result : Term) (pre : List Term) (facts : Delivered s record result pre raw)
  /-- A committed runtime failure notice is settled. -/
  | failureSettled (pre : List Term) (facts : FailureSettled s pre raw)
  /-- A channel-onboarding activation settles. -/
  | onboarding (pre : List Term) (router : Bool) (facts : OnboardingSettled s pre router raw)
  /-- The model settled a final output, or a repair phase ran out of budget. -/
  | finalSettled (hwm phase terminal : Term) (facts : FinalSettled s hwm phase terminal raw)

theorem literal_raw_quiet {raw : Term} {t : String} {rest : List (Term × Term)}
    (same : raw = Term.map ((b "type", b t) :: rest)) (keys : rest.all (fun pair => pair.1.isBinary) = true)
    (ack : (b t == b "ack") = false) (resolve : (b t == b "provider_reply_obligation_resolved") = false)
    (normal : NormalizesTo raw DischargeEvent) : False := by
  subst raw
  obtain ⟨event, _, _, read, found⟩ := normal
  exact literal_quiet keys ack resolve event _ _ read found

theorem quiet_normal {raw : Term} (quiet : RawQuiet raw) (normal : NormalizesTo raw DischargeEvent) : False := by
  obtain ⟨event, _, _, read, found⟩ := normal
  exact quiet event _ _ read found

theorem list_ne_nil {xs : List Term} : list xs ≠ nil := by
  intro h
  cases h

/-- Every discharge event of a loop commit has a permitted justification. -/
theorem commit_events_justified {s machine event opts mode raw : Term} {events : List Term}
    (source : CommitSource s machine event events opts mode)
    (carried : mkey machine "entry" = b "wait_timeout" → RawQuiet (mkey machine "timeout_event"))
    (member : raw ∈ events) (normal : NormalizesTo raw DischargeEvent) : Justified s machine event raw := by
  cases source with
  | overflow sid hwm eventId created seq compacted recovery =>
    exfalso
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with same | same
    · exact literal_raw_quiet same (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal
    · exact quiet_normal (by rw [same]; exact statusIdle_quiet sid) normal
  | modelFailure sid hwm raw' info eventId created projected answer entry session ackHwm retry project ackQuery =>
    simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with (same | same) | acked
    · exact absurd normal (fun normal =>
        literal_raw_quiet same (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal)
    · exact absurd normal (fun normal => quiet_normal (by rw [same]; exact statusIdle_quiet sid) normal)
    · split at acked
      · rename_i truthy
        simp only [List.mem_cons, List.not_mem_nil, or_false] at acked
        exact .failureAck sid hwm eventId info created projected answer project ackQuery truthy
          (failureAck_reason ackQuery truthy) acked ackHwm
      · simp at acked
  | boundaryIdle sid p entry phase named session =>
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    exact absurd normal (fun normal => quiet_normal (by rw [member]; exact statusIdle_quiet sid) normal)
  | guardRetire events entry retire =>
    obtain ⟨j, j', call⟩ := retire
    rw [ask_retire] at call
    rcases retire_discharge call with none | ⟨out, same, facts⟩
    · exact absurd none list_ne_nil
    · cases same
      exact .retired (facts raw member normal)
  | guardLocal retire events entry retireAnswer retireNotList settle =>
    obtain ⟨j, j', call⟩ := settle
    rw [ask_local] at call
    rcases guardLocal_discharge call with none | ⟨out, same, facts⟩
    · exact absurd none list_ne_nil
    · injection same with same
      subst out
      have kept := facts
      obtain ⟨_, _, sid, _, _, _, _, hwm, details, _, _, _, _, _, _, _, _, _, listed⟩ := kept
      refine .disposed events facts member ⟨sid, hwm, ?_⟩
      rw [listed] at member
      exact terminalEvents_discharge member normal
  | notice retire settle reply sid aid disposition callId attempt entry retireAnswer retireNotList
      settleAnswer settleNotList replyField noReply config session nextId dispositionAnswer dispositionMap
      prepare attemptMap =>
    exfalso
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with same | same
    · exact literal_raw_quiet same (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal
    · obtain ⟨j, j', call⟩ := prepare
      rw [ask_prepare] at call
      exact quiet_normal (by rw [same]; exact guardPrepare_quiet call attemptMap) normal
  | noticeCleanup now events entry cleanup nonempty =>
    exfalso
    obtain ⟨j, j', call⟩ := cleanup
    rw [ask_cleanup] at call
    rcases guardCleanup_quiet call with none | ⟨out, same, quiet⟩
    · exact list_ne_nil none
    · cases same
      exact quiet_normal (quiet raw member) normal
  | finalOutput record nmid sid aid unsettledId created tag outputEvents fopts plan onboarding events entry
      phase nextId fresh checked aidIs session finish onboardingCase committed =>
    obtain ⟨j, j', call⟩ := finish
    rw [ask_finish] at call
    obtain ⟨finished, fopts', plan', shape, all⟩ := finishOutput_discharge
      (literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)) call
    cases shape
    have fromFinish : ∀ raw, raw ∈ finished → NormalizesTo raw DischargeEvent → Justified s machine event raw := by
      intro raw member normal
      rcases all raw member normal with ⟨xs, leading, present⟩ | assistant | facts
      · exact .host (Or.inl ⟨record, entry, Or.inl (by rw [leading]; exact present)⟩)
      · exact .host (Or.inl ⟨record, entry, Or.inr (Or.inl assistant)⟩)
      · exact .finalSettled _ _ _ facts
    rcases onboardingCase with ⟨_, router, answer⟩ | ⟨_, none⟩
    · split at committed
      · obtain ⟨j, j', call⟩ := answer
        rw [ask_onboarding] at call
        obtain ⟨_, _, empty, call⟩ := bind_ok call
        obtain ⟨input, _, hinput, call⟩ := bind_ok call
        have same := (asList_ok_iff.mp hinput).1
        cases same
        rcases onboarding_discharge call with none | ⟨out, listed, facts⟩
        · rw [none] at committed; cases committed
        · rw [listed] at committed
          cases committed
          rcases facts raw member normal with kept | settled
          · exact fromFinish raw kept normal
          · exact .onboarding _ _ settled
      · cases committed
        exact fromFinish raw member normal
    · subst onboarding
      cases committed
      exact fromFinish raw member normal
  | intent record nmid entry phase nextId fresh checked roundStart roundCommitted =>
    exact .host (Or.inl ⟨record, entry, Or.inr (Or.inr member)⟩)
  | settle hostEvents hwm base stored nmid sid unsettledId unsettledAt resetId resetAt router events entry
      phase nextId fresh checked session settleAnswer =>
    obtain ⟨j, j', call⟩ := settleAnswer
    rw [ask_batch] at call
    obtain ⟨out, same, all⟩ := batch_discharge
      (literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide))
      (literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)) call
    cases same
    rcases all raw member normal with ⟨xs, listed, present⟩ | ⟨record, result, pre, facts⟩ | ⟨pre, facts⟩ |
        ⟨pre, facts⟩
    · exact .host (Or.inr ⟨hostEvents, hwm, base, stored, entry, by rw [listed]; exact present⟩)
    · exact .delivered record result pre facts
    · exact .failureSettled pre facts
    · exact .onboarding pre _ facts
  | waitExtend sid wait busy now ceiling next entry session waitField ceilingIs decided =>
    exfalso
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    exact literal_raw_quiet member (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal
  | waitTimeoutFresh waitId source timeout entry answer present =>
    exfalso
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    subst raw
    obtain ⟨j, j', call⟩ := answer
    rw [ask_timeout] at call
    exact quiet_normal (waitTimeout_quiet call present) normal
  | waitTimeoutCarried value entry timer =>
    exfalso
    simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    subst raw
    exact quiet_normal (carried timer) normal


theorem hwmEvents_quiet (hwm : Term) : ∀ raw ∈ PendingRevision.hwmEvents hwm, RawQuiet raw := by
  intro raw member
  unfold PendingRevision.hwmEvents at member
  split at member
  · simp only [List.mem_cons, List.not_mem_nil, or_false] at member
    subst raw
    exact literal_quiet (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide)
  · simp at member

/-- A discharging commit of a commit source: some event of the commit is a
discharge event, and every such event has a permitted justification. `extra`
is the host's watermark tail, which must not discharge. -/
theorem commit_discharge_justified {s machine event opts mode t : Term} {events extra : List Term}
    (source : CommitSource s machine event events opts mode)
    (carried : mkey machine "entry" = b "wait_timeout" → RawQuiet (mkey machine "timeout_event"))
    (extraQuiet : ∀ raw ∈ extra, RawQuiet raw)
    (apply : ResidentBatch s (events ++ extra) t) (discharges : Discharges s t) :
    (∃ raw ∈ events, NormalizesTo raw DischargeEvent) ∧
      ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Justified s machine event raw := by
  refine ⟨?_, fun raw member normal => commit_events_justified source carried member normal⟩
  obtain ⟨raw, member, normal⟩ := resident_batch_discharge_source apply discharges
  rcases List.mem_append.mp member with here | there
  · exact ⟨raw, here, normal⟩
  · exact absurd normal (fun normal => quiet_normal (extraQuiet raw there) normal)

/-- Property A for one step of the loop. Suppose the host applies a commit of
`Loop.step` to the state that the step read (H1), and the application lowers
the ack watermark or removes an obligation key. Then the commit carries an ack
or a resolution, and each such event has a permitted justification.
`carried` says that the timeout event that the machine carries for a
`wait_timeout` entry is quiet. `loop_chain_discharge_justified` proves it for
every machine of a `LoopChain`. -/
theorem loop_discharge_justified {s machine event machine' opts mode hwm t : Term}
    {effects events : List Term}
    (step : StepOK Loop.queryAsk s machine event machine' effects)
    (committed : commitEffect events opts mode ∈ effects)
    (carried : mkey machine "entry" = b "wait_timeout" → RawQuiet (mkey machine "timeout_event"))
    (apply : ResidentBatch s (events ++ PendingRevision.hwmEvents hwm) t) (discharges : Discharges s t) :
    (∃ raw ∈ events, NormalizesTo raw DischargeEvent) ∧
      ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Justified s machine event raw :=
  commit_discharge_justified (step_commit_source step committed) carried (hwmEvents_quiet hwm) apply discharges

/-- A send that did not reach a terminal result cannot justify a delivery. -/
theorem failed_send_not_delivered {s record result raw : Term} {pre : List Term}
    (failed : terminalResult (RoundQuery.valueOf record "terminal_reply") result = false) :
    ¬Delivered s record result pre raw := by
  intro facts
  rw [facts.2.1] at failed
  cases failed


/-- A failed send keeps the turn open: when the tool result is not terminal for
the binding, `Settlement.terminal` settles nothing. -/
theorem failed_send_keeps_turn_open {s record result output : Term} {input j r : List Term}
    (failed : terminalResult (RoundQuery.valueOf record "terminal_reply") result = false)
    (call : Settlement.terminal s record result input j = .ok (output, r)) : output = nil := by
  unfold Settlement.terminal at call
  obtain ⟨owned, _, _, call⟩ := bind_ok call
  split at call
  · exact pure_ok call
  · rename_i settles
    exfalso
    apply settles
    unfold terminalResult successfulOf onboardingBinding at failed
    simp only [Bool.not_eq_true', Bool.and_eq_false_iff]
    exact Or.inl (Or.inr failed)

/-! ## The provider-wait yield write -/

theorem ask_yield (s x : Term) :
    Loop.queryAsk s "provider_wait_yield_events" x = StateQuery.waitYieldEvents s x :=
  LoopProof.ask_yield s x

/-- The facts behind the ack of a provider-wait yield. A `wait_for` wait yields
to queued human input. The ack is at `next_message_id - 1` and closes the
waiting turn as blocked. No reply is sent for it. -/
def Yielded (s raw : Term) : Prop :=
  Decides (StateQuery.yieldableProviderWait s) true ∧
  ∃ sid nid hwm, FieldIs s "session_id" sid ∧ FieldIs s "next_message_id" nid ∧
    Returns (sub nid (i 1)) hwm ∧ raw = ackEvent sid hwm

set_option backward.split false in
theorem yield_discharge {s expected out : Term} {j r : List Term}
    (call : StateQuery.waitYieldEvents s expected j = .ok (out, r)) :
    ∃ events, out = list events ∧ ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Yielded s raw := by
  unfold StateQuery.waitYieldEvents at call
  obtain ⟨yieldable, _, hyieldable, call⟩ := bind_ok call
  split at call
  · exact ⟨[], pure_ok call, fun _ member => by simp at member⟩
  rename_i isYieldable
  have yes : yieldable = true := by simpa using isYieldable
  rw [yes] at hyieldable
  leaf_walk call
  all_goals first
    | exact ⟨[], rfl, fun _ member => by simp at member⟩
    | (refine ⟨_, rfl, fun raw member normal => ?_⟩
       simp only [StateQuery.stringKeyed, List.map, List.mem_cons, List.not_mem_nil, or_false] at member
       rcases member with same | same | same
       · exact absurd normal (fun normal =>
           literal_raw_quiet same (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal)
       · exact absurd normal (fun normal =>
           literal_raw_quiet same (by simp [b, Term.text, Term.isBinary]) (by decide) (by decide) normal)
       · exact ⟨⟨_, _, hyieldable⟩, _, _, _, ⟨_, _, (hyp% field s "session_id" _ = _)⟩,
           ⟨_, _, (hyp% field s "next_message_id" _ = _)⟩, ⟨_, _, (hyp% sub _ (i 1) _ = _)⟩, same⟩)

/-- Every discharge event of a loop `write` effect is the ack of a provider-wait yield. -/
theorem write_discharge_justified {s machine event raw : Term} {events : List Term}
    (source : WriteSource s machine event events) (member : raw ∈ events)
    (normal : NormalizesTo raw DischargeEvent) : Yielded s raw := by
  cases source with
  | yield waitIdentity nid ack human events entry next identity nextId acked humans yielded nonempty =>
    obtain ⟨j, j', call⟩ := yielded
    rw [ask_yield] at call
    obtain ⟨out, same, facts⟩ := yield_discharge call
    cases same
    exact facts raw member normal

/-! ## M4: obligation targets carry only binary keys -/

theorem binaryKeys_putBounded {target value : Term} {k : String} {limit : Nat} (keys : BinaryKeys target) :
    BinaryKeys (putBounded target (b k) value limit) := by
  unfold putBounded
  dsimp only
  split
  · exact keys
  · exact binaryKeys_put keys

/-- `normalizeObligation` builds every target from binary keys. -/
theorem normalizeObligation_binary {value target : Term} {j r : List Term}
    (call : normalizeObligation value j = .ok (target, r)) : BinaryKeys target := by
  unfold normalizeObligation at call
  leaf_walk call
  all_goals first
    | trivial
    | (apply binaryKeys_put
       repeat' apply binaryKeys_putBounded
       simp [BinaryKeys, b, Term.text, Term.isBinary])


theorem get_atom_binaryKeys {m : Term} {k : String} (keys : BinaryKeys m) : m.get (a k) = nil := by
  cases m with
  | map entries =>
    unfold BinaryKeys at keys
    simp only [Term.get]
    have none : entries.find? (fun entry => entry.1 == a k) = none := by
      rw [List.find?_eq_none]
      intro entry member
      have binary := List.all_eq_true.mp keys entry member
      cases h : entry.1 <;> simp_all [Term.isBinary, BEq.beq]
    rw [none]
    rfl
  | _ => rfl

/-- On a binary-keyed target the atom-or-binary `kind` check of
`obligationBlocking` and the binary-only check of `blockingObligationCount` agree. -/
theorem blocking_checks_agree {target : Term} (keys : BinaryKeys target) :
    (obligationValue target "kind" == b "task_card") = (target.get (b "kind") == b "task_card") := by
  unfold obligationValue Term.default
  split
  · rfl
  · rename_i falsy
    rw [get_atom_binaryKeys keys]
    have left : (nil == b "task_card") = false := by decide
    rw [left]
    cases h : target.get (b "kind") <;> simp_all [Term.truthy, BEq.beq, b, Term.text]

/-- The obligation table that the reducers read. -/
def tableEntries (s : Term) : List (Term × Term) :=
  match obligationMap s with
  | .map xs => xs
  | _ => []

/-- Every stored obligation target carries only binary keys. -/
def StoredBinary (s : Term) : Prop := ∀ pair ∈ tableEntries s, BinaryKeys pair.2

theorem obligationMap_entries (s : Term) : obligationMap s = .map (tableEntries s) := by
  unfold tableEntries
  have := obligationMap_isMap s
  cases h : obligationMap s <;> simp_all [Term.isMap]

theorem any_congr_mem {α : Type} {xs : List α} {f g : α → Bool} (same : ∀ x ∈ xs, f x = g x) :
    xs.any f = xs.any g := by
  induction xs with
  | nil => rfl
  | cons x rest ih =>
    simp only [List.any_cons]
    rw [same x List.mem_cons_self, ih (fun y member => same y (List.mem_cons_of_mem _ member))]

theorem any_filter_length {α : Type} {xs : List α} {p : α → Bool} :
    xs.any p = decide (Int.ofNat (xs.filter p).length > 0) := by
  cases h : xs.any p
  · have none : xs.filter p = [] := by
      rw [List.filter_eq_nil_iff]
      intro x member
      have := List.any_eq_false.mp h x member
      simpa using this
    simp [none]
  · obtain ⟨x, member, px⟩ := List.any_eq_true.mp h
    have positive : 0 < (xs.filter p).length := List.length_pos_of_mem (List.mem_filter.mpr ⟨member, px⟩)
    symm
    simp only [decide_eq_true_eq, Int.ofNat_eq_natCast]
    omega

/-- On a state whose stored targets carry only binary keys, `obligationBlocking`
holds exactly when `blockingObligationCount` is positive. -/
theorem blocking_agree {s count : Term} (stored : StoredBinary s)
    (counted : Returns (ReplyQuery.blockingObligationCount s) count) :
    obligationBlocking s = decide (integerValue count > 0) := by
  obtain ⟨j, j', call⟩ := counted
  unfold ReplyQuery.blockingObligationCount at call
  obtain ⟨xs, _, hxs, call⟩ := bind_ok call
  rw [obligationMap_entries] at hxs
  unfold entries at hxs
  have same := pure_ok hxs
  subst xs
  rw [pure_ok call]
  unfold obligationBlocking
  rw [obligationMap_entries]
  dsimp only
  have agree : ∀ pair ∈ tableEntries s,
      (obligationValue pair.2 "kind" == b "task_card") = (pair.2.get (b "kind") == b "task_card") :=
    fun pair member => blocking_checks_agree (stored pair member)
  rw [any_congr_mem agree]
  rw [integerValue_i]
  exact any_filter_length


/-! ### The writers store only normalized targets -/

/-- The entries of a map term, or none. -/
def mapEntries (m : Term) : List (Term × Term) :=
  match m with
  | .map xs => xs
  | _ => []

theorem put_entries {m key v : Term} (map : m.isMap = true) :
    ∀ pair ∈ mapEntries (m.put key v), pair = (key, v) ∨ pair ∈ mapEntries m := by
  cases m with
  | map xs =>
    intro pair member
    simp only [mapEntries, Term.put, List.mem_cons] at member
    rcases member with same | kept
    · exact Or.inl same
    · exact Or.inr (List.mem_filter.mp kept).1
  | _ => simp [Term.isMap] at map

theorem write_put_stored {s t key target : Term} {j r : List Term} (stored : StoredBinary s)
    (binary : BinaryKeys target)
    (h : write s [("provider_reply_obligations", (obligationMap s).put key target)] j = .ok (t, r)) :
    StoredBinary t := by
  obtain ⟨_, table⟩ := write_obligations h (put_isMap _ _ _)
  intro pair member
  unfold tableEntries at member
  rcases table with same | same <;> rw [same] at member
  · exact stored pair member
  · rcases put_entries (obligationMap_isMap s) pair member with new | old
    · rw [new]; exact binary
    · exact stored pair old

theorem addObligation_stored {s raw t : Term} {j r : List Term} (stored : StoredBinary s)
    (call : addObligation s raw j = .ok (t, r)) : StoredBinary t := by
  unfold addObligation at call
  obtain ⟨target, _, normal, call⟩ := bind_ok call
  split at call
  · exact write_put_stored stored (normalizeObligation_binary normal) call
  · rw [pure_ok call]; exact stored

set_option backward.split false in
theorem obligationCard_stored {s conversation limit t : Term} {j r : List Term} (stored : StoredBinary s)
    (call : obligationCard s conversation limit j = .ok (t, r)) : StoredBinary t := by
  unfold obligationCard at call
  repeat' first
    | (execution_head_is call "Pure.pure"; have same := pure_ok call; subst same; exact stored)
    | (execution_head_is call "VerifiedKernel.Data.write"
       exact write_put_stored stored (normalizeObligation_binary (hyp% normalizeObligation _ _ = _)) call)
    | (execution_head_is call "Bind.bind"; obtain ⟨_, _, prior, call⟩ := bind_ok call
       try (execution_head_is prior "VerifiedKernel.fail"; exact (fail_ok prior).elim))
    | (execution_head_is call "VerifiedKernel.fail"; exact (fail_ok call).elim)
    | split at call
    | (generalize List.filter _ _ = discriminant at call; split at call)
    | dsimp only at call

theorem obligationResolve_stored {s key t : Term} {j r : List Term} (stored : StoredBinary s)
    (call : obligationResolve s key j = .ok (t, r)) : StoredBinary t := by
  unfold obligationResolve at call
  split at call
  · rw [pure_ok call]; exact stored
  · obtain ⟨rest, _, removed, call⟩ := bind_ok call
    obtain ⟨_, table⟩ := write_obligations call (remove_isMap removed)
    intro pair member
    unfold tableEntries at member
    rcases table with same | same <;> rw [same] at member
    · exact stored pair member
    · have restIs : rest = .map ((tableEntries s).filter (fun pair => pair.1 != key)) := by
        rw [obligationMap_entries] at removed
        exact pure_ok removed
      rw [restIs] at member
      exact stored pair (List.mem_filter.mp member).1


/-- The values of a map term. -/
def mapValuesBinary (m : Term) : Prop := ∀ pair ∈ mapEntries m, BinaryKeys pair.2

/-- One step of the `Lifecycle.obligationTable` fold. -/
def tableStep (acc : Term) (pair : Term × Term) : KernelM Term := do
  let target ← normalizeObligation pair.2
  if target.isMap && target.has (b "key") then Data.put acc (target.get (b "key")) target
  else pure acc

theorem table_fold_binary {xs : List (Term × Term)} {acc t : Term} {j r : List Term}
    (start : mapValuesBinary acc) (map : acc.isMap = true)
    (call : xs.foldlM tableStep acc j = .ok (t, r)) : mapValuesBinary t := by
  induction xs generalizing acc j with
  | nil => rw [pure_ok call]; exact start
  | cons pair rest ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, step, call⟩ := bind_ok call
    unfold tableStep at step
    obtain ⟨target, _, normal, step⟩ := bind_ok step
    split at step
    · have same := put_ok step
      subst next
      refine ih (fun entry member => ?_) (put_isMap _ _ _) call
      rcases put_entries map entry member with new | old
      · rw [new]; exact normalizeObligation_binary (target := target) normal
      · exact start entry old
    · rw [pure_ok step] at call
      exact ih start map call

/-- State load normalization stores only normalized targets. -/
theorem obligationTable_binary {value t : Term} {j r : List Term}
    (call : Lifecycle.obligationTable value j = .ok (t, r)) : mapValuesBinary t := by
  unfold Lifecycle.obligationTable at call
  split at call
  · rw [pure_ok call]; intro pair member; simp [empty, mapEntries] at member
  · obtain ⟨xs, _, _, call⟩ := bind_ok call
    exact table_fold_binary (fun pair member => by simp [empty, mapEntries] at member) rfl call


theorem write_last {s t v : Term} {name : String} {pre post : List (String × Term)} {j r : List Term}
    (h : write s (pre ++ (name, v) :: post) j = .ok (t, r))
    (later : post.all (fun entry => entry.1 != name) = true) : t.get (a name) = v := by
  induction pre generalizing s j with
  | nil =>
    obtain ⟨j', h⟩ := write_cons h
    rw [write_field_frame h later, get_put_same]
  | cons entry rest ih =>
    obtain ⟨j', h⟩ := write_cons (k := entry.1) (v := entry.2) h
    exact ih h

set_option backward.split false in
/-- An ack either keeps the obligation table or clears it. -/
theorem sessionAck_table {s e t : Term} {j r : List Term} (call : sessionAck s e j = .ok (t, r)) :
    obligationMap t = obligationMap s ∨ obligationMap t = empty := by
  unfold sessionAck at call
  obtain ⟨previous, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨next, _, _, call⟩ := bind_ok call
  obtain ⟨advanced, _, _, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call]; exact Or.inl rfl
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨current, _, read, call⟩ := bind_ok call
  simp only [field, fetch_ok_iff] at read
  obtain ⟨_, _, same, _⟩ := read
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  have binary : t.get (b "provider_reply_obligations") = s.get (b "provider_reply_obligations") :=
    write_binary_frame call
  have atom := write_last (pre := [("last_ack_message_id", next)]) call rfl
  unfold obligationMap obligationValue
  rw [binary, atom, same]
  cases advanced
  · left; rfl
  · unfold clearedWhen
    simp only [if_true]
    by_cases truthy : (s.get (b "provider_reply_obligations")).truthy = true
    · left; simp [Term.default, truthy]
    · right; simp [Term.default, truthy, empty, Term.isMap]

theorem sessionAck_stored {s e t : Term} {j r : List Term} (stored : StoredBinary s)
    (call : sessionAck s e j = .ok (t, r)) : StoredBinary t := by
  intro pair member
  unfold tableEntries at member
  rcases sessionAck_table call with same | same <;> rw [same] at member
  · exact stored pair member
  · simp [empty] at member


/-! ### The stored-target invariant across a batch -/

/-- The step keeps the stored-target invariant. -/
def StoredStep (s t : Term) : Prop := StoredBinary s → StoredBinary t

theorem stored_refl (s : Term) : StoredStep s s := id

theorem stored_trans {s t u : Term} (first : StoredStep s t) (second : StoredStep t u) : StoredStep s u :=
  fun stored => second (first stored)

theorem ReplyFrame.stored {s t : Term} (frame : ReplyFrame s t) : StoredStep s t := by
  intro stored pair member
  unfold tableEntries at member
  rw [obligationMap_frame frame] at member
  exact stored pair member

theorem addObligation_stored_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ StoredStep s t :=
  step_iff fun h stored => addObligation_stored stored h

syntax "stored_step" ident : tactic
macro_rules
  | `(tactic| stored_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_reply_frame_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine stored_trans (kept rfl rfl).stored ?_)
      | (head_step $h "_stored_step"; obtain ⟨_, kept⟩ := $h; refine stored_trans kept ?_)
      | (head_step $h "_reply_frame_step"; obtain ⟨_, kept⟩ := $h; refine stored_trans kept.stored ?_))

syntax "stored_walk" ident : tactic
macro_rules
  | `(tactic| stored_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact stored_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (stored_step $h; exact stored_refl _)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [field, fetch]; simp only [field, fetch_ok_iff] at $hx:ident
              obtain ⟨_, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Data.append]; simp only [append_ok_iff] at $hx:ident
              obtain ⟨_, _, $hl:ident, _, $rfl:ident, _⟩ := $hx)
           | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
           | stored_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | stored_step $hx
               | ((repeat (fail_if_success stored_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  stored_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem transcriptDelivery_stored {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : StoredStep s t := by
  unfold transcriptDelivery at h
  stored_walk h

theorem inner_stored {s e t : Term} {j r : List Term} (h : inner s e j = .ok (t, r)) : StoredStep s t := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := (h : _ ∨ _))
  all_goals first
    | (head_is h [sessionAck]; exact fun stored => sessionAck_stored stored h)
    | (head_is h [obligationResolve]; exact fun stored => obligationResolve_stored stored h)
    | (head_is h [obligationCard]; exact fun stored => obligationCard_stored stored h)
    | (head_is h [transcriptDelivery]; exact transcriptDelivery_stored h)
    | (fail_if_success head_is h [sessionAck, obligationResolve, obligationCard, transcriptDelivery]
       stored_walk h)

theorem prepareTrusted_stored {s raw next : Term} {normalized : Option Term} {j r : List Term}
    (h : prepareTrusted s raw j = .ok ((next, normalized), r)) : StoredStep s next := by
  cases normalized with
  | none => rw [prepareTrusted_none h]; exact stored_refl _
  | some event =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify h
    exact inner_stored reduced


def StoredToken (state raw : Term) : Term → Prop
  | .tuple [.atom "reduce", current, event, .list _] => current = state ∧ event = raw
  | .tuple [.atom "activity", resident, _, _, _, .list _] => StoredStep state resident
  | _ => False

def StoredTrace (state raw : Term) : Term → Prop
  | .tuple [.atom "done", final] => StoredStep state final
  | .tuple [.atom "observe", _, token] => StoredToken state raw token
  | _ => True

theorem runActivityTrusted_stored {state raw original next event : Term} {observations : List Term}
    (valid : StoredStep state next) :
    StoredTrace state raw (runActivityTrusted original next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent original next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact stored_trans valid (afterEvent_reply_frame result).stored
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_stored {state raw : Term} {observations : List Term} :
    StoredTrace state raw (runTrusted state raw observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted state raw observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      have kept := prepareTrusted_stored result
      cases normalized with
      | none => dsimp only; split <;> first | exact kept | trivial
      | some event => dsimp only; exact runActivityTrusted_stored kept
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_stored {state raw token observation : Term} (valid : StoredToken state raw token) :
    StoredTrace state raw (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · obtain ⟨same, sameRaw⟩ := valid
      subst same sameRaw
      exact runTrusted_stored
    · rename_i resident current next event observations
      change StoredStep state resident at valid
      dsimp only
      cases result : afterEvent current next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change StoredStep state (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          split
          · exact stored_trans (stored_trans valid (put_activity_frame _ _ (by decide) (by decide)).stored)
              (put_activity_frame _ _ (by decide) (by decide)).stored
          · exact stored_trans valid (put_activity_frame _ _ (by decide) (by decide)).stored
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

theorem resident_trace_stored {state raw initial final : Term} (trace : ResidentTrace initial final)
    (valid : StoredTrace state raw initial) : StoredTrace state raw final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_stored valid)

/-- A resident batch keeps the stored-target invariant. -/
theorem resident_batch_stored {s t : Term} {events : List Term} (execution : ResidentBatch s events t)
    (stored : StoredBinary s) : StoredBinary t := by
  induction execution with
  | nil => exact stored
  | cons head tail ih => exact ih (resident_trace_stored head runTrusted_stored stored)

/-- A projected batch keeps the stored-target invariant. -/
theorem project_stored {s t : Term} {events j r : List Term}
    (h : Command.project s events j = .ok (t, r)) (stored : StoredBinary s) : StoredBinary t := by
  obtain ⟨_, trace⟩ := project_execution h
  clear h
  revert stored
  induction trace with
  | nil => exact id
  | skip prepared tail ih => exact fun stored => ih (prepareTrusted_stored prepared stored)
  | cons prepared activity tail ih =>
    exact fun stored => ih ((afterEvent_reply_frame activity).stored (prepareTrusted_stored prepared stored))

/-- With binary-keyed stored targets, a zero blocking count means that an
advancing ack is not blocked. `Settlement.ready` checks the count. -/
theorem zero_count_not_blocking {s count : Term} (stored : StoredBinary s)
    (counted : Returns (ReplyQuery.blockingObligationCount s) count) (zero : integerValue count = 0) :
    obligationBlocking s = false := by
  rw [blocking_agree stored counted, zero]
  rfl

/-! ## The machine invariant for the carried timeout event

`LoopChain` (from `WorkEmbedding`) holds the machines that the kernel returned
and the host passed back unchanged. Every such machine keeps its carried
timeout event quiet: the event comes from `wait_timeout_event`, which never
builds an ack or a resolution. The walk copies `LoopChain.safe` with `RawQuiet`
in place of `RawOrdinary`. -/

theorem raw_quiet_non_map {v : Term} (plain : v.isMap = false) : RawQuiet v := by
  intro normalized journal rest call
  unfold shallowStringify at call
  obtain ⟨xs, _, read, _⟩ := bind_ok call
  cases v <;> simp_all [entries, Term.isMap, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift,
    Functor.map, Except.map]

/-- The carried timeout event of a machine whose entry is `wait_timeout` is quiet. -/
def MachineQuiet (machine : Term) : Prop :=
  mkey machine "entry" = b "wait_timeout" → RawQuiet (mkey machine "timeout_event")

def QuietOut (out : Term) : Prop := ∃ machine effects, out = .tuple [machine, list effects] ∧ MachineQuiet machine

theorem quiet_nil_entry {m : Term} (absent : mkey m "entry" = nil) : MachineQuiet m := by
  intro he
  rw [absent] at he
  cases he

syntax "close_quiet" : tactic
macro_rules
  | `(tactic| close_quiet) => `(tactic|
    (refine ⟨_, _, rfl, ?_⟩
     unfold MachineQuiet
     try split
     all_goals
       safe_norm
       first
         | assumption
         | (intro he; cases he)
         | (intro _; exact raw_quiet_non_map rfl)))

theorem guardOutcome_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% guardOutcome) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop guardOutcome
  run_split
  all_goals close_quiet

theorem park_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% park) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop park
  run_split
  all_goals first
    | close_quiet

theorem guardNotice_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% guardNotice) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop guardNotice
  unfold_loop finalStop
  run_split
  all_goals first
    | close_quiet

theorem noticeCleanup_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% noticeCleanup) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop noticeCleanup
  run_split
  all_goals first
    | close_quiet

theorem finalize_quiet {state m out : Term} {terminal : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% finalize) Loop.queryAsk state m terminal j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop finalize
  run_split
  all_goals first
    | close_quiet

theorem finalRecord_quiet {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% finalRecord) Loop.queryAsk state m record j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop finalRecord
  run_split
  all_goals first
    | close_quiet
    | exact finalize_quiet safe h
    | exact finalize_quiet safe prior

theorem modelFailure_quiet {state m out : Term} {info : Term} {recover : Bool} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% modelFailure) Loop.queryAsk state m info recover j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop modelFailure
  run_split
  all_goals first
    | close_quiet

theorem modelFailed_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% modelFailed) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop modelFailed
  run_split
  all_goals first
    | close_quiet

theorem toolTurn_quiet {m out : Term} {outcome : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% toolTurn) m outcome j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop toolTurn
  run_split
  all_goals first
    | close_quiet

theorem intentRecord_quiet {state m out : Term} {record : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% intentRecord) state m record j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop intentRecord
  run_split
  all_goals first
    | close_quiet
    | exact toolTurn_quiet safe h
    | exact toolTurn_quiet safe prior
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) _ _ _ _ = _)
       close_quiet)

theorem toolsDone_quiet {state m out : Term} {results async : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% toolsDone) Loop.queryAsk state m results async j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop toolsDone
  run_split
  all_goals first
    | close_quiet
    | (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _)
       close_quiet)

theorem resultsStored_quiet {state m out : Term} {events hwm base stored : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% resultsStored) Loop.queryAsk state m events hwm base stored j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop resultsStored
  run_split
  all_goals first
    | close_quiet

theorem quiet_after_park {next parked : Term} {prefix_ : List Term}
    (parkOut : QuietOut (.tuple [next, parked])) : QuietOut (.tuple [next, list (prefix_ ++ wrap parked)]) := by
  obtain ⟨m, effs, same, safe⟩ := parkOut
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  obtain ⟨rfl, _⟩ := same
  exact ⟨_, _, rfl, safe⟩

theorem outputCommitted_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% outputCommitted) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  have safe' := safe
  unfold MachineQuiet at safe
  unfold_loop outputCommitted
  run_split
  all_goals first
    | close_quiet
    | exact quiet_after_park (park_quiet safe' prior)

theorem continuation_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% continuation) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  have safe' := safe
  unfold MachineQuiet at safe
  unfold_loop continuation
  run_split
  all_goals try (obtain ⟨_, rfl⟩ := advance_ok (hyp% (loop% advance) m _ _ _ = _))
  all_goals first
    | close_quiet
    | (refine quiet_after_park (park_quiet ?_ prior)
       unfold MachineQuiet
       safe_norm
       exact safe)

theorem expire_quiet {state m busy out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% expire) state m busy j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop expire
  run_split
  all_goals try split_decide
  all_goals run_split
  all_goals close_quiet

theorem expireEntry_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% expireEntry) state m j = .ok (out, j')) : QuietOut out := by
  have safe' := safe
  unfold MachineQuiet at safe
  unfold_loop expireEntry
  run_split
  all_goals first
    | close_quiet
    | (refine expire_quiet ?_ h
       unfold MachineQuiet
       safe_norm
       exact safe)

theorem activation_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% activation) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop activation
  run_split
  all_goals first
    | close_quiet
    | (refine expireEntry_quiet ?_ h
       unfold MachineQuiet
       safe_norm
       exact safe)

theorem timeoutEntry_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% timeoutEntry) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  unfold MachineQuiet at safe
  unfold_loop timeoutEntry
  run_split
  all_goals first
    | close_quiet
    | (refine expireEntry_quiet ?_ h
       unfold MachineQuiet
       safe_norm
       intro _
       have call := (hyp% Loop.queryAsk state "wait_timeout_event" _ _ = _)
       rw [ask_timeout] at call
       exact waitTimeout_quiet call (not_true_false ‹_›))

theorem classify_quiet {state m out : Term} {j j' : List Term} (safe : MachineQuiet m)
    (h : (loop% classify) Loop.queryAsk state m j = .ok (out, j')) : QuietOut out := by
  have safe' := safe
  unfold MachineQuiet at safe
  open_classify
  -- Select the helper lemma by the execution head. A failed `exact` against another helper
  -- unfolds both helper bodies before it fails.
  all_goals first
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalize"; refine finalize_quiet ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_quiet ?_ h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"; refine modelFailure_quiet ?_ h)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.finalize"; refine finalize_quiet ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.toolTurn"; refine toolTurn_quiet ?_ prior)
    | (execution_head_is prior "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_quiet ?_ prior)
  all_goals first
    | exact safe'
    | (unfold MachineQuiet
       safe_norm
       exact safe)

theorem step_quiet_out {state machine event out : Term} {j j' : List Term} (safe : MachineQuiet machine)
    (h : Loop.stepWith Loop.queryAsk state (.tuple [machine, event]) j = .ok (out, j')) : QuietOut out := by
  have safe' := safe
  unfold MachineQuiet at safe
  unfold Loop.stepWith at h
  unfold_loop finalStop
  run_split
  all_goals first
    | (execution_head_is h "Pure.pure"; close_quiet)
    | close_quiet
    | (execution_head_is h "VerifiedKernel.Session.Loop.finalRecord"
       exact finalRecord_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.intentRecord"
       exact intentRecord_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.toolsDone"
       exact toolsDone_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.resultsStored"
       exact resultsStored_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.expire"
       exact expire_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.classify"
       exact classify_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.outputCommitted"
       exact outputCommitted_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailed"
       exact modelFailed_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.noticeCleanup"
       exact noticeCleanup_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardOutcome"
       exact guardOutcome_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.continuation"
       exact continuation_quiet safe' h)
    | (execution_head_is h "VerifiedKernel.Session.Loop.guardNotice"
       refine guardNotice_quiet ?_ h
       first
         | exact safe'
         | (refine quiet_nil_entry ?_
            safe_norm
            simp))
    | (execution_head_is h "VerifiedKernel.Session.Loop.modelFailure"
       refine modelFailure_quiet (quiet_nil_entry ?_) h
       safe_norm
       simp)
    | (execution_head_is h "VerifiedKernel.Session.Loop.activation"
       refine activation_quiet ?_ h
       first
         | exact safe'
         | (intro he
            safe_norm
            simp only [↓reduceIte, show ("round" = "entry") = False from by decide] at he
            exact absurd he (binary_ne (by decide)))
         | (unfold MachineQuiet
            safe_norm
            exact safe))
    | (execution_head_is h "VerifiedKernel.Session.Loop.timeoutEntry"
       refine timeoutEntry_quiet ?_ h
       first
         | exact safe'
         | (intro _
            refine raw_quiet_non_map ?_
            safe_norm
            simp [nil, Term.isMap]))

/-- The kernel keeps every machine it returns safe: a carried timeout event is
ordinary. -/
theorem step_machine_quiet {state machine event machine' : Term} {effects : List Term}
    (h : StepOK Loop.queryAsk state machine event machine' effects) (safe : MachineQuiet machine) :
    MachineQuiet machine' := by
  obtain ⟨j, j', h⟩ := h
  obtain ⟨m, effs, same, safeOut⟩ := step_quiet_out safe h
  simp only [Term.tuple.injEq, List.cons.injEq, and_true] at same
  rw [same.1]
  exact safeOut

/-- The machine before the first event is safe. -/
theorem initial_machine_quiet : MachineQuiet nil := fun he => Term.noConfusion he

theorem loopChain_quiet {machine : Term} (chain : LoopChain machine) : MachineQuiet machine := by
  induction chain with
  | initial => exact initial_machine_quiet
  | step _ h ih => exact step_machine_quiet h ih


/-- Property A for a loop step on a machine that the kernel produced and the
host passed back unchanged (`LoopChain`). The carried timeout event needs no
separate hypothesis. -/
theorem loop_chain_discharge_justified {s machine event machine' opts mode hwm t : Term}
    {effects events : List Term} (chain : LoopChain machine)
    (step : StepOK Loop.queryAsk s machine event machine' effects)
    (committed : commitEffect events opts mode ∈ effects)
    (apply : ResidentBatch s (events ++ PendingRevision.hwmEvents hwm) t) (discharges : Discharges s t) :
    (∃ raw ∈ events, NormalizesTo raw DischargeEvent) ∧
      ∀ raw ∈ events, NormalizesTo raw DischargeEvent → Justified s machine event raw :=
  loop_discharge_justified step committed (loopChain_quiet chain) apply discharges

end VerifiedKernel.Session.LoopDischarge
