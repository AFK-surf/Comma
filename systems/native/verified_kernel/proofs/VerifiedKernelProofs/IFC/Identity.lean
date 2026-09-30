import VerifiedKernelProofs.Order
import VerifiedKernel.IFC.Data

namespace VerifiedKernel.IFC.Identity
open Data

theorem bytes_eq {x y : ByteArray} (h : (x == y) = true) : x = y := by
  apply ByteArray.ext
  exact eq_of_beq h

inductive Scalar where
  | atom (name : String)
  | binary (bytes : ByteArray)
  deriving DecidableEq

inductive Key where
  | scalar (value : Scalar)
  | tuple (values : List Scalar)
  | invalid
  deriving DecidableEq

def scalar : Term → Option Scalar
  | .atom name => some (.atom name)
  | .binary bytes => some (.binary bytes)
  | _ => none

/-- IFC refs, atoms, and resolved principals have scalar or flat-tuple
identities. Unsupported wire values do not acquire a valid identity. -/
def key : Term → Key
  | .atom name => .scalar (.atom name)
  | .binary bytes => .scalar (.binary bytes)
  | .tuple xs => match xs.mapM scalar with
      | some ys => .tuple ys
      | none => .invalid
  | _ => .invalid

theorem exact_scalar_eq (h : Term.exactFuel fuel x y = true) : scalar x = scalar y := by
  cases fuel with
  | zero => simp [Term.exactFuel] at h
  | succ fuel =>
    cases x <;> cases y <;> simp_all [Term.exactFuel, scalar]
    exact bytes_eq h

