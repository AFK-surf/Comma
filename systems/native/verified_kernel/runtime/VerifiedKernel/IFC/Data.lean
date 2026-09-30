import VerifiedKernel.Order

namespace VerifiedKernel.IFC
open Data

@[inline] def f (value : Term) (name : String) : Term := value.get (a name)
def record (name : String) (fields : List (String × Term)) : Term :=
  .map ((a "__struct__", a ("Elixir.SalixIFC." ++ name)) :: fields.map (fun (k, v) => (a k, v)))
@[inline] def tagged (value : Term) (name : String) : Bool :=
  value.isMap && f value "__struct__" == a ("Elixir.SalixIFC." ++ name)
def values : Term → List Term
  | .list xs => xs
  | _ => []
def keys : Term → List Term
  | .map xs => xs.map Prod.fst
  | _ => []
def setValues (value : Term) : List Term := keys (f value "map")
def set (xs : List Term) : Term :=
  .map [(a "__struct__", a "Elixir.MapSet"), (a "map", .map ((uniq xs).map (fun x => (x, list []))))]
def isSet (value : Term) : Bool :=
  value.isMap && f value "__struct__" == a "Elixir.MapSet" &&
  (match value with | .map xs => xs.length == 2 | _ => false) &&
  (match f value "map" with | .map xs => xs.all (fun x => x.2 == list []) | _ => false)
def contains (xs : List Term) (x : Term) : Bool := xs.any (· == x)
def subset (xs ys : List Term) : Bool := xs.all (contains ys)
def setEqual (xs ys : List Term) : Bool := subset xs ys && subset ys xs

def atomValid : Term → Bool
  | .atom "public" | .atom "agent_private" => true
  | .tuple [.atom "scope", .binary _, .binary _] => true
  | .tuple [.atom kind, .binary _] =>
    ["space", "tag", "conversation", "group", "task"].contains kind
  | _ => false
def atomKind : Term → Term
  | .tuple (kind :: _) => kind
  | other => other
def atomConnect : Term → Term
  | .tuple [.atom "space", c] | .tuple [.atom "scope", c, _] => c
  | _ => nil

def principalValidFuel : Nat → Term → Bool
  | 0, _ => false
  | n + 1, value =>
    match value with
    | .atom "system" => true
    | .tuple [.atom "provider_user", .binary _, .binary _] => true
    | .tuple [.atom "comma_user", .binary _] | .tuple [.atom "agent", .binary _] => true
    | .tuple [.atom "schedule", .binary _, creator] | .tuple [.atom "api_key", .binary _, creator] =>
      principalValidFuel n creator
    | _ => false
def principalValid (p : Term) : Bool := principalValidFuel (p.depth + 1) p
def authorityFuel : Nat → Term → Term
  | 0, p => p
  | n + 1, .tuple [.atom "schedule", _, creator]
  | n + 1, .tuple [.atom "api_key", _, creator] => authorityFuel n creator
  | _, p => p
def authority (p : Term) : Term := authorityFuel (p.depth + 1) p
def principalConnect (p : Term) : Term :=
  match authority p with | .tuple [.atom "provider_user", c, _] => c | _ => nil

def atoms (label : Term) : List Term := setValues (f label "atoms")
def label (xs : List Term) : Term := record "Label" [("atoms", set xs)]
def normalize (xs : List Term) : List Term :=
  let xs := uniq xs
  if xs.isEmpty then [a "public"]
  else if xs.length == 1 then xs else xs.filter (· != a "public")
def bottom : Term := label [a "public"]
def labelJoin (x y : Term) : Term := label (normalize (atoms x ++ atoms y))
def joinAll (xs : List Term) : Term := xs.foldl labelJoin bottom
def publicLabel (x : Term) : Bool := setEqual (atoms x) [a "public"]
def noHuman (x : Term) : Bool := contains (atoms x) (a "agent_private")
def runtimeOnly (x : Term) : Bool := setEqual (atoms x) [a "agent_private"]
def labelEqual (x y : Term) : Bool := setEqual (atoms x) (atoms y)
def restricted (d s : Term) : Bool := subset (atoms s) (atoms d) || publicLabel s
def labelValid (x : Term) : Bool :=
  tagged x "Label" && isSet (f x "atoms") && (atoms x).all atomValid

