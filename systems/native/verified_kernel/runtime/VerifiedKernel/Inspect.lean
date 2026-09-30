import VerifiedKernel.Json

namespace VerifiedKernel.Inspect
open Data

private def printable (char : Char) : Bool :=
  let n := char.toNat
  (n ≥ 32 && n != 127 && !(128 ≤ n && n ≤ 159)) || [7, 8, 9, 10, 11, 12, 13, 27].contains n

private def escaped (text : String) : String :=
  (String.join (text.toList.map (fun c => match c with
    | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\r' => "\\r" | '\t' => "\\t"
    | '\x07' => "\\a" | '\x08' => "\\b" | '\x0b' => "\\v" | '\x0c' => "\\f" | '\x1b' => "\\e"
    | _ => String.singleton c))).replace "#{" "\\#{"

private def identifier (name : String) : Bool :=
  let chars := name.toList
  match chars with
  | [] => false
  | first :: rest =>
    (('a' ≤ first && first ≤ 'z') || first == '_') &&
      rest.all (fun c => c.isAlphanum || c == '_' || c == '@' || c == '?' || c == '!')

def atomText (name : String) : String :=
  if ["nil", "true", "false"].contains name then name
  else if name.startsWith "Elixir." then String.ofList (name.toList.drop 7)
  else if identifier name then ":" ++ name
  else ":\"" ++ escaped name ++ "\""

/-- The module of an Elixir struct: an `Elixir.` atom. -/
private def structName : Term → Option String
  | .atom name => if name.startsWith "Elixir." then some name else none
  | _ => none

private def grouped (left right : String) (values : List String) : String :=
  left ++ String.intercalate ", " values ++ right

private def renderFuel : Nat → Nat → Nat → Term → String
  | 0, _, _, _ => "..."
  | fuel + 1, limit, printableLimit, value =>
    let render := renderFuel fuel limit printableLimit
    let items := fun (xs : List Term) =>
      (xs.take limit).map render ++ if xs.length > limit then ["..."] else []
    match value with
    | .integer n => toString n
    | .floatBits bits => Number.floatText bits true
    | .atom name => atomText name
    | .binary raw =>
      match String.fromUTF8? raw with
      | some text =>
        if text.toList.all printable then
          let chars := text.toList
          "\"" ++ escaped (String.ofList (chars.take printableLimit)) ++ "\"" ++
            (if chars.length > printableLimit then " <> ..." else "")
        else grouped "<<" ">>" (items (raw.toList.map (fun byte => i byte.toNat)))
      | none => grouped "<<" ">>" (items (raw.toList.map (fun byte => i byte.toNat)))
    | .bitstring raw lastBits =>
      let bytes := raw.toList
      let full := bytes.take (bytes.length - 1)
      let tail := (bytes.getLast?.getD 0).toNat / 2^(8 - lastBits.toNat)
      grouped "<<" ">>" (full.map (fun byte => toString byte.toNat) ++ [toString tail ++ "::size(" ++ toString lastBits.toNat ++ ")"])
    | .tuple xs => grouped "{" "}" (items xs)
    | .list [] => "[]"
    | .list xs =>
      let chars := xs.filterMap (fun x => match x with
        | .integer n => if n ≥ 0 && n ≤ 0x10FFFF then some (Char.ofNat n.toNat) else none
        | _ => none)
      if chars.length == xs.length && chars.all printable then
        "~c\"" ++ escaped (String.ofList (chars.take printableLimit)) ++ "\""
      else
        let keyword := xs.all (fun x => match x with | .tuple [.atom _, _] => true | _ => false)
        if keyword then
          let entries := (xs.take limit).map (fun x => match x with
            | .tuple [.atom key, value] => (if identifier key then key else "\"" ++ escaped key ++ "\"") ++ ": " ++ render value
            | _ => "...")
          grouped "[" "]" (entries ++ if xs.length > limit then ["..."] else [])
        else grouped "[" "]" (items xs)
    | .improper xs tail => "[" ++ String.intercalate ", " (items xs) ++ " | " ++ render tail ++ "]"
    | .map xs =>
      if value.get (a "__struct__") == a "Elixir.MapSet" then
        let members := match value.get (a "map") with | .map pairs => pairs.map Prod.fst | _ => []
        "MapSet.new(" ++ grouped "[" "]" (items members) ++ ")"
      else if let some module := structName (value.get (a "__struct__")) then
        -- A struct renders by its module name, without its struct and
        -- exception markers. Field order is the map's order.
        let fields := xs.filter (fun pair => pair.1 != a "__struct__" &&
          !(pair.1 == a "__exception__" && pair.2 == a "true"))
        let entries := (fields.take limit).map (fun pair =>
          let key := match pair.1 with | .atom name => name | _ => ""
          (if identifier key then key else "\"" ++ escaped key ++ "\"") ++ ": " ++ render pair.2)
        "%" ++ atomText module ++ grouped "{" "}" (entries ++ if fields.length > limit then ["..."] else [])
      else
        let keyword := xs.all (fun pair => match pair.1 with | .atom _ => true | _ => false)
        let entries := (xs.take limit).map (fun pair =>
          if keyword then
            let key := match pair.1 with | .atom name => name | _ => ""
            (if identifier key then key else "\"" ++ escaped key ++ "\"") ++ ": " ++ render pair.2
          else render pair.1 ++ " => " ++ render pair.2)
        grouped "%{" "}" (entries ++ if xs.length > limit then ["..."] else [])

def render (value : Term) (limit : Nat := 50) (printableLimit : Nat := 4096) : String :=
  renderFuel (value.depth + 1) limit printableLimit value

end VerifiedKernel.Inspect
