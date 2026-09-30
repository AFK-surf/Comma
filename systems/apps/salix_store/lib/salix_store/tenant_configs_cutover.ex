defmodule SalixStore.TenantConfigsCutover do
  @moduledoc """
  The tenant-configs authority cutover (docs/storage-search.md).

  Moves discrete tenant config objects (`ctl/tenant_configs/{tenant_id}/{name}.json`)
  from S3 to Postgres in one exclusive stage: import every legacy object,
  verify strict S3↔PG set equality, persist the terminal marker
  `tenant_configs_v1`.

  Same contract as `SalixStore.ProviderCredentialsCutover`: `run/0` consults the
  three-state `marker_status/0` directly (present → no-op, absent → import,
  unreadable → abort, never re-import over PG-only deletes). Enumeration is
  fail-closed and name-agnostic — every object under the prefix is imported, and
  a record whose body does not round-trip to its physical `(tenant_id, name)` key
  aborts the cutover rather than importing under a different identity. The
  payload is arbitrary JSON, so equality compares the DECODED value map, not the
  raw bytes. Readiness (`SalixStore.TenantConfigsReadiness` via
  `Comma.PodLifecycle.ready(:salix)`) keeps a pod out of service until the marker
  exists.
  """

  alias SalixStore.{Keys, Repo, S3, TenantConfigs}

  @marker_name "tenant_configs_v1"
  @suffix ".json"

  # Largest epoch-seconds value `DateTime.from_unix!(x * 1_000_000, :microsecond)`
  # accepts (9999-12-31T23:59:59Z). from_record multiplies updated_at by 1_000_000
  # and builds a microsecond DateTime, so a larger value — e.g. a millisecond-
  # magnitude corrupt timestamp — raises ArgumentError mid-import.
  @max_epoch_seconds 253_402_300_799

  @spec run() :: :ok | {:error, term()}
  def run do
    case marker_status() do
      :present ->
        :ok

      :absent ->
        with {:ok, records} <- enumerate(),
             :ok <- import_all(records),
             {:ok, evidence} <- verify_equality(),
             :ok <- mark!(evidence) do
          :ok
        end

      {:error, reason} ->
        {:error, {:marker_unreadable, reason}}
    end
  end

  @doc "Strict S3↔PG set equality without writing anything."
  @spec verify_equality() :: {:ok, map()} | {:error, term()}
  def verify_equality do
    with {:ok, records} <- enumerate() do
      s3 = record_set(records)
      pg = record_set(TenantConfigs.all_records())

      if MapSet.equal?(s3, pg),
        do: {:ok, %{"tenant_config_records" => MapSet.size(s3)}},
        else: {:error, {:mismatch, :tenant_configs}}
    end
  end

  @doc "Fail-closed importable count (pre-cutover preflight)."
  @spec importable_count() :: {:ok, map()} | {:error, term()}
  def importable_count do
    with {:ok, records} <- enumerate() do
      {:ok, %{"tenant_configs" => length(records)}}
    end
  end

  @doc "True once the cutover marker exists; false when absent or unreadable."
  @spec marker_present?() :: boolean()
  def marker_present?, do: marker_status() == :present

  defp record_set(records), do: MapSet.new(records, &TenantConfigs.canonical/1)

  defp import_all(records) do
    reduce_ok(records, fn rec ->
      case TenantConfigs.import_record(rec) do
        :ok -> :ok
        {:error, reason} -> {:error, {:tenant_config_import_failed, reason}}
      end
    end)
  end

  # Fail-closed, name-agnostic prefix walk: full pagination, every object
  # fetched, decoded, and validated; any error aborts the whole enumeration.
  defp enumerate do
    with {:ok, objects} <- S3.list_all(Keys.ctl_tenant_configs_prefix()) do
      objects
      |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, acc} ->
        with {:ok, rec} <- read_json(key),
             {:ok, record} <- validate(key, rec) do
          {:cont, {:ok, [record | acc]}}
        else
          {:error, reason} -> {:halt, {:error, {:enumerate_failed, key, reason}}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = error -> error
      end
    end
  end

  # The physical key is authoritative for `(tenant_id, name)`; the body carries
  # the payload. Reject any object whose address does not parse, whose body
  # `tenant_id`/`name` disagree with the key, or whose `value` is not a JSON map.
  defp validate(key, rec) do
    with {:ok, tenant_id, name} <- parse_key(key) do
      cond do
        rec["tenant_id"] not in [nil, tenant_id] ->
          {:error, :record_address_mismatch}

        rec["name"] not in [nil, name] ->
          {:error, :record_address_mismatch}

        not is_map(rec["value"]) ->
          {:error, :invalid_record}

        not valid_updated_at?(rec["updated_at"]) ->
          {:error, :invalid_record}

        true ->
          {:ok,
           %{
             "tenant_id" => tenant_id,
             "name" => name,
             "value" => rec["value"],
             "updated_at" => rec["updated_at"]
           }}
      end
    end
  end

  # `TenantConfigs.from_record/1` treats `updated_at` as epoch seconds and
  # converts it with DateTime.from_unix!/2; a non-integer (ISO-8601 string →
  # ArithmeticError) or an out-of-range integer (millisecond-magnitude value →
  # ArgumentError) would raise mid-import. Require an integer within the
  # representable range so both the audit preflight (importable_count/0) and
  # run/0 fail closed during enumeration — before any PG write or marker —
  # instead of a partial import + crash in the ceremony.
  defp valid_updated_at?(value),
    do: is_integer(value) and value >= 0 and value <= @max_epoch_seconds

  defp parse_key(key) do
    middle =
      key
      |> String.replace_prefix(Keys.ctl_tenant_configs_prefix(), "")
      |> String.replace_suffix(@suffix, "")

    with [tenant_id, name] <- String.split(middle, "/"),
         true <- tenant_id != "" and name != "",
         ^key <- Keys.ctl_tenant_config(tenant_id, name) do
      {:ok, tenant_id, name}
    else
      _ -> {:error, :record_address_mismatch}
    end
  end

  # Require a JSON object: a top-level array/scalar body must fail closed here,
  # before validate/2 accesses `rec["tenant_id"]` (Access on a non-map raises).
  defp read_json(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_record}
    end
  end

  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

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
end
