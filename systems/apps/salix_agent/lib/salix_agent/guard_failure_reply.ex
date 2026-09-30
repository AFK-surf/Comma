defmodule SalixAgent.GuardFailureReply do
  @moduledoc false

  # The tool context for the runtime failure notice. The kernel's loop reserves
  # the notice and builds its call; the host dispatches it with this context.

  alias SalixAgent.{InternalSession, TerminalReply}

  def context(session, config, runtime_context) do
    sources = InternalSession.query(session, :current_source_ids)
    scope = TerminalReply.source_scope(session)
    origin = if is_map(scope), do: scope["trusted_origin"], else: nil
    source = if is_map(scope), do: scope["source_message_id"], else: nil
    tenant_id = config[:tenant_id]
    group_id = config[:group_id]
    mode = SalixAgent.IFC.mode_for(tenant_id, group_id)

    Map.merge(config, %{
      agent_id: InternalSession.agent_id(session),
      session_id: InternalSession.session_id(session),
      source_message_id: source,
      source_message_ids: sources,
      reply_source_scope: scope,
      trusted_origin: origin,
      trusted_origins: InternalSession.query(session, :current_turn_trusted_origins, sources),
      ifc_mode: mode,
      ifc:
        mode != :off &&
          SalixAgent.IFC.Context.build(session,
            source_message_id: source,
            source_message_ids: sources,
            trusted_origin: origin
          ),
      organization_scopes: SalixAgent.IFC.Context.organization_scopes(session, sources),
      triage_scopes:
        SalixAgent.IFC.Context.organization_scopes(session, sources, "triage_investigation"),
      runtime_kind: :internal,
      llm_tool_envelope: true,
      defer_tool_observations: true,
      billing_context: InternalSession.get(session, :billing_context) || %{},
      visible_reply_phase: runtime_context[:visible_reply_phase] || :clean,
      visible_reply_scope: runtime_context[:visible_reply_scope],
      trace_ctx: runtime_context[:trace_ctx]
    })
  end
end
