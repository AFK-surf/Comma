import VerifiedKernel.Data

/-! Facts that a private tool failure keeps after visible-reply repair.

Repair removes a private diagnostic's text from model context. The model must
still know that the call failed, whether its effect may have happened, and
whether it may repeat the call. Each retained value comes from this closed
table or is a bounded identifier. No provider or tool text passes through.

To retain a new fact, return a stable `error_class` and add it here. -/

namespace VerifiedKernel.Session.FailureOutcome
open Data

/-- `effect`: `not_applied` (the effect did not happen) or `unknown` (it may
have happened). `retry`: `forbidden` (do not repeat the call), `after_change`
(do not repeat it unchanged) or `after_delay` (wait before repeating it). -/
def table : List (String × Option String × Option String) := [
  ("voice_call_ended", some "not_applied", some "forbidden"),
  ("voice_outcome_unknown", some "unknown", some "forbidden"),
  ("imessage_delivery_unknown", some "unknown", some "forbidden"),
  ("delivery_outcome_unknown", some "unknown", some "forbidden"),
  ("provider_timeout", some "unknown", none),
  ("timeout", some "unknown", none),
  ("crashed", some "unknown", none),
  ("rate_limited", some "not_applied", some "after_delay"),
  ("signal_rate_limited", some "not_applied", some "after_delay"),
  ("signal_forbidden", some "not_applied", some "forbidden"),
  ("signal_recipient_unregistered", some "not_applied", some "forbidden"),
  ("signal_group_unavailable", some "not_applied", some "forbidden"),
  ("signal_challenge_required", some "not_applied", some "forbidden")]

private def tokenChar (dots : Bool) (c : Char) : Bool :=
  (c ≥ 'a' && c ≤ 'z') || (c ≥ '0' && c ≤ '9') || c == '_' || (dots && c == '.')

/-- A lowercase identifier of at most `limit` bytes, or `none`. Identifiers
cannot carry prose, so they may survive redaction. -/
def token? (value : Term) (limit : Nat := 64) (dots : Bool := false) : Option String :=
  match value with
  | .binary raw =>
    if raw.size == 0 || raw.size > limit then none else
    match String.fromUTF8? raw with
    | some text =>
      match text.toList with
      | first :: _ => if first ≥ 'a' && first ≤ 'z' && text.all (tokenChar dots) then some text else none
      | [] => none
    | none => none
  | _ => none

private def effectNote : String → String
  | "not_applied" => "The effect did not happen."
  | _ => "The effect may have happened. Check its state before you repeat it."

private def retryNote : String → String
  | "forbidden" => "Do not repeat this call."
  | "after_delay" => "Wait before you repeat this call."
  | _ => "Do not repeat this call unchanged."

/-- The retained record of one failure. `errorClass` and `reason` are raw
fields; only valid identifiers survive. A guidance refusal happens before the
tool runs, so its effect did not happen. -/
def record (errorClass reason kind : Term) (guidance : Bool) : Term :=
  let errorClass := token? errorClass
  let reason := token? reason
  let kind := token? kind
  let known := errorClass.bind (fun code => (table.find? (·.1 == code)).map (·.2))
  let (effect, retry) := match known with
    | some facts => facts
    | none => if guidance then (some "not_applied", some "after_change") else (none, none)
  let note := String.intercalate " " ((effect.map effectNote).toList ++ (retry.map retryNote).toList)
  let entries : List (Term × Term) :=
    [(b "status", b "failed")] ++
    (kind.map (fun v => (b "type", b v))).toList ++
    (errorClass.map (fun v => (b "error_class", b v))).toList ++
    (reason.map (fun v => (b "reason", b v))).toList ++
    (effect.map (fun v => (b "effect", b v))).toList ++
    (retry.map (fun v => (b "retry", b v))).toList ++
    (if note.isEmpty then [] else [(b "note", b note)]) ++
    [(b "detail", b "redacted")]
  .map entries

end VerifiedKernel.Session.FailureOutcome
