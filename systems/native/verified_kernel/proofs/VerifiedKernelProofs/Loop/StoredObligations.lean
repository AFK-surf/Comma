import VerifiedKernelProofs.Loop.Discharge
import VerifiedKernelProofs.Session.WorkLifecycle
import VerifiedKernelProofs.Session.WorkForkProgram
import VerifiedKernelProofs.Session.WorkIdentityReload
import VerifiedKernelProofs.Session.WorkReadRevision

/-!
# M4: every kernel-built Session keeps binary obligation keys

`Discharge.blocking_agree` shows that `obligationBlocking` and
`blockingObligationCount` agree on a state whose stored obligation targets
carry only binary keys (`StoredBinary`). This module shows that the Session
entry points of the kernel produce such states, and that every kernel batch
keeps them.

`obligationMap` reads the binary field key `"provider_reply_obligations"`
first and the atom field key second. `normalize` rewrites only the atom field.
A truthy binary field thus hides the normalized table. `Canonical` therefore
also requires that the binary field is not truthy. Every kernel writer uses
atom field keys, so every reducer keeps the binary field.
-/

namespace VerifiedKernel.Session.LoopDischarge
open Data WorkConservation LoopProof

set_option Elab.async false
set_option maxHeartbeats 1000000

/-! ## The invariant -/

/-- The binary-keyed obligation field of the Session state is absent or falsy. -/
def NoBinaryTable (s : Term) : Prop := (s.get (b "provider_reply_obligations")).truthy = false

/-- The obligation table comes from the atom field, and its targets carry only binary keys. -/
def Canonical (s : Term) : Prop := NoBinaryTable s ∧ StoredBinary s

/-- The step keeps the binary-keyed obligation field. -/
def BinaryKept (s t : Term) : Prop :=
  t.get (b "provider_reply_obligations") = s.get (b "provider_reply_obligations")

theorem binary_kept_refl (s : Term) : BinaryKept s s := rfl

theorem binary_kept_trans {s t u : Term} (first : BinaryKept s t) (second : BinaryKept t u) :
    BinaryKept s u := second.trans first

theorem ReplyFrame.binary {s t : Term} (frame : ReplyFrame s t) : BinaryKept s t := frame.2.2

theorem write_binary_kept {s t : Term} {entries : List (String × Term)} {j r : List Term}
    (h : write s entries j = .ok (t, r)) : BinaryKept s t := write_binary_frame h

theorem put_atom_binary_kept (s v : Term) (key : String) : BinaryKept s (s.put (a key) v) :=
  get_put_atom_binary s v key _

theorem ReplyFrame.canonical {s t : Term} (frame : ReplyFrame s t) (canonical : Canonical s) :
    Canonical t := by
  refine ⟨?_, frame.stored canonical.2⟩
  unfold NoBinaryTable
  rw [frame.binary]
  exact canonical.1

/-- A state with a falsy binary field reads its obligation table from the atom field. -/
theorem obligationMap_atom {s : Term} (absent : NoBinaryTable s) :
    obligationMap s = (let v := s.get (a "provider_reply_obligations"); if v.isMap then v else empty) := by
  unfold obligationMap obligationValue Term.default
  unfold NoBinaryTable at absent
  simp only [absent, Bool.false_eq_true, ↓reduceIte]

/-- A falsy binary field and a binary-valued atom table give a canonical state. -/
theorem canonical_of_table {s table : Term} (absent : NoBinaryTable s)
    (read : s.get (a "provider_reply_obligations") = table) (values : mapValuesBinary table) :
    Canonical s := by
  refine ⟨absent, ?_⟩
  intro pair member
  unfold tableEntries at member
  rw [obligationMap_atom absent, read] at member
  cases table with
  | map xs => exact values pair member
  | _ => simp [Term.isMap, empty] at member

/-- A state whose table has no entries is stored-binary. -/
theorem stored_of_empty {s : Term} (none : tableEntries s = []) : StoredBinary s := by
  intro pair member
  rw [none] at member
  cases member

/-! ## Normalization -/

theorem fillDefaults_binary (s : Term) : BinaryKept s (Lifecycle.fillDefaults s) := by
  unfold Lifecycle.fillDefaults
  have folded : ∀ (entries : List (String × Term)) (state : Term),
      BinaryKept state (entries.foldl (fun current pair =>
        if current.has (a pair.1) then current else current.put (a pair.1) pair.2) state) := by
    intro entries
    induction entries with
    | nil => intro state; rfl
    | cons pair rest ih =>
      intro state
      rw [List.foldl_cons]
      split
      · exact ih state
      · exact binary_kept_trans (put_atom_binary_kept state pair.2 pair.1) (ih _)
  exact folded Lifecycle.defaults s

