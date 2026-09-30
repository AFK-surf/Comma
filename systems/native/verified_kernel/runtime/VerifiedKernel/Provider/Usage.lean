import VerifiedKernel.Provider.Common

namespace VerifiedKernel.Provider.Usage
open Data

def int (v : Term) : Int :=
  match v with
  | .integer n => n
  | .floatBits _ => match v.number with | some (n, d) => n.tdiv d | none => 0
  | .binary raw =>
    let chars := (String.fromUTF8! raw).toList
    let sign := if chars.head? == some '-' then -1 else 1
    let rest := if chars.head? == some '-' || chars.head? == some '+' then chars.tail else chars
    sign * ((String.ofList (rest.takeWhile Char.isDigit)).toInt?.getD 0)
  | _ => 0

private def count (v : Term) (k : String) : Int := int (get v k)
private def detail (v : Term) (k sub : String) : Term := get (get v k) sub
private def total (v : Term) (prompt completion : Int) : Int := if int v == 0 then prompt + completion else int v
private def summary (prompt completion read write : Int) (reportedTotal : Term := nil) : Term :=
  obj [("prompt_tokens", i prompt), ("completion_tokens", i completion), ("total_tokens", i (total reportedTotal prompt completion)),
    ("cache_read_input_tokens", i read), ("cache_write_input_tokens", i write)]

def anthropic (v : Term) : Term :=
  if !v.isMap then nil else
  let cc := get v "cache_creation"
  let write := if cc.isMap then count cc "ephemeral_5m_input_tokens" + count cc "ephemeral_1h_input_tokens" else count v "cache_creation_input_tokens"
  let read := count v "cache_read_input_tokens"
  summary (count v "input_tokens" + read + write) (count v "output_tokens") read write

private def topWrite (v : Term) : Int :=
  let top := get v "cache_creation_input_tokens"
  if top != nil then int top else
    count (get v "cache_creation") "ephemeral_5m_input_tokens" + count (get v "cache_creation") "ephemeral_1h_input_tokens"

def openai (v : Term) : Term :=
  if !v.isMap then nil else
  let topRead := count v "cache_read_input_tokens"
  let write := topWrite v
  let prompt := if count v "prompt_tokens" > 0 then count v "prompt_tokens" else
    if count v "input_tokens" > 0 || count v "uncached_input_tokens" > 0 then
      int (coalesce [get v "input_tokens", get v "uncached_input_tokens"]) + topRead + write else 0
  let read := if get v "cache_read_input_tokens" == nil then
    int (coalesce [detail v "prompt_tokens_details" "cached_tokens", detail v "input_tokens_details" "cached_tokens"]) else topRead
  let write := if write == 0 then
    int (coalesce [detail v "prompt_tokens_details" "cache_write_tokens", detail v "input_tokens_details" "cache_write_tokens"]) else write
  summary prompt (int (coalesce [get v "completion_tokens", get v "output_tokens"])) read write (get v "total_tokens")

private def gemini (v : Term) : Term :=
  if !v.isMap then nil else
  let prompt := int (coalesce [get v "promptTokenCount", get v "prompt_token_count"])
  let completion := int (coalesce [get v "candidatesTokenCount", get v "candidates_token_count"])
  let total := total (coalesce [get v "totalTokenCount", get v "total_token_count"]) prompt completion
  let read := int (coalesce [get v "cachedContentTokenCount", get v "cached_content_token_count"])
  if prompt == 0 && completion == 0 && total == 0 && read == 0 then nil else summary prompt completion read 0 (i total)

private def mergeMissing (x y : Term) : Term :=
  if x == nil then y else if y == nil then x else
    match y with | .map fields => fields.foldl (fun acc (k, v) => if int (acc.get k) == 0 then acc.put k v else acc) x | _ => x

def chat (resp : Term) : Term :=
  mergeMissing (mergeMissing (openai (get resp "usage")) (gemini (coalesce [get resp "usageMetadata", get resp "usage_metadata"])))
    (gemini (coalesce [detail resp "usage" "usageMetadata", detail resp "usage" "usage_metadata"]))

private def isNumber (v : Term) : Bool := match v with | .integer _ | .floatBits _ => true | _ => false

def responses (v : Term) : Term :=
  if !v.isMap then nil else
  let prompt := count v "input_tokens" + count v "cache_read_input_tokens" + count v "cache_creation_input_tokens"
  let read := if get v "cache_read_input_tokens" == nil then int (detail v "input_tokens_details" "cached_tokens") else count v "cache_read_input_tokens"
  let write := if get v "cache_creation_input_tokens" == nil then int (detail v "input_tokens_details" "cache_write_tokens") else count v "cache_creation_input_tokens"
  let reasoning := detail v "output_tokens_details" "reasoning_tokens"
  let reasoning := match reasoning with | .integer n => if n ≥ 0 then reasoning else nil | _ => nil
  mergeMaps (summary prompt (count v "output_tokens") read write (get v "total_tokens"))
    (obj [("usage_reported", a "true"), ("prompt_tokens_reported", Term.bool (isNumber (get v "input_tokens"))),
      ("completion_tokens_reported", Term.bool (isNumber (get v "output_tokens"))),
      ("cache_read_tokens_reported", Term.bool (isNumber (coalesce [get v "cache_read_input_tokens", detail v "input_tokens_details" "cached_tokens"]))),
      ("reasoning_tokens", reasoning)])

def attach (result usage model : Term) : Term :=
  if usage == nil then result else
  let metadata := putOptional (obj [("usage", usage)]) "model" model
  match result with
  | .tuple [.atom "final", text] => .tuple [a "final", text, metadata]
  | .tuple [.atom "final", text, providerMeta, traceMeta] => .tuple [a "final", text, providerMeta, mergeMaps (coalesce [traceMeta, empty]) metadata]
  | .tuple [.atom "assistant", text, calls] => .tuple [a "assistant", text, calls, nil, metadata]
  | .tuple [.atom "assistant", text, calls, providerMeta] => .tuple [a "assistant", text, calls, providerMeta, metadata]
  | _ => result

end VerifiedKernel.Provider.Usage
