import VerifiedKernelProofs.Session.WorkResident
import VerifiedKernelProofs.Session.WorkExecution
import VerifiedKernelProofs.Proof.NativeProducerTactic

/-!
# Reply frame for property A

Only two reducers can lower the reply state of a Session: `sessionAck` (event
type `ack`) and `obligationResolve` (event type
`provider_reply_obligation_resolved`). `addObligation`, `obligationCard` and
`transcriptDelivery` only add obligation keys. Every other reducer keeps the
ack watermark and the obligation table.

The obligation table is the value that the reducers read, `obligationMap`. It
reads the binary field key first and then the atom field key, so the frame
tracks both keys.
-/

namespace VerifiedKernel.Session.LoopDischarge
open Data WorkConservation

set_option Elab.async false
set_option maxHeartbeats 1000000

/-- The ack watermark of a Session state. -/
def ackOf (s : Term) : Term := s.get (a "last_ack_message_id")

/-- The obligation table of `s` holds the key `k`. -/
def Held (s k : Term) : Prop := (obligationMap s).has k = true

/-- The reducer keeps the ack watermark and both obligation fields. -/
def ReplyFrame (s t : Term) : Prop :=
  t.get (a "last_ack_message_id") = s.get (a "last_ack_message_id") ∧
  t.get (a "provider_reply_obligations") = s.get (a "provider_reply_obligations") ∧
  t.get (b "provider_reply_obligations") = s.get (b "provider_reply_obligations")

/-- The reducer keeps the ack watermark and every held binary obligation key.
The kernel builds every obligation key as a binary digest. -/
def KeysKept (s t : Term) : Prop :=
  ackOf t = ackOf s ∧ ∀ k : ByteArray, Held s (.binary k) → Held t (.binary k)

theorem reply_frame_refl (s : Term) : ReplyFrame s s := ⟨rfl, rfl, rfl⟩

theorem reply_frame_trans {s t u : Term} (first : ReplyFrame s t) (second : ReplyFrame t u) :
    ReplyFrame s u :=
  ⟨second.1.trans first.1, second.2.1.trans first.2.1, second.2.2.trans first.2.2⟩

theorem keys_kept_refl (s : Term) : KeysKept s s := ⟨rfl, fun _ held => held⟩

theorem keys_kept_trans {s t u : Term} (first : KeysKept s t) (second : KeysKept t u) : KeysKept s u :=
  ⟨second.1.trans first.1, fun k held => second.2 k (first.2 k held)⟩

theorem obligationMap_frame {s t : Term} (frame : ReplyFrame s t) : obligationMap t = obligationMap s := by
  unfold obligationMap obligationValue
  rw [frame.2.1, frame.2.2]

theorem ReplyFrame.kept {s t : Term} (frame : ReplyFrame s t) : KeysKept s t :=
  ⟨frame.1, fun k held => by unfold Held at *; rw [obligationMap_frame frame]; exact held⟩

theorem get_put_atom_binary (v x : Term) (l : String) (k : ByteArray) :
    (Term.put v (Term.atom l) x).get (Term.binary k) = v.get (Term.binary k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons]
    have skip : (Term.atom l == Term.binary k) = false := by simp [BEq.beq]
    rw [skip]
    simp only
    rw [find?_filter_of_imp]
    intro e he
    cases hk : e.1 <;> simp_all [BEq.beq]
  | _ => simp [Term.put, Term.get, BEq.beq]

theorem write_binary_frame {s t : Term} {entries : List (String × Term)} {k : ByteArray} {j r : List Term}
    (h : write s entries j = .ok (t, r)) : t.get (.binary k) = s.get (.binary k) := by
  induction entries generalizing s j with
  | nil =>
    have eq := pure_ok h
    subst t
    rfl
  | cons entry rest ih =>
    obtain ⟨name, value⟩ := entry
    obtain ⟨j', h⟩ := write_cons h
    rw [ih h, get_put_atom_binary]

theorem write_reply_frame {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (ack : entries.all (fun entry => entry.1 != "last_ack_message_id") = true)
    (obligations : entries.all (fun entry => entry.1 != "provider_reply_obligations") = true) :
    ReplyFrame s t :=
  ⟨write_field_frame h ack, write_field_frame h obligations, write_binary_frame h⟩

theorem write_reply_frame_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "last_ack_message_id") = true →
       entries.all (fun entry => entry.1 != "provider_reply_obligations") = true → ReplyFrame s t) :=
  step_iff write_reply_frame

