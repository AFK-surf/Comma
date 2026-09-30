import VerifiedKernelProofs.Session.WorkDriverQuery

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- Split raw observation history at the first successful query. Its issued write may itself request a timestamp. -/
theorem observations_successful_query {context : Context} {operation args : Term} {observations : List Term}
    {final : Output}
    (trace : ObservationTrace (query context operation args observations) final)
    (terminal : QueryTerminal final) :
    ∃ journal result rest, queryCall context operation args journal = .ok (result, rest) ∧
      settled rest = true ∧ ObservationTrace (issue context result) final := by
  generalize origin : query context operation args observations = initial at trace
  induction trace generalizing observations with
  | done output =>
    rw [← origin] at terminal
    obtain ⟨result, rest, call, settled, issued⟩ := query_terminal_call terminal
    exact ⟨observations, result, rest, call, settled, by rw [← issued, origin]; exact .done _⟩
  | @resume saved request observation final tail ih =>
    have actual := origin
    rw [query_eq] at actual
    split at actual
    · rename_i result rest call
      split at actual
      · rename_i settled
        exact ⟨observations, result, rest, call, settled, by rw [actual]; exact .resume tail⟩
      · have impossible := congrArg Prod.fst actual
        cases impossible
    · have same := (Option.some.inj (congrArg Prod.fst actual)).symm
      subst saved
      exact ih terminal (query_resume_captured _ _ _ _ _).symm
    · have impossible := congrArg Prod.fst actual
      cases impossible

end VerifiedKernel.Session.CommandDriver
