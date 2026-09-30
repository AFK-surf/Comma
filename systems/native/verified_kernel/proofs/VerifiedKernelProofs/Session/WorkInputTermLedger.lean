import VerifiedKernelProofs.Session.WorkInputAliases

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem fallback_avoids_term {items seen : List Term} {key : Term}
    (different : ∀ inserted ∈ items.foldl fallbackIdentityStep seen, (inserted == key) = false) :
    (∀ inserted ∈ seen, (inserted == key) = false) ∧
      (∀ inserted ∈ items, (inserted == key) = false) := by
  induction items generalizing seen with
  | nil => exact ⟨different, by simp⟩
  | cons value items ih =>
    rw [List.foldl_cons] at different
    unfold fallbackIdentityStep at different
    split at different
    next hit =>
      obtain ⟨old, remaining⟩ := ih different
      have absent : (value == key) = false := by
        obtain ⟨earlier, member, matching⟩ := List.any_eq_true.mp hit
        cases current : value == key with
        | false => rfl
        | true =>
          have impossible := Term.beq_trans matching current
          rw [old earlier member] at impossible
          contradiction
      exact ⟨old, fun inserted member => by
        rcases List.mem_cons.mp member with rfl | tail
        · exact absent
        · exact remaining inserted tail⟩
    next noHit =>
      obtain ⟨old, remaining⟩ := ih different
      exact ⟨fun inserted member => old inserted (List.mem_append_left _ member),
        fun inserted member => by
          rcases List.mem_cons.mp member with rfl | tail
          · exact old inserted (List.mem_append_right _ (by simp))
          · exact remaining inserted tail⟩

theorem uniq_avoids_term {items : List Term} {key : Term}
    (different : ∀ inserted ∈ uniq items, (inserted == key) = false) :
    ∀ inserted ∈ items, (inserted == key) = false := by
  by_cases binary : items.all Term.isBinary = true
  · intro inserted member
    have typed := List.all_eq_true.mp binary inserted member
    cases inserted with
    | binary raw =>
      cases key with
      | binary bytes => exact uniq_avoids_binary different _ member
      | _ => rfl
    | _ => contradiction
  · unfold uniq at different
    rw [if_neg binary] at different
    exact (fallback_avoids_term different).2

theorem transcriptLog_checked_term_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "session_log_message")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : transcriptLog s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold Command.inputIdentityGroups at checked
  simp +decide only [kind] at checked
  have groupsEq := pure_ok checked
  subst groups
  apply transcriptLog_ledger_absent absent ?_ h
  apply uniq_avoids_term
  intro inserted member
  exact different inserted (by simpa using member)

theorem transcriptDelivery_checked_term_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (kind : e.get (b "type") = b "delivery")
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : transcriptDelivery s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  unfold Command.inputIdentityGroups at checked
  simp +decide only [kind] at checked
  cases queued : e.get (b "from_queue") == a "true"
  · have same : t = s := by
      have result : (t, r) = (s, j) := by
        simpa only [transcriptDelivery, bne, queued, Bool.not_false, ↓reduceIte, pure_ok_iff] using h
      exact (Prod.mk.inj result).1
    rw [same]; exact absent
  · simp only [bne, queued, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at checked
    have groupsEq := pure_ok checked
    subst groups
    apply transcriptDelivery_ledger_absent absent ?_ h
    apply uniq_avoids_term
    intro inserted member
    exact different inserted (by simpa only [List.flatten_cons, List.flatten_nil, List.append_nil, bne] using member)

theorem admitted_inner_checked_term_absent {s e t key : Term} {groups : List (List Term)}
    {j r before after : List Term}
    (allowed : Command.inputEventAllowed e = true)
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (h : inner s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) key := by
  by_cases append : e.get (b "type") = b "queue_append"
  · apply queueAppend_checked_ledger_absent (by simp +decide [append]) checked different absent
    simpa +decide [inner, append] using h
  by_cases runtime : e.get (b "type") = b "runtime_message"
  · apply transcriptRuntime_checked_ledger_absent runtime checked different absent
    simpa +decide [inner, runtime] using h
  by_cases log : e.get (b "type") = b "session_log_message"
  · apply transcriptLog_checked_term_absent log checked different absent
    simpa +decide [inner, log] using h
  by_cases delivery : e.get (b "type") = b "delivery"
  · apply transcriptDelivery_checked_term_absent delivery checked different absent
    simpa +decide [inner, delivery] using h
  by_cases seed : e.get (b "type") = b "transcript_seed"
  · apply transcriptSeed_checked_ledger_absent seed checked different absent
    simpa +decide [inner, seed] using h
  have frame := admitted_inner_ledger_frame allowed (binary_ne_false append) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) h
  rw [frame]
  exact absent

def TermIdentityCheckAvoids (event key : Term) : Prop :=
  ∃ groups before after, Command.inputIdentityGroups event before = .ok (groups, after) ∧
    ∀ inserted ∈ groups.flatten, (inserted == key) = false

