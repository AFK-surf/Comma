import VerifiedKernel.IFC.Data

namespace VerifiedKernel.IFC
open Data

def reason (clause : String) (ref : Term := nil) (detail : Term := nil) : Term :=
  record "Reason" [("clause", a clause), ("ref", ref), ("detail", detail), ("source_failures", list [])]
abbrev Check := Except Term

def sourceDenial (failures : List Term) : Term :=
  match failures with
  | [] => reason "invalid_input"
  | first :: _ => first.put (a "source_failures") (list (dedupe failures))

/-- Evaluate each selected source once. Preserve source order in the diagnostics.
FORMAL-SPEC: IFC/FullRefinement.lean collectSources_ok preserves successful results. -/
def collectSources (check : Term → Check Term) (sources : List Term) : Check (List Term) :=
  let results := sources.map check
  let failures := results.filterMap (fun result => match result with
    | .error why => some why | .ok _ => none)
  if failures.isEmpty then
    .ok (results.filterMap (fun result => match result with
      | .ok entry => some entry | .error _ => none))
  else .error (sourceDenial failures)

def kinds (source : Term) : Term := list (uniq (sortedTerms ((atoms source).map atomKind)))
def sealedKinds (source policy : Term) : Term :=
  list (sortedTerms (((atoms source).filter (contains (setValues (f policy "sealed_atoms")))).map atomKind))
def sealed (source policy : Term) : Bool :=
  (atoms source).any (contains (setValues (f policy "sealed_atoms")))
def findReceipt (facts p source destination : Term) : Option Term :=
  let receipts := (setValues (f facts "receipts")).mergeSort (fun x y =>
    match f x "id", f y "id" with
    | .binary a, .binary b => compare a.toList b.toList != .gt
    | _, _ => true)
  (receipts.find? (fun r => receiptValidAt r (f facts "now") &&
    receiptCovers r p source destination)).map (fun r => f r "id")

inductive Admission where
  | flow | inPlace | instruction | receipt (id : Term)
inductive Denial where
  | sealed | unknown | flow
def Admission.term : Admission → Term
  | .flow => a "flow" | .inPlace => a "in_place" | .instruction => a "instruction"
  | .receipt id => .tuple [a "receipt", id]

/-- This is the clause selector used by every source admission. -/
def selectAdmission (flow readable : Tri) (locked inPlace instruction : Bool)
    (receipt : Option Term) : Except Denial Admission :=
  if flow == .yes then .ok .flow
  else if locked then .error .sealed
  else if readable == .yes then
    if inPlace then .ok .inPlace
    else if instruction then .ok .instruction
    else match receipt with
      | some id => .ok (.receipt id)
      | none => if flow == .unknown then .error .unknown else .error .flow
  else if flow == .unknown || readable == .unknown then .error .unknown
  else .error .flow

def admitSource (source effect activation p facts : Term) : Check Term :=
  let sourceLabel := f source "label"
  let destination := f effect "destination"
  let policy := f facts "policy"
  let readable := reader p sourceLabel facts
  let receipt := if readable == .yes && receiptAllowed policy then
      findReceipt facts p sourceLabel destination else none
  match selectAdmission (readersSubset destination sourceLabel facts) readable
      (sealed sourceLabel policy)
      (labelEqual destination (f activation "source_scope") && inPlaceAllowed policy)
      (instructionAllowed policy) receipt with
  | .ok clause => .ok (.tuple [f source "ref", clause.term])
  | .error .sealed => .error (reason "sealed" (f source "ref") (sealedKinds sourceLabel policy))
  | .error .unknown => .error (reason "membership_unknown" (f source "ref") (kinds sourceLabel))
  | .error .flow => .error (reason "flow_denied" (f source "ref") (kinds sourceLabel))

def checkWriter (effect activation p facts : Term) : Check Unit :=
  let policy := f facts "policy"
  let mode := f policy "external_principals"
  let externalOk := !external facts p || mode == a "as_internal" ||
    (mode == a "own_thread_only" && labelEqual (f effect "destination") (f activation "source_scope"))
  let writers := f effect "writers"
  if !externalOk then .error (reason "external_principal_denied")
  else if writers == a "any" then .ok ()
  else if writers == a "unknown" then .error (reason "writers_unknown")
  else if contains (setValues writers) (authority p) then .ok ()
  else .error (reason "writer_not_authorized")

