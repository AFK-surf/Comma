defmodule SalixIM.Triage.RunFence.AuthorizedProjection do
  @moduledoc false

  @enforce_keys [:fence, :correlations]
  defstruct [:fence, :correlations]

  @opaque t :: %__MODULE__{fence: map(), correlations: [map()]}
end

defmodule SalixIM.Triage.RunFence.AuthorizedReadContext do
  @moduledoc false

  @enforce_keys [:fence, :run_id, :raw_bundle, :alias_map]
  defstruct [:fence, :run_id, :raw_bundle, :alias_map]

  @opaque t :: %__MODULE__{
            fence: map(),
            run_id: String.t(),
            raw_bundle: map(),
            alias_map: map()
          }
end

defmodule SalixIM.Triage.RunFence.AuthorizedProductEffects do
  @moduledoc false

  @enforce_keys [:fence, :run_id, :raw_bundle, :alias_map]
  defstruct [:fence, :run_id, :raw_bundle, :alias_map]

  @opaque t :: %__MODULE__{
            fence: map(),
            run_id: String.t(),
            raw_bundle: map(),
            alias_map: map()
          }
end

defmodule SalixIM.Triage.RunFence.Creation do
  @moduledoc false

  @enforce_keys [:key, :record, :identity?]
  defstruct [:key, :record, :identity?]

  @opaque t :: %__MODULE__{
            key: String.t(),
            record: map(),
            identity?: boolean()
          }
end

defmodule SalixIM.Triage.RunFence.Settlement do
  @moduledoc false

  @enforce_keys [:fence, :outcome, :requested_terminal]
  defstruct [:fence, :outcome, :requested_terminal]

  @opaque t :: %__MODULE__{
            fence: map(),
            outcome: :requested | :timeout | :existing,
            requested_terminal: map()
          }
end

