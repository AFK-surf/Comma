import VerifiedKernelProofs.Session.WorkArchiveWatermark
import VerifiedKernelProofs.Session.WorkCatalogBacking
import VerifiedKernelProofs.Session.WorkInitialScope
import VerifiedKernelProofs.Session.WorkDurableReload

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

structure PhysicalInvariant (objects : Objects) (owner session : ByteArray) (state : Term) (sealed : List Term) : Prop where
  history : KernelHistory state sealed
  archive : ArchiveInvariant state
  nonnegative : ArchiveNonnegative state
  catalog : StateCatalogBacked objects state
  images : SealedImagesBacked objects state sealed
  owned : state.get (a "agent_id") = .binary owner
  identified : state.get (a "session_id") = .binary session

theorem PhysicalInvariant.owner_not_nil {objects : Objects} {owner session : ByteArray} {state : Term} {sealed : List Term}
    (before : PhysicalInvariant objects owner session state sealed) : state.get (a "agent_id") ≠ nil := by
  rw [before.owned]
  intro impossible
  cases impossible

theorem PhysicalInvariant.session_not_nil {objects : Objects} {owner session : ByteArray} {state : Term} {sealed : List Term}
    (before : PhysicalInvariant objects owner session state sealed) : state.get (a "session_id") ≠ nil := by
  rw [before.identified]
  intro impossible
  cases impossible

theorem PhysicalInvariant.create {objects : Objects} {owner session : ByteArray} {state attrs next : Term} {journal rest : List Term}
    (call : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (next, rest)) :
    PhysicalInvariant objects owner session next [] := by
  have initial := create_initial_fields call
  have scope := create_scope call
  exact ⟨.create call, initial.archive, initial.archive_nonnegative, StateCatalogBacked.initial objects initial,
    by simp [SealedImagesBacked], scope.1, scope.2⟩

theorem PhysicalInvariant.fork {objects : Objects} {owner session sourceSession : ByteArray}
    {source attrs next : Term} {sealed journal rest : List Term}
    (before : PhysicalInvariant objects owner sourceSession source sealed)
    (call : Fork.fork source (.tuple [.binary session, attrs]) journal = .ok (.tuple [a "ok", next], rest)) :
    PhysicalInvariant objects owner session next [] := by
  have format := before.history.invariant.format
  have initial := modern_fork_initial format call
  have scope := modern_fork_scope before.owned format call
  exact ⟨.fork format call, initial.archive, initial.archive_nonnegative, StateCatalogBacked.initial objects initial,
    by simp [SealedImagesBacked], scope.1, scope.2⟩