def checkPublic (effect : Term) (sources : List Term) (facts : Term) : Check Unit :=
  if !publicLabel (f effect "destination") || f (f facts "policy") "public_egress" == a "receipt" then .ok ()
  else match sources.find? (fun s => !publicLabel (f s "label")) with
    | none => .ok ()
    | some _ => .error (sourceDenial ((sources.filter (fun s => !publicLabel (f s "label"))).map
        (fun source => reason "public_egress_denied" (f source "ref"))))

def checkUniqueRefsAux (seen : List Term) : List Term → Check Unit
  | [] => .ok ()
  | item :: rest =>
      if contains seen (f item "ref") then
        .error (reason "duplicate_item_ref" (f item "ref"))
      else checkUniqueRefsAux (f item "ref" :: seen) rest
def checkUniqueRefs (items : List Term) : Check Unit := checkUniqueRefsAux [] items
def requestCheck (item activation : Term) : Check Unit :=
  let ref := f item "ref"
  if f item "integrity" != a "command" then .error (reason "request_not_command" ref)
  else if f item "principal" == nil then .error (reason "request_without_principal" ref)
  else if !contains (setValues (f activation "consumed_refs")) ref then .error (reason "request_outside_activation" ref)
  else if authority (f item "principal") != authority (f activation "requester") then
    .error (reason "request_principal_mismatch" ref)
  else .ok ()
def resolveRequest (effect activation : Term) (items : List Term) : Check Term := do
  let ref := f effect "request"
  let some item := items.find? (fun item => f item "ref" == ref)
    | throw (reason "unknown_request_ref" ref)
  requestCheck item activation
  return item
def resolveSource (items : List Term) (ref : Term) : Check Term :=
  match items.find? (fun item => f item "ref" == ref) with
  | some item => .ok item
  | none => .error (reason "unknown_source_ref" ref)
def resolveSources (effect request : Term) (items : List Term) : Check (List Term) :=
  if f effect "sources" == a "context" then .ok (dedupe (request :: items))
  else do
    let selected ← collectSources (resolveSource items) (values (f effect "sources"))
    return dedupe selected
def validate (effect activation items facts : Term) : Check Unit :=
  if !tagged effect "Effect" || !tagged activation "Activation" || !tagged facts "Facts" ||
      !(match items with | .list _ => true | _ => false) then .error (reason "invalid_input")
  else if !dataValid effect || !effectValid effect then .error (reason "invalid_input" nil (a "effect"))
  else if !dataValid activation || !activationValid activation then .error (reason "invalid_input" nil (a "activation"))
  else if !dataValid items || !(values items).all itemValid then .error (reason "invalid_input" nil (a "items"))
  else if !dataValid facts || !factsValid facts then .error (reason "invalid_input" nil (a "facts"))
  else .ok ()

/-- The whole authorization pipeline runs before evidence is constructed.
FORMAL-SPEC: IFC/DecisionContract.lean Authorized; IFC/FullRefinement.lean decideChecked_sound. -/
def decideChecked (effect activation rawItems facts : Term) : Check Term := do
  validate effect activation rawItems facts
  let items := values rawItems
  checkUniqueRefs items
  let request ← resolveRequest effect activation items
  let p := f request "principal"
  let sources ← resolveSources effect request items
  checkPublic effect sources facts
  checkWriter effect activation p facts
  let admitted ← collectSources (fun source => admitSource source effect activation p facts) sources
  return record "Evidence" [("request", f effect "request"), ("requester", authority p),
    ("destination", f effect "destination"), ("sources", list admitted),
    ("membership_revisions", consultedRevisions effect facts sources)]

def decide (effect activation items facts : Term) : Term :=
  match decideChecked effect activation items facts with
  | .ok evidence => .tuple [a "allow", evidence]
  | .error why => .tuple [a "deny", why]

end VerifiedKernel.IFC
