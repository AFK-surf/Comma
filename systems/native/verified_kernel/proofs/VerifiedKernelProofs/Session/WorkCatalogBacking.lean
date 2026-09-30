import VerifiedKernelProofs.Session.WorkPhysicalBatch

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

theorem StateCatalogBacked.fields {objects : Objects} {state next : Term}
    (owner : next.get (a "agent_id") = state.get (a "agent_id"))
    (session : next.get (a "session_id") = state.get (a "session_id"))
    (catalog : next.get (a "segment_catalog") = state.get (a "segment_catalog"))
    (before : StateCatalogBacked objects state) : StateCatalogBacked objects next := by
  simpa only [StateCatalogBacked, owner, session, catalog] using before

theorem StateCatalogBacked.mono {before after : Objects} {state : Term}
    (extension : ObjectsExtend before after) (backed : StateCatalogBacked before state) :
    StateCatalogBacked after state := fun entry member => (backed entry member).mono extension

theorem StateCatalogBacked.initial {state : Term} (objects : Objects)
    (initial : InitialFields state) : StateCatalogBacked objects state := by
  intro entry member
  rw [initial.catalog] at member
  simp [list, Term.default, Term.truthy, wrap] at member

theorem StateCatalogBacked.equivalent {objects : Objects} {state next : Term} {owner session : ByteArray}
    (codec : ValueSemantics.Equivalent state next)
    (owned : state.get (a "agent_id") = .binary owner) (identified : state.get (a "session_id") = .binary session)
    (archive : ArchiveInvariant state) (before : StateCatalogBacked objects state) : StateCatalogBacked objects next := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := archive
  have nextOwner := codec.get (a "agent_id")
  have nextSession := codec.get (a "session_id")
  rw [owned] at nextOwner
  rw [identified] at nextSession
  exact before.fields (nextOwner.binary.trans owned.symm) (nextSession.binary.trans identified.symm)
    ((codec.catalog read valid).trans read.symm)

theorem StateCatalogBacked.normalize {objects : Objects} {state next : Term} {journal rest : List Term}
    (owned : state.get (a "agent_id") ≠ nil) (identified : state.get (a "session_id") ≠ nil)
    (archive : ArchiveInvariant state) (before : StateCatalogBacked objects state)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) : StateCatalogBacked objects next := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := archive
  exact before.fields (normalize_owner owned call) (normalize_session_id identified call)
    ((normalize_archive_fields read through valid call).1.trans read.symm)

theorem StateCatalogBacked.admitted {objects : Objects} {state next : Term} {events : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (before : StateCatalogBacked objects state) : StateCatalogBacked objects next := by
  have frame := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (admitted_nonretiring (allowed event member)).2.2)
  exact before.fields (admitted_resident_owner execution canonical allowed) frame.2.2 frame.1

theorem StateCatalogBacked.materialize {objects : Objects} {state projected next : Term} {events journal rest : List Term}
    {limit : Int} {wake : Bool} {hwm : Term}
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next)
    (before : StateCatalogBacked objects state) : StateCatalogBacked objects next := by
  have frame := materialize_catalog_frame planned execution
  exact before.fields (materialize_owner planned execution) frame.2.2 frame.1

theorem StateCatalogBacked.publication {state event next : Term} {records journal rest : List Term}
    {ceiling line : Int} {before after : Objects} {final : Output}
    (initial : StateCatalogBacked before state)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (execution : Execution (start state (i line)) before final after)
    (emitted : final.2 = .tuple [a "advance", event])
    (reduced : archiveAdvance state event journal = .ok (next, rest)) : StateCatalogBacked after next := by
  rcases archiveAdvance_storage_fields reduced with same | ⟨entries, watermark, permuted, read, through, owner, session⟩
  · subst next
    exact initial.mono (execution_objects_extend execution)
  · intro catalogEntry member
    rw [read] at member
    have member : catalogEntry ∈ entries := by simpa only [list, default_list, wrap] using member
    have emittedEntry := (List.mem_filter.mp (permuted.mem_iff.mp member)).1
    rw [owner, session]
    exact publication_scoped_catalog initial window positive execution emitted catalogEntry emittedEntry

end VerifiedKernel.Session.ArchivePublication
