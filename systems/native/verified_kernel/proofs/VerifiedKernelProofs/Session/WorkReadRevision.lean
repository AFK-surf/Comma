import VerifiedKernelProofs.Session.WorkCurrentStorage

namespace VerifiedKernel.SessionDomain.ReadRevision
open Data Session.WorkConservation
set_option Elab.async false
set_option maxRecDepth 4096

abbrev Output := Option Term × Term
def response (value : Term) : Term := .tuple [i 1, a "ok", value]

theorem start_captured {agent session : ByteArray} {cursor objectKey : Term}
    (call : resident none (a "start") (.tuple [.binary agent, .binary session]) =
      (some cursor, response (.tuple [a "read", objectKey]))) :
    objectKey = key agent session ∧ Session.validId (.binary session) "ses1" = true ∧
      cursor = .tuple [a "session_read_pending", .binary agent, .binary session, objectKey] := by
  change (if Session.validId (.binary session) "ses1" then
    (some (.tuple [a "session_read_pending", .binary agent, .binary session, key agent session]),
      response (.tuple [a "read", key agent session])) else failed (a "invalid_session_id")) = _ at call
  split at call
  · rename_i valid
    have same := Prod.mk.inj call
    have keyEq : key agent session = objectKey := by
      simpa only [response, Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same.2
    exact ⟨keyEq.symm, valid, (Option.some.inj same.1).symm.trans (by rw [keyEq])⟩
  · cases congrArg Prod.fst call

theorem finish_captured {agent session : ByteArray} {objectKey etag state cursor : Term}
    (versioned : (etag == nil) = false)
    (call : finish agent session objectKey etag state = (some cursor, response (.tuple [a "loaded"]))) :
    state.get (a "agent_id") = .binary agent ∧ state.get (a "session_id") = .binary session ∧
      Session.validId (state.get (a "session_id")) "ses1" = true ∧ objectKey = key agent session ∧
      cursor = (Session.Revision.Cursor.committed state etag).pack := by
  unfold finish at call
  split at call
  · cases congrArg Prod.fst call
  · rename_i owner
    split at call
    · cases congrArg Prod.fst call
    · rename_i valid
      split at call
      · cases congrArg Prod.fst call
      · rename_i identified
        split at call
        · cases congrArg Prod.fst call
        · rename_i object
          simp only [bne, Bool.not_eq_true', Bool.not_eq_false] at owner valid identified object
          have owned := beq_binary_right owner
          have sessionField := beq_binary_right identified
          have addressed : objectKey = key agent session := beq_binary_right object
          simp only [versioned, Bool.false_eq_true, ↓reduceIte] at call
          have captured := Option.some.inj (congrArg Prod.fst call)
          exact ⟨owned, sessionField, valid, addressed, captured.symm⟩

theorem finish_not_observing (agent session : ByteArray) (objectKey etag state cursor request : Term) :
    finish agent session objectKey etag state ≠ (some cursor, response (.tuple [a "observe", request])) := by
  intro same
  unfold finish at same
  repeat' first
    | (cases congrArg Prod.fst same)
    | (have wrong := congrArg Prod.snd same
       change response (.tuple [a "loaded"]) = response (.tuple [a "observe", request]) at wrong
       simp [response, a] at wrong)
    | split at same

inductive LoadTrace : Output → Term → Prop where
  | done (cursor : Term) : LoadTrace (some cursor, response (.tuple [a "loaded"])) cursor
  | resume {saved request observation final : Term}
      (tail : LoadTrace (resident (some saved) (a "resume") observation) final) :
      LoadTrace (some saved, response (.tuple [a "observe", request])) final

theorem accept_completed {agent session : ByteArray} {objectKey etag cursor : Term} {output : Output}
    (call : accept agent session objectKey etag output = (some cursor, response (.tuple [a "loaded"]))) :
    ∃ state, output = (some state, response (.tuple [a "done"])) ∧
      finish agent session objectKey etag state = (some cursor, response (.tuple [a "loaded"])) := by
  unfold accept at call
  split at call
  · exact ⟨_, rfl, call⟩
  · have wrong := congrArg Prod.snd call
    change response (.tuple [a "observe", _]) = response (.tuple [a "loaded"]) at wrong
    simp [response, a] at wrong
  · cases congrArg Prod.fst call

theorem accept_observing {agent session : ByteArray} {objectKey etag cursor request : Term} {output : Output}
    (call : accept agent session objectKey etag output =
      (some cursor, response (.tuple [a "observe", request]))) :
    ∃ state token, output = (some state, response (.tuple [a "observe", request, token])) ∧
      cursor = .tuple [a "session_read_loading", .binary agent, .binary session, objectKey, etag, state, token] := by
  unfold accept at call
  split at call
  · exact (finish_not_observing _ _ _ _ _ _ _ call).elim
  · rename_i ignored state issued token
    have pair := Prod.mk.inj call
    have responseEq := pair.2
    change response (.tuple [a "observe", issued]) = response (.tuple [a "observe", request]) at responseEq
    have same : issued = request := by
      simpa only [response, Term.tuple.injEq, List.cons.injEq, and_true, true_and] using responseEq
    subst issued
    exact ⟨state, token, rfl, (Option.some.inj pair.1).symm⟩
  · cases congrArg Prod.fst call

theorem load_trace_reflect {agent session : ByteArray} {objectKey etag cursor : Term} {output : Output}
    (trace : LoadTrace (accept agent session objectKey etag output) cursor) :
    ∃ state, Session.WorkConservation.ReloadTrace output (some state, response (.tuple [a "done"])) ∧
      finish agent session objectKey etag state = (some cursor, response (.tuple [a "loaded"])) := by
  generalize origin : accept agent session objectKey etag output = initial at trace
  induction trace generalizing output with
  | done cursor =>
    obtain ⟨state, same, finished⟩ := accept_completed origin
    exact ⟨state, same ▸ .done _, finished⟩
  | @resume saved request observation final tail ih =>
    obtain ⟨state, token, same, captured⟩ := accept_observing origin
    subst saved
    obtain ⟨loaded, reloaded, finished⟩ := ih rfl
    refine ⟨loaded, ?_, finished⟩
    rw [same]
    exact .resume observation rfl reloaded

theorem load_snapshot_evidence {state : Term} {bytes : ByteArray} (observations : List Term)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, state]))
    (ready : QueueReady state) : ReloadEvidence state (loadSnapshot bytes observations) := by
  have initial := normalizedResponse_evidence state observations ready
  have map := queueReady_isMap ready
  apply Eq.mp ?_ initial
  apply congrArg (ReloadEvidence state)
  cases state with
  | map entries =>
    simp only [loadSnapshot, decoded]
    rfl
  | _ => cases map

