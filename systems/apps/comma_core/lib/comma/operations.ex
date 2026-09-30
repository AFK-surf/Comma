defmodule Comma.Operations do
  @moduledoc """
  Durable state reducer for Comma-owned external operations.

  Domain contexts insert their desired fact, operation, and Oban job in one
  transaction through `create_with_job/2`. Workers claim the operation before
  making an external call, then acknowledge the result in a separate
  transaction. An operation row and its generation are the mutex and fencing
  contract; Oban uniqueness only reduces duplicate enqueue.
  """

  import Ecto.Query

  alias Comma.Data.ExternalOperation
  alias Comma.Repo
  alias Ecto.{Changeset, Multi}

  @terminal ~w(succeeded terminal_failed superseded)
  @active ~w(pending executing retryable)
  @forbidden_metadata_fragments ~w(token secret password authorization cookie)

  @type claim_result ::
          {:execute, struct()}
          | {:complete, struct()}
          | {:superseded, struct()}

  @doc """
  Adds an operation and its domain worker job to an `Ecto.Multi`.

  The worker changeset must contain exactly `%{"operation_id" => id}`. Domain
  payloads remain in typed Comma tables rather than durable queue arguments.
  """
  def create_with_job(%Multi{} = multi, attrs, %Changeset{} = job_changeset)
      when is_map(attrs) do
    operation_id = fetch_attr!(attrs, :operation_id)
    validate_job_args!(job_changeset, operation_id)

    multi =
      multi
      |> Multi.insert(
        :comma_operation,
        ExternalOperation.changeset(%ExternalOperation{}, attrs),
        on_conflict: :nothing
      )
      |> Multi.run(:comma_operation_row, fn repo, _changes ->
        fetch_and_validate_created(repo, attrs)
      end)
      |> Multi.run(:comma_superseded_operations, fn repo, %{comma_operation_row: operation} ->
        supersede_older(repo, operation)
      end)

    Oban.insert(Comma.Oban, multi, :comma_operation_job, job_changeset)
  end

  def create_with_job(attrs, %Changeset{} = job_changeset) when is_map(attrs) do
    Multi.new()
    |> create_with_job(attrs, job_changeset)
    |> Repo.transaction()
  end

  @doc """
  Locks and claims an operation if it still matches the owner's desired generation.

  A lower operation generation is atomically marked `superseded`. A higher
  generation is never mutated by a stale caller.
  """
  @spec claim(String.t(), non_neg_integer()) ::
          {:ok, claim_result()} | {:error, :not_found | :future_generation | :not_due}
  def claim(operation_id, desired_generation)
      when is_binary(operation_id) and is_integer(desired_generation) and desired_generation >= 0 do
    Repo.transaction(fn ->
      operation = lock_operation(operation_id)

      cond do
        is_nil(operation) ->
          Repo.rollback(:not_found)

        operation.generation < desired_generation ->
          operation = finish(operation, "superseded", %{})
          {:superseded, operation}

        operation.generation > desired_generation ->
          Repo.rollback(:future_generation)

        operation.status in @terminal ->
          {:complete, operation}

        operation.status == "executing" and not orphaned?(operation) ->
          Repo.rollback(:not_due)

        operation.status == "retryable" and not due?(operation.next_attempt_at) ->
          Repo.rollback(:not_due)

        operation.status in ["pending", "retryable", "executing"] ->
          operation =
            operation
            |> Changeset.change(
              status: "executing",
              attempt: operation.attempt + 1,
              next_attempt_at: nil,
              last_error_class: nil,
              finished_at: nil
            )
            |> Repo.update!()

          {:execute, operation}
      end
    end)
    |> finalize_transaction()
  end

  @doc """
  Records a retryable failure without altering prior external identity or evidence.
  """
  def retryable(operation_id, generation, error_class, next_attempt_at)
      when is_binary(error_class) and is_struct(next_attempt_at, DateTime) do
    transition_from_executing(operation_id, generation, fn operation ->
      operation
      |> Changeset.change(
        status: "retryable",
        last_error_class: error_class,
        next_attempt_at: next_attempt_at,
        finished_at: nil
      )
      |> Repo.update!()
    end)
  end

  @doc """
  Records the stable external identity and bounded redacted success evidence.

  Repeating the same acknowledgement returns the original succeeded row without
  replacing its identity, metadata, or completion timestamp.
  """
  def succeed(operation_id, generation, external_identity, evidence \\ %{})
      when is_binary(external_identity) and external_identity != "" do
    validate_evidence!(evidence)

    transition_from_executing(operation_id, generation, fn operation ->
      case operation.external_identity do
        existing when is_binary(existing) and existing != external_identity ->
          Repo.rollback(:external_identity_conflict)

        _ ->
          finish(operation, "succeeded", evidence,
            external_identity: operation.external_identity || external_identity
          )
      end
    end)
  end

  @doc """
  Records a non-retryable, redacted error classification and bounded evidence.
  """
  def terminal_failed(operation_id, generation, error_class, evidence \\ %{})
      when is_binary(error_class) and error_class != "" do
    validate_evidence!(evidence)

    transition_from_executing(operation_id, generation, fn operation ->
      finish(operation, "terminal_failed", evidence, last_error_class: error_class)
    end)
  end

  defp transition_from_executing(operation_id, generation, reducer) do
    Repo.transaction(fn ->
      operation = lock_operation(operation_id)

      cond do
        is_nil(operation) ->
          Repo.rollback(:not_found)

        operation.generation != generation ->
          Repo.rollback(:stale_generation)

        operation.status in @terminal ->
          {:complete, operation}

        operation.status != "executing" ->
          Repo.rollback(:not_executing)

        true ->
          updated = reducer.(operation)
          {:updated, updated}
      end
    end)
    |> finalize_transaction()
  end

  defp finish(operation, status, evidence, extra_changes \\ []) do
    metadata =
      if map_size(evidence) == 0 do
        operation.metadata
      else
        Map.update(operation.metadata || %{}, "terminal_evidence", evidence, fn existing ->
          existing || evidence
        end)
      end

    operation
    |> Changeset.change(
      Keyword.merge(extra_changes,
        status: status,
        metadata: metadata,
        next_attempt_at: nil,
        finished_at: DateTime.utc_now()
      )
    )
    |> Repo.update!()
  end

  defp lock_operation(operation_id) do
    Repo.one(
      from(operation in ExternalOperation,
        where: operation.operation_id == ^operation_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch_and_validate_created(repo, attrs) do
    operation_type = fetch_attr!(attrs, :operation_type)
    owner_type = fetch_attr!(attrs, :owner_type)
    owner_id = fetch_attr!(attrs, :owner_id)
    generation = fetch_attr!(attrs, :generation)

    expected_key = fetch_attr!(attrs, :external_idempotency_key)
    expected_id = fetch_attr!(attrs, :operation_id)

    case repo.one(
           from(operation in ExternalOperation,
             where:
               operation.operation_type == ^operation_type and
                 operation.owner_type == ^owner_type and
                 operation.owner_id == ^owner_id and
                 operation.generation == ^generation
           )
         ) do
      %ExternalOperation{
        operation_id: ^expected_id,
        external_idempotency_key: ^expected_key
      } = operation ->
        {:ok, operation}

      _ ->
        {:error, :operation_identity_conflict}
    end
  end

  defp supersede_older(repo, operation) do
    now = DateTime.utc_now()

    {count, _} =
      repo.update_all(
        from(candidate in ExternalOperation,
          where:
            candidate.operation_type == ^operation.operation_type and
              candidate.owner_type == ^operation.owner_type and
              candidate.owner_id == ^operation.owner_id and
              candidate.generation < ^operation.generation and
              candidate.status in ^@active
        ),
        set: [status: "superseded", next_attempt_at: nil, finished_at: now, updated_at: now]
      )

    {:ok, count}
  end

  defp validate_job_args!(job_changeset, operation_id) do
    case Changeset.get_field(job_changeset, :args) do
      %{"operation_id" => ^operation_id} = args when map_size(args) == 1 -> :ok
      %{operation_id: ^operation_id} = args when map_size(args) == 1 -> :ok
      _ -> raise ArgumentError, "Comma Oban jobs must contain only operation_id"
    end
  end

  defp validate_evidence!(evidence) when is_map(evidence) and map_size(evidence) <= 16 do
    valid? =
      Enum.all?(evidence, fn
        {key, value} when is_binary(key) and byte_size(key) <= 64 ->
          downcased = String.downcase(key)

          Enum.all?(@forbidden_metadata_fragments, &(not String.contains?(downcased, &1))) and
            bounded_scalar?(value)

        _ ->
          false
      end)

    if valid?,
      do: :ok,
      else: raise(ArgumentError, "operation evidence must be bounded and redacted")
  end

  defp validate_evidence!(_evidence),
    do: raise(ArgumentError, "operation evidence must be a bounded map")

  defp bounded_scalar?(value) when is_binary(value), do: byte_size(value) <= 512

  defp bounded_scalar?(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  defp bounded_scalar?(_value), do: false

  defp due?(nil), do: true
  defp due?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp orphaned?(operation) do
    timeout_ms = Application.fetch_env!(:comma_core, :operation_claim_timeout_ms)
    DateTime.diff(DateTime.utc_now(), operation.updated_at, :millisecond) >= timeout_ms
  end

  defp fetch_attr!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(attrs, Atom.to_string(key))
    end
  end

  defp finalize_transaction({:ok, {kind, operation}} = result)
       when kind in [:execute, :superseded, :updated] do
    emit_transition(operation, operation.status)
    result
  end

  defp finalize_transaction({:ok, result}), do: {:ok, result}
  defp finalize_transaction({:error, reason}), do: {:error, reason}

  defp emit_transition(operation, status) do
    :telemetry.execute(
      [:comma, :operation, :transition],
      %{attempt: operation.attempt},
      %{status: status}
    )

    case status do
      "retryable" ->
        CommaProduct.Telemetry.emit_backlog_retry(queue_for(operation.operation_type))

      "terminal_failed" ->
        CommaProduct.Telemetry.emit_backlog_terminal_failure(queue_for(operation.operation_type))

      _ ->
        :ok
    end
  end

  defp queue_for(_operation_type), do: :comma_external
end
