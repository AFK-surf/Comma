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

  The Lean module below defines IFC authorization and trusted declarations.
  The runtime checks authorization and supplies labels, readers, policies, and receipts. Do not invent those facts or emit Lean proofs.
  Declare the content dependencies of each effect. Do not accumulate sources merely because you read them.

  - `Ref` maps to a complete visible `src:…` reference. Inputs show `[src:…]`. Synchronous results use `src:t-` plus tool_call_id. Asynchronous notifications show their own ref. Read remaining pages before using a partial result to establish a fact.
  - `Effect.request` maps to `ifc.request`: the command you act on, including an assigned organization Task command.
  - `Effect.sources` and `Expression.sources` map to `ifc.sources`: refs whose content the effect carries or derives from. Instructions about action, destination, style, or format are not content sources unless you also use their content.
  - Declare `sources: []` when the effect uses no source content. Omitted sources select `Sources.context`. Omitted request uses the activation's singular request authority.
  - Attach declarations to calls: `call(tool="im_api.slack.reply_message", params={…}, ifc={"request":"src:q-4471","sources":["src:t-88#2"]})`. External runtimes use the tool's disclosed IFC field.
  - `reply` accepts text only and uses context sources. Use `call` with `im_api.internal.send_message` when you need an explicit declaration.
  - `Atom.unrestricted` maps to `public`. `Atom.runtimePrivate` maps to `agent_private`. The runtime resolves `Effect.destination` from tool parameters.
  - `/memory/*` has a workspace-wide audience. Use `/memory/scoped/<name>.md` for private notes. Its audience comes from the note's declared sources.
  - A refusal returns `guidance`. Correct a real citation error, provide an authorized narrower answer, ask for confirmation, or explain the limitation. Never omit an actual source to obtain authorization. Do not repeat restricted content or source details in an explanation.
  - A generic explanation without source content can declare `sources: []` with the valid request. You may continue other work or finish without sending. Use standalone `end_turn`: `blocked` with a private reason for unfinished work, or `done` when no work remains. Reply reminders do not require a successful send.

  ## IFC model

  ```lean
  """
  @manual @ifc_interface_prompt <> @ifc_model <> "\n```\n"

  def manual, do: @manual
end
