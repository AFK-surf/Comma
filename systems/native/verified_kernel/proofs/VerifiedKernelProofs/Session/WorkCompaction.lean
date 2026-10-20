import VerifiedKernelProofs.Session.WorkFrames

namespace VerifiedKernel.Session.WorkConservation
open Data

def WorkFieldsPreserved (s t : Term) : Prop :=
  t.get (a "input_queue") = s.get (a "input_queue") ∧
  t.get (a "messages") = s.get (a "messages")

end VerifiedKernel.Session.WorkConservation