syntax "reply_frame_step" ident : tactic
macro_rules
  | `(tactic| reply_frame_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_reply_frame_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine reply_frame_trans (kept rfl rfl) ?_)
      | (head_step $h "_reply_frame_step"; obtain ⟨_, kept⟩ := $h; refine reply_frame_trans kept ?_))

syntax "reply_frame_walk" ident : tactic
macro_rules
  | `(tactic| reply_frame_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact reply_frame_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (reply_frame_step $h; exact reply_frame_refl _)
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
           | reply_frame_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | reply_frame_step $hx
               | ((repeat (fail_if_success reply_frame_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  reply_frame_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

/-- `reply_rule f (state x y)` proves `f_reply_frame` and `f_reply_frame_step` by the walk. -/
syntax "reply_rule " ident " (" ident+ ")" : command
macro_rules
  | `(reply_rule $fn:ident ($args:ident*)) => do
    let lemma := Lean.mkIdent (fn.getId.appendAfter "_reply_frame")
    let step := Lean.mkIdent (fn.getId.appendAfter "_reply_frame_step")
    let state := args[0]!
    let binders ← args.mapM (fun arg => `(bracketedBinder| {$arg : Term}))
    let applied ← args.foldlM (fun acc arg => `(term| $acc $arg)) (← `(term| $fn))
    let first ← `(command|
      theorem $lemma $binders:bracketedBinder* {next : Term} {journal rest : List Term}
          (call : $applied journal = .ok (next, rest)) : ReplyFrame $state next := by
        unfold $fn at call
        reply_frame_walk call)
    let second ← `(command|
      theorem $step $binders:bracketedBinder* {next : Term} {journal rest : List Term} :
          $applied journal = .ok (next, rest) ↔
            Except.ok (next, rest) = $applied journal ∧ ReplyFrame $state next := step_iff $lemma)
    return Lean.mkNullNode #[first, second]

reply_rule appendFields (state event message)
reply_rule bumpHwm (state hwm)
reply_rule appendMessage (state event message)
reply_rule noteResult (state tool input status errorClass message content)
reply_rule noteAsyncResult (state existing event status)
reply_rule asyncStart (state event)
reply_rule asyncTerminal (state event status)
reply_rule resetFresh (state message)
reply_rule replyRepair (state event)
reply_rule replyIntent (state event)
reply_rule retireIntent (state event)
reply_rule activationStarted (state raw)
reply_rule activationFinished (state identity)
reply_rule pruneResultRefs (state)
reply_rule waitClear (state event)
reply_rule statusTransition (state event)
reply_rule activityTransition (state event)
reply_rule metadataCreated (state event)
reply_rule conversationSourceAdvance (state event)
reply_rule metadataPrompt (state event)
reply_rule metadataUpdate (state event)
reply_rule stampWorkReasons (state event)
reply_rule stampAgentId (state event)
reply_rule stampRuntimeEpoch (state event)
reply_rule stampRuntimeNode (state event)
reply_rule stampActivityRevision (state event)
reply_rule stampStorageRevision (state event)
reply_rule stampFlushId (state event)
reply_rule stampWorkIndexToken (state event)
reply_rule sessionStamp (state event)
reply_rule bumpHwmEvent (state event)
reply_rule compactionFailure (state event)
reply_rule compactionRecovery (state event)
reply_rule progressStep (state event)
reply_rule pruneCompactResults (state)
reply_rule recomputeContext (state)

set_option backward.split false in
theorem historyCompaction_reply_frame {s e t : Term} {provider : Bool} {j r : List Term}
    (h : historyCompaction s e provider j = .ok (t, r)) : ReplyFrame s t := by
  unfold historyCompaction at h
  repeat' first
    | (execution_head_is h "VerifiedKernel.Session.recomputeContext"
       exact recomputeContext_reply_frame h)
    | (execution_head_is h "Pure.pure"
       have same := pure_ok h
       subst t
       exact reply_frame_refl _)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            refine reply_frame_trans (write_reply_frame prior rfl rfl) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneResultRefs"
            refine reply_frame_trans (pruneResultRefs_reply_frame prior) ?_)
         | (execution_head_is prior "VerifiedKernel.Session.pruneCompactResults"
            refine reply_frame_trans (pruneCompactResults_reply_frame prior) ?_)
         | (execution_head_is prior "Pure.pure"
            have same := pure_ok prior
            subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem historyCompaction_reply_frame_step {s e t : Term} {provider : Bool} {j r : List Term} :
    historyCompaction s e provider j = .ok (t, r) ↔
      Except.ok (t, r) = historyCompaction s e provider j ∧ ReplyFrame s t :=
  step_iff historyCompaction_reply_frame

reply_rule compactResult (state event)
reply_rule storedResult (state event)
reply_rule transcriptToolResult (state event)
reply_rule transcriptAssistant (state event)
reply_rule transcriptLog (state event)
/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). This is much
cheaper than a walk over every branch of `runtimeAppend`. -/
theorem runtimeAppend_reply_frame {state event next : Term} {journal rest : List Term}
    (call : runtimeAppend state event journal = .ok (next, rest)) : ReplyFrame state next := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops call
  exact reply_frame_trans (appendFields_reply_frame appended) (reply_frame_trans (write_reply_frame written rfl rfl)
    (reply_frame_trans (bumpHwm_reply_frame bumped) (resetFresh_reply_frame reset)))

theorem runtimeAppend_reply_frame_step {state event next : Term} {journal rest : List Term} :
    runtimeAppend state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = runtimeAppend state event journal ∧ ReplyFrame state next :=
  step_iff runtimeAppend_reply_frame
reply_rule transcriptRuntime (state event)
reply_rule transcriptSeed (state event)
reply_rule queueAppend (state event)
reply_rule queueAck (state event)
reply_rule queueConsume (state event)
set_option backward.split false in
/-- `sessionEvent` writes only atom keys, so it keeps every binary key. -/
theorem sessionEvent_binary_kept {s e t : Term} {k : ByteArray} {j r : List Term}
    (h : sessionEvent s e j = .ok (t, r)) : t.get (.binary k) = s.get (.binary k) := by
  unfold sessionEvent at h
  have preserved : s.get (.binary k) = s.get (.binary k) := rfl
  repeat' first
    | (execution_head_is h "VerifiedKernel.Data.write"
       exact (write_binary_frame h).trans preserved)
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            have preserved : value.get (.binary k) = s.get (.binary k) :=
              (write_binary_frame prior).trans preserved)
         | (execution_head_is prior "Pure.pure"; have same := pure_ok prior; subst value)
         | skip)
    | dsimp only at h
    | split at h

