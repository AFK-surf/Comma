defmodule SalixStore.SchedulesCutover do
  @moduledoc """
  The schedules authority cutover (docs/storage-search.md).

  Moves schedule definitions (`ctl/schedules/{id}.json`) from S3 to Postgres in
  one exclusive stage: import every legacy object, verify strict S3↔PG set
  equality, persist the terminal marker `schedules_v1`.

  Same contract as `SalixStore.TenantConfigsCutover`: `run/0` consults the
  three-state `marker_status/0` directly (present → no-op, absent → import,
  unreadable → abort, never re-import over PG-only deletes). Enumeration is
  fail-closed: every object under the prefix is fetched and validated against
  every materialization precondition of `SalixStore.Schedules.import_record/2`
  — top-level map, physical-key round-trip for `id`, string/integer column
  types with int8-representable timestamps, map-or-absent `payload` — so both
  the audit preflight and the ceremony abort deterministically before any PG
  write. Bodies are otherwise imported verbatim (odd historical values keep
  today's runtime behaviour); unknown keys round-trip through `attrs`.

  `next_fire_at` is imported as the anchor (`last_run || created_at`) — a
  valid lower bound by construction (both recurrence kinds fire strictly after
  their anchor), so no cron evaluation happens inside salix_store; the first
  sweep re-derives exact values and heals the column.

  ## Run claims (`ctl/schedule_runs/`) are deliberately NOT imported

  A legacy claim object has exactly one live use: resuming an in-flight window
  (claimed but not yet advanced) — and the cutover runs at zero replicas with
  the sweeper stopped. If such a window exists at cutover, the definition's
  un-advanced anchor re-selects it, the PG claim insert wins, and the window is
  re-dispatched — absorbed by the receiver idempotency contract (deterministic
  `schedule:{id}:{scheduled_for_ms}` source ids dedupe at the inbox and the
  owner's in-state index; the Task receiver is idempotent per contract). The
  historical claim audit trail restarts empty in PG, retention-pruned — the S3
  prefix had no GC and only ever grew.
  """

  alias SalixStore.{Keys, Repo, S3, Schedules}

  @marker_name "schedules_v1"
  @suffix ".json"

  # Largest magnitude a Postgres bigint column accepts. Legacy timestamps are
  # unix-ms integers stored verbatim (no DateTime conversion), so the only
  # materialization bound is int8 representability — a JSON integer beyond it
  # would raise inside the insert, mid-import.
  @max_int8 9_223_372_036_854_775_807

  @string_keys ~w(receiver agent_id session_id prompt cron timezone status kind name)
  @integer_keys ~w(interval_minutes run_at updated_at last_run)

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
      pg = record_set(Schedules.all_records())

      if MapSet.equal?(s3, pg),
        do: {:ok, %{"schedule_records" => MapSet.size(s3)}},
        else: {:error, {:mismatch, :schedules}}
    end
  end

  @doc "Fail-closed importable count (pre-cutover preflight)."
  @spec importable_count() :: {:ok, map()} | {:error, term()}
  def importable_count do
    with {:ok, records} <- enumerate() do
      {:ok, %{"schedules" => length(records)}}
    end
  end

  @doc "True once the cutover marker exists; false when absent or unreadable."
  @spec marker_present?() :: boolean()
  def marker_present?, do: marker_status() == :present

  defp record_set(records), do: MapSet.new(records, &Schedules.canonical/1)

  defp import_all(records) do
    reduce_ok(records, fn rec ->
      case Schedules.import_record(rec, anchor(rec)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:schedule_import_failed, reason}}
      end
    end)
  end

  # Anchor = the value both recurrence kinds fire strictly after; always a
  # valid `next_fire_at` lower bound. `created_at` is validated required.
  defp anchor(rec), do: rec["last_run"] || rec["created_at"]

  # Fail-closed prefix walk: full pagination, every object fetched, decoded,
  # and validated; any error aborts the whole enumeration.
  defp enumerate do
    with {:ok, objects} <- S3.list_all(Keys.schedule_prefix()) do
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

  # The physical key is authoritative for `id`. Reject any object whose
  # address does not round-trip, whose body `id` disagrees with the key, or
  # whose fields cannot materialize into their columns.
  defp validate(key, rec) do
    with {:ok, id} <- parse_key(key) do
      cond do
        rec["id"] not in [nil, id] ->
          {:error, :record_address_mismatch}

        not valid_ms?(rec["created_at"]) ->
          {:error, :invalid_record}

        not (is_nil(rec["payload"]) or is_map(rec["payload"])) ->
          {:error, :invalid_record}

        Enum.any?(@string_keys, fn k -> not optional_string?(rec[k]) end) ->
          {:error, :invalid_record}

        Enum.any?(@integer_keys, fn k -> not optional_ms?(rec[k]) end) ->
          {:error, :invalid_record}

        true ->
          {:ok, Map.put(rec, "id", id)}
      end
    end
  end

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp optional_ms?(value), do: is_nil(value) or valid_ms?(value)

  defp valid_ms?(value), do: is_integer(value) and abs(value) <= @max_int8

  defp parse_key(key) do
    id =
      key
      |> String.replace_prefix(Keys.schedule_prefix(), "")
      |> String.replace_suffix(@suffix, "")

    with true <- id != "",
         ^key <- Keys.schedule(id) do
      {:ok, id}
    else
      _ -> {:error, :record_address_mismatch}
    end
  end

  # Require a JSON object: a top-level array/scalar body must fail closed here,
  # before validate/2 accesses `rec["id"]` (Access on a non-map raises).
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
