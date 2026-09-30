import VerifiedKernel.Session.Ops

/-! Rule texts the runtime used to append to every request as per-request
reminders. They now live in the stored prompt as one static catalog, and a
request ends with a short `turn:` line naming the flags active on it
(`Session/Request.lean` `turnMarker`). `ReplyQuery.promptSnapshot` refreshes this
prompt from the current activation configuration. -/

namespace VerifiedKernel.Session.TurnReminders
open Data

def catalogHeading : String := "## Turn reminders"

def deliveryInstruction : String := "Plain assistant content is not delivered to Comma. A standalone send delivers only after a successful tool result. A final reply carried by end_turn is delivered before settlement; the runtime checks its send result. A draft, search result, or generated answer is not a delivery receipt. Do not resend an answer that already has a successful send result. If no reply is needed, or delivery cannot progress, you may still end_turn with the appropriate outcome; do not claim unsent content was delivered."
def deliveryRule : String := " Send standalone Comma messages through call with tool=im_api.internal.send_message, params.connect_id=internal and params.conversation_id set to the current source conversation. Content uses the operation schema. If the answer is ready and unsent, carry that tool and its params in end_turn.reply. Send opening or progress updates through call. Follow current disclosure and authorization. Do not send this Comma answer to an earlier external chat."
def opening : String := "This request answers a new Comma user message. Respond promptly, before extended analysis, research, delegation, or other task work. Keep reasoning brief: send one short, specific sentence in the user's language that addresses the request and states your immediate next step, through call with tool=im_api.internal.send_message to the current source conversation. Do not delay it until you have worked out the full solution. For a greeting or an immediately answerable question, give the answer itself instead of a separate acknowledgment. Ask only essential questions. Respect requests for silence or a particular output format. Continue the requested work after the first message and deliver the result. Do not invent progress, results, or time estimates. Send later updates only when they add useful progress, and never repeat a successful send merely to finish the turn."
def terminalReply : String := "A standalone current-source IM or Comma send only delivers a message. It does not end the activation. If work is complete and the final reply has not been sent, call end_turn with outcome done and reply={tool,params}. The runtime sends that reply before it settles. If a reply was already sent, call end_turn without reply when work is complete. Continue independent work after an opening or progress reply. Create or update the ordinary Worker Task before reporting delegation. If essential human input prevents all progress, call end_turn with outcome blocked, a reason, and an optional unsent question in reply. Do not repeat a delivered reply to finish. Keep provider parameters inside params and use the current source provider operation. Existing interactive-card and optional channel-welcome lifecycle rules still apply."
def turnOutcome : String := "Re-evaluate every current request, commitment, and unfinished action. If work can progress now, use a capability tool. If progress depends on a concrete future condition, use wait_for. Use end_turn with outcome done only when the requested work is complete; ordinary reply reminders may be declined when no reply is needed. Use end_turn with outcome blocked only when unresolved work remains and no action can make progress. An IFC refusal can be settled without sending another message: use blocked with a private reason for unfinished work, or done when no reply or further work is needed. Optional clues are not blockers; continue available searches or independent work after asking. Plain text does not end the turn."
def onboarding : String := "Current input is an optional product-owned Slack channel welcome, not a human request. Use only brief channel-local research; do not enumerate the workspace or retry refusals with different references. If appropriate, make one standalone im_api.slack.post_channel_message call to the joined channel, without thread_ts. The runtime supplies authority only for that welcome, not for private-data transfer or other effects. Keep ifc.sources accurate. This attempt ends on success or refusal; unrelated reads cannot resolve a denial. If no welcome is appropriate, use end_turn. Onboarding research is bounded and may end automatically so later human requests can proceed."
def repair : String := "A private tool diagnostic requires repair. Keep private diagnostics private and do not quote or expose them. Use the currently disclosed tools as needed; calls execute normally and return their real results or receipts. A successful terminal tool result completes repair, while a pending or failed result keeps repair active. Plain text, blank output, and end_turn cannot settle it."

def catalog : String :=
  "## Turn reminders\n\nA request may end with one short runtime line of the form `turn: <flag> <flag> ...` inside a system block. Each flag activates the matching rule below for that request only; a flag that is absent is inactive on that request. The line is kept short so the provider prompt cache can extend past it; the rules stay here so they are cached with this prompt.\n\n- opening=on: " ++ opening ++
  "\n- deliver=on: " ++ deliveryInstruction ++ deliveryRule ++
  "\n- decide=on: " ++ turnOutcome ++
  "\n- final_reply=on: " ++ terminalReply ++
  "\n- onboarding=on: " ++ onboarding ++
  "\n- repair=on: " ++ repair

private def headingBytes : ByteArray := catalogHeading.toUTF8

private def headingAt (raw : ByteArray) (pos : Nat) : Nat → Bool
  | 0 => true
  | index + 1 => raw[pos + index]! == headingBytes[index]! && headingAt raw pos index

/-- Whether the heading occurs at a position from `start`, trying only the
positions of its first byte. -/
private def headingFrom (raw : ByteArray) (start : Nat) : Nat → Bool
  | 0 => false
  | fuel + 1 =>
    match raw.findIdx? (· == headingBytes[0]!) start with
    | none => false
    | some pos =>
      if pos + headingBytes.size > raw.size then false
      else headingAt raw pos headingBytes.size || headingFrom raw (pos + 1) fuel

/-- Whether a stored or configured prompt already carries the catalog: the
prompt is UTF-8 and holds the heading. UTF-8 matches a character sequence
exactly where its bytes match, so the bytes are searched without decoding
the prompt into a string and splitting it. -/
def catalogPresent (prompt : Term) : Bool :=
  match prompt with
  | .binary raw => headingFrom raw 0 (raw.size + 1) && raw.validateUTF8
  | _ => false

end VerifiedKernel.Session.TurnReminders