/-- `normalize` keeps the binary field and stores a normalized table in the atom field. -/
theorem normalize_obligations {s t : Term} {j r : List Term}
    (h : Lifecycle.normalize s j = .ok (t, r)) :
    BinaryKept s t ∧ ∃ table, t.get (a "provider_reply_obligations") = table ∧ mapValuesBinary table := by
  have filled := fillDefaults_binary s
  unfold Lifecycle.normalize at h
  repeat
    fail_if_success (bind_head_is h [Lifecycle.obligationTable])
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨table, _, tableCall, h⟩ := bind_ok h
  repeat
    fail_if_success (bind_head_is h [write])
    obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨normalized, _, written, h⟩ := bind_ok h
  have firstBinary := write_binary_kept written
  have selected : normalized.get (a "provider_reply_obligations") = table := by
    iterate 16 obtain ⟨_, written⟩ := write_cons written
    obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written (by simp)).trans (get_put_same _ _ _)
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨activityState, _, activityWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨providerState, _, providerWrite, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  refine ⟨?_, table, ?_, obligationTable_binary tableCall⟩
  · exact binary_kept_trans filled (binary_kept_trans firstBinary (binary_kept_trans
      (write_binary_kept activityWrite) (binary_kept_trans (write_binary_kept providerWrite) (write_binary_kept h))))
  · exact (write_field_frame h (by simp)).trans
      ((write_field_frame providerWrite (by simp)).trans ((write_field_frame activityWrite (by simp)).trans selected))

/-- `normalize` of a state with a falsy binary field gives a canonical state. -/
theorem normalize_canonical_of_absent {s t : Term} {j r : List Term} (absent : NoBinaryTable s)
    (h : Lifecycle.normalize s j = .ok (t, r)) : Canonical t := by
  obtain ⟨kept, table, read, values⟩ := normalize_obligations h
  refine canonical_of_table ?_ read values
  unfold NoBinaryTable
  rw [kept]
  exact absent

/-- `normalize` keeps the stored-target invariant, whatever the binary field holds. -/
theorem normalize_stored {s t : Term} {j r : List Term} (stored : StoredBinary s)
    (h : Lifecycle.normalize s j = .ok (t, r)) : StoredBinary t := by
  by_cases absent : NoBinaryTable s
  · exact (normalize_canonical_of_absent absent h).2
  · obtain ⟨kept, _⟩ := normalize_obligations h
    have same : obligationMap t = obligationMap s := by
      unfold obligationMap obligationValue Term.default
      unfold NoBinaryTable at absent
      rw [kept]
      simp only [Bool.not_eq_false] at absent
      simp only [absent, ↓reduceIte]
    intro pair member
    unfold tableEntries at member
    rw [same] at member
    exact stored pair member

theorem normalize_canonical {s t : Term} {j r : List Term} (canonical : Canonical s)
    (h : Lifecycle.normalize s j = .ok (t, r)) : Canonical t :=
  normalize_canonical_of_absent canonical.1 h

/-! ## Creation -/

theorem blank_binary (k : ByteArray) : Lifecycle.blank.get (.binary k) = nil := by
  unfold Lifecycle.blank
  simp only [Term.get]
  have none : ((a "__struct__", a "Elixir.SalixAgent.InternalSession.State") ::
      Lifecycle.defaults.map (fun pair => (a pair.1, pair.2))).find?
        (fun entry => entry.1 == Term.binary k) = none := by
    rw [List.find?_eq_none]
    intro entry member
    rcases List.mem_cons.mp member with same | mapped
    · subst same; simp [BEq.beq]
    · obtain ⟨pair, _, same⟩ := List.mem_map.mp mapped
      subst same; simp [BEq.beq]
  rw [none]
  rfl

