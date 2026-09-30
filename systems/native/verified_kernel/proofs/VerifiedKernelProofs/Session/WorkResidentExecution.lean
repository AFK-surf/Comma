import VerifiedKernelProofs.Session.WorkCapturedRevision
import VerifiedKernelProofs.Session.WorkStoreExecution
import VerifiedKernelProofs.Session.WorkBirth

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

structure ResidentWorld where
  store : World
  captured : List CapturedRevision

def ResidentInitial : ResidentWorld := ⟨Initial, []⟩

/-- Captures are a proof overapproximation: even a lost CAS reply may retain its candidate here.
Actual confirmations must additionally follow the native reply continuation. -/
inductive ResidentStep (versions : VersionBytes) : ResidentWorld → ResidentWorld → Prop where
  | birth {before : ResidentWorld} {after : HotStore} {owner session etag bytes : ByteArray}
      {state snapshot outcome : Term} {journal rest : List Term}
      (born : Birth before.captured owner session state)
      (persisted : Lifecycle.persistable state journal = .ok (snapshot, rest))
      (encoded : ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes)
      (cas : HotCAS before.store.hot
        (.tuple [a "cas", StorageAddress.key owner session, .binary bytes, nil])
        (.tuple [a "ok", .binary etag, outcome]) after)
      (tokens : after.versioned versions) :
      ResidentStep versions before
        ⟨⟨after, before.store.objects⟩, ⟨owner, session, .committed state (.binary etag)⟩ :: before.captured⟩
  | read (before : ResidentWorld) (call : ReadCall before.store.hot) :
      ResidentStep versions before ⟨before.store, capturedRead call :: before.captured⟩
  | create {before : ResidentWorld} {after : HotStore} {owner session etag : ByteArray}
      {state attrs fresh continuation outcome : Term} {journal rest : List Term}
      (created : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (fresh, rest))
      (write : WriteSubmission (Revision.Cursor.fresh fresh).candidate continuation)
      (cas : HotCAS before.store.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase])
        (.tuple [a "ok", .binary etag, outcome]) after)
      (tokens : after.versioned versions) :
      ResidentStep versions before
        ⟨⟨after, before.store.objects⟩, ⟨owner, session, .committed write.stamped (.binary etag)⟩ :: before.captured⟩
  | fork {before : ResidentWorld} {after : HotStore} {source : CapturedRevision} {session etag : ByteArray}
      {attrs fresh continuation outcome : Term} {journal rest : List Term}
      (captured : source ∈ before.captured)
      (forked : Fork.fork source.cursor.candidate.working (.tuple [.binary session, attrs]) journal =
        .ok (.tuple [a "ok", fresh], rest))
      (write : WriteSubmission (Revision.Cursor.fresh fresh).candidate continuation)
      (cas : HotCAS before.store.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase])
        (.tuple [a "ok", .binary etag, outcome]) after)
      (tokens : after.versioned versions) :
      ResidentStep versions before
        ⟨⟨after, before.store.objects⟩, ⟨source.owner, session, .committed write.stamped (.binary etag)⟩ :: before.captured⟩
  | commit {before : ResidentWorld} {after : HotStore} {objects : Objects} {source : CapturedRevision}
      {next : Revision.Cursor} {continuation outcome : Term} {etag : ByteArray}
      (captured : source ∈ before.captured)
      (staging : Staging before.store.objects source.cursor objects next)
      (write : WriteSubmission next.candidate continuation)
      (cas : HotCAS before.store.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase])
        (.tuple [a "ok", .binary etag, outcome]) after)
      (tokens : after.versioned versions) :
      ResidentStep versions before
        ⟨⟨after, objects⟩, ⟨source.owner, source.session, .committed write.stamped (.binary etag)⟩ :: before.captured⟩
  | objects {before : ResidentWorld} {objects : Objects}
      (extension : ObjectsExtend before.store.objects objects) :
      ResidentStep versions before ⟨⟨before.store.hot, objects⟩, before.captured⟩
  | unchanged (before : ResidentWorld) : ResidentStep versions before before
  | forget {before : ResidentWorld} {remaining : List CapturedRevision}
      (included : ∀ captured ∈ remaining, captured ∈ before.captured) :
      ResidentStep versions before ⟨before.store, remaining⟩

def ResidentInvariant (framing : CodecFraming) (versions : VersionBytes) (world : ResidentWorld) : Prop :=
  world.store.hot.lineage framing world.store.objects ∧ world.store.hot.versioned versions ∧
    ∀ captured ∈ world.captured, captured.Valid framing world.store.objects versions

theorem resident_initial_invariant (framing : CodecFraming) (versions : VersionBytes) :
    ResidentInvariant framing versions ResidentInitial := by
  refine ⟨HotStore.empty_lineage _ _, ?_, ?_⟩
  · intro key value stored
    cases stored
  · intro captured member
    cases member

