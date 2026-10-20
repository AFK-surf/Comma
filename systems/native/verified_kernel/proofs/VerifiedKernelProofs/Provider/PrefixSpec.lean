import VerifiedKernelProofs.Provider.Eval

/-!
The vocabulary of the provider-request prefix theorems.

A provider caches a request prefix: the request head (system text or instructions, and tools),
then a prefix of the message array. `headOf` and `messagesOf` select those parts of a request
body. Anthropic cache markers do not take part in prefix matching, and a string content is the
same prompt as one text block with that text, so `eraseMessage` removes both differences.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- An Anthropic content block without its cache marker. -/
def eraseBlock (v : Term) : Term := removeKey v (b "cache_control")

/-- Anthropic content without cache markers; one text block reads as its text. -/
def eraseContent (content : Term) : Term :=
  match content with
  | .list [block] =>
    let block := eraseBlock block
    if (get block "type" == b "text" && removeKey (removeKey block (b "type")) (b "text") == Term.map []) = true
    then get block "text" else list [block]
  | .list blocks => list (blocks.map eraseBlock)
  | other => other

/-- An Anthropic message without cache markers. -/
def eraseMessage (m : Term) : Term :=
  if m.has (b "content") then m.put (b "content") (eraseContent (get m "content")) else m

/-- The request part that a provider caches before the message array. Chat sends its system
text as the first message, so its head holds only the tools. -/
def headOf (protocol : String) (body : Term) : Term :=
  if protocol = "anthropic" then
    .tuple [eraseContent (get body "system"), list ((items (get body "tools")).map eraseBlock)]
  else if protocol = "responses" then .tuple [get body "instructions", get body "tools"]
  else get body "tools"

/-- The message array of a request body, in the order the provider caches it. -/
def messagesOf (protocol : String) (body : Term) : List Term :=
  if protocol = "anthropic" then (items (get body "messages")).map eraseMessage
  else if protocol = "responses" then items (get body "input")
  else items (get body "messages")

end VerifiedKernel.ProviderLoop
