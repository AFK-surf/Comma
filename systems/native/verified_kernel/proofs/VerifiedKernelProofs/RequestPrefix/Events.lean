import VerifiedKernelProofs.RequestPrefix.EndToEnd
import VerifiedKernelProofs.Session.AppendOnly

/-!
# The events that can change the request prefix

`consecutive_requests_share_prefix` has four state conditions: the window fields
(`SameWindow`), the stored prompt, the transcript (`TranscriptExtends`), and the attachment
watermark (`AckFrame`). This module proves them for every run of completed events whose types are
not in the closed list `prefixEventTypes`:

* `session_system_prompt` writes the stored prompt;
* `compaction` and `provider_compaction` write the compaction prefix and watermark;
* `ack` writes the acknowledgment watermark that attachment inlining reads;
* `archive_advance` removes a prefix of the transcript.

Every other reducer keeps the fields in `PrefixKept` (`inner_prefix_kept`) and appends to the
transcript (`inner_extends`). `runs_share_prefix` is the end-to-end theorem without the four state
conditions.
-/

namespace VerifiedKernel.Session.PrefixEvents
open Data
open VerifiedKernel.RequestPrefix (SameKey)
set_option Elab.async false
set_option maxHeartbeats 1000000

/-- The state fields that a provider request reads besides the transcript: the stored prompt, the
compaction prefix and watermark, and the watermark of attachment inlining. -/
def PrefixKept (s t : Term) : Prop :=
  t.isMap = s.isMap ∧ SameKey s t "system_prompt" ∧ SameKey s t "provider_compaction" ∧
    SameKey s t "summary" ∧ SameKey s t "compacted_through" ∧ SameKey s t "last_ack_message_id"

theorem same_key_refl (s : Term) (k : String) : SameKey s s k := ⟨rfl, rfl, rfl⟩

theorem same_key_trans {s t u : Term} {k : String} (first : SameKey s t k) (second : SameKey t u k) :
    SameKey s u k :=
  ⟨second.1.trans first.1, second.2.1.trans first.2.1, second.2.2.trans first.2.2⟩

theorem prefix_kept_refl (s : Term) : PrefixKept s s :=
  ⟨rfl, same_key_refl _ _, same_key_refl _ _, same_key_refl _ _, same_key_refl _ _, same_key_refl _ _⟩

theorem prefix_kept_trans {s t u : Term} (first : PrefixKept s t) (second : PrefixKept t u) :
    PrefixKept s u :=
  ⟨second.1.trans first.1, same_key_trans first.2.1 second.2.1, same_key_trans first.2.2.1 second.2.2.1,
    same_key_trans first.2.2.2.1 second.2.2.2.1, same_key_trans first.2.2.2.2.1 second.2.2.2.2.1,
    same_key_trans first.2.2.2.2.2 second.2.2.2.2.2⟩

/-! ### `write` keeps the fields it does not name -/

theorem has_put_other (v x : Term) {k l : String} (h : l ≠ k) :
    (Term.put v (a l) x).has (a k) = v.has (a k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.has, List.any_cons, atom_beq_ne h, Bool.false_or]
    induction entries with
    | nil => rfl
    | cons entry rest ih =>
      obtain ⟨key, value⟩ := entry
      by_cases same : (key == Term.atom l) = true
      · obtain rfl := atom_beq_true same
        simp [atom_beq_self, atom_beq_ne h, ih]
      · simp [same, ih]
  | _ => simp [Term.put, Term.has, atom_beq_ne h]

theorem get_put_binary (v x : Term) (l k : String) : (Term.put v (a l) x).get (b k) = v.get (b k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons]
    simp only [show (a l == b k) = false from rfl]
    rw [find?_filter_of_imp]
    intro entry matched
    obtain ⟨key, value⟩ := entry
    cases key <;> simp_all [BEq.beq, b, Term.text]
  | _ => simp [Term.put, Term.get, b, a, Term.text, BEq.beq]

