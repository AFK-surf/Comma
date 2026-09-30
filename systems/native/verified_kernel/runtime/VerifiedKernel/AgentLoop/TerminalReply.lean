import VerifiedKernel.Data

/-! Admission of one tool call against the current terminal-reply scope.

Destination authorization, IFC and disclosure checks run elsewhere. This gate
owns the channel welcome, Telegram interactive cards, and replies carried by
runtime completion decisions. Only those three attach a terminal binding; an
ordinary send passes unchanged. The host supplies the call's name, arguments,
id and reply intent, and the scope from `terminal_reply_context`. -/

namespace VerifiedKernel.AgentLoop.TerminalReply
open Data

private def onboardingTools : List Term := [b "im_api.slack.post_message", b "im_api.slack.post_channel_message"]
private def interactiveTools : List Term :=
  [b "question.request", b "permission.request", b "location.request", b "oauth.request_authorization"]

private def key (m : Term) (k : String) : Term := if m.isMap then m.get (b k) else nil

/-- Elixir `text/1`: `nil` is empty, anything else is `to_string/1`. -/
private def text (v : Term) : KernelM Term := if v == nil then pure (b "") else stringChars v

private def trimmed (v : Term) : KernelM Term := do
  match ← text v with
  | .binary raw => pure (.binary (trim raw))
  | other => pure other

private def matchingTarget (name args scope : Term) : KernelM Term := do
  let targets := key scope "targets"
  let targets := if targets.isList then targets else list []
  enumFind targets (fun target => do
    let tool := key target "tool"
    if name != tool then return false
    let params ← entries (key target "params")
    let paramsMatch ← params.allM (fun (k, expected) => do
      let .binary raw := k | return false
      let actual ← text (key args (String.fromUTF8! raw))
      return actual == expected)
    let broadcast := key args "reply_broadcast"
    let broadcasts := broadcast == a "true" || broadcast == b "true" || broadcast == i 1 || broadcast == b "1"
    let filter := key args "delivery_filter"
    return paramsMatch && !broadcasts &&
      (tool != b "im_api.internal.send_message" || filter == nil || filter == empty))

private def sourceSend (name args scope : Term) : KernelM Bool := do
  if !scope.isMap then return false
  if key scope "kind" == b "channel_onboarding" then
    return onboardingTools.contains name &&
      (← text (key args "connect_id")) == key scope "connect_id" &&
      (← text (key args "channel")) == key scope "chat_id" &&
      (← text (key args "thread_ts")) == b ""
  if scope.has (b "targets") then return (← matchingTarget name args scope) != nil
  return name == b "im_api.telegram.send_message" &&
    (← trimmed (key args "connect_id")) == (← trimmed (key scope "connect_id")) &&
    (← text (key args "chat_id")) == key scope "chat_id" &&
    (← text (key args "message_thread_id")) == key scope "message_thread_id"

private def defaultReplyTarget (args scope : Term) : Term :=
  let id := key scope "reply_to_message_id"
  let current := key args "reply_to_message_id"
  if id.isBinary && id != b "" && (current == nil || current == b "") then
    (args.put (b "reply_to_message_id") id).put (b "allow_sending_without_reply") (a "true")
  else args

private def binding (scope outcome id : Term) : Term :=
  ((scope.put (b "outcome") outcome).put (b "tool_call_id") id) |> fun m =>
    match m with
    | .map xs => .map (xs.filter (fun (k, _) => k != b "eligible"))
    | other => other

/-- A settling source reply: the scope without eligibility or targets, the
matched target, the outcome and the tool call id. -/
private def replyBinding (name args scope outcome id : Term) : KernelM Term := do
  let target ← matchingTarget name args scope
  let base := match binding scope outcome id with
    | .map xs => Term.map (xs.filter (fun (k, _) => k != b "targets"))
    | other => other
  return if scope.has (b "targets") then base.put (b "reply_target") target else base

private def finalOutcome (intent : Term) : Term :=
  let outcome := key intent "final_outcome"
  if key intent "reply_mode" == b "final" && (outcome == b "done" || outcome == b "blocked") then outcome
  else nil

private def ok (args bound : Term) : Term := .tuple [a "ok", args, bound]
private def refuse (message : String) : Term := .tuple [a "error", b message]

/-- `{:ok, args, binding | nil}` or `{:error, reason}`. `flags` carries
`llm_tool_envelope`, `runtime_failure_delivery` and `terminal_decision_outcome`, the
outcome of the model's `end_turn` whose reply this call delivers. -/
def admit (call scope flags : Term) : KernelM Term := do
  let name := key call "name"
  let args := (key call "args").default empty
  let id := key call "id"
  let intent := (key call "reply_intent").default empty
  let envelope := key flags "llm_tool_envelope" == a "true"
  let eligible := key scope "eligible" == a "true"
  let failure := key flags "runtime_failure_delivery" == a "true"
  let decisionOutcome := key flags "terminal_decision_outcome"
  let decision := decisionOutcome != nil
  if scope.isMap && key scope "kind" == b "channel_onboarding" && onboardingTools.contains name then
    if (← sourceSend name args scope) && eligible && envelope then
      return ok args (binding scope (b "done") id)
    return refuse "A channel welcome must be one standalone send to the joined channel, with no running work."
  if interactiveTools.contains name && scope.isMap && key scope "kind" == b "telegram" then
    if eligible && envelope then return ok args (binding scope (b "blocked") id)
    return refuse "Telegram questions must be standalone current-source calls with no running work."
  if ← sourceSend name args scope then
    let args := defaultReplyTarget args scope
    let outcome := finalOutcome intent
    let settle := replyBinding name args scope outcome id
    if failure then
      if key intent "reply_mode" == b "progress" then return ok args nil
      if outcome == nil then
        return refuse "A runtime failure reply requires reply_mode=progress or final with final_outcome."
      if eligible && envelope then return ok args (← settle)
      return refuse "A runtime failure reply must be standalone, with no running tools or pending work."
    if decision then
      if decisionOutcome != b "done" && decisionOutcome != b "blocked" then
        return refuse "A terminal decision reply requires a final outcome."
      if eligible && envelope then
        return ok args (← replyBinding name args scope decisionOutcome id)
      return refuse "A terminal decision reply requires the current source and no pending work."
    return ok args nil
  if decision then
    return refuse "A terminal decision reply must target the current accepted source destination."
  if failure && key intent "reply_mode" == b "final" then
    return refuse "A runtime failure reply must target the current accepted source destination."
  return ok args nil

end VerifiedKernel.AgentLoop.TerminalReply
