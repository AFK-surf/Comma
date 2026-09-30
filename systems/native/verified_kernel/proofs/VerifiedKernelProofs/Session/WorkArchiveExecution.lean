import VerifiedKernelProofs.Session.AppendOnly.Sorted

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem filterAuxM_input_calls {f : Term → KernelM Bool} {values acc output journal rest : List Term}
    (call : List.filterAuxM f values acc journal = .ok (output, rest)) :
    ∀ value ∈ values, ∃ verdict before after, f value before = .ok (verdict, after) := by
  induction values generalizing acc journal with
  | nil => simp
  | cons value values ih =>
    simp only [List.filterAuxM] at call
    obtain ⟨verdict, middle, head, tail⟩ := bind_ok call
    intro item member
    rcases List.mem_cons.mp member with rfl | member
    · exact ⟨verdict, journal, middle, head⟩
    · cases verdict <;> exact ih tail item member

theorem filterM_input_calls {f : Term → KernelM Bool} {values output journal rest : List Term}
    (call : List.filterM f values journal = .ok (output, rest)) :
    ∀ value ∈ values, ∃ verdict before after, f value before = .ok (verdict, after) := by
  unfold List.filterM at call
  obtain ⟨_, _, filtered, _⟩ := bind_ok call
  exact filterAuxM_input_calls filtered

theorem accessed_integer_plain {record key value : Term} {stamp : Int} {journal rest : List Term}
    (stamped : record.get key = i stamp) (call : access record key journal = .ok (value, rest)) :
    (record.isMap && !record.has (a "__struct__")) = true := by
  have actual := (access_ok call).1.trans stamped
  unfold access at call
  split at call
  · assumption
  · split at call
    · have nilValue := pure_ok call
      rw [actual] at nilValue
      cases nilValue
    · exact (fail_ok call).elim

theorem archiveAdvance_plain_or_same {state event next : Term} {live journal rest : List Term}
    (read : state.get (a "messages") = list live)
    (stamped : ∀ record ∈ live, ∃ stamp : Int, record.get (a "seq") = i stamp)
    (call : archiveAdvance state event journal = .ok (next, rest)) :
    next = state ∨ ∀ record ∈ live, (record.isMap && !record.has (a "__struct__")) = true := by
  unfold archiveAdvance at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · exact Or.inl (pure_ok call)
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨messages, _, messagesRead, call⟩ := bind_ok call
  simp only [field, fetch_ok_iff] at messagesRead
  obtain ⟨_, _, rfl, _⟩ := messagesRead
  rw [read] at call
  simp only [Data.list, default_list] at call
  obtain ⟨values, _, mapped, call⟩ := bind_ok call
  rw [enumMap_list_pure] at mapped
  have same : values = live := (Prod.mk.inj (Except.ok.inj mapped)).1.symm
  subst values
  obtain ⟨_, _, filtered, _⟩ := bind_ok call
  right
  intro record member
  obtain ⟨_, _, _, verdict⟩ := filterM_input_calls filtered record member
  obtain ⟨_, _, accessed, _⟩ := bind_ok verdict
  obtain ⟨stamp, stamped⟩ := stamped record member
  exact accessed_integer_plain stamped accessed

theorem archiveAdvance_executed_prefix {state event next : Term} {live journal rest : List Term}
    (sorted : SeqSorted state) (read : state.get (a "messages") = list live)
    (call : archiveAdvance state event journal = .ok (next, rest)) :
    ∃ dropped kept, live = dropped ++ kept ∧ next.get (a "messages") = list kept ∧
      ∀ record ∈ dropped, integerValue (record.get (a "seq")) ≤ integerValue (event.get (b "archived_through")) := by
  have stamped : ∀ record ∈ live, ∃ stamp : Int, record.get (a "seq") = i stamp := by
    obtain ⟨values, last, valuesRead, _, stamped, _⟩ := sorted
    rw [read] at valuesRead
    have same := Term.list.inj valuesRead
    subst values
    exact fun record member => (stamped record member).imp (fun _ fields => fields.1)
  rcases archiveAdvance_plain_or_same read stamped call with same | plain
  · exact ⟨[], live, rfl, by rwa [same], by simp⟩
  · exact archiveAdvance_prefix sorted read plain call

end VerifiedKernel.Session.WorkConservation
