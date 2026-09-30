defmodule SalixMigrate.Cutover do
  @moduledoc """
  Per-agent one-way cutover routing while Willow and Salix run side by side.

  While the legacy Go cluster and Salix run side-by-side, each agent is owned by
  exactly one runtime at a time. The `ctl/agents/{id}.json` registry record (the
  same object `SalixMigrate.Import` seeds) carries the authoritative `migrated`
  flag; the front door routes a request by reading that flag:

    * `migrated == true`  → `:salix` (the agent now lives in this runtime)
    * otherwise           → `:go`   (still served by the legacy cluster)

  The flag is **one-way and idempotent**: `mark_migrated/1` flips `false → true`
  via an `If-Match` CAS against the imported record's live ETag,
  retries on a concurrent write, and is a no-op once already migrated. There is no
  un-migrate path, and a missing import record cannot be created by cutover. This mirrors the
  Go side surrendering the agent under its lock before the flag is set, so the
  S3 conditional write is the single linearization point of the cutover.
  """

  alias SalixStore.{S3, Keys}

  @type route :: :salix | :go

  @doc """
  Read the cutover flag for `agent_id`. `true` once cut over to Salix, `false`
  if the record is absent (never imported) or still flagged for the legacy
  cluster. Surfaces transport errors as `{:error, reason}`.
  """
  @spec migrated?(String.t()) :: boolean() | {:error, term()}
  def migrated?(agent_id) do
    case read(agent_id) do
      {:ok, record, _etag} -> record["migrated"] == true
      {:error, :not_found} -> false
      {:error, _} = err -> err
    end
  end

  @doc """
  Route a request for `agent_id` to the owning runtime. `:salix` once the agent
  has been cut over, `:go` while it is still served by the legacy cluster.
  Transport errors fail closed to `:go` so a flaky read never strands traffic
  away from the runtime that still owns the agent.
  """
  @spec route(String.t()) :: route()
  def route(agent_id) do
    case migrated?(agent_id) do
      true -> :salix
      false -> :go
      {:error, _} -> :go
    end
  end

  @doc """
  Cut `agent_id` over to Salix by setting `migrated: true` in its registry
  record. One-way and idempotent: re-marking an already-migrated agent returns
  `:ok` without a write, and the flag never flips back to `false`. Uses an
  `If-Match` CAS and retries on a
  concurrent registry write so a racing writer cannot lose the cutover.
  """
  @spec mark_migrated(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_migrated(agent_id, opts \\ []) do
    case read(agent_id) do
      {:ok, %{"migrated" => true}, _etag} ->
        :ok

      {:ok, record, etag} ->
        cas_mark(agent_id, record, etag, opts)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  # ---- internal ----

  defp read(agent_id) do
    case S3.get(Keys.ctl_agent(agent_id)) do
      {:ok, %{body: body, etag: etag}} -> {:ok, Jason.decode!(body), etag}
      {:error, :not_found} = err -> err
      {:error, _} = err -> err
    end
  end

  defp cas_mark(agent_id, record, etag, opts) do
    body =
      record |> Map.put("migrated", true) |> Map.put("migrated_at", at(opts)) |> Jason.encode!()

    case S3.put(Keys.ctl_agent(agent_id), body, if_match: etag) do
      {:ok, _} -> :ok
      # Concurrent registry write: re-read and re-apply (idempotent on success).
      {:error, :precondition_failed} -> mark_migrated(agent_id, opts)
      {:error, {:ambiguous, _}} -> verify(agent_id)
      other -> other
    end
  end

  # GET-and-check recovery for an ambiguous write: if the flag stuck,
  # the one-way cutover is done regardless of whether our response was lost.
  defp verify(agent_id) do
    case migrated?(agent_id) do
      true -> :ok
      false -> {:error, {:ambiguous, :mark_migrated}}
      {:error, _} = err -> err
    end
  end

  defp at(opts), do: opts[:at] || DateTime.utc_now() |> DateTime.to_iso8601()
end
