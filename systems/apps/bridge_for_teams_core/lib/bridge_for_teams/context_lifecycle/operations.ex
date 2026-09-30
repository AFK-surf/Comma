defmodule BridgeForTeams.ContextLifecycle.Operations do
  @moduledoc """
  Source-neutral lifecycle commands and leased purge execution.

  The retry, restore, lease-fencing, and atomic-purge protocol is modeled in
  `tla/salix/ContextLifecyclePurge.tla`.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo}
  alias BridgeForTeams.ContextLifecycle.Deadlines
  alias BridgeForTeams.Schema.{ContextBundle, ContextBundleSubject}

  alias BridgeForTeams.Schema.{
    ContextLifecycleEvidence,
    ContextLifecycleRequest
  }

  alias BridgeForTeams.SourcedContext.CanonicalJSON
  alias BridgeForTeams.SourcedContext.Instrumentation

  @request_states ~w(pending processing retry_wait)
  @restorable_states ~w(pending retry_wait failed_terminal)
  @request_reason_codes ~w(user_request retention_expired organization_request legal_requirement administrative_cleanup)
  @restore_reason_codes ~w(request_submitted_in_error legal_hold administrative_override)
  @count_keys ~w(
    rows_deleted
    payloads_deleted
    subject_index_rows_deleted
    publications_deleted
    command_receipts_deleted
    review_items_deleted
    artifact_sources_deleted
    derivation_attempts_deleted
    review_revisions_deleted
    artifacts_deleted
    derivations_deleted
    snapshots_deleted
    source_objects_deleted
    page_receipts_deleted
    stream_checkpoints_deleted
    channels_deleted
  )
  @error_classes ~w(
    unknown
    storage_temporarily_unavailable
    invalid_purge_counts
    unsupported_context_source_type
    invalid_slack_history_bundle_identity
    slack_history_run_not_found
    slack_history_bundle_mismatch
    purger_crash
    purger_exit
    purger_throw
  )

  @spec request_deletion(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def request_deletion(bundle_id, attrs), do: request(bundle_id, attrs, "deletion")

  @spec request_erasure(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def request_erasure(bundle_id, attrs), do: request(bundle_id, attrs, "erasure")

  @spec restore(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def restore(bundle_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:context_lifecycle, fn ->
      with {:ok, command} <- normalize_restore(attrs) do
        transaction(fn -> persist_restore(bundle_id, command) end)
      end
    end)
    |> audit_lifecycle("context.lifecycle.restored")
  end

  def restore(_bundle_id, _attrs), do: {:error, :invalid_lifecycle_restore}

  @spec claim(Ecto.UUID.t(), String.t()) ::
          {:ok, ContextLifecycleRequest.t()} | {:error, term()}
  def claim(request_id, worker_id) do
    with {:ok, request_id} <- uuid(request_id, :invalid_lifecycle_request_id),
         {:ok, worker_id} <- bounded_string(worker_id, :invalid_lifecycle_worker) do
      transaction(fn -> persist_claim(request_id, worker_id) end)
    end
  end

  @spec run_claim(ContextLifecycleRequest.t() | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_claim(claim, opts \\ [])

  def run_claim(claim, opts) when is_map(claim) and is_list(opts) do
    Instrumentation.measure(:context_lifecycle, fn ->
      with {:ok, fence} <- normalize_claim(claim) do
        case Repo.transaction(fn -> execute_claim(fence, opts) end) do
          {:ok, result} ->
            {:ok, result}

          {:error, {:lifecycle_purge_failed, failure}} ->
            persist_failure(fence, failure)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
    |> audit_lifecycle_execution()
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  def run_claim(_claim, _opts), do: {:error, :invalid_lifecycle_claim}

  @spec get_request(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get_request(request_id, user_id) do
    with {:ok, request_id} <- uuid(request_id, :invalid_lifecycle_request_id),
         {:ok, user_id} <- uuid(user_id, :invalid_user_id),
         %ContextLifecycleRequest{} = request <- Repo.get(ContextLifecycleRequest, request_id),
         %ContextBundle{} = bundle <- Repo.get(ContextBundle, request.bundle_id),
         :ok <- authorize_read(user_id, bundle) do
      {:ok,
       %{
         request: request,
         bundle: bundle,
         evidence: Repo.get_by(ContextLifecycleEvidence, request_id: request.id)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_bundles_for_subject(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def list_bundles_for_subject(org_id, kind, ref, user_id, opts \\ []) do
    with {:ok, org_id} <- uuid(org_id, :invalid_org_id),
         {:ok, user_id} <- uuid(user_id, :invalid_user_id),
         {:ok, kind} <- bounded_string(kind, :invalid_subject_kind),
         {:ok, ref} <- bounded_subject_ref(ref),
         :ok <- authorize_org_admin(user_id, org_id) do
      limit = bounded_limit(opts, :limit, 100)

      bundles =
        Repo.all(
          from(bundle in ContextBundle,
            join: subject in ContextBundleSubject,
            on: subject.bundle_id == bundle.id,
            where: bundle.org_id == ^org_id and subject.kind == ^kind and subject.ref == ^ref,
            order_by: [asc: bundle.created_at, asc: bundle.id],
            limit: ^(limit + 1)
          )
        )

      truncated? = length(bundles) > limit

      {:ok,
       %{
         bundles: Enum.take(bundles, limit),
         completeness: if(truncated?, do: :truncated, else: :complete),
         truncated?: truncated?
       }}
    end
  end

  defp request(bundle_id, attrs, kind) when is_map(attrs) do
    Instrumentation.measure(:context_lifecycle, fn ->
      with {:ok, command} <- normalize_request(attrs, kind) do
        transaction(fn -> persist_request(bundle_id, command) end)
      end
    end)
    |> audit_lifecycle("context.lifecycle.#{kind}_requested")
  end

  defp request(_bundle_id, _attrs, _kind), do: {:error, :invalid_lifecycle_request}

  defp persist_request(bundle_id, command) do
    bundle = lock_bundle(bundle_id)
    :ok = authorize_admin(command.requested_by_user_id, bundle)

    case lock_request_by_command(bundle.id, command.command_id) do
      %ContextLifecycleRequest{} = request ->
        replay_request(bundle, request, command)

      nil ->
        ensure_requestable(bundle, command.expected_revision)
        ensure_no_active_request(bundle.id)

        request =
          %ContextLifecycleRequest{}
          |> ContextLifecycleRequest.create_changeset(%{
            bundle_id: bundle.id,
            requested_by_user_id: command.requested_by_user_id,
            command_id: command.command_id,
            kind: command.kind,
            reason: command.reason,
            state: "pending",
            base_revision: command.expected_revision,
            retry_count: 0,
            lease_generation: 0
          })
          |> Repo.insert!()

        pending_state = pending_state(command.kind)

        bundle =
          update_bundle!(bundle, %{
            lifecycle_state: pending_state,
            lifecycle_revision: bundle.lifecycle_revision + 1,
            last_error: nil
          })

        %{bundle: bundle, request: request, replayed?: false}
    end
  end

  defp replay_request(bundle, request, command) do
    expected =
      request.kind == command.kind and
        request.reason == command.reason and
        request.requested_by_user_id == command.requested_by_user_id and
        request.base_revision == command.expected_revision

    if expected do
      %{bundle: bundle, request: request, replayed?: true}
    else
      Repo.rollback(:command_id_conflict)
    end
  end

  defp persist_restore(bundle_id, command) do
    bundle = lock_bundle(bundle_id)
    :ok = authorize_admin(command.requested_by_user_id, bundle)

    case lock_request_by_cancel_command(bundle.id, command.command_id) do
      %ContextLifecycleRequest{} = request ->
        replay_restore(bundle, request, command)

      nil ->
        restore_active_request(bundle, command)
    end
  end

  defp restore_active_request(bundle, command) do
    request = lock_latest_request(bundle.id)

    cond do
      is_nil(request) ->
        Repo.rollback(:no_lifecycle_request)

      request.state == "processing" ->
        Repo.rollback(:lifecycle_purge_in_progress)

      request.state == "completed" ->
        Repo.rollback(:lifecycle_purge_already_completed)

      request.state == "canceled" ->
        Repo.rollback(:no_active_lifecycle_request)

      request.state not in @restorable_states ->
        Repo.rollback(:lifecycle_request_not_restorable)

      bundle.lifecycle_revision != command.expected_revision ->
        Repo.rollback(:stale_lifecycle_revision)

      true ->
        now = DateTime.utc_now()

        request =
          request
          |> ContextLifecycleRequest.transition_changeset(%{
            state: "canceled",
            retry_count: request.retry_count,
            retry_not_before: nil,
            last_error_class: request.last_error_class,
            lease_generation: request.lease_generation,
            lease_owner: nil,
            lease_expires_at: nil,
            cancel_command_id: command.command_id,
            canceled_by_user_id: command.requested_by_user_id,
            cancel_reason: command.reason,
            canceled_at: now,
            completed_at: nil
          })
          |> Repo.update!()

        bundle =
          update_bundle!(bundle, %{
            lifecycle_state: "registered",
            lifecycle_revision: bundle.lifecycle_revision + 1,
            last_error: nil
          })

        %{bundle: bundle, request: request, replayed?: false}
    end
  end

  defp replay_restore(bundle, request, command) do
    if request.state == "canceled" and
         request.cancel_reason == command.reason and
         request.canceled_by_user_id == command.requested_by_user_id do
      %{bundle: bundle, request: request, replayed?: true}
    else
      Repo.rollback(:command_id_conflict)
    end
  end

  defp persist_claim(request_id, worker_id) do
    request = lock_request(request_id)
    bundle = lock_bundle(request.bundle_id)
    now = DateTime.utc_now()

    :ok = ensure_bundle_pending(bundle, request)
    :ok = ensure_claimable(request, now)

    request
    |> ContextLifecycleRequest.transition_changeset(%{
      state: "processing",
      retry_count: request.retry_count,
      retry_not_before: nil,
      last_error_class: request.last_error_class,
      lease_generation: request.lease_generation + 1,
      lease_owner: worker_id,
      lease_expires_at:
        DateTime.add(now, bound(:context_lifecycle_lease_ms, 180_000), :millisecond),
      completed_at: nil
    })
    |> Repo.update!()
  end

  defp execute_claim(fence, opts) do
    request = lock_request(fence.id)
    :ok = ensure_current_claim(request, fence)
    bundle = lock_bundle(request.bundle_id)
    :ok = ensure_bundle_pending(bundle, request)

    purger = resolve_purger(bundle.source_type, opts)

    counts =
      case invoke_purger(purger, bundle) do
        {:ok, counts} ->
          case normalize_counts(counts) do
            {:ok, counts} -> counts
            {:error, class} -> purge_failed(:terminal, class)
          end

        {:error, {:terminal, class}} ->
          purge_failed(:terminal, class)

        {:error, {:retryable, class}} ->
          purge_failed(:retryable, class)

        {:error, class} ->
          purge_failed(:retryable, class)
      end

    # The adapter runs inside this transaction, but it may outlive its lease.
    # Recheck time after it returns so an expired worker rolls the adapter's
    # deletes back instead of publishing stale completion evidence.
    :ok = ensure_current_claim(request, fence)
    now = DateTime.utc_now()

    {subject_count, _subjects} =
      Repo.delete_all(
        from(subject in ContextBundleSubject, where: subject.bundle_id == ^bundle.id)
      )

    counts = Map.put(counts, "subject_index_rows_deleted", subject_count)

    request =
      request
      |> ContextLifecycleRequest.transition_changeset(%{
        state: "completed",
        retry_count: request.retry_count,
        retry_not_before: nil,
        last_error_class: nil,
        lease_generation: request.lease_generation,
        lease_owner: nil,
        lease_expires_at: nil,
        completed_at: now
      })
      |> Repo.update!()

    counts_sha256 = CanonicalJSON.sha256(CanonicalJSON.encode!(counts))

    evidence =
      %ContextLifecycleEvidence{}
      |> ContextLifecycleEvidence.changeset(%{
        request_id: request.id,
        bundle_id: bundle.id,
        source_type: bundle.source_type,
        purger: inspect(purger),
        counts: counts,
        counts_sha256: counts_sha256,
        completed_at: now,
        created_at: now
      })
      |> Repo.insert!()

    bundle =
      update_bundle!(bundle, %{
        lifecycle_state: "deleted",
        subject_index_state: "complete",
        lifecycle_revision: bundle.lifecycle_revision + 1,
        last_error: nil
      })

    %{bundle: bundle, request: request, evidence: evidence}
  end

  defp persist_failure(fence, failure) do
    case Repo.transaction(fn -> persist_failure_transaction(fence, failure) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp persist_failure_transaction(fence, failure) do
    request = lock_request(fence.id)
    :ok = ensure_current_claim(request, fence)
    bundle = lock_bundle(request.bundle_id)
    :ok = ensure_bundle_pending(bundle, request)

    retry_count = request.retry_count + 1
    error_class = normalize_error_class(failure.class)
    retryable? = failure.retryable? and retry_count < bound(:context_lifecycle_retries, 4)

    if retryable? do
      now = DateTime.utc_now()

      request =
        request
        |> ContextLifecycleRequest.transition_changeset(%{
          state: "retry_wait",
          retry_count: retry_count,
          retry_not_before: DateTime.add(now, retry_backoff_ms(retry_count), :millisecond),
          last_error_class: error_class,
          lease_generation: request.lease_generation,
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: nil
        })
        |> Repo.update!()

      bundle = update_bundle!(bundle, %{last_error: error_class})
      %{bundle: bundle, request: request, outcome: :retry_scheduled}
    else
      request =
        request
        |> ContextLifecycleRequest.transition_changeset(%{
          state: "failed_terminal",
          retry_count: retry_count,
          retry_not_before: nil,
          last_error_class: error_class,
          lease_generation: request.lease_generation,
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: nil
        })
        |> Repo.update!()

      bundle =
        update_bundle!(bundle, %{
          lifecycle_state: "failed",
          lifecycle_revision: bundle.lifecycle_revision + 1,
          last_error: error_class
        })

      %{bundle: bundle, request: request, outcome: :failed_terminal}
    end
  end

  defp audit_lifecycle({:ok, %{replayed?: false} = result} = response, action) do
    request = result.request
    bundle = result.bundle

    actor_user_id = request.canceled_by_user_id || request.requested_by_user_id

    Instrumentation.record_audit(
      action,
      bundle_scope(bundle),
      actor_user_id,
      request.id,
      lifecycle_metadata(bundle, request)
    )

    response
  end

  defp audit_lifecycle(response, _action), do: response

  defp audit_lifecycle_execution(
         {:ok, %{evidence: evidence, request: request, bundle: bundle}} = response
       ) do
    Instrumentation.record_audit(
      "context.lifecycle.purge_completed",
      bundle_scope(bundle),
      request.requested_by_user_id,
      evidence.id,
      lifecycle_metadata(bundle, request)
      |> Map.merge(%{
        purger: evidence.purger,
        rows_deleted: evidence.counts["rows_deleted"],
        payloads_deleted: evidence.counts["payloads_deleted"],
        subject_index_rows_deleted: evidence.counts["subject_index_rows_deleted"],
        counts_sha256: evidence.counts_sha256
      })
    )

    response
  end

  defp audit_lifecycle_execution(
         {:ok, %{outcome: outcome, request: request, bundle: bundle}} = response
       ) do
    action =
      if outcome == :retry_scheduled,
        do: "context.lifecycle.purge_retry_scheduled",
        else: "context.lifecycle.purge_failed_terminal"

    Instrumentation.record_audit(
      action,
      bundle_scope(bundle),
      request.requested_by_user_id,
      Ecto.UUID.generate(),
      lifecycle_metadata(bundle, request)
      |> Map.put(:outcome, Atom.to_string(outcome))
      |> Map.put(:error_class, request.last_error_class)
    )

    response
  end

  defp audit_lifecycle_execution(response), do: response

  defp bundle_scope(bundle) do
    %{
      org_id: bundle.org_id,
      project_id: bundle.project_id,
      resource_type: "context_bundle",
      resource_id: bundle.id,
      resource_label: "Context bundle"
    }
  end

  defp lifecycle_metadata(bundle, request) do
    %{
      source_type: bundle.source_type,
      policy_ref: bundle.policy_ref,
      lifecycle_state: bundle.lifecycle_state,
      lifecycle_revision: bundle.lifecycle_revision,
      subject_index_state: bundle.subject_index_state,
      request_id: request.id,
      request_kind: request.kind,
      request_state: request.state,
      retry_count: request.retry_count,
      lease_generation: request.lease_generation
    }
  end

  defp normalize_request(attrs, kind) do
    with {:ok, expected_revision} <-
           nonnegative(value(attrs, :expected_revision), :invalid_lifecycle_revision),
         {:ok, requested_by_user_id} <-
           uuid(value(attrs, :requested_by_user_id), :invalid_user_id),
         {:ok, command_id} <-
           opaque_command_id(value(attrs, :command_id), :invalid_lifecycle_command_id),
         {:ok, reason} <-
           reason_code(
             value(attrs, :reason),
             @request_reason_codes,
             :invalid_lifecycle_reason
           ) do
      {:ok,
       %{
         expected_revision: expected_revision,
         requested_by_user_id: requested_by_user_id,
         command_id: command_id,
         reason: reason,
         kind: kind
       }}
    end
  end

  defp normalize_restore(attrs) do
    with {:ok, expected_revision} <-
           nonnegative(value(attrs, :expected_revision), :invalid_lifecycle_revision),
         {:ok, requested_by_user_id} <-
           uuid(value(attrs, :requested_by_user_id), :invalid_user_id),
         {:ok, command_id} <-
           opaque_command_id(value(attrs, :command_id), :invalid_lifecycle_command_id),
         {:ok, reason} <-
           reason_code(
             value(attrs, :reason),
             @restore_reason_codes,
             :invalid_lifecycle_reason
           ) do
      {:ok,
       %{
         expected_revision: expected_revision,
         requested_by_user_id: requested_by_user_id,
         command_id: command_id,
         reason: reason
       }}
    end
  end

  defp normalize_claim(claim) do
    with {:ok, id} <- uuid(value(claim, :id), :invalid_lifecycle_request_id),
         {:ok, lease_owner} <-
           bounded_string(value(claim, :lease_owner), :invalid_lifecycle_worker),
         {:ok, lease_generation} <-
           nonnegative(value(claim, :lease_generation), :invalid_lifecycle_lease) do
      {:ok, %{id: id, lease_owner: lease_owner, lease_generation: lease_generation}}
    end
  end

  defp normalize_counts(counts) when is_map(counts) and map_size(counts) <= 64 do
    counts
    |> Enum.reduce_while({:ok, %{}}, fn {key, count}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if key in @count_keys and is_integer(count) and count >= 0 do
        {:cont, {:ok, Map.put(acc, key, count)}}
      else
        {:halt, {:error, :invalid_purge_counts}}
      end
    end)
  end

  defp normalize_counts(_counts), do: {:error, :invalid_purge_counts}

  defp resolve_purger(source_type, opts) do
    configured =
      Application.get_env(:bridge_for_teams_core, :context_lifecycle_purgers, %{})

    purger = Keyword.get(opts, :purger) || Map.get(configured, source_type)

    if is_atom(purger) and Code.ensure_loaded?(purger) and function_exported?(purger, :purge, 1),
      do: purger,
      else: purge_failed(:terminal, :unsupported_context_source_type)
  end

  defp invoke_purger(purger, bundle) do
    purger.purge(bundle)
  rescue
    _error -> {:error, {:retryable, :purger_crash}}
  catch
    :exit, _reason -> {:error, {:retryable, :purger_exit}}
    _kind, _reason -> {:error, {:retryable, :purger_throw}}
  end

  defp purge_failed(retryability, class) do
    Repo.rollback({
      :lifecycle_purge_failed,
      %{retryable?: retryability == :retryable, class: class}
    })
  end

  defp ensure_requestable(bundle, expected_revision) do
    cond do
      bundle.lifecycle_state != "registered" ->
        Repo.rollback(:context_bundle_not_registered)

      bundle.subject_index_state != "complete" ->
        Repo.rollback(:context_subject_index_incomplete)

      bundle.lifecycle_revision != expected_revision ->
        Repo.rollback(:stale_lifecycle_revision)

      true ->
        :ok
    end
  end

  defp ensure_no_active_request(bundle_id) do
    if Repo.exists?(
         from(request in ContextLifecycleRequest,
           where: request.bundle_id == ^bundle_id and request.state in ^@request_states
         )
       ) do
      Repo.rollback(:lifecycle_request_already_active)
    else
      :ok
    end
  end

  defp ensure_bundle_pending(bundle, request) do
    if bundle.lifecycle_state == pending_state(request.kind),
      do: :ok,
      else: Repo.rollback(:context_lifecycle_state_mismatch)
  end

  defp ensure_claimable(%{state: "pending"}, _now), do: :ok

  defp ensure_claimable(%{state: "retry_wait", retry_not_before: retry_at}, now) do
    if is_struct(retry_at, DateTime) and DateTime.compare(retry_at, now) in [:lt, :eq],
      do: :ok,
      else: Repo.rollback({:retry_not_before, retry_at})
  end

  defp ensure_claimable(%{state: "processing", lease_expires_at: expires_at}, now) do
    if is_struct(expires_at, DateTime) and DateTime.compare(expires_at, now) in [:lt, :eq],
      do: :ok,
      else: Repo.rollback({:lifecycle_request_lease_held, expires_at})
  end

  defp ensure_claimable(%{state: state}, _now),
    do: Repo.rollback({:lifecycle_request_not_claimable, state})

  defp ensure_current_claim(request, fence) do
    now = DateTime.utc_now()

    if request.state == "processing" and request.lease_owner == fence.lease_owner and
         request.lease_generation == fence.lease_generation and
         is_struct(request.lease_expires_at, DateTime) and
         DateTime.compare(request.lease_expires_at, now) == :gt do
      :ok
    else
      Repo.rollback(:stale_lifecycle_lease)
    end
  end

  defp authorize_admin(user_id, %{project_id: project_id}) when not is_nil(project_id) do
    case Memberships.authorize(user_id, :write, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:forbidden)
    end
  end

  defp authorize_admin(user_id, %{org_id: org_id}) do
    authorize_org_admin(user_id, org_id, rollback?: true)
  end

  defp authorize_read(user_id, %{project_id: project_id}) when not is_nil(project_id) do
    Memberships.authorize(user_id, :read, %{project_id: project_id, min_project_role: "user"})
  end

  defp authorize_read(user_id, %{org_id: org_id}) do
    Memberships.authorize(user_id, :read, %{org_id: org_id, min_org_role: "member"})
  end

  defp authorize_org_admin(user_id, org_id),
    do: authorize_org_admin(user_id, org_id, rollback?: false)

  defp authorize_org_admin(user_id, org_id, opts) do
    case Memberships.authorize(user_id, :manage, %{org_id: org_id, min_org_role: "admin"}) do
      :ok ->
        :ok

      {:error, _reason} ->
        if Keyword.get(opts, :rollback?, false),
          do: Repo.rollback(:forbidden),
          else: {:error, :forbidden}
    end
  end

  defp lock_bundle(id) do
    Repo.one(from(bundle in ContextBundle, where: bundle.id == ^id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp lock_request(id) do
    Repo.one(
      from(request in ContextLifecycleRequest, where: request.id == ^id, lock: "FOR UPDATE")
    ) || Repo.rollback(:not_found)
  end

  defp lock_request_by_command(bundle_id, command_id) do
    Repo.one(
      from(request in ContextLifecycleRequest,
        where: request.bundle_id == ^bundle_id and request.command_id == ^command_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_request_by_cancel_command(bundle_id, command_id) do
    Repo.one(
      from(request in ContextLifecycleRequest,
        where: request.bundle_id == ^bundle_id and request.cancel_command_id == ^command_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_latest_request(bundle_id) do
    Repo.one(
      from(request in ContextLifecycleRequest,
        where: request.bundle_id == ^bundle_id,
        order_by: [desc: request.created_at, desc: request.id],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  defp update_bundle!(bundle, attrs) do
    bundle
    |> ContextBundle.lifecycle_changeset(
      Map.merge(
        %{
          lifecycle_state: bundle.lifecycle_state,
          subject_index_state: bundle.subject_index_state,
          lifecycle_revision: bundle.lifecycle_revision,
          last_error: bundle.last_error
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp pending_state("deletion"), do: "deletion_pending"
  defp pending_state("erasure"), do: "erasure_pending"

  defp retry_backoff_ms(retry_count),
    do: min(trunc(:math.pow(2, max(retry_count - 1, 0))) * 1_000, 60_000)

  defp normalize_error_class(value) when is_atom(value) do
    normalized = Atom.to_string(value)
    if normalized in @error_classes, do: normalized, else: "unknown"
  end

  defp normalize_error_class(_value), do: "unknown"

  defp bound(key, default) do
    Application.get_env(:bridge_for_teams_core, :context_lifecycle_bounds, [])
    |> Keyword.get(key, default)
  end

  defp transaction(fun) do
    case Repo.transaction(fun, timeout: Deadlines.lifecycle_request_transaction_timeout_ms()) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp nonnegative(value, _error) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative(_value, error), do: {:error, error}

  defp uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp opaque_command_id(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp reason_code(value, allowed, error) when is_binary(value) do
    normalized = String.trim(value)
    if normalized in allowed, do: {:ok, normalized}, else: {:error, error}
  end

  defp reason_code(_value, _allowed, error), do: {:error, error}

  defp bounded_string(value, error) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= 256, do: {:ok, value}, else: {:error, error}
  end

  defp bounded_string(_value, error), do: {:error, error}

  defp bounded_subject_ref(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 512,
      do: {:ok, value},
      else: {:error, :invalid_subject_ref}
  end

  defp bounded_subject_ref(_value), do: {:error, :invalid_subject_ref}

  defp bounded_limit(opts, key, max) when is_list(opts) do
    case Keyword.get(opts, key, max) do
      value when is_integer(value) and value > 0 -> min(value, max)
      _ -> max
    end
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
