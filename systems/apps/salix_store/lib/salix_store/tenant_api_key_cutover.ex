defmodule SalixStore.TenantApiKeyCutover do
  @moduledoc """
  The tenant-api-key authority cutover (docs/storage-search.md).

  `run/0` executes inside the exclusive release stage at zero replicas: it
  imports every legacy S3 record into Postgres, verifies strict set equality
  between the two stores, and persists the cutover marker.

  The marker is a **terminal authority fence**, not a progress note. Once it
  exists, `run/0` is a no-op: Postgres is authoritative, S3 still holds the
  pre-cutover objects (PR-B removes them), and a re-run must never re-import
  them over legitimate PG-only deletes. `run/0` therefore consults the
  three-state `marker_status/0` directly: `:present` → no-op, `:absent` →
  import, and an unreadable marker (transient DB fault) → **abort**, never
  re-import.

  Serving does not check the marker per request. Readiness does: a pod stays
  out of service until `marker_present?/0` is true (wired through
  `Comma.PodLifecycle.ready(:salix)` and the `SalixStore.TenantApiKeyReadiness`
  probe), exactly like `Comma.SchemaReadiness` gates the comma_product surface.
  Once ready, request handlers read Postgres directly — the migration is a
  deploy-time fact, not a runtime protocol. The marker is only ever written by
  `run/0` (the exclusive release ceremony in production, or `Comma.Release.migrate/0`
  in dev/compose/test); the request path never mints it.

  Enumeration is fail-closed end to end: full pagination via `S3.list_all/1`,
  and any LIST/GET/decode/shape error aborts the whole step. It deliberately
  does not reuse `Salix.Control.Store.list_keyed_records/2`, which folds
  LIST/GET failures into a partially-successful corpus.
  """

  alias SalixStore.{Keys, Repo, S3, TenantApiKeys}

  @marker_name "tenant_api_keys_v1"

  # Largest epoch-seconds value `DateTime.from_unix!(x * 1_000_000, :microsecond)`
  # accepts (9999-12-31T23:59:59Z). A larger created_at — e.g. a millisecond-
  # magnitude corrupt value — raises ArgumentError inside from_record mid-import.
  @max_epoch_seconds 253_402_300_799

  @doc """
  The full exclusive-stage cutover: import, verify equality, mark.

  A no-op once the marker exists (terminal authority fence): re-importing S3
  after cutover would resurrect keys deleted through the PG-only path. A
  transient DB fault at the marker read aborts rather than blindly re-importing.
  """
  @spec run() :: :ok | {:error, term()}
  def run do
    case marker_status() do
      :present ->
        :ok

      :absent ->
        with {:ok, records} <- enumerate_s3(),
             :ok <- import_all(records),
             {:ok, evidence} <- verify_equality(),
             :ok <- mark!(evidence) do
          :ok
        end

      {:error, reason} ->
        {:error, {:marker_unreadable, reason}}
    end
  end

  @doc """
  Compare the S3 corpus with the PG rows without writing anything.

  Returns `{:ok, evidence}` on strict equality, `{:error, {:mismatch, diff}}`
  otherwise. Used by the equality gate inside `run/0` and by
  `mix salix.tenant_api_keys.audit`.
  """
  @spec verify_equality() :: {:ok, map()} | {:error, term()}
  def verify_equality do
    with {:ok, records} <- enumerate_s3() do
      s3_set = records |> Enum.map(&TenantApiKeys.canonical/1) |> MapSet.new()
      pg_set = TenantApiKeys.all_records() |> Enum.map(&TenantApiKeys.canonical/1) |> MapSet.new()

      missing_in_pg = MapSet.difference(s3_set, pg_set)
      missing_in_s3 = MapSet.difference(pg_set, s3_set)

      if MapSet.size(missing_in_pg) == 0 and MapSet.size(missing_in_s3) == 0 do
        {:ok, %{"record_count" => MapSet.size(s3_set)}}
      else
        {:error,
         {:mismatch,
          %{
            missing_in_pg: Enum.map(missing_in_pg, & &1["key_hash"]),
            missing_in_s3: Enum.map(missing_in_s3, & &1["key_hash"])
          }}}
      end
    end
  end

  @doc """
  Fail-closed count of importable legacy S3 records (pre-cutover preflight).

  Returns `{:ok, count}` when the corpus reads cleanly, `{:error, reason}` on
  any LIST/GET/decode/address fault. Unlike `verify_equality/0` it does NOT
  compare against Postgres: before the cutover, PG is legitimately empty, so the
  normal preflight state (nonempty S3, empty PG) reports the importable count
  rather than a mismatch.
  """
  @spec importable_count() :: {:ok, non_neg_integer()} | {:error, term()}
  def importable_count do
    with {:ok, records} <- enumerate_s3() do
      {:ok, length(records)}
    end
  end

  @doc """
  True once the cutover marker exists; false when it is absent or unreadable.

  This is the readiness signal consumed by `SalixStore.TenantApiKeyReadiness`
  and, through it, `Comma.PodLifecycle.ready(:salix)`. A `false` result keeps the
  pod out of service (probe retries), which correctly covers both "cutover not
  run yet" and "DB not reachable yet" — neither may serve key operations.
  """
  @spec marker_present?() :: boolean()
  def marker_present? do
    marker_status() == :present
  end

  # Three-state so `run/0` can tell "cutover not done" (absent) apart from
  # "cannot tell" (DB fault): the latter must abort the import, never proceed.
  defp marker_status do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker_name]) do
      {:ok, %{rows: [[1]]}} -> :present
      {:ok, %{rows: []}} -> :absent
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp mark!(evidence) when is_map(evidence) do
    now = DateTime.utc_now()

    case Repo.query(
           "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, $2, $3) ON CONFLICT (name) DO NOTHING",
           [@marker_name, now, evidence]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:marker_write_failed, reason}}
    end
  end

  defp import_all(records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case TenantApiKeys.import_record(record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:import_failed, reason}}}
      end
    end)
  end

  # Fail-closed corpus walk: complete pagination, every object fetched and
  # decoded, body coordinates required to round-trip to the physical key
  # (a lying body must abort the cutover, not be imported under a different
  # identity).
  defp enumerate_s3 do
    root = Keys.ctl_api_keys_root()

    with {:ok, objects} <- S3.list_all(root) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, acc} ->
        case read_record(key) do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          {:error, reason} -> {:halt, {:error, {:enumerate_failed, key, reason}}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, _} = error -> error
      end
    end
  end

  defp read_record(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} <- Jason.decode(body),
         :ok <- validate_record(key, record) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_record}
    end
  end

  # Validate every field `TenantApiKeys.from_record/1` materializes into a row,
  # so a malformed legacy record fails enumeration closed — before any PG write —
  # rather than crashing the exclusive ceremony mid-import (partial write):
  #   * key_hash/tenant_id must be strings (they key the row and its address);
  #   * created_at must be a non-negative epoch integer within the range
  #     DateTime.from_unix!/2 accepts (a non-integer → ArithmeticError, an
  #     out-of-range integer → ArgumentError);
  #   * name feeds a :string column, so a non-string would raise Ecto.ChangeError
  #     at insert (nil is fine — from_record substitutes "API key").
  # A non-map body or any missing/ill-typed key field falls through to the
  # catch-all clause.
  defp validate_record(
         key,
         %{
           "key_hash" => key_hash,
           "tenant_id" => tenant_id,
           "created_at" => created_at
         } = record
       )
       when is_binary(key_hash) and is_binary(tenant_id) and is_integer(created_at) and
              created_at >= 0 and created_at <= @max_epoch_seconds do
    cond do
      not optional_string?(record["name"]) -> {:error, :invalid_record}
      key != Keys.ctl_api_key(tenant_id, key_hash) -> {:error, :record_address_mismatch}
      true -> :ok
    end
  end

  defp validate_record(_key, _record), do: {:error, :invalid_record}

  defp optional_string?(value), do: is_nil(value) or is_binary(value)
end