/-- `sessionEvent` writes only `sessionEventWrittenKeys`. This frame is much cheaper than a
walk over every branch of `sessionEvent`. -/
theorem sessionEvent_reply_frame {state event next : Term} {journal rest : List Term}
    (call : sessionEvent state event journal = .ok (next, rest)) : ReplyFrame state next :=
  have kept := (sessionEvent_fields call).2
  ⟨kept "last_ack_message_id" rfl, kept "provider_reply_obligations" rfl, sessionEvent_binary_kept call⟩

theorem sessionEvent_reply_frame_step {state event next : Term} {journal rest : List Term} :
    sessionEvent state event journal = .ok (next, rest) ↔
      Except.ok (next, rest) = sessionEvent state event journal ∧ ReplyFrame state next :=
  step_iff sessionEvent_reply_frame

theorem mergePredicate_reply_frame {s kind through replacement extra t : Term} {j r : List Term}
    (h : mergePredicate s kind through replacement extra j = .ok (t, r)) : ReplyFrame s t := by
  unfold mergePredicate at h
  repeat' first
    | exact write_reply_frame h rfl rfl
    | split at h
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)

theorem mergePredicate_reply_frame_step {s kind through replacement extra t : Term} {j r : List Term} :
    mergePredicate s kind through replacement extra j = .ok (t, r) ↔
      Except.ok (t, r) = mergePredicate s kind through replacement extra j ∧ ReplyFrame s t :=
  step_iff mergePredicate_reply_frame