theorem build_absent (overrides : List (String × Term)) : NoBinaryTable (Lifecycle.build overrides) := by
  have kept : BinaryKept Lifecycle.blank (Lifecycle.build overrides) := by
    unfold Lifecycle.build
    have folded : ∀ (xs : List (String × Term)) (state : Term),
        BinaryKept state (xs.foldl (fun state pair => state.put (a pair.1) pair.2) state) := by
      intro xs
      induction xs with
      | nil => intro state; rfl
      | cons pair rest ih =>
        intro state
        rw [List.foldl_cons]
        exact binary_kept_trans (put_atom_binary_kept state pair.2 pair.1) (ih _)
    exact folded overrides _
  unfold NoBinaryTable
  rw [kept, b, Term.text, blank_binary]
  rfl

theorem normalize_build_canonical {overrides : List (String × Term)} {t : Term} {j r : List Term}
    (h : Lifecycle.normalize (Lifecycle.build overrides) j = .ok (t, r)) : Canonical t :=
  normalize_canonical_of_absent (build_absent overrides) h

/-- `State.new/3` gives a canonical state. -/
theorem create_canonical {state args t : Term} {j r : List Term}
    (h : Lifecycle.create state args j = .ok (t, r)) : Canonical t := by
  unfold Lifecycle.create at h
  split at h
  · repeat
      fail_if_success head_is h [Lifecycle.normalize]
      obtain ⟨_, _, _, h⟩ := bind_ok h
    exact normalize_build_canonical h
  · exact (fail_ok h).elim

/-- `State.persistable/1` keeps a canonical state. -/
theorem persistable_canonical {s t : Term} {j r : List Term} (canonical : Canonical s)
    (h : Lifecycle.persistable s j = .ok (t, r)) : Canonical t := by
  have same := put_ok h
  subst same
  refine ReplyFrame.canonical ⟨?_, ?_, ?_⟩ canonical
  · exact get_put_other _ _ (by decide)
  · exact get_put_other _ _ (by decide)
  · exact get_put_atom_binary _ _ _ _

/-! ## Fork and write preparation -/

theorem rebuildRefs_frame {s t : Term} {j r : List Term} (h : rebuildRefs s j = .ok (t, r)) :
    ReplyFrame s t := by
  unfold rebuildRefs at h
  repeat
    fail_if_success head_is h [write]
    obtain ⟨_, _, _, h⟩ := bind_ok h
  exact write_reply_frame h (by simp) (by simp)

theorem ok_tuple_eq {x t : Term} (same : Term.tuple [a "ok", x] = Term.tuple [a "ok", t]) : x = t := by
  simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same

/-- Walk a lifecycle body whose success result is `{:ok, state}`. The walk
proves `ReplyFrame` from the writes and `rebuildRefs` calls on the way. -/
syntax "ok_frame_walk" ident : tactic
macro_rules
  | `(tactic| ok_frame_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let same := Lean.mkIdent `same
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]
         have $same:ident := pure_ok $h
         first
           | (simp [a] at $same:ident; done)
           | (have $same:ident := ok_tuple_eq $same; subst $same; exact reply_frame_refl _))
      | (head_is $h [VerifiedKernel.fail]; exact (fail_ok $h).elim)
      | (head_is $h [rebuildRefs]; exact rebuildRefs_frame $h)
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [write]; refine reply_frame_trans (write_reply_frame $hx (by simp) (by simp)) ?_)
           | (head_is $hx [rebuildRefs]; refine reply_frame_trans (rebuildRefs_frame $hx) ?_)
           | (head_is $hx [VerifiedKernel.fail]; exact (fail_ok $hx).elim)
           | skip)
      | split at $h:ident
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | dsimp only at $h:ident)

/-- The legacy migration keeps the reply fields. -/
theorem migrateFormat1_frame {s t : Term} {j r : List Term}
    (h : Legacy.migrateFormat1 s j = .ok (.tuple [a "ok", t], r)) : ReplyFrame s t := by
  unfold Legacy.migrateFormat1 at h
  ok_frame_walk h

theorem legacyFork_canonical {source session attrs maxId t : Term} {j r : List Term}
    (h : Fork.legacyFork source session attrs maxId j = .ok (t, r)) : Canonical t := by
  unfold Fork.legacyFork at h
  repeat'
    fail_if_success head_is h [Lifecycle.normalize]
    first
      | (head_is h [VerifiedKernel.fail]; exact (fail_ok h).elim)
      | (obtain ⟨_, _, _, h⟩ := bind_ok h)
      | split at h
      | dsimp only at h
  all_goals exact normalize_build_canonical h

