import VerifiedKernel.Session.Attachments
import VerifiedKernel.Session.Queue
import VerifiedKernel.Grapheme

namespace VerifiedKernel.Session.RequestPage
open Data Provider

private def resized (message envelope page : Term) (text : String) (chars : Nat) : KernelM Term := do
  let content := Grapheme.takeString text chars
  let next := integerValue (get page "offset") + Int.ofNat (Grapheme.countString content)
  let page := (page.put (b "content") (b content)).put (b "content_chars") (i (Int.ofNat chars))
  let page := page.put (b "truncated") (Term.bool (integerValue (get page "offset") > 0 || next < integerValue (get page "total_chars")))
  let page := if next < integerValue (get page "total_chars") then page.put (b "next_offset") (i next)
    else removeKey page (b "next_offset")
  return Attachments.putField message "content" (← encode (envelope.put (b "result_page") page))

private def pageKey : ByteArray := "result_page".toUTF8
private def escapeMark : ByteArray := "\\u".toUTF8

def fit (annotate : Term → KernelM Term) (message : Term) : KernelM Term := do
  if Provider.field message "role" != b "runtime" then return message
  -- A JSON text holds a `result_page` key only when the key appears literally
  -- or through a `\u` escape; any other text is not a page and is not decoded.
  if let .binary raw := Provider.field message "content" then
    if !Session.containsBytes raw pageKey && !Session.containsBytes raw escapeMark then return message
  let some envelope := decode (Provider.field message "content") | return message
  let page := get envelope "result_page"
  if get envelope "tool_name" != b "tool_call.get_result" || !page.isMap then return message
  let content := get page "content"
  let offset := get page "offset"
  let total := get page "total_chars"
  if !content.isBinary || !offset.isInteger || integerValue offset < 0 ||
    !total.isInteger || integerValue total < 0 then return message
  let text := String.fromUTF8! (bytes content)
  let maximum := Grapheme.countString text
  let remaining := (integerValue total - integerValue offset).toNat
  let minimum := if remaining > 0 then 1 else 0
  if maximum < minimum || maximum > remaining then return message
  let fits := fun candidate => do
    let projected ← annotate (Attachments.dropField candidate "result_seq")
    pure ((bytes (← encode (list [projected]))).size ≤ 120000)
  if ← fits message then return message
  if !(← fits (← resized message envelope page text minimum)) then return message
  let mut low := minimum
  let mut high := maximum
  for _ in [:maximum + 1] do
    if low ≥ high then break
    let mid := (low + high + 1) / 2
    if ← fits (← resized message envelope page text mid) then low := mid else high := mid - 1
  resized message envelope page text low

end VerifiedKernel.Session.RequestPage