theorem microcompactIds_reply_frame {s replacement e t : Term} {ids j r : List Term}
    (h : microcompactIds s ids replacement e j = .ok (t, r)) : ReplyFrame s t := by
  unfold microcompactIds at h
  reply_frame_walk h

theorem microcompactIds_reply_frame_step {s replacement e t : Term} {ids j r : List Term} :
    microcompactIds s ids replacement e j = .ok (t, r) ↔
      Except.ok (t, r) = microcompactIds s ids replacement e j ∧ ReplyFrame s t :=
  step_iff microcompactIds_reply_frame

reply_rule microcompact (state event)
reply_rule capabilitySync (state event)
reply_rule archiveAdvance (state event)

/-- The activity reducer changes only the two activity fields. -/
theorem afterEvent_reply_frame {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : ReplyFrame next t := by
  unfold afterEvent at h
  reply_frame_walk h

/-! ### The writers that only add obligation keys -/

theorem beq_binary {x : Term} {k : ByteArray} (same : (x == Term.binary k) = true) : x = Term.binary k := by
  cases x <;> first | exact binary_term_beq rfl rfl same | simp [BEq.beq] at same

theorem binary_beq {x : Term} {k : ByteArray} (same : (Term.binary k == x) = true) : x = Term.binary k := by
  cases x <;> first | exact (binary_term_beq rfl rfl same).symm | simp [BEq.beq] at same

theorem binary_beq_self (k : ByteArray) : (Term.binary k == Term.binary k) = true := by
  change (k.data == k.data) = true
  exact beq_self_eq_true _

theorem has_binary {m : Term} {k : ByteArray} (held : m.has (.binary k) = true) :
    ∃ xs v, m = .map xs ∧ (Term.binary k, v) ∈ xs := by
  cases m with
  | map xs =>
    simp only [Term.has, List.any_eq_true] at held
    obtain ⟨⟨key, v⟩, member, same⟩ := held
    rw [beq_binary (x := key) same] at member
    exact ⟨xs, v, rfl, member⟩
  | _ => simp [Term.has] at held

theorem has_of_mem {xs : List (Term × Term)} {k : ByteArray} {v : Term} (member : (Term.binary k, v) ∈ xs) :
    (Term.map xs).has (.binary k) = true := by
  simp only [Term.has, List.any_eq_true]
  exact ⟨_, member, binary_beq_self k⟩

theorem has_put_binary {m key target : Term} {k : ByteArray} (held : m.has (.binary k) = true) :
    (m.put key target).has (.binary k) = true := by
  obtain ⟨xs, v, rfl, member⟩ := has_binary held
  cases same : (Term.binary k == key)
  · simp only [Term.put]
    apply has_of_mem (v := v)
    apply List.mem_cons_of_mem
    simp [List.mem_filter, member, same]
  · have := binary_beq same
    subst key
    simp only [Term.put]
    exact has_of_mem List.mem_cons_self

theorem put_isMap (m key target : Term) : (m.put key target).isMap = true := by
  cases m <;> simp [Term.put, Term.isMap]

theorem obligationMap_isMap (s : Term) : (obligationMap s).isMap = true := by
  unfold obligationMap
  dsimp only
  split
  · assumption
  · rfl

/-- A write of the obligation field to a map `v`: the table is `v` unless a binary field overrides it. -/
theorem write_obligations {s t v : Term} {j r : List Term}
    (h : write s [("provider_reply_obligations", v)] j = .ok (t, r)) (map : v.isMap = true) :
    ackOf t = ackOf s ∧
      (obligationMap t = obligationMap s ∨ obligationMap t = v) := by
  have ack : ackOf t = ackOf s := write_field_frame h rfl
  have binary : t.get (b "provider_reply_obligations") = s.get (b "provider_reply_obligations") :=
    write_binary_frame h
  obtain ⟨j', h'⟩ := write_cons h
  have final := pure_ok h'
  have field : t.get (a "provider_reply_obligations") = v := by rw [final]; exact get_put_same _ _ _
  refine ⟨ack, ?_⟩
  unfold obligationMap obligationValue
  rw [binary, field]
  by_cases truthy : (s.get (b "provider_reply_obligations")).truthy = true
  · left; simp only [Term.default, truthy, if_true]
  · right; simp only [Term.default, truthy, if_false, map, Bool.false_eq_true, if_true]

theorem write_obligations_put {s t key target : Term} {j r : List Term}
    (h : write s [("provider_reply_obligations", (obligationMap s).put key target)] j = .ok (t, r)) :
    KeysKept s t := by
  obtain ⟨ack, map⟩ := write_obligations h (put_isMap _ _ _)
  refine ⟨ack, fun k held => ?_⟩
  unfold Held at held ⊢
  rcases map with same | same <;> rw [same]
  · exact held
  · exact has_put_binary held

theorem write_keys_kept_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun entry => entry.1 != "last_ack_message_id") = true →
       entries.all (fun entry => entry.1 != "provider_reply_obligations") = true → KeysKept s t) :=
  step_iff fun h ack obligations => (write_reply_frame h ack obligations).kept

