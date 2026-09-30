defmodule Salix.Control.IntegrationMaterializationLifecycle do
  @moduledoc """
  Owns the complete eval-only OAuth materialization transaction.

  The group lease serializes plugin setup, OAuth connection/binding creation,
  remote MCP projection, and compensation across every Salix instance. The
  logical lifecycle record prevents an idempotent caller from treating a
  partially materialized integration as successful: only `committed` records
  are replayable.
  """

  alias Salix.Control.Store
  alias SalixStore.{Keys, Lease, S3}

  @lease_ttl_ms 300_000
  @acquire_timeout_ms 60_000
  @retry_ms 100

  def run(tenant_id, group_id, identity, integration_id, operation)
      when is_map(identity) and is_function(operation, 0) do
    holder = Store.random_id()
    lease_key = Keys.ctl_integration_materialization_lease(group_id)

    with {:ok, lease} <- acquire(lease_key, holder) do
      try do
        key =
          Keys.ctl_integration_materialization(
            group_id,
            identity
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(fn {key, value} -> [key, value] end)
            |> Jason.encode!()
          )

        case begin_lifecycle(key, tenant_id, group_id, identity, integration_id, holder) do
          {:committed, result} ->
            {:ok, result}

          {:execute, token} ->
            case execute(token, operation) do
              {:ok, result} ->
                case transition(token, "committed", %{"result" => result}) do
                  :ok -> {:ok, result}
                  {:error, reason} -> {:error, reason}
                end

              {:error, _reason} = error ->
                _ = transition(token, "failed", %{})
                error
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        Lease.release(lease)
      end
    end
  end

  defp acquire(key, holder) do
    deadline = System.monotonic_time(:millisecond) + @acquire_timeout_ms
    acquire(key, holder, deadline)
  end

  defp execute(token, operation) do
    operation.()
  rescue
    error ->
      _ = transition(token, "failed", %{})
      reraise(error, __STACKTRACE__)
  catch
    kind, reason ->
      _ = transition(token, "failed", %{})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp acquire(key, holder, deadline) do
    case Lease.acquire(key, holder, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:held_by, _owner, _until}} ->
        retry_acquire(key, holder, deadline)

      {:error, {:ambiguous, _operation}} ->
        retry_acquire(key, holder, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_acquire(key, holder, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:conflict, "integration materialization is already in progress"}}
    else
      Process.sleep(@retry_ms)
      acquire(key, holder, deadline)
    end
  end

  defp begin_lifecycle(key, tenant_id, group_id, identity, integration_id, holder) do
    now = Store.now()

    case S3.get(key) do
      {:error, :not_found} ->
        record =
          lifecycle_record(
            tenant_id,
            group_id,
            identity,
            integration_id,
            holder,
            1,
            now
          )

        case S3.put(key, Jason.encode!(record), if_none_match: "*") do
          {:ok, %{etag: etag}} ->
            {:execute, %{key: key, etag: etag, holder: holder, generation: 1}}

          {:error, :precondition_failed} ->
            begin_lifecycle(key, tenant_id, group_id, identity, integration_id, holder)

          {:error, {:ambiguous, _operation}} ->
            verify_pending(key, holder, 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{body: body, etag: etag}} ->
        record = Jason.decode!(body)

        if record["state"] == "committed" do
          if record["integration_id"] == integration_id do
            {:committed, record["result"]}
          else
            {:error, {:conflict, "integration alias is already owned by another integration"}}
          end
        else
          generation = (record["generation"] || 0) + 1

          next =
            lifecycle_record(
              tenant_id,
              group_id,
              identity,
              integration_id,
              holder,
              generation,
              now
            )

          case S3.put(key, Jason.encode!(next), if_match: etag) do
            {:ok, %{etag: next_etag}} ->
              {:execute, %{key: key, etag: next_etag, holder: holder, generation: generation}}

            {:error, :precondition_failed} ->
              begin_lifecycle(key, tenant_id, group_id, identity, integration_id, holder)

            {:error, {:ambiguous, _operation}} ->
              verify_pending(key, holder, generation)

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_pending(key, holder, generation) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        record = Jason.decode!(body)

        if record["state"] == "pending" and record["holder"] == holder and
             record["generation"] == generation do
          {:execute, %{key: key, etag: etag, holder: holder, generation: generation}}
        else
          {:error, :precondition_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition(token, state, extra) do
    with {:ok, %{body: body}} <- S3.get(token.key) do
      current = Jason.decode!(body)

      if current["state"] == "pending" and current["holder"] == token.holder and
           current["generation"] == token.generation do
        next =
          current
          |> Map.merge(extra)
          |> Map.put("state", state)
          |> Map.put("updated_at", Store.now())

        case S3.put(token.key, Jason.encode!(next), if_match: token.etag) do
          {:ok, _result} -> :ok
          {:error, {:ambiguous, _operation}} -> verify_transition(token, state)
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :precondition_failed}
      end
    end
  end

  defp verify_transition(token, state) do
    case S3.get(token.key) do
      {:ok, %{body: body}} ->
        record = Jason.decode!(body)

        if record["state"] == state and record["holder"] == token.holder and
             record["generation"] == token.generation,
           do: :ok,
           else: {:error, :precondition_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lifecycle_record(
         tenant_id,
         group_id,
         identity,
         integration_id,
         holder,
         generation,
         now
       ) do
    %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "identity" => identity,
      "integration_id" => integration_id,
      "state" => "pending",
      "holder" => holder,
      "generation" => generation,
      "created_at" => now,
      "updated_at" => now
    }
  end
end
