import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkSnapshot

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096
set_option Elab.async false

private def wireOk (value : Term) : Term := .tuple [i 1, a "ok", value]

private def lifecycleResponse (response : Term) : Option Term × Term :=
  match response with
  | .tuple [.atom "done", .tuple [.atom "ok", next]] => (some next, wireOk (.tuple [a "done"]))
  | .tuple [.atom "done", .tuple [.atom "error", reason]] => (none, wireOk (.tuple [a "failed", reason]))
  | .tuple [.atom "done", next] => (some next, wireOk (.tuple [a "done"]))
  | other => let (resident, value) := detach other; (resident, wireOk value)

private def normalizedResponse (state : Term) (prelude : List Term) : Option Term × Term :=
  match lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil (fun state _ => Lifecycle.normalize state) state prelude) with
  | (some next, response) =>
    if Schema.admissible next true then (some next, response)
    else (none, wireOk (.tuple [a "failed", a "invalid_snapshot"]))
  | other => other

private def snapshotState : Term → Option Term
  | .tuple [.atom "comma_internal_session", .integer 3, state] => if state.isMap then some state else none
  | state => if state.isMap && state.has (a "__struct__") then some state else none

private def loadResponse (bytes : ByteArray) : Option Term × Term :=
  match ETF.decode bytes with
  | .error _ => (none, wireOk (.tuple [a "failed", a "invalid_snapshot"]))
  | .ok snapshot => match snapshotState snapshot with
    | some state => normalizedResponse state []
    | none => (none, wireOk (.tuple [a "failed", a "invalid_snapshot"]))

theorem queueReady_isMap {s : Term} (ready : QueueReady s) : s.isMap = true := by
  obtain ⟨items, _, read, _⟩ := ready.1
  cases s <;> try rfl
  all_goals cases read

theorem load_dispatch_normalization {resident : Option Term} {s : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (map : s.isMap = true) :
    SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]) =
      normalizedResponse s [] := by
  have equation : SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]) =
      loadResponse bytes := by rfl
  rw [equation]
  simp +decide [loadResponse, decoded, snapshotState, a, i, map]

theorem normalizedResponse_completed {s t : Term} {prelude : List Term}
    (ready : QueueReady s)
    (h : normalizedResponse s prelude = (some t, wireOk (.tuple [a "done"]))) :
    ∃ rest, Lifecycle.normalize s prelude = .ok (t, rest) := by
  unfold normalizedResponse at h
  cases call : Lifecycle.normalize s prelude with
  | error failure =>
    cases failure with
    | observe request =>
      simp +decide [runOp, call, lifecycleResponse, detach, a, i, nil] at h
      split at h
      · have response := (Prod.mk.inj h).2
        simp [wireOk, a, i] at response
      · cases (Prod.mk.inj h).1
    | raised reason =>
      simp only [runOp, call] at h
      change (none, wireOk (.tuple [a "raised", reason])) = (some t, wireOk (.tuple [a "done"])) at h
      cases (Prod.mk.inj h).1
  | ok pair =>
    obtain ⟨next, rest⟩ := pair
    have map := queueReady_isMap (normalize_work ready call).1
    cases next with
    | map entries =>
      cases stable : settled rest with
      | false =>
        simp only [runOp, call, stable] at h
        change (none, wireOk (.tuple [a "raised", .tuple [a "invalid_observation", list []]])) =
          (some t, wireOk (.tuple [a "done"])) at h
        cases (Prod.mk.inj h).1
      | true =>
        simp +decide [runOp, call, stable, lifecycleResponse, a, i, nil] at h
        split at h
        · have same := Option.some.inj (Prod.mk.inj h).1
          exact ⟨rest, by rw [← same]⟩
        · cases (Prod.mk.inj h).1
    | _ => cases map

