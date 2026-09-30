import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkRevisionExpiry

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def ActivationEvent (event : Term) : Prop :=
  event.get (b "type") = b "visible_reply_activation_started" ∨
  event.get (b "type") = b "visible_reply_activation_finished" ∨
  event.get (b "type") = b "session_system_prompt" ∨
  event.get (b "type") = b "status"

def ActivationBatch (events : List Term) : Prop :=
  ∀ event ∈ events, BinaryKeys event ∧ ActivationEvent event

theorem activation_empty : ActivationBatch [] := by simp [ActivationBatch]

theorem activation_singleton (event : Term) (canonical : BinaryKeys event) (allowed : ActivationEvent event) :
    ActivationBatch [event] := by simpa [ActivationBatch] using And.intro canonical allowed

theorem activation_inner_frames {state event next : Term} {journal rest : List Term}
    (allowed : ActivationEvent event)
    (call : inner state event journal = .ok (next, rest)) :
    QueueFrame state next ∧ TranscriptExtends state next := by
  rcases allowed with kind | kind | kind | kind
  all_goals
    refine ⟨inner_queue_frame ?_ ?_ ?_ ?_ call, inner_extends ?_ ?_ call⟩
    all_goals simp +decide [kind]

theorem activation_resident_frames {state event next : Term}
    (step : ResidentStep state event next) (canonical : BinaryKeys event) (allowed : ActivationEvent event) :
    QueueFrame state next ∧ TranscriptExtends state next := by
  obtain ⟨reduced, normalized, journal, rest, prepared, activity⟩ := step
  cases normalized with
  | none =>
    rw [prepareTrusted_none prepared] at activity
    exact ⟨activity_frame_queue activity, activity_frame_extends activity⟩
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    obtain ⟨queue, records⟩ := activation_inner_frames allowed call
    exact ⟨queue_frame_trans queue (activity_frame_queue activity),
      extends_trans records (activity_frame_extends activity)⟩

theorem activation_batch_frames {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next) (batch : ActivationBatch events) :
    QueueFrame state next ∧ TranscriptExtends state next := by
  induction execution with
  | nil => exact ⟨queue_frame_refl _, extends_refl _⟩
  | cons head tail ih =>
    have event := batch _ List.mem_cons_self
    obtain ⟨queue, records⟩ := activation_resident_frames (resident_execution_step head) event.1 event.2
    obtain ⟨nextQueue, nextRecords⟩ := ih (fun event member => batch event (List.mem_cons_of_mem _ member))
    exact ⟨queue_frame_trans queue nextQueue, extends_trans records nextRecords⟩

theorem activation_batch_preserves {state next : Term} {events : List Term}
    (ready : QueueReady state) (batch : ActivationBatch events)
    (execution : ResidentBatch state events next) :
    QueueReady next ∧ next.get (a "storage_format") = state.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented state sealed item → ValueSemantics.Represented next sealed item := by
  obtain ⟨queue, records⟩ := activation_batch_frames execution batch
  exact ⟨queue_frame_ready queue ready, resident_batch_format execution,
    fun _ _ represented => ValueSemantics.execution_preserves
      (fun _ present => concrete_representation_frame_extends queue.1 records present)
      (fun _ present => record_survives records present) represented⟩

theorem activation_retirement_events {state args details : Term} {events journal rest : List Term}
    (call : ReplyQuery.activationRetirement state args journal = .ok (.tuple [list events, details], rest)) :
    ActivationBatch events := by
  unfold ReplyQuery.activationRetirement at call
  split at call
  · obtain ⟨_, _, _, call⟩ := bind_ok call
    split at call
    all_goals
      have same := pure_ok call
      simp only [Term.tuple.injEq, List.cons.injEq, and_true, list, Term.list.injEq] at same
      obtain ⟨rfl, _⟩ := same
      first
      | exact activation_empty
      | exact activation_singleton _ (by rfl) (by simp +decide [ActivationEvent, Term.get, b, Term.text])
  · exact (fail_ok call).elim

def ActivationResultEvents : Term → Prop
  | .tuple [.atom "ok", .list events, _, _] => ActivationBatch events
  | .tuple [.list events, _] => ActivationBatch events
  | _ => True

