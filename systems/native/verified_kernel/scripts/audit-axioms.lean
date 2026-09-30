import Lean

/-!
Checks every declaration in every module under `runtime/` and `proofs/`.
The script finds the modules from the source tree, so no list of theorems or modules
needs maintenance. A declaration passes only if its transitive axioms are Lean's
standard axioms. `sorry` and `admit` use `sorryAx`, `native_decide` adds an auxiliary
axiom, and each `axiom` command adds its own axiom, so all of them fail.

Run from the package root after `lake build`: `lake env lean --run scripts/audit-axioms.lean`.
-/

open Lean

def standardAxioms : NameSet :=
  .ofList [``propext, ``Classical.choice, ``Quot.sound]

def sourceRoots : List System.FilePath := ["runtime", "proofs"]

def moduleName (root file : System.FilePath) : Name :=
  let parts := (file.withExtension "").components.drop root.components.length
  parts.foldl Name.mkStr .anonymous

def sourceModules : IO (Array Name) := do
  let mut modules := #[]
  for root in sourceRoots do
    for file in ← root.walkDir do
      if file.extension == some "lean" then
        modules := modules.push (moduleName root file)
  return modules.qsort Name.lt

/-- Axioms that each visited constant reaches. One cache serves all declarations. -/
abbrev AxiomM := ReaderT Environment (StateM (NameMap NameSet))

/-- The same traversal as `Lean.collectAxioms`, with a cache that persists across calls. -/
partial def axiomsOf (c : Name) : AxiomM NameSet := do
  if let some axioms := (← get).find? c then
    return axioms
  -- An inductive type and its constructors refer to each other.
  modify (·.insert c {})
  let refs (e : Expr) := e.getUsedConstants
  let (own, deps) := match (← read).find? c with
    | some (.axiomInfo v) => ([c], refs v.type)
    | some (.defnInfo v) => ([], refs v.type ++ refs v.value)
    | some (.thmInfo v) => ([], refs v.type ++ refs v.value)
    | some (.opaqueInfo v) => ([], refs v.type ++ refs v.value)
    | some (.ctorInfo v) => ([], refs v.type)
    | some (.recInfo v) => ([], refs v.type)
    | some (.inductInfo v) => ([], refs v.type ++ v.ctors.toArray)
    | some (.quotInfo _) | none => ([], #[])
  let mut axioms := NameSet.ofList own
  for dep in deps do
    for ax in ← axiomsOf dep do
      axioms := axioms.insert ax
  modify (·.insert c axioms)
  return axioms

def main : IO UInt32 := do
  let modules ← sourceModules
  if modules.isEmpty then
    IO.eprintln "No Lean modules were found. Run this script from the package root."
    return 1
  initSearchPath (← findSysroot)
  let env ← importModules (modules.map ({ module := · })) {}
  let mut checked := 0
  let mut failures := #[]
  let mut cache := {}
  for module in modules do
    let some idx := env.getModuleIdx? module
      | IO.eprintln s!"{module} was not imported."
        return 1
    for name in env.header.moduleData[idx.toNat]!.constNames do
      checked := checked + 1
      let (axioms, next) := (axiomsOf name |>.run env).run cache
      cache := next
      let rejected := axioms.toArray.filter (!standardAxioms.contains ·)
      unless rejected.isEmpty do
        failures := failures.push (module, name, rejected)
  let byModule := fun (a b : Name × Name × Array Name) =>
    Name.lt a.1 b.1 || (a.1 == b.1 && Name.lt a.2.1 b.2.1)
  for (module, name, rejected) in failures.qsort byModule do
    IO.eprintln s!"{module}: {name} depends on {rejected.toList}"
  if failures.isEmpty then
    IO.println s!"Checked {checked} declarations in {modules.size} modules. \
      All use only {standardAxioms.toList}."
    return 0
  IO.eprintln s!"{failures.size} of {checked} declarations depend on a non-standard axiom."
  return 1