def inPlaceAllowed (p : Term) : Bool :=
  contains [a "in_place_and_receipt", a "trust_requester_instruction"] (f p "declassification")
def receiptAllowed (p : Term) : Bool := f p "declassification" != a "none"
def instructionAllowed (p : Term) : Bool := f p "declassification" == a "trust_requester_instruction"
def policyValid (p : Term) : Bool :=
  tagged p "Policy" &&
  contains [a "in_place_and_receipt", a "receipt_only", a "trust_requester_instruction", a "none"] (f p "declassification") &&
  contains [a "own_thread_only", a "deny", a "as_internal"] (f p "external_principals") &&
  contains [a "receipt", a "deny", a "allow_public_sources_only"] (f p "public_egress") &&
  isSet (f p "sealed_atoms") && (setValues (f p "sealed_atoms")).all atomValid

def scopeKind (facts atom : Term) : Term :=
  match atom with
  | .tuple [.atom "space", _] => a "space"
  | _ => let entry := (f facts "scopes").get atom
         if entry == nil then a "unknown" else f entry "kind"
def within (facts atom : Term) : Term := f ((f facts "scopes").get atom) "within"
def membership (facts atom : Term) : Term :=
  let table := f facts "membership"
  if table.has atom then table.get atom else a "unknown"
def members (facts atom : Term) : Term :=
  match membership facts atom with | .tuple [.atom "members", xs, _] => xs | _ => a "unknown"
def revision (facts atom : Term) : Term :=
  match membership facts atom with | .tuple [.atom "members", _, rev] => rev | _ => nil
def placement (facts p connect : Term) : Term :=
  let byConnect := (f facts "placements").get (authority p)
  if byConnect.has connect then byConnect.get connect else a "unknown"
def external (facts p : Term) : Bool :=
  let connect := principalConnect p
  connect != nil && placement facts p connect == a "external"

inductive Tri where
  | yes | no | unknown
  deriving BEq, DecidableEq, ReflBEq, LawfulBEq
def Tri.term : Tri → Term
  | .yes => a "true" | .no => a "false" | .unknown => a "unknown"
def Tri.ofBool (b : Bool) : Tri := if b then .yes else .no
def Tri.and : Tri → Tri → Tri
  | .no, _ | _, .no => .no
  | .unknown, _ | _, .unknown => .unknown
  | .yes, .yes => .yes
def Tri.or : Tri → Tri → Tri
  | .yes, _ | _, .yes => .yes
  | .unknown, _ | _, .unknown => .unknown
  | .no, .no => .no
def allTri (xs : List Term) (test : Term → Tri) : Tri := xs.foldl (fun acc x => acc.and (test x)) .yes
def anyTri (xs : List Term) (test : Term → Tri) : Tri := xs.foldl (fun acc x => acc.or (test x)) .no
def member (facts key atom : Term) : Tri :=
  match membership facts atom with
  | .tuple [.atom "members", xs, _] => .ofBool (contains (setValues xs) key)
  | _ => .unknown
def readerAtom (p atom facts : Term) : Tri :=
  match atom with
  | .atom "public" => .yes
  | .atom "agent_private" => .no
  | .tuple [.atom "space", c] =>
    match placement facts p c with
    | .atom "internal" => .yes
    | .atom "external" => .no
    | _ => member facts (authority p) atom
  | _ => member facts (authority p) atom
def withinWalk : Nat → Term → Term → Term → Bool
  | 0, _, _, _ => false
  | n + 1, child, ancestor, facts =>
    let parent := within facts child
    if parent == nil then false
    else if parent == ancestor then true else withinWalk n parent ancestor facts
def atomSubset (d s facts : Term) : Tri :=
  if d == s || s == a "public" || d == a "agent_private" then .yes
  else if s == a "agent_private" || d == a "public" then .no
  else if withinWalk 8 d s facts then .yes
  else if withinWalk 8 s d facts then .no
  else let known := members facts d
       if isSet known then allTri (setValues known) (fun p => readerAtom p s facts)
       else if scopeKind facts s == a "direct" then .no else .unknown
def readersSubset (d s facts : Term) : Tri :=
  if restricted d s || publicLabel s || noHuman d then .yes
  else allTri (atoms s) (fun src => anyTri (atoms d) (fun dst => atomSubset dst src facts))
def reader (p source facts : Term) : Tri := allTri (atoms source) (fun x => readerAtom p x facts)

