import Lean
import Lean.Compiler.IR
import Lean.Compiler.LCNF.PhaseExt
import Lean.Compiler.ExportAttr

/-!
Export the pinned compiler's final IR and erased monomorphic type information.
The Python checker uses these facts for closure flow and recursion bounds.
-/

open Lean

def arg (a : IR.Arg) : Json := match a with
  | .var v => toJson v.idx
  | .erased => Json.null

def vars (a : Array IR.Arg) : Json := toJson (a.map arg)

def expr (value : IR.Expr) : Json :=
  match value with
  | .fap n args => Json.mkObj [("op", toJson "call"), ("target", toJson n.toString), ("args", vars args)]
  | .pap n args => Json.mkObj [("op", toJson "closure"), ("target", toJson n.toString), ("args", vars args)]
  | .ap f args => Json.mkObj [("op", toJson "apply"), ("fn", toJson f.idx), ("args", vars args)]
  | .ctor info args | .reuse _ info _ args =>
    Json.mkObj [("op", toJson "ctor"), ("ctor", toJson info.name.toString), ("args", vars args)]
  | .proj i x => Json.mkObj [("op", toJson "proj"), ("index", toJson i), ("object", toJson x.idx)]
  | .box _ x | .unbox x => Json.mkObj [("op", toJson "copy"), ("value", toJson x.idx)]
  | .lit (.num n) => Json.mkObj [("op", toJson "number"), ("value", toJson n)]
  | .lit (.str s) => Json.mkObj [("op", toJson "string"), ("value", toJson s)]
  | .reset .. | .uproj .. | .sproj .. | .isShared .. => Json.mkObj [("op", toJson "scalar")]