theorem scalar_lists_eq {xs ys : List Term} (lengths : xs.length = ys.length)
    (equal : (xs.zip ys).all (fun pair => Term.exactFuel fuel pair.1 pair.2) = true) :
    xs.mapM scalar = ys.mapM scalar := by
  induction xs generalizing ys with
  | nil =>
    have empty : ys = [] := by simpa using lengths.symm
    subst ys
    rfl
  | cons x xs ih =>
    cases ys with
    | nil => simp at lengths
    | cons y ys =>
      have lengths' : xs.length = ys.length := by simpa using lengths
      have both : Term.exactFuel fuel x y = true ∧
          (xs.zip ys).all (fun pair => Term.exactFuel fuel pair.1 pair.2) = true := by
        simpa using equal
      simp only [List.mapM_cons, exact_scalar_eq both.1, ih lengths' both.2]

theorem exact_tuple_eq (h : Term.exactFuel fuel (.tuple xs) (.tuple ys) = true) :
    xs.mapM scalar = ys.mapM scalar := by
  cases fuel with
  | zero => simp [Term.exactFuel] at h
  | succ fuel =>
    have both : xs.length = ys.length ∧
        (xs.zip ys).all (fun pair => Term.exactFuel fuel pair.1 pair.2) = true := by
      simpa [Term.exactFuel] using h
    exact scalar_lists_eq both.1 both.2

theorem key_eq (h : (x == y) = true) : key x = key y := by
  cases x <;> cases y <;> try { simp_all [key, BEq.beq] }
  · congr 2
    exact bytes_eq h
  · rename_i xs ys
    have hexact : Term.exactFuel (max (Term.tuple xs).depth (Term.tuple ys).depth)
        (.tuple xs) (.tuple ys) = true := (Bool.and_eq_true_iff.mp h).2
    simp only [key, exact_tuple_eq hexact]

theorem scalar_key_injective (hx : scalar x = some sx) (hy : scalar y = some sy)
    (h : key x = key y) : x = y := by
  cases x <;> cases y <;> simp only [scalar, Option.some.injEq, reduceCtorEq] at hx hy
    <;> try contradiction
  all_goals simp only [key, Key.scalar.injEq, Scalar.atom.injEq,
    Scalar.binary.injEq, reduceCtorEq] at h
  all_goals first | contradiction | exact congrArg _ h

def Scalar.wire : Scalar → Term
  | .atom name => .atom name
  | .binary bytes => .binary bytes

def Key.wire : Key → Term
  | .scalar value => value.wire
  | .tuple values => .tuple (values.map Scalar.wire)
  | .invalid => .atom "nil"

theorem scalar_restore (h : scalar x = some s) : s.wire = x := by
  cases x <;> simp [scalar] at h
  all_goals subst s; rfl

theorem scalars_restore {xs : List Term} (h : xs.mapM scalar = some ss) :
    ss.map Scalar.wire = xs := by
  induction xs generalizing ss with
  | nil => simpa using h.symm
  | cons x xs ih =>
    cases hs : scalar x with
    | none => simp [List.mapM_cons, hs] at h
    | some s =>
      cases hss : xs.mapM scalar with
      | none => simp [List.mapM_cons, hs, hss] at h
      | some ss' =>
        have heq : s :: ss' = ss := by simpa [List.mapM_cons, hs, hss] using h
        subst ss
        simp only [List.map_cons, scalar_restore hs, ih hss]

theorem key_restore (h : key x ≠ .invalid) : (key x).wire = x := by
  cases x with
  | atom name => rfl
  | binary bytes => rfl
  | tuple xs =>
    cases heq : xs.mapM scalar with
    | some ss => simp only [key, heq, Key.wire, scalars_restore heq]
    | none => simp [key, heq] at h
  | _ => exact False.elim (h rfl)

theorem key_injective (hx : key x ≠ .invalid) (hy : key y ≠ .invalid)
    (h : key x = key y) : x = y := by
  rw [← key_restore hx, ← key_restore hy, h]

theorem scalar_wire_exact (s : Scalar) : Term.exactFuel (n + 1) s.wire s.wire = true := by
  cases s with
  | atom name => simp [Scalar.wire, Term.exactFuel]
  | binary bytes => change (bytes.data == bytes.data) = true; exact beq_self_eq_true _

theorem scalar_wire_depth (s : Scalar) : s.wire.depth = 1 := by
  cases s <;> simp [Scalar.wire, Term.depth]

theorem tuple_wire_exact (ss : List Scalar) :
    Term.exactFuel (n + 2) (.tuple (ss.map Scalar.wire)) (.tuple (ss.map Scalar.wire)) = true := by
  change ((_ == _) && _) = true
  simp only [beq_self_eq_true, Bool.true_and]
  induction ss with
  | nil => rfl
  | cons s ss ih =>
    simp only [List.map_cons, List.zip_cons_cons, List.all_cons,
      scalar_wire_exact, Bool.true_and]
    exact ih

theorem key_wire_beq (k : Key) : (k.wire == k.wire) = true := by
  cases k with
  | invalid => rfl
  | scalar s =>
    cases s with
    | atom name => change (name == name) = true; exact beq_self_eq_true _
    | binary bytes => change (bytes.data == bytes.data) = true; exact beq_self_eq_true _
  | tuple ss =>
    cases ss with
    | nil => simp [Key.wire, BEq.beq, Term.exactFuel, Term.depth]
    | cons s ss =>
      have positive : 2 ≤ (Term.tuple ((s :: ss).map Scalar.wire)).depth := by
        simp only [Term.depth, List.map_cons, scalar_wire_depth, List.foldl_cons]
        have bound : ∀ (xs : List Nat) (n : Nat), n ≤ xs.foldl max n := by
          intro xs
          induction xs with
          | nil => simp
          | cons x xs ih => intro n; exact Nat.le_trans (Nat.le_max_left n x) (ih _)
        have := bound (ss.map Scalar.wire |>.map Term.depth) 1
        change 2 ≤ 1 + (ss.map Scalar.wire |>.map Term.depth).foldl max 1
        omega
      change ((_ == _) && Term.exactFuel _ _ _) = true
      simp only [beq_self_eq_true, Bool.true_and, Nat.max_self]
      simp only [Key.wire]
      obtain ⟨n, heq⟩ := Nat.exists_eq_add_of_le positive
      rw [heq, Nat.add_comm]
      exact tuple_wire_exact _

theorem beq_of_key_eq (hx : key x ≠ .invalid) (hy : key y ≠ .invalid)
    (h : key x = key y) : (x == y) = true := by
  rw [← key_restore hx, ← key_restore hy, h]
  exact key_wire_beq _

theorem atom_key_valid (valid : atomValid x = true) : key x ≠ .invalid := by
  unfold atomValid at valid
  split at valid <;> simp_all [key, scalar]

theorem binary_key_valid (valid : x.isBinary = true) : key x ≠ .invalid := by
  cases x <;> simp_all [Term.isBinary, key]

theorem authority_key_valid_fuel (valid : principalValidFuel fuel p = true) :
    key (authorityFuel fuel p) ≠ .invalid := by
  induction fuel generalizing p with
  | zero => simp [principalValidFuel] at valid
  | succ fuel ih =>
    unfold principalValidFuel at valid
    split at valid
    all_goals first
      | exact ih valid
      | simpa only [authorityFuel] using ih valid
      | simp_all [authorityFuel, key, scalar]

theorem authority_key_valid (valid : principalValid p = true) : key (authority p) ≠ .invalid :=
  authority_key_valid_fuel valid

end VerifiedKernel.IFC.Identity
