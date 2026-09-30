import VerifiedKernelProofs.Session.WorkIdentityCodec

namespace VerifiedKernel.Session.WorkConservation
open Data ArchivePublication
set_option Elab.async false

theorem decoded_load_invariants {resident : Option Term} {snapshot decodedState loaded : Term}
    {bytes owner session : ByteArray} {sealed catalog : List Term} {watermark : Int} {objects : Objects}
    (ready : QueueReady snapshot) (format : snapshot.get (a "storage_format") = i 3)
    (header : LedgerHeader snapshot) (supported : LedgerSupported snapshot sealed)
    (backed : SealedImagesBacked objects snapshot sealed)
    (owned : snapshot.get (a "agent_id") = .binary owner) (identified : snapshot.get (a "session_id") = .binary session)
    (catalogRead : snapshot.get (a "segment_catalog") = list catalog)
    (through : snapshot.get (a "archived_through") = i watermark)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : ValueSemantics.Equivalent snapshot decodedState)
    (reload : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    QueueReady loaded ∧ loaded.get (a "storage_format") = i 3 ∧ LedgerHeader loaded ∧
      LedgerSupported loaded sealed ∧ SealedImagesBacked objects loaded sealed ∧
      loaded.get (a "agent_id") = .binary owner ∧ loaded.get (a "session_id") = .binary session ∧
      loaded.get (a "segment_catalog") = list catalog ∧ loaded.get (a "archived_through") = i watermark ∧
      ∀ item, ValueSemantics.Represented snapshot sealed item → ValueSemantics.Represented loaded sealed item := by
  have decodedReady := codec.ready ready
  have decodedHeader := equivalent_ledger_header header codec
  have decodedSupport := equivalent_ledger_supported codec supported
  have decodedBacked := backed.equivalent codec owned identified catalogRead valid
  have ownerField := codec.get (a "agent_id")
  have sessionField := codec.get (a "session_id")
  have formatField := codec.get (a "storage_format")
  have throughField := codec.get (a "archived_through")
  rw [owned] at ownerField
  rw [identified] at sessionField
  rw [format] at formatField
  rw [through] at throughField
  have decodedOwner := ownerField.binary
  have decodedSession := sessionField.binary
  have decodedFormat := formatField.integer
  have decodedThrough := throughField.integer
  have decodedCatalog := codec.catalog catalogRead valid
  have nonnilOwner : decodedState.get (a "agent_id") ≠ nil := by
    rw [decodedOwner]; intro impossible; cases impossible
  have nonnilSession : decodedState.get (a "session_id") ≠ nil := by
    rw [decodedSession]; intro impossible; cases impossible
  obtain ⟨journal, rest, normalized⟩ := load_trace_normalizes decoded decodedReady reload
  have fields := normalize_archive_fields decodedCatalog decodedThrough valid normalized
  exact ⟨(normalize_work decodedReady normalized).1, normalize_format decodedFormat normalized,
    normalize_ledger_header normalized, normalize_ledger_supported decodedReady decodedHeader decodedSupport normalized,
    decodedBacked.normalize nonnilOwner nonnilSession decodedCatalog decodedThrough valid normalized,
    (normalize_owner nonnilOwner normalized).trans decodedOwner,
    (normalize_session_id nonnilSession normalized).trans decodedSession, fields.1, fields.2,
    fun item represented => ValueSemantics.normalize_preserves decodedReady normalized (codec.represents represented)⟩

end VerifiedKernel.Session.WorkConservation