theorem currentFork_canonical {source session attrs maxId t : Term} {j r : List Term}
    (h : Fork.currentFork source session attrs maxId j = .ok (t, r)) : Canonical t := by
  rw [current_fork_factor] at h
  unfold forkSelection at h
  repeat'
    fail_if_success bind_head_is h [Lifecycle.normalize]
    first
      | (head_is h [VerifiedKernel.fail]; exact (fail_ok h).elim)
      | (obtain ⟨_, _, _, h⟩ := bind_ok h)
      | split at h
      | dsimp only at h
  all_goals
    obtain ⟨child, _, normalized, h⟩ := bind_ok h
    exact (rebuildRefs_frame h).canonical (normalize_build_canonical normalized)

/-- A fork gives a canonical state, whatever the source holds. -/
theorem fork_canonical {source args t : Term} {j r : List Term}
    (h : Fork.fork source args j = .ok (.tuple [a "ok", t], r)) : Canonical t := by
  unfold Fork.fork at h
  split at h
  · obtain ⟨_, _, _, h⟩ := bind_ok h
    obtain ⟨_, _, _, h⟩ := bind_ok h
    split at h
    · obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, _, _, h⟩ := bind_ok h
      rcases ite_ok_iff.mp h with ⟨_, rejected⟩ | ⟨_, accepted⟩
      · have impossible := pure_ok rejected
        simp [a] at impossible
      · obtain ⟨child, _, forked, returned⟩ := bind_ok accepted
        have same := ok_tuple_eq (pure_ok returned)
        subst same
        exact currentFork_canonical forked
    · obtain ⟨child, _, legacy, h⟩ := bind_ok h
      have canonical := legacyFork_canonical legacy
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨_, _, _, h⟩ := bind_ok h
      obtain ⟨written, _, write, h⟩ := bind_ok h
      exact (migrateFormat1_frame h).canonical ((write_reply_frame write (by simp) (by simp)).canonical canonical)
  · exact (fail_ok h).elim

