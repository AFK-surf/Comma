import VerifiedKernel.IFC.Data

namespace VerifiedKernel.IFC.Transfer
open Data

def receiptId : Term → Option ByteArray
  | .tuple [_, .tuple [.atom "receipt", .binary id]] => some id
  | _ => none

def ids (evidence : Term) : List ByteArray :=
  ((values (f evidence "sources")).filterMap receiptId).eraseDups

def next : List ByteArray → Term
  | [] => a "ok"
  | id :: rest => .tuple [a "consume", .binary id, .list (rest.map Term.binary)]

def start (evidence : Term) : Term := next (ids evidence)

def bytes : Term → Option ByteArray
  | .binary id => some id
  | _ => none

def resume (cursor observation : Term) : Term :=
  match cursor with
  | .list raw => match raw.mapM bytes with
    | some pending => match observation with
      | .tuple [.atom "ok", .atom "true"] => next pending
      | .tuple [.atom "ok", .atom "false"] => .tuple [a "error", a "receipt_already_used"]
      | _ => .tuple [a "error", a "receipt_unavailable"]
    | none => .tuple [a "error", a "invalid_input"]
  | _ => .tuple [a "error", a "invalid_input"]

end VerifiedKernel.IFC.Transfer
