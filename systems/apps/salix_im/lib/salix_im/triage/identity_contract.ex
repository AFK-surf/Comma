defmodule SalixIM.Triage.IdentityContract do
  @moduledoc "Pure canonical identity contract shared by native Triage boundaries."

  require Logger

  alias SalixIM.Provider.Slack.{API, Addressee}

  alias SalixIM.Triage.{
    AddressingEvidence,
    CanonicalJSON,
    ExpressionContext,
    FileAttachments,
    ProductDecision,
    SourceMode
  }

  alias SalixStore.ULID

  @identity_revision_fields ~w(
    agent_id
    display_name
    persona_revision_sha256
    principal_ref
    role
    source_ref
  )
  @endpoint_revision_fields ~w(
    app_id
    bot_user_id
    connect_generation
    connect_id
    group_id
    inbound_agent_id
    provider
    tenant_id
    workspace_id
  )
  @endpoint_provenance_fields ~w(
    callback_api_app_id
    captured_at_ms
    endpoint_revision_sha256
    fast_path_bot_user_id
    schema
  )
  @clickhouse_provenance_fields ~w(
    cursor_revision
    ingest_at
    message_ts_us
    observed_version
    schema
    table
  )
  @context_fields ~w(
    mention_evidence
    observed_principals
    principal_refs
    remember_forbidden_source_refs
    schema
    self_agent
    self_endpoint
    source_mode
    source_refs
  )
  @self_agent_fields ~w(
    agent_id
    display_name
    identity_revision_sha256
    persona_revision_sha256
    principal_ref
    role
    source_ref
  )
  @self_endpoint_fields ~w(
    bot_id
    bot_user_id
    connect_generation
    connect_id
    display_aliases
    provider
    provider_app_id
    represents_principal_ref
    revision_sha256
    revision_status
    source_ref
    workspace_id
  )
  @observed_principal_fields ~w(
    display_aliases
    evidence_tier
    kind
    principal_ref
    provider
    relation_to_self
    source_refs
  )
  @mention_evidence_fields ~w(
    message_source_ref
    principal_ref
    provider_user_id
    selectors
    source_ref
    source_refs
  )
  @projected_self_agent_fields ~w(display_alias principal_ref role source_ref)
  @projected_self_endpoint_fields ~w(
    display_aliases endpoint_ref provider represents_principal_ref revision_status source_ref
  )
  @projected_mention_evidence_fields ~w(
    message_ref message_source_ref principal_ref selectors source_ref source_refs
  )
  @identity_topics ~w(none self_identity other_agent_identity identity_relation ambiguous)
  @actions ~w(silence reply react delegate remember)
  @sourced_actions ~w(reply delegate remember)
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @private_projection_fields ~w(
    schema
    raw_source_bundle_bytes
    raw_source_bundle_sha256
    raw_context_sha256
    alias_map_bytes
    alias_map_sha256
    projection_policy_sha256
    projected_context_sha256
  )
  @private_bundle_fields ~w(
    schema
    sealed_events
    slack_page
    source_authority
    root_ts
    source_observation
    connect_identity
    product_identity
    product_context
    raw_context
    raw_identity_context
    target_cutoff
  )
  @private_bundle_v5_fields ~w(
    schema
    sealed_events
    source_snapshot
    source_authority
    root_ts
    source_observation
    connect_identity
    product_identity
    product_context
    raw_context
    raw_identity_context
    target_cutoff
  )
  @alias_map_fields ~w(
    principals provider_principals participants sources messages members links project
  )
  @source_authority_fields ~w(
    connect_id connect_generation workspace_id channel_id thread_ts
  )
  @connect_identity_fields ~w(
    provider tenant_id group_id connect_id connect_generation workspace_id
    approved_channel_id inbound_agent_id app_id bot_user_id bot_id
  )
  @product_identity_fields ~w(
    project_id project_status project_archived_at project_salix_group_id
    agent_id agent_project_id salix_agent_id agent_status agent_archived_at
    agent_role agent_name
  )
  @raw_context_fields ~w(
    slack_context team_project_memory answered_recheck identity_context
  )
  @private_bundle_v3_schema "comma.triage-private-source-bundle.v3"
  @private_bundle_v4_schema "comma.triage-private-source-bundle.v4"
  @private_bundle_v5_schema "comma.triage-private-source-bundle.v5"
  @private_bundle_v6_schema "comma.triage-private-source-bundle.v6"
  alias SalixIM.Triage.ChannelBatch

  @private_bundle_v8_schema "comma.triage-private-source-bundle.v8"
  @private_bundle_v7_schema "comma.triage-private-source-bundle.v7"
  @full_thread_bundle_schemas [
    @private_bundle_v6_schema,
    @private_bundle_v7_schema,
    @private_bundle_v8_schema
  ]
  @clickhouse_bundle_schemas [@private_bundle_v5_schema | @full_thread_bundle_schemas]
  @expression_bundle_schemas [@private_bundle_v4_schema | @clickhouse_bundle_schemas]
  @normalized_slack_message_v3_fields ~w(actor_id actor_kind message_ts text source_ref)
  @normalized_slack_message_v4_fields ~w(actor_id actor_kind message_ts reactions text source_ref)
  @normalized_slack_message_v5_fields @normalized_slack_message_v4_fields ++
                                        ~w(message_ts_us observed_version)
  @normalized_slack_message_v7_fields @normalized_slack_message_v5_fields ++ ~w(file_attachments)
  @raw_slack_message_v3_fields ~w(
    ts user text subtype bot_id app_id bot_profile_name blocks actor_kind
  )
  @raw_slack_message_v4_fields ~w(
    ts user text subtype bot_id app_id bot_profile_name blocks actor_kind reactions
  )
  @projected_slack_message_v3_fields ~w(
    actor_kind actor_ref message_ref ordinal source_ref text
  )
  @projected_slack_message_v4_fields ~w(
    actor_kind actor_ref message_ref observed_reactions ordinal source_ref text
  )
  @projected_slack_message_v7_fields @projected_slack_message_v4_fields ++ ~w(file_attachments)
  @observed_reaction_limit 64
  @observed_reaction_count_limit 10_000
  @identity_claim_fields ~w(
    schema
    identity_profile_sha256
    request_selector_sha256
    slack_api_origin_sha256
    source_observation_sha256
  )
  @identity_source_claim_fields ~w(
    schema
    identity_profile_sha256
    request_selector_sha256
    source_origin_sha256
    source_observation_sha256
  )
  @identity_transport_result_fields ~w(
    schema
    kind
    receipt
    canonical_page_bytes
    canonical_page_sha256
    classified_private_messages_sha256
    reason_code
  )
  @identity_transport_result_v2_fields @identity_transport_result_fields ++
                                         ~w(canonical_page_chain_bytes canonical_page_chain_sha256)
  @identity_source_result_fields ~w(
    schema
    kind
    receipt
    canonical_snapshot_bytes
    canonical_snapshot_sha256
    classified_private_messages_sha256
    reason_code
  )
  @clickhouse_read_receipt_fields ~w(
    schema
    operation
    request_selector_sha256
    source_origin_sha256
    outcome
    typed_reason
    canonical_snapshot_sha256
    message_count
    reaction_count
    complete
  )
  @slack_read_receipt_fields ~w(
    schema
    operation
    method
    request_selector_sha256
    slack_api_origin_sha256
    transport_invocation_count
    retry
    redirect
    outcome
    typed_reason
    http_status
    canonical_page_sha256
    message_count
    next_cursor_empty
    slack_request_id_sha256
  )
  @slack_read_receipt_chain_fields @slack_read_receipt_fields ++
                                     ~w(page_budget canonical_page_chain_sha256 rejection exchanges)
  @observed_page_chain_schema "comma.slack-read-page-chain.v1"
  @winning_source_anchor_fields ~w(
    schema generation source_mode sealed_events source_authority
  )
  @identity_profile_fields ~w(
    schema
    provider
    operation
    tenant_id
    group_id
    connect_id
    connect_generation
    workspace_id
    approved_channel_id
    root_ts
    inbound_agent_id
    app_id
    bot_user_id
    bot_id
    endpoint_revision_sha256
    project_id
    project_status
    agent_id
    agent_role
    agent_name
    self_agent_identity_revision_sha256
    slack_api_origin_sha256
  )
  @identity_profile_v2_fields (@identity_profile_fields -- ["slack_api_origin_sha256"]) ++
                                ["source_origin_sha256"]
  # Closed source shapes reject credential fields. Free text may discuss their
  # names; reject assignments with values and known credential literals instead.
  @credential_assignment ~r/(?:authorization|client[_-]?secret|signing[_-]?secret|api[_-]?key|access[_-]?token)["'`]?\s*[:=]\s*["'`]?[^\s"'`,;}\]]/i
  @credential_url_keys ~w(
    authorization auth token access_token refresh_token id_token oauth_token jwt
    api_key apikey key secret client_secret password passwd signature sig pub_secret
    x-amz-signature x-amz-credential x-amz-security-token
    x-goog-signature x-goog-credential googleaccessid awsaccesskeyid
  )
  @raw_uuid ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i
  @raw_uri ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/i
  @slack_mrkdwn_link ~r/<(https?:\/\/[^>|]+)(?:\|[^>]*)?>/i
  @raw_email ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  @raw_path ~r/(?<![\p{L}\p{N}_])\/(?:[^\s\/<>"']+\/)*[^\s<>"']+/u
  @raw_sha256 ~r/\b[0-9a-f]{64}\b/i
  @provider_safe_text_replacements [
    {@raw_email, "@email"},
    {@raw_uuid, "@id"},
    {@raw_sha256, "@hash"},
    {@raw_path, "@path"}
  ]
  @projected_alias ~r/(?<![\p{L}\p{N}_])@(?:self|(?:agent|human|unknown|project|member):[A-Za-z0-9_-]+)\b/u
  @credential_literal_patterns [
    ~r/\bBearer\s+\S+/i,
    ~r/\bxox[baprs]-[A-Za-z0-9-]+\b/i,
    ~r/\bsk-(?:live|test)-[A-Za-z0-9_-]+\b/i,
    ~r/\bsk-[A-Za-z0-9_-]{12,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]
  # Historical callback v1/v2 proofs remain readable after their production
  # reader and producer are removed. This closed allowlist is decoder evidence,
  # not a callable Slack read path.
  @identity_source_modules_v3 [
    "Elixir.BridgeForTeams.TriageContext",
    "Elixir.BridgeForTeams.TriageContext.ProductSource",
    "Elixir.SalixIM.ProviderConnects",
    "Elixir.Salix.Bindings.SlackTriageThreadReader"
  ]
  @identity_source_modules_v4 [
    "Elixir.BridgeForTeams.TriageContext",
    "Elixir.BridgeForTeams.TriageContext.ProductSource",
    "Elixir.SalixIM.ProviderConnects",
    "Elixir.SalixIM.Triage.ExpressionContext",
    "Elixir.Salix.Bindings.SlackTriageThreadReader"
  ]
  @identity_source_modules_v5 [
    "Elixir.BridgeForTeams.TriageContext",
    "Elixir.BridgeForTeams.TriageContext.ProductSource",
    "Elixir.SalixIM.ProviderConnects",
    "Elixir.SalixIM.Triage.ExpressionContext",
    "Elixir.Salix.Bindings.ClickHouseTriageThreadReader"
  ]

  @type recomputed_projection :: %{
          projected_context: map(),
          canonical_bytes: binary(),
          sha256: String.t(),
          bundle_schema: String.t()
        }

  @spec recompute_projected_context(map()) ::
          {:ok, recomputed_projection()}
          | {:error, :identity_projection_invalid | :identity_projection_privacy_rejected}
  def recompute_projected_context(private_projection) when is_map(private_projection) do
    with {:projection_shape, :ok} <-
           {:projection_shape, validate_private_projection_shape(private_projection)},
         {:raw_bundle_decode, {:ok, raw_bundle}} <-
           {:raw_bundle_decode, decode_canonical(private_projection["raw_source_bundle_bytes"])},
         {:alias_map_decode, {:ok, supplied_alias_map}} <-
           {:alias_map_decode, decode_canonical(private_projection["alias_map_bytes"])},
         {:alias_map_shape, true} <-
           {:alias_map_shape, exact_keys?(supplied_alias_map, @alias_map_fields)},
         {:private_bundle, :ok} <- {:private_bundle, validate_private_bundle(raw_bundle)},
         {:raw_hashes, :ok} <-
           {:raw_hashes, validate_raw_hashes(private_projection, raw_bundle)},
         {:projection_registry, {:ok, registry}} <-
           {:projection_registry, rebuild_projection_registry(raw_bundle)},
         {:alias_map_match, true} <-
           {:alias_map_match, registry_alias_map(registry) == supplied_alias_map},
         registry =
           Map.put(registry, :source_visible?, source_visible_projection?(private_projection)),
         {:project_context, {:ok, projected_context}} <-
           {:project_context, project_context(raw_bundle, registry)},
         {:projected_encoding, {:ok, projected_bytes}} <-
           {:projected_encoding, CanonicalJSON.encode(projected_context)},
         projected_sha256 = CanonicalJSON.sha256(projected_bytes),
         {:projected_hash, true} <-
           {:projected_hash, projected_sha256 == private_projection["projected_context_sha256"]},
         {:privacy_boundary, :ok} <-
           {:privacy_boundary, reject_projected_credentials(projected_context)} do
      {:ok,
       %{
         projected_context: projected_context,
         canonical_bytes: projected_bytes,
         sha256: projected_sha256,
         bundle_schema: raw_bundle["schema"]
       }}
    else
      {stage, {:error, :identity_projection_privacy_rejected} = error} ->
        log_projection_recompute_failure(stage, :identity_projection_privacy_rejected)
        error

      {stage, {:error, reason}} when is_atom(reason) ->
        log_projection_recompute_failure(stage, reason)
        {:error, :identity_projection_invalid}

      {stage, _other} ->
        log_projection_recompute_failure(stage, :invalid_result)
        {:error, :identity_projection_invalid}
    end
  end

  def recompute_projected_context(_private_projection),
    do: {:error, :identity_projection_invalid}

  defp log_projection_recompute_failure(stage, reason)
       when is_atom(stage) and is_atom(reason) do
    Logger.warning("triage_identity_projection_recompute_failed stage=#{stage} reason=#{reason}")
  end

  @spec recompute_bound_projection(map(), map(), map(), map()) ::
          {:ok, recomputed_projection()}
          | {:error, :identity_projection_invalid | :identity_projection_privacy_rejected}
  def recompute_bound_projection(
        private_projection,
        claim,
        transport_result,
        winning_source_anchor
      )
      when is_map(private_projection) and is_map(claim) and is_map(transport_result) and
             is_map(winning_source_anchor) do
    with {:ok, recomputed} <- recompute_projected_context(private_projection),
         {:ok, raw_bundle} <- decode_canonical(private_projection["raw_source_bundle_bytes"]),
         :ok <- validate_bound_claim(claim),
         :ok <- validate_bound_transport_result(transport_result, claim),
         :ok <- validate_winning_source_anchor(winning_source_anchor, raw_bundle),
         :ok <- validate_committed_page(raw_bundle, transport_result),
         :ok <-
           validate_bound_claim_material(raw_bundle, private_projection, claim, transport_result) do
      {:ok, recomputed}
    else
      {:error, :identity_projection_privacy_rejected} = error -> error
      _other -> {:error, :identity_projection_invalid}
    end
  end

  def recompute_bound_projection(
        _private_projection,
        _claim,
        _transport_result,
        _winning_source_anchor
      ),
      do: {:error, :identity_projection_invalid}

  @spec validate_bound_decision(map(), map(), map(), map(), map()) ::
          :ok
          | {:error,
             :identity_decision_invalid
             | :identity_projection_invalid
             | :identity_projection_privacy_rejected}
  def validate_bound_decision(decision, projection, claim, transport, anchor),
    do: validate_bound_decision(decision, projection, claim, transport, anchor, :current)

  defp validate_current_assignment(_decision, _context, :replay), do: :ok

  defp validate_current_assignment(decision, context, :current),
    do: SalixIM.Triage.WorkerSelection.validate_intake(decision, context)

  @doc "Validates a saved terminal decision under its frozen historical schema."
  def validate_replayed_bound_decision(decision, projection, claim, transport, anchor),
    do: validate_bound_decision(decision, projection, claim, transport, anchor, :replay)

  defp validate_bound_decision(
         decision,
         private_projection,
         claim,
         transport_result,
         winning_source_anchor,
         mode
       )
       when is_map(private_projection) and is_map(claim) and is_map(transport_result) and
              is_map(winning_source_anchor) do
    with {:ok,
          %{
            projected_context: projected_context,
            bundle_schema: bundle_schema
          }} <-
           recompute_bound_projection(
             private_projection,
             claim,
             transport_result,
             winning_source_anchor
           ),
         {:decision_shape, true} <- {:decision_shape, is_map(decision)},
         {:decision_schema, true} <-
           {:decision_schema, readable_decision_schema?(decision, bundle_schema, mode)},
         {:worker_assignment, :ok} <-
           {:worker_assignment, validate_current_assignment(decision, projected_context, mode)},
         {:projected_decision, :ok} <-
           {:projected_decision,
            validate_projected_decision(decision, projected_context, bundle_schema)} do
      :ok
    else
      {:error, :identity_projection_invalid} = error ->
        error

      {:error, :identity_projection_privacy_rejected} = error ->
        error

      {stage, _rejected} ->
        Logger.warning("triage_identity_decision_rejected stage=#{stage}")
        {:error, :identity_decision_invalid}
    end
  end

  defp validate_bound_decision(
         _decision,
         _private_projection,
         _claim,
         _transport_result,
         _winning_source_anchor,
         _mode
       ),
       do: {:error, :identity_projection_invalid}

  defp readable_decision_schema?(
         %{"schema" => "comma.triage-product-decision.v2"},
         @private_bundle_v3_schema,
         :current
       ),
       do: false

  defp readable_decision_schema?(_decision, _bundle_schema, _mode), do: true

  @spec identity_revision_sha256(map()) :: {:ok, String.t()} | {:error, atom()}
  def identity_revision_sha256(identity) when is_map(identity) do
    with true <- exact_keys?(identity, @identity_revision_fields),
         true <- Enum.all?(@identity_revision_fields, &present?(identity[&1])),
         true <- identity["role"] in ["router", "worker"],
         true <- Regex.match?(@sha256, identity["persona_revision_sha256"]),
         {:ok, bytes} <- CanonicalJSON.encode(identity) do
      {:ok, CanonicalJSON.sha256(bytes)}
    else
      _other -> {:error, :invalid_self_agent_identity}
    end
  end

  def identity_revision_sha256(_identity), do: {:error, :invalid_self_agent_identity}

  @spec endpoint_revision_sha256(map()) :: {:ok, String.t()} | {:error, atom()}
  def endpoint_revision_sha256(endpoint) when is_map(endpoint) do
    projection = Map.take(endpoint, @endpoint_revision_fields)

    with true <- Map.keys(projection) |> Enum.sort() == @endpoint_revision_fields,
         true <- projection["provider"] == "slack",
         true <- is_binary(projection["bot_user_id"]),
         true <-
           @endpoint_revision_fields
           |> List.delete("bot_user_id")
           |> Enum.all?(&present?(projection[&1])),
         {:ok, bytes} <- CanonicalJSON.encode(projection) do
      {:ok, CanonicalJSON.sha256(bytes)}
    else
      _other -> {:error, :invalid_endpoint_identity}
    end
  end

  def endpoint_revision_sha256(_endpoint), do: {:error, :invalid_endpoint_identity}

  @spec classify_event_provenance([map()]) ::
          {:ok, :legacy | :identity_enabled}
          | {:error, :mixed_identity_provenance | :invalid_identity_provenance}
  def classify_event_provenance([_ | _] = events) do
    cond do
      not Enum.all?(events, &is_map/1) ->
        {:error, :invalid_identity_provenance}

      Enum.all?(events, &(not Map.has_key?(&1, "endpoint_provenance"))) ->
        {:ok, :legacy}

      Enum.any?(events, &(not Map.has_key?(&1, "endpoint_provenance"))) ->
        {:error, :mixed_identity_provenance}

      Enum.all?(events, &valid_endpoint_provenance?(&1["endpoint_provenance"])) ->
        {:ok, :identity_enabled}

      true ->
        {:error, :invalid_identity_provenance}
    end
  end

  def classify_event_provenance(_events), do: {:error, :invalid_identity_provenance}

  @spec validate_context(map()) :: :ok | {:error, :invalid_identity_context}
  def validate_context(%{"schema" => "comma.triage-identity-model-context.v1"} = context) do
    self_agent = context["self_agent"]
    self_endpoint = context["self_endpoint"]
    observed = context["observed_principals"]
    mentions = context["mention_evidence"]

    with true <- exact_keys?(context, @context_fields),
         true <-
           context["source_mode"] in [
             "callback",
             "clickhouse_etl",
             "historical_thread_reenactment",
             "periodic_patrol",
             "scheduled_recheck"
           ],
         true <- valid_projected_self_agent?(self_agent),
         true <- valid_projected_self_endpoint?(self_endpoint, self_agent),
         true <- is_list(observed) and Enum.all?(observed, &valid_observed_principal?/1),
         true <- unique_by?(observed, & &1["principal_ref"]),
         true <- is_list(mentions) and Enum.all?(mentions, &valid_projected_mention_evidence?/1),
         true <- unique_by?(mentions, &{&1["source_ref"], &1["principal_ref"]}),
         true <- context["principal_refs"] == principal_refs(context),
         true <- Enum.all?(mentions, &(&1["principal_ref"] in context["principal_refs"])),
         true <- Enum.all?(context["principal_refs"], &projected_ref?(&1, "principal://run/")),
         true <-
           context["remember_forbidden_source_refs"] == remember_forbidden_source_refs(context),
         true <- context["source_refs"] == source_refs(context),
         true <- Enum.all?(context["source_refs"], &projected_ref?(&1, "source://run/")),
         true <-
           Enum.all?(
             context["remember_forbidden_source_refs"],
             &(projected_ref?(&1, "principal://run/") or projected_ref?(&1, "source://run/"))
           ) do
      :ok
    else
      _other -> {:error, :invalid_identity_context}
    end
  end

  def validate_context(context) when is_map(context) do
    self_agent = context["self_agent"]
    self_endpoint = context["self_endpoint"]
    observed = context["observed_principals"]
    mentions = context["mention_evidence"]

    with true <- exact_keys?(context, @context_fields),
         true <- context["schema"] == "comma.triage-identity-context.v1",
         true <-
           context["source_mode"] in [
             "callback",
             "clickhouse_etl",
             "historical_thread_reenactment",
             "periodic_patrol",
             "scheduled_recheck"
           ],
         :ok <- validate_self_agent(self_agent),
         :ok <- validate_self_endpoint(self_endpoint, self_agent),
         true <- is_list(observed) and Enum.all?(observed, &valid_observed_principal?/1),
         true <- unique_by?(observed, & &1["principal_ref"]),
         true <- is_list(mentions) and Enum.all?(mentions, &valid_mention_evidence?/1),
         true <- unique_by?(mentions, &{&1["source_ref"], &1["principal_ref"]}),
         true <- Enum.uniq(Enum.map(mentions, & &1["principal_ref"])) |> length() <= 16,
         true <- context["principal_refs"] == principal_refs(context),
         true <-
           context["remember_forbidden_source_refs"] ==
             remember_forbidden_source_refs(context),
         true <- context["source_refs"] == source_refs(context) do
      :ok
    else
      _other -> {:error, :invalid_identity_context}
    end
  end

  def validate_context(_context), do: {:error, :invalid_identity_context}

  @spec principal_refs(map()) :: [String.t()]
  def principal_refs(%{"schema" => "comma.triage-identity-model-context.v1"} = context) do
    ([get_in(context, ["self_agent", "principal_ref"])] ++
       Enum.map(List.wrap(context["observed_principals"]), &map_value(&1, "principal_ref")))
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  def principal_refs(context) when is_map(context) do
    ([get_in(context, ["self_agent", "principal_ref"])] ++
       Enum.map(List.wrap(context["observed_principals"]), &map_value(&1, "principal_ref")) ++
       Enum.map(List.wrap(context["mention_evidence"]), &map_value(&1, "principal_ref")))
    |> canonical_refs()
  end

  def principal_refs(_context), do: []

  @spec remember_forbidden_source_refs(map()) :: [String.t()]
  def remember_forbidden_source_refs(context) when is_map(context) do
    self_agent = context["self_agent"] || %{}
    self_endpoint = context["self_endpoint"] || %{}
    observed = List.wrap(context["observed_principals"])
    mentions = List.wrap(context["mention_evidence"])

    ([
       map_value(self_agent, "principal_ref"),
       map_value(self_agent, "source_ref"),
       map_value(self_endpoint, "source_ref")
     ] ++
       Enum.map(observed, &map_value(&1, "principal_ref")) ++
       Enum.flat_map(mentions, fn mention ->
         [map_value(mention, "principal_ref"), map_value(mention, "source_ref")]
       end))
    |> canonical_refs()
  end

  def remember_forbidden_source_refs(_context), do: []

  @spec source_refs(map()) :: [String.t()]
  def source_refs(context) when is_map(context) do
    self_agent = context["self_agent"] || %{}
    self_endpoint = context["self_endpoint"] || %{}
    observed = List.wrap(context["observed_principals"])
    mentions = List.wrap(context["mention_evidence"])

    ([map_value(self_agent, "source_ref"), map_value(self_endpoint, "source_ref")] ++
       Enum.flat_map(observed, &list_value(&1, "source_refs")) ++
       Enum.flat_map(mentions, fn mention ->
         [map_value(mention, "source_ref") | list_value(mention, "source_refs")]
       end))
    |> canonical_refs()
  end

  def source_refs(_context), do: []

  @spec validate_decision(map(), map()) ::
          :ok | {:error, :invalid_identity_context | :invalid_identity_decision}
  def validate_decision(%{"schema" => schema} = decision, identity_context)
      when schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] do
    with :ok <- validate_context(identity_context),
         true <-
           identity_context["source_mode"] in [
             "callback",
             "clickhouse_etl",
             "periodic_patrol",
             "scheduled_recheck"
           ],
         true <- ProductDecision.structurally_valid?(decision),
         true <- valid_interpretation?(decision["identity_interpretation"], identity_context) do
      :ok
    else
      {:error, :invalid_identity_context} = error -> error
      _other -> {:error, :invalid_identity_decision}
    end
  end

  def validate_decision(decision, identity_context) when is_map(decision) do
    with :ok <- validate_context(identity_context),
         true <- decision["action"] in @actions,
         true <- exact_keys?(decision, decision_fields(decision["action"])),
         true <- valid_action_value?(decision),
         true <- valid_decision_source_refs?(decision),
         true <- valid_interpretation?(decision["identity_interpretation"], identity_context),
         true <- valid_remember_identity_boundary?(decision, identity_context) do
      :ok
    else
      {:error, :invalid_identity_context} = error -> error
      _other -> {:error, :invalid_identity_decision}
    end
  end

  def validate_decision(_decision, identity_context) do
    case validate_context(identity_context) do
      :ok -> {:error, :invalid_identity_decision}
      {:error, :invalid_identity_context} = error -> error
    end
  end

  defp validate_bound_claim(%{"schema" => "comma.triage-source-observation-claim.v2"} = claim) do
    valid? =
      exact_keys?(claim, @identity_source_claim_fields) and
        Enum.all?(@identity_source_claim_fields -- ["schema"], &valid_sha256?(claim[&1]))

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp validate_bound_claim(claim) do
    valid? =
      exact_keys?(claim, @identity_claim_fields) and
        claim["schema"] == "comma.triage-identity-observation-claim.v1" and
        Enum.all?(@identity_claim_fields -- ["schema"], &valid_sha256?(claim[&1]))

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp validate_bound_transport_result(
         %{"schema" => "comma.triage-source-read-result.v1"} = transport_result,
         %{"schema" => "comma.triage-source-observation-claim.v2"} = claim
       ) do
    receipt = transport_result["receipt"]

    valid? =
      exact_keys?(transport_result, @identity_source_result_fields) and
        transport_result["kind"] == "success" and is_nil(transport_result["reason_code"]) and
        is_binary(transport_result["canonical_snapshot_bytes"]) and
        valid_sha256?(transport_result["canonical_snapshot_sha256"]) and
        CanonicalJSON.sha256(transport_result["canonical_snapshot_bytes"]) ==
          transport_result["canonical_snapshot_sha256"] and
        valid_sha256?(transport_result["classified_private_messages_sha256"]) and
        valid_clickhouse_success_receipt?(receipt) and
        receipt["canonical_snapshot_sha256"] ==
          transport_result["canonical_snapshot_sha256"] and
        receipt["request_selector_sha256"] == claim["request_selector_sha256"] and
        receipt["source_origin_sha256"] == claim["source_origin_sha256"]

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp validate_bound_transport_result(transport_result, claim) do
    receipt = transport_result["receipt"]

    valid? =
      valid_transport_result_shape?(transport_result) and
        transport_result["kind"] == "success" and
        is_nil(transport_result["reason_code"]) and
        is_binary(transport_result["canonical_page_bytes"]) and
        valid_sha256?(transport_result["canonical_page_sha256"]) and
        CanonicalJSON.sha256(transport_result["canonical_page_bytes"]) ==
          transport_result["canonical_page_sha256"] and
        valid_sha256?(transport_result["classified_private_messages_sha256"]) and
        valid_success_receipt?(receipt) and
        receipt["canonical_page_sha256"] == transport_result["canonical_page_sha256"] and
        receipt["request_selector_sha256"] == claim["request_selector_sha256"] and
        receipt["slack_api_origin_sha256"] == claim["slack_api_origin_sha256"]

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp valid_clickhouse_success_receipt?(receipt) when is_map(receipt) do
    exact_keys?(receipt, @clickhouse_read_receipt_fields) and
      receipt["schema"] == "comma.clickhouse-thread-read-receipt.v1" and
      receipt["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
      valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["source_origin_sha256"]) and receipt["outcome"] == "success" and
      is_nil(receipt["typed_reason"]) and valid_sha256?(receipt["canonical_snapshot_sha256"]) and
      is_integer(receipt["message_count"]) and receipt["message_count"] in 0..200 and
      is_integer(receipt["reaction_count"]) and receipt["reaction_count"] >= 0 and
      receipt["complete"] == true
  end

  defp valid_clickhouse_success_receipt?(_receipt), do: false

  # A v1 transport result predates the chain schema and no writer in this system
  # produces one carrying a chain receipt. Accepting the combination let a
  # forged v1 result smuggle in a chain receipt whose per-exchange coverage
  # nothing checks, because chain coverage runs only for v2.
  defp valid_transport_result_shape?(
         %{"schema" => "comma.triage-identity-transport-result.v1", "receipt" => receipt} =
           transport_result
       ),
       do:
         exact_keys?(transport_result, @identity_transport_result_fields) and
           unchained_receipt?(receipt)

  defp valid_transport_result_shape?(
         %{
           "schema" => "comma.triage-identity-transport-result.v2",
           "canonical_page_chain_bytes" => chain_bytes,
           "canonical_page_chain_sha256" => chain_sha256,
           "receipt" => receipt
         } = transport_result
       ) do
    exact_keys?(transport_result, @identity_transport_result_v2_fields) and
      is_binary(chain_bytes) and valid_sha256?(chain_sha256) and
      CanonicalJSON.sha256(chain_bytes) == chain_sha256 and
      receipt["canonical_page_chain_sha256"] == chain_sha256
  end

  defp valid_transport_result_shape?(_transport_result), do: false

  defp unchained_receipt?(receipt),
    do: is_map(receipt) and receipt["schema"] != "comma.slack-read-receipt-chain.v1"

  defp valid_success_receipt?(%{"schema" => "comma.slack-read-receipt-chain.v1"} = receipt) do
    exchanges = receipt["exchanges"]
    selectors = if is_list(exchanges), do: Enum.map(exchanges, & &1["request_selector_sha256"])

    exact_keys?(receipt, @slack_read_receipt_chain_fields) and
      valid_success_receipt_base?(receipt) and
      is_integer(receipt["page_budget"]) and
      receipt["page_budget"] in 1..API.observed_page_budget() and
      is_list(exchanges) and exchanges != [] and
      length(exchanges) == receipt["transport_invocation_count"] and
      length(exchanges) <= receipt["page_budget"] and
      valid_sha256?(receipt["canonical_page_chain_sha256"]) and
      is_nil(receipt["rejection"]) and
      Enum.all?(exchanges, fn exchange ->
        # Admission bound every exchange to its own physical selector; the
        # recompute skipped the field entirely, so a page spliced in from a
        # different channel or thread carried no selector this side ever read.
        is_map(exchange) and exchange["schema"] == "comma.slack-read-receipt.v1" and
          exact_keys?(exchange, @slack_read_receipt_fields) and
          exchange["operation"] == receipt["operation"] and exchange["method"] == "GET" and
          exchange["slack_api_origin_sha256"] == receipt["slack_api_origin_sha256"] and
          exchange["transport_invocation_count"] == 1 and exchange["retry"] == false and
          exchange["redirect"] == false and exchange["outcome"] == "success" and
          valid_sha256?(exchange["canonical_page_sha256"]) and
          valid_sha256?(exchange["request_selector_sha256"]) and
          is_integer(exchange["message_count"]) and exchange["message_count"] >= 0 and
          exchange["message_count"] <= API.observed_page_limit()
      end) and
      selectors == Enum.uniq(selectors) and
      List.last(exchanges)["next_cursor_empty"] == true and
      exchanges |> Enum.drop(-1) |> Enum.all?(&(&1["next_cursor_empty"] == false))
  end

  defp valid_success_receipt?(receipt) do
    exact_keys?(receipt, @slack_read_receipt_fields) and
      receipt["schema"] == "comma.slack-read-receipt.v1" and
      receipt["transport_invocation_count"] == 1 and
      valid_success_receipt_base?(receipt)
  end

  defp valid_success_receipt_base?(receipt) do
    # The authorized logical read is bounded; a receipt claiming more objects
    # than that read could ever have returned is a forgery, not a big thread.
    receipt["operation"] in ["conversations.history", "conversations.replies"] and
      receipt["method"] == "GET" and
      valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["slack_api_origin_sha256"]) and
      is_integer(receipt["transport_invocation_count"]) and
      receipt["transport_invocation_count"] >= 1 and receipt["retry"] == false and
      receipt["redirect"] == false and receipt["outcome"] == "success" and
      is_nil(receipt["typed_reason"]) and receipt["http_status"] in 200..299 and
      valid_sha256?(receipt["canonical_page_sha256"]) and
      is_integer(receipt["message_count"]) and receipt["message_count"] >= 0 and
      receipt["message_count"] <= API.observed_logical_limit() and
      receipt["next_cursor_empty"] == true and
      (is_nil(receipt["slack_request_id_sha256"]) or
         valid_sha256?(receipt["slack_request_id_sha256"]))
  end

  defp validate_winning_source_anchor(anchor, raw_bundle) do
    source_mode = anchor["source_mode"]
    sealed_events = anchor["sealed_events"]

    valid? =
      exact_keys?(anchor, @winning_source_anchor_fields) and
        anchor["schema"] == "comma.triage-winning-source-anchor.v1" and
        ULID.valid?(anchor["generation"]) and
        source_mode in [
          "callback",
          "clickhouse_etl",
          "historical_thread_reenactment",
          "periodic_patrol",
          "scheduled_recheck"
        ] and
        sealed_events == raw_bundle["sealed_events"] and
        anchor["source_authority"] == raw_bundle["source_authority"] and
        get_in(raw_bundle, ["raw_identity_context", "source_mode"]) == source_mode and
        is_list(sealed_events) and SourceMode.resolve(sealed_events) == {:ok, source_mode}

    if valid?, do: :ok, else: {:error, :identity_projection_invalid}
  end

  defp validate_committed_page(
         %{"schema" => schema} = raw_bundle,
         transport_result
       )
       when schema in [@private_bundle_v3_schema, @private_bundle_v4_schema] do
    page = raw_bundle["slack_page"]
    receipt = transport_result["receipt"]

    with {:ok, page_bytes} <- CanonicalJSON.encode(page),
         true <- page_bytes == transport_result["canonical_page_bytes"],
         page_sha256 = CanonicalJSON.sha256(page_bytes),
         true <- page_sha256 == transport_result["canonical_page_sha256"],
         true <- page_sha256 == receipt["canonical_page_sha256"],
         true <- receipt["message_count"] == length(page["messages"]),
         true <- page["next_cursor"] == "" and receipt["next_cursor_empty"] == true,
         :ok <- validate_committed_page_chain(page, transport_result) do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp validate_committed_page(
         %{"schema" => schema} = raw_bundle,
         %{"schema" => "comma.triage-source-read-result.v1"} = transport_result
       )
       when schema in @clickhouse_bundle_schemas do
    snapshot = raw_bundle["source_snapshot"]
    receipt = transport_result["receipt"]

    with {:ok, snapshot_bytes} <- CanonicalJSON.encode(snapshot),
         true <- snapshot_bytes == transport_result["canonical_snapshot_bytes"],
         snapshot_sha256 = CanonicalJSON.sha256(snapshot_bytes),
         true <- snapshot_sha256 == transport_result["canonical_snapshot_sha256"],
         true <- snapshot_sha256 == receipt["canonical_snapshot_sha256"],
         true <- receipt["message_count"] == length(snapshot["messages"]),
         true <-
           receipt["reaction_count"] ==
             Enum.reduce(snapshot["messages"], 0, &(length(&1["reactions"]) + &2)),
         true <- snapshot["complete"] == true and receipt["complete"] == true do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  # A chained read is only proof of the frozen page if every exchange it claims
  # is still present, in order, with its own bytes — and if the merged page the
  # context froze is exactly what those pages concatenate to under the ONE merge
  # licence the reader has: Slack repeats the thread parent at the head of every
  # `conversations.replies` page after the first, so that head repeat may
  # collapse. Nothing else may be added, dropped, reordered, or de-duplicated.
  defp validate_committed_page_chain(
         page,
         %{"schema" => "comma.triage-identity-transport-result.v2"} = transport_result
       ) do
    exchanges = get_in(transport_result, ["receipt", "exchanges"])
    operation = get_in(transport_result, ["receipt", "operation"])

    with {:ok, %{"schema" => @observed_page_chain_schema, "pages" => pages}} <-
           decode_canonical(transport_result["canonical_page_chain_bytes"]),
         true <- is_list(pages) and length(pages) == length(exchanges),
         true <- pages_match_exchanges?(pages, exchanges),
         true <- page["messages"] == merge_chain_pages(pages, operation) do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp validate_committed_page_chain(_page, _transport_result), do: :ok

  defp pages_match_exchanges?(pages, exchanges) do
    pages
    |> Enum.zip(exchanges)
    |> Enum.all?(fn {chain_page, exchange} ->
      match?(
        %{"messages" => messages, "next_cursor" => cursor}
        when is_list(messages) and is_binary(cursor),
        chain_page
      ) and
        map_size(chain_page) == 2 and
        CanonicalJSON.sha256(CanonicalJSON.encode!(chain_page)) ==
          exchange["canonical_page_sha256"] and
        length(chain_page["messages"]) == exchange["message_count"] and
        chain_page["next_cursor"] == "" == exchange["next_cursor_empty"]
    end)
  end

  # Byte-identical to `SalixIM.Provider.Slack.API`'s merge. The previous form
  # collapsed an exact repeat at ANY position, so it validated merged pages the
  # reader could never have produced — a duplicate anywhere in the thread was
  # silently accepted as a paging artifact.
  defp merge_chain_pages([first | rest], "conversations.replies") do
    root = List.first(first["messages"])

    Enum.reduce(rest, first["messages"], fn page, merged ->
      merged ++ drop_repeated_root(page["messages"], root)
    end)
  end

  defp merge_chain_pages(pages, _operation), do: Enum.flat_map(pages, & &1["messages"])

  defp drop_repeated_root([head | tail], root) when is_map(root) do
    if head == root, do: tail, else: [head | tail]
  end

  defp drop_repeated_root(messages, _root), do: messages

  defp validate_bound_claim_material(
         %{"schema" => schema} = raw_bundle,
         _private_projection,
         %{"schema" => "comma.triage-source-observation-claim.v2"} = claim,
         transport_result
       )
       when schema in @clickhouse_bundle_schemas do
    messages = raw_bundle["source_snapshot"]["messages"]

    with {:ok, selector_sha256} <- canonical_sha256(request_selector(raw_bundle)),
         true <- selector_sha256 == claim["request_selector_sha256"],
         true <-
           get_in(transport_result, ["receipt", "operation"]) ==
             ChannelBatch.operation(raw_bundle["source_authority"]),
         {:ok, observation_sha256} <- canonical_sha256(raw_bundle["source_observation"]),
         true <- observation_sha256 == claim["source_observation_sha256"],
         {:ok, profile} <- identity_profile_v2(raw_bundle, claim["source_origin_sha256"]),
         true <- exact_keys?(profile, @identity_profile_v2_fields),
         {:ok, profile_sha256} <- canonical_sha256(profile),
         true <- profile_sha256 == claim["identity_profile_sha256"],
         {:ok, classified_sha256} <- canonical_sha256(messages),
         true <-
           classified_sha256 == transport_result["classified_private_messages_sha256"] do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp validate_bound_claim_material(
         raw_bundle,
         _private_projection,
         %{"schema" => "comma.triage-identity-observation-claim.v1"} = claim,
         transport_result
       ) do
    with {:ok, selector_sha256} <- canonical_sha256(request_selector(raw_bundle)),
         true <- selector_sha256 == claim["request_selector_sha256"],
         :ok <- validate_first_exchange_selector(raw_bundle, transport_result),
         true <-
           get_in(transport_result, ["receipt", "operation"]) == request_operation(raw_bundle),
         {:ok, observation_sha256} <- canonical_sha256(raw_bundle["source_observation"]),
         true <- observation_sha256 == claim["source_observation_sha256"],
         {:ok, profile} <- identity_profile(raw_bundle, claim["slack_api_origin_sha256"]),
         true <- exact_keys?(profile, @identity_profile_fields),
         {:ok, profile_sha256} <- canonical_sha256(profile),
         true <- profile_sha256 == claim["identity_profile_sha256"],
         classified =
           Enum.map(raw_bundle["slack_page"]["messages"], fn message ->
             Map.put(
               message,
               "actor_kind",
               historical_actor_kind(message, raw_bundle["connect_identity"])
             )
           end),
         {:ok, classified_sha256} <- canonical_sha256(classified),
         true <-
           classified_sha256 == transport_result["classified_private_messages_sha256"] do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  # Page 1 of a chain is fully recomputable: it is the pinned logical selector
  # narrowed to one capped page at the empty cursor. Binding it here is what
  # stops a page read from a different channel or thread being spliced in as the
  # head of the proof. Later pages carry an opaque Slack cursor this side cannot
  # reproduce, so they stay bound by shape and distinctness only, exactly as
  # admission binds them.
  defp validate_first_exchange_selector(raw_bundle, transport_result) do
    case get_in(transport_result, ["receipt", "exchanges"]) do
      [first | _rest] ->
        with {:ok, expected} <-
               canonical_sha256(API.observed_page_selector(request_selector(raw_bundle), "")),
             true <- first["request_selector_sha256"] == expected do
          :ok
        else
          _mismatch -> {:error, :identity_projection_invalid}
        end

      _unchained ->
        :ok
    end
  end

  defp request_selector(raw_bundle) do
    authority = raw_bundle["source_authority"]
    connect = raw_bundle["connect_identity"]

    if raw_bundle["schema"] in @clickhouse_bundle_schemas do
      ChannelBatch.selector(authority, connect, raw_bundle["sealed_events"])
    else
      slack_request_selector(raw_bundle, authority)
    end
  end

  defp slack_request_selector(raw_bundle, authority) do
    if request_operation(raw_bundle) == "conversations.history" do
      %{
        "operation" => "conversations.history",
        "channel_id" => authority["channel_id"],
        "limit" => 200,
        "cursor" => ""
      }
    else
      %{
        "operation" => "conversations.replies",
        "channel_id" => authority["channel_id"],
        "thread_ts" => authority["thread_ts"],
        "limit" => 200,
        "cursor" => ""
      }
    end
  end

  defp identity_profile_v2(raw_bundle, source_origin_sha256) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]

    with {:ok, endpoint_revision} <- endpoint_revision_sha256(connect) do
      profile = %{
        "schema" => "comma.triage-identity-selector.v2",
        "provider" => connect["provider"],
        "operation" => ChannelBatch.operation(raw_bundle["source_authority"]),
        "tenant_id" => connect["tenant_id"],
        "group_id" => connect["group_id"],
        "connect_id" => connect["connect_id"],
        "connect_generation" => connect["connect_generation"],
        "workspace_id" => connect["workspace_id"],
        "approved_channel_id" => connect["approved_channel_id"],
        "root_ts" => raw_bundle["root_ts"],
        "inbound_agent_id" => connect["inbound_agent_id"],
        "app_id" => connect["app_id"],
        "bot_user_id" => connect["bot_user_id"],
        "bot_id" => connect["bot_id"],
        "endpoint_revision_sha256" => endpoint_revision,
        "project_id" => product["project_id"],
        "project_status" => product["project_status"],
        "agent_id" => product["salix_agent_id"],
        "agent_role" => product["agent_role"],
        "agent_name" => product["agent_name"],
        "self_agent_identity_revision_sha256" =>
          get_in(raw_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"]),
        "source_origin_sha256" => source_origin_sha256
      }

      valid? =
        exact_keys?(profile, @identity_profile_v2_fields) and
          Enum.all?(@identity_profile_v2_fields, &present?(profile[&1])) and
          profile["provider"] == "slack" and
          profile["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
          profile["project_status"] == "active" and
          profile["agent_role"] in ["router", "worker"] and
          Enum.all?(
            ~w(endpoint_revision_sha256 self_agent_identity_revision_sha256 source_origin_sha256),
            &valid_sha256?(profile[&1])
          )

      if valid?, do: {:ok, profile}, else: {:error, :identity_projection_invalid}
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp identity_profile(raw_bundle, slack_api_origin_sha256) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]
    operation = request_operation(raw_bundle)

    with {:ok, endpoint_revision} <- endpoint_revision_sha256(connect) do
      profile = %{
        "schema" => "comma.triage-identity-selector.v1",
        "provider" => connect["provider"],
        "operation" => operation,
        "tenant_id" => connect["tenant_id"],
        "group_id" => connect["group_id"],
        "connect_id" => connect["connect_id"],
        "connect_generation" => connect["connect_generation"],
        "workspace_id" => connect["workspace_id"],
        "approved_channel_id" => connect["approved_channel_id"],
        "root_ts" => raw_bundle["root_ts"],
        "inbound_agent_id" => connect["inbound_agent_id"],
        "app_id" => connect["app_id"],
        "bot_user_id" => connect["bot_user_id"],
        "bot_id" => connect["bot_id"],
        "endpoint_revision_sha256" => endpoint_revision,
        "project_id" => product["project_id"],
        "project_status" => product["project_status"],
        "agent_id" => product["salix_agent_id"],
        "agent_role" => product["agent_role"],
        "agent_name" => product["agent_name"],
        "self_agent_identity_revision_sha256" =>
          get_in(raw_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"]),
        "slack_api_origin_sha256" => slack_api_origin_sha256
      }

      if exact_keys?(profile, @identity_profile_fields) and
           Enum.all?(@identity_profile_fields, &present?(profile[&1])) and
           profile["provider"] == "slack" and
           profile["operation"] in ["conversations.history", "conversations.replies"] and
           profile["project_status"] == "active" and
           profile["agent_role"] in ["router", "worker"] and
           Enum.all?(
             ~w(endpoint_revision_sha256 self_agent_identity_revision_sha256 slack_api_origin_sha256),
             &valid_sha256?(profile[&1])
           ) do
        {:ok, profile}
      else
        {:error, :identity_projection_invalid}
      end
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp request_operation(%{"root_ts" => "__channel__"}), do: "conversations.history"
  defp request_operation(_raw_bundle), do: "conversations.replies"

  defp canonical_sha256(value) do
    with {:ok, bytes} <- CanonicalJSON.encode(value) do
      {:ok, CanonicalJSON.sha256(bytes)}
    end
  end

  defp regex_matches(regex, value) do
    regex
    |> Regex.scan(value, capture: :first)
    |> Enum.map(&hd/1)
  end

  defp validate_private_projection_shape(projection) do
    policy = %{
      "schema" => "comma.triage-identity-projection-policy.v1",
      "target" => "provider_safe_context"
    }

    with true <-
           exact_keys?(Map.delete(projection, "raw_deny_literals"), @private_projection_fields),
         true <- projection["schema"] == "comma.triage-private-projection-control.v1",
         true <- is_binary(projection["raw_source_bundle_bytes"]),
         true <- is_binary(projection["alias_map_bytes"]),
         true <-
           Enum.all?(
             ~w(raw_source_bundle_sha256 raw_context_sha256 alias_map_sha256 projection_policy_sha256 projected_context_sha256),
             &valid_sha256?(projection[&1])
           ),
         true <-
           CanonicalJSON.sha256(projection["raw_source_bundle_bytes"]) ==
             projection["raw_source_bundle_sha256"],
         true <-
           CanonicalJSON.sha256(projection["alias_map_bytes"]) == projection["alias_map_sha256"],
         {:ok, policy_bytes} <- CanonicalJSON.encode(policy),
         true <-
           CanonicalJSON.sha256(policy_bytes) == projection["projection_policy_sha256"] or
             source_visible_projection?(projection) do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  # The policy identifies how a durable snapshot was encoded; it is not an
  # independent security authority. Keep v1 decoding for already accepted work.
  defp source_visible_projection?(projection) do
    {:ok, bytes} =
      CanonicalJSON.encode(%{
        "schema" => "comma.triage-identity-projection-policy.v2",
        "target" => "authorized_source_context"
      })

    projection["projection_policy_sha256"] == CanonicalJSON.sha256(bytes)
  end

  defp validate_raw_hashes(projection, raw_bundle) do
    with {:ok, raw_context_bytes} <- CanonicalJSON.encode(raw_bundle["raw_context"]),
         true <- CanonicalJSON.sha256(raw_context_bytes) == projection["raw_context_sha256"] do
      :ok
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp decode_canonical(bytes) when is_binary(bytes) do
    with {:ok, value} when is_map(value) <- Jason.decode(bytes),
         {:ok, ^bytes} <- CanonicalJSON.encode(value) do
      {:ok, value}
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp validate_private_bundle(bundle) do
    case do_validate_private_bundle(bundle) do
      :ok ->
        if contains_credential?(bundle),
          do: {:error, :identity_projection_privacy_rejected},
          else: :ok

      {:error, :identity_projection_invalid} = error ->
        error
    end
  end

  defp do_validate_private_bundle(bundle) do
    raw_context = bundle["raw_context"]
    authority = bundle["source_authority"]
    connect = bundle["connect_identity"]
    product = bundle["product_identity"]
    events = bundle["sealed_events"]
    bundle_schema = bundle["schema"]

    with {:bundle_shape, true} <- {:bundle_shape, valid_private_bundle_shape?(bundle)},
         {:bundle_schema, true} <- {:bundle_schema, valid_private_bundle_schema?(bundle)},
         {:source_authority, true} <-
           {:source_authority, valid_source_authority?(authority)},
         {:connect_shape, true} <-
           {:connect_shape,
            exact_keys_with_diagnostic?(connect, @connect_identity_fields, :connect_shape)},
         {:connect_projection, true} <-
           {:connect_projection, validate_connect_projection(connect, authority)},
         {:product_shape, true} <-
           {:product_shape, exact_keys?(product, @product_identity_fields)},
         {:product_projection, true} <-
           {:product_projection, validate_product_projection(product, connect)},
         {:thread_root, true} <- {:thread_root, bundle["root_ts"] == authority["thread_ts"]},
         {:source_observation, true} <-
           {:source_observation,
            valid_source_observation?(bundle["source_observation"], bundle_schema)},
         {:sealed_events, true} <-
           {:sealed_events,
            is_list(events) and events != [] and Enum.all?(events, &valid_sealed_event?/1)},
         {:event_authority, true} <-
           {:event_authority, events_match_authority?(events, authority, connect)},
         {:target_cutoff, true} <-
           {:target_cutoff, valid_target_cutoff?(bundle["target_cutoff"], events)},
         {:source_snapshot, true} <- {:source_snapshot, valid_private_source_snapshot?(bundle)},
         {:raw_context_shape, true} <-
           {:raw_context_shape, exact_keys?(raw_context, raw_context_fields(bundle_schema))},
         {:raw_identity_match, true} <-
           {:raw_identity_match,
            raw_context["identity_context"] == bundle["raw_identity_context"]},
         {:raw_memory_match, true} <-
           {:raw_memory_match, raw_context["team_project_memory"] == bundle["product_context"]},
         {:identity_context, :ok} <-
           {:identity_context, validate_context(bundle["raw_identity_context"])},
         {:identity_authority, true} <-
           {:identity_authority,
            raw_identity_matches_authority?(bundle["raw_identity_context"], connect, product)},
         {:raw_memory, true} <-
           {:raw_memory, valid_raw_memory?(bundle["product_context"], product)},
         {:raw_slack_context, true} <-
           {:raw_slack_context,
            valid_raw_slack_context?(raw_context["slack_context"], bundle_schema)},
         {:source_snapshot_match, true} <-
           {:source_snapshot_match,
            raw_slack_matches_source_snapshot?(raw_context["slack_context"], bundle)},
         {:answered_recheck, true} <-
           {:answered_recheck, valid_answered_recheck?(raw_context["answered_recheck"], bundle)} do
      :ok
    else
      {stage, {:error, reason}} when is_atom(reason) ->
        log_private_bundle_failure(stage, reason)
        {:error, :identity_projection_invalid}

      {stage, _other} ->
        log_private_bundle_failure(stage, :invalid_result)
        {:error, :identity_projection_invalid}
    end
  end

  defp valid_private_bundle_shape?(%{"schema" => @private_bundle_v3_schema} = bundle),
    do: exact_keys?(bundle, @private_bundle_fields)

  defp valid_private_bundle_shape?(%{"schema" => @private_bundle_v4_schema} = bundle),
    do: exact_keys?(bundle, @private_bundle_fields)

  defp valid_private_bundle_shape?(%{"schema" => schema} = bundle)
       when schema in @clickhouse_bundle_schemas,
       do: exact_keys?(bundle, @private_bundle_v5_fields)

  defp valid_private_bundle_shape?(_bundle), do: false

  defp valid_private_bundle_schema?(%{"schema" => schema}),
    do: schema in [@private_bundle_v3_schema | @expression_bundle_schemas]

  defp valid_private_bundle_schema?(_bundle), do: false

  defp valid_private_source_snapshot?(%{
         "schema" => @private_bundle_v3_schema,
         "slack_page" => page
       }),
       do: valid_slack_page?(page, @private_bundle_v3_schema)

  defp valid_private_source_snapshot?(%{
         "schema" => @private_bundle_v4_schema,
         "slack_page" => page
       }),
       do: valid_slack_page?(page, @private_bundle_v4_schema)

  defp valid_private_source_snapshot?(%{
         "schema" => schema,
         "source_snapshot" => snapshot
       })
       when schema in @clickhouse_bundle_schemas do
    expected_schema =
      case schema do
        @private_bundle_v8_schema -> "comma.triage-clickhouse-channel-snapshot.v1"
        @private_bundle_v7_schema -> "comma.triage-clickhouse-thread-snapshot.v2"
        _ -> "comma.triage-clickhouse-thread-snapshot.v1"
      end

    is_map(snapshot) and snapshot["schema"] == expected_schema and
      valid_clickhouse_snapshot?(snapshot)
  end

  defp valid_private_source_snapshot?(_bundle), do: false

  defp log_private_bundle_failure(stage, reason) when is_atom(stage) and is_atom(reason) do
    Logger.warning("triage_identity_private_bundle_failed stage=#{stage} reason=#{reason}")
  end

  defp exact_keys_with_diagnostic?(value, expected, stage)
       when is_list(expected) and is_atom(stage) do
    actual = if is_map(value), do: Map.keys(value), else: []
    valid? = Enum.sort(actual) == Enum.sort(expected)

    unless valid? do
      missing = expected -- actual
      extra = actual -- expected

      Logger.warning(
        "triage_identity_shape_mismatch stage=#{stage} missing=#{Enum.join(missing, ",")} extra=#{Enum.join(extra, ",")}"
      )
    end

    valid?
  end

  defp validate_connect_projection(connect, authority) do
    connect["provider"] == "slack" and
      Enum.all?(@connect_identity_fields, fn field ->
        field in ["bot_user_id", "bot_id"] or present?(connect[field])
      end) and is_binary(connect["bot_user_id"]) and is_binary(connect["bot_id"]) and
      connect["connect_id"] == authority["connect_id"] and
      connect["connect_generation"] == authority["connect_generation"] and
      connect["workspace_id"] == authority["workspace_id"] and
      connect["approved_channel_id"] == authority["channel_id"]
  end

  defp valid_source_authority?(authority) when is_map(authority) do
    keys = Map.keys(authority) |> Enum.sort()

    keys in [
      Enum.sort(@source_authority_fields),
      Enum.sort(@source_authority_fields ++ ["scope_kind"])
    ] and Enum.all?(@source_authority_fields, &present?(authority[&1])) and
      case authority["scope_kind"] do
        nil -> authority["thread_ts"] != "__channel__"
        "channel" -> authority["thread_ts"] == "__channel__"
        "thread" -> authority["thread_ts"] != "__channel__"
        _invalid -> false
      end
  end

  defp valid_source_authority?(_authority), do: false

  defp validate_product_projection(product, connect) do
    product["project_status"] == "active" and is_nil(product["project_archived_at"]) and
      product["agent_status"] == "active" and is_nil(product["agent_archived_at"]) and
      product["agent_role"] in ["router", "worker"] and
      Enum.all?(
        ~w(project_id project_salix_group_id agent_id agent_project_id salix_agent_id agent_name),
        &present?(product[&1])
      ) and product["project_salix_group_id"] == connect["group_id"] and
      product["agent_project_id"] == product["project_id"] and
      product["salix_agent_id"] == connect["inbound_agent_id"]
  end

  defp valid_source_observation?(
         %{
           "schema" => "comma.triage-source-observation.v1",
           "modules" => modules
         } = observation,
         bundle_schema
       ) do
    expected_modules =
      case bundle_schema do
        @private_bundle_v3_schema -> @identity_source_modules_v3
        @private_bundle_v4_schema -> @identity_source_modules_v4
        schema when schema in @clickhouse_bundle_schemas -> @identity_source_modules_v5
        _invalid -> []
      end

    exact_keys?(observation, ~w(schema modules)) and is_list(modules) and
      Enum.map(modules, & &1["module"]) == expected_modules and
      Enum.all?(modules, fn module ->
        exact_keys?(module, ~w(module object_code_sha256)) and present?(module["module"]) and
          valid_sha256?(module["object_code_sha256"])
      end) and length(modules) == length(Enum.uniq_by(modules, & &1["module"]))
  end

  defp valid_source_observation?(_observation, _bundle_schema), do: false

  @doc "Validates one sealed Slack event before identity projection."
  @spec validate_sealed_event(map()) :: :ok | {:error, :invalid_identity_sealed_event}
  def validate_sealed_event(event) do
    if valid_sealed_event?(event),
      do: :ok,
      else: {:error, :invalid_identity_sealed_event}
  end

  defp valid_sealed_event?(event) when is_map(event) do
    bucket = event["bucket"]

    AddressingEvidence.validate_shape_only(event) == :ok and
      Enum.all?(~w(event_id connect_generation message_ts actor_id text), &is_binary(event[&1])) and
      event["actor_kind"] in ["human", "agent"] and
      event["source_mode"] in [
        "callback",
        "clickhouse_etl",
        "historical_thread_reenactment",
        "periodic_patrol",
        "scheduled_recheck"
      ] and
      is_boolean(event["fast_path"]) and valid_event_bucket?(bucket) and
      valid_endpoint_provenance?(event["endpoint_provenance"]) and
      valid_slack_ts?(event["message_ts"])
  end

  defp valid_sealed_event?(_event), do: false

  defp valid_event_bucket?(bucket) when is_map(bucket) do
    keys = Map.keys(bucket) |> Enum.sort()

    keys in [
      Enum.sort(~w(workspace_id channel_id thread_ts)),
      Enum.sort(~w(workspace_id channel_id thread_ts scope_kind))
    ] and Enum.all?(~w(workspace_id channel_id thread_ts), &present?(bucket[&1])) and
      case bucket["scope_kind"] do
        nil -> true
        "channel" -> bucket["thread_ts"] == "__channel__" or valid_slack_ts?(bucket["thread_ts"])
        "thread" -> bucket["thread_ts"] != "__channel__"
        _invalid -> false
      end
  end

  defp valid_event_bucket?(_bucket), do: false

  defp events_match_authority?(events, authority, connect) do
    with {:ok, endpoint_revision} <- endpoint_revision_sha256(connect) do
      Enum.all?(events, fn event ->
        event["connect_generation"] == authority["connect_generation"] and
          AddressingEvidence.validate(event, connect["connect_id"]) == :ok and
          event_bucket_matches_authority?(event["bucket"], authority) and
          event_provenance_matches_authority?(event, connect, endpoint_revision)
      end)
    else
      _other -> false
    end
  end

  defp event_provenance_matches_authority?(
         %{
           "endpoint_provenance" =>
             %{"schema" => "comma.slack-endpoint-provenance.v1"} = provenance
         },
         connect,
         endpoint_revision
       ) do
    provenance["callback_api_app_id"] == connect["app_id"] and
      provenance["fast_path_bot_user_id"] == connect["bot_user_id"] and
      provenance["endpoint_revision_sha256"] == endpoint_revision
  end

  defp event_provenance_matches_authority?(
         %{
           "source_mode" => "clickhouse_etl",
           "endpoint_provenance" => %{
             "schema" => "comma.slack-clickhouse-etl-provenance.v1"
           }
         },
         _connect,
         _endpoint_revision
       ),
       do: true

  defp event_provenance_matches_authority?(_event, _connect, _endpoint_revision), do: false

  defp event_bucket_matches_authority?(
         %{"scope_kind" => "channel"} = bucket,
         %{"scope_kind" => "channel", "thread_ts" => "__channel__"} = authority
       ) do
    bucket["workspace_id"] == authority["workspace_id"] and
      bucket["channel_id"] == authority["channel_id"] and
      (bucket["thread_ts"] == "__channel__" or valid_slack_ts?(bucket["thread_ts"]))
  end

  defp event_bucket_matches_authority?(bucket, authority) do
    base = %{
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["channel_id"],
      "thread_ts" => authority["thread_ts"]
    }

    bucket == base or
      bucket ==
        Map.put(
          base,
          "scope_kind",
          if(authority["thread_ts"] == "__channel__", do: "channel", else: "thread")
        )
  end

  defp raw_identity_matches_authority?(identity, connect, product) do
    agent = identity["self_agent"]
    endpoint = identity["self_endpoint"]

    with {:ok, endpoint_revision} <- endpoint_revision_sha256(connect) do
      agent["agent_id"] == product["salix_agent_id"] and
        agent["role"] == product["agent_role"] and agent["display_name"] == product["agent_name"] and
        agent["principal_ref"] == "comma-agent://#{product["salix_agent_id"]}" and
        agent["source_ref"] ==
          "bft://projects/#{product["project_id"]}/agents/#{product["agent_id"]}" and
        endpoint["provider"] == "slack" and endpoint["workspace_id"] == connect["workspace_id"] and
        endpoint["connect_id"] == connect["connect_id"] and
        endpoint["connect_generation"] == connect["connect_generation"] and
        endpoint["provider_app_id"] == connect["app_id"] and
        endpoint["bot_user_id"] == connect["bot_user_id"] and
        endpoint["bot_id"] == connect["bot_id"] and
        endpoint["represents_principal_ref"] == agent["principal_ref"] and
        endpoint["revision_sha256"] == endpoint_revision
    else
      _other -> false
    end
  end

  defp valid_target_cutoff?(%{"event_message_timestamps" => timestamps} = cutoff, events) do
    exact_keys?(cutoff, ~w(event_message_timestamps)) and
      timestamps == Enum.map(events, & &1["message_ts"])
  end

  defp valid_target_cutoff?(_cutoff, _events), do: false

  defp valid_slack_page?(%{"messages" => messages, "next_cursor" => ""} = page, bundle_schema) do
    allowed_message_fields =
      case bundle_schema do
        @private_bundle_v3_schema -> @raw_slack_message_v3_fields
        @private_bundle_v4_schema -> @raw_slack_message_v4_fields
        _invalid -> []
      end

    exact_keys?(page, ~w(messages next_cursor)) and is_list(messages) and
      Enum.all?(messages, fn message ->
        is_map(message) and Map.keys(message) -- allowed_message_fields == [] and
          present?(message["ts"]) and is_binary(message["user"] || "") and
          is_binary(message["text"] || "") and valid_slack_ts?(message["ts"]) and
          valid_bundle_reactions?(message, bundle_schema) and
          (is_nil(message["actor_kind"]) or
             message["actor_kind"] in ["agent", "system", "human", "unknown"])
      end)
  end

  defp valid_slack_page?(_page, _bundle_schema), do: false

  defp valid_raw_slack_context?(
         %{"messages" => messages, "source_refs" => refs} = slack,
         @private_bundle_v3_schema
       ) do
    exact_keys?(slack, ~w(messages source_refs)) and is_list(messages) and
      Enum.all?(messages, fn message ->
        exact_keys?(message, @normalized_slack_message_v3_fields) and
          message["actor_kind"] in ["agent", "system", "human", "unknown"] and
          Enum.all?(~w(actor_id message_ts text source_ref), &is_binary(message[&1])) and
          valid_slack_ts?(message["message_ts"])
      end) and refs == Enum.map(messages, & &1["source_ref"])
  end

  defp valid_raw_slack_context?(
         %{
           "messages" => messages,
           "source_refs" => refs,
           "expression_context" => expression_context
         } = slack,
         @private_bundle_v4_schema
       ) do
    exact_keys?(slack, ~w(expression_context messages source_refs)) and is_list(messages) and
      ExpressionContext.valid?(expression_context) and
      Enum.all?(messages, fn message ->
        exact_keys?(message, @normalized_slack_message_v4_fields) and
          message["actor_kind"] in ["agent", "system", "human", "unknown"] and
          Enum.all?(~w(actor_id message_ts text source_ref), &is_binary(message[&1])) and
          valid_slack_ts?(message["message_ts"]) and valid_raw_reactions?(message["reactions"])
      end) and refs == Enum.map(messages, & &1["source_ref"])
  end

  defp valid_raw_slack_context?(
         %{
           "messages" => messages,
           "source_refs" => refs,
           "expression_context" => expression_context
         } = slack,
         schema
       )
       when schema in @clickhouse_bundle_schemas do
    exact_keys?(slack, ~w(expression_context messages source_refs)) and is_list(messages) and
      ExpressionContext.valid?(expression_context) and
      Enum.all?(messages, fn message ->
        exact_keys?(message, normalized_message_fields(schema)) and
          valid_message_files?(message, schema) and
          message["actor_kind"] in ["agent", "system", "human", "unknown"] and
          Enum.all?(~w(actor_id message_ts text source_ref), &is_binary(message[&1])) and
          valid_slack_ts?(message["message_ts"]) and
          is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
          is_integer(message["observed_version"]) and message["observed_version"] >= 0 and
          valid_raw_reactions?(message["reactions"])
      end) and refs == Enum.map(messages, & &1["source_ref"])
  end

  defp valid_raw_slack_context?(_slack, _bundle_schema), do: false

  defp valid_clickhouse_snapshot?(
         %{
           "schema" => schema,
           "complete" => true,
           "messages" => messages
         } = snapshot
       )
       when schema in [
              "comma.triage-clickhouse-thread-snapshot.v1",
              "comma.triage-clickhouse-thread-snapshot.v2",
              "comma.triage-clickhouse-channel-snapshot.v1"
            ] do
    exact_keys?(snapshot, ~w(schema complete messages)) and is_list(messages) and
      length(messages) <= 200 and
      Enum.all?(messages, &valid_clickhouse_snapshot_message?(&1, schema))
  end

  defp valid_clickhouse_snapshot?(_snapshot), do: false

  defp valid_clickhouse_snapshot_message?(message, schema) when is_map(message) do
    expected =
      ~w(ts text subtype user bot_id app_id bot_profile_name actor_kind actor_id message_ts_us observed_version reactions)

    expected =
      if schema != "comma.triage-clickhouse-thread-snapshot.v1",
        do: expected ++ ~w(file_attachments),
        else: expected

    expected =
      if schema == "comma.triage-clickhouse-channel-snapshot.v1",
        do: expected ++ ~w(root_thread_ts),
        else: expected

    exact_keys?(message, expected) and valid_slack_ts?(message["ts"]) and
      (schema != "comma.triage-clickhouse-channel-snapshot.v1" or
         valid_slack_ts?(message["root_thread_ts"])) and
      Enum.all?(
        ~w(ts text subtype user bot_id app_id bot_profile_name actor_kind actor_id),
        &is_binary(message[&1])
      ) and
      message["actor_kind"] in ["agent", "system", "human", "unknown"] and
      is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
      is_integer(message["observed_version"]) and message["observed_version"] >= 0 and
      valid_raw_reactions?(message["reactions"]) and
      (schema == "comma.triage-clickhouse-thread-snapshot.v1" or
         FileAttachments.valid?(message["file_attachments"]))
  end

  defp valid_clickhouse_snapshot_message?(_message, _schema), do: false

  defp normalized_message_fields(@private_bundle_v8_schema),
    do: @normalized_slack_message_v7_fields ++ ~w(root_thread_ts)

  defp normalized_message_fields(@private_bundle_v7_schema),
    do: @normalized_slack_message_v7_fields

  defp normalized_message_fields(_schema), do: @normalized_slack_message_v5_fields

  defp projected_message_fields(@private_bundle_v8_schema),
    do: @projected_slack_message_v7_fields ++ ~w(thread_ref)

  defp projected_message_fields(@private_bundle_v7_schema), do: @projected_slack_message_v7_fields
  defp projected_message_fields(_schema), do: @projected_slack_message_v4_fields

  defp valid_message_files?(message, schema)
       when schema in [@private_bundle_v7_schema, @private_bundle_v8_schema],
       do: FileAttachments.valid?(message["file_attachments"])

  defp valid_message_files?(_message, _schema), do: true

  defp valid_projected_message_files?(message, schema)
       when schema in [@private_bundle_v7_schema, @private_bundle_v8_schema],
       do: FileAttachments.valid_projected?(message["file_attachments"])

  defp valid_projected_message_files?(_message, _schema), do: true

  defp raw_slack_matches_source_snapshot?(raw_slack, bundle) do
    authority = bundle["source_authority"]
    connect = bundle["connect_identity"]

    cutoff =
      bundle["target_cutoff"]["event_message_timestamps"]
      |> Enum.map(&slack_ts_key/1)
      |> Enum.max()

    normalized =
      bundle
      |> private_source_messages()
      |> Enum.map(&normalize_private_source_message(&1, authority, connect, bundle["schema"]))
      |> Enum.sort_by(&slack_ts_key(&1["message_ts"]))
      |> Enum.filter(fn message ->
        bundle["schema"] in @full_thread_bundle_schemas or
          slack_ts_key(message["message_ts"]) <= cutoff
      end)

    case bundle["schema"] do
      @private_bundle_v3_schema ->
        raw_slack == %{
          "messages" => normalized,
          "source_refs" => Enum.map(normalized, & &1["source_ref"])
        }

      schema when schema in @expression_bundle_schemas ->
        base_expression_context =
          Map.put(raw_slack["expression_context"], "observed_reactions", [])

        with {:ok, expression_context} <-
               ExpressionContext.with_observed_reactions(base_expression_context, normalized) do
          raw_slack == %{
            "messages" => normalized,
            "source_refs" => Enum.map(normalized, & &1["source_ref"]),
            "expression_context" => expression_context
          }
        else
          _invalid -> false
        end

      _invalid ->
        false
    end
  end

  defp private_source_messages(%{"schema" => schema} = bundle)
       when schema in @clickhouse_bundle_schemas,
       do: bundle["source_snapshot"]["messages"]

  defp private_source_messages(bundle), do: bundle["slack_page"]["messages"]

  defp normalize_private_source_message(
         message,
         authority,
         connect,
         schema
       )
       when schema in @clickhouse_bundle_schemas do
    normalize_raw_slack_message(
      message,
      ChannelBatch.physical_authority(authority, message),
      connect,
      schema
    )
    |> ChannelBatch.retain_root(message)
    |> Map.put("message_ts_us", message["message_ts_us"])
    |> Map.put("observed_version", message["observed_version"])
    |> then(fn normalized ->
      if schema in [@private_bundle_v7_schema, @private_bundle_v8_schema],
        do: Map.put(normalized, "file_attachments", message["file_attachments"]),
        else: normalized
    end)
  end

  defp normalize_private_source_message(message, authority, connect, schema),
    do: normalize_raw_slack_message(message, authority, connect, schema)

  defp normalize_raw_slack_message(message, authority, connect, @private_bundle_v3_schema) do
    message_ts = trim(message["ts"])

    %{
      "actor_id" => trim(message["actor_id"] || message["user"]),
      "actor_kind" => historical_actor_kind(message, connect),
      "message_ts" => message_ts,
      "text" => trim(message["text"]),
      "source_ref" => slack_source_ref(authority, message_ts)
    }
  end

  defp normalize_raw_slack_message(message, authority, connect, @private_bundle_v4_schema) do
    message_ts = trim(message["ts"])

    %{
      "actor_id" => trim(message["user"]),
      "actor_kind" => historical_actor_kind(message, connect),
      "message_ts" => message_ts,
      "text" => trim(message["text"]),
      "source_ref" => slack_source_ref(authority, message_ts),
      "reactions" => normalize_raw_reactions(message["reactions"] || [])
    }
  end

  defp normalize_raw_slack_message(message, authority, connect, schema)
       when schema in @clickhouse_bundle_schemas do
    message_ts = trim(message["ts"])

    %{
      "actor_id" => trim(message["actor_id"] || message["user"]),
      "actor_kind" => actor_kind(message, connect),
      "message_ts" => message_ts,
      "text" => trim(message["text"]),
      "source_ref" => slack_source_ref(authority, message_ts),
      "reactions" => normalize_raw_reactions(message["reactions"] || [])
    }
  end

  defp valid_bundle_reactions?(message, @private_bundle_v3_schema),
    do: not Map.has_key?(message, "reactions")

  defp valid_bundle_reactions?(message, @private_bundle_v4_schema),
    do: valid_raw_reactions?(message["reactions"] || [])

  defp valid_bundle_reactions?(_message, _bundle_schema), do: false

  defp valid_raw_reactions?(reactions) when is_list(reactions) do
    length(reactions) <= @observed_reaction_limit and
      Enum.all?(reactions, fn reaction ->
        exact_keys?(reaction, ~w(count name)) and present?(reaction["name"]) and
          byte_size(reaction["name"]) <= 100 and
          Regex.match?(~r/\A[a-z0-9_+\-:]+\z/, reaction["name"]) and
          is_integer(reaction["count"]) and
          reaction["count"] in 1..@observed_reaction_count_limit
      end)
  end

  defp valid_raw_reactions?(_reactions), do: false

  defp normalize_raw_reactions(reactions) do
    Enum.map(reactions, &Map.take(&1, ~w(name count)))
  end

  @doc """
  The one Slack actor-kind rule every Triage layer must agree on.

  The reader classifies a raw Slack page, the freeze normalizes it, and this
  module re-derives it during recompute. Each layer used to carry its own copy
  of the rule, and the copies had already drifted — the reader looked at
  `bot_profile` while the recompute looked at `bot_profile_name`, so a bot
  message could classify differently on the two sides of the same proof. Both
  raw and normalized key spellings are accepted here precisely so one rule can
  serve all three.

  The four kinds are `agent`, `system`, `human`, `unknown`. Slack's `app_id`
  identifies the app involved in producing a message, but does not by itself
  prove that the app rather than the named user authored it. Agent authorship
  requires `bot_id`, a bot profile, the connect's own bot user, or an explicit
  closed-decoder classification. The admission side spells the same rule in
  `SalixIM.Provider.Slack.TriageCallbackRouter.agent_authored?/1`.

  `file_share`, `me_message` and `thread_broadcast` are message-body subtypes,
  not evidence of system authorship. Bot evidence still takes precedence and
  a user is still required. Immutable v3/v4 raw-page proofs retain their old
  subtype classification during recompute; current snapshots already contain
  an explicit classified kind, which is never rewritten.
  """
  @spec actor_kind(map(), map()) :: String.t()
  def actor_kind(%{"actor_kind" => kind}, _connect)
      when kind in ["agent", "system", "human", "unknown"],
      do: kind

  def actor_kind(message, connect) when is_map(message) and is_map(connect) do
    cond do
      bot_authored?(message, connect) ->
        "agent"

      present?(message["subtype"]) and
          message["subtype"] not in ~w(file_share me_message thread_broadcast) ->
        "system"

      present?(message["user"] || message["actor_id"]) ->
        "human"

      true ->
        "unknown"
    end
  end

  def actor_kind(_message, _connect), do: "unknown"

  defp bot_authored?(message, connect) do
    user = message["user"] || message["actor_id"]

    message["is_bot"] == true or present?(message["bot_id"]) or
      present?(message["bot_profile_name"]) or is_map(message["bot_profile"]) or
      (present?(user) and user == connect["bot_user_id"])
  end

  # Historical raw-page schemas can omit actor_kind. Recompute their immutable
  # classification, not today's reader policy; otherwise a valid old proof's
  # raw-context comparison and classified-message hash change after upgrade.
  defp historical_actor_kind(%{"actor_kind" => kind}, _connect)
       when kind in ["agent", "system", "human", "unknown"],
       do: kind

  defp historical_actor_kind(message, connect) do
    cond do
      bot_authored?(message, connect) -> "agent"
      present?(message["subtype"]) -> "system"
      present?(message["user"] || message["actor_id"]) -> "human"
      true -> "unknown"
    end
  end

  @doc """
  Historical activity classifier for immutable v3-v5 bundle verification and
  the retired v1 compatibility port. Despite its old name this identifies a
  non-self speaker, NOT semantic completion. Native v6 snapshots and scheduled
  follow-ups never use it to suppress evaluation or resolve an entry.
  """
  @spec answering_participant?(map(), map()) :: boolean()
  def answering_participant?(message, connect) when is_map(message) and is_map(connect) do
    actor_id = trim(message["actor_id"] || message["user"])
    self_bot_user_id = trim(connect["bot_user_id"])

    actor_id != "" and
      case message["actor_kind"] do
        "human" -> true
        "agent" -> self_bot_user_id != "" and actor_id != self_bot_user_id
        _other -> false
      end
  end

  def answering_participant?(_message, _connect), do: false

  defp raw_context_fields(schema) when schema in @full_thread_bundle_schemas,
    do: @raw_context_fields -- ["answered_recheck"]

  defp raw_context_fields(_historical_schema), do: @raw_context_fields

  defp valid_answered_recheck?(nil, %{"schema" => schema})
       when schema in @full_thread_bundle_schemas,
       do: true

  defp valid_answered_recheck?(recheck, bundle) when is_map(recheck) do
    expected_keys =
      if recheck["answered"],
        do: ~w(answered checked_at source_refs answer_source_ref),
        else: ~w(answered checked_at source_refs)

    authority = bundle["source_authority"]
    connect = bundle["connect_identity"]

    messages =
      Enum.map(
        private_source_messages(bundle),
        &normalize_private_source_message(&1, authority, connect, bundle["schema"])
      )

    input_keys = MapSet.new(Enum.map(bundle["sealed_events"], &slack_ts_key(&1["message_ts"])))
    latest = Enum.max(input_keys)

    answer =
      messages
      |> Enum.reject(&MapSet.member?(input_keys, slack_ts_key(&1["message_ts"])))
      |> Enum.filter(
        &(slack_ts_key(&1["message_ts"]) > latest and answering_participant?(&1, connect))
      )
      |> Enum.max_by(&slack_ts_key(&1["message_ts"]), fn -> nil end)

    expected_refs = Enum.map(messages, & &1["source_ref"])

    exact_keys?(recheck, expected_keys) and is_boolean(recheck["answered"]) and
      present?(recheck["checked_at"]) and recheck["source_refs"] == expected_refs and
      recheck["answered"] == not is_nil(answer) and
      if(answer, do: recheck["answer_source_ref"] == answer["source_ref"], else: true)
  end

  defp valid_answered_recheck?(_recheck, _bundle), do: false

  @doc """
  Validates one raw team/project memory against its product identity.

  This is the exact rule the projection verifier applies, exposed so the freeze
  that produces the memory can be tested against the verifier that accepts it.
  """
  @spec valid_raw_memory?(term(), map()) :: boolean()
  def valid_raw_memory?(memory, product) when is_map(memory) do
    project = memory["project"]
    members = memory["members"]
    member_roster = memory["member_roster"]
    facts = memory["facts"]

    exact_keys?(memory, ~w(project members member_roster facts source_refs)) and
      exact_keys?(project, ~w(key name status source_ref)) and
      project["status"] == product["project_status"] and is_list(members) and is_list(facts) and
      valid_member_roster?(member_roster, members) and
      Enum.all?(members, &valid_raw_member?/1) and Enum.all?(facts, &valid_raw_fact?/1) and
      memory["source_refs"] ==
        raw_memory_source_refs(
          project["source_ref"],
          Enum.map(members, & &1["source_ref"]),
          facts
        )
  end

  def valid_raw_memory?(_memory, _product), do: false

  defp valid_member_roster?(roster, members) when is_map(roster) and is_list(members) do
    completeness = roster["completeness"]
    truncated = roster["truncated"]
    limit = roster["limit"]
    returned_count = roster["returned_count"]

    exact_keys?(roster, ~w(completeness truncated limit returned_count)) and
      completeness in ["complete", "truncated"] and is_boolean(truncated) and
      truncated == (completeness == "truncated") and is_integer(limit) and limit in 1..100 and
      is_integer(returned_count) and returned_count == length(members) and
      returned_count in 0..limit
  end

  defp valid_member_roster?(_roster, _members), do: false

  @doc """
  The one derivation of a raw memory's source refs.

  A memory's refs are a function of the facts it actually carries, never of the
  rows the freeze happened to read: a meeting that produces no fact contributes
  no ref. The freeze calls this to emit `source_refs` and the verifier calls it
  to rebuild them, so the two agree by construction rather than by convention.
  """
  @spec raw_memory_source_refs(String.t(), [String.t()], [map()]) :: [String.t()]
  def raw_memory_source_refs(project_source_ref, member_source_refs, facts)
      when is_list(member_source_refs) and is_list(facts) do
    [project_source_ref | member_source_refs] ++
      (facts |> Enum.map(&fact_root_source_ref(&1["source_ref"])) |> Enum.uniq())
  end

  defp valid_raw_member?(member),
    do:
      exact_keys?(member, ~w(key display_name rbac_role source_ref)) and
        Enum.all?(~w(key display_name rbac_role source_ref), &present?(member[&1]))

  defp valid_raw_fact?(fact) do
    keys = Map.keys(fact) |> Enum.sort()

    keys in [
      Enum.sort(~w(kind text source_ref)),
      Enum.sort(~w(kind text owner deadline source_ref))
    ] and
      present?(fact["kind"]) and present?(fact["text"]) and present?(fact["source_ref"]) and
      (not Map.has_key?(fact, "owner") or is_binary(fact["owner"] || "")) and
      (not Map.has_key?(fact, "deadline") or is_binary(fact["deadline"] || ""))
  end

  defp fact_root_source_ref(source_ref) do
    Regex.replace(~r{/(?:key-point|action-item)/\d+\z}, source_ref, "")
  end

  defp raw_provider_principal_ref(provider_user_id, identity, bundle) do
    if provider_user_id == bundle["connect_identity"]["bot_user_id"] do
      get_in(identity, ["self_agent", "principal_ref"])
    else
      "slack-principal://#{get_in(identity, ["self_endpoint", "workspace_id"])}/#{provider_user_id}"
    end
  end

  defp rebuild_projection_registry(bundle) do
    raw_context = bundle["raw_context"]
    identity = raw_context["identity_context"]
    slack = raw_context["slack_context"]
    memory = raw_context["team_project_memory"]
    self_ref = get_in(identity, ["self_agent", "principal_ref"])

    principals =
      identity["principal_refs"]
      |> Enum.reject(&(&1 == self_ref))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {raw, index} -> {raw, "principal://run/p#{ordinal(index)}"} end)
      |> Map.put(self_ref, "principal://run/self")

    principal_aliases =
      identity["observed_principals"]
      |> Map.new(fn principal ->
        projected_ref = principals[principal["principal_ref"]]
        {projected_ref, projected_principal_alias(principal, projected_ref)}
      end)
      |> Map.put("principal://run/self", "@self")

    # Mirrors `BridgeForTeams.TriageContext`'s registry exactly: an agent author
    # is a principal even when nobody mentioned it, so its provider id must map
    # to that principal here too. Recomputing it — rather than reading the
    # freeze's answer — is the whole point: a run that claimed a principal the
    # pinned page cannot produce fails right here.
    agent_author_principals =
      slack["messages"]
      |> Enum.filter(&(&1["actor_kind"] == "agent" and present?(&1["actor_id"])))
      |> Map.new(fn message ->
        {message["actor_id"],
         principals[raw_provider_principal_ref(message["actor_id"], identity, bundle)]}
      end)
      |> Enum.reject(fn {_provider_user_id, projected_ref} -> is_nil(projected_ref) end)
      |> Map.new()

    provider_principals =
      identity["mention_evidence"]
      |> Map.new(fn mention ->
        {mention["provider_user_id"], principals[mention["principal_ref"]]}
      end)
      |> Map.merge(agent_author_principals)
      |> Map.put(bundle["connect_identity"]["bot_user_id"], "principal://run/self")

    participants =
      slack["messages"]
      |> Enum.map(& &1["actor_id"])
      |> Enum.filter(&present?/1)
      |> Enum.reject(&Map.has_key?(provider_principals, &1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {raw, index} -> {raw, "participant://run/u#{ordinal(index)}"} end)

    sources =
      [slack, identity, memory]
      |> collect_raw_source_refs()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {raw, index} -> {raw, "source://run/s#{ordinal(index)}"} end)

    messages =
      slack["messages"]
      |> Enum.with_index(1)
      |> Map.new(fn {message, index} ->
        {message["source_ref"], "message://run/m#{ordinal(index)}"}
      end)

    members =
      memory["members"]
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.with_index(1)
      |> Map.new(fn {member, index} ->
        {member["source_ref"], "member://run/m#{ordinal(index)}"}
      end)

    links =
      slack["messages"]
      |> raw_message_links()
      |> Enum.with_index(1)
      |> Map.new(fn {raw, index} -> {raw, "link://run/l#{ordinal(index)}"} end)

    registry = %{
      principals: principals,
      principal_aliases: principal_aliases,
      provider_principals: provider_principals,
      participants: participants,
      sources: sources,
      messages: messages,
      members: members,
      links: links,
      project: %{get_in(memory, ["project", "source_ref"]) => "project://run/p001"}
    }

    if registry_closed?(registry),
      do: {:ok, registry},
      else: {:error, :identity_projection_invalid}
  end

  defp registry_alias_map(registry) do
    %{
      "principals" => registry.principals,
      "provider_principals" => registry.provider_principals,
      "participants" => registry.participants,
      "sources" => registry.sources,
      "messages" => registry.messages,
      "members" => registry.members,
      "links" => registry.links,
      "project" => registry.project
    }
  end

  defp registry_closed?(registry) do
    Enum.all?(
      [
        :principals,
        :principal_aliases,
        :provider_principals,
        :participants,
        :sources,
        :messages,
        :members,
        :links,
        :project
      ],
      fn key ->
        map = registry[key]

        is_map(map) and
          Enum.all?(map, fn {raw, projected} -> present?(raw) and present?(projected) end)
      end
    )
  end

  defp project_context(bundle, registry) do
    raw = bundle["raw_context"]

    with {:ok, slack} <- project_slack(raw["slack_context"], registry, bundle),
         {:ok, identity} <- project_identity(raw["identity_context"], registry),
         {:ok, memory} <- project_memory(raw["team_project_memory"], registry) do
      projected = %{
        "slack_context" => slack,
        "identity_context" => identity,
        "team_project_memory" => memory,
        "decision_contract" => %{
          "source_refs" =>
            (slack["source_refs"] ++ identity["source_refs"] ++ memory["source_refs"])
            |> Enum.uniq()
            |> Enum.sort(),
          "principal_refs" => identity["principal_refs"],
          "remember_forbidden_source_refs" => identity["remember_forbidden_source_refs"]
        }
      }

      if bundle["schema"] in @full_thread_bundle_schemas do
        {:ok, projected}
      else
        {:ok,
         Map.put(projected, "answered_recheck", %{
           "answered" => raw["answered_recheck"]["answered"]
         })}
      end
    end
  end

  defp project_slack(
         %{"messages" => messages},
         registry,
         %{
           "schema" => @private_bundle_v3_schema
         } = bundle
       ) do
    projected =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, index} ->
        %{
          "ordinal" => index,
          "actor_ref" =>
            registry.provider_principals[message["actor_id"]] ||
              registry.participants[message["actor_id"]] || "participant://run/u000",
          "actor_kind" => message["actor_kind"],
          "message_ref" => registry.messages[message["source_ref"]],
          "text" => project_provider_safe_text(message["text"], registry),
          "source_ref" => registry.sources[message["source_ref"]]
        }
      end)

    with true <-
           Enum.all?(projected, fn message ->
             exact_keys?(message, @projected_slack_message_v3_fields) and
               is_integer(message["ordinal"]) and present?(message["actor_ref"]) and
               message["actor_kind"] in ["agent", "system", "human", "unknown"] and
               present?(message["message_ref"]) and is_binary(message["text"]) and
               present?(message["source_ref"])
           end),
         {:ok, decision_target} <- project_decision_target(messages, projected, bundle, registry) do
      {:ok,
       %{
         "messages" => projected,
         "source_refs" => Enum.map(projected, & &1["source_ref"]),
         "links" => project_links(messages, projected, registry),
         "decision_target" => decision_target
       }}
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp project_slack(
         %{"messages" => messages, "expression_context" => expression_context},
         registry,
         %{"schema" => schema} = bundle
       )
       when schema in @expression_bundle_schemas do
    projected =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, index} ->
        %{
          "ordinal" => index,
          "actor_ref" =>
            registry.provider_principals[message["actor_id"]] ||
              registry.participants[message["actor_id"]] || "participant://run/u000",
          "actor_kind" => message["actor_kind"],
          "message_ref" => registry.messages[message["source_ref"]],
          "text" => project_provider_safe_text(message["text"], registry),
          "source_ref" => registry.sources[message["source_ref"]],
          "observed_reactions" =>
            Enum.map(message["reactions"], fn reaction ->
              %{"emoji" => reaction["name"], "count" => reaction["count"]}
            end)
        }
        |> then(fn projected ->
          if schema in [@private_bundle_v7_schema, @private_bundle_v8_schema] do
            Map.put(
              projected,
              "file_attachments",
              FileAttachments.project(
                message["file_attachments"],
                &project_provider_safe_text(&1, registry)
              )
            )
          else
            projected
          end
        end)
        |> ChannelBatch.project_thread(message, messages)
      end)

    with true <- ExpressionContext.valid?(expression_context),
         true <-
           Enum.all?(projected, fn message ->
             exact_keys?(message, projected_message_fields(schema)) and
               valid_projected_message_files?(message, schema) and
               is_integer(message["ordinal"]) and present?(message["actor_ref"]) and
               message["actor_kind"] in ["agent", "system", "human", "unknown"] and
               present?(message["message_ref"]) and is_binary(message["text"]) and
               present?(message["source_ref"]) and
               valid_projected_reactions?(message["observed_reactions"])
           end),
         {:ok, decision_target} <- project_decision_target(messages, projected, bundle, registry) do
      {:ok,
       %{
         "messages" => projected,
         "source_refs" => Enum.map(projected, & &1["source_ref"]),
         "links" => project_links(messages, projected, registry),
         "decision_target" => decision_target,
         "expression_context" => expression_context
       }}
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp project_slack(_raw_slack, _registry, _bundle),
    do: {:error, :identity_projection_invalid}

  defp valid_projected_reactions?(reactions) when is_list(reactions) do
    length(reactions) <= @observed_reaction_limit and
      Enum.all?(reactions, fn reaction ->
        exact_keys?(reaction, ~w(count emoji)) and present?(reaction["emoji"]) and
          is_integer(reaction["count"]) and
          reaction["count"] in 1..@observed_reaction_count_limit
      end)
  end

  defp valid_projected_reactions?(_reactions), do: false

  defp project_decision_target(messages, projected, bundle, registry) do
    target_key =
      bundle["target_cutoff"]["event_message_timestamps"]
      |> Enum.map(&slack_ts_key/1)
      |> Enum.max()

    with {raw_target, index} <-
           messages
           |> Enum.with_index(1)
           |> Enum.find(fn {message, _index} ->
             slack_ts_key(message["message_ts"]) == target_key
           end),
         projected_target when is_map(projected_target) <- Enum.at(projected, index - 1) do
      {:ok,
       %{
         "ordinal" => index,
         "message_ref" => projected_target["message_ref"],
         "source_ref" => projected_target["source_ref"],
         "link_refs" => project_link_refs(raw_target["text"], registry),
         "syntactic_addressee" =>
           syntactic_addressee(raw_target["source_ref"], bundle["raw_identity_context"])
       }}
    else
      _other -> {:error, :identity_projection_invalid}
    end
  end

  defp syntactic_addressee(target_source_ref, raw_identity) do
    self_ref = get_in(raw_identity, ["self_agent", "principal_ref"])

    mentioned_refs =
      raw_identity
      |> Map.get("mention_evidence", [])
      |> Enum.filter(&(&1["message_source_ref"] == target_source_ref))
      |> Enum.map(& &1["principal_ref"])
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    Addressee.classify(self_ref, mentioned_refs)
  end

  defp project_identity(raw, registry) do
    self_agent = raw["self_agent"]
    self_endpoint = raw["self_endpoint"]

    observed =
      raw["observed_principals"]
      |> Enum.map(fn principal ->
        projected_ref = registry.principals[principal["principal_ref"]]

        %{
          "principal_ref" => projected_ref,
          "provider" => principal["provider"],
          "kind" => principal["kind"],
          "relation_to_self" => principal["relation_to_self"],
          "display_aliases" =>
            projected_display_aliases(
              projected_principal_alias(principal, projected_ref),
              principal["display_aliases"]
            ),
          "evidence_tier" => principal["evidence_tier"],
          "source_refs" => project_refs(principal["source_refs"], registry.sources)
        }
      end)
      |> Enum.sort_by(& &1["principal_ref"])

    mentions =
      raw["mention_evidence"]
      |> Enum.map(fn mention ->
        %{
          "principal_ref" => registry.principals[mention["principal_ref"]],
          "message_ref" => registry.messages[mention["message_source_ref"]],
          "message_source_ref" => registry.sources[mention["message_source_ref"]],
          "selectors" => mention["selectors"],
          "source_ref" => registry.sources[mention["source_ref"]],
          "source_refs" => project_refs(mention["source_refs"], registry.sources)
        }
      end)
      |> Enum.sort_by(&{&1["message_ref"], &1["principal_ref"]})

    identity = %{
      "schema" => "comma.triage-identity-model-context.v1",
      "source_mode" => raw["source_mode"],
      "self_agent" => %{
        "principal_ref" => "principal://run/self",
        "display_alias" => "@self",
        "role" => self_agent["role"],
        "source_ref" => registry.sources[self_agent["source_ref"]]
      },
      "self_endpoint" => %{
        "endpoint_ref" => "endpoint://run/self",
        "provider" => self_endpoint["provider"],
        "display_aliases" => projected_display_aliases("@self", self_endpoint["display_aliases"]),
        "represents_principal_ref" => "principal://run/self",
        "revision_status" => self_endpoint["revision_status"],
        "source_ref" => registry.sources[self_endpoint["source_ref"]]
      },
      "observed_principals" => observed,
      "mention_evidence" => mentions
    }

    principal_refs =
      ["principal://run/self" | Enum.map(observed, & &1["principal_ref"])] |> Enum.uniq()

    identity =
      identity
      |> Map.put("principal_refs", principal_refs)
      |> Map.put(
        "remember_forbidden_source_refs",
        ([
           get_in(identity, ["self_agent", "source_ref"]),
           get_in(identity, ["self_endpoint", "source_ref"])
         ] ++
           principal_refs ++ Enum.map(mentions, & &1["source_ref"]))
        |> canonical_refs()
      )
      |> Map.put(
        "source_refs",
        ([
           get_in(identity, ["self_agent", "source_ref"]),
           get_in(identity, ["self_endpoint", "source_ref"])
         ] ++
           Enum.flat_map(observed, & &1["source_refs"]) ++
           Enum.flat_map(mentions, &[&1["source_ref"] | &1["source_refs"]]))
        |> canonical_refs()
      )

    if projected_identity_closed?(identity),
      do: {:ok, identity},
      else: {:error, :identity_projection_invalid}
  end

  defp projected_identity_closed?(identity) do
    Enum.all?(identity["principal_refs"], &present?/1) and
      Enum.all?(identity["source_refs"], &present?/1) and
      Enum.all?(identity["remember_forbidden_source_refs"], &present?/1)
  end

  defp project_memory(raw, registry) do
    members =
      raw["members"]
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.with_index(1)
      |> Enum.map(fn {member, index} ->
        %{
          "entity_ref" => registry.members[member["source_ref"]],
          "display_alias" =>
            source_display_alias(member["display_name"], "@member:m#{ordinal(index)}", registry),
          "rbac_role" => member["rbac_role"],
          "source_ref" => registry.sources[member["source_ref"]]
        }
      end)

    owners =
      raw["members"]
      |> Map.new(fn member ->
        {trim(member["display_name"]), registry.members[member["source_ref"]]}
      end)

    facts =
      raw["facts"]
      |> Enum.sort_by(& &1["source_ref"])
      |> Enum.map(fn fact ->
        %{
          "kind" => fact["kind"],
          # Same redaction pipeline the freeze applies to a meeting fact: this
          # side must rebuild the exact projected bytes the freeze committed.
          "text" => project_provider_safe_text(fact["text"], registry),
          "owner_ref" => owners[trim(fact["owner"])],
          "deadline" => normalized_deadline(fact["deadline"]),
          "source_ref" => registry.sources[fact["source_ref"]]
        }
      end)

    project_ref = get_in(raw, ["project", "source_ref"])

    projected = %{
      "project" => %{
        "entity_ref" => registry.project[project_ref],
        "display_alias" =>
          source_display_alias(get_in(raw, ["project", "name"]), "@project:p001", registry),
        "status" => get_in(raw, ["project", "status"]),
        "source_ref" => registry.sources[project_ref]
      },
      "members" => members,
      "member_roster" => raw["member_roster"],
      "facts" => facts,
      "source_refs" =>
        [registry.sources[project_ref]] ++
          Enum.map(members, & &1["source_ref"]) ++ Enum.map(facts, & &1["source_ref"])
    }

    if Enum.all?(projected["source_refs"], &present?/1),
      do: {:ok, projected},
      else: {:error, :identity_projection_invalid}
  end

  defp rewrite_projected_mentions(text, registry) do
    Regex.replace(~r/<@([A-Z0-9_]+)>/, trim(text), fn _token, provider_user_id ->
      registry.provider_principals
      |> Map.get(provider_user_id)
      |> then(&Map.get(registry.principal_aliases, &1, "@unknown:p000"))
    end)
  end

  @doc "Preserve authorized source text; withhold credential-bearing tool text."
  @spec redact_untrusted_text(binary()) :: binary()
  def redact_untrusted_text(text) when is_binary(text) do
    if contains_credential?(text), do: "[Credential-bearing source text withheld]", else: text
  end

  def redact_untrusted_text(_text), do: ""

  defp source_display_alias(text, fallback, %{source_visible?: true}) do
    case trim(text) do
      "" -> fallback
      value -> value
    end
  end

  defp source_display_alias(_text, fallback, _registry), do: fallback

  defp project_provider_safe_text(text, %{source_visible?: true}), do: trim(text)

  defp project_provider_safe_text(text, registry) do
    text =
      registry.links
      |> Enum.sort_by(fn {raw, _ref} -> {-byte_size(raw), raw} end)
      |> Enum.reduce(rewrite_projected_mentions(text, registry), fn {raw, ref}, projected ->
        String.replace(projected, raw, link_display_alias(ref))
      end)

    @provider_safe_text_replacements
    |> Enum.reduce(text, fn {pattern, replacement}, projected ->
      Regex.replace(pattern, projected, replacement)
    end)
    |> SalixStore.SlackPrivateToken.redact()
  end

  defp project_links(messages, projected, registry) do
    registry.links
    |> Enum.sort_by(fn {_raw, ref} -> ref end)
    |> Enum.map(fn {raw, ref} ->
      occurrences =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {message, _index} -> raw in extract_raw_links(message["text"]) end)
        |> Enum.map(fn {_message, index} -> Enum.at(projected, index) end)

      %{
        "link_ref" => ref,
        "display_alias" => link_display_alias(ref),
        "message_refs" => occurrences |> Enum.map(& &1["message_ref"]) |> Enum.uniq(),
        "source_refs" => occurrences |> Enum.map(& &1["source_ref"]) |> Enum.uniq()
      }
    end)
  end

  defp project_link_refs(text, registry) do
    text
    |> extract_raw_links()
    |> Enum.map(&registry.links[&1])
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp raw_message_links(messages) do
    messages
    |> Enum.flat_map(&extract_raw_links(&1["text"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_raw_links(text) when is_binary(text) do
    slack_links =
      @slack_mrkdwn_link
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(&hd/1)

    generic_links =
      Regex.replace(@slack_mrkdwn_link, text, " ")
      |> then(&Regex.scan(@raw_uri, &1, capture: :first))
      |> Enum.map(&hd/1)

    (slack_links ++ generic_links)
    |> Enum.map(&String.replace(&1, ~r/[.,;:!?\)\]\}]+$/, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_raw_links(_text), do: []

  defp link_display_alias("link://run/" <> suffix), do: "@link:#{suffix}"
  defp link_display_alias(_ref), do: "@link:l000"

  defp projected_principal_alias(%{"relation_to_self" => "self"}, _ref), do: "@self"

  defp projected_principal_alias(principal, "principal://run/" <> suffix) do
    case principal["kind"] do
      "agent" -> "@agent:#{suffix}"
      "human" -> "@human:#{suffix}"
      _other -> "@unknown:#{suffix}"
    end
  end

  defp safe_identity_label?(value) do
    is_binary(value) and String.length(value) in 1..64 and
      Regex.match?(~r/\A[\p{L}\p{N} ._-]+\z/u, value)
  end

  defp projected_display_aliases(primary, labels) do
    tails =
      labels
      |> Enum.filter(&safe_identity_label?/1)
      |> Enum.reject(&(&1 == primary))
      |> Enum.uniq()
      |> Enum.sort()

    [primary | tails]
  end

  defp project_refs(refs, sources) do
    refs |> Enum.map(&sources[&1]) |> Enum.filter(&present?/1) |> Enum.uniq() |> Enum.sort()
  end

  defp collect_raw_source_refs(value) when is_list(value),
    do: Enum.flat_map(value, &collect_raw_source_refs/1)

  defp collect_raw_source_refs(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"source_ref", source_ref} when is_binary(source_ref) -> [source_ref]
      {"source_refs", source_refs} when is_list(source_refs) -> source_refs
      {_key, child} -> collect_raw_source_refs(child)
    end)
  end

  defp collect_raw_source_refs(_value), do: []

  defp reject_projected_credentials(projected) do
    if contains_credential?(projected),
      do: {:error, :identity_projection_privacy_rejected},
      else: :ok
  end

  defp collect_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_strings/1)

  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(_value), do: []

  defp contains_credential?(value) do
    Enum.any?(collect_strings(value), fn text ->
      Regex.match?(@credential_assignment, text) or
        Enum.any?(@credential_literal_patterns, &Regex.match?(&1, text)) or
        credential_url?(text)
    end)
  end

  # Keep the existing no-credentials boundary when ordinary URLs remain visible.
  # URL userinfo and signed query values grant access, unlike a normal source link.
  defp credential_url?(text) do
    Enum.any?(Regex.scan(@raw_uri, text, capture: :first), fn [url] ->
      uri = URI.parse(url)

      not is_nil(uri.userinfo) or
        Enum.any?([uri.query, uri.fragment], &credential_url_query?/1)
    end)
  rescue
    ArgumentError -> true
  end

  defp credential_url_query?(nil), do: false

  defp credential_url_query?(query) do
    Enum.any?(URI.query_decoder(query), fn {key, value} ->
      String.downcase(key) in @credential_url_keys and value not in [nil, ""]
    end)
  end

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256, value)

  defp valid_slack_ts?(value),
    do: is_binary(value) and Regex.match?(~r/\A\d+(?:\.\d{1,6})?\z/, String.trim(value))

  defp slack_ts_key(value) do
    [seconds, fraction] =
      case String.split(trim(value), ".", parts: 2) do
        [seconds] -> [seconds, ""]
        pair -> pair
      end

    {String.to_integer(seconds), fraction |> String.pad_trailing(6, "0") |> String.to_integer()}
  end

  defp slack_source_ref(authority, message_ts) do
    scope =
      if authority["thread_ts"] == "__channel__", do: "channel", else: authority["thread_ts"]

    "slack://#{authority["workspace_id"]}/#{authority["channel_id"]}/#{scope}/#{message_ts}"
  end

  defp normalized_deadline(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> Date.to_iso8601(date)
      {:error, _reason} -> nil
    end
  end

  defp normalized_deadline(_value), do: nil

  defp ordinal(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp validate_self_agent(agent) when is_map(agent) do
    with true <- exact_keys?(agent, @self_agent_fields),
         true <- present?(agent["identity_revision_sha256"]),
         {:ok, expected} <-
           agent
           |> Map.delete("identity_revision_sha256")
           |> identity_revision_sha256(),
         true <- agent["identity_revision_sha256"] == expected do
      :ok
    else
      _other -> {:error, :invalid_identity_context}
    end
  end

  defp validate_self_agent(_agent), do: {:error, :invalid_identity_context}

  defp valid_projected_self_agent?(agent) when is_map(agent) do
    exact_keys?(agent, @projected_self_agent_fields) and agent["display_alias"] == "@self" and
      agent["principal_ref"] == "principal://run/self" and present?(agent["role"]) and
      projected_ref?(agent["source_ref"], "source://run/")
  end

  defp valid_projected_self_agent?(_agent), do: false

  defp valid_projected_self_endpoint?(endpoint, self_agent)
       when is_map(endpoint) and is_map(self_agent) do
    exact_keys?(endpoint, @projected_self_endpoint_fields) and
      endpoint["endpoint_ref"] == "endpoint://run/self" and endpoint["provider"] == "slack" and
      valid_string_list?(endpoint["display_aliases"], false) and
      endpoint["represents_principal_ref"] == self_agent["principal_ref"] and
      endpoint["revision_status"] in ["exact", "sanctioned_bot_identity_backfill"] and
      projected_ref?(endpoint["source_ref"], "source://run/")
  end

  defp valid_projected_self_endpoint?(_endpoint, _self_agent), do: false

  defp valid_projected_mention_evidence?(mention) when is_map(mention) do
    exact_keys?(mention, @projected_mention_evidence_fields) and
      projected_ref?(mention["principal_ref"], "principal://run/") and
      projected_ref?(mention["message_ref"], "message://run/") and
      projected_ref?(mention["message_source_ref"], "source://run/") and
      projected_ref?(mention["source_ref"], "source://run/") and
      valid_string_list?(mention["source_refs"], false) and
      Enum.all?(mention["source_refs"], &projected_ref?(&1, "source://run/")) and
      mention["message_source_ref"] in mention["source_refs"] and
      valid_string_list?(mention["selectors"], false) and
      Enum.all?(mention["selectors"], &(&1 in ["text_token", "rich_text_user"]))
  end

  defp valid_projected_mention_evidence?(_mention), do: false

  defp projected_ref?(value, prefix),
    do: is_binary(value) and String.starts_with?(value, prefix) and value != prefix

  defp validate_self_endpoint(endpoint, self_agent)
       when is_map(endpoint) and is_map(self_agent) do
    expected_ref =
      "slack-endpoint://#{endpoint["workspace_id"]}/#{endpoint["connect_id"]}@#{endpoint["connect_generation"]}"

    valid? =
      exact_keys?(endpoint, @self_endpoint_fields) and endpoint["provider"] == "slack" and
        Enum.all?(
          ~w(workspace_id connect_id connect_generation provider_app_id represents_principal_ref source_ref),
          &present?(endpoint[&1])
        ) and is_binary(endpoint["bot_user_id"]) and is_binary(endpoint["bot_id"]) and
        valid_string_list?(endpoint["display_aliases"], false) and
        endpoint["represents_principal_ref"] == self_agent["principal_ref"] and
        endpoint["source_ref"] == expected_ref and
        endpoint["revision_status"] in ["exact", "sanctioned_bot_identity_backfill"] and
        is_binary(endpoint["revision_sha256"]) and
        Regex.match?(@sha256, endpoint["revision_sha256"])

    if valid?, do: :ok, else: {:error, :invalid_identity_context}
  end

  defp validate_self_endpoint(_endpoint, _self_agent),
    do: {:error, :invalid_identity_context}

  defp valid_observed_principal?(principal) when is_map(principal) do
    exact_keys?(principal, @observed_principal_fields) and
      present?(principal["principal_ref"]) and principal["provider"] == "slack" and
      principal["kind"] in ["agent", "human", "unknown"] and
      principal["relation_to_self"] in ["self", "other", "unknown"] and
      valid_string_list?(principal["display_aliases"], true) and
      principal["evidence_tier"] in ["self_endpoint", "thread_authorship", "unresolved"] and
      valid_string_list?(principal["source_refs"], false)
  end

  defp valid_observed_principal?(_principal), do: false

  defp valid_mention_evidence?(mention) when is_map(mention) do
    exact_keys?(mention, @mention_evidence_fields) and present?(mention["principal_ref"]) and
      present?(mention["provider_user_id"]) and present?(mention["message_source_ref"]) and
      present?(mention["source_ref"]) and valid_string_list?(mention["source_refs"], false) and
      mention["message_source_ref"] in mention["source_refs"] and
      valid_string_list?(mention["selectors"], false) and
      Enum.all?(mention["selectors"], &(&1 in ["text_token", "rich_text_user"]))
  end

  defp valid_mention_evidence?(_mention), do: false

  defp valid_interpretation?(interpretation, context) when is_map(interpretation) do
    refs = interpretation["referenced_principal_refs"]
    topic = interpretation["topic"]

    exact_keys?(interpretation, ~w(referenced_principal_refs topic)) and topic in @identity_topics and
      valid_string_list?(refs, true) and Enum.all?(refs, &(&1 in principal_refs(context))) and
      if(topic == "none", do: refs == [], else: refs != [])
  end

  defp valid_interpretation?(_interpretation, _context), do: false

  defp valid_decision_source_refs?(%{"action" => action, "source_refs" => refs}) do
    valid_string_list?(refs, true) and (action not in @sourced_actions or refs != [])
  end

  defp valid_decision_source_refs?(_decision), do: false

  defp valid_action_value?(%{"action" => "silence"}), do: true
  defp valid_action_value?(%{"action" => "reply", "text" => value}), do: present?(value)
  defp valid_action_value?(%{"action" => "react", "reaction" => value}), do: present?(value)
  defp valid_action_value?(%{"action" => "delegate", "task" => value}), do: present?(value)
  defp valid_action_value?(%{"action" => "remember", "fact" => value}), do: present?(value)
  defp valid_action_value?(_decision), do: false

  defp valid_remember_identity_boundary?(%{"action" => "remember"} = decision, context) do
    get_in(decision, ["identity_interpretation", "topic"]) == "none" and
      MapSet.disjoint?(
        MapSet.new(decision["source_refs"]),
        MapSet.new(remember_forbidden_source_refs(context))
      )
  end

  defp valid_remember_identity_boundary?(_decision, _context), do: true

  defp validate_projected_decision(
         %{"schema" => schema} = decision,
         projected_context,
         bundle_schema
       )
       when schema in [
              "comma.triage-product-decision.v1",
              "comma.triage-product-decision.v2"
            ] and is_map(projected_context) do
    decision_contract = projected_context["decision_contract"]

    with {:decision_contract, true} <-
           {:decision_contract,
            exact_keys?(
              decision_contract,
              ~w(principal_refs remember_forbidden_source_refs source_refs)
            )},
         {:source_mode, true} <-
           {:source_mode,
            get_in(projected_context, ["identity_context", "source_mode"]) in [
              "callback",
              "clickhouse_etl",
              "periodic_patrol",
              "scheduled_recheck"
            ]},
         {:product_contract, :ok} <-
           {:product_contract,
            validate_product_decision_for_projected_context(
              decision,
              projected_context,
              bundle_schema
            )},
         {:authored_values, :ok} <-
           {:authored_values, validate_model_authored_values(decision, projected_context)} do
      :ok
    else
      {stage, result} ->
        log_product_decision_failure(stage, result)
        {:error, :identity_decision_invalid}
    end
  end

  defp validate_projected_decision(decision, projected_context, _bundle_schema)
       when is_map(decision) do
    decision_contract = projected_context["decision_contract"]
    interpretation = decision["identity_interpretation"] || %{}

    with true <- decision["action"] in @actions,
         true <- exact_keys?(decision, decision_fields(decision["action"])),
         true <- valid_action_value?(decision),
         true <- valid_decision_source_refs?(decision),
         true <-
           exact_keys?(
             decision_contract,
             ~w(principal_refs remember_forbidden_source_refs source_refs)
           ),
         true <-
           Enum.all?(
             decision["source_refs"],
             &(&1 in decision_contract["source_refs"])
           ),
         true <- valid_projected_interpretation?(interpretation, decision_contract),
         true <- valid_projected_remember_boundary?(decision, decision_contract),
         true <- valid_model_authored_values?(decision, projected_context) do
      :ok
    else
      _other -> {:error, :identity_decision_invalid}
    end
  end

  defp validate_product_decision_for_projected_context(
         %{"schema" => schema} = decision,
         projected_context,
         @private_bundle_v3_schema
       )
       when schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] do
    # Both decision schemas predate expression-aware source bundles. Their
    # frozen v3 records retain the original standard-palette authorization.
    decision_contract = projected_context["decision_contract"]
    slack_context = projected_context["slack_context"]

    with true <- exact_legacy_projected_slack_context?(slack_context) do
      ProductDecision.validate_for_target_detailed(
        decision,
        decision_contract["source_refs"],
        decision_contract["principal_refs"],
        ProductDecision.target_route(
          slack_context,
          get_in(projected_context, ["identity_context", "source_mode"])
        ),
        :standard
      )
    else
      _invalid -> {:error, :projected_slack_context}
    end
  end

  defp validate_product_decision_for_projected_context(
         %{"schema" => "comma.triage-product-decision.v2"} = decision,
         projected_context,
         bundle_schema
       )
       when bundle_schema in @expression_bundle_schemas do
    decision_contract = projected_context["decision_contract"]
    slack_context = projected_context["slack_context"]

    with true <- exact_expression_projected_slack_context?(slack_context, bundle_schema),
         %{} = expression_context <- slack_context["expression_context"] do
      ProductDecision.validate_for_target_detailed(
        decision,
        decision_contract["source_refs"],
        decision_contract["principal_refs"],
        ProductDecision.target_route(
          slack_context,
          get_in(projected_context, ["identity_context", "source_mode"])
        ),
        get_in(slack_context, ["decision_target", "source_ref"]),
        expression_context
      )
    else
      _invalid -> {:error, :projected_slack_context}
    end
  end

  defp validate_product_decision_for_projected_context(
         _decision,
         _projected_context,
         _bundle_schema
       ),
       do: {:error, :product_schema}

  defp exact_legacy_projected_slack_context?(slack_context) when is_map(slack_context) do
    exact_keys?(slack_context, ~w(decision_target links messages source_refs)) and
      Enum.all?(slack_context["messages"], fn message ->
        exact_keys?(message, @projected_slack_message_v3_fields)
      end)
  end

  defp exact_legacy_projected_slack_context?(_slack_context), do: false

  defp exact_expression_projected_slack_context?(slack_context, schema)
       when is_map(slack_context) do
    exact_keys?(
      slack_context,
      ~w(decision_target expression_context links messages source_refs)
    ) and ExpressionContext.valid?(slack_context["expression_context"]) and
      Enum.all?(slack_context["messages"], fn message ->
        exact_keys?(message, projected_message_fields(schema)) and
          valid_projected_message_files?(message, schema) and
          valid_projected_reactions?(message["observed_reactions"])
      end)
  end

  defp exact_expression_projected_slack_context?(_slack_context, _schema), do: false

  defp valid_projected_interpretation?(interpretation, contract) when is_map(interpretation) do
    refs = interpretation["referenced_principal_refs"]
    topic = interpretation["topic"]

    exact_keys?(interpretation, ~w(referenced_principal_refs topic)) and
      topic in @identity_topics and valid_string_list?(refs, true) and
      Enum.all?(refs, &(&1 in contract["principal_refs"])) and
      if(topic == "none", do: refs == [], else: refs != [])
  end

  defp valid_projected_interpretation?(_interpretation, _contract), do: false

  defp valid_projected_remember_boundary?(%{"action" => "remember"} = decision, contract) do
    get_in(decision, ["identity_interpretation", "topic"]) == "none" and
      MapSet.disjoint?(
        MapSet.new(decision["source_refs"]),
        MapSet.new(contract["remember_forbidden_source_refs"])
      )
  end

  defp valid_projected_remember_boundary?(_decision, _contract), do: true

  defp valid_model_authored_values?(decision, projected_context) do
    validate_model_authored_values(decision, projected_context) == :ok
  end

  defp validate_model_authored_values(decision, projected_context) do
    free_form_values = model_authored_values(decision)

    allowed_aliases = projected_aliases(projected_context)

    aliases_closed? =
      free_form_values
      |> Enum.flat_map(&regex_matches(@projected_alias, &1))
      |> Enum.all?(&(&1 in allowed_aliases))

    cond do
      not aliases_closed? -> {:error, :projected_aliases}
      contains_credential?(free_form_values) -> {:error, :credential_literal}
      true -> :ok
    end
  end

  defp log_product_decision_failure(stage, result) do
    {check, reason} =
      case result do
        {:error, {check, reason}} -> {check, reason}
        {:error, check} -> {check, :invalid}
        false -> {stage, :invalid}
      end

    Logger.warning(
      "triage_identity_product_rejected stage=#{stage} check=#{check} reason=#{reason}"
    )
  end

  defp model_authored_values(%{"schema" => schema} = decision)
       when schema in [
              "comma.triage-product-decision.v1",
              "comma.triage-product-decision.v2"
            ] do
    communication_values =
      case decision["communication"] do
        %{"text" => text} when is_binary(text) -> [text]
        _other -> []
      end

    context_values =
      decision
      |> Map.get("context_candidates", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"subject" => subject, "value" => value}
        when is_binary(subject) and is_binary(value) ->
          [subject, value]

        _other ->
          []
      end)

    delegation_values =
      decision
      |> Map.get("delegations", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"task" => task} when is_binary(task) -> [task]
        _other -> []
      end)

    communication_values ++ context_values ++ delegation_values
  end

  defp model_authored_values(decision) do
    ~w(text reaction task fact)
    |> Enum.map(&decision[&1])
    |> Enum.filter(&is_binary/1)
  end

  defp projected_aliases(projected_context) do
    identity = projected_context["identity_context"] || %{}
    memory = projected_context["team_project_memory"] || %{}

    ([get_in(identity, ["self_agent", "display_alias"])] ++
       List.wrap(get_in(identity, ["self_endpoint", "display_aliases"])) ++
       Enum.flat_map(List.wrap(identity["observed_principals"]), fn principal ->
         List.wrap(principal["display_aliases"])
       end) ++
       [get_in(memory, ["project", "display_alias"])] ++
       Enum.map(List.wrap(memory["members"]), & &1["display_alias"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&(regex_matches(@projected_alias, &1) == [&1]))
    |> Enum.uniq()
  end

  defp decision_fields("silence"), do: ~w(action identity_interpretation source_refs)
  defp decision_fields("reply"), do: ~w(action identity_interpretation source_refs text)
  defp decision_fields("react"), do: ~w(action identity_interpretation reaction source_refs)
  defp decision_fields("delegate"), do: ~w(action identity_interpretation source_refs task)
  defp decision_fields("remember"), do: ~w(action fact identity_interpretation source_refs)
  defp decision_fields(_action), do: []

  defp exact_keys?(map, fields) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(fields)

  defp valid_string_list?(values, allow_empty?) when is_list(values) do
    (allow_empty? or values != []) and Enum.all?(values, &present?/1) and
      length(values) == length(Enum.uniq(values))
  end

  defp valid_string_list?(_values, _allow_empty?), do: false

  defp unique_by?(values, fun) when is_list(values) do
    projected = Enum.map(values, fun)
    length(projected) == length(Enum.uniq(projected))
  end

  defp map_value(map, key) when is_map(map), do: map[key]
  defp map_value(_map, _key), do: nil

  defp list_value(map, key) when is_map(map) do
    case map[key] do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp list_value(_map, _key), do: []

  defp canonical_refs(refs) do
    refs
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp valid_endpoint_provenance?(provenance) when is_map(provenance) do
    case provenance["schema"] do
      "comma.slack-endpoint-provenance.v1" ->
        Map.keys(provenance) |> Enum.sort() == @endpoint_provenance_fields and
          is_integer(provenance["captured_at_ms"]) and provenance["captured_at_ms"] > 0 and
          present?(provenance["callback_api_app_id"]) and
          is_binary(provenance["fast_path_bot_user_id"]) and
          is_binary(provenance["endpoint_revision_sha256"]) and
          Regex.match?(@sha256, provenance["endpoint_revision_sha256"])

      "comma.slack-clickhouse-etl-provenance.v1" ->
        Map.keys(provenance) |> Enum.sort() == @clickhouse_provenance_fields and
          provenance["table"] == "slack_messages" and
          is_integer(provenance["message_ts_us"]) and provenance["message_ts_us"] >= 0 and
          is_integer(provenance["observed_version"]) and provenance["observed_version"] >= 0 and
          is_integer(provenance["cursor_revision"]) and provenance["cursor_revision"] >= 0 and
          match?({:ok, _, _}, DateTime.from_iso8601(provenance["ingest_at"] || ""))

      _invalid ->
        false
    end
  end

  defp valid_endpoint_provenance?(_provenance), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