/-- `prepare_write` keeps a canonical state. -/
theorem prepareWrite_canonical {s t : Term} {j r : List Term} (canonical : Canonical s)
    (h : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", t], r)) : Canonical t := by
  unfold Lifecycle.prepareWrite at h
  obtain ⟨normalized, _, normal, h⟩ := bind_ok h
  have start := normalize_canonical canonical normal
  obtain ⟨_, _, _, h⟩ := bind_ok h
  split at h
  · exact (migrateFormat1_frame h).canonical start
  · split at h
    · obtain ⟨written, _, write, h⟩ := bind_ok h
      have same := ok_tuple_eq (pure_ok h)
      subst same
      exact (write_reply_frame write (by simp) (by simp)).canonical start
    · have impossible := pure_ok h
      simp [a] at impossible

/-! ## Every reducer keeps the binary field

Every reducer writes the Session state through `write`, which puts atom keys
only. The walk below follows the reducer body and composes `BinaryKept`. -/

theorem addObligation_binary {s raw t : Term} {j r : List Term}
    (call : addObligation s raw j = .ok (t, r)) : BinaryKept s t := by
  unfold addObligation at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · exact write_binary_kept call
  · have same := pure_ok call
    subst same
    exact binary_kept_refl _

syntax "binary_walk" ident : tactic
macro_rules
  | `(tactic| binary_walk $h:ident) => do
  let hx := Lean.mkIdent `hx
  let same := Lean.mkIdent `same
  let kept := Lean.mkIdent `kept
  `(tactic| repeat' first
      | (head_is $h [Pure.pure]; have $same:ident := pure_ok $h; subst $same; exact binary_kept_refl _)
      | (head_is $h [argumentError, inspectedError, VerifiedKernel.fail]
         simp only [argumentError, inspectedError, fail_ok_iff] at $h:ident)
      | (head_is $h [write]; exact write_binary_kept $h)
      | (head_is $h [addObligation]; exact addObligation_binary $h)
      | (head_step $h "_reply_frame_step"; obtain ⟨_, $kept:ident⟩ := $h; exact ReplyFrame.binary $kept)
      | split at $h:ident
      | (generalize Term.get _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.filter _ _ = discriminant at $h:ident; split at $h:ident)
      | (generalize List.find? _ _ = discriminant at $h:ident; split at $h:ident)
      | (obtain ⟨_, $h:ident⟩ | ⟨_, $h:ident⟩ := ($h : _ ∨ _))
      | ((obtain ⟨_, _, $hx:ident, $h:ident⟩ := bind_ok $h)
         first
           | (head_is $hx [Pure.pure]; have $same:ident := pure_ok $hx; subst $same)
           | (head_is $hx [VerifiedKernel.fail]; exact (fail_ok $hx).elim)
           | (head_is $hx [write]; refine binary_kept_trans (write_binary_kept $hx) ?_)
           | (head_is $hx [addObligation]; refine binary_kept_trans (addObligation_binary $hx) ?_)
           | (head_step $hx "_reply_frame_step"; obtain ⟨_, $kept:ident⟩ := $hx
              refine binary_kept_trans (ReplyFrame.binary $kept) ?_)
           | skip)
      | dsimp only at $h:ident)

theorem sessionAck_binary {s e t : Term} {j r : List Term} (call : sessionAck s e j = .ok (t, r)) :
    BinaryKept s t := by
  unfold sessionAck at call
  binary_walk call

theorem obligationResolve_binary {s key t : Term} {j r : List Term}
    (call : obligationResolve s key j = .ok (t, r)) : BinaryKept s t := by
  unfold obligationResolve at call
  binary_walk call

set_option backward.split false in
theorem obligationCard_binary {s conversation limit t : Term} {j r : List Term}
    (call : obligationCard s conversation limit j = .ok (t, r)) : BinaryKept s t := by
  unfold obligationCard at call
  binary_walk call

theorem transcriptDelivery_binary {s e t : Term} {j r : List Term}
    (call : transcriptDelivery s e j = .ok (t, r)) : BinaryKept s t := by
  unfold transcriptDelivery at call
  binary_walk call

theorem inner_binary {s e t : Term} {j r : List Term} (h : inner s e j = .ok (t, r)) : BinaryKept s t := by
  unfold inner at h
  simp only [ite_ok_iff] at h
  repeat' (obtain ⟨_, h⟩ | ⟨_, h⟩ := (h : _ ∨ _))
  all_goals first
    | (head_is h [sessionAck]; exact sessionAck_binary h)
    | (head_is h [obligationResolve]; exact obligationResolve_binary h)
    | (head_is h [obligationCard]; exact obligationCard_binary h)
    | (head_is h [transcriptDelivery]; exact transcriptDelivery_binary h)
    | (fail_if_success head_is h [sessionAck, obligationResolve, obligationCard, transcriptDelivery]
       binary_walk h)

/-- Every reducer keeps a canonical state. -/
theorem inner_canonical {s e t : Term} {j r : List Term} (h : inner s e j = .ok (t, r))
    (canonical : Canonical s) : Canonical t := by
  refine ⟨?_, inner_stored h canonical.2⟩
  unfold NoBinaryTable
  rw [inner_binary h]
  exact canonical.1

/-! ## Batches keep a canonical state

The walk copies `resident_batch_stored` with `Canonical` in place of `StoredBinary`. -/

/-- The step keeps a canonical state. -/
def CanonicalStep (s t : Term) : Prop := Canonical s → Canonical t

theorem canonical_refl (s : Term) : CanonicalStep s s := id

theorem canonical_trans {s t u : Term} (first : CanonicalStep s t) (second : CanonicalStep t u) :
    CanonicalStep s u := fun canonical => second (first canonical)

theorem ReplyFrame.canonicalStep {s t : Term} (frame : ReplyFrame s t) : CanonicalStep s t :=
  frame.canonical

theorem prepareTrusted_canonical {s raw next : Term} {normalized : Option Term} {j r : List Term}
    (h : prepareTrusted s raw j = .ok ((next, normalized), r)) : CanonicalStep s next := by
  cases normalized with
  | none => rw [prepareTrusted_none h]; exact canonical_refl _
  | some event =>
    obtain ⟨_, _, _, reduced⟩ := prepareTrusted_stringify h
    exact fun canonical => inner_canonical reduced canonical

def CanonicalToken (state raw : Term) : Term → Prop
  | .tuple [.atom "reduce", current, event, .list _] => current = state ∧ event = raw
  | .tuple [.atom "activity", resident, _, _, _, .list _] => CanonicalStep state resident
  | _ => False

def CanonicalTrace (state raw : Term) : Term → Prop
  | .tuple [.atom "done", final] => CanonicalStep state final
  | .tuple [.atom "observe", _, token] => CanonicalToken state raw token
  | _ => True

theorem runActivityTrusted_canonical {state raw original next event : Term} {observations : List Term}
    (valid : CanonicalStep state next) :
    CanonicalTrace state raw (runActivityTrusted original next event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent original next event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact canonical_trans valid (afterEvent_reply_frame result).canonicalStep
    · trivial
  | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial

theorem runTrusted_canonical {state raw : Term} {observations : List Term} :
    CanonicalTrace state raw (runTrusted state raw observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted state raw observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      have kept := prepareTrusted_canonical result
      cases normalized with
      | none => dsimp only; split <;> first | exact kept | trivial
      | some event => dsimp only; exact runActivityTrusted_canonical kept
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_canonical {state raw token observation : Term} (valid : CanonicalToken state raw token) :
    CanonicalTrace state raw (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · obtain ⟨same, sameRaw⟩ := valid
      subst same sameRaw
      exact runTrusted_canonical
    · rename_i resident current next event observations
      change CanonicalStep state resident at valid
      dsimp only
      cases result : afterEvent current next event (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change CanonicalStep state (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          split
          · exact canonical_trans (canonical_trans valid (put_activity_frame _ _ (by decide) (by decide)).canonicalStep)
              (put_activity_frame _ _ (by decide) (by decide)).canonicalStep
          · exact canonical_trans valid (put_activity_frame _ _ (by decide) (by decide)).canonicalStep
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

theorem resident_trace_canonical {state raw initial final : Term} (trace : ResidentTrace initial final)
    (valid : CanonicalTrace state raw initial) : CanonicalTrace state raw final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_canonical valid)

/-- A resident batch keeps a canonical state. -/
theorem resident_batch_canonical {s t : Term} {events : List Term} (execution : ResidentBatch s events t)
    (canonical : Canonical s) : Canonical t := by
  induction execution with
  | nil => exact canonical
  | cons head tail ih => exact ih (resident_trace_canonical head runTrusted_canonical canonical)

/-- A projected batch keeps a canonical state. -/
theorem project_canonical {s t : Term} {events j r : List Term}
    (h : Command.project s events j = .ok (t, r)) (canonical : Canonical s) : Canonical t := by
  obtain ⟨_, trace⟩ := project_execution h
  clear h
  revert canonical
  induction trace with
  | nil => exact id
  | skip prepared tail ih => exact fun canonical => ih (prepareTrusted_canonical prepared canonical)
  | cons prepared activity tail ih =>
    exact fun canonical =>
      ih ((afterEvent_reply_frame activity).canonical (prepareTrusted_canonical prepared canonical))

/-! ## Load paths -/

/-- Map order and field presence carry over to a decoded copy, so the binary field stays falsy. -/
theorem equivalent_absent {x y : Term} (codec : ValueSemantics.Equivalent x y) (absent : NoBinaryTable x) :
    NoBinaryTable y := by
  unfold NoBinaryTable at *
  rw [← (codec.get (b "provider_reply_obligations")).truthy]
  exact absent

/-- A snapshot that the kernel persisted from a canonical state decodes without a truthy binary field. -/
theorem snapshot_absent {s snapshot decoded : Term} {j r : List Term} (canonical : Canonical s)
    (persisted : Lifecycle.persistable s j = .ok (snapshot, r))
    (codec : ValueSemantics.Equivalent snapshot decoded) : NoBinaryTable decoded :=
  equivalent_absent codec (persistable_canonical canonical persisted).1

/-- `session load` normalizes the decoded snapshot. The result is canonical when
the snapshot has no truthy binary-keyed obligation field. -/
theorem load_canonical {resident : Option Term} {decoded t : Term} {bytes : ByteArray}
    (decodedEq : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (ready : QueueReady decoded) (absent : NoBinaryTable decoded)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) : Canonical t := by
  obtain ⟨_, _, normalized⟩ := load_trace_normalizes decodedEq ready trace
  exact normalize_canonical_of_absent absent normalized

/-- The `session_read` path stores a canonical working state in its cursor. -/
theorem read_canonical {agent session bytes etag : ByteArray} {snapshot cursor : Term}
    {observations : List Term}
    (decodedEq : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, snapshot]))
    (ready : QueueReady snapshot) (absent : NoBinaryTable snapshot)
    (trace : SessionDomain.ReadRevision.LoadTrace
      (SessionDomain.ReadRevision.resident
        (some (.tuple [a "session_read_pending", .binary agent, .binary session,
          SessionDomain.ReadRevision.key agent session]))
        (a "read_result") (.tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations])) cursor) :
    ∃ state, Canonical state ∧ cursor = (Revision.Cursor.committed state (.binary etag)).pack := by
  obtain ⟨state, _, _, normalized, _, _, _, captured⟩ :=
    SessionDomain.ReadRevision.read_result_normalizes decodedEq ready trace
  exact ⟨state, normalize_canonical_of_absent absent normalized, captured⟩

/-! ## Kernel sessions -/

/-- The Session states that the kernel entry points build, and every state that
kernel steps reach from them.

* `created`, `forked`: `State.new/3` and `fork_from`.
* `loaded`: `normalize` of a decoded snapshot without a truthy binary-keyed
  obligation field. `snapshot_absent` shows this for every snapshot that the
  kernel persisted from a `KernelSession`. A snapshot from another writer
  needs this as an assumption.
* The other constructors are the kernel lifecycle operations and batches.

`session open` and `session admit` install a host-built map without
normalization. They are not constructors here. -/
inductive KernelSession : Term → Prop where
  | created {state args t : Term} {j r : List Term}
      (call : Lifecycle.create state args j = .ok (t, r)) : KernelSession t
  | forked {source args t : Term} {j r : List Term}
      (call : Fork.fork source args j = .ok (.tuple [a "ok", t], r)) : KernelSession t
  | loaded {decoded t : Term} {j r : List Term} (absent : NoBinaryTable decoded)
      (call : Lifecycle.normalize decoded j = .ok (t, r)) : KernelSession t
  | normalized {s t : Term} {j r : List Term} (prior : KernelSession s)
      (call : Lifecycle.normalize s j = .ok (t, r)) : KernelSession t
  | prepared {s t : Term} {j r : List Term} (prior : KernelSession s)
      (call : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", t], r)) : KernelSession t
  | persisted {s t : Term} {j r : List Term} (prior : KernelSession s)
      (call : Lifecycle.persistable s j = .ok (t, r)) : KernelSession t
  | batch {s t : Term} {events : List Term} (prior : KernelSession s)
      (execution : ResidentBatch s events t) : KernelSession t
  | projected {s t : Term} {events j r : List Term} (prior : KernelSession s)
      (call : Command.project s events j = .ok (t, r)) : KernelSession t
  | reduced {s e t : Term} {j r : List Term} (prior : KernelSession s)
      (call : inner s e j = .ok (t, r)) : KernelSession t

theorem KernelSession.canonical {s : Term} (reached : KernelSession s) : Canonical s := by
  induction reached with
  | created call => exact create_canonical call
  | forked call => exact fork_canonical call
  | loaded absent call => exact normalize_canonical_of_absent absent call
  | normalized _ call ih => exact normalize_canonical ih call
  | prepared _ call ih => exact prepareWrite_canonical ih call
  | persisted _ call ih => exact persistable_canonical ih call
  | batch _ execution ih => exact resident_batch_canonical execution ih
  | projected _ call ih => exact project_canonical call ih
  | reduced _ call ih => exact inner_canonical call ih

/-- A persisted kernel session reloads as a kernel session. -/
theorem KernelSession.reload {s snapshot decoded t : Term} {j r j' r' : List Term}
    (reached : KernelSession s) (persisted : Lifecycle.persistable s j = .ok (snapshot, r))
    (codec : ValueSemantics.Equivalent snapshot decoded)
    (call : Lifecycle.normalize decoded j' = .ok (t, r')) : KernelSession t :=
  .loaded (snapshot_absent reached.canonical persisted codec) call

/-- M4: on every kernel session the atom-or-binary `kind` check of
`obligationBlocking` and the binary-only count of `blockingObligationCount` agree. -/
theorem kernel_session_blocking_agree {s count : Term} (reached : KernelSession s)
    (counted : Returns (ReplyQuery.blockingObligationCount s) count) :
    obligationBlocking s = decide (integerValue count > 0) :=
  blocking_agree reached.canonical.2 counted

/-- A zero blocking count on a kernel session means that an advancing ack is not blocked. -/
theorem kernel_session_zero_not_blocking {s count : Term} (reached : KernelSession s)
    (counted : Returns (ReplyQuery.blockingObligationCount s) count) (zero : integerValue count = 0) :
    obligationBlocking s = false :=
  zero_count_not_blocking reached.canonical.2 counted zero

end VerifiedKernel.Session.LoopDischarge