partial def body (owner : Name) (b : IR.FnBody) (found : Array Json := #[]) (guards : Array Json := #[]) : Array Json :=
  match b with
  | .vdecl result _ value next =>
    let loop := match value, next with
      | .fap n _, .ret (.var r) => n == owner && r == result
      | _, _ => false
    let item := Json.mkObj [("let", toJson result.idx), ("value", expr value), ("loop", toJson loop), ("guards", toJson guards)]
    body owner next (found.push item) guards
  | .jdecl j ps value next =>
    let item := Json.mkObj [("join", toJson j.idx), ("params", toJson (ps.map (·.x.idx)))]
    body owner next (body owner value (found.push item) guards) guards
  | .case _ discr _ alts => alts.foldl (fun found alt =>
    let nextGuards := match alt with
      | .ctor info _ => guards.push (toJson (discr.idx, info.name.toString))
      | .default _ => guards
    body owner alt.body found nextGuards) found
  | .set obj i value next =>
    body owner next (found.push <| Json.mkObj [("set", toJson obj.idx), ("index", toJson i), ("value", arg value)]) guards
  | .ret value => found.push (Json.mkObj [("return", arg value)])
  | .jmp j args => found.push (Json.mkObj [("jump", toJson j.idx), ("args", vars args)])
  | .unreachable => found
  | .uset .. | .sset .. | .setTag .. | .inc .. | .dec .. | .del .. => body owner b.body found guards

def callees (items : Array Json) : List Name := Id.run do
  let mut names := []
  for item in items do
    if let .ok value := item.getObjVal? "value" then
      if let .ok name := value.getObjValAs? String "target" then names := name.toName :: names
  return names


open Lean.Compiler.LCNF

abbrev Masks := NameMap (Array Bool)

partial def closureType (env : Environment) (masks : Masks) (type : Expr) (seen : List Expr := []) (fuel : Nat := 100) : Bool := Id.run do
  if fuel == 0 then return true
  let type := type.consumeMData
  if seen.contains type then return false
  let seen := type :: seen
  if type.isForall then return true
  let .const name levels := type.getAppFn | return true
  let args := type.getAppArgs
  match env.find? name with
  | some (.defnInfo info) =>
    return closureType env masks ((mkAppN (info.value.instantiateLevelParams info.levelParams levels) args).headBeta) seen (fuel - 1)
  | some (.inductInfo info) =>
    if args.size < info.numParams then return true
    for ctor in info.ctors do
      let some (.ctorInfo ci) := env.find? ctor | return true
      let mut ct := ci.type.instantiateLevelParams ci.levelParams levels
      for i in [:info.numParams] do
        let .forallE _ _ body _ := ct | return true
        ct := body.instantiate1 args[i]!
      let mut fieldIndex := info.numParams
      while ct.isForall do
        let .forallE _ field body _ := ct | break
        let erased := ((masks.find? ctor).getD #[])[fieldIndex]?.getD false
        fieldIndex := fieldIndex + 1
        if !erased && closureType env masks field seen (fuel - 1) then return true
        ct := body.instantiate1 (mkConst `lcAny)
    return false
  | _ => return true

def closureSignature (env : Environment) (masks : Masks) (n : Name) (arity : Nat) : Json × Json := Id.run do
  let some decl := getDeclCore? env monoExt n | return (toJson (Array.replicate arity true), toJson true)
  if decl.params.size != arity then return (toJson (Array.replicate arity true), toJson true)
  let mut result := decl.type
  for _ in [:arity] do
    let .forallE _ _ body _ := result | return (toJson (Array.replicate arity true), toJson true)
    result := body.instantiate1 (mkConst `lcAny)
  return (toJson (decl.params.map (fun p => closureType env masks p.type)), toJson (closureType env masks result))

def main (args : List String) : IO UInt32 := do
  let (moduleName, modulePrefix, only) ← match args with
    | [] => pure (`VerifiedKernel.Native, `VerifiedKernel, none)
    | ["--module", m, "--prefix", p] => pure (m.toName, p.toName, none)
    | ["--module", m, "--prefix", p, "--entry", entry] => pure (m.toName, p.toName, some entry.toName)
    | _ => IO.eprintln "Usage: recursion-ir.lean [--module MODULE --prefix PREFIX [--entry EXPORT]]"; return 2
  if Lean.versionString != "4.33.1" then
    IO.eprintln "The recursion checker supports Lean 4.33.1. Review its IR and tail-call rules before upgrading."
    return 2
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := moduleName, importAll := true, isMeta := true }] {}
  let task : MetaM Masks := do
    let mut masks : Masks := {}
    for (n, info) in env.constants.toList do
      if let .ctorInfo _ := info then
        let mask ← Meta.forallTelescope info.type fun xs _ => xs.mapM fun x => do
          Meta.isProp (← Meta.inferType x)
        masks := masks.insert n mask
    return masks
  let (masks, _, _) ← task.toIO {fileName := "audit", fileMap := default} {env := env}
  let mut roots : NameSet := {}
  for idx in [:env.header.moduleNames.size] do
    if !modulePrefix.isPrefixOf env.header.moduleNames[idx]! then continue
    -- Erased-type filtering requires the source type discipline. Standard
    -- library implementations remain part of the pinned compiler contract.
    for n in env.header.moduleData[idx]!.constNames do
      if (env.find? n).any ConstantInfo.isUnsafe then
        IO.eprintln s!"Unsafe definition {n} prevents erased-type closure analysis in {modulePrefix}."
        return 2
    for decl in IR.declMapExt.getModuleIREntries env idx do
      if (getExportNameFor? env decl.name).isSome then roots := roots.insert decl.name
    for decl in IR.declMapExt.getModuleEntries env idx do
      if (getExportNameFor? env decl.name).isSome then roots := roots.insert decl.name
  if let some entry := only then
    if !roots.contains entry then
      IO.eprintln s!"{entry} is not an export in {modulePrefix}."
      return 2
    roots := NameSet.ofList [entry]
  if roots.isEmpty then
    IO.eprintln s!"No compiled exports found in {modulePrefix}. Build {moduleName} first."
    return 2
  let mut seen : NameSet := {}
  let mut pending := roots.toList
  let mut decls := #[]
  while !pending.isEmpty do
    let n := pending.head!
    pending := pending.tail!
    if seen.contains n then continue
    seen := seen.insert n
    let some decl := IR.findEnvDecl env n | IO.eprintln s!"Missing compiled IR for {n}."; return 2
    let items := match decl with | .fdecl _ _ _ b _ => body n b | _ => #[]
    pending := callees items ++ pending
    let (pc, rc) := closureSignature env masks n decl.params.size
    let natParams : Array Bool := match getDeclCore? env monoExt n with
      | some d => if d.params.size == decl.params.size then d.params.map (fun p => p.type.isConstOf ``Nat) else Array.replicate decl.params.size false
      | none => Array.replicate decl.params.size false
    let generic := match getDeclCore? env monoExt n with
      | some d => d.type.getUsedConstants.contains `lcAny || d.params.any (fun p => p.type.getUsedConstants.contains `lcAny)
      | none => true
    decls := decls.push (Json.mkObj [("name", toJson n.toString),
      ("generic", toJson generic), ("nat_params", toJson natParams), ("params", toJson (decl.params.map (·.x.idx))), ("closure_params", pc), ("closure_return", rc),
      ("external", toJson (decl.isExtern && isExtern env n)), ("missing", toJson (decl.isExtern && !isExtern env n)), ("body", toJson items)])
  IO.println (Json.mkObj [("compiler", toJson Lean.versionString), ("module", toJson moduleName.toString), ("roots", toJson (roots.toList.map Name.toString)), ("decls", toJson decls)]).compress

  return 0
