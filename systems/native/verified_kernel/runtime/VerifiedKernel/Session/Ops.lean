import VerifiedKernel.Data

/-!
Operations over a resident Session state.

An operation reads the state and some arguments and produces a data result.
Two kinds exist:

* a `query` returns derived data and leaves the resident state unchanged;
* a `lifecycle` operation returns the next resident state.

Both may ask the host for configuration or the clock through `observe`, so
both run under the same continuation protocol as event reduction: the
response is `{:observe, request, token}` and the host resumes with the
observation. The token carries the state, which `Session.detach` keeps
resident on the way out and `Session.attach` restores on the way in.
-/

namespace VerifiedKernel.Session
open Data

/-- `state → args → result`. -/
abbrev Op := Term → Term → KernelM Term

/-- Operation registries are association lists from name to operation. -/
abbrev OpTable := List (String × Op)

def lookupOp (table : OpTable) (name : Term) : Option Op :=
  match name with
  | .atom s => (table.find? (fun entry => entry.1 == s)).map Prod.snd
  | .binary raw => match String.fromUTF8? raw with
    | some s => (table.find? (fun entry => entry.1 == s)).map Prod.snd
    | none => none
  | _ => none

private def raisedTerm (reason : Term) : Term := .tuple [a "raised", reason]

/-- Runs `op` with the recorded observations. A finished query answers
`{:value, result}`; a finished lifecycle operation answers `{:done, next}`.
A pending observation answers `{:observe, request, {:op, kind, state, name, args, observations}}`. -/
def runOp (kind name args : Term) (op : Op) (state : Term) (observations : List Term) : Term :=
  match op state args observations with
  | .ok (result, rest) =>
    if !settled rest then raisedTerm (.tuple [a "invalid_observation", list []])
    else if kind == a "lifecycle" then .tuple [a "done", result] else .tuple [a "value", result]
  | .error (.observe request) =>
    .tuple [a "observe", request, .tuple [a "op", kind, state, name, args, list observations]]
  | .error (.raised reason) => raisedTerm reason

/-- Elixir `x || default`. -/
def orElse (value fallback : Term) : Term := value.default fallback

/-- The integer of `value`, else `fallback`. -/
def intOr (value : Term) (fallback : Int) : Int :=
  if value.isInteger then integerValue value else fallback

def isTrue (value : Term) : Bool := value == a "true"

/-- A Lean `Option Term` as an Elixir value or `nil`. -/
def optional : Option Term → Term
  | some value => value
  | none => nil

end VerifiedKernel.Session
