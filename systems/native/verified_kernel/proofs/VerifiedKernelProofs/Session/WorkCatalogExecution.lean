import VerifiedKernelProofs.Session.WorkCatalogFrame
import VerifiedKernelProofs.Session.WorkArchiveInvariant

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem inner_catalog_frame {state event next : Term} {journal rest : List Term}
    (ordinary : (event.get (b "type") == b "archive_advance") = false)
    (call : inner state event journal = .ok (next, rest)) : CatalogFrame state next := by
  unfold inner at call
  simp only [ordinary, Bool.false_eq_true, ↓reduceIte, ite_ok_iff] at call
  catalog_frame_walk call

theorem resident_catalog_frame {state event next : Term}
    (step : ResidentStep state event next) (canonical : BinaryKeys event)
    (ordinary : (event.get (b "type") == b "archive_advance") = false) : CatalogFrame state next := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  have frames : CatalogFrame middle next := ⟨activity "segment_catalog" (by decide) (by decide),
    activity "archived_through" (by decide) (by decide), activity "session_id" (by decide) (by decide)⟩
  cases normalized with
  | none => rwa [prepareTrusted_none prepared] at frames
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact catalog_frame_trans (inner_catalog_frame ordinary call) frames

theorem batch_catalog_frame {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (ordinary : ∀ event ∈ events, (event.get (b "type") == b "archive_advance") = false) :
    CatalogFrame state next := by
  induction execution with
  | nil => exact catalog_frame_refl _
  | cons head tail ih =>
    exact catalog_frame_trans
      (resident_catalog_frame (resident_execution_step head) (canonical _ List.mem_cons_self)
        (ordinary _ List.mem_cons_self))
      (ih (fun event member => canonical event (List.mem_cons_of_mem _ member))
        (fun event member => ordinary event (List.mem_cons_of_mem _ member)))

theorem materialized_event_no_archive {ack event : Term} {consumes : List Term}
    (kind : MaterializedEvent ack consumes event) :
    (event.get (b "type") == b "archive_advance") = false := by
  rcases kind with record | ⟨ack, _⟩ | ⟨consume, _⟩ | retry
  · obtain ⟨_, delivery | runtime⟩ := record
    · simp +decide [delivery]
    · simp +decide [runtime]
  · simp +decide [ack]
  · simp +decide [consume]
  · simp +decide [retry]

theorem materialize_catalog_frame {state projected next : Term} {events journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : CatalogFrame state next := by
  obtain ⟨_, _, _, _, _, _, _, _, _, _, _, kinds⟩ := materialize_coordinates planned
  exact batch_catalog_frame execution (fun event member => (materialize_routed planned event member).1)
    (fun event member => materialized_event_no_archive (kinds event member))

theorem CatalogFrame.archive {state next : Term} (frame : CatalogFrame state next)
    (before : ArchiveInvariant state) : ArchiveInvariant next := before.fields frame.1 frame.2.1

end VerifiedKernel.Session.WorkConservation
