import VerifiedKernelProofs.Session.WorkResident

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

def ResidentStep (state event final : Term) : Prop :=
  ∃ reduced normalized j r, prepareTrusted state event j = .ok ((reduced, normalized), r) ∧
    ActivityFrame reduced final

def ResidentTokenEvidence (state event : Term) : Term → Prop
  | .tuple [.atom "reduce", resident, raw, .list _] => resident = state ∧ raw = event
  | .tuple [.atom "activity", resident, _, _, _, .list _] => ResidentStep state event resident
  | _ => False

def ResidentResultEvidence (state event : Term) : Term → Prop
  | .tuple [.atom "done", final] => ResidentStep state event final
  | .tuple [.atom "observe", _, token] => ResidentTokenEvidence state event token
  | _ => True

theorem resident_step_frame {state event reduced final : Term}
    (step : ResidentStep state event reduced) (frame : ActivityFrame reduced final) :
    ResidentStep state event final := by
  obtain ⟨middle, normalized, j, r, prepared, first⟩ := step
  exact ⟨middle, normalized, j, r, prepared, activity_frame_trans first frame⟩

theorem runActivityTrusted_evidence {state raw reduced event : Term} {j rest observations : List Term}
    (prepared : prepareTrusted state raw j = .ok ((reduced, some event), rest)) :
    ResidentResultEvidence state raw (runActivityTrusted state reduced event observations) := by
  unfold runActivityTrusted
  cases result : afterEvent state reduced event observations with
  | ok value =>
    obtain ⟨final, rest⟩ := value
    dsimp only
    split
    · exact ⟨reduced, some event, j, _, prepared, afterEvent_activity_frame result⟩
    · trivial
  | error fault =>
    cases fault <;> dsimp only
    · exact ⟨reduced, some event, j, _, prepared, activity_frame_refl _⟩
    · trivial

theorem runTrusted_evidence (state event : Term) (observations : List Term) :
    ResidentResultEvidence state event (runTrusted state event observations) := by
  unfold runTrusted
  split
  · trivial
  · cases result : prepareTrusted state event observations with
    | ok value =>
      obtain ⟨⟨next, normalized⟩, rest⟩ := value
      cases normalized with
      | none =>
        dsimp only
        split
        · exact ⟨next, none, observations, rest, result, activity_frame_refl _⟩
        · trivial
      | some normalized => dsimp only; exact runActivityTrusted_evidence result
    | error fault => cases fault <;> dsimp only <;> first | exact ⟨rfl, rfl⟩ | trivial

theorem resumeTrusted_evidence {state event token observation : Term}
    (valid : ResidentTokenEvidence state event token) :
    ResidentResultEvidence state event (resumeTrusted token observation) := by
  unfold resumeTrusted
  split
  · trivial
  · split
    · dsimp only [ResidentTokenEvidence] at valid
      rw [valid.1, valid.2]
      exact runTrusted_evidence _ _ _
    · rename_i resident previous next raw observations
      change ResidentStep state event resident at valid
      dsimp only
      cases result : afterEvent previous next raw (observations ++ [observation]) with
      | ok value =>
        obtain ⟨view, rest⟩ := value
        dsimp only
        split
        · change ResidentStep state event (if view.has (a "activity_status_updated_at") then
            (resident.put (a "activity_status") (view.get (a "activity_status"))).put
              (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
            else resident.put (a "activity_status") (view.get (a "activity_status")))
          apply resident_step_frame valid
          intro key notStatus notTime
          split
          · rw [get_put_other _ _ (Ne.symm notTime), get_put_other _ _ (Ne.symm notStatus)]
          · exact get_put_other _ _ (Ne.symm notStatus)
        · trivial
      | error fault => cases fault <;> dsimp only <;> first | exact valid | trivial
    · trivial

theorem resident_trace_evidence {state event initial final : Term}
    (trace : ResidentTrace initial final) (valid : ResidentResultEvidence state event initial) :
    ResidentResultEvidence state event final := by
  induction trace with
  | done => exact valid
  | resume tail ih => exact ih (resumeTrusted_evidence valid)

theorem resident_execution_step {state event final : Term} {observations : List Term}
    (trace : ResidentTrace (runTrusted state event observations) (.tuple [a "done", final])) :
    ResidentStep state event final := resident_trace_evidence trace (runTrusted_evidence _ _ _)

end VerifiedKernel.Session.WorkConservation
