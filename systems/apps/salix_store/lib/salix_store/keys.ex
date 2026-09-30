defmodule SalixStore.Keys do
  @moduledoc """
  Centralized S3 object-key construction. Every key the storage
  kernel reads or writes is produced here so the layout is reviewable in one
  place and the per-agent-prefix request-rate fan-out is guaranteed.

  Numeric components are fixed-width, zero-padded hex where lexical LIST order
  needs to match numeric order.
  """

  alias SalixStore.{Crypto, Ids}

  # ---- per-agent execution/data plane ----

  def agents_prefix, do: "agents/"
  def agent_state(agent_id), do: "agents/#{agent_id}/state.etf.zst"
  def agent_workspace_state_suffix, do: "/workspace/state.etf.zst"

  def agent_workspace_state(agent_id),
    do: agents_prefix() <> agent_id <> agent_workspace_state_suffix()

  # Runtime-NEUTRAL, per-(agent, session) create-once birth marker: the
  # single durable authority for which store a session id is born in
  # (SalixAgent.SessionBirth, plan clause 2b). One small object per session
  # ever placed; it lives under the agent prefix so agent-lifecycle cleanup
  # covers it.
  def agent_session_birth(agent_id, session_id),
    do: "agents/#{agent_id}/session_birth/#{Crypto.hex(session_id)}.json"

  def agent_internal_runtime_sessions_prefix(agent_id),
    do: "agents/#{agent_id}/internal_runtime/sessions/"

  def agent_internal_runtime_session(agent_id, session_id),
    do: "agents/#{agent_id}/internal_runtime/sessions/#{Crypto.hex(session_id)}/state.etf.zst"

  # ONE append-only archive object per session. The hot object's byte-offset
  # catalog addresses ranges inside it, so history paging is a single ranged
  # GET and archival is a single PUT — no chunk namespace, no LIST.
  def agent_internal_runtime_session_archive(agent_id, session_id),
    do: "agents/#{agent_id}/internal_runtime/sessions/#{Crypto.hex(session_id)}/archive.jsonl"

  # Format 3: immutable sealed segments, named by their FIRST seq (the name
  # is the segment's whole identity — SegmentLog's "name is the only index"
  # rule). Seq is zero-padded so lexical order matches seq order. The hot
  # object's segment catalog is the only index — these keys are addressed
  # directly, never listed.
  def agent_internal_runtime_session_segments_prefix(agent_id, session_id),
    do: "agents/#{agent_id}/internal_runtime/sessions/#{Crypto.hex(session_id)}/segments/"

  def agent_internal_runtime_session_segment(agent_id, session_id, first_seq) do
    agent_internal_runtime_session_segments_prefix(agent_id, session_id) <>
      "#{pad_seq(first_seq)}.etf.zst"
  end

  defp pad_seq(seq) when is_integer(seq) and seq >= 0,
    do: seq |> Integer.to_string() |> String.pad_leading(20, "0")

  def agent_external_runtime_sessions_prefix(agent_id),
    do: "agents/#{agent_id}/external_runtime/sessions/"

  def agent_external_runtime_session_prefix(agent_id, session_id),
    do: agent_external_runtime_sessions_prefix(agent_id) <> "#{session_id}/"

  def agent_external_runtime_session(agent_id, session_id),
    do: agent_external_runtime_sessions_prefix(agent_id) <> "#{session_id}.json"

  def agent_external_runtime_session_segments_prefix(agent_id, session_id),
    do: agent_external_runtime_session_prefix(agent_id, session_id) <> "segments/"

  def agent_external_runtime_session_segment(agent_id, session_id, first_record_ulid),
    do:
      agent_external_runtime_session_segments_prefix(agent_id, session_id) <>
        "#{first_record_ulid}.jsonl"

  def agent_external_runtime_session_status(agent_id, session_id),
    do: agent_external_runtime_session_prefix(agent_id, session_id) <> "status.json"

  def agent_session_trajectory_eval(agent_id, session_id),
    do: "agents/#{agent_id}/trajectory_evals/#{Crypto.hex(session_id)}.json"

  def agent_session_work_index_prefix(agent_id),
    do: "agents/#{agent_id}/session_work_index/"

  def agent_session_work_index_prefix(agent_id, runtime_kind),
    do: "agents/#{agent_id}/session_work_index/#{runtime_kind}/"

  def agent_session_work_index(agent_id, runtime_kind, session_id),
    do: "agents/#{agent_id}/session_work_index/#{runtime_kind}/#{Crypto.hex(session_id)}.json"

  # The staged-delivery protocol's key families (the per-agent inbox and
  # dead-letter objects, the sharded queue markers, and the hourly recent
  # touches) are retired (A2 §3.4, rpc-direct-delivery.md). Leftover objects
  # are cleaned by the A3 GC as it walks agents; nothing reads or writes
  # those prefixes any more. The identity migrations carry their own literals
  # for the historical layout they transform.

  def blob(uuid), do: "blobs/#{uuid}"

  # Prepared meeting-artifact bodies are owned by this durable cleanup record
  # until an agent workspace manifest commits their ref.  The record lives
  # outside the blob namespace so listing cleanup work never scans user data.
  def prepared_blob_cleanup_prefix, do: "cleanup/prepared_blobs/"

  def prepared_blob_cleanup(uuid),
    do: prepared_blob_cleanup_prefix() <> "#{uuid}.json"

  def prepared_blob_cleanup_cursor, do: "cleanup/prepared_blobs_cursor.json"

  # ---- control plane ----

  def ctl_agent(agent_id), do: "ctl/agents/#{agent_id}.json"
  def ctl_template(template_id), do: "ctl/templates/#{template_id}.json"
  def ctl_templates_prefix, do: "ctl/templates/"

  def ctl_private_templates_prefix(tenant_id), do: "ctl/tenant_templates/#{tenant_id}/"

  def ctl_private_template(tenant_id, template_id),
    do: ctl_private_templates_prefix(tenant_id) <> "#{template_id}.json"

  def ctl_group(group_id), do: "ctl/groups/#{group_id}.json"
  def ctl_groups_prefix, do: "ctl/groups/"

  def ctl_groups_prefix_for_tenant(tenant_id),
    do: ctl_groups_prefix() <> Ids.group_id_prefix_for_tenant!(tenant_id)

  def ctl_initial_agent(tenant_id, slot), do: "ctl/initial_agents/#{tenant_id}/#{slot}.json"
  def ctl_initial_agents_prefix(tenant_id), do: "ctl/initial_agents/#{tenant_id}/"
  def ctl_tenant(tenant_id), do: "ctl/tenants/#{tenant_id}.json"
  def ctl_tenants_prefix, do: "ctl/tenants/"
  def ctl_node(node_id), do: "ctl/nodes/#{node_id}.json"
  def ctl_nodes_prefix, do: "ctl/nodes/"
  def ctl_api_key(tenant_id, key_hash), do: "ctl/tenant_api_keys/#{tenant_id}/#{key_hash}.json"
  def ctl_api_keys_prefix(tenant_id), do: "ctl/tenant_api_keys/#{tenant_id}/"
  def ctl_api_keys_root, do: "ctl/tenant_api_keys/"
  def ctl_connector_token(token_hash), do: "ctl/connector_tokens/#{token_hash}.json"
  def ctl_connector_tokens_prefix, do: "ctl/connector_tokens/"
  def ctl_runtime_capability(token_hash), do: "ctl/runtime_capabilities/#{token_hash}.json"
  def ctl_runtime_capabilities_prefix, do: "ctl/runtime_capabilities/"

  def ctl_tenant_config(tenant_id, name), do: "ctl/tenant_configs/#{tenant_id}/#{name}.json"
  # Root prefix used only by the S3->PG cutover/audit to enumerate every discrete
  # tenant-config object (docs/storage-search.md).
  def ctl_tenant_configs_prefix, do: "ctl/tenant_configs/"

  # Platform-wide Router/Worker default template pointers (SalixAgent.AgentDefaults).
  def ctl_system_agent_defaults, do: "ctl/system/agent_defaults.json"

  # Platform-wide voice call settings (SalixVoice.Settings).
  def ctl_system_voice, do: "ctl/system/voice.json"
  # The platform Signal account (SalixSignal.Settings).
  def ctl_system_signal, do: "ctl/system/signal.json"

  def ctl_system_plugin_definitions_prefix, do: "ctl/system/plugins/definitions/"

  def ctl_tenant_plugin_definitions_prefix(tenant_id),
    do: "ctl/tenants/#{tenant_id}/plugins/definitions/"

  def ctl_group_plugin_definitions_prefix(tenant_id, group_id),
    do: "ctl/tenants/#{tenant_id}/groups/#{group_id}/plugins/definitions/"

  def ctl_system_plugin_definition(plugin_id),
    do: ctl_system_plugin_definitions_prefix() <> "#{plugin_id}/state.json"

  def ctl_tenant_plugin_definition(tenant_id, plugin_id),
    do: ctl_tenant_plugin_definitions_prefix(tenant_id) <> "#{plugin_id}/state.json"

  def ctl_group_plugin_definition(tenant_id, group_id, plugin_id),
    do: ctl_group_plugin_definitions_prefix(tenant_id, group_id) <> "#{plugin_id}/state.json"

  def ctl_group_plugin_enablements_prefix(tenant_id, group_id),
    do: "ctl/tenants/#{tenant_id}/groups/#{group_id}/plugins/enablements/"

  def ctl_group_plugin_enablement(tenant_id, group_id, plugin_id),
    do: ctl_group_plugin_enablements_prefix(tenant_id, group_id) <> "#{plugin_id}/state.json"

  def ctl_skill_scope_global, do: "ctl/skills/global/state.etf.zst"
  def ctl_skill_scope_tenant(tenant_id), do: "ctl/skills/tenants/#{tenant_id}/state.etf.zst"
  def ctl_skill_scope_group(group_id), do: "ctl/skills/groups/#{group_id}/state.etf.zst"
  def ctl_skill_scope_agent(agent_id), do: "ctl/skills/agents/#{agent_id}/state.etf.zst"

  def ctl_oauth_provider_app(tenant_id, provider),
    do: "ctl/oauth/provider_apps/#{tenant_id}/#{provider}.json"

  def ctl_oauth_provider_apps_prefix(tenant_id), do: "ctl/oauth/provider_apps/#{tenant_id}/"
  # Root prefix used only by the S3->PG cutover/audit to enumerate every tenant's
  # provider apps (docs/storage-search.md).
  def ctl_oauth_provider_apps_root, do: "ctl/oauth/provider_apps/"

  # Deployment-wide default OAuth provider apps: the fallback client
  # credentials used when a tenant has not configured its own provider app.
  # Operator-managed (Salix dashboard / admin API), tenant-independent.
  def ctl_oauth_default_app(provider), do: "ctl/oauth/default_apps/#{provider}.json"

  def ctl_oauth_default_apps_prefix, do: "ctl/oauth/default_apps/"

  def ctl_oauth_remote_mcp_client_registration(tenant_id, provider_key),
    do: "ctl/tenants/#{tenant_id}/oauth/client_registrations/remote_mcp/#{provider_key}.json"

  def ctl_oauth_remote_mcp_client_registrations_prefix(tenant_id),
    do: "ctl/tenants/#{tenant_id}/oauth/client_registrations/remote_mcp/"

  def ctl_oauth_remote_mcp_provider_app(tenant_id, provider_key),
    do: "ctl/tenants/#{tenant_id}/oauth/provider_apps/remote_mcp/#{provider_key}.json"

  def ctl_oauth_remote_mcp_provider_apps_prefix(tenant_id),
    do: "ctl/tenants/#{tenant_id}/oauth/provider_apps/remote_mcp/"

  # Tenant Composio settings: the tenant's Composio project API key + enabled
  # flag, letting a tenant use Composio-hosted connections and direct tool
  # execution instead of configuring per-provider OAuth apps. Mirrors the
  # oauth provider-app layout, including a deployment-wide default record.
  def ctl_composio_settings(tenant_id), do: "ctl/composio/tenants/#{tenant_id}.json"

  def ctl_composio_default_settings, do: "ctl/composio/default.json"

  # Prefix of the per-tenant Composio settings objects (the deployment default
  # is a single object outside this prefix). Used only by the S3→Postgres
  # cutover enumeration (docs/storage-search.md).
  def ctl_composio_tenants_prefix, do: "ctl/composio/tenants/"

  # Tenant-level (org-level) Feishu app record. One per tenant — the org's
  # Feishu custom app — holding the bot-side secrets. Mirrors the oauth
  # provider-app layout (`ctl/oauth/provider_apps/...`); the bot secret lives
  # here, never in BFT (RFC feishu-onboarding-rfc.md §4.4, option B).
  def ctl_feishu_tenant_app(tenant_id), do: "ctl/feishu/tenant_apps/#{tenant_id}.json"

  # Prefix of the per-tenant Feishu app objects. Used only by the S3→Postgres
  # cutover enumeration (docs/storage-search.md).
  def ctl_feishu_tenant_apps_prefix, do: "ctl/feishu/tenant_apps/"

  def ctl_oauth_group_binding(group_id, binding_id),
    do: "ctl/oauth/group_bindings/#{group_id}/#{binding_id}.json"

  def ctl_oauth_group_bindings_prefix(group_id), do: "ctl/oauth/group_bindings/#{group_id}/"

  def ctl_group_conversation(group_id, conversation_id),
    do: ctl_group_conversation_meta(group_id, conversation_id)

  def ctl_group_conversations_prefix(), do: "ctl/group_conversations/"

  def ctl_group_conversations_prefix(group_id), do: "ctl/group_conversations/#{group_id}/"

  def ctl_group_conversation_list_prefix(group_id),
    do: "ctl/group_conversation_list/#{group_id}/"

  def ctl_group_conversation_list_entry(group_id, sort_key, conversation_id),
    do:
      ctl_group_conversation_list_prefix(group_id) <>
        sort_key <> "/" <> Crypto.hex(conversation_id) <> ".json"

  def ctl_group_conversation_dir(group_id, conversation_id),
    do: "ctl/group_conversations/#{group_id}/#{conversation_id}/"

  def ctl_group_conversation_meta(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "meta.json"

  def ctl_group_conversation_messages_segments_prefix(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "messages/segments/"

  def ctl_group_conversation_message_segment(group_id, conversation_id, segment_id),
    do:
      ctl_group_conversation_messages_segments_prefix(group_id, conversation_id) <>
        segment_id <> ".jsonl"

  def ctl_group_conversation_message_thread_backup(group_id, conversation_id, segment_id),
    do:
      ctl_group_conversation_dir(group_id, conversation_id) <>
        "migrations/message_threads/" <> segment_id <> ".jsonl"

  def ctl_group_conversation_message_segment_index_prefix(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "messages/segment_index/"

  def ctl_group_conversation_message_segment_index(group_id, conversation_id, segment_id),
    do:
      ctl_group_conversation_message_segment_index_prefix(group_id, conversation_id) <>
        segment_id <> ".json"

  def ctl_group_conversation_message_seq_index_prefix(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "messages/seq_index/"

  def ctl_group_conversation_message_seq_index(group_id, conversation_id, seq) do
    seq_id =
      seq
      |> to_string()
      |> String.pad_leading(18, "0")

    ctl_group_conversation_message_seq_index_prefix(group_id, conversation_id) <>
      seq_id <> ".json"
  end

  def ctl_group_conversation_message_idempotency(group_id, conversation_id, source_hash),
    do:
      ctl_group_conversation_dir(group_id, conversation_id) <>
        "idempotency/messages/" <> source_hash <> ".json"

  def ctl_group_conversation_message_identity(group_id, conversation_id, message_hash),
    do:
      ctl_group_conversation_dir(group_id, conversation_id) <>
        "messages/by_id/" <> message_hash <> ".json"

  def ctl_group_conversation_create_request(group_id, request_hash),
    do: "ctl/group_conversation_create_requests/#{group_id}/#{request_hash}.json"

  def ctl_group_conversation_participants_prefix(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "participants/"

  def ctl_group_conversation_participant_states_prefix(group_id, conversation_id),
    do: ctl_group_conversation_dir(group_id, conversation_id) <> "participant_states/"

  def ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id),
    do:
      ctl_group_conversation_participants_prefix(group_id, conversation_id) <>
        Crypto.hex(participant_id) <> "/"

  def ctl_group_conversation_participant_state(group_id, conversation_id, participant_id),
    do:
      ctl_group_conversation_participant_states_prefix(group_id, conversation_id) <>
        Crypto.hex(participant_id) <> ".json"

  def ctl_group_conversation_participant_outbox_segments_prefix(
        group_id,
        conversation_id,
        participant_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "outbox/segments/"

  def ctl_group_conversation_participant_outbox_segment(
        group_id,
        conversation_id,
        participant_id,
        segment_id
      ),
      do:
        ctl_group_conversation_participant_outbox_segments_prefix(
          group_id,
          conversation_id,
          participant_id
        ) <> segment_id <> ".jsonl"

  def ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "deliveries/" <> Crypto.hex(delivery_id) <> "/state.json"

  def ctl_group_conversation_participant_deliveries_prefix(
        group_id,
        conversation_id,
        participant_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "deliveries/"

  def ctl_group_conversation_participant_delivery_status_prefix(
        group_id,
        conversation_id,
        participant_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "delivery_status/"

  def ctl_group_conversation_participant_delivery_status_prefix(
        group_id,
        conversation_id,
        participant_id,
        status
      ),
      do:
        ctl_group_conversation_participant_delivery_status_prefix(
          group_id,
          conversation_id,
          participant_id
        ) <> status <> "/"

  def ctl_group_conversation_participant_delivery_status(
        group_id,
        conversation_id,
        participant_id,
        status,
        delivery_id
      ),
      do:
        ctl_group_conversation_participant_delivery_status_prefix(
          group_id,
          conversation_id,
          participant_id,
          status
        ) <> Crypto.hex(delivery_id) <> ".json"

  def ctl_group_conversation_participant_delivery_attempts_segments_prefix(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "deliveries/" <> Crypto.hex(delivery_id) <> "/attempts/segments/"

  def ctl_group_conversation_participant_event_segments_prefix(
        group_id,
        conversation_id,
        participant_id
      ),
      do:
        ctl_group_conversation_participant_dir(group_id, conversation_id, participant_id) <>
          "events/segments/"

  def ctl_group_conversation_delivery_wakeups_prefix(),
    do: "ctl/group_conversation_delivery_wakeups/"

  def ctl_group_conversation_delivery_wakeups_prefix(group_id),
    do: ctl_group_conversation_delivery_wakeups_prefix() <> group_id <> "/"

  def ctl_group_conversation_delivery_wakeups_prefix(group_id, conversation_id),
    do:
      ctl_group_conversation_delivery_wakeups_prefix(group_id) <>
        Crypto.hex(conversation_id) <> "/"

  def ctl_group_conversation_participant_delivery_wakeup(
        group_id,
        conversation_id,
        participant_id
      ),
      do:
        ctl_group_conversation_delivery_wakeups_prefix(group_id, conversation_id) <>
          Crypto.hex(participant_id) <> ".json"

  def ctl_conversation_pin(group_id, conversation_id),
    do: "ctl/conversation_pins/#{Crypto.hex(group_id)}/#{Crypto.hex(conversation_id)}.json"

  def ctl_conversation_pins_prefix(group_id),
    do: "ctl/conversation_pins/#{Crypto.hex(group_id)}/"

  def ctl_conversation_pins_aggregate(group_id),
    do: ctl_conversation_pins_prefix(group_id) <> "aggregate.json"

  def ctl_task_order_prefix(group_id),
    do: "ctl/task_orders/#{Crypto.hex(group_id)}/"

  def ctl_task_order_aggregate(group_id),
    do: ctl_task_order_prefix(group_id) <> "aggregate.json"

  def ctl_capability_request(group_id, request_id),
    do: "ctl/capability_requests/#{group_id}/#{request_id}.json"

  def ctl_capability_requests_prefix(group_id), do: "ctl/capability_requests/#{group_id}/"

  def ctl_im_connect(group_id, connect_id),
    do: "ctl/im_connects/#{group_id}/#{connect_id}.json"

  def ctl_im_connects_prefix(group_id), do: "ctl/im_connects/#{group_id}/"

  def ctl_im_connects_all_prefix, do: "ctl/im_connects/"

  def ctl_im_slack_thread_binding(group_id, connect_id, channel_id, thread_ts) do
    identity = Enum.join([connect_id, channel_id, thread_ts], ":")
    "ctl/im_slack_thread_bindings/#{group_id}/#{Crypto.hex(identity)}.json"
  end

  def ctl_im_telegram_task_topic(group_id, connect_id, conversation_id),
    do: "ctl/im_telegram_task_topics/#{group_id}/#{connect_id}/#{conversation_id}.json"

  def ctl_im_telegram_topic_route(bot_id, chat_id, topic_id) do
    identity = Enum.join([bot_id, chat_id, topic_id], ":")
    "ctl/im_telegram_topic_routes/#{Crypto.hex(identity)}.json"
  end

  def ctl_im_slack_thread_bindings_prefix(group_id),
    do: "ctl/im_slack_thread_bindings/#{group_id}/"

  def ctl_im_provider_identity(provider, identity),
    do: "ctl/im_provider_identities/#{provider}/#{Crypto.hex(identity)}.json"

  def ctl_im_provider_identities_prefix(provider),
    do: "ctl/im_provider_identities/#{provider}/"

  def ctl_im_slack_command_thread(connect_id, trigger_id),
    do: "ctl/im_slack_command_threads/#{connect_id}/#{Crypto.hex(trigger_id)}.json"

  def ctl_im_slack_event_receipt(connect_id, event_id),
    do: "ctl/im_slack_event_receipts/#{connect_id}/#{Crypto.hex(event_id)}.json"

  def ctl_im_slack_event_receipts_prefix, do: "ctl/im_slack_event_receipts/"

  def ctl_im_slack_thread_route_owner(
        group_id,
        workspace_id,
        channel_id,
        root_thread_ts
      ) do
    identity = Enum.join([workspace_id, channel_id, root_thread_ts], <<0>>)

    "ctl/im_slack_thread_route_owners/#{Crypto.hex(group_id)}/#{Crypto.hex(identity)}.json"
  end

  # Source-compatibility shims for callers that still import the historical
  # S3 key module. These return logical PostgreSQL addresses; CasRecord and
  # Lease dispatch the closed Triage family through TriageRecordStore.
  defdelegate ctl_im_triage_projection_marker(namespace, receipt_ref),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_source_alias(namespace, source_message_ref),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_buckets_prefix(namespace), to: SalixStore.TriageKeys
  defdelegate ctl_im_triage_bucket(namespace, bucket_identity), to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_bucket_seal(namespace, bucket_identity, generation),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_bucket_seals_prefix(namespace), to: SalixStore.TriageKeys
  defdelegate ctl_im_triage_ledger_run(namespace, run_id), to: SalixStore.TriageKeys
  defdelegate ctl_im_triage_ledger_runs_prefix(namespace), to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_run_correlation(
                namespace,
                selector_kind,
                selector_sha256,
                run_id
              ),
              to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_run_correlations_prefix(
                namespace,
                selector_kind,
                selector_sha256
              ),
              to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_run_time_index_entry(namespace, created_at, run_id),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_run_time_index_prefix(namespace), to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_activity_index_entry(
                namespace,
                identity_scope_sha256,
                created_at,
                run_id
              ),
              to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_activity_index_prefix(namespace, identity_scope_sha256),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_replay(namespace, run_id), to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_lifecycle_event(namespace, run_id, event_id),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_lifecycle_events_prefix(namespace, run_id),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_late_result(namespace, run_id, observation_id),
    to: SalixStore.TriageKeys

  defdelegate ctl_im_triage_late_results_prefix(namespace), to: SalixStore.TriageKeys
  defdelegate ctl_im_triage_receipt_recovery_lease(namespace), to: SalixStore.TriageKeys

  def ctl_im_slack_router_status_windows_prefix,
    do: "ctl/im_slack_router_status_windows/"

  def ctl_im_slack_router_status_window(connect_id),
    do: ctl_im_slack_router_status_windows_prefix() <> Crypto.hex(connect_id) <> ".json"

  def ctl_im_wechat_quote(connect_id, message_id),
    do: "ctl/im_wechat_quotes/#{Crypto.hex(connect_id)}/#{Crypto.hex(message_id)}.json"

  def ctl_im_wechat_event_receipt(connect_id, event_id),
    do: "ctl/im_wechat_event_receipts/#{connect_id}/#{Crypto.hex(event_id)}.json"

  def ctl_im_wechat_poll_lease(connect_id),
    do: "ctl/im_wechat_poll_leases/#{connect_id}.json"

  def ctl_im_telegram_event_receipt(connect_id, event_id),
    do: "ctl/im_telegram_event_receipts/#{connect_id}/#{Crypto.hex(event_id)}.json"

  def ctl_im_feishu_event_receipt(connect_id, message_id),
    do: "ctl/im_feishu_event_receipts/#{connect_id}/#{Crypto.hex(message_id)}.json"

  def ctl_im_feishu_thread_participation(group_id, connect_id, chat_id, thread_id) do
    identity = Enum.join([connect_id, chat_id, thread_id], ":")
    "ctl/im_feishu_thread_participation/#{group_id}/#{Crypto.hex(identity)}.json"
  end

  def ctl_im_feishu_thread_participation_prefix(group_id),
    do: "ctl/im_feishu_thread_participation/#{group_id}/"

  def ctl_im_telegram_chat(connect_id, chat_id),
    do: "ctl/im_telegram_chats/#{connect_id}/#{Crypto.hex(chat_id)}.json"

  def ctl_im_telegram_chats_prefix(connect_id), do: "ctl/im_telegram_chats/#{connect_id}/"

  def ctl_im_telegram_user(connect_id, user_id),
    do: "ctl/im_telegram_users/#{connect_id}/#{Crypto.hex(user_id)}.json"

  def ctl_im_telegram_users_prefix(connect_id), do: "ctl/im_telegram_users/#{connect_id}/"

  def ctl_im_feishu_chat(connect_id, chat_id),
    do: "ctl/im_feishu_chats/#{connect_id}/#{Crypto.hex(chat_id)}.json"

  def ctl_im_feishu_chats_prefix(connect_id), do: "ctl/im_feishu_chats/#{connect_id}/"

  def ctl_im_feishu_user(connect_id, open_id),
    do: "ctl/im_feishu_users/#{connect_id}/#{Crypto.hex(open_id)}.json"

  def ctl_im_feishu_users_prefix(connect_id), do: "ctl/im_feishu_users/#{connect_id}/"

  def ctl_mcp_system_definitions_prefix, do: "ctl/system/mcp/definitions/"

  def ctl_mcp_tenant_definitions_prefix(tenant_id),
    do: "ctl/tenants/#{tenant_id}/mcp/definitions/"

  def ctl_mcp_tenant_groups_prefix(tenant_id),
    do: "ctl/tenants/#{tenant_id}/groups/"

  def ctl_mcp_definition(tenant_id, mcp_id) when tenant_id in [nil, ""],
    do: ctl_mcp_system_definitions_prefix() <> "#{mcp_id}/state.json"

  def ctl_mcp_definition(tenant_id, mcp_id),
    do: ctl_mcp_tenant_definitions_prefix(tenant_id) <> "#{mcp_id}/state.json"

  def ctl_mcp_group_bindings_prefix(tenant_id, group_id),
    do: "ctl/tenants/#{tenant_id}/groups/#{group_id}/mcp/bindings/"

  def ctl_mcp_group_binding(tenant_id, group_id, binding_id),
    do: ctl_mcp_group_bindings_prefix(tenant_id, group_id) <> "#{binding_id}/state.json"

  def ctl_mcp_connection(tenant_id, group_id, binding_id),
    do: ctl_mcp_group_bindings_prefix(tenant_id, group_id) <> "#{binding_id}/connection.json"

  def lease(node_id, agent_id), do: "ctl/leases/#{node_id}/#{agent_id}"
  def lease_node_prefix(node_id), do: "ctl/leases/#{node_id}/"
  def lease_prefix, do: "ctl/leases/"

  def timer(agent_id, session_id, timer_id, minute_bucket),
    do:
      "ctl/timers/#{minute_bucket}/#{Crypto.hex(agent_id)}--#{Crypto.hex(session_id)}--#{Crypto.hex(timer_id)}.json"

  def timer_minute_prefix(minute_bucket), do: "ctl/timers/#{minute_bucket}/"

  @doc "Parent prefix of every minute bucket, for a delimited bucket probe."
  def timers_prefix, do: "ctl/timers/"

  @spec singleton(:recovery | :metering | :migration | :timers | :schedules) :: String.t()
  def singleton(name) when name in [:recovery, :metering, :migration, :timers, :schedules],
    do: "ctl/singletons/#{name}.json"

  @doc "Registry prefix for sweeping all known agents."
  def ctl_agents_prefix, do: "ctl/agents/"

  def ctl_agents_prefix_for_tenant(tenant_id),
    do: ctl_agents_prefix() <> Ids.agent_id_prefix_for_tenant!(tenant_id)

  def ctl_agents_prefix_for_group(group_id),
    do: ctl_agents_prefix() <> Ids.agent_id_prefix_for_group!(group_id)

  def ctl_agent_worker_tool_idempotency(group_id, identity_hash),
    do: "ctl/agent_worker_tool_idempotency/#{group_id}/#{identity_hash}.json"

  def ctl_agent_worker_tool_idempotency_prefix(group_id),
    do: "ctl/agent_worker_tool_idempotency/#{group_id}/"

  # ---- schedules ----

  def schedule(id), do: "ctl/schedules/#{id}.json"
  def schedule_prefix, do: "ctl/schedules/"
  def schedule_run(id, scheduled_for), do: "ctl/schedule_runs/#{id}/#{scheduled_for}.json"

  # ---- calendars ----

  def ctl_calendar_dir(group_id, calendar_id),
    do: "ctl/calendars/#{group_id}/#{calendar_id}/"

  def ctl_calendar(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "calendar.json"

  def ctl_calendars_prefix(group_id), do: "ctl/calendars/#{group_id}/"

  def ctl_calendar_ensure(group_id, digest),
    do: ctl_calendars_prefix(group_id) <> "_indexes/by_identity/#{digest}.json"

  def ctl_calendar_sources_prefix(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "sources/"

  def ctl_calendar_source(group_id, calendar_id, source_id),
    do: ctl_calendar_sources_prefix(group_id, calendar_id) <> "#{source_id}.json"

  def ctl_calendar_source_lease(group_id, calendar_id, source_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "source_leases/#{source_id}.json"

  def ctl_calendar_items_prefix(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "items/"

  def ctl_calendar_item(group_id, calendar_id, item_id),
    do: ctl_calendar_items_prefix(group_id, calendar_id) <> "#{item_id}.json"

  def ctl_calendar_query_month_prefix(group_id, calendar_id, month),
    do: ctl_calendar_dir(group_id, calendar_id) <> "query_index/month/#{month}/"

  def ctl_calendar_query_month(group_id, calendar_id, month, item_id),
    do: ctl_calendar_query_month_prefix(group_id, calendar_id, month) <> "#{item_id}.json"

  def ctl_calendar_query_recurring_prefix(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "query_index/recurring/"

  def ctl_calendar_query_recurring(group_id, calendar_id, item_id),
    do: ctl_calendar_query_recurring_prefix(group_id, calendar_id) <> "#{item_id}.json"

  def ctl_calendar_query_spanning_prefix(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "query_index/spanning/"

  def ctl_calendar_query_spanning(group_id, calendar_id, item_id),
    do: ctl_calendar_query_spanning_prefix(group_id, calendar_id) <> "#{item_id}.json"

  # ---- Comma-local item indexes ----
  # Owner/time markers bound a personal Feed query to one principal without
  # scanning the whole group Calendar. The marker filename is the item id; its
  # body is empty. Markers are rebuildable and are never authorization authority:
  # every Feed result revalidates the current item `owner_principal_ref`.

  def ctl_calendar_query_owner_prefix(group_id, calendar_id, subject_digest),
    do: ctl_calendar_dir(group_id, calendar_id) <> "query_index/owner/#{subject_digest}/"

  def ctl_calendar_query_owner_month_prefix(group_id, calendar_id, subject_digest, month),
    do:
      ctl_calendar_query_owner_prefix(group_id, calendar_id, subject_digest) <> "month/#{month}/"

  def ctl_calendar_query_owner_month(group_id, calendar_id, subject_digest, month, item_id),
    do:
      ctl_calendar_query_owner_month_prefix(group_id, calendar_id, subject_digest, month) <>
        "#{item_id}.json"

  def ctl_calendar_retirements_prefix(group_id, calendar_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "retirements/"

  def ctl_calendar_retirements_source_prefix(group_id, calendar_id, source_id),
    do: ctl_calendar_retirements_prefix(group_id, calendar_id) <> "#{source_id}/"

  def ctl_calendar_retirements_generation_prefix(
        group_id,
        calendar_id,
        source_id,
        generation
      ),
      do:
        ctl_calendar_retirements_source_prefix(group_id, calendar_id, source_id) <>
          "#{calendar_generation_key(generation)}/"

  def ctl_calendar_retirement(group_id, calendar_id, source_id, generation, link_id),
    do:
      ctl_calendar_retirements_generation_prefix(group_id, calendar_id, source_id, generation) <>
        "#{link_id}.json"

  defp calendar_generation_key(generation) when is_integer(generation) and generation >= 0,
    do: generation |> Integer.to_string() |> String.pad_leading(20, "0")

  def ctl_calendar_source_members_prefix(group_id, calendar_id, source_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "source_members/#{source_id}/"

  def ctl_calendar_source_member(group_id, calendar_id, source_id, item_id),
    do: ctl_calendar_source_members_prefix(group_id, calendar_id, source_id) <> "#{item_id}.json"

  def ctl_calendar_link_members_prefix(group_id, calendar_id, link_id),
    do: ctl_calendar_dir(group_id, calendar_id) <> "link_members/#{link_id}/"

  def ctl_calendar_link_member(group_id, calendar_id, link_id, item_id),
    do: ctl_calendar_link_members_prefix(group_id, calendar_id, link_id) <> "#{item_id}.json"

  def ctl_calendar_context(group_id, calendar_id, link_id, recurrence_digest),
    do:
      ctl_calendar_dir(group_id, calendar_id) <>
        "contexts/#{link_id}/#{recurrence_digest}.json"

  def ctl_calendar_item_by_external_locator(group_id, calendar_id, digest),
    do: ctl_calendar_dir(group_id, calendar_id) <> "indexes/by_external_locator/#{digest}.json"

  def ctl_calendar_link_by_scheduling_identity(group_id, calendar_id, digest),
    do: ctl_calendar_dir(group_id, calendar_id) <> "indexes/by_scheduling_identity/#{digest}.json"

  def ctl_task_calendar_changes_prefix(group_id),
    do: "ctl/task_calendar_changes/#{group_id}/"

  def ctl_task_calendar_change(group_id, change_id),
    do: ctl_task_calendar_changes_prefix(group_id) <> "#{change_id}.json"

  def ctl_task_calendar_change_state(group_id, digest),
    do: "ctl/task_calendar_change_states/#{group_id}/#{digest}.json"

  def ctl_task_calendar_repair_track(group_id),
    do: "ctl/task_calendar_repair_tracks/#{group_id}.json"

  # ---- meeting plans ----

  def ctl_meeting_plans_root_prefix, do: "ctl/meeting_plans/"

  def ctl_meeting_plans_dir(group_id), do: ctl_meeting_plans_root_prefix() <> "#{group_id}/"

  def ctl_meeting_plans_prefix(group_id),
    do: ctl_meeting_plans_dir(group_id) <> "plans/"

  def ctl_meeting_plan(group_id, meeting_plan_id),
    do: ctl_meeting_plans_prefix(group_id) <> "#{meeting_plan_id}.json"

  def ctl_meeting_plan_by_occurrence(group_id, occurrence_digest),
    do: ctl_meeting_plans_dir(group_id) <> "indexes/by_occurrence/#{occurrence_digest}.json"

  def ctl_meeting_plans_by_scheduling_link_prefix(group_id, calendar_id, link_id),
    do:
      ctl_meeting_plans_dir(group_id) <>
        "indexes/by_scheduling_link/#{calendar_id}/#{link_id}/"

  def ctl_meeting_plan_by_scheduling_link(group_id, calendar_id, link_id, meeting_plan_id),
    do:
      ctl_meeting_plans_by_scheduling_link_prefix(group_id, calendar_id, link_id) <>
        "#{meeting_plan_id}.json"

  # ---- bridge / IM ----

  def bridge_lease(tenant, platform), do: "ctl/bridge/#{tenant}/#{platform}/lease.json"

  def ctl_integration_materialization_lease(group_id),
    do: "ctl/integration_materializations/#{Crypto.hex(group_id)}/lease.json"

  def ctl_integration_materialization(group_id, identity),
    do:
      "ctl/integration_materializations/#{Crypto.hex(group_id)}/records/#{Crypto.hex(identity)}.json"

  def bridge_receipt(tenant, platform, external_id),
    do: "ctl/bridge/#{tenant}/#{platform}/receipts/#{Crypto.hex(external_id)}.json"

  def bridge_cursor(tenant, platform), do: "ctl/bridge/cursors/#{tenant}/#{platform}.json"

  def oauth_connection(id), do: "ctl/oauth/connections/#{id}.json"

  # ---- devices and current connector runs ----

  def ctl_group_devices_prefix(tenant_id, group_id),
    do: "ctl/tenants/#{tenant_id}/groups/#{group_id}/devices/"

  def ctl_group_device(tenant_id, group_id, device_id),
    do: ctl_group_devices_prefix(tenant_id, group_id) <> "#{device_id}.json"

  def connector_run(connector_run_id), do: "ctl/connector_runs/#{connector_run_id}.json"
  def connector_runs_prefix, do: "ctl/connector_runs/"

  def connector_run_by_node(node, connector_run_id),
    do: "ctl/connector_runs_by_node/#{node}/#{connector_run_id}.json"

  # Root of the by-node index, for the recovery fast path: one keys-only LIST
  # yields every {node, connector_run_id} pair without touching record bodies.
  def connector_runs_by_node_all_prefix, do: "ctl/connector_runs_by_node/"

  def connector_runs_by_node_prefix(node), do: "ctl/connector_runs_by_node/#{node}/"

  # ---- Cloud VMs (group-owned runtime/device rows) ----

  def ctl_vm(group_id), do: "ctl/vms/#{group_id}.json"
  def ctl_vms_prefix, do: "ctl/vms/"
  def ctl_vm_worker_release, do: "ctl/vm/worker_release.json"
  def ctl_vm_maintenance, do: "ctl/vm/maintenance.json"

  # Deployment-wide platform cloud-VM provider configuration. Tenants use this
  # only when their `vm` config explicitly follows platform config.
  # Operator-managed (Salix dashboard / admin API), tenant-independent.
  def ctl_vm_default_config, do: "ctl/vm/default_config.json"

  # ---- Group outbound SSH (SalixAgent.SSH) ----

  # The Group's SSH client key (unencrypted PKCS#8 PEM, create-once) and its
  # trust-on-first-use host key database. Group deletion removes the prefix.
  def ctl_group_ssh_prefix(group_id), do: "ctl/ssh/groups/#{group_id}/"
  def ctl_group_ssh_identity(group_id), do: ctl_group_ssh_prefix(group_id) <> "identity.pem"

  def ctl_group_ssh_known_hosts(group_id),
    do: ctl_group_ssh_prefix(group_id) <> "known_hosts.json"

  # ---- site APIs (willow site_doc_namespaces / site_llm_billing) ----

  @doc "Per-agent registry of site document namespaces (willow's agent-DB table; 10-cap)."
  def site_doc_namespaces(agent_id), do: "sitedocs/#{agent_id}/ns.json"

  @doc "One JSON document of a site's document store. Doc keys are S3-safe by validation."
  def site_doc(agent_id, site_name, doc_key),
    do: "sitedocs/#{agent_id}/sites/#{site_name}/#{doc_key}"

  def site_docs_prefix(agent_id, site_name), do: "sitedocs/#{agent_id}/sites/#{site_name}/"

  @doc "Create-once site LLM proxy billing records (willow's site_llm_billing rows)."
  def ctl_site_llm_billing(agent_id, record_id),
    do: "ctl/site_llm_billing/#{agent_id}/#{record_id}.json"

  def ctl_site_llm_billing_prefix(agent_id), do: "ctl/site_llm_billing/#{agent_id}/"

  @doc "Latest product billing/runtime state mirrored from Commaboard."
  def ctl_agent_billing_state(agent_id), do: "ctl/agent_billing_state/#{agent_id}.json"

  # ---- meetings ----

  def meet_agent(group_id), do: "ctl/meeting_agents/#{group_id}.json"
  def meet_agents_prefix, do: "ctl/meeting_agents/"

  @doc "Single state object per meeting; the leadership lease is folded into it."
  def meet_state(id), do: "meet/#{id}/state.json"
  def meet_states_prefix, do: "meet/"

  def ctl_meet_calendar_index(group_id), do: "ctl/meet/calendar/#{group_id}.json"
  def ctl_meet_calendar_prefix, do: "ctl/meet/calendar/"
  def ctl_meet_calendar_scan_cursor, do: "ctl/meet/calendar_autojoin/scan_cursor.json"
  def ctl_meet_calendar_join_cursor, do: "ctl/meet/calendar_autojoin/join_cursor.json"

  def ctl_meet_calendar_enrollments_prefix,
    do: "ctl/meet/calendar_autojoin/enrollments/"

  def ctl_meet_calendar_enrollment(connect_id, fingerprint),
    do:
      ctl_meet_calendar_enrollments_prefix() <>
        Crypto.hex(connect_id) <> "/" <> fingerprint <> ".json"

  def ctl_meet_calendar_projection(group_id),
    do: "ctl/meet/calendar_autojoin/groups/#{group_id}.json"
end
