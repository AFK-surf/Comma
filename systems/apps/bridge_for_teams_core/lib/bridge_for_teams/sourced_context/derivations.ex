defmodule BridgeForTeams.SourcedContext.Derivations do
  @moduledoc """
  Durable, generation-fenced interpretation of frozen sourced-context snapshots.

  Request creation records exact model/prompt/policy/schema evidence and moves
  the import run into `deriving`. A worker then claims a short lease, invokes a
  configured `BridgeForTeams.SourcedContext.Processor` behind the bounded
  source-neutral lifecycle read barrier, validates the result, and atomically
  persists an immutable derivation plus its initial review revision.

  Neither this module nor a processor can read Slack, advance acquisition
  checkpoints, or publish the resulting context. Lifecycle request/derivation
  races are anchored by `LifecycleRequestWaitsForDerivation`,
  `StartDerivation`, and `FinishDerivation` in
  `tla/salix/ContextLifecyclePurge.tla`. Re-derivation from a frozen
  `preview_ready` snapshot and committing only its latest review are anchored
  by `BeginDerivation`, `FinishDerivation`, and `CommitTransaction` in
  `tla/salix/SlackHistoryImport.tla`.
  """

  import Ecto.Query

  alias BridgeForTeams.{Agents, Memberships, Repo, SlackHistoryImports}
  alias BridgeForTeams.ContextLifecycle.ReadBarrier
  alias BridgeForTeams.SlackHistoryImport.StateMachine

  alias BridgeForTeams.Schema.{
    Agent,
    Project,
    ContextBundle,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextArtifactSource,
    SourcedContextDerivation,
    SourcedContextDerivationAttempt,
    SourcedContextReviewItem,
    SourcedContextReviewRevision,
    SourcedContextSnapshot
  }

  alias BridgeForTeams.SourcedContext.{
    Acquisition,
    CanonicalJSON,
    Crypto,
    Instrumentation,
    Payloads,
    ProcessorOutput
  }

  defmodule Claim do
    @moduledoc false

    @enforce_keys [
      :attempt_id,
      :run_id,
      :snapshot_id,
      :lease_generation,
      :lease_owner,
      :evidence,
      :processor_config
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt_id: Ecto.UUID.t(),
            run_id: Ecto.UUID.t(),
            snapshot_id: Ecto.UUID.t(),
            lease_generation: non_neg_integer(),
            lease_owner: String.t(),
            evidence: map(),
            processor_config: map()
          }
  end

  @evidence_fields [
    :model_provider,
    :model_id,
    :model_revision,
    :prompt_template_id,
    :prompt_revision,
    :policy_revision,
    :schema_revision
  ]
  @processor_config_fields ~w(temperature_millis max_output_tokens seed)

  @type request_result :: %{
          required(:run) => SlackHistoryImportRun.t(),
          required(:attempt) => SourcedContextDerivationAttempt.t(),
          required(:replayed?) => boolean()
        }

  @type completion_result :: %{
          required(:run) => SlackHistoryImportRun.t(),
          required(:attempt) => SourcedContextDerivationAttempt.t(),
          optional(:derivation) => SourcedContextDerivation.t(),
          optional(:review_revision) => SourcedContextReviewRevision.t()
        }

  @spec request(Ecto.UUID.t(), map()) :: {:ok, request_result()} | {:error, term()}
  def request(run_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:sourced_context_derivation, fn ->
      with :ok <- feature_enabled(),
           :ok <- encryption_available(),
           {:ok, request} <- normalize_request(attrs) do
        transaction(fn -> persist_request(run_id, request) end)
      end
    end)
    |> audit_derivation_request()
  end

  def request(_run_id, _attrs), do: {:error, :invalid_derivation_request}

  @doc "Capture the configured processor's live evidence before creating a derivation request."
  def prepare_evidence(run_id, evidence, opts \\ []) do
    with {:ok, processor} <- processor(opts) do
      if function_exported?(processor, :prepare_evidence, 2),
        do: processor.prepare_evidence(run_id, evidence),
        else: {:ok, evidence}
    end
  end

  @doc false
  def current_router(run_id) do
    with %SlackHistoryImportRun{project_id: project_id} <- Repo.get(SlackHistoryImportRun, run_id),
         %Project{} = project <- Repo.get(Project, project_id),
         {:ok, %Agent{salix_agent_id: agent_id}} <- Agents.current_router(project),
         true <- is_binary(agent_id) and agent_id != "" do
      {:ok, agent_id}
    else
      _ -> {:error, :project_agent_unavailable}
    end
  end

  @spec get_attempt(Ecto.UUID.t()) ::
          {:ok, SourcedContextDerivationAttempt.t()} | {:error, :not_found}
  def get_attempt(id) do
    case Repo.get(SourcedContextDerivationAttempt, id) do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt}
    end
  end

  @doc "Claim one attempt without invoking its processor. Used by durable workers and fence tests."
  @spec claim(Ecto.UUID.t(), String.t()) :: {:ok, Claim.t()} | {:error, term()}
  def claim(attempt_id, worker_id) do
    with :ok <- feature_enabled(),
         {:ok, worker_id} <- nonempty(worker_id, 256, :invalid_worker_id) do
      transaction(fn -> persist_claim(attempt_id, worker_id) end)
    end
  end

  @doc "Claim and process one attempt using the configured or explicitly supplied processor."
  @spec process(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, completion_result()} | {:error, term()}
  def process(attempt_id, worker_id, opts \\ []) do
    with {:ok, claim} <- claim(attempt_id, worker_id) do
      run_claim(claim, opts)
    end
  end

  @doc "Process an already claimed lease; stale lease results are rejected at commit."
  @spec run_claim(Claim.t(), keyword()) :: {:ok, completion_result()} | {:error, term()}
  def run_claim(claim, opts \\ [])

  def run_claim(%Claim{} = claim, opts) do
    Instrumentation.measure(:sourced_context_derivation, fn ->
      with :ok <- feature_enabled(),
           :ok <- encryption_available(),
           {:ok, snapshot_data, raw_result} <- dispatch_claim_processing(claim, opts),
           source_ids = MapSet.new(snapshot_data.objects, & &1.id),
           {:ok, normalized} <- ProcessorOutput.normalize(raw_result, source_ids, output_bounds()) do
        persist_success(claim, normalized)
      else
        {:error, reason}
        when reason in [
               :stale_derivation_lease,
               :derivation_not_processing,
               :context_lifecycle_not_ready
             ] ->
          {:error, reason}

        {:error, reason} ->
          persist_failure(claim, classify_failure(reason))
      end
    end)
    |> audit_derivation_completion()
  end

  def run_claim(_claim, _opts), do: {:error, :invalid_derivation_claim}

  defp persist_request(run_id, request) do
    lock_request_key(run_id, request.client_request_id)

    case Repo.get_by(SourcedContextDerivationAttempt,
           run_id: run_id,
           client_request_id: request.client_request_id
         ) do
      %SourcedContextDerivationAttempt{} = attempt ->
        replay_request(attempt, request)

      nil ->
        insert_request(run_id, request)
    end
  end

  defp replay_request(attempt, request) do
    if same_request?(attempt, request) do
      run = Repo.get!(SlackHistoryImportRun, attempt.run_id)
      bundle = lock_bundle(run.context_bundle_id)
      :ok = ensure_lifecycle_ready(bundle)
      %{run: run, attempt: attempt, replayed?: true}
    else
      Repo.rollback(:derivation_idempotency_conflict)
    end
  end

  defp insert_request(run_id, request) do
    run = Repo.get(SlackHistoryImportRun, run_id) || Repo.rollback(:not_found)

    :ok = authorize_admin(request.requested_by_user_id, run.project_id)
    bundle = lock_bundle(run.context_bundle_id)
    :ok = ensure_lifecycle_ready(bundle)
    snapshot = ensure_frozen_snapshot(run)
    :ok = reject_existing_evidence(snapshot.id, request)
    :ok = ensure_derivation_bound(run.id)

    attempt_id = Ecto.UUID.generate()
    parent_derivation_id = if run.state == "preview_ready", do: run.derivation_id

    {transitioned_run, _event} =
      SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
        StateMachine.start_derivation(protocol_run, request.expected_generation, attempt_id)
      end)

    attempt =
      %SourcedContextDerivationAttempt{id: attempt_id}
      |> SourcedContextDerivationAttempt.create_changeset(%{
        id: attempt_id,
        run_id: run.id,
        snapshot_id: snapshot.id,
        parent_derivation_id: parent_derivation_id,
        requested_by_user_id: request.requested_by_user_id,
        client_request_id: request.client_request_id,
        status: "pending",
        model_provider: request.model_provider,
        model_id: request.model_id,
        model_revision: request.model_revision,
        prompt_template_id: request.prompt_template_id,
        prompt_revision: request.prompt_revision,
        policy_revision: request.policy_revision,
        schema_revision: request.schema_revision,
        processor_config: request.processor_config,
        processor_config_sha256: request.processor_config_sha256,
        retry_count: 0,
        lease_generation: 0
      })
      |> Repo.insert!()

    %{run: transitioned_run, attempt: attempt, replayed?: false}
  end

  defp persist_claim(attempt_id, worker_id) do
    now = DateTime.utc_now()
    {_bundle, attempt, run} = lock_derivation_context(attempt_id)

    :ok = ensure_claimable(attempt, now)
    run = prepare_run_for_claim(run, attempt, now)

    lease_generation = attempt.lease_generation + 1
    lease_expires_at = DateTime.add(now, bound(:derivation_lease_ms, 180_000), :millisecond)

    attempt =
      attempt
      |> SourcedContextDerivationAttempt.transition_changeset(%{
        status: "processing",
        retry_count: attempt.retry_count,
        retry_not_before: nil,
        last_error_class: attempt.last_error_class,
        lease_generation: lease_generation,
        lease_owner: worker_id,
        lease_expires_at: lease_expires_at
      })
      |> Repo.update!()

    %Claim{
      attempt_id: attempt.id,
      run_id: run.id,
      snapshot_id: attempt.snapshot_id,
      lease_generation: lease_generation,
      lease_owner: worker_id,
      evidence: evidence(attempt),
      processor_config: attempt.processor_config
    }
  end

  defp prepare_run_for_claim(run, attempt, now) do
    cond do
      run.state == "deriving" and run.derivation_id == attempt.id ->
        run

      run.state == "paused" and run.resume_phase == "deriving" and
          run.derivation_id == attempt.id ->
        :ok = retry_window_open(attempt.retry_not_before, now)
        :ok = retry_window_open(run.retry_not_before, now)

        {resumed, _event} =
          SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
            StateMachine.resume(protocol_run, protocol_run.generation)
          end)

        resumed

      true ->
        Repo.rollback(:run_not_deriving_attempt)
    end
  end

  defp persist_success(claim, normalized) do
    transaction(fn ->
      now = DateTime.utc_now()
      {_bundle, attempt, run} = lock_derivation_context(claim.attempt_id)
      :ok = verify_fence(attempt, claim, now)
      :ok = verify_run_fence(run, attempt)

      derivation = insert_derivation!(attempt, normalized, now)
      artifacts = insert_artifacts!(derivation, normalized.artifacts, now)
      review = insert_initial_review!(run, attempt, derivation, artifacts, now)

      {completed_run, _event} =
        SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
          with :ok <- verify_protocol_attempt(protocol_run, attempt.id) do
            StateMachine.complete_derivation(
              protocol_run,
              protocol_run.generation,
              review.id
            )
          end
        end)

      attempt =
        attempt
        |> SourcedContextDerivationAttempt.transition_changeset(%{
          status: "completed",
          retry_count: attempt.retry_count,
          retry_not_before: nil,
          last_error_class: nil,
          lease_generation: attempt.lease_generation,
          lease_owner: nil,
          lease_expires_at: nil
        })
        |> Repo.update!()

      %{
        run: completed_run,
        attempt: attempt,
        derivation: Repo.preload(derivation, artifacts: :sources),
        review_revision: Repo.preload(review, :items)
      }
    end)
  end

  defp persist_failure(claim, failure) do
    transaction(fn ->
      now = DateTime.utc_now()
      {_bundle, attempt, run} = lock_derivation_context(claim.attempt_id)
      :ok = verify_fence(attempt, claim, now)

      if run.state != "deriving" or run.derivation_id != attempt.id do
        Repo.rollback(:stale_derivation_lease)
      end

      next_retry_count = attempt.retry_count + 1

      if failure.retryable? and next_retry_count < bound(:derivation_retries, 4) do
        retry_not_before = retry_not_before(now, next_retry_count)

        {paused_run, _event} =
          SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
            StateMachine.pause(
              protocol_run,
              protocol_run.generation,
              :processor_unavailable,
              retry_not_before
            )
          end)

        attempt =
          attempt
          |> SourcedContextDerivationAttempt.transition_changeset(%{
            status: "paused",
            retry_count: next_retry_count,
            retry_not_before: retry_not_before,
            last_error_class: Atom.to_string(failure.class),
            lease_generation: attempt.lease_generation,
            lease_owner: nil,
            lease_expires_at: nil
          })
          |> Repo.update!()

        %{run: paused_run, attempt: attempt}
      else
        {failed_run, _event} =
          SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
            StateMachine.fail_terminal(
              protocol_run,
              protocol_run.generation,
              failure.class
            )
          end)

        attempt =
          attempt
          |> SourcedContextDerivationAttempt.transition_changeset(%{
            status: "failed_terminal",
            retry_count: next_retry_count,
            retry_not_before: nil,
            last_error_class: Atom.to_string(failure.class),
            lease_generation: attempt.lease_generation,
            lease_owner: nil,
            lease_expires_at: nil
          })
          |> Repo.update!()

        %{run: failed_run, attempt: attempt}
      end
    end)
  end

  defp insert_derivation!(attempt, normalized, now) do
    %SourcedContextDerivation{id: attempt.id}
    |> SourcedContextDerivation.changeset(%{
      run_id: attempt.run_id,
      snapshot_id: attempt.snapshot_id,
      parent_derivation_id: attempt.parent_derivation_id,
      model_provider: attempt.model_provider,
      model_id: attempt.model_id,
      model_revision: attempt.model_revision,
      prompt_template_id: attempt.prompt_template_id,
      prompt_revision: attempt.prompt_revision,
      policy_revision: attempt.policy_revision,
      schema_revision: attempt.schema_revision,
      processor_config: attempt.processor_config,
      output_sha256: normalized.output_sha256,
      artifact_count: length(normalized.artifacts),
      warnings: normalized.warnings,
      created_at: attempt.created_at,
      completed_at: now
    })
    |> Repo.insert!()
  end

  defp insert_artifacts!(derivation, artifacts, now) do
    Enum.map(artifacts, fn normalized ->
      id = Ecto.UUID.generate()
      {:ok, sealed} = Payloads.seal(:artifact, id, normalized["payload"])

      artifact =
        %SourcedContextArtifact{id: id}
        |> SourcedContextArtifact.changeset(%{
          derivation_id: derivation.id,
          kind: normalized["kind"],
          stable_key: normalized["stable_key"],
          payload_ciphertext: sealed.ciphertext,
          payload_sha256: sealed.sha256,
          confidence_millis: normalized["confidence_millis"],
          created_at: now
        })
        |> Repo.insert!()

      Enum.each(normalized["source_object_ids"], fn source_object_id ->
        %SourcedContextArtifactSource{}
        |> SourcedContextArtifactSource.changeset(%{
          artifact_id: artifact.id,
          source_object_id: source_object_id,
          created_at: now
        })
        |> Repo.insert!()
      end)

      %{record: artifact, payload: normalized["payload"]}
    end)
  end

  defp insert_initial_review!(run, attempt, derivation, artifacts, now) do
    parent_revision = latest_review(run.id)
    revision = if parent_revision, do: parent_revision.revision + 1, else: 1

    selection =
      Enum.map(artifacts, fn artifact ->
        %{
          "artifact_id" => artifact.record.id,
          "kind" => artifact.record.kind,
          "payload_sha256" => artifact.record.payload_sha256
        }
      end)

    review =
      %SourcedContextReviewRevision{}
      |> SourcedContextReviewRevision.changeset(%{
        run_id: run.id,
        snapshot_id: attempt.snapshot_id,
        derivation_id: derivation.id,
        parent_revision_id: parent_revision && parent_revision.id,
        revision: revision,
        created_by_user_id: attempt.requested_by_user_id,
        selection_sha256: CanonicalJSON.sha256(CanonicalJSON.encode!(selection)),
        selected_count: length(artifacts),
        created_at: now
      })
      |> Repo.insert!()

    Enum.each(artifacts, fn artifact ->
      id = Ecto.UUID.generate()
      {:ok, sealed} = Payloads.seal(:review_item, id, artifact.payload)

      %SourcedContextReviewItem{id: id}
      |> SourcedContextReviewItem.changeset(%{
        review_revision_id: review.id,
        artifact_id: artifact.record.id,
        kind: artifact.record.kind,
        payload_ciphertext: sealed.ciphertext,
        payload_sha256: sealed.sha256,
        created_at: now
      })
      |> Repo.insert!()
    end)

    review
  end

  defp latest_review(run_id) do
    Repo.one(
      from(review in SourcedContextReviewRevision,
        where: review.run_id == ^run_id,
        order_by: [desc: review.revision],
        limit: 1
      )
    )
  end

  defp audit_derivation_request({:ok, %{replayed?: false} = result} = response) do
    run = result.run
    attempt = result.attempt

    Instrumentation.record_audit(
      "sourced_context.derivation.requested",
      run_scope(run),
      attempt.requested_by_user_id,
      attempt.id,
      derivation_evidence(attempt)
    )

    response
  end

  defp audit_derivation_request(response), do: response

  defp audit_derivation_completion(
         {:ok, %{derivation: derivation, review_revision: review} = result} = response
       ) do
    run = result.run
    attempt = result.attempt

    Instrumentation.record_audit(
      "sourced_context.preview.generated",
      run_scope(run),
      attempt.requested_by_user_id,
      attempt.id,
      derivation_evidence(derivation)
      |> Map.merge(%{
        output_sha256: derivation.output_sha256,
        artifact_count: derivation.artifact_count,
        review_revision_id: review.id,
        review_revision: review.revision
      })
    )

    response
  end

  defp audit_derivation_completion(response), do: response

  defp run_scope(run) do
    %{
      org_id: run.org_id,
      project_id: run.project_id,
      resource_type: "slack_history_import_run",
      resource_id: run.id,
      resource_label: "Slack history onboarding"
    }
  end

  defp derivation_evidence(record) do
    %{
      snapshot_id: record.snapshot_id,
      model_provider: record.model_provider,
      model_id: record.model_id,
      model_revision: record.model_revision,
      prompt_template_id: record.prompt_template_id,
      prompt_revision: record.prompt_revision,
      policy_revision: record.policy_revision,
      schema_revision: record.schema_revision
    }
  end

  defp normalize_request(attrs) do
    with expected_generation when is_integer(expected_generation) and expected_generation >= 0 <-
           value(attrs, :expected_generation),
         {:ok, requested_by_user_id} <-
           uuid(value(attrs, :requested_by_user_id), :invalid_user_id),
         {:ok, client_request_id} <-
           nonempty(value(attrs, :client_request_id), 256, :invalid_client_request_id),
         {:ok, evidence} <- normalize_evidence(attrs),
         {:ok, processor_config} <-
           normalize_processor_config(value(attrs, :processor_config, %{})),
         {:ok, processor_config_bytes} <- CanonicalJSON.encode(processor_config),
         true <- byte_size(processor_config_bytes) <= bound(:processor_config_bytes, 1_024) do
      {:ok,
       evidence
       |> Map.merge(%{
         expected_generation: expected_generation,
         requested_by_user_id: requested_by_user_id,
         client_request_id: client_request_id,
         processor_config: processor_config,
         processor_config_sha256: CanonicalJSON.sha256(processor_config_bytes)
       })}
    else
      false -> {:error, :processor_config_bound_exceeded}
      nil -> {:error, :invalid_expected_generation}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_derivation_request}
    end
  end

  defp normalize_processor_config(config) when is_map(config) do
    Enum.reduce_while(config, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      normalized =
        case {key, value} do
          {"temperature_millis", value} when is_integer(value) and value in 0..2_000 ->
            {:ok, value}

          {"max_output_tokens", value} when is_integer(value) and value in 1..100_000 ->
            {:ok, value}

          {"seed", value} when is_integer(value) and value in 0..2_147_483_647 ->
            {:ok, value}

          _ ->
            {:error, :invalid_processor_config}
        end

      case normalized do
        {:ok, value} when key in @processor_config_fields ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_processor_config(_config), do: {:error, :invalid_processor_config}

  defp normalize_evidence(attrs) do
    Enum.reduce_while(@evidence_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case nonempty(value(attrs, field), 256, {:invalid_evidence, field}) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp same_request?(attempt, request) do
    attempt.requested_by_user_id == request.requested_by_user_id and
      attempt.processor_config_sha256 == request.processor_config_sha256 and
      attempt.processor_config == request.processor_config and
      Enum.all?(@evidence_fields, &(Map.fetch!(request, &1) == Map.get(attempt, &1)))
  end

  defp reject_existing_evidence(snapshot_id, request) do
    query =
      Enum.reduce(@evidence_fields, from(d in SourcedContextDerivation), fn field, query ->
        value = Map.fetch!(request, field)
        where(query, [d], field(d, ^field) == ^value)
      end)

    case Repo.one(from(d in query, where: d.snapshot_id == ^snapshot_id, limit: 1)) do
      nil -> :ok
      _existing -> Repo.rollback(:derivation_evidence_already_exists)
    end
  end

  defp ensure_derivation_bound(run_id) do
    count =
      Repo.aggregate(
        from(attempt in SourcedContextDerivationAttempt, where: attempt.run_id == ^run_id),
        :count
      )

    if count < bound(:run_derivations, 20),
      do: :ok,
      else: Repo.rollback(:run_derivation_bound_exceeded)
  end

  defp ensure_frozen_snapshot(%SlackHistoryImportRun{state: state} = run)
       when state in ["acquired", "preview_ready"] do
    case Repo.get(SourcedContextSnapshot, run.snapshot_id) do
      %SourcedContextSnapshot{run_id: run_id, coverage: %{"complete" => true}} = snapshot
      when run_id == run.id ->
        snapshot

      _ ->
        Repo.rollback(:complete_snapshot_required)
    end
  end

  defp ensure_frozen_snapshot(_run), do: Repo.rollback(:run_not_ready_for_derivation)

  defp ensure_lifecycle_ready(%ContextBundle{
         lifecycle_state: "registered",
         subject_index_state: "complete"
       }),
       do: :ok

  defp ensure_lifecycle_ready(_bundle), do: Repo.rollback(:context_lifecycle_not_ready)

  # Lock order is lifecycle bundle -> derivation attempt -> import run. The
  # lifecycle purger owns the same bundle row before it removes source-layout
  # rows, so a deletion/erasure request either precedes this use and rejects it
  # or waits for this short database transaction. The external processor does
  # not hold these exclusive attempt/run locks; it runs under ReadBarrier's
  # shared bundle lock instead. Success is fenced again before any derived row
  # is persisted.
  defp lock_derivation_context(attempt_id) do
    bundle_id = bundle_id_for_attempt(attempt_id)
    bundle = lock_bundle(bundle_id)
    :ok = ensure_lifecycle_ready(bundle)
    attempt = lock_attempt(attempt_id)
    run = lock_run(attempt.run_id)

    if run.context_bundle_id == bundle.id do
      {bundle, attempt, run}
    else
      Repo.rollback(:context_lifecycle_not_ready)
    end
  end

  # Reading the frozen snapshot and invoking the processor are one
  # lifecycle-linearized read. A deletion/erasure request therefore either
  # wins before this callback (and the callback never runs) or waits until the
  # bounded processor invocation has returned. This closes the preflight ->
  # snapshot read/dispatch gap without extending the derivation lease into a
  # source-authority decision.
  defp dispatch_claim_processing(claim, opts) do
    with {:ok, bundle_id} <- claim_bundle_id(claim) do
      ReadBarrier.run([bundle_id], fn ->
        with :ok <- authorize_claim_processing(claim, bundle_id),
             {:ok, snapshot_data} <- Acquisition.read_snapshot(claim.snapshot_id),
             :ok <- verify_claim_snapshot(claim, snapshot_data),
             {:ok, processor} <- processor(opts),
             {:ok, request} <- processor_request(claim, snapshot_data),
             {:ok, raw_result} <-
               invoke_processor(processor, request) do
          {:ok, snapshot_data, raw_result}
        end
      end)
    end
  end

  defp authorize_claim_processing(claim, bundle_id) do
    attempt =
      Repo.get(SourcedContextDerivationAttempt, claim.attempt_id) ||
        Repo.rollback(:stale_derivation_lease)

    run =
      Repo.get(SlackHistoryImportRun, claim.run_id) ||
        Repo.rollback(:context_lifecycle_not_ready)

    if attempt.run_id != run.id or run.context_bundle_id != bundle_id,
      do: Repo.rollback(:context_lifecycle_not_ready)

    now = DateTime.utc_now()
    :ok = verify_fence(attempt, claim, now)
    verify_run_fence(run, attempt)
  end

  defp claim_bundle_id(claim) do
    bundle_id =
      Repo.one(
        from(attempt in SourcedContextDerivationAttempt,
          join: run in SlackHistoryImportRun,
          on: run.id == attempt.run_id,
          where:
            attempt.id == ^claim.attempt_id and attempt.run_id == ^claim.run_id and
              attempt.snapshot_id == ^claim.snapshot_id,
          select: run.context_bundle_id
        )
      )

    if is_binary(bundle_id),
      do: {:ok, bundle_id},
      else: {:error, :context_lifecycle_not_ready}
  end

  defp authorize_admin(user_id, project_id) do
    case Memberships.authorize(user_id, :write, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:forbidden)
    end
  end

  defp ensure_claimable(%{status: "pending"}, _now), do: :ok

  defp ensure_claimable(%{status: "paused", retry_not_before: retry_not_before}, now),
    do: retry_window_open(retry_not_before, now)

  defp ensure_claimable(%{status: "processing", lease_expires_at: expires_at}, now) do
    if is_struct(expires_at, DateTime) and DateTime.compare(expires_at, now) in [:lt, :eq],
      do: :ok,
      else: Repo.rollback({:derivation_lease_held, expires_at})
  end

  defp ensure_claimable(%{status: "completed"}, _now),
    do: Repo.rollback(:derivation_already_completed)

  defp ensure_claimable(%{status: "failed_terminal"}, _now),
    do: Repo.rollback(:derivation_failed_terminal)

  defp ensure_claimable(_attempt, _now), do: Repo.rollback(:invalid_derivation_attempt_state)

  defp retry_window_open(nil, _now), do: :ok

  defp retry_window_open(retry_not_before, now) do
    if DateTime.compare(now, retry_not_before) in [:eq, :gt],
      do: :ok,
      else: Repo.rollback({:retry_not_before, retry_not_before})
  end

  defp verify_fence(attempt, claim, now) do
    if attempt.status == "processing" and
         attempt.lease_generation == claim.lease_generation and
         attempt.lease_owner == claim.lease_owner and
         is_struct(attempt.lease_expires_at, DateTime) and
         DateTime.compare(attempt.lease_expires_at, now) == :gt do
      :ok
    else
      Repo.rollback(:stale_derivation_lease)
    end
  end

  defp verify_run_fence(run, attempt) do
    if run.state == "deriving" and run.derivation_id == attempt.id and
         run.snapshot_id == attempt.snapshot_id,
       do: :ok,
       else: Repo.rollback(:stale_derivation_lease)
  end

  defp verify_protocol_attempt(%{state: :deriving, derivation_id: id}, id), do: :ok
  defp verify_protocol_attempt(_run, _attempt_id), do: {:error, :stale_derivation_lease}

  defp verify_claim_snapshot(claim, %{snapshot: snapshot}) do
    if snapshot.id == claim.snapshot_id and snapshot.run_id == claim.run_id and
         snapshot.coverage["complete"] == true,
       do: :ok,
       else: {:error, :snapshot_integrity_failed}
  end

  defp processor_request(claim, snapshot_data) do
    with {:ok, agent_id} <- current_router(claim.run_id) do
      {:ok,
       %{
         run_id: claim.run_id,
         agent_id: agent_id,
         snapshot: snapshot_view(snapshot_data.snapshot),
         objects: snapshot_data.objects,
         evidence: claim.evidence,
         processor_config: claim.processor_config
       }}
    else
      _missing -> {:error, :project_agent_unavailable}
    end
  end

  defp snapshot_view(snapshot) do
    %{
      id: snapshot.id,
      run_id: snapshot.run_id,
      normalization_revision: snapshot.normalization_revision,
      coverage_profile: snapshot.coverage_profile,
      manifest_sha256: snapshot.manifest_sha256,
      object_count: snapshot.object_count,
      byte_count: snapshot.byte_count,
      coverage: snapshot.coverage,
      finalized_at: snapshot.finalized_at
    }
  end

  defp processor(opts) do
    processor =
      Keyword.get(opts, :processor) ||
        Application.get_env(:bridge_for_teams_core, :sourced_context_processor)

    if is_atom(processor) and not is_nil(processor) and Code.ensure_loaded?(processor) and
         function_exported?(processor, :derive, 1) do
      {:ok, processor}
    else
      {:error, :processor_unavailable}
    end
  end

  defp invoke_processor(processor, request) do
    task =
      Task.async(fn ->
        try do
          processor.derive(request)
        rescue
          _error -> {:error, :processor_crashed}
        catch
          _kind, _reason -> {:error, :processor_crashed}
        end
      end)

    case Task.yield(task, bound(:processor_timeout_ms, 120_000)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} when is_map(result) -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, normalize_processor_error(reason)}
      {:ok, _invalid} -> {:error, :invalid_processor_output}
      {:exit, _reason} -> {:error, :processor_crashed}
      nil -> {:error, :processor_timeout}
    end
  end

  defp normalize_processor_error(reason)
       when reason in [:processor_timeout, :processor_unavailable, :processor_crashed],
       do: reason

  defp normalize_processor_error(_reason), do: :processor_unavailable

  defp classify_failure(reason)
       when reason in [:processor_timeout, :processor_unavailable, :processor_crashed] do
    %{class: reason, retryable?: true}
  end

  defp classify_failure(_reason), do: %{class: :invalid_processor_output, retryable?: false}

  defp evidence(attempt) do
    Map.new(@evidence_fields, &{&1, Map.fetch!(attempt, &1)})
  end

  defp lock_attempt(id) do
    Repo.one(
      from(attempt in SourcedContextDerivationAttempt,
        where: attempt.id == ^id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_run(id) do
    Repo.one(
      from(run in SlackHistoryImportRun,
        where: run.id == ^id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp bundle_id_for_attempt(attempt_id) do
    Repo.one(
      from(attempt in SourcedContextDerivationAttempt,
        join: run in SlackHistoryImportRun,
        on: run.id == attempt.run_id,
        where: attempt.id == ^attempt_id,
        select: run.context_bundle_id
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_bundle(id) do
    Repo.one(
      from(bundle in ContextBundle,
        where: bundle.id == ^id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:context_lifecycle_not_ready)
  end

  defp lock_request_key(run_id, client_request_id) do
    key = Enum.join(["sourced_context_derivation", run_id, client_request_id], ":")
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end

  defp retry_not_before(now, retry_count) do
    seconds = min(5 * Integer.pow(2, max(retry_count - 1, 0)), 300)
    DateTime.add(now, seconds, :second)
  end

  defp output_bounds do
    [
      max_artifacts: bound(:derivation_artifacts, 100),
      max_sources_per_artifact: bound(:artifact_sources, 20),
      max_payload_bytes: bound(:artifact_payload_bytes, 8_000),
      max_warnings_bytes: bound(:derivation_warnings_bytes, 16_384)
    ]
  end

  defp bound(key, default) do
    Application.get_env(:bridge_for_teams_core, :sourced_context_bounds, [])
    |> Keyword.get(key, default)
  end

  defp feature_enabled do
    if Keyword.get(
         Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
         :derivation,
         false
       ),
       do: :ok,
       else: {:error, {:feature_disabled, :derivation}}
  end

  defp encryption_available do
    if Crypto.available?(),
      do: :ok,
      else: {:error, :sourced_context_encryption_unavailable}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp nonempty(value, max_bytes, error) when is_binary(value) do
    normalized = String.trim(value)

    if normalized != "" and byte_size(normalized) <= max_bytes,
      do: {:ok, normalized},
      else: {:error, error}
  end

  defp nonempty(_value, _max_bytes, error), do: {:error, error}

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp value(_map, _key, default), do: default
end