theorem write_cons_map {s t : Term} {k : String} {v : Term} {rest : List (String × Term)} {j r : List Term}
    (h : write s ((k, v) :: rest) j = .ok (t, r)) :
    s.isMap = true ∧ ∃ j', write (Term.put s (Term.atom k) v) rest j' = .ok (t, r) := by
  unfold write at h ⊢
  rw [List.foldlM_cons] at h
  obtain ⟨x, j', hx, h⟩ := bind_ok h
  obtain ⟨_, _, _, hx⟩ := bind_ok hx
  unfold Data.put at hx
  split at hx
  · obtain rfl := pure_ok hx
    exact ⟨‹_›, j', h⟩
  · exact (fail_ok hx).elim

theorem write_isMap {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r)) : t.isMap = s.isMap := by
  induction entries generalizing s j with
  | nil =>
    unfold write at h
    simp only [List.foldlM_nil] at h
    obtain rfl := pure_ok h
    rfl
  | cons entry rest ih =>
    obtain ⟨k, v⟩ := entry
    obtain ⟨map, j', h⟩ := write_cons_map h
    rw [ih h, map]
    cases s <;> first | rfl | simp [Term.isMap] at map

theorem write_same_key {s t : Term} {entries : List (String × Term)} {key : String} {j r : List Term}
    (h : write s entries j = .ok (t, r)) (ok : entries.all (fun e => e.1 != key) = true) :
    SameKey s t key := by
  induction entries generalizing s j with
  | nil =>
    unfold write at h
    simp only [List.foldlM_nil] at h
    obtain rfl := pure_ok h
    exact same_key_refl _ _
  | cons entry rest ih =>
    obtain ⟨k, v⟩ := entry
    simp only [List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at ok
    obtain ⟨j', h⟩ := write_cons h
    exact same_key_trans ⟨has_put_other _ _ ok.1, get_put_other _ _ ok.1, get_put_binary _ _ _ _⟩ (ih h ok.2)

theorem write_prefix_kept {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r))
    (prompt : entries.all (fun e => e.1 != "system_prompt") = true)
    (compaction : entries.all (fun e => e.1 != "provider_compaction") = true)
    (summary : entries.all (fun e => e.1 != "summary") = true)
    (compacted : entries.all (fun e => e.1 != "compacted_through") = true)
    (ack : entries.all (fun e => e.1 != "last_ack_message_id") = true) : PrefixKept s t :=
  ⟨write_isMap h, write_same_key h prompt, write_same_key h compaction, write_same_key h summary,
    write_same_key h compacted, write_same_key h ack⟩

theorem write_prefix_kept_step {s t : Term} {entries : List (String × Term)} {j r : List Term} :
    write s entries j = .ok (t, r) ↔ Except.ok (t, r) = write s entries j ∧
      (entries.all (fun e => e.1 != "system_prompt") = true →
        entries.all (fun e => e.1 != "provider_compaction") = true →
        entries.all (fun e => e.1 != "summary") = true →
        entries.all (fun e => e.1 != "compacted_through") = true →
        entries.all (fun e => e.1 != "last_ack_message_id") = true → PrefixKept s t) :=
  step_iff write_prefix_kept

/-! ### Walking a reducer -/

syntax "prefix_kept_step" ident : tactic
macro_rules
  | `(tactic| prefix_kept_step $h:ident) =>
    `(tactic| first
      | (head_is $h [write]; simp only [write_prefix_kept_step] at $h:ident; obtain ⟨_, kept⟩ := $h
         refine prefix_kept_trans
           (kept (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent)) ?_)
      | (head_step $h "_prefix_kept_step"; obtain ⟨_, kept⟩ := $h; refine prefix_kept_trans kept ?_))

