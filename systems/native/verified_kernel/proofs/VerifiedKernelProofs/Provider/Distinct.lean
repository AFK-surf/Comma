import VerifiedKernelProofs.Provider.CallKey
import VerifiedKernelProofs.Provider.AnsweredCore

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- No two tool calls of the list have equivalent ids. -/
def DistinctCalls (xs : List Term) : Prop :=
  (xs.flatMap callsOf).Pairwise fun x y => (CallKey.mk x == CallKey.mk y) = false

end VerifiedKernel.ProviderLoop