theorem normalizeOp_completed {s t : Term} {prelude : List Term}
    (ready : QueueReady s)
    (h : lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
      (fun state _ => Lifecycle.normalize state) s prelude) = (some t, wireOk (.tuple [a "done"]))) :
    ∃ rest, Lifecycle.normalize s prelude = .ok (t, rest) := by
  cases call : Lifecycle.normalize s prelude with
  | error failure =>
    cases failure with
    | observe request =>
      simp +decide [runOp, call, lifecycleResponse, detach, wireOk, a, i, nil] at h
    | raised reason =>
      simp only [runOp, call] at h
      change (none, wireOk (.tuple [a "raised", reason])) = (some t, wireOk (.tuple [a "done"])) at h
      cases (Prod.mk.inj h).1
  | ok pair =>
    obtain ⟨next, rest⟩ := pair
    have map := queueReady_isMap (normalize_work ready call).1
    cases next with
    | map entries =>
      cases stable : settled rest with
      | false =>
        simp only [runOp, call, stable] at h
        change (none, wireOk (.tuple [a "raised", .tuple [a "invalid_observation", list []]])) =
          (some t, wireOk (.tuple [a "done"])) at h
        cases (Prod.mk.inj h).1
      | true =>
        simp +decide [runOp, call, stable, lifecycleResponse, a] at h
        exact ⟨rest, by rw [← h]⟩
    | _ => cases map

theorem reload_resume_preserves {s t observation : Term} {prelude : List Term}
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (h : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "resume",
      .tuple [.tuple [a "op", a "lifecycle", a "normalize", nil, list prelude], observation]]) =
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    QueueReady t ∧ t.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have equation : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "resume",
      .tuple [.tuple [a "op", a "lifecycle", a "normalize", nil, list prelude], observation]]) =
      (if !Schema.admissible observation then
        (none, wireOk (.tuple [a "raised", .tuple [a "schema", list [b "continuations and observations must contain Session data"]]]))
      else lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
        (fun state _ => Lifecycle.normalize state) s (prelude ++ [observation]))) := by rfl
  rw [equation] at h
  split at h
  · cases (Prod.mk.inj h).1
  · obtain ⟨rest, normalized⟩ := normalizeOp_completed ready h
    exact ⟨(normalize_work ready normalized).1, normalize_format format normalized,
      fun _ _ present => normalize_representation ready normalized present⟩

theorem load_dispatch_preserves {resident : Option Term} {s t : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (h : SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]) =
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    QueueReady t ∧ t.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  rw [load_dispatch_normalization decoded (queueReady_isMap ready)] at h
  obtain ⟨rest, normalized⟩ := normalizedResponse_completed ready h
  exact ⟨(normalize_work ready normalized).1, normalize_format format normalized,
    fun _ _ present => normalize_representation ready normalized present⟩

theorem normalizeOp_pending {s t request token : Term} {prelude : List Term}
    (ready : QueueReady s)
    (h : lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
      (fun state _ => Lifecycle.normalize state) s prelude) =
      (some t, wireOk (.tuple [a "observe", request, token]))) :
    t = s ∧ token = .tuple [a "op", a "lifecycle", a "normalize", nil, list prelude] := by
  cases call : Lifecycle.normalize s prelude with
  | error failure =>
    cases failure with
    | observe observed =>
      simp +decide [runOp, call, lifecycleResponse, detach, wireOk, a, i, nil] at h
      exact ⟨h.1.symm, h.2.2.symm⟩
    | raised reason =>
      simp only [runOp, call] at h
      change (none, wireOk (.tuple [a "raised", reason])) = _ at h
      cases (Prod.mk.inj h).1
  | ok pair =>
    obtain ⟨next, rest⟩ := pair
    have map := queueReady_isMap (normalize_work ready call).1
    cases next with
    | map entries =>
      cases stable : settled rest with
      | false =>
        simp only [runOp, call, stable] at h
        change (none, wireOk (.tuple [a "raised", .tuple [a "invalid_observation", list []]])) = _ at h
        cases (Prod.mk.inj h).1
      | true => simp +decide [runOp, call, stable, lifecycleResponse, wireOk, a, i] at h
    | _ => cases map

def ReloadEvidence (s : Term) (response : Option Term × Term) : Prop :=
  (∀ t, response = (some t, wireOk (.tuple [a "done"])) →
    ∃ prelude rest, Lifecycle.normalize s prelude = .ok (t, rest)) ∧
  (∀ t request token, response = (some t, wireOk (.tuple [a "observe", request, token])) →
    t = s ∧ ∃ prelude, token = .tuple [a "op", a "lifecycle", a "normalize", nil, list prelude])

