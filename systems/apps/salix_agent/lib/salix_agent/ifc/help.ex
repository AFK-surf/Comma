defmodule SalixAgent.IFC.Help do
  @moduledoc false

  @ifc_model_path Path.expand(
                    "../../../../../native/verified_kernel/proofs/VerifiedKernelProofs/IFC/Model.lean",
                    __DIR__
                  )
  @external_resource @ifc_model_path
  @ifc_model File.read!(@ifc_model_path)

  @ifc_interface_prompt """
  ## IFC interface

  Hard mode uses the Lean model below. The stored name `enforce` also means Hard.
  Easy checks requester access to IM sources: provider conversations and Comma Conversations. Channel sources also require the connected bot to be in that channel.
  Supervisors retain requester clearance, but do not bypass the bot membership requirement.
  Easy does not require a receipt or destination writer permission. Sealed sources and SSH host tags do not restrict Easy.
  The shared /memory writer whitelist still applies.
  The runtime applies the selected mode. Do not refuse a request by guessing which mode is active.
  The Lean module below defines Hard authorization and trusted declarations.
  The runtime checks authorization and supplies labels, readers, policies, and receipts. Do not invent those facts or emit Lean proofs.
  Declare the content dependencies of each effect. Do not accumulate sources merely because you read them.

  - `Ref` maps to a complete visible `src:…` reference. Inputs show `[src:…]`. Synchronous results use `src:t-` plus tool_call_id. Asynchronous notifications are runtime messages: use their `ref` or `[src:…]` marker, not the call ID. Read remaining pages before using a partial result to establish a fact.
  - `Effect.request` maps to `ifc.request`: the reference of the command you act on, including an assigned organization Task command. Copy its complete `src:` reference from the input. For an input marked `[src:q-4471]`, use `"request":"src:q-4471"`, without square brackets. Do not put the message text, a paraphrase, a user ID, or a channel ID in this field. The marker can appear before source metadata or system reminders within the same input. It still identifies that input.
  - `request` identifies whose request the effect serves. `sources` identifies the information the output uses. They can refer to different inputs. For a request marked `[src:q-4471]` answered from data marked `[src:t-88#2]`, declare `"request":"src:q-4471","sources":["src:t-88#2"]`.
  - For `unknown_request_ref`, inspect the input you are responding to and copy its actual marker. Check that it is the request this effect serves. Correct the reference and submit the call again through normal authorization. Do not invent a reference or select an unrelated request. An invalid submitted reference does not mean the input has no valid reference. Reading this manual does not complete the failed action.
  - `Effect.sources` and `Expression.sources` map to `ifc.sources`: refs whose content the effect carries or derives from. Instructions about action, destination, style, or format are not content sources unless you also use their content.
  - Declare `sources: []` when the effect uses no source content. When IFC is enabled, capability calls require an `ifc` object and an explicit `sources` array. Fixed local queries may omit it: registered local help with only tool, built-in skill reads with only path, and im.provider_apis_list with only a built-in provider selector. Other reads and effects still require declarations. An explicit malformed declaration remains invalid. Missing sources, `context`, and malformed arrays are tool parameter errors before IFC authorization, including in audit mode. A valid call that receives an IFC deny still executes in audit mode. An activation can hold several requests from one thread: cite the one each effect acts on, and its sender is the requester. With several senders, an effect that omits request is refused.
  - Attach declarations to calls: `call(tool="im_api.slack.reply_message", params={…}, ifc={"request":"src:q-4471","sources":["src:t-88#2"]})`. Canonical HTTP and script calls put `ifc` beside the tool arguments. Their help schema includes this field when IFC is enabled.
  - `end_turn.reply` carries the same `ifc` declaration as `call`. A settlement without a reply needs no declaration.
  - `Atom.unrestricted` maps to `public`. `Atom.runtimePrivate` maps to `agent_private`. The runtime resolves `Effect.destination` from tool parameters.
  - `/memory/*` has a workspace-wide audience. Use `/memory/scoped/<name>.md` for private notes. Its audience comes from the note's declared sources.
  - A refusal returns `guidance`. Correct a real citation error, provide an authorized narrower answer, ask for confirmation, or explain the limitation. Never omit an actual source to obtain authorization. Do not repeat restricted content or source details in an explanation.
  - A generic explanation without source content can declare `sources: []` with the valid request. Generic means it names no topic, entity, or detail learned only from the restricted source: say "I cannot share that information here", not a topic-specific refusal. Asking for documents about that topic also reveals it. A person waiting for an answer gets that explanation before you settle, unless they told you not to reply. You may also continue other work. Then use standalone `end_turn`: `blocked` with a private reason for unfinished work, or `done` when no work remains. If the explanation is refused too, settle anyway.

  A local validation result can expose a fixed diagnostic in items[0], cited as its result ref plus #0. That item is public; the complete error retains its original audience. Never treat provider errors or their public summaries as public sources.

  ## IFC model

  ```lean
  """
  @manual @ifc_interface_prompt <> @ifc_model <> "\n```\n"

  def manual, do: @manual
end
