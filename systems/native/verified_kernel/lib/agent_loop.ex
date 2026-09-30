defmodule SalixVerifiedKernel.AgentLoop do
  @moduledoc """
  Agent control decisions over explicit data. Dependency references cross the
  boundary as identity bytes, never as executable ETF terms.
  """

  @doc """
  `{events, continue?, speculate?}` for a settling background result, given the
  completion owner of that call and of each sibling still in flight in this actor.
  """
  def completion_wake(own_owner, sibling_owners, events),
    do: call(:completion_wake, {own_owner, sibling_owners, events})

  @doc """
  `{:ok, args, binding | nil}` or `{:error, reason}` for one call against the
  terminal-reply scope from the session query `terminal_reply_context`.
  """
  def terminal_reply_admission(call, scope, flags),
    do: call(:terminal_reply_admission, {call, scope, flags})

  @doc """
  `{:ok, target, params, ifc, reply_intent}` or `{:error, reason, target}` for
  the arguments of one `call` envelope.
  """
  def call_envelope(args), do: call(:call_envelope, args)

  def activation(llm, compaction, backoff), do: call(:activation, {llm, compaction, backoff})
  def retry_admission(retained, attempts), do: call(:retry_admission, {retained, attempts})
  def retry_failure(attempts, budget), do: call(:retry_failure, {attempts, budget})

  def terminal_owner(owner_session, owner_call, session, call),
    do: call(:terminal_owner, {owner_session, owner_call, session, call})

  def dependency_step({phase, expected}, {observed, event})
      when phase in [:running, :retained] and is_reference(expected) and is_reference(observed) do
    case call(
           :dependency_step,
           {{phase, reference_bytes(expected)}, {reference_bytes(observed), event}}
         ) do
      {{next_phase, _identity}, command} -> {{next_phase, expected}, command}
    end
  end

  def dependency_step(:retired, {observed, event}) when is_reference(observed),
    do: call(:dependency_step, {:retired, {reference_bytes(observed), event}})

  # Only references use this representation. Lean compares bytes and does not
  # decode them. The actor keeps the actual reference and retained payload.
  defp reference_bytes(reference), do: :erlang.term_to_binary(reference, minor_version: 2)

  defp call(operation, payload) do
    case SalixVerifiedKernel.invoke(:agent_loop, operation, payload) do
      {:ok, result} -> result
      {:error, owner, code} -> raise ArgumentError, "verified kernel #{owner}: #{code}"
    end
  end
end
