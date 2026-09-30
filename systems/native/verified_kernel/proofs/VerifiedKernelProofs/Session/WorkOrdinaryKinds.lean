import VerifiedKernelProofs.Session.WorkCanonical

namespace VerifiedKernel.Session.WorkConservation
open Data

def OrdinaryKind (kind : Term) : Prop :=
  kind ≠ b "queue_ack" ∧ kind ≠ b "queue_consume" ∧
    kind ≠ b "archive_advance" ∧ kind ≠ b "session_stamp"

def OrdinaryBatch (events : List Term) : Prop :=
  ∀ event ∈ events, BinaryKeys event ∧ OrdinaryKind (event.get (b "type"))

/-- Classification follows the kernel's key conversion, including atom and nested chardata keys. -/
def RawOrdinary (event : Term) : Prop :=
  ∀ normalized journal rest, shallowStringify event journal = .ok (normalized, rest) →
    OrdinaryKind (normalized.get (b "type"))

def RawOrdinaryBatch (events : List Term) : Prop := ∀ event ∈ events, RawOrdinary event

theorem OrdinaryBatch.raw {events : List Term} (batch : OrdinaryBatch events) : RawOrdinaryBatch events := by
  intro event member normalized journal rest converted
  rw [shallowStringify_binary_keys (batch event member).1 converted]
  exact (batch event member).2

end VerifiedKernel.Session.WorkConservation
