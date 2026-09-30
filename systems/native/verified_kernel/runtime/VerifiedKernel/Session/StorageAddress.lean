import VerifiedKernel.Encoding

namespace VerifiedKernel.Session.StorageAddress
open Data

/-- This is the existing hot-object address, not a new authenticity check. -/
def key (agent session : ByteArray) : Term :=
  .binary ("agents/".toUTF8 ++ agent ++ "/internal_runtime/sessions/".toUTF8 ++
    hex (ByteDigest.sha256Bytes session) ++ "/state.etf.zst".toUTF8)

def agrees (state objectKey : Term) : Bool :=
  match state.get (a "agent_id"), state.get (a "session_id") with
  | .binary agent, .binary session => objectKey == key agent session
  | _, _ => false

end VerifiedKernel.Session.StorageAddress
