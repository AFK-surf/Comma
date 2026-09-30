defmodule SalixAgent.TerminalReply do
  @moduledoc """
  Source-bound replies for IM and Comma, plus optional Slack channel welcomes.
  Ordinary replies can accompany an explicit end_turn decision. Existing
  terminal records and interactive-card settlement retain their result-commit semantics.
  A welcome attempt settles on success or refusal without acknowledging later
  input. The session owner commits its result, source ACK, and idle status
  together. Feature behavior is covered by implementation regressions.
  """

  alias SalixAgent.InternalSession

  @doc """
  Derive the one Telegram request owner without dropping activation provenance.

  Trusted Worker/system and no-wake inputs are context, not additional human
  requests. Unknown carriers and multiple human requests fail closed. This
  `source_message_id` and `trusted_origin` identify that request and destination.
  `context_source_message_ids` retains all execution sources for IFC and tool
  checks. This projection is not a capability token or a second source ledger.
  FORMAL-SPEC: tla/salix/TerminalReplySettlement.tla Allowed / ExactSource.
  """
  def source_scope(session), do: InternalSession.query(session, :terminal_reply_source_scope)

  @doc false
  def source_scope_matches_context?(scope, ctx) when is_map(scope) do
    scope["source_message_id"] == ctx[:source_message_id] and
      scope["context_source_message_ids"] == ctx[:source_message_ids] and
      scope["trusted_origin"] == ctx[:trusted_origin]
  end

  def source_scope_matches_context?(_scope, _ctx), do: false

  def append_reminder(messages, session, role),
    do:
      InternalSession.query(
        session,
        :provider_request_part,
        {:terminal_reminder, messages, request_authority?(session, role)}
      )

  def request_authority?(session, role),
    do:
      role == "router" and
        canonical_router?(InternalSession.agent_id(session), InternalSession.session_id(session))

  # This binding permits only local failure disposition. Send authorization
  # remains in the kernel's terminal_reply_context, including the Router fact.
  def disposition_context(session, assistant_id),
    do: InternalSession.query(session, :guard_disposition_binding, assistant_id)

  # The kernel builds the scope; the host supplies only the canonical-Router fact.
  def context(session, ctx, assistant_id, call_count) do
    InternalSession.query(session, :terminal_reply_context, %{
      "role" => ctx[:role],
      "router_authority" => request_authority?(session, ctx[:role]),
      "agent_id" => ctx[:agent_id],
      "trusted_origin" => ctx[:trusted_origin],
      "source_message_id" => ctx[:source_message_id],
      "source_message_ids" => ctx[:source_message_ids],
      "assistant_id" => assistant_id,
      "call_count" => call_count
    })
  end

  # The kernel admits the call against the scope and returns its arguments with
  # any source-reply default, plus the terminal binding when the call settles.
  def authorize(call, ctx) do
    admitted =
      SalixVerifiedKernel.AgentLoop.terminal_reply_admission(
        %{
          "name" => value(call, :name),
          "args" => value(call, :args),
          "id" => value(call, :id),
          "reply_intent" => call[:reply_intent]
        },
        ctx[:terminal_reply_context],
        %{
          "llm_tool_envelope" => ctx[:llm_tool_envelope] == true,
          "runtime_failure_delivery" => ctx[:runtime_failure_delivery] == true,
          "terminal_decision_outcome" => ctx[:terminal_decision_outcome]
        }
      )

    case admitted do
      {:ok, args, nil} -> {:ok, put_args(call, args)}
      {:ok, args, binding} -> {:ok, call |> put_args(args) |> Map.put(:terminal_reply, binding)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_args(%{args: current} = call, args) when current != nil, do: %{call | args: args}
  defp put_args(call, _args), do: call

  def stamp_results(results, calls) do
    bindings = Map.new(calls, &{value(&1, :id), &1[:terminal_reply]})

    Enum.map(results, fn result ->
      case bindings[value(result, :id)] do
        nil -> result
        binding -> Map.put(result, :terminal_reply, binding)
      end
    end)
  end

  # The kernel owns settlement events and the exact source ACK.
  def settle(session, record, result, events),
    do: InternalSession.query(session, :terminal_settlement, {record, result, events})

  def settle_onboarding(session, results, events),
    do:
      InternalSession.query(session, :onboarding_settlement, {
        results,
        events,
        onboarding_authority?(session)
      })

  def settle_onboarding_async(session, pending, result, events),
    do:
      InternalSession.query(session, :onboarding_async_settlement, {
        pending,
        result,
        events,
        onboarding_authority?(session)
      })

  def settled?(events), do: InternalSession.settlement_completed?(events)

  def onboarding_authority?(session),
    do:
      InternalSession.query(session, :onboarding_authority_required?) and
        canonical_router?(InternalSession.agent_id(session), InternalSession.session_id(session))

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "Whether this session is its agent's canonical Router session."
  def canonical_router?(session),
    do: canonical_router?(InternalSession.agent_id(session), InternalSession.session_id(session))

  defp canonical_router?(agent_id, session_id) do
    with {:ok, agent} <- SalixAgent.Control.get(agent_id),
         {:ok, ^session_id} <- SalixStore.RuntimeIds.persisted_router_session_id(agent) do
      true
    else
      _ -> false
    end
  end
end