theorem PhysicalInvariant.admitted {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (before : PhysicalInvariant objects owner session state sealed) (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true) :
    PhysicalInvariant objects owner session next sealed := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (admitted_nonretiring (allowed event member)).2.2)
  exact ⟨.nonretiring before.history execution canonical (fun event member => admitted_nonretiring (allowed event member)),
    fields.archive before.archive, before.nonnegative.fields fields.2.1,
    before.catalog.admitted execution canonical allowed,
    admitted_batch_sealed_images execution canonical allowed before.images,
    (admitted_resident_owner execution canonical allowed).trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.nonretiring {objects : Objects} {owner session : ByteArray} {state next : Term}
    {sealed events : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (execution : ResidentBatch state events next) (canonical : ∀ event ∈ events, BinaryKeys event)
    (safe : ∀ event ∈ events, NonRetiring event) (ownerFrame : OwnerFrame state next) :
    PhysicalInvariant objects owner session next sealed := by
  have fields := batch_catalog_frame execution canonical
    (fun event member => binary_ne_false (safe event member).2.2)
  exact ⟨.nonretiring before.history execution canonical safe, fields.archive before.archive,
    before.nonnegative.fields fields.2.1, before.catalog.fields ownerFrame fields.2.2 fields.1,
    before.images.fields ownerFrame fields.2.2 fields.1, ownerFrame.trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.reduceOrdinary {objects : Objects} {owner session : ByteArray}
    {state event next : Term} {sealed journal rest : List Term}
    (before : PhysicalInvariant objects owner session state sealed)
    (safe : NonRetiring event) (ownerFrame : OwnerFrame state next)
    (call : inner state event journal = .ok (next, rest)) :
    PhysicalInvariant objects owner session next sealed := by
  have fields := inner_catalog_frame (binary_ne_false safe.2.2) call
  exact ⟨.reduceOrdinary before.history safe call, fields.archive before.archive,
    before.nonnegative.fields fields.2.1, before.catalog.fields ownerFrame fields.2.2 fields.1,
    before.images.fields ownerFrame fields.2.2 fields.1, ownerFrame.trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.materialize {objects : Objects} {owner session : ByteArray} {state next : Term}
    {sealed events journal rest : List Term} {limit : Int} {wake : Bool} {hwm : Term}
    (before : PhysicalInvariant objects owner session state sealed)
    (planned : StateQuery.materialize state limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : PhysicalInvariant objects owner session next sealed := by
  have fields := materialize_catalog_frame planned execution
  exact ⟨.materialize before.history planned execution, fields.archive before.archive,
    before.nonnegative.fields fields.2.1, before.catalog.materialize planned execution,
    materialize_sealed_images planned execution before.images,
    (materialize_owner planned execution).trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.materialize_framed {objects : Objects} {owner session : ByteArray}
    {state projected next : Term} {sealed events journal rest : List Term} {limit : Int} {wake : Bool} {hwm : Term}
    (before : PhysicalInvariant objects owner session state sealed)
    (queue : projected.get (a "input_queue") = state.get (a "input_queue"))
    (ack : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
    (sessionEq : state.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) : PhysicalInvariant objects owner session next sealed := by
  have fields := materialize_catalog_frame planned execution
  exact ⟨.materialize_framed before.history queue ack sessionEq planned execution, fields.archive before.archive,
    before.nonnegative.fields fields.2.1, before.catalog.materialize planned execution,
    materialize_sealed_images planned execution before.images,
    (materialize_owner planned execution).trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.metadata {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed events : List Term}
    (before : PhysicalInvariant objects owner session state sealed) (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event) (metadata : ∀ event ∈ events, CommitMetadata event) :
    PhysicalInvariant objects owner session next sealed := by
  have fields := metadata_batch_archive_frame execution canonical metadata
  have owned := (commit_metadata_batch_frames execution canonical metadata).2.2
  exact ⟨.nonretiring before.history execution canonical (fun event member => commit_metadata_nonretiring (metadata event member)),
    before.archive.fields fields.1 fields.2.1, before.nonnegative.fields fields.2.1,
    before.catalog.fields owned fields.2.2 fields.1, before.images.fields owned fields.2.2 fields.1,
    owned.trans before.owned, fields.2.2.trans before.identified⟩

theorem PhysicalInvariant.activity {objects : Objects} {owner session : ByteArray} {state next : Term} {sealed : List Term}
    (before : PhysicalInvariant objects owner session state sealed) (frame : ActivityFrame state next) :
    PhysicalInvariant objects owner session next sealed := by
  have owned := frame "agent_id" (by decide) (by decide)
  have identified := frame "session_id" (by decide) (by decide)
  have catalog := frame "segment_catalog" (by decide) (by decide)
  have watermark := frame "archived_through" (by decide) (by decide)
  exact ⟨.activity before.history frame, before.archive.fields catalog watermark,
    before.nonnegative.fields watermark, before.catalog.fields owned identified catalog,
    before.images.fields owned identified catalog, owned.trans before.owned, identified.trans before.identified⟩

theorem PhysicalInvariant.normalize {objects : Objects} {owner session : ByteArray} {state next : Term}
    {sealed journal rest : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) : PhysicalInvariant objects owner session next sealed := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before.archive
  have fields := normalize_archive_fields read through valid call
  exact ⟨.normalize before.history call, before.archive.normalize call,
    before.nonnegative.fields (fields.2.trans through.symm),
    before.catalog.normalize before.owner_not_nil before.session_not_nil before.archive call,
    before.images.normalize before.owner_not_nil before.session_not_nil read through valid call,
    (normalize_owner before.owner_not_nil call).trans before.owned,
    (normalize_session_id before.session_not_nil call).trans before.identified⟩

theorem PhysicalInvariant.persist {objects : Objects} {owner session : ByteArray} {state next : Term}
    {sealed journal rest : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (call : Lifecycle.persistable state journal = .ok (next, rest)) : PhysicalInvariant objects owner session next sealed := by
  have fields := persistable_archive_fields call
  have owned := persistable_owner call
  have identified := (persistable_queue_frame call).2.2.2.1
  exact ⟨.persist before.history call, before.archive.persist call, before.nonnegative.fields fields.2,
    before.catalog.fields owned identified fields.1, before.images.fields owned identified fields.1,
    owned.trans before.owned, identified.trans before.identified⟩

theorem PhysicalInvariant.prepare {objects : Objects} {owner session : ByteArray} {state next : Term}
    {sealed journal rest : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    PhysicalInvariant objects owner session next sealed := by
  have format := before.history.invariant.format
  obtain ⟨catalog, watermark, read, through, valid⟩ := before.archive
  have fields := prepareWrite_archive_fields format read through valid call
  obtain ⟨prepared, same, owned⟩ := prepareWrite_owner before.owner_not_nil format (Or.inr rfl) call
  have equal : next = prepared := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst prepared
  have identified := prepare_write_session_id before.session_not_nil format call
  exact ⟨.prepare before.history call, before.archive.prepare format call,
    before.nonnegative.fields (fields.2.trans through.symm),
    before.catalog.fields owned identified (fields.1.trans read.symm),
    before.images.fields owned identified (fields.1.trans read.symm),
    owned.trans before.owned, identified.trans before.identified⟩

theorem PhysicalInvariant.objects {objects nextObjects : Objects} {owner session : ByteArray}
    {state : Term} {sealed : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (extension : ObjectsExtend objects nextObjects) : PhysicalInvariant nextObjects owner session state sealed :=
  { before with catalog := before.catalog.mono extension, images := before.images.mono extension }

theorem PhysicalInvariant.reload {objects : Objects} {owner session bytes : ByteArray}
    {state decodedState next : Term} {resident : Option Term} {sealed : List Term}
    (before : PhysicalInvariant objects owner session state sealed)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent state decodedState)
    (trace : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some next, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    PhysicalInvariant objects owner session next sealed := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before.archive
  have logical := before.history.invariant
  obtain ⟨_, _, _, _, images, owned, identified, nextCatalog, nextThrough, _⟩ :=
    decoded_load_invariants logical.ready logical.format logical.header logical.supported before.images
      before.owned before.identified read through valid decoded codec trace
  refine ⟨.reload before.history decoded codec trace, ⟨catalog, watermark, nextCatalog, nextThrough, valid⟩,
    before.nonnegative.fields (nextThrough.trans through.symm), ?_, images, owned, identified⟩
  exact before.catalog.fields (owned.trans before.owned.symm) (identified.trans before.identified.symm)
    (nextCatalog.trans read.symm)

theorem PhysicalInvariant.decode {objects : Objects} {owner session bytes : ByteArray}
    {state next : Term} {sealed : List Term} (before : PhysicalInvariant objects owner session state sealed)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, next]))
    (codec : ValueSemantics.Equivalent state next) : PhysicalInvariant objects owner session next sealed := by
  obtain ⟨catalog, watermark, read, through, valid⟩ := before.archive
  obtain ⟨base, baseRead, nonnegative⟩ := before.nonnegative
  have owned := codec.get (a "agent_id")
  have identified := codec.get (a "session_id")
  have archived := codec.get (a "archived_through")
  rw [before.owned] at owned
  rw [before.identified] at identified
  rw [baseRead] at archived
  exact ⟨.decode before.history decoded codec, before.archive.equivalent codec,
    ⟨base, archived.integer, nonnegative⟩,
    before.catalog.equivalent codec before.owned before.identified before.archive,
    before.images.equivalent codec before.owned before.identified read valid, owned.binary, identified.binary⟩

theorem PhysicalInvariant.publication {objects nextObjects : Objects} {owner session : ByteArray}
    {state event next : Term} {sealed records live dropped kept journal rest : List Term}
    {ceiling line : Int} {final : Output}
    (before : PhysicalInvariant objects owner session state sealed) (framing : CodecFraming)
    (window : StorageQuery.archiveWindow state [] = .ok (.tuple [a "ok", list records, i ceiling], []))
    (positive : line > 0) (execution : Execution (start state (i line)) objects final nextObjects)
    (emitted : final.2 = .tuple [a "advance", event])
    (reduced : archiveAdvance state event journal = .ok (next, rest))
    (read : state.get (a "messages") = list live) (partition : live = dropped ++ kept)
    (after : next.get (a "messages") = list kept) :
    PhysicalInvariant nextObjects owner session next (sealed ++ dropped) := by
  obtain ⟨catalog, watermark, catalogRead, through, valid⟩ := before.archive
  obtain ⟨base, baseRead, nonnegative⟩ := before.nonnegative
  have numeric : (state.get (a "archived_through")).default (i 0) = i base := by
    rw [baseRead]; exact default_integer _ _
  have catalogValid : ∀ value ∈ wrap ((state.get (a "segment_catalog")).default (list [])),
      validSegment value = true := by
    simpa only [catalogRead, list, default_list, wrap] using valid
  obtain ⟨removed, retained, split, retainedRead, _, images⟩ := published_archive_sealed_images
    framing before.history.invariant.sorted numeric nonnegative before.catalog catalogValid window positive
      execution emitted read before.history.invariant.supported before.images reduced
  have sameKept : kept = retained := by
    simpa only [list, Term.list.injEq] using after.symm.trans retainedRead
  subst retained
  have sameDropped : dropped = removed := by
    simpa using partition.symm.trans split
  subst removed
  have kind : event.get (b "type") = b "archive_advance" := by
    obtain ⟨_, _, _, _, shape, _⟩ := publication_catalog_backed before.catalog execution emitted
    rw [shape]
    rfl
  have scope : next.get (a "agent_id") = state.get (a "agent_id") ∧
      next.get (a "session_id") = state.get (a "session_id") := by
    rcases archiveAdvance_storage_fields reduced with same | ⟨_, _, _, _, _, owned, identified⟩
    · subst next; exact ⟨rfl, rfl⟩
    · exact ⟨owned, identified⟩
  exact ⟨.archive before.history kind reduced read partition after, before.archive.advance reduced,
    before.nonnegative.advance reduced, before.catalog.publication window positive execution emitted reduced,
    images, scope.1.trans before.owned, scope.2.trans before.identified⟩

end VerifiedKernel.Session.WorkConservation
