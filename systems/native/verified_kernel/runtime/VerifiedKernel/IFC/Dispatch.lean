import VerifiedKernel.IFC.Kernel
import VerifiedKernel.IFC.Transfer

namespace VerifiedKernel.IFC
open Data

private def result (value : Term) : Term := .tuple [a "ok", value]

private def validCall (operation payload : Term) : Bool :=
  match operation, payload with
  | .atom "label_new", .tuple [.list xs] => xs.all atomValid
  | .atom "label_join_all", .tuple [.list xs] => xs.all labelValid
  | .atom "compaction_label", .tuple [.list xs] => xs.all itemValid
  | .atom "label_join", .tuple [x, y]
  | .atom "label_restricted", .tuple [x, y]
  | .atom "label_equal", .tuple [x, y] => labelValid x && labelValid y
  | .atom "label_public", .tuple [x]
  | .atom "label_no_human", .tuple [x]
  | .atom "label_runtime_only", .tuple [x]
  | .atom "label_atoms", .tuple [x] => labelValid x
  | .atom "readers_subset", .tuple [d, s, facts] => labelValid d && labelValid s && factsValid facts
  | .atom "atom_subset", .tuple [d, s, facts] => atomValid d && atomValid s && factsValid facts
  | .atom "reader", .tuple [p, s, facts] => principalValid p && labelValid s && factsValid facts
  | .atom "reader_atom", .tuple [p, s, facts] => principalValid p && atomValid s && factsValid facts
  | .atom "receipt_covers", .tuple [r, p, s, d] =>
    receiptValid r && principalValid p && labelValid s && labelValid d
  | .atom "receipt_valid_at", .tuple [r, .integer now] => receiptValid r && now ≥ 0
  | .atom "policy_in_place", .tuple [p]
  | .atom "policy_receipt", .tuple [p]
  | .atom "policy_instruction", .tuple [p] => policyValid p
  | .atom "facts_scope_kind", .tuple [facts, atom]
  | .atom "facts_within", .tuple [facts, atom]
  | .atom "facts_membership", .tuple [facts, atom]
  | .atom "facts_members", .tuple [facts, atom]
  | .atom "facts_revision", .tuple [facts, atom] => factsValid facts && atomValid atom
  | .atom "facts_member", .tuple [facts, p, atom] => factsValid facts && principalValid p && atomValid atom
  | .atom "facts_placement", .tuple [facts, p, c] => factsValid facts && principalValid p && c.isBinary
  | .atom "facts_external", .tuple [facts, p] => factsValid facts && principalValid p
  | _, _ => true

def invoke (operation payload : Term) : Term :=
  match operation, payload with
  | .atom "decide", .tuple [effect, activation, items, facts] => result (decide effect activation items facts)
  | .atom "transfer_start", .tuple [evidence] => result (Transfer.start evidence)
  | .atom "transfer_resume", .tuple [cursor, observation] => result (Transfer.resume cursor observation)
  | op, args =>
    if !dataValid args || !validCall op args then .tuple [a "error", a "invalid_input"] else
    match op, args with
    | .atom "atom_valid", .tuple [x] => result ((Tri.ofBool (atomValid x)).term)
    | .atom "atom_kind", .tuple [x] => result (atomKind x)
    | .atom "atom_connect", .tuple [x] => result (atomConnect x)
    | .atom "principal_valid", .tuple [x] => result ((Tri.ofBool (principalValid x)).term)
    | .atom "principal_authority", .tuple [x] => result (authority x)
    | .atom "principal_connect", .tuple [x] => result (principalConnect x)
    | .atom "label_bottom", .tuple [] => result (bottom)
    | .atom "label_new", .tuple [x] => result (label (normalize (values x)))
    | .atom "label_join", .tuple [x, y] => result (labelJoin x y)
    | .atom "label_join_all", .tuple [x] => result (joinAll (values x))
    | .atom "label_public", .tuple [x] => result ((Tri.ofBool (publicLabel x)).term)
    | .atom "label_no_human", .tuple [x] => result ((Tri.ofBool (noHuman x)).term)
    | .atom "label_runtime_only", .tuple [x] => result ((Tri.ofBool (runtimeOnly x)).term)
    | .atom "label_restricted", .tuple [x, y] => result ((Tri.ofBool (restricted x y)).term)
    | .atom "label_equal", .tuple [x, y] => result ((Tri.ofBool (labelEqual x y)).term)
    | .atom "label_atoms", .tuple [x] => result (list (sortedTerms (atoms x)))
    | .atom "policy_in_place", .tuple [x] => result ((Tri.ofBool (inPlaceAllowed x)).term)
    | .atom "policy_receipt", .tuple [x] => result ((Tri.ofBool (receiptAllowed x)).term)
    | .atom "policy_instruction", .tuple [x] => result ((Tri.ofBool (instructionAllowed x)).term)
    | .atom "facts_scope_kind", .tuple [x, y] => result (scopeKind x y)
    | .atom "facts_within", .tuple [x, y] => result (within x y)
    | .atom "facts_membership", .tuple [x, y] => result (membership x y)
    | .atom "facts_members", .tuple [x, y] => result (members x y)
    | .atom "facts_revision", .tuple [x, y] => result (revision x y)
    | .atom "facts_member", .tuple [x, y, z] => result ((member x y z).term)
    | .atom "facts_placement", .tuple [x, y, z] => result (placement x y z)
    | .atom "facts_external", .tuple [x, y] => result ((Tri.ofBool (external x y)).term)
    | .atom "receipt_valid_at", .tuple [x, y] => result ((Tri.ofBool (receiptValidAt x y)).term)
    | .atom "receipt_covers", .tuple [x, y, z, w] => result ((Tri.ofBool (receiptCovers x y z w)).term)
    | .atom "activation_valid", .tuple [x] => result ((Tri.ofBool (activationValid x)).term)
    | .atom "effect_valid", .tuple [x] => result ((Tri.ofBool (effectValid x)).term)
    | .atom "item_valid", .tuple [x] => result ((Tri.ofBool (itemValid x)).term)
    | .atom "readers_subset", .tuple [x, y, z] => result ((readersSubset x y z).term)
    | .atom "atom_subset", .tuple [x, y, z] => result ((atomSubset x y z).term)
    | .atom "reader", .tuple [x, y, z] => result ((reader x y z).term)
    | .atom "reader_atom", .tuple [x, y, z] => result ((readerAtom x y z).term)
    | .atom "compaction_label", .tuple [x] => result (joinAll ((values x).map (fun item => f item "label")))
    | _, _ => .tuple [a "error", a "invalid_input"]

end VerifiedKernel.IFC