syntax "keys_kept_step" ident : tactic
macro_rules
  | `(tactic| keys_kept_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; refine keys_kept_trans (write_obligations_put $h) ?_)
      | (head_is $h [write]; simp only [write_keys_kept_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine keys_kept_trans (kept rfl rfl) ?_)
      | (head_step $h "_keys_kept_step"; obtain ⟨_, kept⟩ := $h; refine keys_kept_trans kept ?_)
      | (head_step $h "_reply_frame_step"; obtain ⟨_, kept⟩ := $h; refine keys_kept_trans kept.kept ?_))

syntax "keys_kept_walk" ident : tactic
macro_rules
  | `(tactic| keys_kept_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact keys_kept_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (keys_kept_step $h; exact keys_kept_refl _)
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
           | keys_kept_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | keys_kept_step $hx
               | ((repeat (fail_if_success keys_kept_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  keys_kept_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

theorem addObligation_keys_kept {s raw t : Term} {j r : List Term}
    (h : addObligation s raw j = .ok (t, r)) : KeysKept s t := by
  unfold addObligation at h
  keys_kept_walk h

theorem addObligation_keys_kept_step {s raw t : Term} {j r : List Term} :
    addObligation s raw j = .ok (t, r) ↔ Except.ok (t, r) = addObligation s raw j ∧ KeysKept s t :=
  step_iff addObligation_keys_kept

theorem obligationCard_keys_kept {s conversation limit t : Term} {j r : List Term}
    (h : obligationCard s conversation limit j = .ok (t, r)) : KeysKept s t := by
  unfold obligationCard at h
  keys_kept_walk h

theorem obligationCard_keys_kept_step {s conversation limit t : Term} {j r : List Term} :
    obligationCard s conversation limit j = .ok (t, r) ↔
      Except.ok (t, r) = obligationCard s conversation limit j ∧ KeysKept s t :=
  step_iff obligationCard_keys_kept

/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). This is
much cheaper than a walk over every branch of `transcriptDelivery`. -/
theorem transcriptDelivery_keys_kept {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : KeysKept s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, obligated, bumped, reset⟩
  · exact keys_kept_refl _
  · exact keys_kept_trans ((appendFields_reply_frame appended).kept) (keys_kept_trans ((write_keys_kept_step.mp written).2 rfl rfl)
      (keys_kept_trans (addObligation_keys_kept obligated) (keys_kept_trans ((bumpHwm_reply_frame bumped).kept) ((resetFresh_reply_frame reset).kept))))

theorem transcriptDelivery_keys_kept_step {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ KeysKept s t :=
  step_iff transcriptDelivery_keys_kept

theorem remove_keeps {m key rest : Term} {k : ByteArray} {j r : List Term}
    (call : remove m key j = .ok (rest, r)) (held : m.has (.binary k) = true) :
    rest.has (.binary k) = true ∨ key = .binary k := by
  obtain ⟨xs, v, rfl, member⟩ := has_binary held
  unfold remove at call
  have same := pure_ok call
  subst rest
  cases different : (Term.binary k != key)
  · right
    simp only [bne, Bool.not_eq_false'] at different
    exact binary_beq different
  · left
    exact has_of_mem (v := v) (List.mem_filter.mpr ⟨member, different⟩)

theorem remove_isMap {m key rest : Term} {j r : List Term} (call : remove m key j = .ok (rest, r)) :
    rest.isMap = true := by
  cases m <;> unfold remove at call <;> first | (rw [pure_ok call]; rfl) | exact (fail_ok call).elim

/-- A resolution keeps the ack and every key except its own. -/
theorem obligationResolve_keeps {s key t : Term} {j r : List Term}
    (h : obligationResolve s key j = .ok (t, r)) :
    ackOf t = ackOf s ∧ ∀ k : ByteArray, Held s (.binary k) → Held t (.binary k) ∨ key = .binary k := by
  unfold obligationResolve at h
  split at h
  · have := pure_ok h
    subst t
    exact ⟨rfl, fun _ held => Or.inl held⟩
  · obtain ⟨rest, _, removed, h⟩ := bind_ok h
    have map : rest.isMap = true := remove_isMap removed
    obtain ⟨ack, table⟩ := write_obligations h map
    refine ⟨ack, fun k held => ?_⟩
    unfold Held at held ⊢
    rcases table with same | same <;> rw [same]
    · exact Or.inl held
    · exact remove_keeps removed held

/-- An `ack` event, as the reducer dispatch reads it. -/
def AckEvent (e : Term) : Prop := (e.get (b "type") == b "ack") = true

/-- A `provider_reply_obligation_resolved` event, as the reducer dispatch reads it. -/
def ResolveEvent (e : Term) : Prop :=
  (e.get (b "type") == b "provider_reply_obligation_resolved") = true ∧ e.has (b "obligation_key") = true

/-- What one reducer step can do to the reply state. -/
def ReplyStep (e s t : Term) : Prop :=
  AckEvent e ∨
  (ResolveEvent e ∧ ackOf t = ackOf s ∧
    ∀ k : ByteArray, Held s (.binary k) → Held t (.binary k) ∨ e.get (b "obligation_key") = .binary k) ∨
  KeysKept s t

theorem inner_reply {s e t : Term} {j r : List Term} (h : inner s e j = .ok (t, r)) : ReplyStep e s t := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := (h : _ ∨ _))
  all_goals first
    | exact Or.inl ‹_›
    | (head_is h [obligationResolve]
       obtain ⟨ack, keys⟩ := obligationResolve_keeps h
       refine Or.inr (Or.inl ⟨?_, ack, keys⟩)
       unfold ResolveEvent
       exact Bool.and_eq_true_iff.mp (by assumption))
    | (right; right; keys_kept_walk h)


theorem ReplyStep.frame {e s t u : Term} (step : ReplyStep e s t) (frame : ReplyFrame t u) : ReplyStep e s u := by
  rcases step with ack | ⟨resolve, ack, keys⟩ | kept
  · exact Or.inl ack
  · refine Or.inr (Or.inl ⟨resolve, frame.1.trans ack, fun k held => ?_⟩)
    rcases keys k held with present | same
    · left; unfold Held at present ⊢; rw [obligationMap_frame frame]; exact present
    · exact Or.inr same
  · exact Or.inr (Or.inr (keys_kept_trans kept frame.kept))

/-- One raw event of a batch: the target filter skipped it, or its normalized form stepped. -/
def RawStep (raw s t : Term) : Prop :=
  KeysKept s t ∨ ∃ event j r, shallowStringify raw j = .ok (event, r) ∧ ReplyStep event s t

theorem RawStep.frame {raw s t u : Term} (step : RawStep raw s t) (frame : ReplyFrame t u) : RawStep raw s u := by
  rcases step with kept | ⟨event, j, r, read, step⟩
  · exact Or.inl (keys_kept_trans kept frame.kept)
  · exact Or.inr ⟨event, j, r, read, step.frame frame⟩

theorem prepareTrusted_reply {s raw next : Term} {normalized : Option Term} {j r : List Term}
    (h : prepareTrusted s raw j = .ok ((next, normalized), r)) : RawStep raw s next := by
  cases normalized with
  | none => left; rw [prepareTrusted_none h]; exact keys_kept_refl _
  | some event =>
    obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify h
    exact Or.inr ⟨event, _, _, read, inner_reply reduced⟩

/-! ### Resident execution -/

/-- The activity continuation keeps the resident state that the reducer produced. -/
def TokenGood (state raw : Term) : Term → Prop
  | .tuple [.atom "reduce", current, event, .list _] => current = state ∧ event = raw
  | .tuple [.atom "activity", resident, _, _, _, .list _] => RawStep raw state resident
  | _ => False

def TraceGood (state raw : Term) : Term → Prop
  | .tuple [.atom "done", final] => RawStep raw state final
  | .tuple [.atom "observe", _, token] => TokenGood state raw token
  | _ => True

theorem put_activity_frame (s x : Term) {key : String} (status : key ≠ "last_ack_message_id")
    (table : key ≠ "provider_reply_obligations") : ReplyFrame s (s.put (a key) x) :=
  ⟨get_put_other _ _ status, get_put_other _ _ table, get_put_atom_binary _ _ _ _⟩

theorem runActivityTrusted_good {state raw original next event : Term} {observations : List Term}
    (valid : RawStep raw state next) :
    TraceGood state raw (runActivityTrusted original next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent original next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact valid.frame (afterEvent_reply_frame result)
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_good {state raw : Term} {observations : List Term} :
    TraceGood state raw (runTrusted state raw observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted state raw observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      have kept := prepareTrusted_reply result
      cases normalized with
      | none => dsimp only; split <;> first | exact kept | trivial
      | some event => dsimp only; exact runActivityTrusted_good kept
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_good {state raw token observation : Term} (valid : TokenGood state raw token) :
    TraceGood state raw (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · obtain ⟨same, sameRaw⟩ := valid
      subst same sameRaw
      exact runTrusted_good
    · rename_i resident current next event observations
      change RawStep raw state resident at valid
      dsimp only
      cases result : afterEvent current next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change RawStep raw state (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          split
          · exact (valid.frame (put_activity_frame _ _ (by decide) (by decide))).frame
              (put_activity_frame _ _ (by decide) (by decide))
          · exact valid.frame (put_activity_frame _ _ (by decide) (by decide))
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

theorem resident_trace_good {state raw initial final : Term} (trace : ResidentTrace initial final)
    (valid : TraceGood state raw initial) : TraceGood state raw final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_good valid)

/-- One resident event execution changes the reply state only as its normalized event allows. -/
theorem resident_step_reply {state raw next : Term} {observations : List Term}
    (trace : ResidentTrace (runTrusted state raw observations) (.tuple [a "done", next])) :
    RawStep raw state next :=
  resident_trace_good trace runTrusted_good


/-! ### Batches -/

/-- The kernel normalizes `raw` to an event that satisfies `P`. -/
def NormalizesTo (raw : Term) (P : Term → Prop) : Prop :=
  ∃ event j r, shallowStringify raw j = .ok (event, r) ∧ P event

/-- An event that can lower the reply state. -/
def DischargeEvent (event : Term) : Prop := AckEvent event ∨ ResolveEvent event

/-- The batch took the ack watermark to a different value, or removed an obligation key. -/
def Discharges (s t : Term) : Prop :=
  ackOf t ≠ ackOf s ∨ ∃ k : ByteArray, Held s (.binary k) ∧ ¬Held t (.binary k)

/-- A chain of raw event steps. Resident and projected batches both give one. -/
inductive ReplyChain : Term → List Term → Term → Prop where
  | nil (s : Term) : ReplyChain s [] s
  | cons {s next t raw : Term} {events : List Term} (head : RawStep raw s next)
      (tail : ReplyChain next events t) : ReplyChain s (raw :: events) t

theorem resident_batch_chain {s t : Term} {events : List Term} (execution : ResidentBatch s events t) :
    ReplyChain s events t := by
  induction execution with
  | nil => exact .nil _
  | cons head tail ih => exact .cons (resident_step_reply head) ih

theorem projected_batch_chain {s t : Term} {events normalized j r : List Term}
    (trace : ProjectedBatch s events j normalized t r) : ReplyChain s events t := by
  induction trace with
  | nil => exact .nil _
  | skip prepared tail ih => exact .cons (prepareTrusted_reply prepared) ih
  | cons prepared activity tail ih =>
    exact .cons ((prepareTrusted_reply prepared).frame (afterEvent_reply_frame activity)) ih

theorem chain_ack_source {s t : Term} {events : List Term} (chain : ReplyChain s events t)
    (changed : ackOf t ≠ ackOf s) : ∃ raw ∈ events, NormalizesTo raw AckEvent := by
  induction chain with
  | nil => exact absurd rfl changed
  | @cons s next t raw events head tail ih =>
    by_cases same : ackOf next = ackOf s
    · obtain ⟨found, member, normal⟩ := ih (by rw [same]; exact changed)
      exact ⟨found, List.mem_cons_of_mem _ member, normal⟩
    · rcases head with kept | ⟨event, j, r, read, ack | ⟨_, keep, _⟩ | kept⟩
      · exact absurd kept.1 same
      · exact ⟨raw, List.mem_cons_self, event, j, r, read, ack⟩
      · exact absurd keep same
      · exact absurd kept.1 same

theorem chain_key_source {s t : Term} {events : List Term} {k : ByteArray} (chain : ReplyChain s events t)
    (held : Held s (.binary k)) (lost : ¬Held t (.binary k)) :
    ∃ raw ∈ events, NormalizesTo raw (fun event =>
      AckEvent event ∨ (ResolveEvent event ∧ event.get (b "obligation_key") = .binary k)) := by
  induction chain with
  | nil => exact absurd held lost
  | @cons s next t raw events head tail ih =>
    by_cases kept : Held next (.binary k)
    · obtain ⟨found, member, normal⟩ := ih kept lost
      exact ⟨found, List.mem_cons_of_mem _ member, normal⟩
    · rcases head with keys | ⟨event, j, r, read, ack | ⟨resolve, _, keys⟩ | keys⟩
      · exact absurd (keys.2 k held) kept
      · exact ⟨raw, List.mem_cons_self, event, j, r, read, Or.inl ack⟩
      · rcases keys k held with present | same
        · exact absurd present kept
        · exact ⟨raw, List.mem_cons_self, event, j, r, read, Or.inr ⟨resolve, same⟩⟩
      · exact absurd (keys.2 k held) kept

/-- Frame lemma for property A: a discharge needs an ack event or a resolution of the lost key. -/
theorem chain_discharge_source {s t : Term} {events : List Term} (chain : ReplyChain s events t)
    (discharges : Discharges s t) : ∃ raw ∈ events, NormalizesTo raw DischargeEvent := by
  rcases discharges with changed | ⟨k, held, lost⟩
  · obtain ⟨raw, member, event, j, r, read, ack⟩ := chain_ack_source chain changed
    exact ⟨raw, member, event, j, r, read, Or.inl ack⟩
  · obtain ⟨raw, member, event, j, r, read, found⟩ := chain_key_source chain held lost
    rcases found with ack | ⟨resolve, _⟩
    · exact ⟨raw, member, event, j, r, read, Or.inl ack⟩
    · exact ⟨raw, member, event, j, r, read, Or.inr resolve⟩

theorem resident_batch_discharge_source {s t : Term} {events : List Term}
    (execution : ResidentBatch s events t) (discharges : Discharges s t) :
    ∃ raw ∈ events, NormalizesTo raw DischargeEvent :=
  chain_discharge_source (resident_batch_chain execution) discharges

theorem project_discharge_source {s t : Term} {events j r : List Term}
    (h : Command.project s events j = .ok (t, r)) (discharges : Discharges s t) :
    ∃ raw ∈ events, NormalizesTo raw DischargeEvent := by
  obtain ⟨_, trace⟩ := project_execution h
  exact chain_discharge_source (projected_batch_chain trace) discharges

/-- A raw event whose every normalization is not a discharge event. -/
def RawQuiet (raw : Term) : Prop := ∀ event j r, shallowStringify raw j = .ok (event, r) → ¬DischargeEvent event

theorem quiet_batch_no_discharge {s t : Term} {events : List Term} (chain : ReplyChain s events t)
    (quiet : ∀ raw ∈ events, RawQuiet raw) : ¬Discharges s t := by
  intro discharges
  obtain ⟨raw, member, event, j, r, read, found⟩ := chain_discharge_source chain discharges
  exact quiet raw member event j r read found

/-- For binary-keyed events the normalized form is the event itself. -/
theorem normalizes_binary {raw : Term} {P : Term → Prop} (keys : BinaryKeys raw) (normal : NormalizesTo raw P) :
    P raw := by
  obtain ⟨event, j, r, read, found⟩ := normal
  rw [← shallowStringify_binary_keys keys read]
  exact found

end VerifiedKernel.Session.LoopDischarge
