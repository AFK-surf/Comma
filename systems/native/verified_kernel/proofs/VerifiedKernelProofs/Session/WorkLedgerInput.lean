import VerifiedKernelProofs.Session.WorkLedgerSeed
import VerifiedKernelProofs.Session.WorkSafetyOperations

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem admitted_inner_checked_ledger_absent {s e t : Term} {key : ByteArray} {groups : List (List Term)}
    {j r before after : List Term}
    (allowed : Command.inputEventAllowed e = true)
    (checked : Command.inputIdentityGroups e before = .ok (groups, after))
    (different : ∀ inserted ∈ groups.flatten, (inserted == .binary key) = false)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (h : inner s e j = .ok (t, r)) : IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  by_cases append : e.get (b "type") = b "queue_append"
  · apply queueAppend_checked_ledger_absent (by simp +decide [append]) checked different absent
    simpa +decide [inner, append] using h
  by_cases runtime : e.get (b "type") = b "runtime_message"
  · apply transcriptRuntime_checked_ledger_absent runtime checked different absent
    simpa +decide [inner, runtime] using h
  by_cases log : e.get (b "type") = b "session_log_message"
  · apply transcriptLog_checked_ledger_absent log checked different absent
    simpa +decide [inner, log] using h
  by_cases delivery : e.get (b "type") = b "delivery"
  · apply transcriptDelivery_checked_ledger_absent delivery checked different absent
    simpa +decide [inner, delivery] using h
  by_cases seed : e.get (b "type") = b "transcript_seed"
  · apply transcriptSeed_checked_ledger_absent seed checked different absent
    simpa +decide [inner, seed] using h
  have frame := admitted_inner_ledger_frame allowed (binary_ne_false append) (binary_ne_false log)
    (binary_ne_false seed) (binary_ne_false runtime) (binary_ne_false delivery) h
  rw [frame]
  exact absent

def IdentityCheckAvoids (event : Term) (key : ByteArray) : Prop :=
  ∃ groups before after, Command.inputIdentityGroups event before = .ok (groups, after) ∧
    ∀ inserted ∈ groups.flatten, (inserted == .binary key) = false

theorem projected_input_ledger_absent {s t : Term} {key : ByteArray} {raw normalized j r : List Term}
    (execution : ProjectedBatch s raw j normalized t r)
    (canonical : ∀ event ∈ raw, BinaryKeys event)
    (allowed : ∀ event ∈ raw, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ raw, IdentityCheckAvoids event key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key)) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  induction execution with
  | nil => exact absent
  | @skip s next final raw events normalized j middle r prepared tail ih =>
    have same := prepareTrusted_none prepared
    subst next
    exact ih (fun e mem => canonical e (List.mem_cons_of_mem _ mem))
      (fun e mem => allowed e (List.mem_cons_of_mem _ mem))
      (fun e mem => checked e (List.mem_cons_of_mem _ mem)) absent
  | @cons s middle next final raw event events normalized j rest after r prepared activity tail ih =>
    obtain ⟨_, normalizedRead, _, reduced⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys (canonical _ List.mem_cons_self) normalizedRead
    subst event
    obtain ⟨groups, before, afterCheck, guard, different⟩ := checked _ List.mem_cons_self
    have kept := admitted_inner_checked_ledger_absent (allowed _ List.mem_cons_self) guard different absent reduced
    have frame := afterEvent_ledger_frame activity
    apply ih (fun e mem => canonical e (List.mem_cons_of_mem _ mem))
      (fun e mem => allowed e (List.mem_cons_of_mem _ mem))
      (fun e mem => checked e (List.mem_cons_of_mem _ mem))
    rw [frame]
    exact kept

theorem project_input_ledger_absent {s t : Term} {key : ByteArray} {events j r : List Term}
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (checked : ∀ event ∈ events, IdentityCheckAvoids event key)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (h : Command.project s events j = .ok (t, r)) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  obtain ⟨normalized, execution⟩ := project_execution h
  exact projected_input_ledger_absent execution canonical allowed checked absent

theorem identity_map_avoids {events : List Term} {groups : List (List (List Term))} {key : ByteArray}
    {j r : List Term}
    (read : events.mapM Command.inputIdentityGroups j = .ok (groups, r))
    (different : ∀ inserted ∈ groups.flatten.flatten, (inserted == .binary key) = false) :
    ∀ event ∈ events, IdentityCheckAvoids event key := by
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

theorem identity_guard_prefix_avoids {earlier : List Term} {main : Term} {key : ByteArray}
    {mainGroups : List (List Term)} {j r before after : List Term}
    (checked : Command.inputIdentitiesDistinct (earlier ++ [main]) j = .ok (true, r))
    (mainRead : Command.inputIdentityGroups main before = .ok (mainGroups, after))
    (member : Term.binary key ∈ mainGroups.flatten) :
    ∀ event ∈ earlier, IdentityCheckAvoids event key := by
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
  exact identity_map_avoids prefixRead (fun inserted present => cross inserted present _ member)

theorem checked_prefix_project_absent {s t main : Term} {earlier selected : List Term} {key : ByteArray}
    {mainGroups : List (List Term)} {j r before after projectBefore projectAfter : List Term}
    (checked : Command.inputIdentitiesDistinct (earlier ++ [main]) j = .ok (true, r))
    (mainRead : Command.inputIdentityGroups main before = .ok (mainGroups, after))
    (member : Term.binary key ∈ mainGroups.flatten)
    (canonical : ∀ event ∈ earlier, BinaryKeys event)
    (allowed : ∀ event ∈ earlier, Command.inputEventAllowed event = true)
    (selectedFrom : ∀ event ∈ selected, event ∈ earlier)
    (absent : IdentityAbsent (s.get (a "input_dedupe")) (.binary key))
    (projected : Command.project s selected projectBefore = .ok (t, projectAfter)) :
    IdentityAbsent (t.get (a "input_dedupe")) (.binary key) := by
  have avoids := identity_guard_prefix_avoids checked mainRead member
  exact project_input_ledger_absent
    (fun event present => canonical event (selectedFrom event present))
    (fun event present => allowed event (selectedFrom event present))
    (fun event present => avoids event (selectedFrom event present)) absent projected

end VerifiedKernel.Session.WorkConservation