theorem normalizeOp_evidence (s : Term) (prelude : List Term) (ready : QueueReady s) :
    ReloadEvidence s (lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
      (fun state _ => Lifecycle.normalize state) s prelude)) := by
  constructor
  · intro t completed
    obtain ⟨rest, call⟩ := normalizeOp_completed ready completed
    exact ⟨prelude, rest, call⟩
  · intro t request token pending
    obtain ⟨same, tokenRead⟩ := normalizeOp_pending ready pending
    exact ⟨same, prelude, tokenRead⟩

theorem normalizedResponse_evidence (s : Term) (prelude : List Term) (ready : QueueReady s) :
    ReloadEvidence s (normalizedResponse s prelude) := by
  have evidence := normalizeOp_evidence s prelude ready
  unfold normalizedResponse
  generalize read : lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
    (fun state _ => Lifecycle.normalize state) s prelude) = response at *
  obtain ⟨resident, response⟩ := response
  cases resident with
  | none => exact evidence
  | some next =>
    dsimp only
    split
    · exact evidence
    · constructor
      · intro t impossible; cases (Prod.mk.inj impossible).1
      · intro t request token impossible; cases (Prod.mk.inj impossible).1

theorem reload_resume_evidence (s observation : Term) (prelude : List Term) (ready : QueueReady s) :
    ReloadEvidence s (SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "resume",
      .tuple [.tuple [a "op", a "lifecycle", a "normalize", nil, list prelude], observation]])) := by
  have equation : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "resume",
      .tuple [.tuple [a "op", a "lifecycle", a "normalize", nil, list prelude], observation]]) =
      (if !Schema.admissible observation then
        (none, wireOk (.tuple [a "raised", .tuple [a "schema", list [b "continuations and observations must contain Session data"]]]))
      else lifecycleResponse (runOp (a "lifecycle") (a "normalize") nil
        (fun state _ => Lifecycle.normalize state) s (prelude ++ [observation]))) := by rfl
  rw [equation]
  split
  · constructor
    · intro t impossible; cases (Prod.mk.inj impossible).1
    · intro t request token impossible; cases (Prod.mk.inj impossible).1
  · exact normalizeOp_evidence s (prelude ++ [observation]) ready

inductive ReloadTrace : (Option Term × Term) → (Option Term × Term) → Prop where
  | done (response) : ReloadTrace response response
  | resume {s request token next final} (observation : Term)
      (call : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "resume",
        .tuple [token, observation]]) = next)
      (tail : ReloadTrace next final) :
      ReloadTrace (some s, wireOk (.tuple [a "observe", request, token])) final

theorem reload_trace_evidence {s : Term} {initial final : Option Term × Term}
    (trace : ReloadTrace initial final) (ready : QueueReady s)
    (evidence : ReloadEvidence s initial) : ReloadEvidence s final := by
  induction trace with
  | done => exact evidence
  | resume observation call tail ih =>
    obtain ⟨same, prelude, tokenRead⟩ := evidence.2 _ _ _ rfl
    subst same
    rw [tokenRead] at call
    apply ih
    rw [← call]
    exact reload_resume_evidence _ observation prelude ready

theorem load_trace_preserves {resident : Option Term} {s t : Term} {bytes : ByteArray}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, s]))
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some t, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    QueueReady t ∧ t.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item := by
  have initial : ReloadEvidence s (SessionDomain.dispatch resident
      (.tuple [i 1, a "session", i 1, a "load", .binary bytes])) := by
    rw [load_dispatch_normalization decoded (queueReady_isMap ready)]
    exact normalizedResponse_evidence s [] ready
  obtain ⟨prelude, rest, normalized⟩ := (reload_trace_evidence trace ready initial).1 t rfl
  exact ⟨(normalize_work ready normalized).1, normalize_format format normalized,
    fun _ _ present => normalize_representation ready normalized present⟩

end VerifiedKernel.Session.WorkConservation