theorem read_result_normalizes {agent session bytes etag : ByteArray} {snapshot cursor : Term}
    {observations : List Term}
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, snapshot]))
    (ready : QueueReady snapshot)
    (trace : LoadTrace
      (resident (some (.tuple [a "session_read_pending", .binary agent, .binary session, key agent session]))
        (a "read_result") (.tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations])) cursor) :
    ∃ state journal rest,
      Session.Lifecycle.normalize snapshot journal = .ok (state, rest) ∧
      state.get (a "agent_id") = .binary agent ∧ state.get (a "session_id") = .binary session ∧
      Session.validId (state.get (a "session_id")) "ses1" = true ∧
      cursor = (Session.Revision.Cursor.committed state (.binary etag)).pack := by
  change LoadTrace (if Schema.admissible (list observations) then
    accept agent session (key agent session) (.binary etag) (loadSnapshot bytes observations)
    else failed (a "invalid_session_snapshot")) cursor at trace
  split at trace
  · obtain ⟨state, reloaded, finished⟩ := load_trace_reflect trace
    have evidence := reload_trace_evidence reloaded ready (load_snapshot_evidence observations decoded ready)
    obtain ⟨journal, rest, normalized⟩ := evidence.1 state rfl
    obtain ⟨owned, identified, valid, _, captured⟩ := finish_captured rfl finished
    exact ⟨state, journal, rest, normalized, owned, identified, valid, captured⟩
  · cases trace

theorem current_read_preserves {framing : Session.ArchivePublication.CodecFraming}
    {objects : Session.ArchivePublication.Objects} {store : HotStore}
    {agent session bytes etag : ByteArray} {snapshot decodedState pending objectKey cursor : Term}
    {sealed observations : List Term}
    (history : PhysicalHistory framing objects agent session snapshot sealed)
    (current : store.current objectKey (.binary etag) snapshot)
    (started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
      .tuple [.binary agent, .binary session]]) = (some pending, response (.tuple [a "read", objectKey])))
    (read : HotRead store objectKey bytes (.binary etag))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (trace : LoadTrace
      (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
        .tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations]])) cursor) :
    objectKey = key agent session ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      ∃ state journal rest,
        Session.Lifecycle.normalize decodedState journal = .ok (state, rest) ∧
        state.get (a "agent_id") = .binary agent ∧ state.get (a "session_id") = .binary session ∧
        cursor = (Session.Revision.Cursor.committed state (.binary etag)).pack ∧
        ∀ item, ValueSemantics.Represented snapshot sealed item → ValueSemantics.Represented state sealed item := by
  have stored := read.snapshot_bytes current
  obtain ⟨keyEq, _, pendingEq⟩ := start_captured started
  subst objectKey
  rw [pendingEq] at trace
  have ready := codec.ready history.invariant.history.invariant.ready
  obtain ⟨state, journal, rest, normalized, owned, identified, _, captured⟩ := read_result_normalizes decoded ready trace
  exact ⟨rfl, stored, state, journal, rest, normalized, owned, identified, captured,
    fun item present => ValueSemantics.normalize_preserves ready normalized (codec.represents present)⟩

theorem current_read_history {framing : Session.ArchivePublication.CodecFraming}
    {objects : Session.ArchivePublication.Objects} {store : HotStore}
    {agent session bytes etag : ByteArray} {snapshot decodedState pending objectKey cursor : Term}
    {sealed observations : List Term}
    (history : PhysicalHistory framing objects agent session snapshot sealed)
    (current : store.current objectKey (.binary etag) snapshot)
    (started : SessionDomain.dispatch none (.tuple [i 1, a "session_read", i 1, a "start",
      .tuple [.binary agent, .binary session]]) = (some pending, response (.tuple [a "read", objectKey])))
    (read : HotRead store objectKey bytes (.binary etag))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (trace : LoadTrace
      (SessionDomain.dispatch (some pending) (.tuple [i 1, a "session_read", i 1, a "read_result",
        .tuple [.tuple [a "ok", .binary bytes, .binary etag], list observations]])) cursor) :
    objectKey = key agent session ∧ ∃ state,
      cursor = (Session.Revision.Cursor.committed state (.binary etag)).pack ∧
      PhysicalHistory framing objects agent session state sealed ∧
      ∀ item, ValueSemantics.Represented snapshot sealed item → ValueSemantics.Represented state sealed item := by
  obtain ⟨addressed, _, state, journal, rest, normalized, _, _, captured, kept⟩ :=
    current_read_preserves history current started read decoded codec trace
  exact ⟨addressed, state, captured, (history.decode decoded codec).normalize normalized, kept⟩

end VerifiedKernel.SessionDomain.ReadRevision
