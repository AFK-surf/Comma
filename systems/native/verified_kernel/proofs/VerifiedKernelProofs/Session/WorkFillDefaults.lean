import VerifiedKernelProofs.Session.WorkLifecycle

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem fill_defaults_fold_default {key : String} {fallback : Term}
    (entries : List (String × Term)) (state : Term)
    (values : ∀ pair ∈ entries, pair.1 = key → pair.2 = fallback) :
    ((entries.foldl (fun current pair =>
      if current.has (a pair.1) then current else current.put (a pair.1) pair.2) state).get (a key)).default fallback =
      (state.get (a key)).default fallback := by
  induction entries generalizing state with
  | nil => rfl
  | cons pair rest ih =>
    rw [List.foldl_cons]
    have tailValues := fun entry member => values entry (List.mem_cons_of_mem _ member)
    split
    · exact ih state tailValues
    · rename_i absent
      rw [ih _ tailValues]
      by_cases equal : pair.1 = key
      · have missing : state.get (a key) = nil := by
          apply Classical.byContradiction
          intro different
          exact absent (by rw [equal]; exact get_present_has different)
        rw [equal, values pair List.mem_cons_self equal, get_put_same, missing]
        simp only [Term.default, nil, Term.truthy]
        split <;> rfl
      · rw [get_put_other _ _ equal]

theorem fillDefaults_lastSeq (state : Term) : lastSeq (Lifecycle.fillDefaults state) = lastSeq state := by
  exact fill_defaults_fold_default Lifecycle.defaults state
    (by simp +decide [Lifecycle.defaults])

end VerifiedKernel.Session.WorkConservation
