import VerifiedKernelProofs.Session.WorkReadRevision
import VerifiedKernelProofs.Session.WorkPhysicalPreservation

namespace VerifiedKernel.SessionDomain.ReadRevision
open Data Session.WorkConservation Session.ArchivePublication
set_option Elab.async false

theorem current_read_physical_preserves {framing : CodecFraming} {objects : Objects} {store : HotStore}
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
    ∃ state, cursor = (Session.Revision.Cursor.committed state (.binary etag)).pack ∧
      PhysicalHistory framing objects agent session state sealed ∧
      ∀ item, PhysicalIdentityFact objects snapshot (.work item) → PhysicalIdentityFact objects state (.work item) := by
  obtain ⟨_, _, state, journal, rest, normalized, _, _, captured, _⟩ :=
    current_read_preserves history current started read decoded codec trace
  have decodedHistory := history.decode decoded codec
  exact ⟨state, captured, decodedHistory.normalize normalized, fun item present =>
    decodedHistory.normalize_physical normalized item (history.decode_physical codec item present)⟩

end VerifiedKernel.SessionDomain.ReadRevision
