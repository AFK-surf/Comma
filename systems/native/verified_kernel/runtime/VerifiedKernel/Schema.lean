import VerifiedKernel.Term

namespace VerifiedKernel.Schema

/-- Session data includes the State envelope and MapSet's data representation.
Other struct tags and runtime identities are outside the contract. -/
def admissibleFuel : Nat → Bool → Term → Bool
  | 0, _, _ => false
  | fuel + 1, root, value =>
    match value with
    | .map entries =>
      let tag := value.get (.atom "__struct__")
      let allowed := !value.has (.atom "__struct__") ||
        (root && tag == .atom "Elixir.SalixAgent.InternalSession.State") ||
        (tag == .atom "Elixir.MapSet" && entries.length == 2 &&
          match value.get (.atom "map") with
          | .map members => members.all (fun pair => pair.2 == .list [])
          | _ => false)
      allowed && entries.all (fun pair => admissibleFuel fuel false pair.1 && admissibleFuel fuel false pair.2)
    | .list xs | .tuple xs => xs.all (admissibleFuel fuel false)
    | .improper xs tail => xs.all (admissibleFuel fuel false) && admissibleFuel fuel false tail
    | _ => true

def admissible (value : Term) (stateEnvelope : Bool := false) : Bool :=
  admissibleFuel (value.depth + 1) stateEnvelope value

end VerifiedKernel.Schema
