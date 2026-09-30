import VerifiedKernelProofs.Session.WorkNativeFenceEmbedding
import VerifiedKernelProofs.Session.WorkResidentTrace

namespace VerifiedKernel.Session.WorkConservation.CurrentExecution
open Data ArchivePublication CommandDriver
set_option Elab.async false

/-- Direct Store writes use the same current-byte transition; the wrapper is proof-only. -/
theorem native_store_commit {versions : VersionBytes} {before : ResidentWorld} {after : HotStore}
    {captured : CapturedRevision} {objects : Objects} {staged : PendingRevision.Cursor}
    {etag : ByteArray} {outcome : Term}
    (member : captured ∈ before.captured)
    (staging : Staging before.store.objects captured.cursor objects (.pending staged))
    (native : NativeFenceSubmission staged)
    (cas : HotCAS before.store.hot
      (.tuple [a "cas", native.requestedKey, native.requestedBytes, native.requestedBase])
      (.tuple [a "ok", .binary etag, outcome]) after)
    (tokens : after.versioned versions) :
    ResidentStep versions before
      (committedWorld before after objects captured.owner captured.session native.stamped (.binary etag)) :=
  .commit member staging (native.embed nil) cas tokens

end VerifiedKernel.Session.WorkConservation.CurrentExecution