syntax "prefix_kept_walk" ident : tactic
macro_rules
  | `(tactic| prefix_kept_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let hl := Lean.mkIdent `hl
  let rfl := Lean.mkIdent `rfl
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; simp only [pure_ok_iff] at $h:ident; cases $h:ident; exact prefix_kept_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (prefix_kept_step $h; exact prefix_kept_refl _)
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
           | prefix_kept_step $hx
           | (split at $hx:ident <;> first
               | (head_is $hx [Pure.pure]; simp only [pure_ok_iff] at $hx:ident; cases $hx:ident)
               | prefix_kept_step $hx
               | ((repeat (fail_if_success prefix_kept_step $hx; obtain ⟨_, _, _, $hx:ident⟩ := bind_ok $hx))
                  prefix_kept_step $hx)
               | skip)
           | skip)
      | dsimp only at $h:ident)

/-- `prefix_rule f (state x y)` proves `f_prefix_kept` and `f_prefix_kept_step` by the walk. -/
syntax "prefix_rule " ident " (" ident+ ")" : command
macro_rules
  | `(prefix_rule $fn:ident ($args:ident*)) => do
    let lemma := Lean.mkIdent (fn.getId.appendAfter "_prefix_kept")
    let step := Lean.mkIdent (fn.getId.appendAfter "_prefix_kept_step")
    let state := args[0]!
    let binders ← args.mapM (fun arg => `(bracketedBinder| {$arg : Term}))
    let applied ← args.foldlM (fun acc arg => `(term| $acc $arg)) (← `(term| $fn))
    let first ← `(command|
      theorem $lemma $binders:bracketedBinder* {next : Term} {journal rest : List Term}
          (call : $applied journal = .ok (next, rest)) : PrefixKept $state next := by
        unfold $fn at call
        prefix_kept_walk call)
    let second ← `(command|
      theorem $step $binders:bracketedBinder* {next : Term} {journal rest : List Term} :
          $applied journal = .ok (next, rest) ↔
            Except.ok (next, rest) = $applied journal ∧ PrefixKept $state next := step_iff $lemma)
    return Lean.mkNullNode #[first, second]

/-! ### The reducers that keep the request fields

`metadataPrompt`, `historyCompaction` and `sessionAck` write them; `archiveAdvance` removes a
transcript prefix. No other reducer calls these four. -/

prefix_rule appendFields (state event message)
prefix_rule bumpHwm (state hwm)
prefix_rule appendMessage (state event message)
prefix_rule noteResult (state tool input status errorClass message content)
prefix_rule noteAsyncResult (state existing event status)
prefix_rule asyncStart (state event)
prefix_rule asyncTerminal (state event status)
prefix_rule resetFresh (state message)
prefix_rule addObligation (state raw)
prefix_rule obligationResolve (state key)
prefix_rule obligationCard (state conversation limit)
prefix_rule replyRepair (state event)
prefix_rule replyIntent (state event)
prefix_rule retireIntent (state event)
prefix_rule activationStarted (state raw)
prefix_rule activationFinished (state identity)
prefix_rule pruneResultRefs (state)
prefix_rule waitClear (state event)
prefix_rule statusTransition (state event)
prefix_rule activityTransition (state event)
prefix_rule metadataCreated (state event)
prefix_rule conversationSourceAdvance (state event)
prefix_rule metadataUpdate (state event)
prefix_rule stampWorkReasons (state event)
prefix_rule stampAgentId (state event)
prefix_rule stampRuntimeEpoch (state event)
prefix_rule stampRuntimeNode (state event)
prefix_rule stampActivityRevision (state event)
prefix_rule stampStorageRevision (state event)
prefix_rule stampFlushId (state event)
prefix_rule stampWorkIndexToken (state event)
prefix_rule sessionStamp (state event)
prefix_rule bumpHwmEvent (state event)
prefix_rule compactionFailure (state event)
prefix_rule compactionRecovery (state event)
prefix_rule progressStep (state event)
prefix_rule pruneCompactResults (state)
prefix_rule recomputeContext (state)
prefix_rule compactResult (state event)
prefix_rule storedResult (state event)
prefix_rule transcriptToolResult (state event)
prefix_rule transcriptAssistant (state event)
prefix_rule transcriptLog (state event)

/-- Compose the Session operations of `runtimeAppend` (`runtimeAppend_ops`). -/
theorem runtimeAppend_prefix_kept {s e t : Term} {j r : List Term} (h : runtimeAppend s e j = .ok (t, r)) :
    PrefixKept s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, appended, written, bumped, reset⟩ := runtimeAppend_ops h
  exact prefix_kept_trans (appendFields_prefix_kept appended) (prefix_kept_trans
    (write_prefix_kept written (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent))
    (prefix_kept_trans (bumpHwm_prefix_kept bumped) (resetFresh_prefix_kept reset)))

theorem runtimeAppend_prefix_kept_step {s e t : Term} {j r : List Term} :
    runtimeAppend s e j = .ok (t, r) ↔ Except.ok (t, r) = runtimeAppend s e j ∧ PrefixKept s t :=
  step_iff runtimeAppend_prefix_kept

prefix_rule transcriptRuntime (state event)

/-- Compose the Session operations of `transcriptDelivery` (`transcriptDelivery_ops`). -/
theorem transcriptDelivery_prefix_kept {s e t : Term} {j r : List Term}
    (h : transcriptDelivery s e j = .ok (t, r)) : PrefixKept s t := by
  rcases transcriptDelivery_ops h with rfl | ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _,
    appended, written, obligated, bumped, reset⟩
  · exact prefix_kept_refl _
  · exact prefix_kept_trans (appendFields_prefix_kept appended) (prefix_kept_trans
      (write_prefix_kept written (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent))
      (prefix_kept_trans (addObligation_prefix_kept obligated)
        (prefix_kept_trans (bumpHwm_prefix_kept bumped) (resetFresh_prefix_kept reset))))

theorem transcriptDelivery_prefix_kept_step {s e t : Term} {j r : List Term} :
    transcriptDelivery s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptDelivery s e j ∧ PrefixKept s t :=
  step_iff transcriptDelivery_prefix_kept

/-- Compose the two writes of `transcriptSeed` (`transcriptSeed_ops`). -/
theorem transcriptSeed_prefix_kept {s e t : Term} {j r : List Term} (h : transcriptSeed s e j = .ok (t, r)) :
    PrefixKept s t := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, seeded, bytes⟩ := transcriptSeed_ops h
  exact prefix_kept_trans
    (write_prefix_kept seeded (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent))
    (write_prefix_kept bytes (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent))

theorem transcriptSeed_prefix_kept_step {s e t : Term} {j r : List Term} :
    transcriptSeed s e j = .ok (t, r) ↔ Except.ok (t, r) = transcriptSeed s e j ∧ PrefixKept s t :=
  step_iff transcriptSeed_prefix_kept

prefix_rule queueAppend (state event)
prefix_rule queueAck (state event)
prefix_rule queueConsume (state event)

set_option backward.split false in
/-- Read-only binds do not change the Session. Compose the two writes of `sessionEvent`. This is
much cheaper than a walk over every branch of `sessionEvent`. -/
theorem sessionEvent_prefix_kept {s e t : Term} {j r : List Term} (h : sessionEvent s e j = .ok (t, r)) :
    PrefixKept s t := by
  unfold sessionEvent at h
  have kept : PrefixKept s s := prefix_kept_refl s
  repeat' first
    | (execution_head_is h "VerifiedKernel.Data.write"
       exact prefix_kept_trans kept
         (write_prefix_kept h (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent)))
    | (execution_head_is h "Bind.bind"
       have bound := bind_ok h
       clear h
       obtain ⟨value, _, prior, h⟩ := bound
       first
         | (execution_head_is prior "VerifiedKernel.Data.write"
            replace kept := prefix_kept_trans kept
              (write_prefix_kept prior (by keys_absent) (by keys_absent) (by keys_absent) (by keys_absent)
                (by keys_absent)))
         | (execution_head_is prior "Pure.pure"; have same := pure_ok prior; subst value)
         | skip)
    | dsimp only at h
    | split at h

theorem sessionEvent_prefix_kept_step {s e t : Term} {j r : List Term} :
    sessionEvent s e j = .ok (t, r) ↔ Except.ok (t, r) = sessionEvent s e j ∧ PrefixKept s t :=
  step_iff sessionEvent_prefix_kept

prefix_rule capabilitySync (state event)

theorem afterEvent_prefix_kept {previous next e t : Term} {j r : List Term}
    (h : afterEvent previous next e j = .ok (t, r)) : PrefixKept next t := by
  unfold afterEvent at h
  prefix_kept_walk h

/-! ### Events -/

/-- The event types whose reducers can change what a later provider request reads before its new
messages. -/
def prefixEventTypes : List String :=
  ["session_system_prompt", "compaction", "provider_compaction", "ack", "archive_advance"]

/-- The type of `event` is not in `prefixEventTypes`. -/
def PrefixQuiet (event : Term) : Prop :=
  ∀ kind ∈ prefixEventTypes, (event.get (b "type") == b kind) = false

/-- Every dispatched event outside `prefixEventTypes` keeps the request fields. -/
theorem inner_prefix_kept {s e t : Term} {j r : List Term} (quiet : PrefixQuiet e)
    (h : inner s e j = .ok (t, r)) : PrefixKept s t := by
  have prompt := quiet "session_system_prompt" (by simp [prefixEventTypes])
  have summary := quiet "compaction" (by simp [prefixEventTypes])
  have provider := quiet "provider_compaction" (by simp [prefixEventTypes])
  have ack := quiet "ack" (by simp [prefixEventTypes])
  have archive := quiet "archive_advance" (by simp [prefixEventTypes])
  unfold inner at h
  simp only [prompt, summary, provider, ack, archive, Bool.false_eq_true, ↓reduceIte, ite_ok_iff] at h
  prefix_kept_walk h

/-- `runTrusted` completing with `done` keeps the request fields, for every normalized event outside
`prefixEventTypes`. -/
theorem runTrusted_done_prefix_kept {state raw next : Term} {journal : List Term}
    (quiet : ∀ event rest, shallowStringify raw journal = .ok (event, rest) → PrefixQuiet event)
    (h : runTrusted state raw journal = .tuple [a "done", next]) : PrefixKept state next := by
  unfold runTrusted at h
  split at h
  · not_done h
  split at h
  · rename_i n rest hp
    unfold prepareTrusted at hp
    simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
      or_false, pure_ok_iff, Prod.mk.injEq, reduceCtorEq, and_true] at hp
    obtain ⟨-, -, normalized, rest', hs, -, rfl, -⟩ := hp
    split at h
    · injection h with h₁
      injection h₁ with h₂ h₃
      injection h₃ with h₄
      subst h₄
      exact prefix_kept_refl _
    · not_done h
  · rename_i n normalized rest hp
    unfold prepareTrusted at hp
    simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
      pure_ok_iff, Prod.mk.injEq, reduceCtorEq, Option.some.injEq] at hp
    obtain ⟨-, -, ev, rest', hs, -, n', rest'', hn, ⟨rfl, rfl⟩, rfl⟩ := hp
    have step : PrefixKept state n := inner_prefix_kept (quiet _ _ hs) hn
    unfold runActivityTrusted at h
    split at h
    · rename_i d r ha
      split at h
      · injection h with h₁
        injection h₁ with h₂ h₃
        injection h₃ with h₄
        subst h₄
        exact prefix_kept_trans step (afterEvent_prefix_kept ha)
      · not_done h
    · not_done h
    · not_done h
  · not_done h
  · not_done h

/-- `u` follows `s` by events that `runTrusted` completes, none of them of a type in
`prefixEventTypes`. -/
inductive PrefixRuns : Term → Term → Prop
  | refl (s : Term) : PrefixRuns s s
  | step {s t u raw : Term} {journal : List Term}
      (quiet : ∀ event rest, shallowStringify raw journal = .ok (event, rest) → PrefixQuiet event)
      (h : runTrusted s raw journal = .tuple [a "done", t]) (rest : PrefixRuns t u) : PrefixRuns s u

theorem PrefixRuns.kept {s u : Term} : PrefixRuns s u → PrefixKept s u
  | .refl s => prefix_kept_refl s
  | .step quiet h rest => prefix_kept_trans (runTrusted_done_prefix_kept quiet h) rest.kept

theorem PrefixRuns.transcript {s u : Term} : PrefixRuns s u → TranscriptRuns s u
  | .refl s => .refl s
  | .step quiet h rest =>
    .step (fun event r read => quiet event r read "archive_advance" (by simp [prefixEventTypes])) h
      rest.transcript

theorem PrefixKept.window {s s' : Term} (h : PrefixKept s s') : RequestPrefix.SameWindow s s' := by
  refine ⟨h.1, ?_⟩
  intro k member
  simp only [List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with rfl | rfl | rfl
  · exact h.2.2.1
  · exact h.2.2.2.1
  · exact h.2.2.2.2.1

theorem PrefixKept.prompt {s s' : Term} (h : PrefixKept s s') :
    s'.get (a "system_prompt") = s.get (a "system_prompt") := h.2.1.2.1

theorem PrefixKept.watermark {s s' : Term} (h : PrefixKept s s') :
    RequestPrefix.watermark s' = RequestPrefix.watermark s := by
  obtain ⟨map, -, -, -, -, has, get, binary⟩ := h
  simp only [RequestPrefix.watermark, RoundQuery.valueOf, map, has, get, binary]

end VerifiedKernel.Session.PrefixEvents

namespace VerifiedKernel.RequestPrefix
open Data
open Session.PrefixEvents (PrefixRuns)

/-- **Consecutive requests share a prefix across ordinary events.** `s'` follows `s` by completed
events whose types are not in `prefixEventTypes`. Then the conclusion of
`consecutive_requests_share_prefix` holds without its state conditions. -/
theorem runs_share_prefix {s s' delta delta' cfg tools mode body body' : Term} {name : ByteArray}
    {xs : List Term} {pre pre' : List (Term × Term)} {J J' K K' : List Term} {host : Term → Term}
    (protocol : String.fromUTF8! name ∈ ["chat", "anthropic", "responses"])
    (hJ : HostAnswers host J) (hJ' : HostAnswers host J') (hpre : PrefetchSound host pre)
    (hpre' : PrefetchSound host pre')
    (runs : PrefixRuns s s') (msgs : s.get (a "messages") = list xs)
    (h : Session.Request.dispatch s (.tuple [delta, .binary name, cfg, tools, mode]) pre J =
      .ok (body, K))
    (h' : Session.Request.dispatch s' (.tuple [delta', .binary name, cfg, tools, mode]) pre' J' =
      .ok (body', K')) :
    let pr := String.fromUTF8! name
    let md := String.fromUTF8! (Provider.bytes mode)
    ∃ D Y tools' b₁ b₂, tools = list tools' ∧
      (∃ X j k, Provider.Request.body pr cfg (wire pr (D ++ X)) (wire pr tools') md j = .ok (b₁, k)) ∧
      (∃ j k, Provider.encode (Provider.scrub b₁) j = .ok (body, k)) ∧
      (∃ X j k, Provider.Request.body pr cfg (wire pr (D ++ (Y ++ X))) (wire pr tools') md j = .ok (b₂, k)) ∧
      (∃ j k, Provider.encode (Provider.scrub b₂) j = .ok (body', k)) ∧
      (∃ C C', (∃ j k, Session.Request.context s j = .ok (list C, k)) ∧
        (∃ j k, Session.Request.context s' j = .ok (list (C ++ C'), k)) ∧
        D = (promptHead (Session.ReplyQuery.presentTerm (s.get (a "system_prompt"))) ++ C).map
          (inlineOne host (watermark s)) ∧
        Y = C'.map (inlineOne host (watermark s'))) ∧
      ∀ b₀ j k, Provider.Request.body pr cfg (wire pr D) (wire pr tools') md j = .ok (b₀, k) →
        ProviderLoop.ClosedHistory (wire pr D) →
        ProviderLoop.headOf pr b₁ = ProviderLoop.headOf pr b₀ ∧ ProviderLoop.headOf pr b₂ = ProviderLoop.headOf pr b₀ ∧
          ProviderLoop.messagesOf pr b₀ <+: ProviderLoop.messagesOf pr b₁ ∧
          ProviderLoop.messagesOf pr b₀ <+: ProviderLoop.messagesOf pr b₂ :=
  consecutive_requests_share_prefix protocol hJ hJ' hpre hpre' runs.kept.window runs.kept.prompt msgs
    runs.transcript.extends (AckFrame.of_watermark runs.kept.watermark) h h'

end VerifiedKernel.RequestPrefix
