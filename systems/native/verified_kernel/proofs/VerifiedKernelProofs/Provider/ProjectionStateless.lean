import VerifiedKernelProofs.Provider.Stateless

/-!
The provider projection never observes the host, so every run of it is journal independent.
-/

namespace VerifiedKernel
open Data Provider

set_option maxHeartbeats 4000000

theorem Provider.str.stateless (v : Term) : Stateless (str v) := by stateless
theorem Provider.cat.stateless (xs : List Term) : Stateless (cat xs) := by stateless
theorem Provider.join.stateless (xs : List Term) (sep : String) : Stateless (join xs sep) := by stateless
theorem Provider.encode.stateless (v : Term) : Stateless (Provider.encode v) := by stateless
theorem Provider.trimmed.stateless (v : Term) : Stateless (trimmed v) := by stateless
theorem Provider.toolSpec.stateless (protocol : String) (spec : Term) : Stateless (toolSpec protocol spec) := by
  stateless
theorem Provider.Content.runtimeText.stateless (m : Term) : Stateless (Content.runtimeText m) := by stateless
theorem Provider.Content.systemText.stateless (m : Term) : Stateless (Content.systemText m) := by stateless
theorem Provider.Content.inputTime.stateless (m content : Term) (textType : String) :
    Stateless (Content.inputTime m content textType) := by stateless
theorem Provider.Content.fileText.stateless (block : Term) : Stateless (Content.fileText block) := by stateless
theorem Provider.Content.block.stateless (protocol : String) (v : Term) : Stateless (Content.block protocol v) := by
  stateless
theorem Provider.Content.convert.stateless (protocol : String) (m : Term) :
    Stateless (Content.convert protocol m) := by stateless

namespace Provider.Messages
theorem context.stateless (text : Term) : Stateless (context text) := by stateless
theorem runtimeCallId.stateless (m : Term) : Stateless (runtimeCallId m) := by stateless
theorem runtimeContent.stateless (content : Term) : Stateless (runtimeContent content) := by stateless
theorem runtimePayload.stateless (m : Term) : Stateless (runtimePayload m) := by stateless
theorem asReminder.stateless (m : Term) : Stateless (asReminder m) := by stateless
theorem runtimeCall.stateless (m id : Term) (reminder : Bool) : Stateless (runtimeCall m id reminder) := by
  stateless
theorem conversationTurn.stateless (m : Term) : Stateless (conversationTurn m) := by stateless
theorem syntheticRuntime.stateless (messages : List Term) (reminders system : Bool) :
    Stateless (syntheticRuntime messages reminders system) := by stateless
theorem anthropicMessage.stateless (m model : Term) : Stateless (anthropicMessage m model) := by stateless
theorem anthropicParts.stateless (messages : List Term) (model : Term) :
    Stateless (anthropicParts messages model) := by stateless
theorem chatMessage.stateless (m model : Term) : Stateless (chatMessage m model) := by stateless
theorem chatTool.stateless (m : Term) (names : CallMap Term) : Stateless (chatTool m names) := by stateless
theorem adjacentChat.stateless (chat : List Term) : Stateless (adjacentChat chat) := by stateless
theorem freeWireId.stateless (issued : Std.HashSet CallKey) (id : Term) :
    ∀ (n fuel : Nat), Stateless (freeWireId issued id n fuel)
  | _, 0 => by rw [freeWireId]; exact Stateless.fail _ _
  | n, fuel + 1 => by
    rw [freeWireId]
    exact Stateless.bind (by stateless) fun _ =>
      Stateless.ite (freeWireId.stateless issued id (n + 1) fuel) (Stateless.pure _)
theorem wireCall.stateless (ids : WireIds) (c : Term) : Stateless (wireCall ids c) := by stateless
theorem wireCallStep.stateless (r : WireIds × CallMap Term × List Term) (c : Term) :
    Stateless (wireCallStep r c) := by stateless
theorem wireMessage.stateless (ids : WireIds) (m : Term) : Stateless (wireMessage ids m) := by stateless
theorem wireStep.stateless (r : WireIds × List Term) (m : Term) : Stateless (wireStep r m) := by stateless
theorem wireMessages.stateless (ids : WireIds) (xs : List Term) : Stateless (wireMessages ids xs) := by stateless
theorem uniqueChatCallIds.stateless (messages : List Term) : Stateless (uniqueChatCallIds messages) := by
  stateless
theorem chat.stateless (messages : List Term) (model : Term) : Stateless (chat messages model) := by stateless
theorem responsesMessage.stateless (m : Term) : Stateless (responsesMessage m) := by stateless
theorem historicalRecord.stateless (item : Term) : Stateless (historicalRecord item) := by stateless
theorem historicalStep.stateless (r : List Term × List Term) (item : Term) :
    Stateless (historicalStep r item) := by stateless
theorem historicalTools.stateless (items : List Term) : Stateless (historicalTools items) := by stateless
theorem responsesParts.stateless (messages : List Term) :
    Stateless (responsesParts messages) := by stateless
end Provider.Messages

theorem Provider.Request.body.stateless (protocol : String) (cfg : Term) (messages tools : List Term)
    (mode : String) :
    Stateless (Request.body protocol cfg messages tools mode) := by stateless

end VerifiedKernel