defmodule SalixIM.Triage.RunFence do
  @moduledoc """
  Durable identity-run fence transitions and closed-schema validation.

  This module is the sole owner of fence record mutation rules. Callers supply
  the Runtime-minted active binding and receive only closed transition results;
  no callback, transport, model, or product effect runs inside a CAS callback.

  Modeled in `tla/salix/TriageRunFence.tla`.
  """

  alias SalixIM.Provider.Slack.API

  alias SalixIM.Triage.{
    Bucketing,
    CanonicalJSON,
    Correlation,
    IdentityContract,
    ParticipationDecision,
    ProductDecision,
    ReviewProjection,
    SourceMode
  }

  alias SalixIM.Triage.RunFence.AuthorizedReadContext
  alias SalixIM.Triage.RunFence.AuthorizedProductEffects
  alias SalixIM.Triage.RunFence.AuthorizedProjection
  alias SalixIM.Triage.RunFence.Creation
  alias SalixIM.Triage.RunFence.Settlement
  alias SalixStore.{CasRecord, TriageRecordStore, ULID}

  @identity_claim_keys ~w(
    schema
    identity_profile_sha256
    request_selector_sha256
    slack_api_origin_sha256
    source_observation_sha256
  )
  @identity_source_claim_keys ~w(
    schema
    identity_profile_sha256
    request_selector_sha256
    source_origin_sha256
    source_observation_sha256
  )
  @identity_transport_result_keys ~w(
    schema
    kind
    receipt
    canonical_page_bytes
    canonical_page_sha256
    classified_private_messages_sha256
    reason_code
  )
  # v2 binds the whole observed page chain, not only the merged page: Slack's
  # commercial tier caps one read response at 15 objects, so one authorized
  # logical read is an ordered chain of capped exchanges. `canonical_page_bytes`
  # stays the merged page the freeze context consumes; the chain bytes make
  # every contributing page provable on its own.
  @identity_transport_result_v2_keys @identity_transport_result_keys ++
                                       ~w(canonical_page_chain_bytes canonical_page_chain_sha256)
  @identity_source_result_keys ~w(
    schema
    kind
    receipt
    canonical_snapshot_bytes
    canonical_snapshot_sha256
    classified_private_messages_sha256
    reason_code
  )
  @clickhouse_read_receipt_keys ~w(
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
  @identity_private_projection_keys ~w(
    schema
    raw_source_bundle_bytes
    raw_source_bundle_sha256
    raw_context_sha256
    alias_map_bytes
    alias_map_sha256
    projection_policy_sha256
    projected_context_sha256
  )
  @slack_read_receipt_keys ~w(
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
  @slack_read_receipt_v2_keys @slack_read_receipt_keys ++ ["rejection"]
  @slack_read_receipt_chain_keys @slack_read_receipt_keys ++
                                   ~w(page_budget canonical_page_chain_sha256 rejection exchanges)
  @slack_read_rejection_keys ~w(schema stage path unknown_keys)
  @slack_read_rejection_stages ~w(
    json_decode
    response_shape
    credential_material
    message_unknown_keys
    unsupported_message_content
    message_field_shape
    bot_profile_unknown_keys
    bot_profile_shape
    rich_text_unknown_keys
    rich_text_shape
    duplicate_timestamps
    unsafe_unknown_key_name
    unknown_key_overflow
  )
  @slack_read_rejection_paths ~w(
    response
    messages
    messages[]
    messages[].ts
    messages[].user
    messages[].text
    messages[].subtype
    messages[].bot_profile
    messages[].bot_id
    messages[].app_id
    messages[].blocks
    messages[].blocks[]
  )
  @slack_read_rejection_credential_fragments ~w(
    api_key
    apikey
    authorization
    client_secret
    cookie
    credential
    headers
    password
    passwd
    private_key
    secret
    signing_secret
    token
  )
  @slack_error_reasons ~w(slack_error rate_limited http_error transport_error decode_error)
  # An incomplete chain cannot authorize a decision on its unread tail.
  # Keep lease_denied readable for stored receipts from the retired method lock.
  @slack_read_chain_only_reasons ~w(page_budget_exceeded chain_deadline_exceeded lease_denied)
  @slack_read_chain_reasons @slack_error_reasons ++ @slack_read_chain_only_reasons
  # Every diagnostic reason this module can mint for an interrupted or refused
  # run, without any transport reason a writer may commit.
  @identity_diagnostic_reasons ~w(
    identity_projection_invalid
    identity_projection_privacy_rejected
    identity_decision_invalid
    triage_worker_unavailable
    triage_source_target_unavailable
    identity_diagnostic_indeterminate_transport
    identity_diagnostic_interrupted_before_transport
    identity_diagnostic_interrupted_after_read
    identity_diagnostic_indeterminate_model
    identity_diagnostic_internal_error
  )
  # The closed set of `failed` terminal reasons. Recovery passes a committed
  # `reason_code` straight through, so this must be the union of the diagnostic
  # reasons and EVERY transport reason an observation can legitimately carry —
  # including the chain-only ones. A reason a writer can commit but a terminal
  # cannot hold would wedge the bucket on a durably invalid record.
  @terminal_failed_reasons @identity_diagnostic_reasons ++ @slack_read_chain_reasons
  @identity_model_proof_keys ~w(
    schema
    provider
    model
    provider_sha256
    model_sha256
    prompt_sha256
    policy_sha256
    provider_payload_bytes
    provider_payload_sha256
    observer_payload_sha256
    transport_payload_sha256
    request_count
    retry
    canonical_snapshot_sha256
    source_refs_sha256
  )
  @identity_model_proof_review_keys @identity_model_proof_keys ++
                                      ~w(review_artifact review_artifact_sha256)
  @identity_model_proof_v2_keys @identity_model_proof_keys ++
                                  ~w(provider_payload_chain tool_call_count tool_names tool_receipts)
  @identity_model_proof_v2_review_keys @identity_model_proof_v2_keys ++
                                         ~w(review_artifact review_artifact_sha256)
  @identity_model_proof_v3_keys @identity_model_proof_v2_keys ++ ~w(participation_decision)
  @identity_model_proof_v3_review_keys @identity_model_proof_v3_keys ++
                                         ~w(review_artifact review_artifact_sha256)
  @identity_read_tools ~w(web.read_pages triage.slack_read_permalink triage_run.get)
  @link_read_tools ~w(web.read_pages triage.slack_read_permalink)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @spec create(String.t(), String.t(), String.t(), map(), integer(), integer()) ::
          {:ok, {:won, Creation.t()} | :lost} | {:error, term()}
  def create(namespace, scope, run_id, input, created_at, deadline_at) do
    identity? = identity_run?(input)
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, input["generation"])
    record = initial_record(scope, run_id, input, created_at, deadline_at, identity?)
    creation = %Creation{key: key, record: record, identity?: identity?}

    case CasRecord.create(key, record) do
      {:ok, _stored} ->
        {:ok, {:won, creation}}

      {:error, :exists} ->
        {:ok, :lost}

      {:error, _reason} = error ->
        if match?({:ok, ^record}, CasRecord.get(key)),
          do: {:ok, {:won, creation}},
          else: error
    end
  end

  @type settlement_authority :: :result | :timeout

  @doc "Settles one active run and returns which durable terminal won the CAS."
  @spec terminalize(String.t(), map(), map(), settlement_authority()) ::
          {:ok, Settlement.t()} | {:error, term()}
  def terminalize(scope, active, terminal, authority)
      when is_binary(scope) and scope != "" and is_map(active) and is_map(terminal) and
             authority in [:result, :timeout] do
    requested_terminal = Map.put(terminal, "terminal_id", ULID.generate())

    timeout_terminal = %{
      "terminal_id" => ULID.generate(),
      "status" => "skipped_timeout",
      "decision" => %{"action" => "silence"},
      "evaluator" => %{},
      "settled_at" => now()
    }

    with fence_key when is_binary(fence_key) and fence_key != "" <- active[:fence_key],
         {:ok, fence} <-
           CasRecord.update(
             fence_key,
             fn current ->
               terminalize_transition(
                 current,
                 scope,
                 active,
                 requested_terminal,
                 timeout_terminal,
                 authority
               )
             end,
             create: false
           ) do
      requested_id = requested_terminal["terminal_id"]
      timeout_id = timeout_terminal["terminal_id"]

      outcome =
        case get_in(fence, ["terminal", "terminal_id"]) do
          ^requested_id -> :requested
          ^timeout_id -> :timeout
          _existing -> :existing
        end

      {:ok,
       %Settlement{
         fence: fence,
         outcome: outcome,
         requested_terminal: requested_terminal
       }}
    else
      nil -> {:error, :identity_diagnostic_invalid_fence}
      {:error, _reason} = error -> error
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def terminalize(_scope, _active, _terminal, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Prepares the exact terminal fence bytes for the PostgreSQL authoritative transaction."
  @spec prepare_terminal_commit(String.t(), String.t(), map(), map(), settlement_authority()) ::
          {:ok, map()} | {:error, term()}
  def prepare_terminal_commit(namespace, scope, active, terminal, authority)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_map(active) and is_map(terminal) and
             authority in [:result, :timeout] do
    requested_terminal = Map.put(terminal, "terminal_id", ULID.generate())

    timeout_terminal = %{
      "terminal_id" => ULID.generate(),
      "status" => "skipped_timeout",
      "decision" => %{"action" => "silence"},
      "evaluator" => %{},
      "settled_at" => now()
    }

    with fence_key when is_binary(fence_key) and fence_key != "" <- active[:fence_key],
         {:ok, %{body: bytes, etag: expected_etag}} <- TriageRecordStore.get(fence_key),
         {:ok, current} when is_map(current) <- Jason.decode(bytes),
         {:ok, transitioned} <-
           terminal_commit_transition(
             current,
             scope,
             active,
             requested_terminal,
             timeout_terminal,
             authority
           ),
         {:ok, finalized} <- finalize_terminal_for_commit(transitioned),
         {:ok, fence} <- archive_sealed_generation(namespace, finalized) do
      requested_id = requested_terminal["terminal_id"]
      timeout_id = timeout_terminal["terminal_id"]

      outcome =
        case get_in(fence, ["terminal", "terminal_id"]) do
          ^requested_id -> :requested
          ^timeout_id -> :timeout
          _existing -> :existing
        end

      {:ok,
       %{
         fence_key: fence_key,
         expected_etag: expected_etag,
         fence: fence,
         outcome: outcome,
         requested_terminal: requested_terminal
       }}
    else
      nil -> {:error, :identity_diagnostic_invalid_fence}
      {:error, _reason} = error -> error
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def prepare_terminal_commit(_namespace, _scope, _active, _terminal, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Prepares one recovery terminal for the PostgreSQL authoritative transaction."
  @spec prepare_recovery_commit(String.t(), map(), recovery_authority()) ::
          {:ok, map()} | {:error, term()}
  def prepare_recovery_commit(
        namespace,
        %{
          "bucket_scope" => scope,
          "generation" => generation,
          "terminal" => nil
        } = expected,
        authority
      )
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(generation) and generation != "" and
             authority in [:deadline, :interrupted_worker] do
    terminal_id = ULID.generate()
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    with true <- valid_record?(expected),
         {:ok, winning_input} <- load_winning_input(namespace, expected),
         :ok <- validate_chain(expected, winning_input),
         {:ok, requested_terminal} <-
           interruption_terminal(expected["identity_observation"], terminal_id),
         {:ok, %{body: bytes, etag: expected_etag}} <- TriageRecordStore.get(key),
         {:ok, current} when is_map(current) <- Jason.decode(bytes),
         {:ok, transitioned} <-
           recovery_commit_transition(
             recover_open_transition(current, expected, authority, terminal_id)
           ),
         true <- is_map(transitioned["terminal"]),
         {:ok, finalized} <- finalize_terminal_for_commit(transitioned),
         {:ok, fence} <- archive_sealed_generation(namespace, finalized),
         true <- valid_record?(fence),
         {:ok, recovered_winning_input} <- load_winning_input(namespace, fence),
         :ok <- validate_chain(fence, recovered_winning_input) do
      {:ok,
       %{
         fence_key: key,
         expected_etag: expected_etag,
         fence: fence,
         outcome:
           if(fence["terminal"]["terminal_id"] == terminal_id,
             do: :requested,
             else: :existing
           ),
         requested_terminal: requested_terminal
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def prepare_recovery_commit(_namespace, _fence, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp terminal_commit_transition(
         current,
         scope,
         active,
         requested_terminal,
         timeout_terminal,
         authority
       ) do
    case terminalize_transition(
           current,
           scope,
           active,
           requested_terminal,
           timeout_terminal,
           authority
         ) do
      {:unchanged, fence} -> {:ok, fence}
      {:error, _reason} = error -> error
      fence when is_map(fence) -> {:ok, fence}
    end
  end

  defp recovery_commit_transition({:unchanged, fence}) when is_map(fence), do: {:ok, fence}
  defp recovery_commit_transition({:error, _reason} = error), do: error
  defp recovery_commit_transition(fence) when is_map(fence), do: {:ok, fence}
  defp recovery_commit_transition(_invalid), do: {:error, :identity_diagnostic_invalid_fence}

  defp finalize_terminal_for_commit(
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
           "identity_observation" => %{"state" => "snapshot_bound"} = observation,
           "terminal" => terminal
         } = fence
       )
       when is_map(terminal) do
    finalized =
      Map.put(
        fence,
        "identity_observation",
        observation
        |> Map.put("state", "finalized")
        |> Map.put("finalized_at_ms", now())
      )

    if valid_record?(finalized),
      do: {:ok, finalized},
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp finalize_terminal_for_commit(%{"terminal" => terminal} = fence) when is_map(terminal) do
    if fence["schema"] == "comma.triage-bucket-fence.v1" or valid_record?(fence),
      do: {:ok, fence},
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp finalize_terminal_for_commit(_fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp terminalize_transition(
         current,
         scope,
         active,
         requested_terminal,
         timeout_terminal,
         authority
       ) do
    cond do
      not active_binding?(current, scope, active) ->
        {:error, :identity_diagnostic_invalid_fence}

      current["schema"] == "comma.triage-bucket-fence.v2" and not valid_record?(current) ->
        {:error, :identity_diagnostic_invalid_fence}

      current["schema"] == "comma.triage-bucket-fence.v2" and
          validate_chain(current, active[:identity_winning_input]) != :ok ->
        {:error, :identity_diagnostic_invalid_fence}

      current["terminal"] != nil ->
        {:unchanged, current}

      current["schema"] == "comma.triage-bucket-fence.v2" and deadline_reached?(current) ->
        case interruption_terminal(
               current["identity_observation"],
               timeout_terminal["terminal_id"]
             ) do
          {:ok, identity_terminal} -> put_identity_terminal(current, identity_terminal)
          {:error, _reason} = error -> error
        end

      deadline_reached?(current) ->
        Map.put(current, "terminal", timeout_terminal)

      authority == :timeout ->
        {:error, :deadline_not_reached}

      current["schema"] == "comma.triage-bucket-fence.v2" ->
        put_identity_terminal(current, requested_terminal)

      true ->
        Map.put(current, "terminal", requested_terminal)
    end
  end

  # Every identity terminal is validated as a whole record before it can reach
  # a CAS write: an invalid construction settles as a refusal the caller can
  # turn into a validated diagnostic terminal, never as a durable record no
  # reader can project.
  defp put_identity_terminal(current, terminal) do
    next = Map.put(current, "terminal", terminal)

    if valid_terminal?(terminal) and valid_record?(next),
      do: next,
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp active_binding?(current, scope, active) do
    is_map(current) and current["bucket_scope"] == scope and
      current["generation"] == active[:generation] and current["run_id"] == active[:run_id]
  end

  @type recovery_authority :: :deadline | :interrupted_worker
  @type recovery_view :: {:legacy | :identity, :open | :terminal} | :invalid

  @doc "Classifies one stored fence for Runtime recovery without exposing schema dispatch."
  @spec recovery_view(map()) :: recovery_view()
  def recovery_view(%{"schema" => "comma.triage-bucket-fence.v1", "terminal" => nil}),
    do: {:legacy, :open}

  def recovery_view(%{"schema" => "comma.triage-bucket-fence.v1", "terminal" => terminal})
      when is_map(terminal),
      do: {:legacy, :terminal}

  def recovery_view(%{"schema" => "comma.triage-bucket-fence.v2", "terminal" => terminal} = fence)
      when is_nil(terminal) or is_map(terminal) do
    if valid_record?(fence),
      do: {:identity, if(is_nil(terminal), do: :open, else: :terminal)},
      else: :invalid
  end

  def recovery_view(_fence), do: :invalid

  @doc "Recovers one exact open identity fence through its durable winning generation."
  @spec recover_open(String.t(), map(), recovery_authority()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def recover_open(
        namespace,
        %{
          "bucket_scope" => scope,
          "generation" => generation,
          "terminal" => nil
        } = fence,
        authority
      )
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(generation) and generation != "" and
             authority in [:deadline, :interrupted_worker] do
    terminal_id = ULID.generate()
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    with true <- valid_record?(fence),
         {:ok, winning_input} <- load_winning_input(namespace, fence),
         :ok <- validate_chain(fence, winning_input),
         {:ok, recovered} <-
           CasRecord.update(
             key,
             fn current ->
               recover_open_transition(current, fence, authority, terminal_id)
             end,
             create: false
           ),
         true <- valid_record?(recovered),
         true <- is_map(recovered["terminal"]),
         {:ok, recovered_winning_input} <- load_winning_input(namespace, recovered),
         :ok <- validate_chain(recovered, recovered_winning_input) do
      {:ok, recovered}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def recover_open(_namespace, _fence, _authority),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Reads and settles the exact physical fence for one interrupted active run."
  @spec recover_interrupted(binary(), binary(), map()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def recover_interrupted(namespace, scope, active)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_map(active) do
    with {:ok, fence} <- read_interrupted(namespace, scope, active) do
      case fence["terminal"] do
        nil ->
          recover_open(namespace, fence, :interrupted_worker)

        terminal when is_map(terminal) ->
          {:ok, fence}

        _invalid ->
          {:error, :identity_diagnostic_invalid_fence}
      end
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def recover_interrupted(_namespace, _scope, _active),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Reads and validates the exact physical fence for one interrupted active run."
  @spec read_interrupted(binary(), binary(), map()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def read_interrupted(namespace, scope, active)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_map(active) do
    with fence_key when is_binary(fence_key) and fence_key != "" <- active[:fence_key],
         generation when is_binary(generation) and generation != "" <- active[:generation],
         run_id when is_binary(run_id) and run_id != "" <- active[:run_id],
         {:ok, fence} <- CasRecord.get(fence_key),
         ^fence_key <- projection_key(namespace, fence),
         true <- valid_record?(fence),
         true <- fence["bucket_scope"] == scope,
         true <- fence["generation"] == generation,
         true <- fence["run_id"] == run_id,
         :ok <- validate_chain_from_storage(namespace, fence) do
      {:ok, fence}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def read_interrupted(_namespace, _scope, _active),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Looks up one interrupted fence from its Runtime-owned exact physical binding."
  @spec lookup_interrupted(binary(), map()) ::
          {:ok, binary(), map()}
          | {:error, :identity_diagnostic_invalid_fence | :storage_unavailable}
  def lookup_interrupted(namespace, pending)
      when is_binary(namespace) and namespace != "" and is_map(pending) do
    with fence_key when is_binary(fence_key) and fence_key != "" <- pending[:fence_key],
         fence_ref_sha256 when is_binary(fence_ref_sha256) <- pending[:fence_ref_sha256],
         true <- sha256(fence_key) == fence_ref_sha256,
         generation when is_binary(generation) and generation != "" <- pending[:generation],
         run_id when is_binary(run_id) and run_id != "" <- pending[:run_id] do
      case CasRecord.get(fence_key) do
        {:ok, fence} ->
          with true <- valid_record?(fence),
               ^fence_key <- projection_key(namespace, fence),
               true <- fence["generation"] == generation,
               true <- fence["run_id"] == run_id do
            {:ok, fence_key, fence}
          else
            _invalid -> {:error, :identity_diagnostic_invalid_fence}
          end

        {:error, :not_found} ->
          {:error, :identity_diagnostic_invalid_fence}

        {:error, _reason} ->
          {:error, :storage_unavailable}
      end
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def lookup_interrupted(_namespace, _pending),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Finalizes one exact terminal snapshot-bound identity fence before public projection."
  @spec finalize(String.t(), map()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def finalize(
        namespace,
        %{
          "bucket_scope" => scope,
          "generation" => generation,
          "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
          "identity_observation" => %{"state" => "snapshot_bound"} = observation,
          "terminal" => terminal
        } = fence
      )
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(generation) and generation != "" and is_map(terminal) do
    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

    with true <- valid_record?(fence),
         {:ok, winning_input} <- load_winning_input(namespace, fence),
         :ok <- validate_chain(fence, winning_input, stored_decision_mode(namespace, fence)),
         {:ok, finalized} <-
           CasRecord.update(
             key,
             fn current -> finalize_transition(current, fence, observation) end,
             create: false
           ),
         true <- valid_record?(finalized),
         "finalized" <- get_in(finalized, ["identity_observation", "state"]),
         true <- finalized["terminal"] == terminal,
         {:ok, finalized_winning_input} <- load_winning_input(namespace, finalized),
         :ok <-
           validate_chain(
             finalized,
             finalized_winning_input,
             stored_decision_mode(namespace, finalized)
           ) do
      {:ok, finalized}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def finalize(_namespace, _fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Binds one legacy frozen model input to its exact open compatibility fence."
  @spec bind_compatibility_snapshot(String.t(), map(), map()) ::
          :ok | {:error, :snapshot_freeze_lost_authority}
  def bind_compatibility_snapshot(
        fence_key,
        %{"schema" => "comma.triage-input-snapshot.v1"} = base_input,
        %{"schema" => "comma.triage-model-input.v1"} = model_input
      )
      when is_binary(fence_key) and fence_key != "" do
    case CasRecord.update(
           fence_key,
           fn current ->
             bind_compatibility_snapshot_transition(current, base_input, model_input)
           end,
           create: false
         ) do
      {:ok, %{"terminal" => nil, "input_snapshot" => ^model_input}} ->
        :ok

      _lost ->
        {:error, :snapshot_freeze_lost_authority}
    end
  end

  def bind_compatibility_snapshot(_fence_key, _base_input, _model_input),
    do: {:error, :snapshot_freeze_lost_authority}

  @doc "Authorizes one exact snapshot-bound model invocation from durable state."
  @spec authorize_model(String.t(), map()) ::
          :proceed | {:error, :identity_fence_denied}
  def authorize_model(namespace, active)
      when is_binary(namespace) and namespace != "" and is_map(active) do
    with {:ok, _fence, _winning_input} <- load_authorized_snapshot(namespace, active) do
      :proceed
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def authorize_model(_namespace, _active), do: {:error, :identity_fence_denied}

  @doc "Returns the ephemeral Agent identity bound to an authorized model run."
  @spec model_runtime_authorization(String.t(), map()) ::
          {:ok, map()} | {:error, :identity_fence_denied}
  def model_runtime_authorization(namespace, active)
      when is_binary(namespace) and namespace != "" and is_map(active) do
    with {:ok,
          %{
            "identity_observation" => %{
              "private_projection" => %{
                "raw_source_bundle_bytes" => raw_bundle_bytes
              }
            }
          }, _winning_input} <- load_authorized_snapshot(namespace, active),
         true <- is_binary(raw_bundle_bytes),
         {:ok, raw_bundle} <- Jason.decode(raw_bundle_bytes),
         agent_id <- get_in(raw_bundle, ["product_identity", "salix_agent_id"]),
         identity_revision <-
           get_in(raw_bundle, [
             "raw_identity_context",
             "self_agent",
             "identity_revision_sha256"
           ]),
         true <- nonempty?(agent_id),
         true <- valid_sha256?(identity_revision) do
      {:ok,
       %{
         "schema" => "comma.triage-model-runtime-authorization.v1",
         "agent_id" => agent_id,
         "identity_revision_sha256" => identity_revision
       }}
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def model_runtime_authorization(_namespace, _active),
    do: {:error, :identity_fence_denied}

  @doc "Validates one model decision against the exact durable snapshot authority."
  @spec validate_model_decision(String.t(), map(), term()) ::
          :ok | {:error, :identity_projection_invalid | :identity_decision_invalid}
  def validate_model_decision(namespace, active, decision)
      when is_binary(namespace) and namespace != "" and is_map(active) do
    with {:ok,
          %{
            "identity_observation" => %{
              "claim" => claim,
              "transport_result" => transport_result,
              "private_projection" => private_projection
            }
          }, winning_input} <- load_authorized_snapshot(namespace, active) do
      IdentityContract.validate_bound_decision(
        decision,
        private_projection,
        claim,
        transport_result,
        winning_source_anchor(winning_input)
      )
    else
      _denied -> {:error, :identity_projection_invalid}
    end
  end

  def validate_model_decision(_namespace, _active, _decision),
    do: {:error, :identity_projection_invalid}

  @doc "Returns the exact source-bound private context for bounded read-tool policy."
  @spec authorize_read_context(String.t(), map()) ::
          {:ok, AuthorizedReadContext.t()} | {:error, :identity_fence_denied}
  def authorize_read_context(namespace, active)
      when is_binary(namespace) and namespace != "" and is_map(active) do
    with {:ok,
          %{
            "run_id" => run_id,
            "identity_observation" => %{
              "claim" => claim,
              "transport_result" => transport_result,
              "private_projection" => private_projection
            }
          } = fence, winning_input} <- load_authorized_snapshot(namespace, active),
         {:ok, _projection} <-
           IdentityContract.recompute_bound_projection(
             private_projection,
             claim,
             transport_result,
             winning_source_anchor(winning_input)
           ),
         {:ok, alias_map} <- Jason.decode(private_projection["alias_map_bytes"]),
         {:ok, raw_bundle} <- Jason.decode(private_projection["raw_source_bundle_bytes"]) do
      {:ok,
       %AuthorizedReadContext{
         fence: fence,
         run_id: run_id,
         raw_bundle: raw_bundle,
         alias_map: alias_map
       }}
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def authorize_read_context(_namespace, _active),
    do: {:error, :identity_fence_denied}

  @doc "Authorizes the sealed raw authority needed to materialize product effects."
  @spec authorize_product_effects_from_storage(String.t(), map()) ::
          {:ok, AuthorizedProductEffects.t()} | {:error, :identity_diagnostic_invalid_fence}
  def authorize_product_effects_from_storage(
        namespace,
        %{
          "terminal" => %{
            "status" => "evaluated",
            "decision" => %{"schema" => schema}
          }
        } = fence
      )
      when is_binary(namespace) and namespace != "" and
             schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"] do
    with true <- valid_record?(fence),
         true <- authoritative_stage?(fence),
         {:ok, winning_input} <- load_winning_input(namespace, fence),
         true <-
           winning_input["source_mode"] in [
             "callback",
             "clickhouse_etl",
             "periodic_patrol",
             "scheduled_recheck"
           ],
         :ok <- validate_chain(fence, winning_input, stored_decision_mode(namespace, fence)),
         %{
           "private_projection" => private_projection
         } <- fence["identity_observation"],
         :ok <- validate_identity_private_projection(private_projection),
         {:ok, raw_bundle} <- Jason.decode(private_projection["raw_source_bundle_bytes"]),
         {:ok, alias_map} <- Jason.decode(private_projection["alias_map_bytes"]),
         true <- raw_bundle["source_authority"] == winning_input["source_authority"] do
      {:ok,
       %AuthorizedProductEffects{
         fence: fence,
         run_id: fence["run_id"],
         raw_bundle: raw_bundle,
         alias_map: alias_map
       }}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def authorize_product_effects_from_storage(_namespace, _fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp load_authorized_snapshot(namespace, active) do
    with fence_key when is_binary(fence_key) and fence_key != "" <- active[:fence_key],
         {:ok, fence} <- CasRecord.get(fence_key),
         true <- valid_record?(fence),
         true <- fence["run_id"] == active[:run_id],
         true <- fence["generation"] == active[:generation],
         false <- deadline_reached?(fence),
         nil <- fence["terminal"],
         "snapshot_bound" <- get_in(fence, ["identity_observation", "state"]),
         {:ok, winning_input} <- load_winning_input(namespace, fence),
         true <- winning_input == active[:identity_winning_input],
         :ok <- validate_chain(fence, winning_input) do
      {:ok, fence, winning_input}
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  defp bind_compatibility_snapshot_transition(
         %{
           "schema" => "comma.triage-bucket-fence.v1",
           "terminal" => nil,
           "input_snapshot" => current_input
         } = current,
         base_input,
         model_input
       ) do
    cond do
      deadline_reached?(current) ->
        {:unchanged, current}

      current_input == model_input ->
        {:unchanged, current}

      current_input == base_input ->
        Map.put(current, "input_snapshot", model_input)

      true ->
        {:unchanged, current}
    end
  end

  defp bind_compatibility_snapshot_transition(current, _base_input, _model_input),
    do: {:unchanged, current}

  defp finalize_transition(current, expected, observation) do
    if current == expected do
      finalized =
        Map.put(
          current,
          "identity_observation",
          observation
          |> Map.put("state", "finalized")
          |> Map.put("finalized_at_ms", now())
        )

      if valid_record?(finalized),
        do: finalized,
        else: {:error, :identity_diagnostic_invalid_fence}
    else
      {:error, :identity_diagnostic_invalid_fence}
    end
  end

  @doc "Builds the closed stage-derived terminal used by timeout and recovery CAS."
  @spec interruption_terminal(map(), String.t()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def interruption_terminal(observation, terminal_id) when is_binary(terminal_id) do
    with true <- ULID.valid?(terminal_id),
         {:ok, reason} <- recovery_reason(observation) do
      {:ok, recovery_terminal(terminal_id, reason)}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def interruption_terminal(_observation, _terminal_id),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp recover_open_transition(current, expected, authority, terminal_id) do
    with true <- valid_record?(current),
         nil <- current["terminal"],
         true <- current == expected,
         true <- recovery_authority_allowed?(current, authority),
         {:ok, reason} <- recovery_reason(current["identity_observation"]) do
      put_identity_terminal(current, recovery_terminal(terminal_id, reason))
    else
      %{} -> {:unchanged, current}
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp recovery_authority_allowed?(_fence, :interrupted_worker), do: true
  defp recovery_authority_allowed?(fence, :deadline), do: deadline_reached?(fence)

  defp recovery_reason(%{"state" => state}) when state in ~w(unused claimed),
    do: {:ok, "identity_diagnostic_interrupted_before_transport"}

  defp recovery_reason(%{"state" => "transport_maybe_started"}),
    do: {:ok, "identity_diagnostic_indeterminate_transport"}

  defp recovery_reason(%{
         "state" => "committed",
         "transport_result" => %{"kind" => "success"}
       }),
       do: {:ok, "identity_diagnostic_interrupted_after_read"}

  defp recovery_reason(%{
         "state" => "committed",
         "transport_result" => %{"kind" => kind, "reason_code" => reason}
       })
       when kind in ~w(attempted_error local_rejected),
       do: {:ok, reason}

  defp recovery_reason(%{"state" => "projection_bound"}),
    do: {:ok, "identity_diagnostic_interrupted_after_read"}

  defp recovery_reason(%{"state" => "snapshot_bound"}),
    do: {:ok, "identity_diagnostic_indeterminate_model"}

  defp recovery_reason(_observation),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp recovery_terminal(terminal_id, reason) do
    %{
      "terminal_id" => terminal_id,
      "status" => "failed",
      "decision" => %{"action" => "silence", "reason" => reason},
      "evaluator" => %{},
      "settled_at" => now()
    }
  end

  defp initial_record(scope, run_id, input, created_at, deadline_at, true) do
    %{
      "schema" => "comma.triage-bucket-fence.v2",
      "bucket_scope" => scope,
      "public_bucket_ref" => "bucket://run/scope",
      "generation" => input["generation"],
      "run_id" => run_id,
      "created_at" => created_at,
      "deadline_at" => deadline_at,
      "input_snapshot" => base_projection(input),
      "identity_observation" => %{
        "schema" => "comma.triage-identity-observation.v1",
        "state" => "unused"
      },
      "terminal" => nil
    }
  end

  defp initial_record(scope, run_id, input, created_at, deadline_at, false) do
    %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => scope,
      "generation" => input["generation"],
      "run_id" => run_id,
      "created_at" => created_at,
      "deadline_at" => deadline_at,
      "input_snapshot" => input,
      "terminal" => nil
    }
  end

  defp identity_run?(%{
         "schema" => "comma.triage-input-snapshot.v2",
         "source_mode" => source_mode
       })
       when source_mode in [
              "callback",
              "clickhouse_etl",
              "historical_thread_reenactment",
              "periodic_patrol",
              "scheduled_recheck"
            ],
       do: true

  defp identity_run?(_input), do: false

  def transition(active, :claim, claim) do
    with :ok <- validate_identity_claim(claim),
         {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "unused"
                                            } ->
             Map.put(current, "identity_observation", %{
               "schema" => "comma.triage-identity-observation.v1",
               "state" => "claimed",
               "claim" => claim,
               "claimed_at_ms" => now()
             })
           end),
         "claimed" <- get_in(fence, ["identity_observation", "state"]) do
      :ok
    else
      _ -> {:error, :identity_fence_denied}
    end
  end

  def transition(active, :mark_transport, nil) do
    attempt_id = active.identity_transport_attempt_id

    with {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "claimed",
                                              "claim" => claim,
                                              "claimed_at_ms" => claimed_at
                                            } ->
             Map.put(current, "identity_observation", %{
               "schema" => "comma.triage-identity-observation.v1",
               "state" => "transport_maybe_started",
               "claim" => claim,
               "claimed_at_ms" => claimed_at,
               "transport_attempt_id" => attempt_id,
               "transport_marked_at_ms" => now()
             })
           end),
         ^attempt_id <- get_in(fence, ["identity_observation", "transport_attempt_id"]) do
      :proceed
    else
      _ -> {:error, :identity_fence_denied}
    end
  end

  def transition(active, :commit_transport, transport_result) do
    with :ok <- validate_identity_transport_result(transport_result),
         {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "transport_maybe_started",
                                              "claim" => claim,
                                              "claimed_at_ms" => claimed_at,
                                              "transport_attempt_id" => attempt_id,
                                              "transport_marked_at_ms" => marked_at
                                            }
                                            when attempt_id ==
                                                   active.identity_transport_attempt_id ->
             if transport_result_matches_claim?(transport_result, claim) do
               Map.put(current, "identity_observation", %{
                 "schema" => "comma.triage-identity-observation.v1",
                 "state" => "committed",
                 "claim" => claim,
                 "claimed_at_ms" => claimed_at,
                 "transport_attempt_id" => attempt_id,
                 "transport_marked_at_ms" => marked_at,
                 "transport_result" => transport_result,
                 "committed_at_ms" => now()
               })
             else
               {:error, :identity_fence_denied}
             end
           end),
         "committed" <- get_in(fence, ["identity_observation", "state"]) do
      :ok
    else
      _ -> {:error, :identity_fence_denied}
    end
  end

  def transition(
        active,
        :bind_projection,
        %{private_projection: private_projection, context_sha256: context_sha256}
      ) do
    with :ok <- validate_identity_private_projection(private_projection),
         true <- valid_sha256?(context_sha256),
         true <- private_projection["projected_context_sha256"] == context_sha256,
         {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "committed",
                                              "claim" => claim,
                                              "claimed_at_ms" => claimed_at,
                                              "transport_attempt_id" => attempt_id,
                                              "transport_marked_at_ms" => marked_at,
                                              "transport_result" =>
                                                %{
                                                  "kind" => "success"
                                                } = transport_result,
                                              "committed_at_ms" => committed_at
                                            } ->
             case IdentityContract.recompute_bound_projection(
                    private_projection,
                    claim,
                    transport_result,
                    active.identity_winning_source_anchor
                  ) do
               {:ok, %{sha256: ^context_sha256}} ->
                 Map.put(current, "identity_observation", %{
                   "schema" => "comma.triage-identity-observation.v1",
                   "state" => "projection_bound",
                   "claim" => claim,
                   "claimed_at_ms" => claimed_at,
                   "transport_attempt_id" => attempt_id,
                   "transport_marked_at_ms" => marked_at,
                   "transport_result" => transport_result,
                   "committed_at_ms" => committed_at,
                   "private_projection" => private_projection,
                   "pseudonymous_context_sha256" => context_sha256,
                   "projection_bound_at_ms" => now()
                 })

               _invalid ->
                 {:error, :identity_fence_denied}
             end
           end),
         "projection_bound" <- get_in(fence, ["identity_observation", "state"]) do
      :ok
    else
      _ -> {:error, :identity_fence_denied}
    end
  end

  def transition(active, :bind_snapshot, model_input) do
    with {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "projection_bound"
                                            } ->
             bind_snapshot_transition(current, active, model_input)
           end),
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "terminal" => nil,
           "input_snapshot" => ^model_input,
           "identity_observation" => %{"state" => "snapshot_bound"}
         } <- fence do
      :ok
    else
      _ -> {:error, :identity_fence_denied}
    end
  end

  def transition(active, :commit_read_tool, read_tool_observation) do
    with true <- valid_read_tool_observation?(read_tool_observation),
         {:ok, fence} <-
           update_identity_fence(active, fn current,
                                            %{
                                              "schema" => "comma.triage-identity-observation.v1",
                                              "state" => "snapshot_bound"
                                            } = observation ->
             next =
               Map.put(
                 current,
                 "identity_observation",
                 Map.put(observation, "read_tool_result", read_tool_observation)
               )

             if valid_record?(next), do: next, else: {:error, :identity_fence_denied}
           end),
         ^read_tool_observation <- get_in(fence, ["identity_observation", "read_tool_result"]) do
      :ok
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  def transition(_active, _action, _payload),
    do: {:error, :identity_fence_denied}

  defp bind_snapshot_transition(
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "terminal" => nil,
           "input_snapshot" => stored_base,
           "identity_observation" =>
             %{
               "schema" => "comma.triage-identity-observation.v1",
               "state" => "projection_bound",
               "claim" => claim,
               "transport_result" => transport_result,
               "private_projection" => private_projection,
               "pseudonymous_context_sha256" => projected_context_sha256
             } = observation
         } = current,
         active,
         %{
           "schema" => "comma.triage-model-input.v3",
           "snapshot" => snapshot,
           "canonical_snapshot_bytes" => snapshot_bytes,
           "canonical_snapshot_sha256" => snapshot_sha256
         } = model_input
       ) do
    with true <- base_projection_matches?(stored_base, active.identity_winning_input),
         {:ok, %{sha256: ^projected_context_sha256}} <-
           IdentityContract.recompute_bound_projection(
             private_projection,
             claim,
             transport_result,
             active.identity_winning_source_anchor
           ),
         {:ok, ^snapshot_bytes} <- CanonicalJSON.encode(snapshot),
         true <- CanonicalJSON.sha256(snapshot_bytes) == snapshot_sha256,
         true <- projected_context_sha256(snapshot) == projected_context_sha256 do
      next =
        current
        |> Map.put("input_snapshot", model_input)
        |> Map.put(
          "identity_observation",
          observation
          |> Map.put("state", "snapshot_bound")
          |> Map.put("canonical_snapshot_sha256", snapshot_sha256)
          |> Map.put("snapshot_bound_at_ms", now())
        )

      if valid_record?(next), do: next, else: {:error, :identity_fence_denied}
    else
      _invalid -> {:error, :identity_fence_denied}
    end
  end

  defp bind_snapshot_transition(_current, _active, _model_input),
    do: {:error, :identity_fence_denied}

  defp update_identity_fence(active, transition) do
    try do
      CasRecord.update(
        active.fence_key,
        fn current ->
          if valid_identity_fence_for_transition?(current, active) do
            apply_identity_transition(transition, current, current["identity_observation"])
          else
            {:error, :identity_fence_denied}
          end
        end,
        create: false
      )
    rescue
      _error -> {:error, :identity_fence_denied}
    catch
      _kind, _reason -> {:error, :identity_fence_denied}
    end
  end

  # Same rule as the terminal writers: no identity transition may leave a
  # record the closed schema rejects, so the CAS callback validates the whole
  # constructed record before it can be stored.
  defp apply_identity_transition(transition, current, observation) do
    case transition.(current, observation) do
      %{} = next -> if valid_record?(next), do: next, else: {:error, :identity_fence_denied}
      _ -> {:error, :identity_fence_denied}
    end
  rescue
    _error -> {:error, :identity_fence_denied}
  catch
    _kind, _reason -> {:error, :identity_fence_denied}
  end

  defp valid_identity_fence_for_transition?(current, active) do
    valid_record?(current) and
      current["run_id"] == active.run_id and current["generation"] == active.generation and
      not deadline_reached?(current) and is_nil(current["terminal"]) and
      identity_base_input_matches?(current, active)
  end

  def base_projection(input) do
    events =
      input
      |> Map.get("events", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} ->
        event
        |> Map.take(~w(actor_kind event_type addressing_kind trigger_kind fast_path))
        |> Map.merge(%{
          "event_ref" => "event://run/e#{pad_ordinal(index)}",
          "ordinal" => index,
          "fast_path" => event["fast_path"] == true
        })
        |> maybe_put_addressed_recipient_ref(event)
      end)

    receipt_refs =
      input
      |> Map.get("receipt_refs", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {_receipt_ref, index} -> "receipt://run/r#{pad_ordinal(index)}" end)

    authority = input["source_authority"] || %{}

    %{
      "schema" => "comma.triage-ledger-input-projection.v2",
      "source_mode" => input["source_mode"],
      "event_count" => length(events),
      "receipt_count" => length(receipt_refs),
      "events" => events,
      "receipt_refs" => receipt_refs,
      "source_authority" => %{
        "provider" => "slack",
        "scope_kind" => authority["scope_kind"] || "thread",
        "workspace_ref" => "workspace://run/self",
        "bucket_ref" => "bucket://run/scope",
        "endpoint_ref" => "endpoint://run/self"
      }
    }
  end

  defp maybe_put_addressed_recipient_ref(projected, %{"addressing_kind" => "directed"}),
    do: Map.put(projected, "addressed_recipient_ref", "endpoint://run/self")

  defp maybe_put_addressed_recipient_ref(projected, _ambient_or_invalid), do: projected

  # Pre-release v1 fences can be read during a rolling replacement, but every
  # writer emits v2. V1 lacked addressing evidence, so validation reproduces
  # its exact historical projection from the authoritative input; it never
  # upgrades the immutable fence bytes in place or treats v1 as a v2 shape.
  defp legacy_base_projection(input) do
    events =
      input
      |> Map.get("events", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} ->
        %{
          "event_ref" => "event://run/e#{pad_ordinal(index)}",
          "ordinal" => index,
          "fast_path" => event["fast_path"] == true
        }
      end)

    receipt_refs =
      input
      |> Map.get("receipt_refs", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {_receipt_ref, index} -> "receipt://run/r#{pad_ordinal(index)}" end)

    authority = input["source_authority"] || %{}

    %{
      "schema" => "comma.triage-ledger-input-projection.v1",
      "source_mode" => input["source_mode"],
      "event_count" => length(events),
      "receipt_count" => length(receipt_refs),
      "events" => events,
      "receipt_refs" => receipt_refs,
      "source_authority" => %{
        "provider" => "slack",
        "scope_kind" => authority["scope_kind"] || "thread",
        "workspace_ref" => "workspace://run/self",
        "bucket_ref" => "bucket://run/scope",
        "endpoint_ref" => "endpoint://run/self"
      }
    }
  end

  defp base_projection_matches?(
         %{"schema" => "comma.triage-ledger-input-projection.v1"} = stored,
         winning_input
       ),
       do: stored == legacy_base_projection(winning_input)

  defp base_projection_matches?(stored, winning_input),
    do: stored == base_projection(winning_input)

  @doc "Authorizes one already-terminal identity fence for public Ledger projection."
  @spec authorize_projection(map(), map()) ::
          {:ok, AuthorizedProjection.t()} | {:error, :identity_diagnostic_invalid_fence}
  def authorize_projection(fence, winning_input),
    do: authorize_projection(fence, winning_input, :current)

  defp authorize_projection(fence, winning_input, mode) do
    with true <- valid_record?(fence),
         true <- is_map(fence["terminal"]),
         true <- authoritative_stage?(fence),
         :ok <- validate_chain(fence, winning_input, mode),
         {:ok, correlations} <- Correlation.bindings(winning_input) do
      {:ok, %AuthorizedProjection{fence: fence, correlations: correlations}}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  @doc "Loads the exact durable winning input before authorizing a projection."
  @spec authorize_projection_from_storage(binary(), map()) ::
          {:ok, AuthorizedProjection.t()} | {:error, :identity_diagnostic_invalid_fence}
  def authorize_projection_from_storage(namespace, fence)
      when is_binary(namespace) and namespace != "" and is_map(fence) do
    with {:ok, winning_input} <- load_winning_input(namespace, fence) do
      authorize_projection(fence, winning_input, stored_decision_mode(namespace, fence))
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def authorize_projection_from_storage(_namespace, _fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Finalizes a snapshot-bound terminal when needed before public authorization."
  @spec prepare_authoritative_projection(binary(), map()) ::
          {:ok, map()} | {:error, :identity_diagnostic_invalid_fence}
  def prepare_authoritative_projection(namespace, fence),
    do: prepare_projection(namespace, fence)

  @doc "Authorizes one terminal identity projection from its exact physical fence key."
  @spec authorize_projection_from_key(binary(), binary()) ::
          {:ok, AuthorizedProjection.t()} | {:error, :identity_diagnostic_invalid_fence}
  def authorize_projection_from_key(namespace, fence_key)
      when is_binary(namespace) and namespace != "" and is_binary(fence_key) and
             fence_key != "" do
    with {:ok, fence} <- CasRecord.get(fence_key),
         ^fence_key <- projection_key(namespace, fence),
         {:ok, ready} <- prepare_projection(namespace, fence),
         {:ok, authorized_projection} <- authorize_projection_from_storage(namespace, ready) do
      {:ok, authorized_projection}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def authorize_projection_from_key(_namespace, _fence_key),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc "Checks whether the immediate durable predecessor permits a generation to start."
  @spec predecessor_authoritative?(binary(), binary(), binary()) :: boolean()
  def predecessor_authoritative?(namespace, scope, generation)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(generation) and generation != "" do
    with {:ok, bucket} <- Bucketing.load(namespace, scope),
         sealed_generations when is_list(sealed_generations) <- bucket["sealed_generations"],
         index when is_integer(index) <-
           Enum.find_index(sealed_generations, &(&1["generation"] == generation)) do
      case if(index == 0, do: nil, else: Enum.at(sealed_generations, index - 1)) do
        nil ->
          true

        %{"generation" => predecessor_generation} when is_binary(predecessor_generation) ->
          fence_key =
            SalixStore.TriageKeys.ctl_im_triage_bucket_seal(
              namespace,
              scope,
              predecessor_generation
            )

          with {:ok, fence} <- CasRecord.get(fence_key),
               ^fence_key <- projection_key(namespace, fence),
               true <- fence["bucket_scope"] == scope,
               true <- fence["generation"] == predecessor_generation do
            predecessor_fence_authoritative?(namespace, fence)
          else
            _missing_or_invalid -> false
          end

        _invalid_predecessor ->
          false
      end
    else
      _missing_or_invalid -> false
    end
  end

  def predecessor_authoritative?(_namespace, _scope, _generation), do: false

  @doc "Returns whether one generation already has a physical fence record."
  @spec generation_status(binary(), binary(), binary()) :: :present | :missing | :unavailable
  def generation_status(namespace, scope, generation)
      when is_binary(namespace) and namespace != "" and is_binary(scope) and scope != "" and
             is_binary(generation) and generation != "" do
    namespace
    |> SalixStore.TriageKeys.ctl_im_triage_bucket_seal(scope, generation)
    |> CasRecord.get()
    |> case do
      {:ok, _record} -> :present
      {:error, :not_found} -> :missing
      {:error, _reason} -> :unavailable
    end
  end

  def generation_status(_namespace, _scope, _generation), do: :unavailable

  defp predecessor_fence_authoritative?(
         _namespace,
         %{"schema" => "comma.triage-bucket-fence.v1", "terminal" => terminal}
       ),
       do: is_map(terminal)

  defp predecessor_fence_authoritative?(
         namespace,
         %{"schema" => "comma.triage-bucket-fence.v2"} = fence
       ) do
    match?({:ok, %AuthorizedProjection{}}, authorize_projection_from_storage(namespace, fence))
  end

  defp predecessor_fence_authoritative?(_namespace, _fence), do: false

  @doc "Validates one exact fence against its durable winning bucket generation."
  @spec validate_chain_from_storage(binary(), map()) ::
          :ok | {:error, :identity_diagnostic_invalid_fence}
  def validate_chain_from_storage(namespace, fence)
      when is_binary(namespace) and namespace != "" and is_map(fence) do
    with true <- valid_record?(fence),
         {:ok, winning_input} <- load_winning_input(namespace, fence),
         :ok <- validate_chain(fence, winning_input, stored_decision_mode(namespace, fence)) do
      :ok
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  def validate_chain_from_storage(_namespace, _fence),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp prepare_projection(
         namespace,
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
           "identity_observation" => %{"state" => "snapshot_bound"},
           "terminal" => terminal
         } = fence
       )
       when is_map(terminal),
       do: finalize(namespace, fence)

  defp prepare_projection(
         _namespace,
         %{
           "schema" => "comma.triage-bucket-fence.v2",
           "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
           "identity_observation" => %{"state" => "finalized"},
           "terminal" => terminal
         } = fence
       )
       when is_map(terminal),
       do: {:ok, fence}

  defp prepare_projection(
         _namespace,
         %{"schema" => "comma.triage-bucket-fence.v2", "terminal" => terminal} = fence
       )
       when is_map(terminal) do
    if valid_record?(fence),
      do: {:ok, fence},
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp prepare_projection(
         _namespace,
         %{"schema" => "comma.triage-bucket-fence.v1", "terminal" => terminal} = fence
       )
       when is_map(terminal),
       do: {:ok, fence}

  defp prepare_projection(_namespace, _fence), do: {:error, :identity_diagnostic_invalid_fence}

  defp projection_key(
         namespace,
         %{"bucket_scope" => scope, "generation" => generation}
       )
       when is_binary(scope) and scope != "" and is_binary(generation) and generation != "",
       do: SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)

  defp projection_key(_namespace, _fence), do: nil

  @doc "Validates a fence against the exact durable winning input without publishing it."
  @spec validate_chain(map(), map()) ::
          :ok | {:error, :identity_diagnostic_invalid_fence}
  def validate_chain(fence, winning_input), do: validate_chain(fence, winning_input, :current)

  defp validate_chain(
         %{"identity_observation" => %{"state" => state}} = fence,
         winning_input,
         _mode
       )
       when state in ~w(unused claimed transport_maybe_started committed) do
    if base_projection_matches?(fence_base_projection(fence), winning_input),
      do: :ok,
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp validate_chain(
         %{
           "identity_observation" => %{
             "state" => state,
             "claim" => claim,
             "transport_result" => transport_result,
             "private_projection" => private_projection,
             "pseudonymous_context_sha256" => projected_context_sha256
           }
         } = fence,
         winning_input,
         mode
       )
       when state in ~w(projection_bound snapshot_bound finalized) do
    with true <- base_projection_matches?(fence_base_projection(fence), winning_input),
         {:ok, %{sha256: ^projected_context_sha256}} <-
           IdentityContract.recompute_bound_projection(
             private_projection,
             claim,
             transport_result,
             winning_source_anchor(winning_input)
           ),
         :ok <- validate_terminal_binding(fence, winning_input, mode) do
      :ok
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_chain(_fence, _winning_input, _mode),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp authoritative_stage?(%{
         "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"},
         "identity_observation" => %{"state" => "finalized"}
       }),
       do: true

  defp authoritative_stage?(%{
         "input_snapshot" => %{"schema" => "comma.triage-model-input.v3"}
       }),
       do: false

  defp authoritative_stage?(_fence), do: true

  defp validate_terminal_binding(
         %{
           "terminal" => %{
             "status" => "evaluated",
             "decision" => decision,
             "evaluator" => proof
           },
           "input_snapshot" => model_input,
           "identity_observation" =>
             %{
               "claim" => claim,
               "transport_result" => transport_result,
               "private_projection" => private_projection
             } = observation
         },
         winning_input,
         mode
       ) do
    with true <- valid_model_proof?(proof),
         true <- proof["canonical_snapshot_sha256"] == model_input["canonical_snapshot_sha256"],
         true <- proof["source_refs_sha256"] == model_input["source_refs_sha256"],
         :ok <- validate_evaluation_binding(proof, model_input, decision, observation),
         true <- participation_result_matches?(proof, decision),
         true <- participation_snapshot_matches?(proof, model_input["canonical_snapshot_bytes"]),
         :ok <- validate_review_binding(proof, model_input, decision),
         :ok <-
           validate_terminal_decision(
             mode,
             decision,
             private_projection,
             claim,
             transport_result,
             winning_source_anchor(winning_input)
           ) do
      :ok
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_terminal_binding(%{"terminal" => nil}, _winning_input, _mode), do: :ok

  defp validate_terminal_binding(%{"terminal" => terminal}, _winning_input, _mode)
       when is_map(terminal) do
    if valid_terminal?(terminal),
      do: :ok,
      else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp validate_terminal_binding(_fence, _winning_input, _mode),
    do: {:error, :identity_diagnostic_invalid_fence}

  defp validate_terminal_decision(:replay, decision, projection, claim, transport, anchor),
    do:
      IdentityContract.validate_replayed_bound_decision(
        decision,
        projection,
        claim,
        transport,
        anchor
      )

  defp validate_terminal_decision(:current, decision, projection, claim, transport, anchor),
    do: IdentityContract.validate_bound_decision(decision, projection, claim, transport, anchor)

  # New v2 decisions still require expression-aware snapshots. Historical v2
  # decisions may use the old standard palette only when the exact terminal is
  # already stored. A prepared replacement of an open fence cannot use replay.
  defp stored_decision_mode(
         namespace,
         %{
           "terminal" => %{"decision" => %{"schema" => "comma.triage-product-decision.v2"}},
           "input_snapshot" => %{"snapshot" => %{"schema" => "comma.triage-context-snapshot.v5"}}
         } = fence
       ) do
    case CasRecord.get(projection_key(namespace, fence)) do
      {:ok, ^fence} -> :replay
      _not_stored -> :current
    end
  end

  defp stored_decision_mode(_namespace, _fence), do: :current

  defp validate_evaluation_binding(
         %{"schema" => "comma.triage-worker-assignment.v1"},
         input,
         decision,
         observation
       ) do
    with false <- Map.has_key?(observation, "read_tool_result"),
         {:ok, ^decision} <- SalixIM.Triage.WorkerSelection.assignment(input) do
      :ok
    else
      _ -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_evaluation_binding(proof, input, _decision, observation) do
    with {:ok, payload} <- Jason.decode(proof["provider_payload_bytes"]),
         true <- payload_has_exact_message_content?(payload, input["canonical_snapshot_bytes"]),
         :ok <- validate_model_tool_binding(proof, payload, observation) do
      :ok
    else
      _ -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_model_tool_binding(
         %{"schema" => "comma.triage-model-proof.v1"},
         payload,
         observation
       ) do
    if not Map.has_key?(observation, "read_tool_result") and
         valid_read_tool_disclosure?(payload["tools"]),
       do: :ok,
       else: {:error, :identity_diagnostic_invalid_fence}
  end

  defp validate_model_tool_binding(
         %{
           "schema" => "comma.triage-model-proof.v2",
           "provider_payload_chain" => [first_payload_receipt, second_payload_receipt],
           "tool_receipts" => [receipt]
         },
         payload,
         %{
           "read_tool_result" => %{
             "tool_name" => tool_name,
             "link_ref" => link_ref,
             "receipt" => receipt
           }
         }
       )
       when tool_name in @link_read_tools do
    with {:ok, first_payload} <- Jason.decode(first_payload_receipt["payload_bytes"]),
         {:ok, second_payload} <- Jason.decode(second_payload_receipt["payload_bytes"]),
         true <- second_payload == payload,
         true <- is_list(first_payload["tools"]) and length(first_payload["tools"]) == 1,
         true <- second_payload["tools"] in [nil, []],
         {:ok, call} <- Jason.decode(receipt["canonical_call_bytes"]),
         {:ok, result} <- Jason.decode(receipt["canonical_result_bytes"]),
         true <- link_read_call_matches?(call, tool_name, link_ref),
         true <- provider_payload_has_tool_exchange?(second_payload, receipt, call, result) do
      :ok
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_model_tool_binding(
         %{
           "schema" => "comma.triage-model-proof.v2",
           "provider_payload_chain" => [first_payload_receipt, second_payload_receipt],
           "tool_receipts" => [receipt]
         },
         payload,
         %{
           "read_tool_result" => %{
             "schema" => "comma.triage-history-read-observation.v1",
             "tool_name" => "triage_run.get",
             "run_ref" => run_ref,
             "receipt" => receipt
           }
         }
       ) do
    with {:ok, first_payload} <- Jason.decode(first_payload_receipt["payload_bytes"]),
         {:ok, second_payload} <- Jason.decode(second_payload_receipt["payload_bytes"]),
         true <- second_payload == payload,
         true <- is_list(first_payload["tools"]) and length(first_payload["tools"]) == 1,
         true <- second_payload["tools"] in [nil, []],
         {:ok, call} <- Jason.decode(receipt["canonical_call_bytes"]),
         {:ok, result} <- Jason.decode(receipt["canonical_result_bytes"]),
         true <- get_in(call, ["params", "run_ref"]) == run_ref,
         true <- provider_payload_has_tool_exchange?(second_payload, receipt, call, result) do
      :ok
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_model_tool_binding(
         %{"schema" => "comma.triage-model-proof.v3", "provider_payload_chain" => chain} = proof,
         _payload,
         observation
       ) do
    # The read is complete before contribution selection. Reuse the existing
    # committed-read authority check on that prefix, then validate the render
    # request separately. No new read authority belongs to the render phase.
    prefix = Enum.drop(chain, -1)
    selection_payload = prefix |> List.last() |> Map.fetch!("payload_bytes") |> Jason.decode!()

    read_proof =
      proof
      |> Map.put(
        "schema",
        if(length(prefix) == 1,
          do: "comma.triage-model-proof.v1",
          else: "comma.triage-model-proof.v2"
        )
      )
      |> Map.put("provider_payload_chain", prefix)

    validate_model_tool_binding(read_proof, selection_payload, observation)
  end

  defp validate_model_tool_binding(_proof, _payload, _observation),
    do: {:error, :identity_diagnostic_invalid_fence}

  @doc false
  def provider_payload_has_tool_exchange?(payload, receipt, call, result) do
    provider_messages_have_tool_exchange?(payload["messages"], receipt, call, result) or
      anthropic_messages_have_tool_exchange?(payload["messages"], receipt, call, result) or
      responses_input_has_tool_exchange?(payload["input"], receipt, call, result)
  end

  defp provider_messages_have_tool_exchange?(messages, receipt, call, result) do
    is_list(messages) and
      Enum.any?(messages, fn
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => call_id,
              "name" => "call",
              "args" => %{"tool" => tool_name, "params" => params}
            }
          ]
        } ->
          call_id == receipt["call_id"] and tool_name == call["tool"] and
            tool_name in @identity_read_tools and params == call["params"]

        %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => call_id,
              "type" => "function",
              "function" => %{"name" => "call", "arguments" => arguments}
            }
          ]
        }
        when is_binary(arguments) ->
          call_id == receipt["call_id"] and call["tool"] in @identity_read_tools and
            Jason.decode(arguments) ==
              {:ok, %{"tool" => call["tool"], "params" => call["params"]}}

        _other ->
          false
      end) and
      Enum.any?(messages, fn
        %{"role" => "tool", "tool_call_id" => call_id, "content" => content} ->
          call_id == receipt["call_id"] and content == result["content"]

        _other ->
          false
      end)
  end

  defp anthropic_messages_have_tool_exchange?(messages, receipt, call, result) do
    is_list(messages) and
      Enum.any?(messages, fn
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => call_id,
              "name" => "call",
              "input" => %{"tool" => tool_name, "params" => params}
            }
          ]
        } ->
          call_id == receipt["call_id"] and tool_name == call["tool"] and
            tool_name in @identity_read_tools and params == call["params"]

        _other ->
          false
      end) and
      Enum.any?(messages, fn
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => call_id,
              "content" => content
            }
          ]
        } ->
          call_id == receipt["call_id"] and content == result["content"]

        _other ->
          false
      end)
  end

  defp responses_input_has_tool_exchange?(input, receipt, call, result) when is_list(input) do
    Enum.any?(input, fn
      %{
        "type" => "function_call",
        "call_id" => call_id,
        "name" => "call",
        "arguments" => arguments
      }
      when is_binary(arguments) ->
        call_id == receipt["call_id"] and call["tool"] in @identity_read_tools and
          Jason.decode(arguments) ==
            {:ok, %{"tool" => call["tool"], "params" => call["params"]}}

      _other ->
        false
    end) and
      Enum.any?(input, fn
        %{
          "type" => "function_call_output",
          "call_id" => call_id,
          "output" => output
        } ->
          call_id == receipt["call_id"] and output == result["content"]

        _other ->
          false
      end)
  end

  defp responses_input_has_tool_exchange?(_input, _receipt, _call, _result), do: false

  @doc false
  def valid_read_tool_disclosure?(tools) when tools in [nil, []], do: true

  def valid_read_tool_disclosure?([
        %{
          "name" => "call",
          "description" => description,
          "input_schema" => input_schema
        } = spec
      ])
      when not is_map_key(spec, "auto_wait_timeout_seconds") do
    exact_map_keys?(spec, ~w(name description input_schema)) and is_binary(description) and
      valid_call_input_schema?(input_schema)
  end

  def valid_read_tool_disclosure?([
        %{
          "name" => "call",
          "input_schema" => input_schema
        } = spec
      ]) do
    exact_map_keys?(spec, ~w(name description input_schema auto_wait_timeout_seconds)) and
      valid_call_input_schema?(input_schema)
  end

  # `provider_payload_bytes` are the protocol-native HTTP payload, not the
  # internal Salix tool spec. Keep the same closed `call` envelope while
  # recognizing each exact conversion owned by SalixLlm.
  def valid_read_tool_disclosure?([
        %{
          "type" => "function",
          "function" => %{
            "name" => "call",
            "description" => description,
            "parameters" => input_schema
          }
        } = spec
      ]) do
    exact_map_keys?(spec, ~w(type function)) and is_binary(description) and
      exact_map_keys?(spec["function"], ~w(name description parameters)) and
      valid_call_input_schema?(input_schema)
  end

  def valid_read_tool_disclosure?([
        %{
          "type" => "function",
          "name" => "call",
          "description" => description,
          "parameters" => input_schema
        } = spec
      ]) do
    exact_map_keys?(spec, ~w(type name description parameters)) and is_binary(description) and
      valid_call_input_schema?(input_schema)
  end

  def valid_read_tool_disclosure?(_tools), do: false

  defp valid_call_input_schema?(
         %{
           "type" => "object",
           "properties" => %{"tool" => tool, "params" => params},
           "required" => required
         } = input_schema
       ) do
    exact_map_keys?(input_schema, ~w(type properties required)) and
      exact_map_keys?(input_schema["properties"], ~w(tool params)) and is_map(tool) and
      is_map(params) and required == ["tool", "params"]
  end

  defp valid_call_input_schema?(_input_schema), do: false

  defp validate_review_binding(proof, model_input, decision) do
    case {Map.fetch(proof, "review_artifact"), Map.fetch(proof, "review_artifact_sha256")} do
      {:error, :error} ->
        :ok

      {{:ok, artifact}, {:ok, sha256}} ->
        with {:ok, ^artifact} <- ReviewProjection.slack(model_input, decision),
             {:ok, bytes} <- CanonicalJSON.encode(artifact),
             true <- CanonicalJSON.sha256(bytes) == sha256 do
          :ok
        else
          _invalid -> {:error, :identity_diagnostic_invalid_fence}
        end

      _partial_or_invalid ->
        {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp winning_source_anchor(input) do
    %{
      "schema" => "comma.triage-winning-source-anchor.v1",
      "generation" => input["generation"],
      "source_mode" => input["source_mode"],
      "sealed_events" => input["events"],
      "source_authority" => input["source_authority"]
    }
  end

  defp fence_base_projection(%{
         "input_snapshot" =>
           %{
             "schema" => "comma.triage-ledger-input-projection.v2"
           } = input
       }),
       do: input

  defp fence_base_projection(%{
         "input_snapshot" =>
           %{
             "schema" => "comma.triage-ledger-input-projection.v1"
           } = input
       }),
       do: input

  defp fence_base_projection(%{
         "input_snapshot" => %{
           "schema" => "comma.triage-model-input.v3",
           "snapshot" => snapshot
         }
       }) do
    %{
      "schema" => "comma.triage-ledger-input-projection.v2",
      "source_mode" => get_in(snapshot, ["identity_context", "source_mode"]),
      "event_count" => length(snapshot["events"]),
      "receipt_count" => length(snapshot["receipt_refs"]),
      "events" => snapshot["events"],
      "receipt_refs" => snapshot["receipt_refs"],
      "source_authority" => snapshot["source_authority"]
    }
  end

  defp fence_base_projection(_fence), do: nil

  @doc false
  def payload_has_exact_message_content?(value, expected) when is_map(value) do
    value["content"] == expected or exact_provider_text_block?(value, expected) or
      Enum.any?(value, fn {_key, child} -> payload_has_exact_message_content?(child, expected) end)
  end

  def payload_has_exact_message_content?(value, expected) when is_list(value),
    do: Enum.any?(value, &payload_has_exact_message_content?(&1, expected))

  def payload_has_exact_message_content?(_value, _expected), do: false

  defp exact_provider_text_block?(%{"type" => type, "text" => text}, expected)
       when type in ["text", "input_text", "output_text"],
       do: text == expected

  defp exact_provider_text_block?(_value, _expected), do: false

  defp projected_context_sha256(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.take(~w(
      slack_context
      identity_context
      team_project_memory
      answered_recheck
      decision_contract
    ))
    |> CanonicalJSON.encode()
    |> case do
      {:ok, bytes} -> CanonicalJSON.sha256(bytes)
      {:error, _reason} -> nil
    end
  end

  defp projected_context_sha256(_snapshot), do: nil

  def valid_record?(fence) do
    is_map(fence) and exact_identity_fence_outer?(fence) and
      fence["schema"] == "comma.triage-bucket-fence.v2" and
      is_binary(fence["bucket_scope"]) and String.trim(fence["bucket_scope"]) != "" and
      fence["public_bucket_ref"] == "bucket://run/scope" and
      ULID.valid?(fence["generation"]) and ULID.valid?(fence["run_id"]) and
      positive_integer?(fence["created_at"]) and positive_integer?(fence["deadline_at"]) and
      fence["deadline_at"] >= fence["created_at"] and
      valid_identity_observation?(fence["identity_observation"]) and
      valid_identity_fence_input?(fence) and valid_terminal?(fence["terminal"]) and
      valid_archived_generation?(fence)
  end

  def valid_terminal?(nil), do: true

  def valid_terminal?(
        %{
          "terminal_id" => terminal_id,
          "status" => "evaluated",
          "decision" => decision,
          "evaluator" => evaluator,
          "settled_at" => settled_at
        } = terminal
      ) do
    exact_map_keys?(terminal, ~w(terminal_id status decision evaluator settled_at)) and
      ULID.valid?(terminal_id) and positive_integer?(settled_at) and
      valid_decision?(decision) and valid_model_proof?(evaluator) and
      participation_result_matches?(evaluator, decision)
  end

  def valid_terminal?(
        %{
          "terminal_id" => terminal_id,
          "status" => "failed",
          "decision" => %{"action" => "silence", "reason" => reason} = decision,
          "evaluator" => evaluator,
          "settled_at" => settled_at
        } = terminal
      ) do
    exact_map_keys?(terminal, ~w(terminal_id status decision evaluator settled_at)) and
      exact_map_keys?(decision, ~w(action reason)) and evaluator == %{} and
      ULID.valid?(terminal_id) and positive_integer?(settled_at) and
      reason in @terminal_failed_reasons
  end

  def valid_terminal?(
        %{
          "terminal_id" => terminal_id,
          "status" => "skipped_timeout",
          "decision" => decision,
          "evaluator" => evaluator,
          "settled_at" => settled_at
        } = terminal
      ) do
    exact_map_keys?(terminal, ~w(terminal_id status decision evaluator settled_at)) and
      decision == %{"action" => "silence"} and evaluator == %{} and ULID.valid?(terminal_id) and
      positive_integer?(settled_at)
  end

  def valid_terminal?(
        %{
          "terminal_id" => terminal_id,
          "status" => "skipped_already_answered",
          "decision" => decision,
          "evaluator" => evaluator,
          "settled_at" => settled_at
        } = terminal
      ) do
    exact_map_keys?(terminal, ~w(terminal_id status decision evaluator settled_at)) and
      decision == %{"action" => "silence"} and
      evaluator == %{"schema" => "comma.triage-answered-skip.v1"} and
      ULID.valid?(terminal_id) and positive_integer?(settled_at)
  end

  def valid_terminal?(_terminal), do: false

  def valid_decision?(%{"schema" => schema} = decision)
      when schema in ["comma.triage-product-decision.v1", "comma.triage-product-decision.v2"],
      do: ProductDecision.structurally_valid?(decision)

  def valid_decision?(%{"action" => action} = decision)
      when action in ~w(silence reply react delegate remember) do
    expected_keys =
      case action do
        "silence" -> ~w(action identity_interpretation source_refs)
        "reply" -> ~w(action identity_interpretation source_refs text)
        "react" -> ~w(action identity_interpretation reaction source_refs)
        "delegate" -> ~w(action identity_interpretation source_refs task)
        "remember" -> ~w(action fact identity_interpretation source_refs)
      end

    interpretation = decision["identity_interpretation"]
    refs = decision["source_refs"]

    exact_map_keys?(decision, expected_keys) and is_list(refs) and
      Enum.all?(refs, &(is_binary(&1) and &1 != "")) and length(refs) == length(Enum.uniq(refs)) and
      valid_identity_interpretation_shape?(interpretation) and
      valid_identity_action_value?(decision)
  end

  def valid_decision?(_decision), do: false

  defp valid_identity_interpretation_shape?(
         %{
           "topic" => topic,
           "referenced_principal_refs" => refs
         } = interpretation
       ) do
    exact_map_keys?(interpretation, ~w(topic referenced_principal_refs)) and
      topic in ~w(none self_identity other_agent_identity identity_relation ambiguous) and
      is_list(refs) and Enum.all?(refs, &(is_binary(&1) and &1 != "")) and
      length(refs) == length(Enum.uniq(refs)) and
      if(topic == "none", do: refs == [], else: refs != [])
  end

  defp valid_identity_interpretation_shape?(_interpretation), do: false

  defp valid_identity_action_value?(%{"action" => "silence"}), do: true
  defp valid_identity_action_value?(%{"action" => "reply", "text" => value}), do: nonempty?(value)

  defp valid_identity_action_value?(%{"action" => "react", "reaction" => value}),
    do: nonempty?(value)

  defp valid_identity_action_value?(%{"action" => "delegate", "task" => value}),
    do: nonempty?(value)

  defp valid_identity_action_value?(%{"action" => "remember", "fact" => value}),
    do: nonempty?(value)

  defp valid_identity_action_value?(_decision), do: false

  @doc """
  Structural validity of one model proof. This is NOT provider attestation.

  Everything checked here is recomputable from the proof's own bytes: the
  provider / model / prompt / policy hashes are hashes of strings the same
  record carries, and `observer_payload_sha256` and `transport_payload_sha256`
  must both equal the hash of `provider_payload_bytes` — the bytes both were
  derived from. Agreement therefore detects a record corrupted or partially
  rewritten in place. It does not prove the record came from a real HTTP
  request, and a writer that rewrites the payload bytes together with all three
  hashes produces a proof this predicate accepts.

  `request_count` and `retry` are adapter self-declarations, not transport
  attestations: `Salix.Bindings.TriageEvaluator` counts its own `:before_send`
  observations for one `complete/3` call. This predicate pins them to the exact
  values the single-attempt policy allows; a request that never crossed that
  observation seam is invisible here.
  """
  @spec valid_model_proof?(term()) :: boolean()
  def valid_model_proof?(%{"schema" => "comma.triage-worker-assignment.v1"} = proof) do
    keys = ~w(schema canonical_snapshot_sha256 source_refs_sha256 request_count)

    (exact_map_keys?(proof, keys) or
       exact_map_keys?(proof, keys ++ ~w(review_artifact review_artifact_sha256))) and
      proof["request_count"] == 0 and valid_sha256?(proof["canonical_snapshot_sha256"]) and
      valid_sha256?(proof["source_refs_sha256"]) and valid_identity_review_proof?(proof)
  end

  def valid_model_proof?(%{"schema" => "comma.triage-model-proof.v1"} = proof) do
    payload_bytes = proof["provider_payload_bytes"]
    payload_sha256 = if(is_binary(payload_bytes), do: CanonicalJSON.sha256(payload_bytes))

    (exact_map_keys?(proof, @identity_model_proof_keys) or
       exact_map_keys?(proof, @identity_model_proof_review_keys)) and
      proof["schema"] == "comma.triage-model-proof.v1" and nonempty?(proof["provider"]) and
      nonempty?(proof["model"]) and
      proof["provider_sha256"] == CanonicalJSON.sha256(proof["provider"]) and
      proof["model_sha256"] == CanonicalJSON.sha256(proof["model"]) and
      valid_sha256?(proof["prompt_sha256"]) and valid_sha256?(proof["policy_sha256"]) and
      is_binary(payload_bytes) and proof["provider_payload_sha256"] == payload_sha256 and
      proof["observer_payload_sha256"] == payload_sha256 and
      proof["transport_payload_sha256"] == payload_sha256 and proof["request_count"] == 1 and
      proof["retry"] == false and valid_sha256?(proof["canonical_snapshot_sha256"]) and
      valid_sha256?(proof["source_refs_sha256"]) and valid_identity_review_proof?(proof)
  end

  def valid_model_proof?(%{"schema" => "comma.triage-model-proof.v2"} = proof) do
    payload_bytes = proof["provider_payload_bytes"]
    payload_sha256 = if(is_binary(payload_bytes), do: CanonicalJSON.sha256(payload_bytes))
    payload_chain = proof["provider_payload_chain"]
    tool_receipts = proof["tool_receipts"]

    (exact_map_keys?(proof, @identity_model_proof_v2_keys) or
       exact_map_keys?(proof, @identity_model_proof_v2_review_keys)) and
      nonempty?(proof["provider"]) and nonempty?(proof["model"]) and
      proof["provider_sha256"] == CanonicalJSON.sha256(proof["provider"]) and
      proof["model_sha256"] == CanonicalJSON.sha256(proof["model"]) and
      valid_sha256?(proof["prompt_sha256"]) and valid_sha256?(proof["policy_sha256"]) and
      is_binary(payload_bytes) and proof["provider_payload_sha256"] == payload_sha256 and
      proof["observer_payload_sha256"] == payload_sha256 and
      proof["transport_payload_sha256"] == payload_sha256 and proof["request_count"] == 2 and
      proof["retry"] == false and valid_sha256?(proof["canonical_snapshot_sha256"]) and
      valid_sha256?(proof["source_refs_sha256"]) and proof["tool_call_count"] == 1 and
      match?([tool_name] when tool_name in @identity_read_tools, proof["tool_names"]) and
      is_list(tool_receipts) and
      length(tool_receipts) == 1 and
      Enum.all?(tool_receipts, &valid_read_tool_receipt?/1) and
      valid_identity_provider_payload_chain?(payload_chain, payload_bytes) and
      valid_identity_review_proof?(proof)
  end

  def valid_model_proof?(%{"schema" => "comma.triage-model-proof.v3"} = proof) do
    # The final request uses the same header validation as an ordinary request.
    # The actual v3 count and complete request/read chain are checked below.
    header =
      proof
      |> Map.take(@identity_model_proof_review_keys)
      |> Map.put("schema", "comma.triage-model-proof.v1")
      |> Map.put("request_count", 1)

    (exact_map_keys?(proof, @identity_model_proof_v3_keys) or
       exact_map_keys?(proof, @identity_model_proof_v3_review_keys)) and
      valid_model_proof?(header) and valid_participation_payloads?(proof)
  end

  def valid_model_proof?(_proof), do: false

  @doc false
  def valid_participation_payloads?(proof) do
    chain = proof["provider_payload_chain"]
    count = proof["request_count"]
    read_count = proof["tool_call_count"]
    selection = proof["participation_decision"]

    with true <- read_count in [0, 1] and count == read_count + 2,
         true <- is_list(chain) and length(chain) == count,
         true <- Enum.all?(chain, &valid_identity_provider_payload_receipt?/1),
         true <- List.last(chain)["payload_bytes"] == proof["provider_payload_bytes"],
         true <- ParticipationDecision.valid?(selection),
         payloads = Enum.map(chain, &Jason.decode(&1["payload_bytes"])),
         true <- Enum.all?(payloads, &match?({:ok, payload} when is_map(payload), &1)),
         payloads = Enum.map(payloads, &elem(&1, 1)),
         [first | rest] = payloads,
         true <- valid_read_tool_disclosure?(first["tools"]),
         true <- Enum.all?(rest, &(&1["tools"] in [nil, []])),
         true <-
           payload_has_exact_message_content?(
             List.last(payloads),
             ParticipationDecision.render_instruction(selection)
           ),
         true <- participation_read_matches?(proof, payloads) do
      true
    else
      _invalid -> false
    end
  end

  defp participation_read_matches?(
         %{"tool_call_count" => 0, "tool_names" => [], "tool_receipts" => []},
         [_first, _final]
       ),
       do: true

  defp participation_read_matches?(
         %{"tool_call_count" => 1, "tool_names" => [tool_name], "tool_receipts" => [receipt]},
         [first, selection, final]
       )
       when tool_name in @identity_read_tools do
    with true <- is_list(first["tools"]) and length(first["tools"]) == 1,
         true <- valid_read_tool_receipt?(receipt) and receipt["tool_name"] == tool_name,
         {:ok, call} <- Jason.decode(receipt["canonical_call_bytes"]),
         {:ok, result} <- Jason.decode(receipt["canonical_result_bytes"]) do
      provider_payload_has_tool_exchange?(selection, receipt, call, result) and
        provider_payload_has_tool_exchange?(final, receipt, call, result)
    else
      _invalid -> false
    end
  end

  defp participation_read_matches?(_proof, _payloads), do: false

  @doc false
  def participation_result_matches?(
        %{"schema" => "comma.triage-model-proof.v3"} = proof,
        decision
      ),
      do: ParticipationDecision.validate_result(proof["participation_decision"], decision) == :ok

  def participation_result_matches?(_proof, _decision), do: true

  @doc false
  def participation_snapshot_matches?(%{"schema" => "comma.triage-model-proof.v3"} = proof, bytes) do
    Enum.all?(proof["provider_payload_chain"], fn receipt ->
      case Jason.decode(receipt["payload_bytes"]) do
        {:ok, payload} -> payload_has_exact_message_content?(payload, bytes)
        _invalid -> false
      end
    end)
  end

  def participation_snapshot_matches?(_proof, _bytes), do: true

  defp valid_identity_provider_payload_chain?(
         [first, second],
         final_payload_bytes
       ) do
    valid_identity_provider_payload_receipt?(first) and
      valid_identity_provider_payload_receipt?(second) and
      second["payload_bytes"] == final_payload_bytes and
      second["observer_payload_sha256"] == CanonicalJSON.sha256(final_payload_bytes) and
      second["transport_payload_sha256"] == CanonicalJSON.sha256(final_payload_bytes)
  end

  defp valid_identity_provider_payload_chain?(_chain, _final_payload_bytes), do: false

  def valid_provider_payload_chain?(chain, final_payload_bytes),
    do: valid_identity_provider_payload_chain?(chain, final_payload_bytes)

  defp valid_identity_provider_payload_receipt?(receipt) when is_map(receipt) do
    payload_bytes = receipt["payload_bytes"]

    exact_map_keys?(
      receipt,
      ~w(payload_bytes observer_payload_sha256 transport_payload_sha256)
    ) and is_binary(payload_bytes) and
      receipt["observer_payload_sha256"] == CanonicalJSON.sha256(payload_bytes) and
      receipt["transport_payload_sha256"] == CanonicalJSON.sha256(payload_bytes)
  end

  defp valid_identity_provider_payload_receipt?(_receipt), do: false

  defp valid_identity_review_proof?(proof) do
    case {Map.fetch(proof, "review_artifact"), Map.fetch(proof, "review_artifact_sha256")} do
      {:error, :error} ->
        true

      {{:ok, artifact}, {:ok, sha256}} when is_map(artifact) and is_binary(sha256) ->
        case CanonicalJSON.encode(artifact) do
          {:ok, bytes} -> valid_sha256?(sha256) and CanonicalJSON.sha256(bytes) == sha256
          {:error, _reason} -> false
        end

      _partial_or_invalid ->
        false
    end
  end

  defp identity_base_input_matches?(
         %{"identity_observation" => %{"state" => state}, "input_snapshot" => input},
         active
       )
       when state in ~w(unused claimed transport_maybe_started committed projection_bound),
       do: sha256(input) == active.identity_base_input_sha256

  defp identity_base_input_matches?(
         %{
           "identity_observation" => %{"state" => state}
         },
         _active
       )
       when state in ~w(snapshot_bound finalized),
       do: true

  defp identity_base_input_matches?(_fence, _active), do: false

  defp valid_identity_observation?(
         %{
           "schema" => "comma.triage-identity-observation.v1",
           "state" => "unused"
         } = observation
       ),
       do: exact_map_keys?(observation, ~w(schema state))

  defp valid_identity_observation?(
         %{
           "schema" => "comma.triage-identity-observation.v1",
           "state" => "claimed",
           "claim" => claim,
           "claimed_at_ms" => claimed_at
         } = observation
       ),
       do:
         exact_map_keys?(observation, ~w(schema state claim claimed_at_ms)) and
           validate_identity_claim(claim) == :ok and positive_integer?(claimed_at)

  defp valid_identity_observation?(
         %{
           "schema" => "comma.triage-identity-observation.v1",
           "state" => "transport_maybe_started",
           "claim" => claim,
           "claimed_at_ms" => claimed_at,
           "transport_attempt_id" => attempt_id,
           "transport_marked_at_ms" => marked_at
         } = observation
       ),
       do:
         exact_map_keys?(
           observation,
           ~w(schema state claim claimed_at_ms transport_attempt_id transport_marked_at_ms)
         ) and validate_identity_claim(claim) == :ok and positive_integer?(claimed_at) and
           ULID.valid?(attempt_id) and positive_integer?(marked_at)

  defp valid_identity_observation?(
         %{
           "schema" => "comma.triage-identity-observation.v1",
           "state" => "committed",
           "claim" => claim,
           "claimed_at_ms" => claimed_at,
           "transport_attempt_id" => attempt_id,
           "transport_marked_at_ms" => marked_at,
           "transport_result" => transport_result,
           "committed_at_ms" => committed_at
         } = observation
       ),
       do:
         exact_map_keys?(
           observation,
           ~w(schema state claim claimed_at_ms transport_attempt_id transport_marked_at_ms transport_result committed_at_ms)
         ) and validate_identity_claim(claim) == :ok and positive_integer?(claimed_at) and
           ULID.valid?(attempt_id) and positive_integer?(marked_at) and
           validate_identity_transport_result(transport_result) == :ok and
           transport_result_matches_claim?(transport_result, claim) and
           positive_integer?(committed_at)

  defp valid_identity_observation?(%{"state" => "projection_bound"} = observation) do
    committed_keys =
      ~w(schema state claim claimed_at_ms transport_attempt_id transport_marked_at_ms transport_result committed_at_ms)

    exact_map_keys?(
      observation,
      committed_keys ++
        ~w(private_projection pseudonymous_context_sha256 projection_bound_at_ms)
    ) and
      valid_identity_observation?(
        Map.put(
          observation
          |> Map.drop(~w(private_projection pseudonymous_context_sha256 projection_bound_at_ms)),
          "state",
          "committed"
        )
      ) and
      validate_identity_private_projection(observation["private_projection"]) == :ok and
      valid_sha256?(observation["pseudonymous_context_sha256"]) and
      positive_integer?(observation["projection_bound_at_ms"])
  end

  defp valid_identity_observation?(%{"state" => "snapshot_bound"} = observation) do
    {read_tool_result, base_observation} = Map.pop(observation, "read_tool_result")

    exact_map_keys?(
      base_observation,
      ~w(schema state claim claimed_at_ms transport_attempt_id transport_marked_at_ms transport_result committed_at_ms private_projection pseudonymous_context_sha256 projection_bound_at_ms canonical_snapshot_sha256 snapshot_bound_at_ms)
    ) and
      valid_identity_observation?(
        base_observation
        |> Map.drop(~w(canonical_snapshot_sha256 snapshot_bound_at_ms))
        |> Map.put("state", "projection_bound")
      ) and valid_sha256?(base_observation["canonical_snapshot_sha256"]) and
      positive_integer?(base_observation["snapshot_bound_at_ms"]) and
      (is_nil(read_tool_result) or valid_read_tool_observation?(read_tool_result))
  end

  defp valid_identity_observation?(%{"state" => "finalized"} = observation) do
    {read_tool_result, base_observation} = Map.pop(observation, "read_tool_result")

    exact_map_keys?(
      base_observation,
      ~w(schema state claim claimed_at_ms transport_attempt_id transport_marked_at_ms transport_result committed_at_ms private_projection pseudonymous_context_sha256 projection_bound_at_ms canonical_snapshot_sha256 snapshot_bound_at_ms finalized_at_ms)
    ) and
      valid_identity_observation?(
        base_observation
        |> Map.drop(~w(finalized_at_ms))
        |> Map.put("state", "snapshot_bound")
      ) and positive_integer?(base_observation["finalized_at_ms"]) and
      (is_nil(read_tool_result) or valid_read_tool_observation?(read_tool_result))
  end

  defp valid_identity_observation?(_observation), do: false

  def valid_read_tool_observation?(
        %{
          "schema" => "comma.triage-history-read-observation.v1",
          "tool_name" => "triage_run.get",
          "run_ref" => "triage-run://current/r" <> ordinal,
          "receipt" => receipt,
          "committed_at_ms" => committed_at
        } = observation
      ) do
    exact_map_keys?(observation, ~w(schema tool_name run_ref receipt committed_at_ms)) and
      ordinal != "" and valid_read_tool_receipt?(receipt) and
      receipt["tool_name"] == "triage_run.get" and positive_integer?(committed_at)
  end

  def valid_read_tool_observation?(observation) when is_map(observation) do
    receipt = observation["receipt"]

    exact_map_keys?(
      observation,
      ~w(schema tool_name link_ref source_refs receipt committed_at_ms)
    ) and observation["schema"] == "comma.triage-read-tool-observation.v1" and
      observation["tool_name"] in @link_read_tools and
      match?("link://run/l" <> _, observation["link_ref"]) and
      is_list(observation["source_refs"]) and observation["source_refs"] != [] and
      Enum.all?(observation["source_refs"], &nonempty?/1) and
      valid_read_tool_receipt?(receipt) and
      receipt["tool_name"] == observation["tool_name"] and
      positive_integer?(observation["committed_at_ms"])
  end

  def valid_read_tool_observation?(_observation), do: false

  def valid_read_tool_receipt?(receipt) when is_map(receipt) do
    call_bytes = receipt["canonical_call_bytes"]
    result_bytes = receipt["canonical_result_bytes"]

    exact_map_keys?(
      receipt,
      ~w(schema call_id tool_name canonical_call_bytes call_sha256 status error error_class canonical_result_bytes result_sha256)
    ) and receipt["schema"] == "comma.triage-read-tool-receipt.v1" and
      nonempty?(receipt["call_id"]) and receipt["tool_name"] in @identity_read_tools and
      is_binary(call_bytes) and receipt["call_sha256"] == CanonicalJSON.sha256(call_bytes) and
      valid_identity_read_tool_call_bytes?(call_bytes) and
      valid_identity_read_tool_outcome?(receipt) and is_binary(result_bytes) and
      receipt["result_sha256"] == CanonicalJSON.sha256(result_bytes) and
      valid_identity_read_tool_result_bytes?(result_bytes)
  end

  def valid_read_tool_receipt?(_receipt), do: false

  defp valid_identity_read_tool_outcome?(%{
         "status" => "completed",
         "error" => false,
         "error_class" => nil
       }),
       do: true

  defp valid_identity_read_tool_outcome?(%{
         "status" => "error",
         "error" => true,
         "error_class" => error_class
       })
       when error_class in ~w(timeout transport tool_error invalid_result),
       do: true

  defp valid_identity_read_tool_outcome?(_receipt), do: false

  defp valid_identity_read_tool_call_bytes?(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"tool" => "web.read_pages", "params" => %{"urls" => [link_ref]}} = call} ->
        exact_map_keys?(call, ~w(tool params)) and
          exact_map_keys?(call["params"], ["urls"]) and
          match?("link://run/l" <> _, link_ref)

      {:ok, %{"tool" => "triage_run.get", "params" => %{"run_ref" => run_ref}} = call} ->
        exact_map_keys?(call, ~w(tool params)) and
          exact_map_keys?(call["params"], ["run_ref"]) and
          match?("triage-run://current/r" <> _, run_ref)

      {:ok,
       %{"tool" => "triage.slack_read_permalink", "params" => %{"link_ref" => link_ref}} = call} ->
        exact_map_keys?(call, ~w(tool params)) and
          exact_map_keys?(call["params"], ["link_ref"]) and
          match?("link://run/l" <> _, link_ref)

      _invalid ->
        false
    end
  end

  defp link_read_call_matches?(call, "web.read_pages", link_ref),
    do: call == %{"tool" => "web.read_pages", "params" => %{"urls" => [link_ref]}}

  defp link_read_call_matches?(call, "triage.slack_read_permalink", link_ref),
    do: call == %{"tool" => "triage.slack_read_permalink", "params" => %{"link_ref" => link_ref}}

  defp valid_identity_read_tool_result_bytes?(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"content" => content} = result} ->
        exact_map_keys?(result, ["content"]) and is_binary(content)

      _invalid ->
        false
    end
  end

  defp valid_identity_fence_input?(%{
         "identity_observation" => %{"state" => state},
         "input_snapshot" => input
       })
       when state in ~w(unused claimed transport_maybe_started committed projection_bound),
       do: valid_identity_base_projection?(input)

  defp valid_identity_fence_input?(%{
         "identity_observation" => %{"state" => state} = observation,
         "input_snapshot" => input
       })
       when state in ~w(snapshot_bound finalized),
       do: valid_identity_model_input?(input, observation)

  defp valid_identity_fence_input?(_fence), do: false

  defp valid_identity_base_projection?(
         %{
           "schema" => "comma.triage-ledger-input-projection.v2",
           "source_mode" => source_mode,
           "event_count" => event_count,
           "receipt_count" => receipt_count,
           "events" => events,
           "receipt_refs" => receipt_refs,
           "source_authority" => source_authority
         } = input
       ) do
    expected_scope_kind =
      if source_mode in ["callback", "clickhouse_etl"] and
           source_authority["scope_kind"] == "channel",
         do: "channel",
         else: "thread"

    source_mode in [
      "callback",
      "clickhouse_etl",
      "historical_thread_reenactment",
      "periodic_patrol",
      "scheduled_recheck"
    ] and
      exact_map_keys?(
        input,
        ~w(schema source_mode event_count receipt_count events receipt_refs source_authority)
      ) and is_list(events) and is_list(receipt_refs) and event_count == length(events) and
      receipt_count == length(receipt_refs) and
      Enum.with_index(events, 1)
      |> Enum.all?(fn {event, ordinal} -> valid_projected_event?(event, ordinal) end) and
      Enum.with_index(receipt_refs, 1)
      |> Enum.all?(fn {receipt_ref, ordinal} ->
        receipt_ref == "receipt://run/r#{pad_ordinal(ordinal)}"
      end) and
      source_authority == %{
        "provider" => "slack",
        "scope_kind" => expected_scope_kind,
        "workspace_ref" => "workspace://run/self",
        "bucket_ref" => "bucket://run/scope",
        "endpoint_ref" => "endpoint://run/self"
      }
  end

  defp valid_identity_base_projection?(
         %{
           "schema" => "comma.triage-ledger-input-projection.v1",
           "source_mode" => source_mode,
           "event_count" => event_count,
           "receipt_count" => receipt_count,
           "events" => events,
           "receipt_refs" => receipt_refs,
           "source_authority" => source_authority
         } = input
       ) do
    expected_scope_kind =
      if source_mode == "callback" and source_authority["scope_kind"] == "channel",
        do: "channel",
        else: "thread"

    source_mode in [
      "callback",
      "clickhouse_etl",
      "historical_thread_reenactment",
      "periodic_patrol",
      "scheduled_recheck"
    ] and
      exact_map_keys?(
        input,
        ~w(schema source_mode event_count receipt_count events receipt_refs source_authority)
      ) and is_list(events) and is_list(receipt_refs) and event_count == length(events) and
      receipt_count == length(receipt_refs) and
      Enum.with_index(events, 1)
      |> Enum.all?(fn {event, ordinal} ->
        event == %{
          "event_ref" => "event://run/e#{pad_ordinal(ordinal)}",
          "ordinal" => ordinal,
          "fast_path" => event["fast_path"] == true
        }
      end) and
      Enum.with_index(receipt_refs, 1)
      |> Enum.all?(fn {receipt_ref, ordinal} ->
        receipt_ref == "receipt://run/r#{pad_ordinal(ordinal)}"
      end) and
      source_authority == %{
        "provider" => "slack",
        "scope_kind" => expected_scope_kind,
        "workspace_ref" => "workspace://run/self",
        "bucket_ref" => "bucket://run/scope",
        "endpoint_ref" => "endpoint://run/self"
      }
  end

  defp valid_identity_base_projection?(_input), do: false

  defp valid_projected_event?(event, ordinal) when is_map(event) do
    base_keys =
      ~w(event_ref ordinal actor_kind event_type addressing_kind trigger_kind fast_path)

    common? =
      event["event_ref"] == "event://run/e#{pad_ordinal(ordinal)}" and
        event["ordinal"] == ordinal and event["actor_kind"] in ["human", "agent"] and
        is_boolean(event["fast_path"])

    common? and
      case {event["addressing_kind"], event["event_type"], event["trigger_kind"]} do
        {"directed", event_type, "mention"} when event_type in ["message", "app_mention"] ->
          exact_map_keys?(event, ["addressed_recipient_ref" | base_keys]) and
            event["addressed_recipient_ref"] == "endpoint://run/self" and
            event["fast_path"] == true

        {"ambient", "message", "question_heuristic"} ->
          exact_map_keys?(event, base_keys) and event["actor_kind"] == "human" and
            event["fast_path"] == true

        {"ambient", "message", "none"} ->
          exact_map_keys?(event, base_keys) and event["fast_path"] == false

        _invalid ->
          false
      end
  end

  defp valid_projected_event?(_event, _ordinal), do: false

  defp valid_identity_model_input?(
         %{
           "schema" => "comma.triage-model-input.v3",
           "snapshot" => snapshot,
           "canonical_snapshot_bytes" => snapshot_bytes,
           "canonical_snapshot_sha256" => snapshot_sha256,
           "source_refs" => source_refs,
           "source_refs_canonical_bytes" => source_refs_bytes,
           "source_refs_sha256" => source_refs_sha256
         } = input,
         %{
           "private_projection" => private_projection,
           "pseudonymous_context_sha256" => projected_context_sha256,
           "canonical_snapshot_sha256" => observation_snapshot_sha256
         }
       ) do
    projected_keys =
      ~w(slack_context identity_context team_project_memory answered_recheck decision_contract)

    with true <-
           exact_map_keys?(
             input,
             ~w(schema snapshot canonical_snapshot_bytes canonical_snapshot_sha256 source_refs source_refs_canonical_bytes source_refs_sha256)
           ),
         true <- valid_sha256?(snapshot_sha256),
         true <- snapshot_sha256 == observation_snapshot_sha256,
         true <- is_binary(snapshot_bytes),
         true <- CanonicalJSON.encode(snapshot) == {:ok, snapshot_bytes},
         true <- CanonicalJSON.sha256(snapshot_bytes) == snapshot_sha256,
         {:ok,
          %{
            projected_context: projected_context,
            canonical_bytes: _projected_context_bytes,
            sha256: ^projected_context_sha256,
            bundle_schema: bundle_schema
          }} <- IdentityContract.recompute_projected_context(private_projection),
         true <- exact_identity_context_snapshot_outer?(snapshot, bundle_schema),
         true <- valid_identity_snapshot_base?(snapshot),
         true <- Map.take(snapshot, projected_keys) == projected_context,
         true <- source_refs == get_in(snapshot, ["decision_contract", "source_refs"]),
         true <- is_list(source_refs),
         true <- is_binary(source_refs_bytes),
         true <- valid_sha256?(source_refs_sha256),
         true <- CanonicalJSON.encode(source_refs) == {:ok, source_refs_bytes},
         true <- CanonicalJSON.sha256(source_refs_bytes) == source_refs_sha256 do
      true
    else
      _invalid -> false
    end
  end

  defp valid_identity_model_input?(_input, _observation), do: false

  defp exact_identity_context_snapshot_outer?(snapshot, bundle_schema) do
    expected_snapshot_schema =
      case bundle_schema do
        "comma.triage-private-source-bundle.v3" -> "comma.triage-context-snapshot.v5"
        "comma.triage-private-source-bundle.v4" -> "comma.triage-context-snapshot.v6"
        "comma.triage-private-source-bundle.v5" -> "comma.triage-context-snapshot.v7"
        "comma.triage-private-source-bundle.v6" -> "comma.triage-context-snapshot.v8"
        "comma.triage-private-source-bundle.v7" -> "comma.triage-context-snapshot.v9"
        "comma.triage-private-source-bundle.v8" -> "comma.triage-context-snapshot.v10"
        _invalid -> nil
      end

    keys =
      ~w(schema generation_ref events receipt_refs source_authority slack_context identity_context team_project_memory decision_contract)

    keys =
      if bundle_schema in [
           "comma.triage-private-source-bundle.v6",
           "comma.triage-private-source-bundle.v7",
           "comma.triage-private-source-bundle.v8"
         ],
         do: keys,
         else: keys ++ ["answered_recheck"]

    is_binary(expected_snapshot_schema) and
      exact_map_keys?(snapshot, keys) and snapshot["schema"] == expected_snapshot_schema and
      snapshot["generation_ref"] == "generation://run/current"
  end

  defp valid_identity_snapshot_base?(snapshot) do
    events = snapshot["events"]
    receipt_refs = snapshot["receipt_refs"]

    is_list(events) and is_list(receipt_refs) and
      valid_identity_base_projection?(%{
        "schema" => "comma.triage-ledger-input-projection.v2",
        "source_mode" => get_in(snapshot, ["identity_context", "source_mode"]),
        "event_count" => length(events),
        "receipt_count" => length(receipt_refs),
        "events" => events,
        "receipt_refs" => receipt_refs,
        "source_authority" => snapshot["source_authority"]
      })
  end

  defp exact_map_keys?(map, keys) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp exact_map_keys?(_map, _keys), do: false

  defp exact_identity_fence_outer?(fence) do
    exact_map_keys?(
      fence,
      ~w(
        schema
        bucket_scope
        public_bucket_ref
        generation
        run_id
        created_at
        deadline_at
        input_snapshot
        identity_observation
        terminal
      ) ++ if(Map.has_key?(fence, "sealed_generation"), do: ["sealed_generation"], else: [])
    )
  end

  # A terminal fence carries its exact sealed copy, so storage can take the
  # generation out of the active bucket. A channel commit requires the copy. A
  # thread commit that cannot build a valid copy keeps its generation in the
  # bucket, as all thread commits did before copies were written for threads.
  defp archive_sealed_generation(namespace, fence) do
    channel? =
      get_in(fence_base_projection(fence), ["source_authority", "scope_kind"]) == "channel"

    copied =
      with {:ok, sealed} <-
             Bucketing.load_sealed_generation(
               namespace,
               fence["bucket_scope"],
               fence["generation"]
             ),
           archived = Map.put(fence, "sealed_generation", sealed),
           true <- valid_record?(archived) do
        {:ok, archived}
      end

    case copied do
      {:ok, archived} -> {:ok, archived}
      _invalid when channel? -> {:error, :identity_diagnostic_invalid_fence}
      _invalid -> {:ok, fence}
    end
  end

  @doc """
  Adds the exact sealed copy to a terminal fence that was committed without
  one. The copy must reproduce the fence's own input projection, so only the
  generation this fence evaluated can be attached.
  """
  @spec attach_sealed_generation(map(), map()) :: {:ok, map()} | :error
  def attach_sealed_generation(%{"terminal" => terminal} = fence, sealed)
      when is_map(terminal) and is_map(sealed) do
    archived = Map.put(fence, "sealed_generation", sealed)

    if not Map.has_key?(fence, "sealed_generation") and valid_record?(archived),
      do: {:ok, archived},
      else: :error
  end

  def attach_sealed_generation(_fence, _sealed), do: :error

  defp valid_archived_generation?(%{"sealed_generation" => sealed} = fence) do
    is_map(fence["terminal"]) and
      exact_map_keys?(sealed, ~w(generation receipts sealed_at)) and
      sealed["generation"] == fence["generation"] and positive_integer?(sealed["sealed_at"]) and
      is_list(sealed["receipts"]) and sealed["receipts"] != [] and
      Enum.all?(sealed["receipts"], fn receipt ->
        validate_source_receipt(receipt) == :ok and
          Bucketing.scope_key(receipt) == fence["bucket_scope"]
      end) and
      base_projection(%{
        "events" => Enum.map(sealed["receipts"], & &1["triage_event"]),
        "receipt_refs" => Enum.map(sealed["receipts"], & &1["receipt_ref"]),
        "source_authority" => source_authority(sealed["receipts"]),
        "source_mode" => fence_base_projection(fence)["source_mode"]
      }) == fence_base_projection(fence)
  end

  defp valid_archived_generation?(_fence), do: true

  defp load_winning_input(namespace, fence) do
    with {:ok, sealed} <-
           Bucketing.load_sealed_generation(
             namespace,
             fence["bucket_scope"],
             fence["generation"]
           ),
         [_ | _] = receipts <- sealed["receipts"],
         true <- Enum.all?(receipts, &(validate_source_receipt(&1) == :ok)),
         true <- Enum.all?(receipts, &(Bucketing.scope_key(&1) == fence["bucket_scope"])),
         receipt_refs = Enum.map(receipts, & &1["receipt_ref"]),
         true <- receipt_refs == Enum.uniq(receipt_refs),
         events = Enum.map(receipts, & &1["triage_event"]),
         {:ok, source_mode} <- SourceMode.resolve(events),
         input = %{
           "schema" => "comma.triage-input-snapshot.v2",
           "generation" => sealed["generation"],
           "events" => events,
           "receipt_refs" => receipt_refs,
           "source_authority" => source_authority(receipts),
           "source_mode" => source_mode
         },
         :ok <- validate_source_preflight(input) do
      {:ok, input}
    else
      _invalid -> {:error, :identity_diagnostic_invalid_fence}
    end
  end

  defp validate_source_preflight(%{
         "schema" => "comma.triage-input-snapshot.v2",
         "events" => events,
         "source_mode" => input_source_mode
       }) do
    case IdentityContract.classify_event_provenance(events) do
      {:ok, :identity_enabled} ->
        case SourceMode.resolve(events) do
          {:ok, ^input_source_mode} -> :ok
          {:ok, _different} -> {:error, :identity_source_mode_drift}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      {:ok, :legacy} ->
        {:error, :identity_provenance_missing}
    end
  end

  defp validate_source_preflight(_input), do: {:error, :invalid_identity_input}

  defp validate_source_receipt(receipt), do: Bucketing.validate_receipt(receipt)

  defp source_authority([receipt | _rest]) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    %{
      "connect_id" => receipt["connect_id"],
      "connect_generation" => event["connect_generation"],
      "workspace_id" => bucket["workspace_id"],
      "channel_id" => bucket["channel_id"],
      "thread_ts" => bucket["thread_ts"]
    }
    |> maybe_put_scope_kind(bucket["scope_kind"])
  end

  defp maybe_put_scope_kind(authority, "channel"),
    do: authority |> Map.put("scope_kind", "channel") |> Map.put("thread_ts", "__channel__")

  defp maybe_put_scope_kind(authority, _scope_kind), do: authority

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp pad_ordinal(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp deadline_reached?(%{"deadline_at" => deadline_at}) when is_integer(deadline_at),
    do: now() >= deadline_at

  defp deadline_reached?(_fence), do: true

  # Record hashes must be reproducible across OTP releases. Jason follows the
  # map's own iteration order, which above the 32-key flatmap boundary is a HAMT
  # implementation detail, so an OTP upgrade would silently invalidate every
  # historical hash. CanonicalJSON sorts keys, so the bytes are the record's.
  defp sha256(value) do
    value
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp now, do: System.system_time(:millisecond)

  defp validate_identity_claim(claim) do
    valid? = valid_slack_identity_claim?(claim) or valid_source_identity_claim?(claim)

    if valid?, do: :ok, else: {:error, :identity_fence_denied}
  end

  defp valid_slack_identity_claim?(claim) when is_map(claim) do
    exact_map_keys?(claim, @identity_claim_keys) and
      claim["schema"] == "comma.triage-identity-observation-claim.v1" and
      Enum.all?(@identity_claim_keys -- ["schema"], &valid_sha256?(claim[&1]))
  end

  defp valid_slack_identity_claim?(_claim), do: false

  defp valid_source_identity_claim?(claim) when is_map(claim) do
    exact_map_keys?(claim, @identity_source_claim_keys) and
      claim["schema"] == "comma.triage-source-observation-claim.v2" and
      Enum.all?(@identity_source_claim_keys -- ["schema"], &valid_sha256?(claim[&1]))
  end

  defp valid_source_identity_claim?(_claim), do: false

  defp validate_identity_transport_result(result) do
    valid? = exact_identity_transport_result?(result)

    if valid?, do: :ok, else: {:error, :identity_fence_denied}
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v1",
           "kind" => "success",
           "receipt" => receipt,
           "canonical_page_bytes" => page_bytes,
           "canonical_page_sha256" => page_sha256,
           "classified_private_messages_sha256" => classified_sha256,
           "reason_code" => nil
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_keys) and unchained_receipt?(receipt) and
      valid_slack_read_receipt?(receipt, "success") and is_binary(page_bytes) and
      valid_sha256?(page_sha256) and CanonicalJSON.sha256(page_bytes) == page_sha256 and
      receipt["canonical_page_sha256"] == page_sha256 and valid_sha256?(classified_sha256)
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v1",
           "kind" => "attempted_error",
           "receipt" => receipt,
           "canonical_page_bytes" => nil,
           "canonical_page_sha256" => nil,
           "classified_private_messages_sha256" => nil,
           "reason_code" => reason
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_keys) and unchained_receipt?(receipt) and
      reason in @slack_error_reasons and
      valid_slack_read_receipt?(receipt, reason)
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v1",
           "kind" => "local_rejected",
           "receipt" => receipt,
           "canonical_page_bytes" => nil,
           "canonical_page_sha256" => page_sha256,
           "classified_private_messages_sha256" => nil,
           "reason_code" => reason
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_keys) and unchained_receipt?(receipt) and
      reason in ["identity_projection_invalid", "identity_projection_privacy_rejected"] and
      valid_slack_read_receipt?(receipt, "success") and valid_sha256?(page_sha256) and
      receipt["canonical_page_sha256"] == page_sha256
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v2",
           "kind" => "success",
           "receipt" => receipt,
           "canonical_page_bytes" => page_bytes,
           "canonical_page_sha256" => page_sha256,
           "canonical_page_chain_bytes" => chain_bytes,
           "canonical_page_chain_sha256" => chain_sha256,
           "classified_private_messages_sha256" => classified_sha256,
           "reason_code" => nil
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_v2_keys) and
      valid_slack_read_receipt?(receipt, "success") and is_binary(page_bytes) and
      valid_sha256?(page_sha256) and CanonicalJSON.sha256(page_bytes) == page_sha256 and
      receipt["canonical_page_sha256"] == page_sha256 and valid_sha256?(classified_sha256) and
      is_binary(chain_bytes) and valid_sha256?(chain_sha256) and
      CanonicalJSON.sha256(chain_bytes) == chain_sha256 and
      receipt["canonical_page_chain_sha256"] == chain_sha256
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v2",
           "kind" => "attempted_error",
           "receipt" => receipt,
           "canonical_page_bytes" => nil,
           "canonical_page_sha256" => nil,
           "canonical_page_chain_bytes" => nil,
           "canonical_page_chain_sha256" => nil,
           "classified_private_messages_sha256" => nil,
           "reason_code" => reason
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_v2_keys) and
      reason in @slack_read_chain_reasons and valid_slack_read_receipt?(receipt, reason)
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-identity-transport-result.v2",
           "kind" => "local_rejected",
           "receipt" => receipt,
           "canonical_page_bytes" => nil,
           "canonical_page_sha256" => page_sha256,
           "canonical_page_chain_bytes" => nil,
           "canonical_page_chain_sha256" => chain_sha256,
           "classified_private_messages_sha256" => nil,
           "reason_code" => reason
         } = result
       ) do
    exact_map_keys?(result, @identity_transport_result_v2_keys) and
      reason in ["identity_projection_invalid", "identity_projection_privacy_rejected"] and
      valid_slack_read_receipt?(receipt, "success") and valid_sha256?(page_sha256) and
      receipt["canonical_page_sha256"] == page_sha256 and valid_sha256?(chain_sha256) and
      receipt["canonical_page_chain_sha256"] == chain_sha256
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-source-read-result.v1",
           "kind" => "success",
           "receipt" => receipt,
           "canonical_snapshot_bytes" => snapshot_bytes,
           "canonical_snapshot_sha256" => snapshot_sha256,
           "classified_private_messages_sha256" => classified_sha256,
           "reason_code" => nil
         } = result
       ) do
    exact_map_keys?(result, @identity_source_result_keys) and
      valid_clickhouse_read_receipt?(receipt, "success") and is_binary(snapshot_bytes) and
      valid_sha256?(snapshot_sha256) and CanonicalJSON.sha256(snapshot_bytes) == snapshot_sha256 and
      receipt["canonical_snapshot_sha256"] == snapshot_sha256 and
      valid_sha256?(classified_sha256)
  end

  defp exact_identity_transport_result?(
         %{
           "schema" => "comma.triage-source-read-result.v1",
           "kind" => "attempted_error",
           "receipt" => receipt,
           "canonical_snapshot_bytes" => nil,
           "canonical_snapshot_sha256" => nil,
           "classified_private_messages_sha256" => nil,
           "reason_code" => reason
         } = result
       ) do
    exact_map_keys?(result, @identity_source_result_keys) and reason == "source_unavailable" and
      valid_clickhouse_read_receipt?(receipt, reason)
  end

  defp exact_identity_transport_result?(_result), do: false

  # A v1 transport result predates the chain schema and no writer here produces
  # one carrying a chain receipt. Admitting the combination let a forged v1
  # result smuggle in a chain receipt whose per-exchange page coverage is only
  # ever validated for v2 results.
  defp unchained_receipt?(receipt),
    do: is_map(receipt) and receipt["schema"] != "comma.slack-read-receipt-chain.v1"

  defp valid_slack_read_receipt?(
         %{"schema" => "comma.slack-read-receipt-chain.v1"} = receipt,
         outcome
       ),
       do: valid_slack_read_chain_receipt?(receipt, outcome)

  # A standalone receipt is a whole read on its own, so it must have exhausted
  # the cursor. Inside a chain only the tail carries that obligation.
  defp valid_slack_read_receipt?(receipt, "success"),
    do:
      valid_slack_read_exchange_receipt?(receipt, "success") and
        receipt["next_cursor_empty"] == true

  defp valid_slack_read_receipt?(receipt, outcome),
    do: valid_slack_read_exchange_receipt?(receipt, outcome)

  defp valid_slack_read_exchange_receipt?(receipt, "success") do
    # No authorized read can return more than its own logical ceiling, so a
    # receipt claiming more objects than that is a forgery, not a big thread.
    receipt["schema"] == "comma.slack-read-receipt.v1" and
      valid_slack_read_receipt_base?(receipt) and receipt["outcome"] == "success" and
      is_nil(receipt["typed_reason"]) and receipt["http_status"] in 200..299 and
      valid_sha256?(receipt["canonical_page_sha256"]) and
      is_integer(receipt["message_count"]) and receipt["message_count"] >= 0 and
      receipt["message_count"] <= API.observed_logical_limit() and
      receipt["next_cursor_empty"] in [true, false]
  end

  defp valid_slack_read_exchange_receipt?(receipt, reason) when reason in @slack_error_reasons do
    valid_slack_read_receipt_schema_for_error?(receipt, reason) and
      valid_slack_read_receipt_base?(receipt) and receipt["outcome"] == reason and
      receipt["typed_reason"] == reason and is_nil(receipt["canonical_page_sha256"]) and
      is_nil(receipt["message_count"]) and is_nil(receipt["next_cursor_empty"])
  end

  defp valid_slack_read_exchange_receipt?(_receipt, _outcome), do: false

  # One authorized logical read, one ordered chain of capped exchanges. The
  # chain is only a proof if every exchange is itself a closed single-attempt
  # receipt, the exchanges are distinct, all but the last carried the read
  # forward, and the aggregate the fence binds agrees with the tail.
  defp valid_slack_read_chain_receipt?(receipt, outcome) do
    exchanges = receipt["exchanges"]
    budget = receipt["page_budget"]

    exact_map_keys?(receipt, @slack_read_receipt_chain_keys) and
      receipt["operation"] in ["conversations.history", "conversations.replies"] and
      receipt["method"] == "GET" and valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["slack_api_origin_sha256"]) and receipt["retry"] == false and
      receipt["redirect"] == false and
      is_integer(budget) and budget in 1..API.observed_page_budget() and
      is_list(exchanges) and exchanges != [] and
      length(exchanges) == receipt["transport_invocation_count"] and
      length(exchanges) <= budget and
      (is_nil(receipt["http_status"]) or is_integer(receipt["http_status"])) and
      (is_nil(receipt["slack_request_id_sha256"]) or
         valid_sha256?(receipt["slack_request_id_sha256"])) and
      valid_slack_read_chain_exchanges?(exchanges, receipt) and
      valid_slack_read_chain_aggregate?(receipt, outcome)
  end

  defp valid_slack_read_chain_exchanges?(exchanges, receipt) do
    {leading, [last]} = Enum.split(exchanges, length(exchanges) - 1)
    selectors = Enum.map(exchanges, & &1["request_selector_sha256"])

    Enum.all?(exchanges, fn exchange ->
      # One physical exchange asks Slack for at most one capped page.
      is_map(exchange) and exchange["operation"] == receipt["operation"] and
        exchange["slack_api_origin_sha256"] == receipt["slack_api_origin_sha256"] and
        exchange["transport_invocation_count"] == 1 and
        valid_sha256?(exchange["request_selector_sha256"]) and
        (is_nil(exchange["message_count"]) or
           exchange["message_count"] <= API.observed_page_limit())
    end) and
      selectors == Enum.uniq(selectors) and
      Enum.all?(leading, &continuing_chain_exchange?/1) and
      valid_slack_read_chain_tail?(last, receipt)
  end

  defp continuing_chain_exchange?(exchange),
    do:
      valid_slack_read_exchange_receipt?(exchange, "success") and
        exchange["next_cursor_empty"] == false

  defp valid_slack_read_chain_tail?(last, %{"outcome" => "success"}),
    do: valid_slack_read_exchange_receipt?(last, "success") and last["next_cursor_empty"] == true

  defp valid_slack_read_chain_tail?(last, %{"outcome" => "decode_error", "rejection" => rejection}) do
    valid_slack_read_exchange_receipt?(last, "decode_error") or
      (valid_slack_read_rejection?(rejection) and
         valid_slack_read_exchange_receipt?(last, "success") and last["next_cursor_empty"] == true)
  end

  defp valid_slack_read_chain_tail?(last, %{"outcome" => outcome})
       when outcome in @slack_error_reasons,
       do: valid_slack_read_exchange_receipt?(last, outcome)

  defp valid_slack_read_chain_tail?(last, %{"outcome" => outcome})
       when outcome in @slack_read_chain_only_reasons,
       do:
         valid_slack_read_exchange_receipt?(last, "success") and
           last["next_cursor_empty"] == false

  defp valid_slack_read_chain_tail?(_last, _receipt), do: false

  defp valid_slack_read_chain_aggregate?(receipt, "success") do
    # The merged page cannot be wider than the logical read it merges.
    receipt["outcome"] == "success" and is_nil(receipt["typed_reason"]) and
      receipt["http_status"] in 200..299 and
      valid_sha256?(receipt["canonical_page_sha256"]) and
      is_integer(receipt["message_count"]) and receipt["message_count"] >= 0 and
      receipt["message_count"] <= API.observed_logical_limit() and
      receipt["next_cursor_empty"] == true and
      valid_sha256?(receipt["canonical_page_chain_sha256"]) and is_nil(receipt["rejection"])
  end

  defp valid_slack_read_chain_aggregate?(receipt, reason)
       when reason in @slack_read_chain_reasons do
    receipt["outcome"] == reason and receipt["typed_reason"] == reason and
      is_nil(receipt["canonical_page_sha256"]) and is_nil(receipt["message_count"]) and
      is_nil(receipt["next_cursor_empty"]) and is_nil(receipt["canonical_page_chain_sha256"]) and
      (is_nil(receipt["rejection"]) or
         (reason == "decode_error" and valid_slack_read_rejection?(receipt["rejection"])))
  end

  defp valid_slack_read_chain_aggregate?(_receipt, _outcome), do: false

  defp valid_slack_read_receipt_base?(receipt) do
    is_map(receipt) and valid_slack_read_receipt_schema?(receipt) and
      receipt["operation"] in ["conversations.history", "conversations.replies"] and
      receipt["method"] == "GET" and
      valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["slack_api_origin_sha256"]) and
      receipt["transport_invocation_count"] == 1 and receipt["retry"] == false and
      receipt["redirect"] == false and
      (is_nil(receipt["http_status"]) or is_integer(receipt["http_status"])) and
      (is_nil(receipt["slack_request_id_sha256"]) or
         valid_sha256?(receipt["slack_request_id_sha256"]))
  end

  defp valid_slack_read_receipt_schema_for_error?(
         %{"schema" => "comma.slack-read-receipt.v1"},
         _reason
       ),
       do: true

  defp valid_slack_read_receipt_schema_for_error?(
         %{"schema" => "comma.slack-read-receipt.v2"},
         "decode_error"
       ),
       do: true

  defp valid_slack_read_receipt_schema_for_error?(_receipt, _reason), do: false

  defp valid_slack_read_receipt_schema?(%{"schema" => "comma.slack-read-receipt.v1"} = receipt),
    do: exact_map_keys?(receipt, @slack_read_receipt_keys)

  defp valid_slack_read_receipt_schema?(
         %{"schema" => "comma.slack-read-receipt.v2", "rejection" => rejection} = receipt
       ),
       do:
         exact_map_keys?(receipt, @slack_read_receipt_v2_keys) and
           valid_slack_read_rejection?(rejection)

  defp valid_slack_read_receipt_schema?(_receipt), do: false

  defp valid_slack_read_rejection?(
         %{
           "schema" => "comma.slack-read-rejection.v1",
           "stage" => stage,
           "path" => path,
           "unknown_keys" => unknown_keys
         } = rejection
       ) do
    exact_map_keys?(rejection, @slack_read_rejection_keys) and
      stage in @slack_read_rejection_stages and path in @slack_read_rejection_paths and
      is_list(unknown_keys) and length(unknown_keys) <= 16 and
      unknown_keys == unknown_keys |> Enum.uniq() |> Enum.sort() and
      Enum.all?(unknown_keys, &valid_slack_read_rejection_key?/1)
  end

  defp valid_slack_read_rejection?(_rejection), do: false

  defp valid_slack_read_rejection_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    byte_size(key) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, key) and
      Enum.all?(
        @slack_read_rejection_credential_fragments,
        &(not String.contains?(normalized, &1))
      )
  end

  defp valid_slack_read_rejection_key?(_key), do: false

  defp transport_result_matches_claim?(transport_result, claim) do
    receipt = transport_result["receipt"]

    receipt["request_selector_sha256"] == claim["request_selector_sha256"] and
      case claim["schema"] do
        "comma.triage-identity-observation-claim.v1" ->
          receipt["slack_api_origin_sha256"] == claim["slack_api_origin_sha256"]

        "comma.triage-source-observation-claim.v2" ->
          receipt["source_origin_sha256"] == claim["source_origin_sha256"]

        _other ->
          false
      end
  end

  defp valid_clickhouse_read_receipt?(receipt, "success") when is_map(receipt) do
    exact_map_keys?(receipt, @clickhouse_read_receipt_keys) and
      receipt["schema"] == "comma.clickhouse-thread-read-receipt.v1" and
      receipt["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
      valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["source_origin_sha256"]) and receipt["outcome"] == "success" and
      is_nil(receipt["typed_reason"]) and valid_sha256?(receipt["canonical_snapshot_sha256"]) and
      is_integer(receipt["message_count"]) and receipt["message_count"] in 0..200 and
      is_integer(receipt["reaction_count"]) and receipt["reaction_count"] >= 0 and
      receipt["complete"] == true
  end

  defp valid_clickhouse_read_receipt?(receipt, "source_unavailable") when is_map(receipt) do
    exact_map_keys?(receipt, @clickhouse_read_receipt_keys) and
      receipt["schema"] == "comma.clickhouse-thread-read-receipt.v1" and
      receipt["operation"] in ~w(clickhouse.thread_current clickhouse.channel_current) and
      valid_sha256?(receipt["request_selector_sha256"]) and
      valid_sha256?(receipt["source_origin_sha256"]) and
      receipt["outcome"] == "source_unavailable" and
      receipt["typed_reason"] == "source_unavailable" and
      is_nil(receipt["canonical_snapshot_sha256"]) and is_nil(receipt["message_count"]) and
      is_nil(receipt["reaction_count"]) and is_nil(receipt["complete"])
  end

  defp valid_clickhouse_read_receipt?(_receipt, _outcome), do: false

  defp validate_identity_private_projection(projection) do
    valid? =
      is_map(projection) and
        Enum.sort(Map.keys(Map.delete(projection, "raw_deny_literals"))) ==
          Enum.sort(@identity_private_projection_keys) and
        projection["schema"] == "comma.triage-private-projection-control.v1" and
        Enum.all?(
          ~w(raw_source_bundle_sha256 raw_context_sha256 alias_map_sha256 projection_policy_sha256 projected_context_sha256),
          &valid_sha256?(projection[&1])
        ) and
        is_binary(projection["raw_source_bundle_bytes"]) and
        is_binary(projection["alias_map_bytes"])

    if valid?, do: :ok, else: {:error, :identity_fence_denied}
  end

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256, value)
end
