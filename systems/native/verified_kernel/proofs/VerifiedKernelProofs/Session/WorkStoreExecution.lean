import VerifiedKernelProofs.Session.WorkStagedExecution

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

structure World where
  hot : HotStore
  objects : Objects

def World.work (world : World) (key item : Term) : Prop := world.hot.work world.objects key item

def World.fact (world : World) (key : Term) (fact : IdentityFact) : Prop := world.hot.fact world.objects key fact

def Initial : World := ⟨fun _ => none, fun _ _ => False⟩

/-- These constructors cover genesis and read-based input writers. Other writers need separate constructors. -/
inductive Step (versions : VersionBytes) : List World → World → Prop where
  | create {before : World} {past : List World} {after : HotStore}
      {owner session : ByteArray} {state attrs fresh continuation result : Term} {journal rest : List Term}
      (created : Lifecycle.create state (.tuple [.binary owner, .binary session, attrs]) journal = .ok (fresh, rest))
      (write : WriteSubmission (Revision.Cursor.fresh fresh).candidate continuation)
      (cas : HotCAS before.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after)
      (tokens : after.versioned versions) :
      Step versions (before :: past) ⟨after, before.objects⟩
  | fork {before observed : World} {past : List World} {after : HotStore}
      {session : ByteArray} {attrs fresh continuation result : Term} {journal rest : List Term}
      (observedEarlier : observed ∈ before :: past) (read : ReadCall observed.hot)
      (forked : Fork.fork read.context.candidate.working (.tuple [.binary session, attrs]) journal =
        .ok (.tuple [a "ok", fresh], rest))
      (write : WriteSubmission (Revision.Cursor.fresh fresh).candidate continuation)
      (cas : HotCAS before.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after)
      (tokens : after.versioned versions) :
      Step versions (before :: past) ⟨after, before.objects⟩
  | input {before observed : World} {past : List World} {after : HotStore} {result : Term}
      (observedEarlier : observed ∈ before :: past)
      (call : ReadInputSubmission observed.hot)
      (cas : HotCAS before.hot call.request result after) (tokens : after.versioned versions) :
      Step versions (before :: past) ⟨after, before.objects⟩
  | objects {before : World} {past : List World} {after : Objects}
      (extension : ObjectsExtend before.objects after) :
      Step versions (before :: past) ⟨before.hot, after⟩
  | staged {before observed : World} {past : List World} {after : HotStore} {nextObjects : Objects}
      {next : Revision.Cursor} {continuation result : Term}
      (observedEarlier : observed ∈ before :: past) (read : ReadCall observed.hot)
      (staging : Staging before.objects read.context nextObjects next)
      (write : WriteSubmission next.candidate continuation)
      (cas : HotCAS before.hot
        (.tuple [a "cas", write.requestedKey, write.requestedBytes, write.requestedBase]) result after)
      (tokens : after.versioned versions) :
      Step versions (before :: past) ⟨after, nextObjects⟩
  | unchanged (before : World) (past : List World) : Step versions (before :: past) before

/-- Historical worlds are observation points. Only the head is the current store. -/
def Invariant (framing : CodecFraming) (versions : VersionBytes) (current : World) (past : List World) : Prop :=
  (∀ earlier ∈ current :: past, earlier.hot.lineage framing current.objects ∧ earlier.hot.versioned versions) ∧
  (∀ earlier ∈ current :: past, ObjectsExtend earlier.objects current.objects) ∧
  ∀ earlier ∈ current :: past, ∀ key fact, earlier.fact key fact → current.fact key fact

theorem initial_invariant (framing : CodecFraming) (versions : VersionBytes) :
    Invariant framing versions Initial [] := by
  refine ⟨?_, ?_, ?_⟩
  · intro earlier member
    have same : earlier = Initial := by simpa using member
    subst earlier
    exact ⟨HotStore.empty_lineage _ _, fun key value absent => by cases absent⟩
  · intro earlier member
    have same : earlier = Initial := by simpa using member
    subst earlier
    exact fun _ _ stored => stored
  · intro earlier member
    have same : earlier = Initial := by simpa using member
    subst earlier
    exact fun _ _ present => present