def receiptValidAt (receipt now : Term) : Bool :=
  match f receipt "expires_at", now with
  | .atom "never", _ => true
  | .integer expiry, .integer clock => clock < expiry
  | _, _ => false
def receiptCovers (receipt p source destination : Term) : Bool :=
  authority (f receipt "requester") == authority p &&
  labelEqual (f receipt "destination") destination && restricted (f receipt "sources") source
def receiptValid (r : Term) : Bool :=
  tagged r "Receipt" && (f r "id").isBinary && principalValid (f r "requester") &&
  labelValid (f r "sources") && labelValid (f r "destination") &&
  (match f r "expires_at" with | .atom "never" => true | .integer n => n ≥ 0 | _ => false)
def activationValid (v : Term) : Bool :=
  tagged v "Activation" && principalValid (f v "requester") &&
  labelValid (f v "source_scope") && isSet (f v "consumed_refs") &&
  (setValues (f v "consumed_refs")).all Term.isBinary
def effectValid (v : Term) : Bool :=
  tagged v "Effect" && labelValid (f v "destination") && (f v "request").isBinary &&
  (contains [a "any", a "unknown"] (f v "writers") ||
    (isSet (f v "writers") && (setValues (f v "writers")).all principalValid)) &&
  (f v "sources" == a "context" ||
    (match f v "sources" with | .list xs => xs.all Term.isBinary | _ => false))
def itemValid (v : Term) : Bool :=
  tagged v "Item" && (f v "ref").isBinary && labelValid (f v "label") &&
  contains [a "command", a "data"] (f v "integrity") &&
  (f v "principal" == nil || principalValid (f v "principal"))

def mapAll (value : Term) (test : Term → Term → Bool) : Bool :=
  match value with | .map xs => xs.all (fun (k, v) => test k v) | _ => false
def factsValid (v : Term) : Bool :=
  tagged v "Facts" && policyValid (f v "policy") &&
  (match f v "now" with | .integer n => n ≥ 0 | _ => false) &&
  isSet (f v "receipts") && (setValues (f v "receipts")).all receiptValid &&
  mapAll (f v "scopes") (fun atom entry =>
    atomValid atom && entry.isMap &&
    contains [a "room", a "direct", a "shared"] (f entry "kind") &&
    (f entry "within" == nil || atomValid (f entry "within"))) &&
  mapAll (f v "membership") (fun atom entry =>
    atomValid atom && (match entry with
      | .atom "unknown" => true
      | .tuple [.atom "members", xs, .integer rev] =>
        rev ≥ 0 && isSet xs && (setValues xs).all principalValid
      | _ => false)) &&
  mapAll (f v "placements") (fun p byConnect => principalValid p &&
    mapAll byConnect (fun c place => c.isBinary && contains [a "internal", a "external"] place))

-- Only these explicit data records may cross the IFC boundary.
def dataFuel : Nat → Term → Bool
  | 0, _ => false
  | n + 1, v =>
    match v with
    | .map xs =>
      let allowed := if !v.has (a "__struct__") then true
        else if f v "__struct__" == a "Elixir.MapSet" then isSet v
        else ["Label", "Activation", "Effect", "Item", "Facts", "Policy", "Receipt"].any (tagged v)
      allowed && xs.all (fun (k, value) => dataFuel n k && dataFuel n value)
    | .list xs | .tuple xs => xs.all (dataFuel n)
    | .improper _ _ => false
    | _ => true
def dataValid (v : Term) : Bool := dataFuel (v.depth + 1) v

/-- Canonical first-occurrence order for declared source references. -/
def dedupe (items : List Term) : List Term :=
  (items.foldl (fun (acc : List Term × List Term) item =>
    let ref := f item "ref"
    if contains acc.1 ref then acc else (ref :: acc.1, item :: acc.2)) ([], [])).2.reverse

def sortedTerms (xs : List Term) : List Term :=
  match sorted xs [] with | .ok (ys, _) => ys | _ => xs

def consultedRevisions (effect facts : Term) (sources : List Term) : Term :=
  let labels := f effect "destination" :: sources.map (fun s => f s "label")
  list (sortedTerms ((uniq (labels.flatMap atoms)).filterMap (fun atom =>
    let rev := revision facts atom
    if rev == nil then none else some (.tuple [atom, rev]))))

end VerifiedKernel.IFC
