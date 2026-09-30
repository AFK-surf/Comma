import VerifiedKernelProofs.Session.WorkConfirmedCandidate

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem storage_commit_dispatch (current : Option Term) (operation args : Term) :
    SessionDomain.dispatch current (.tuple [i 1, a "session_commit", i 1, operation, args]) =
      let output := StorageCommit.resident current operation args
      (output.1, .tuple [i 1, a "ok", output.2]) := rfl

theorem storage_commit_start {state key base request : Term}
    (h : StorageCommit.prepare state (.tuple [key, base]) [] = .ok (request, [])) :
    StorageCommit.resident (some state) (a "start") (.tuple [key, base]) =
      (some (.tuple [a "storage_commit_pending", state]), request) := by
  simp only [StorageCommit.resident, a, h]

theorem storage_commit_resume_captured (state etag outcome : Term) :
    StorageCommit.resident (some (.tuple [a "storage_commit_pending", state])) (a "resume")
      (.tuple [a "ok", etag, outcome]) = (some state, .tuple [a "ok", etag]) := rfl

theorem storage_commit_address {state key base request : Term} {journal rest : List Term}
    (call : StorageCommit.prepare state (.tuple [key, base]) journal = .ok (request, rest)) :
    StorageAddress.agrees state key = true := by
  cases accepted : StorageAddress.agrees state key with
  | true => rfl
  | false =>
    simp only [StorageCommit.prepare, accepted, Bool.not_false, ↓reduceIte] at call
    exact (fail_ok call).elim

theorem storage_commit_candidate {s key base request : Term} {j r : List Term}
    (h : StorageCommit.prepare s (.tuple [key, base]) j = .ok (request, r)) :
    ∃ snapshot bytes rest,
      Lifecycle.persistable s [] = .ok (snapshot, rest) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, base] ∧
      SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
        (some s, .tuple [i 1, a "ok", .binary bytes]) := by
  have address := storage_commit_address h
  simp only [StorageCommit.prepare, address, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨snapshot, rest, persisted, h⟩ := bind_ok h
  have clean : Lifecycle.persistable s [] = .ok (snapshot, []) := by
    unfold Lifecycle.persistable Data.put at persisted ⊢
    split at persisted
    · rename_i isMap
      simp only [isMap, ↓reduceIte]
      rw [pure_ok persisted]
      rfl
    · exact (fail_ok persisted).elim
  cases encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) with
  | ok bytes =>
    simp only [encoded] at h
    refine ⟨snapshot, bytes, [], clean, encoded, pure_ok h, ?_⟩
    change (match Lifecycle.persistable s [] with
      | .ok (snapshot, _) =>
        match ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) with
        | .ok encoded => (some s, Term.tuple [i 1, a "ok", .binary encoded])
        | .error code => (none, Term.tuple [i 1, a "error", a "wire", b code])
      | .error _ => (none, Term.tuple [i 1, a "error", a "session", b "persist_failed"])) = _
    simp only [clean, encoded]
  | error reason =>
    simp [encoded, fail, throw, throwThe, MonadExceptOf.throw, StateT.lift,
      Functor.map, Except.map] at h

theorem storage_commit_confirmation {s result etag : Term} {j r : List Term}
    (h : StorageCommit.finish s result j = .ok (.tuple [a "ok", etag], r)) :
    ∃ outcome, result = .tuple [a "ok", etag, outcome] := by
  unfold StorageCommit.finish at h
  split at h
  · rename_i committed outcome
    have same := pure_ok h
    simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at same
    subst committed
    exact ⟨outcome, rfl⟩
  · have same := pure_ok h
    simp [a] at same
  · have same := pure_ok h
    simp [a] at same
  · simp [fail, throw, throwThe, MonadExceptOf.throw, StateT.lift,
      Functor.map, Except.map] at h

namespace ValueSemantics
open CommandExecution DurableConfirmation

theorem confirmed_input_storage_request {s entry born result final : Term}
    {source : ByteArray} {j r : List Term} {effects : List (Term × Result)}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (input : Command.input s (.tuple [entry, born]) j = .ok (result, r))
    (trace : Trace result effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "committed"]) ∨
      ∃ notified, final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) :
    ∃ batch event now first last,
      InputStart result batch ∧
      (∃ before after, effects = before ++
        [(.tuple [a "write", list batch, list []], Result.ok), (a "durable_fence", Result.ok)] ++ after) ∧
      Command.inputEvent (s.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      ∀ t prepared stamped key base request before after metadata observations rest,
        ResidentBatch s batch t →
        Lifecycle.prepareWrite t before = .ok (.tuple [a "ok", prepared], after) →
        ResidentBatch prepared metadata stamped →
        (∀ event ∈ metadata, BinaryKeys event) →
        (∀ event ∈ metadata, CommitMetadata event) →
        StorageCommit.prepare stamped (.tuple [key, base]) observations = .ok (request, rest) →
        ∃ snapshot bytes,
          request = .tuple [a "cas", key, .binary bytes, base] ∧
          ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
          QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
          (∀ sealed item, Represented s sealed item → Represented snapshot sealed item) ∧
          ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
            ∀ sealed, Represented snapshot sealed item := by
  obtain ⟨batch, event, now, first, last, started, fenced, generated, candidate⟩ :=
    confirmed_input_snapshot sourceValue ready format input trace confirmed
  refine ⟨batch, event, now, first, last, started, fenced, generated, ?_⟩
  intro t prepared stamped key base request before after metadata observations rest applied prepare stampedBatch keys admitted commit
  obtain ⟨_, bytes, _, _, _, requestBytes, persisted⟩ := storage_commit_candidate commit
  obtain ⟨snapshot, encoded, invariant⟩ :=
    candidate t prepared stamped bytes before after metadata applied prepare stampedBatch keys admitted persisted
  exact ⟨snapshot, bytes, requestBytes, encoded, invariant⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
