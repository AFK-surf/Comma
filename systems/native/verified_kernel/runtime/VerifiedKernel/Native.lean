import VerifiedKernel.Dispatch
import VerifiedKernel.Terminal

/-!
# Native entry point

The NIF links the import closure of this module and initializes it. The
dispatcher and the terminal emulator are independent: proofs about the
dispatcher import `VerifiedKernel.Dispatch` and do not depend on the terminal.
-/