theorem activation_start_result {state args result : Term} {journal rest : List Term}
    (call : ReplyQuery.activationStart state args journal = .ok (result, rest)) :
    ActivationResultEvents result := by
  unfold ReplyQuery.activationStart at call
  repeat' first
    | (exact (fail_ok call).elim)
    | (have same := pure_ok call; subst result
       first
       | exact True.intro
       | exact activation_empty
       | exact activation_singleton _ (by rfl) (by simp +decide [ActivationEvent, Term.get, b, Term.text]))
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem activation_prompt_result {state args result : Term} {journal rest : List Term}
    (call : ReplyQuery.promptSnapshot state args journal = .ok (result, rest)) :
    ActivationResultEvents result := by
  unfold ReplyQuery.promptSnapshot at call
  repeat' first
    | (exact (fail_ok call).elim)
    | (have same := pure_ok call; subst result
       first
       | exact True.intro
       | exact activation_empty
       | exact activation_singleton _ (by rfl) (by simp +decide [ActivationEvent, Term.get, b, Term.text]))
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

def ActivationCommandEvents : Term → Prop
  | .tuple [.atom "perform", .tuple [.atom "write", .list events, _], _] => ActivationBatch events
  | _ => True

theorem activated_no_write {state details result : Term} {journal rest : List Term}
    (call : Command.activated state details journal = .ok (result, rest)) : ActivationCommandEvents result := by
  unfold Command.activated at call
  repeat' first
    | (rw [pure_ok call]; simp [ActivationCommandEvents, Command.perform, Command.finish])
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

/-- Activation writes contain only its own control events after native materialization. -/
theorem commit_activation_events {state session hwm prompt active details checkpoint result : Term}
    {events journal rest : List Term} (batch : ActivationBatch events)
    (call : Command.commitActivation state session (.tuple [list [], hwm, prompt, active])
      (list events) details checkpoint journal = .ok (result, rest)) : ActivationCommandEvents result := by
  unfold Command.commitActivation at call
  obtain ⟨input, _, inputRead, c1⟩ := bind_ok call
  have same : input = events := pure_ok inputRead
  subst input
  obtain ⟨candidate, _, _, c2⟩ := bind_ok c1
  obtain ⟨planned, _, promptCall, c3⟩ := bind_ok c2
  have promptSafe := activation_prompt_result promptCall
  split at c3
  · obtain ⟨sessionId, _, _, c4⟩ := bind_ok c3
    obtain ⟨promptEvents, _, promptRead, c5⟩ := bind_ok c4
    obtain ⟨same, _⟩ := asList_ok_iff.mp promptRead
    subst same
    change ActivationBatch promptEvents at promptSafe
    obtain ⟨leading, _, leadingRead, c6⟩ := bind_ok c5
    have same : leading = [] := pure_ok leadingRead
    subst leading
    obtain ⟨original, _, originalRead, c7⟩ := bind_ok c6
    have same : original = events := pure_ok originalRead
    subst original
    let status := Term.map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "active")]
    let allEvents := [] ++ events ++ (if active.truthy then promptEvents ++ [status] else [])
    have safeAll : ActivationBatch allEvents := by
      intro event member
      change event ∈ [] ++ events ++ (if active.truthy then promptEvents ++ [status] else []) at member
      simp only [List.nil_append, List.mem_append] at member
      rcases member with original | control
      · exact batch event original
      · split at control
        · rcases List.mem_append.mp control with snapshot | statusMember
          · exact promptSafe event snapshot
          · have same := List.mem_singleton.mp statusMember
            subst event
            exact ⟨by rfl, by simp +decide [ActivationEvent, Term.get, b, Term.text, status]⟩
        · simp at control
    by_cases emptyBatch : allEvents.isEmpty = true
    · dsimp only [allEvents, status] at emptyBatch
      simp only [emptyBatch, ↓reduceIte] at c7
      exact activated_no_write c7
    · dsimp only [allEvents, status] at emptyBatch
      simp only [emptyBatch, ↓reduceIte] at c7
      rw [pure_ok c7]
      exact safeAll
  · exact (fail_ok c3).elim

theorem commit_activation_input {state session hwm prompt active raw details checkpoint result : Term}
    {journal rest : List Term}
    (call : Command.commitActivation state session (.tuple [list [], hwm, prompt, active])
      raw details checkpoint journal = .ok (result, rest)) : ∃ events, raw = list events := by
  unfold Command.commitActivation at call
  obtain ⟨events, _, read, _⟩ := bind_ok call
  exact ⟨events, (asList_ok_iff.mp read).1⟩

