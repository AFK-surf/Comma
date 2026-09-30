defmodule SalixAgent.IFC.Render do
  @moduledoc """
  How a labelled item shows the model its `src:` ref
  (`docs/verification.md` §7).

  Nothing here filters, reorders or hides anything: the model sees the whole
  context, and this only gives each staged input a name it can cite when it
  declares what an effect drew on.

  Two properties matter more than the wording:

    * **Cache stability.** The annotation depends only on the message itself,
      never on who is asking or on the Group's mode, so a rendered prefix is
      identical on every later request and the provider's prompt prefix cache
      is untouched.
    * **Only labelled inputs.** A message staged before this design existed
      carries no sealed label, gets no ref, and renders exactly as it did
      before, so turning the check on never rewrites history.

  A tool result needs no annotation: its ref is `src:t-` followed by the tool
  call id the model already sees in its own transcript. The Router prompt
  states that convention. An asynchronous completion has a separate runtime
  record. Its annotation uses that record's `src:a-` ref and canonical result label.
  """

  @doc "Annotates a context message list with the refs of its labelled inputs."
  @spec annotate([map()]) :: [map()]
  def annotate(messages),
    do: SalixAgent.InternalSession.request_projection({:annotate_messages, messages})

  @doc "Annotates one message, or returns it untouched."
  @spec annotate_message(map()) :: map()
  def annotate_message(message),
    do: SalixAgent.InternalSession.request_projection({:annotate_message, message})
end