theorem Step.current {framing : CodecFraming} {versions : VersionBytes} {before after : World} {past : List World}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (safe : Invariant framing versions before past) (step : Step versions (before :: past) after) :
    after.hot.lineage framing after.objects ∧ after.hot.versioned versions ∧
      ObjectsExtend before.objects after.objects ∧
      ∀ key fact, before.fact key fact → after.fact key fact := by
  have current := safe.1 before List.mem_cons_self
  cases step with
  | @create _ _ after owner session state attrs fresh continuation result journal rest created write cas tokens =>
    have history : PhysicalHistory framing before.objects owner session fresh [] := .create created
    obtain ⟨addressed, etag, snapshot, bytes, encoded, issued, stored, nextHistory, kept⟩ :=
      write.current_facts history cas
    have applied : HotCAS before.hot (.tuple [a "cas", write.key, .binary bytes, nil]) result after := by
      rw [issued] at cas
      exact cas
    exact ⟨applied.lineage current.1 addressed encoded nextHistory, tokens, fun _ _ h => h,
      applied.absent_preserves_fact⟩
  | fork observedEarlier read forked write cas tokens =>
    obtain ⟨sealed, sourceHistory, _⟩ := read.history (safe.1 _ observedEarlier).1 codec
    have history := sourceHistory.fork forked
    obtain ⟨addressed, etag, snapshot, bytes, encoded, issued, stored, nextHistory, kept⟩ :=
      write.current_facts history cas
    rw [issued] at cas
    change HotCAS before.hot (.tuple [a "cas", write.key, .binary bytes, nil]) _ _ at cas
    exact ⟨cas.lineage current.1 addressed encoded nextHistory, tokens, fun _ _ h => h,
      cas.absent_preserves_fact⟩
  | input observedEarlier call cas tokens =>
    obtain ⟨lineage, extension, preserved⟩ := (Staging.input call.input).landed call.toReadCall call.input.fence codec roundtrip
      (safe.1 _ observedEarlier).1 current.1 (safe.1 _ observedEarlier).2 current.2 cas
    exact ⟨lineage, tokens, extension, preserved⟩
  | objects extension =>
    exact ⟨HotStore.lineage_objects current.1 extension, current.2, extension,
      fun _ _ present => HotStore.fact_objects extension present⟩
  | staged observedEarlier read staging write cas tokens =>
    obtain ⟨lineage, extension, kept⟩ := staging.landed read write codec roundtrip
      (safe.1 _ observedEarlier).1 current.1 (safe.1 _ observedEarlier).2 current.2 cas
    exact ⟨lineage, tokens, extension, kept⟩
  | unchanged => exact ⟨current.1, current.2, fun _ _ h => h, fun _ _ h => h⟩

theorem Step.invariant {framing : CodecFraming} {versions : VersionBytes} {before after : World} {past : List World}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (safe : Invariant framing versions before past) (step : Step versions (before :: past) after) :
    Invariant framing versions after (before :: past) := by
  obtain ⟨lineage, tokens, extension, preserved⟩ := step.current codec roundtrip safe
  refine ⟨?_, ?_, ?_⟩
  · intro earlier member
    rcases List.mem_cons.mp member with rfl | old
    · exact ⟨lineage, tokens⟩
    · exact ⟨HotStore.lineage_objects (safe.1 earlier old).1 extension, (safe.1 earlier old).2⟩
  · intro earlier member
    rcases List.mem_cons.mp member with rfl | old
    · exact fun _ _ h => h
    · exact fun key records stored => extension key records (safe.2.1 earlier old key records stored)
  · intro earlier member key item present
    rcases List.mem_cons.mp member with rfl | old
    · exact present
    · exact preserved key item (safe.2.2 earlier old key item present)

inductive Reachable (versions : VersionBytes) : World → List World → Prop where
  | initial : Reachable versions Initial []
  | next {before after : World} {past : List World}
      (prior : Reachable versions before past) (step : Step versions (before :: past) after) :
      Reachable versions after (before :: past)

theorem Reachable.invariant {framing : CodecFraming} {versions : VersionBytes} {current : World} {past : List World}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : Reachable versions current past) : Invariant framing versions current past := by
  induction execution with
  | initial => exact initial_invariant framing versions
  | next prior step ih => exact step.invariant codec roundtrip ih

/-- Landed work survives every later step in this execution domain, whether or not its caller received a reply. -/
theorem Reachable.work_conserved {framing : CodecFraming} {versions : VersionBytes}
    {current earlier : World} {past : List World} {key item : Term}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : Reachable versions current past) (observed : earlier ∈ current :: past)
    (landed : earlier.work key item) : current.work key item :=
  (execution.invariant (framing := framing) codec roundtrip).2.2 earlier observed key (.work item) landed

theorem Reachable.fact_conserved {framing : CodecFraming} {versions : VersionBytes}
    {current earlier : World} {past : List World} {key : Term} {fact : IdentityFact}
    (codec : SnapshotCodec)
    (roundtrip : ∀ snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes →
      ∃ decoded, ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decoded]))
    (execution : Reachable versions current past) (observed : earlier ∈ current :: past)
    (landed : earlier.fact key fact) : current.fact key fact :=
  (execution.invariant (framing := framing) codec roundtrip).2.2 earlier observed key fact landed

theorem Reachable.earlier {versions : VersionBytes} {current observed : World} {past : List World}
    (execution : Reachable versions current past) (member : observed ∈ current :: past) :
    ∃ earlierPast, Reachable versions observed earlierPast := by
  induction execution with
  | initial =>
    have same : observed = Initial := by simpa using member
    subst observed
    exact ⟨[], .initial⟩
  | next prior step ih =>
    rcases List.mem_cons.mp member with rfl | old
    · exact ⟨_, .next prior step⟩
    · exact ih old

end VerifiedKernel.Session.WorkConservation.CurrentExecution
