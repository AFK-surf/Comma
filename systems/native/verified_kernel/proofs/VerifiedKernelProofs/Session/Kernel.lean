import VerifiedKernelProofs.Order
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Metadata
import VerifiedKernel.Session.Activity
import VerifiedKernelProofs.Session.Progress
import VerifiedKernel.Session.Async
import VerifiedKernel.Session.Queue
import VerifiedKernel.Session.Replies
import VerifiedKernel.Session.Transcript
import VerifiedKernel.Session.Fact
import VerifiedKernel.Session.History
import VerifiedKernel.Schema

namespace VerifiedKernel.Session
open Data

theorem detach_done (next : Term) : detach (.tuple [a "done", next]) = (some next, .tuple [a "done"]) := rfl

theorem attach_detach_reduce (request state event observations : Term) :
    let (resident, response) := detach (.tuple [a "observe", request, .tuple [a "reduce", state, event, observations]])
    ∃ token, response = .tuple [a "observe", request, token] ∧
      resident.map (fun r => attach r token) = some (.tuple [a "reduce", state, event, observations]) :=
  ⟨_, rfl, rfl⟩

theorem attach_detach_activity (request next state view event observations : Term) :
    let (resident, response) :=
      detach (.tuple [a "observe", request, .tuple [a "activity", next, state, view, event, observations]])
    ∃ token, response = .tuple [a "observe", request, token] ∧
      resident.map (fun r => attach r token) =
        some (.tuple [a "activity", next, state, view, event, observations]) :=
  ⟨_, rfl, rfl⟩

end VerifiedKernel.Session
