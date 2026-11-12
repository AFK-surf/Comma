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

private def admissibleDeferred : Nat → Bool → Term → Stackless Bool
  | 0, _, _ => .done false
  | fuel + 1, root, value => .delay fun _ =>
    match value with
    | .map entries =>
      let tag := value.get (.atom "__struct__")
      let allowed := !value.has (.atom "__struct__") ||
        (root && tag == .atom "Elixir.SalixAgent.InternalSession.State") ||
        (tag == .atom "Elixir.MapSet" && entries.length == 2 &&
          match value.get (.atom "map") with
          | .map members => members.all (fun pair => pair.2 == .list [])
          | _ => false)
      Stackless.both (.done allowed) fun _ => Stackless.allM (fun pair =>
        Stackless.both (admissibleDeferred fuel false pair.1) fun _ =>
          admissibleDeferred fuel false pair.2) entries
    | .list xs | .tuple xs => Stackless.allM (admissibleDeferred fuel false) xs
    | .improper xs tail => Stackless.both (Stackless.allM (admissibleDeferred fuel false) xs)
        fun _ => admissibleDeferred fuel false tail
    | _ => .done true

private theorem admissibleDeferred_eq (fuel : Nat) (root : Bool) (value : Term) :
    (admissibleDeferred fuel root value).run = admissibleFuel fuel root value := by
  induction fuel generalizing root value with
  | zero => rfl
  | succ fuel ih => cases value <;> simp [admissibleDeferred, Stackless.run, admissibleFuel, ih]

def admissibleFuelImpl (fuel : Nat) (root : Bool) (value : Term) : Bool :=
  (admissibleDeferred fuel root value).run

@[csimp] theorem admissibleFuel_eq_admissibleFuelImpl : @admissibleFuel = @admissibleFuelImpl := by
  funext fuel root value
  exact (admissibleDeferred_eq fuel root value).symm

def admissible (value : Term) (stateEnvelope : Bool := false) : Bool :=
  admissibleFuel (value.depth + 1) stateEnvelope value

end VerifiedKernel.Schema