theorem retire_activation_events {state session hwm prompt active result : Term} {journal rest : List Term}
    (call : Command.retireActivation state session (.tuple [list [], hwm, prompt, active]) journal = .ok (result, rest)) :
    ActivationCommandEvents result := by
  unfold Command.retireActivation at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨retirement, _, retired, call⟩ := bind_ok call
  split at call
  · obtain ⟨events, same⟩ := commit_activation_input call
    subst same
    exact commit_activation_events (activation_retirement_events retired) call
  · exact (fail_ok call).elim

theorem install_activation_events {state session hwm prompt active candidate checkpoint result : Term}
    {journal rest : List Term}
    (call : Command.installActivation state session (.tuple [list [], hwm, prompt, active])
      candidate checkpoint journal = .ok (result, rest)) : ActivationCommandEvents result := by
  unfold Command.installActivation at call
  iterate 3 obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨activation, _, started, call⟩ := bind_ok call
  have safe := activation_start_result started
  split at call
  · obtain ⟨events, same⟩ := commit_activation_input call
    subst same
    exact commit_activation_events safe call
  · rw [pure_ok call]
    trivial
  · exact (fail_ok call).elim

theorem authorized_activation_events {state session hwm prompt active candidate result : Term}
    {journal rest : List Term}
    (call : Command.authorizedActivation state session (.tuple [list [], hwm, prompt, active])
      candidate journal = .ok (result, rest)) : ActivationCommandEvents result := by
  unfold Command.authorizedActivation at call
  repeat' first
    | exact install_activation_events call
    | exact commit_activation_events (by simp [ActivationBatch]) call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; trivial)
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

theorem activate_events {state hwm prompt active checkpoint result : Term} {journal rest : List Term}
    (call : Command.activate state (.tuple [list [], hwm, prompt, active]) checkpoint journal = .ok (result, rest)) :
    ActivationCommandEvents result := by
  unfold Command.activate at call
  repeat' first
    | exact authorized_activation_events call
    | exact retire_activation_events call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; trivial)
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

theorem activation_command_events {state hwm prompt active checkpoint result : Term} {journal rest : List Term}
    (call : Command.start state (.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint])
      journal = .ok (result, rest)) : ActivationCommandEvents result := by
  apply activate_events
  simpa +decide [Command.start] using call

theorem activation_authorization_events {state hwm prompt active candidate response result : Term}
    {journal rest : List Term}
    (call : Command.resume state
      (.tuple [.tuple [b "activation_authorized", .tuple [list [], hwm, prompt, active], candidate], response])
      journal = .ok (result, rest)) : ActivationCommandEvents result := by
  simp +decide only [Command.resume, Command.resumeCommitted, b, Term.text, ↓reduceIte] at call
  repeat' first
    | exact authorized_activation_events call
    | exact retire_activation_events call
    | exact (fail_ok call).elim
    | (rw [pure_ok call]; trivial)
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

theorem activation_entropy_events {state hwm prompt active candidate response result : Term}
    {journal rest : List Term}
    (call : Command.resume state
      (.tuple [.tuple [b "activation_entropy", .tuple [list [], hwm, prompt, active], candidate], response])
      journal = .ok (result, rest)) : ActivationCommandEvents result := by
  simp +decide only [Command.resume, Command.resumeCommitted, b, Term.text, ↓reduceIte] at call
  repeat' first
    | exact install_activation_events call
    | exact (fail_ok call).elim
    | split at call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | dsimp only at call

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

theorem activation_write_preserves {cursor final : Cursor} {events : List Term} {hwm : Term}
    (ready : QueueReady cursor.working) (batch : ActivationBatch events)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list events, hwm])) final) :
    final.baseline = cursor.baseline ∧ final.etag = cursor.etag ∧ final.events = cursor.events ++ events ∧
      QueueReady final.working ∧ final.working.get (a "storage_format") = cursor.working.get (a "storage_format") ∧
      ∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented final.working sealed item := by
  obtain ⟨_, _, baselineEq, etagEq, eventsEq, _, applied⟩ := write_executes execution
  obtain ⟨middle, activation, metadataBatch⟩ := resident_batch_append applied
  obtain ⟨middleReady, _, activationKept⟩ := activation_batch_preserves ready batch activation
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  obtain ⟨finalReady, _, metadataKept⟩ := ValueSemantics.metadata_work metadataBatch keys metadata middleReady
  exact ⟨baselineEq, etagEq, eventsEq, finalReady, resident_batch_format applied,
    fun sealed item present => metadataKept sealed item (activationKept sealed item present)⟩

end VerifiedKernel.Session.PendingRevision
