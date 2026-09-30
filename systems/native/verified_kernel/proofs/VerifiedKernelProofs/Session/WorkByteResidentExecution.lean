import VerifiedKernelProofs.Session.WorkArchiveByteStore
import VerifiedKernelProofs.Session.WorkResidentExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication
set_option Elab.async false

structure ByteResidentWorld where
  hot : HotStore
  archive : ByteStore
  captured : List CapturedRevision

def ByteResidentWorld.erase (world : ByteResidentWorld) : ResidentWorld :=
  ⟨⟨world.hot, world.archive.objects⟩, world.captured⟩

def ByteResidentInitial : ByteResidentWorld := ⟨fun _ => none, fun _ => none, []⟩

theorem byte_resident_initial : ByteResidentInitial.erase = ResidentInitial := by
  have empty : ByteStore.objects (fun _ : Term => (none : Option ByteArray)) = fun _ _ => False := by
    funext address records
    apply propext
    simp [ByteStore.objects]
  simp only [ByteResidentWorld.erase, ByteResidentInitial, empty, ResidentInitial, Initial]

noncomputable def insertArchiveBytes (store : ByteStore) (address : Term) (bytes : ByteArray) : ByteStore := by
  classical
  exact fun query => if query = address then some bytes else store query

theorem byte_insert_extends {store : ByteStore} {address : Term} {bytes : ByteArray}
    (absent : store address = none) : store.Extends (insertArchiveBytes store address bytes) := by
  intro query old stored
  unfold insertArchiveBytes
  split
  · subst query
    rw [absent] at stored
    cases stored
  · exact stored

inductive ByteResidentStep (versions : VersionBytes) : ByteResidentWorld → ByteResidentWorld → Prop where
  | hot {before after : ByteResidentWorld}
      (sameArchive : after.archive = before.archive)
      (step : ResidentStep versions before.erase after.erase) : ByteResidentStep versions before after
  | create {before : ByteResidentWorld} {address : Term} {bytes : ByteArray}
      (absent : before.archive address = none) :
      ByteResidentStep versions before { before with archive := insertArchiveBytes before.archive address bytes }
  | existing {before : ByteResidentWorld} {address : Term} {bytes : ByteArray}
      (present : before.archive address = some bytes) : ByteResidentStep versions before before

theorem ByteResidentStep.erase {versions : VersionBytes} {before after : ByteResidentWorld}
    (step : ByteResidentStep versions before after) : ResidentStep versions before.erase after.erase := by
  cases step with
  | hot _ step => exact step
  | @create address bytes absent => exact .objects (byte_insert_extends (bytes := bytes) absent).objects
  | existing _ => exact .unchanged _

theorem ByteResidentStep.archive_extends {versions : VersionBytes} {before after : ByteResidentWorld}
    (step : ByteResidentStep versions before after) : before.archive.Extends after.archive := by
  cases step with
  | hot same _ => rw [same]; exact fun _ _ h => h
  | @create address bytes absent => exact byte_insert_extends (bytes := bytes) absent
  | existing _ => exact fun _ _ h => h

inductive ByteResidentReachable (versions : VersionBytes) : ByteResidentWorld → List ByteResidentWorld → Prop where
  | initial : ByteResidentReachable versions ByteResidentInitial []
  | next {before after : ByteResidentWorld} {past : List ByteResidentWorld}
      (prior : ByteResidentReachable versions before past) (step : ByteResidentStep versions before after) :
      ByteResidentReachable versions after (before :: past)

theorem ByteResidentReachable.erase {versions : VersionBytes} {world : ByteResidentWorld}
    {past : List ByteResidentWorld} (run : ByteResidentReachable versions world past) :
    ResidentReachable versions world.erase (past.map ByteResidentWorld.erase) := by
  induction run with
  | initial => rw [byte_resident_initial]; exact .initial
  | next _ step ih => exact .next ih step.erase

theorem ByteResidentReachable.conservation {framing : CodecFraming} {versions : VersionBytes}
    {world : ByteResidentWorld} {past : List ByteResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (run : ByteResidentReachable versions world past) :
    ResidentInvariant framing versions world.erase ∧
      ∀ earlier ∈ world :: past, ∀ key fact,
        earlier.erase.store.fact key fact → world.erase.store.fact key fact := by
  obtain ⟨invariant, kept⟩ := run.erase.conservation (framing := framing) codec roundtrip
  refine ⟨invariant, ?_⟩
  intro earlier member key fact present
  apply kept earlier.erase _ key fact present
  exact List.mem_map_of_mem member

end VerifiedKernel.Session.WorkConservation.CurrentExecution
