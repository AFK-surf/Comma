defmodule SalixLlm.ConvertOpenAI do
  @moduledoc "OpenAI message projections owned by the Lean provider kernel."
  alias SalixVerifiedKernel.Provider, as: Kernel

  def to_chat(messages, model \\ nil), do: Kernel.call(:chat_messages, {messages, model})
  def to_responses(messages), do: elem(to_responses_parts(messages), 0)
  def to_responses_parts(messages), do: Kernel.call(:responses_parts, messages)
  def chat_tools(specs), do: Kernel.call(:tools, {"chat", specs})
  def responses_tools(specs), do: Kernel.call(:tools, {"responses", specs})
  def parse_chat(response), do: Kernel.call(:parse_chat, response)
  def parse_responses(response), do: Kernel.call(:parse_responses, response)
  def chat_provider_meta(message), do: Kernel.call(:chat_metadata, message)
  def chat_provider_meta_from_deltas(deltas), do: Kernel.call(:chat_delta_metadata, deltas)
end