theorem ResidentStep.invariant {framing : CodecFraming} {versions : VersionBytes} {before after : ResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (valid : ResidentInvariant framing versions before) (step : ResidentStep versions before after) :
    ResidentInvariant framing versions after ∧ ObjectsExtend before.store.objects after.store.objects ∧
      ∀ key fact, before.store.fact key fact → after.store.fact key fact := by
  cases step with
  | birth born persisted encoded cas tokens =>
    have history := born.physical valid.2.2
    have stored := cas.landed_read
    refine ⟨⟨cas.lineage valid.1 rfl encoded (history.persist persisted), tokens, ?_⟩,
      fun _ _ h => h, cas.absent_preserves_fact⟩
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact retained_captured_valid history persisted encoded stored (by simp [nil]) rfl tokens codec
    · exact valid.2.2 captured old
  | read call =>
    refine ⟨⟨valid.1, valid.2.1, ?_⟩, fun _ _ h => h, fun _ _ h => h⟩
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact captured_read_valid call codec valid.1 valid.2.1
    · exact valid.2.2 captured old
  | @create after owner session etag state attrs fresh continuation outcome journal rest created write cas tokens =>
    have history : PhysicalHistory framing before.store.objects owner session fresh [] := .create created
    obtain ⟨addressed, _, snapshot, bytes, encoded, issued, _, nextHistory, _⟩ := write.current_facts history cas
    have applied : HotCAS before.store.hot (.tuple [a "cas", write.key, .binary bytes, nil])
        (.tuple [a "ok", .binary etag, outcome]) after := by rwa [issued] at cas
    refine ⟨⟨applied.lineage valid.1 addressed encoded nextHistory, tokens, ?_⟩,
      fun _ _ h => h, applied.absent_preserves_fact⟩
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_valid write history cas (by simp [nil]) tokens codec
    · exact valid.2.2 captured old
  | fork captured forked write cas tokens =>
    obtain ⟨sealed, sourceHistory⟩ := (valid.2.2 _ captured).1
    have history := sourceHistory.fork forked
    obtain ⟨addressed, _, snapshot, bytes, encoded, issued, _, nextHistory, _⟩ := write.current_facts history cas
    have original := cas
    rw [issued] at cas
    change HotCAS before.store.hot (.tuple [a "cas", write.key, .binary bytes, nil]) _ _ at cas
    refine ⟨⟨cas.lineage valid.1 addressed encoded nextHistory, tokens, ?_⟩,
      fun _ _ h => h, cas.absent_preserves_fact⟩
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_valid write history original (by simp [nil]) tokens codec
    · exact valid.2.2 captured old
  | commit captured staging write cas tokens =>
    have sourceValid := valid.2.2 _ captured
    obtain ⟨lineage, extension, kept⟩ := sourceValid.landed staging write codec roundtrip valid.1 valid.2.1 cas
    obtain ⟨sealed, history⟩ := sourceValid.1
    obtain ⟨_, _, nextSealed, nextHistory, _⟩ := staging.identities history
    refine ⟨⟨lineage, tokens, ?_⟩, extension, kept⟩
    intro captured member
    rcases List.mem_cons.mp member with rfl | old
    · exact landed_captured_valid write nextHistory cas (by simp [nil]) tokens codec
    · exact (valid.2.2 captured old).objects extension
  | objects extension =>
    exact ⟨⟨HotStore.lineage_objects valid.1 extension, valid.2.1,
      fun captured member => (valid.2.2 captured member).objects extension⟩,
      extension, fun _ _ present => HotStore.fact_objects extension present⟩
  | unchanged => exact ⟨valid, fun _ _ h => h, fun _ _ h => h⟩
  | forget included =>
    exact ⟨⟨valid.1, valid.2.1, fun captured member => valid.2.2 captured (included captured member)⟩,
      fun _ _ h => h, fun _ _ h => h⟩

inductive ResidentReachable (versions : VersionBytes) : ResidentWorld → List ResidentWorld → Prop where
  | initial : ResidentReachable versions ResidentInitial []
  | next {before after : ResidentWorld} {past : List ResidentWorld}
      (prior : ResidentReachable versions before past) (step : ResidentStep versions before after) :
      ResidentReachable versions after (before :: past)

theorem ResidentReachable.conservation {framing : CodecFraming} {versions : VersionBytes}
    {current : ResidentWorld} {past : List ResidentWorld}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : ResidentReachable versions current past) :
    ResidentInvariant framing versions current ∧
      ∀ earlier ∈ current :: past, ∀ key fact, earlier.store.fact key fact → current.store.fact key fact := by
  induction execution with
  | initial =>
    refine ⟨resident_initial_invariant framing versions, ?_⟩
    intro earlier member key fact present
    have same : earlier = ResidentInitial := by simpa using member
    simpa only [same] using present
  | next prior step ih =>
    obtain ⟨valid, _, kept⟩ := step.invariant codec roundtrip ih.1
    refine ⟨valid, ?_⟩
    intro earlier member key fact present
    rcases List.mem_cons.mp member with rfl | old
    · exact present
    · exact kept key fact (ih.2 earlier old key fact present)

end VerifiedKernel.Session.WorkConservation.CurrentExecution