theorem identity_map_avoids_term {events : List Term} {groups : List (List (List Term))}
    {key : Term} {j r : List Term}
    (read : events.mapM Command.inputIdentityGroups j = .ok (groups, r))
    (different : ∀ inserted ∈ groups.flatten.flatten, (inserted == key) = false) :
    ∀ event ∈ events, TermIdentityCheckAvoids event key := by
  induction events generalizing groups j r with
  | nil => simp
  | cons event events ih =>
    rw [List.mapM_cons] at read
    obtain ⟨head, middle, headRead, read⟩ := bind_ok read
    obtain ⟨tail, _, tailRead, read⟩ := bind_ok read
    have groupsEq := pure_ok read
    subst groups
    simp only [List.flatten_cons, List.flatten_append] at different
    intro current member
    rcases List.mem_cons.mp member with same | member
    · subst current
      exact ⟨head, j, middle, headRead, fun inserted present =>
        different inserted (List.mem_append_left _ present)⟩
    · exact ih tailRead (fun inserted present =>
        different inserted (List.mem_append_right _ present)) current member

theorem identity_guard_prefix_avoids_term {earlier : List Term} {main key : Term}
    {mainGroups : List (List Term)} {j r before after : List Term}
    (checked : Command.inputIdentitiesDistinct (earlier ++ [main]) j = .ok (true, r))
    (mainRead : Command.inputIdentityGroups main before = .ok (mainGroups, after))
    (member : key ∈ mainGroups.flatten) :
    ∀ event ∈ earlier, TermIdentityCheckAvoids event key := by
  obtain ⟨groups, _, read, distinct⟩ := inputIdentitiesDistinct_sound checked
  rw [List.mapM_append] at read
  obtain ⟨first, _, prefixRead, read⟩ := bind_ok read
  obtain ⟨last, _, lastRead, read⟩ := bind_ok read
  have groupsEq := pure_ok read
  subst groups
  rw [List.mapM_cons] at lastRead
  obtain ⟨actual, _, actualRead, lastRead⟩ := bind_ok lastRead
  obtain ⟨empty, _, emptyRead, lastRead⟩ := bind_ok lastRead
  have emptyEq := pure_ok emptyRead
  subst empty
  have lastEq := pure_ok lastRead
  subst last
  have same := deterministic_inputIdentityGroups main _ _ _ _ _ _ mainRead actualRead
  subst actual
  simp only [List.flatten_append, List.flatten_cons, List.reverse_nil, List.flatten_nil, List.append_nil] at distinct
  have cross := (List.pairwise_append.mp distinct).2.2
  exact identity_map_avoids_term prefixRead (fun inserted present => cross inserted present _ member)

theorem resident_input_term_absent {s e t key : Term} {observations : List Term}
    (canonical : BinaryKeys e) (allowed : Command.inputEventAllowed e = true)
    (checked : TermIdentityCheckAvoids e key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (trace : ResidentTrace (runTrusted s e observations) (.tuple [a "done", t])) :
    IdentityAbsent (t.get (a "input_dedupe")) key := by
  apply resident_execution_preserves
    (P := fun state => IdentityAbsent (state.get (a "input_dedupe")) key) absent ?_ ?_ trace
  · intro next normalized j r prepared
    cases normalized with
    | none => rw [prepareTrusted_none prepared]; exact absent
    | some normalized =>
      obtain ⟨_, read, _, reduced⟩ := prepareTrusted_stringify prepared
      have same := shallowStringify_binary_keys canonical read
      subst normalized
      obtain ⟨groups, before, after, guard, different⟩ := checked
      exact admitted_inner_checked_term_absent allowed guard different absent reduced
  · intro previous next valid frame
    rw [frame "input_dedupe" (by decide) (by decide)]
    exact valid

theorem resident_batch_input_term_absent {s t key : Term} {events : List Term}
    (execution : ResidentBatch s events t)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ events, TermIdentityCheckAvoids event key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key) :
    IdentityAbsent (t.get (a "input_dedupe")) key := by
  induction execution with
  | nil => exact absent
  | cons head tail ih =>
    have first := resident_input_term_absent (canonical _ List.mem_cons_self)
      (allowed _ List.mem_cons_self) (checked _ List.mem_cons_self) absent head
    exact ih (fun e mem => canonical e (List.mem_cons_of_mem _ mem))
      (fun e mem => allowed e (List.mem_cons_of_mem _ mem))
      (fun e mem => checked e (List.mem_cons_of_mem _ mem)) first

theorem checked_prefix_resident_term_absent {s t main key : Term} {earlier selected : List Term}
    {mainGroups : List (List Term)} {j r before after : List Term}
    (checked : Command.inputIdentitiesDistinct (earlier ++ [main]) j = .ok (true, r))
    (mainRead : Command.inputIdentityGroups main before = .ok (mainGroups, after))
    (member : key ∈ mainGroups.flatten)
    (canonical : ∀ event ∈ earlier, BinaryKeys event)
    (allowed : ∀ event ∈ earlier, Command.inputEventAllowed event = true)
    (selectedFrom : ∀ event ∈ selected, event ∈ earlier)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) key)
    (execution : ResidentBatch s selected t) :
    IdentityAbsent (t.get (a "input_dedupe")) key := by
  have avoids := identity_guard_prefix_avoids_term checked mainRead member
  exact resident_batch_input_term_absent execution
    (fun event present => canonical event (selectedFrom event present))
    (fun event present => allowed event (selectedFrom event present))
    (fun event present => avoids event (selectedFrom event present)) absent

end VerifiedKernel.Session.WorkConservation
