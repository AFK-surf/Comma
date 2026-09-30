defmodule SalixStore.OAuthAppsCutover do
  @moduledoc """
  The OAuth-apps authority cutover (docs/storage-search.md, PR-1).

  Moves the OAuth static provider-app credentials to Postgres in one exclusive
  stage under the marker `oauth_apps_v1`:

    * `ctl/oauth/provider_apps/{tenant}/{provider}.json` → `oauth_provider_apps`
      (scope = tenant id);
    * `ctl/oauth/default_apps/{provider}.json` → `oauth_provider_apps`
      (scope = `OAuthProviderApps.default_scope/0`).

  Remote-MCP provider apps (`ctl/tenants/{t}/oauth/provider_apps/remote_mcp/*`),
  OAuth *connections* (live tokens), remote-MCP *client_registrations*, and group
  bindings are OUT of this resident — they migrate later or stay in S3.

  Same contract as the earlier cutovers (`SalixStore.ProviderCredentialsCutover`):
  `run/0` consults the three-state `marker_status/0` directly (present → no-op,
  absent → import, unreadable → abort, never re-import over PG-only deletes).
  Enumeration is fail-closed end to end and validates every `from_record`
  materialization precondition before any PG write — a non-map body, a
  non-string typed field, or an out-of-range `updated_at` aborts the whole step
  as `{:enumerate_failed, key, :invalid_record}` (so `importable_count/0` and
  `run/0` fail at the same point). The imports + equality gate + marker insert
  run in ONE transaction so any failure rolls back to zero rows and no marker.
  The whole step — enumeration and transaction — runs under one outer
  monotonic deadline (`@default_cutover_timeout_ms`) with an execution-time
  object-count bound (`@default_max_objects`): a slow object store or an
  unexpectedly grown corpus aborts fail-closed instead of stretching the
  writers=0 window.
  """

  alias SalixStore.{Keys, OAuthProviderApps, Repo, S3}

  @marker_name "oauth_apps_v1"
  @suffix ".json"

  # Largest epoch-seconds value DateTime.from_unix!(x * 1_000_000, :microsecond)
  # accepts (9999-12-31T23:59:59Z); a larger value raises ArgumentError mid-import.
  @max_epoch_seconds 253_402_300_799

  # One OUTER deadline covers the whole step — the S3 enumeration (LIST + one
  # GET per object, outside the transaction) AND the PG transaction — enforced
  # with a monotonic clock and a supervised task kill, because the release
  # controller does not enforce `timeoutSeconds` against the phase budget. The
  # production hard exclusive budget is 300s for the ENTIRE writers=0 interval
  # (docs/release-operations.md); scheduling, pod start, verify and
  # restart share it, and the one measured incident burned 92s on Job scheduling
  # alone (docs/release-operations.md). The step
  # therefore takes 120s (manifest timeoutSeconds), leaving 180s (>= 2x the
  # measured scheduling stall) of platform headroom. Within 120s the enumeration
  # is bounded by @default_max_objects below. Overridable in tests.
  @default_cutover_timeout_ms 120_000

  # Execution-time preflight bound: more importable objects than this aborts the
  # step BEFORE any PG write (fail-closed, zero rows, no marker) — the recorded
  # approval lapses rather than the window silently stretching. 500 is ~5x the
  # expected production corpus (dozens); the rehearsal ran at 2x this bound
  # (1,005 objects) in 0.9s against local MinIO+Postgres, and even at a
  # conservative 100ms/GET production round trip, 500 objects enumerate in ~50s,
  # inside the 120s deadline with >2x margin.
  @default_max_objects 500

  defp cutover_timeout_ms,
    do:
      Application.get_env(
        :salix_store,
        :oauth_apps_cutover_timeout_ms,
        @default_cutover_timeout_ms
      )

  defp cutover_max_objects,
    do: Application.get_env(:salix_store, :oauth_apps_cutover_max_objects, @default_max_objects)

  @spec run() :: :ok | {:error, term()}
  # EVERYTHING `run/0` does — the three-state marker read, the S3 enumeration,
  # the preflight bound, and the PG transaction — runs inside one task under one
  # monotonic deadline; the only work outside it is reading the budget from app
  # env. A yield kills the task when the budget expires, so no phase (not even a
  # lock-blocked marker SELECT) can stretch the writers=0 window past the
  # declared budget: a kill before the transaction has written nothing, and a
  # killed transaction rolls back to zero rows and no marker.
  def run do
    budget_ms = cutover_timeout_ms()
    task = Task.async(fn -> guarded_run(budget_ms) end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:cutover_crashed, reason}}
      nil -> {:error, {:budget_exceeded, budget_ms}}
    end
  end

  defp guarded_run(budget_ms) do
    started = System.monotonic_time(:millisecond)

    case marker_status() do
      :present ->
        :ok

      :absent ->
        enumerate_then_import(budget_ms, started)

      {:error, reason} ->
        {:error, {:marker_unreadable, reason}}
    end
  rescue
    exception -> {:error, {:cutover_exception, exception}}
  end

  defp enumerate_then_import(budget_ms, started) do
    # Enumerate + validate S3 OUTSIDE the transaction (reads only, fail-closed,
    # no PG writes). Then do every PG write — imports, equality gate, and the
    # marker insert — in ONE transaction, so a marker-insert (or equality)
    # failure rolls back the just-imported secret-bearing rows: the corpus is
    # never left half-imported with no marker. The transaction and each of its
    # statements get only the budget REMAINING after the marker read and
    # enumeration.
    with {:ok, scoped} <- enumerate_provider_apps(),
         :ok <- check_preflight_bound(scoped) do
      remaining_ms = max(budget_ms - (System.monotonic_time(:millisecond) - started), 1)

      case Repo.transaction(fn -> import_verify_mark(scoped, remaining_ms) end,
             timeout: remaining_ms
           ) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Execution-time enforcement of the recorded preflight bound: exceeding it
  # aborts before any PG write — the approval lapses, the window never
  # silently stretches.
  defp check_preflight_bound(scoped) do
    bound = cutover_max_objects()
    count = length(scoped)

    if count > bound,
      do: {:error, {:preflight_bound_exceeded, count, bound}},
      else: :ok
  end

  defp import_verify_mark(scoped, timeout_ms) do
    with :ok <- import_provider_apps(scoped, timeout_ms),
         {:ok, evidence} <- verify_equality_sets(scoped, timeout_ms),
         :ok <- mark!(evidence, timeout_ms) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Strict S3↔PG set equality without writing anything (re-enumerates S3).
  Used by external callers; `run/0` uses the pre-enumerated variant inside its
  transaction.
  """
  @spec verify_equality() :: {:ok, map()} | {:error, term()}
  def verify_equality do
    with {:ok, scoped} <- enumerate_provider_apps() do
      verify_equality_sets(scoped, cutover_timeout_ms())
    end
  end

  defp verify_equality_sets(scoped, timeout_ms) do
    s3 = provider_set(scoped)
    pg = provider_set(OAuthProviderApps.all_scoped_records(timeout: timeout_ms))

    if MapSet.equal?(s3, pg),
      do: {:ok, %{"provider_apps" => MapSet.size(s3)}},
      else: {:error, {:mismatch, :provider_apps}}
  end

  @doc "Fail-closed importable count (pre-cutover preflight)."
  @spec importable_count() :: {:ok, map()} | {:error, term()}
  def importable_count do
    with {:ok, scoped} <- enumerate_provider_apps() do
      {:ok, %{"provider_apps" => length(scoped)}}
    end
  end

  @doc "True once the cutover marker exists; false when absent or unreadable."
  @spec marker_present?() :: boolean()
  def marker_present?, do: marker_status() == :present

  @doc """
  Three-state marker read: `:present`, `:absent`, or `{:error, reason}` when the
  marker table is unreadable. The audit uses this to fail non-zero on a fault
  rather than folding it into `:absent` (which would silently report a
  pre-cutover preflight against an unreachable database).
  """
  @spec marker_status() :: :present | :absent | {:error, term()}
  def marker_status do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker_name]) do
      {:ok, %{rows: [[1]]}} -> :present
      {:ok, %{rows: []}} -> :absent
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp provider_set(scoped) do
    MapSet.new(scoped, fn {scope, rec} -> {scope, OAuthProviderApps.canonical(rec)} end)
  end

  defp import_provider_apps(scoped, timeout_ms) do
    reduce_ok(scoped, fn {scope, rec} ->
      case OAuthProviderApps.import_record(scope, rec, timeout: timeout_ms) do
        :ok -> :ok
        {:error, reason} -> {:error, {:provider_app_import_failed, reason}}
      end
    end)
  end

  # --- provider_apps: per-tenant prefix (scope = tenant) + the flat defaults ---

  defp enumerate_provider_apps do
    with {:ok, tenants} <- enumerate_tenant_provider_apps(),
         {:ok, defaults} <- enumerate_default_apps() do
      {:ok, tenants ++ defaults}
    end
  end

  defp enumerate_tenant_provider_apps do
    Keys.ctl_oauth_provider_apps_root()
    |> enumerate_prefix(fn key, rec ->
      # key = ctl/oauth/provider_apps/{tenant}/{provider}.json
      with {:ok, tenant_id, provider} <- parse_provider_app_key(key),
           :ok <- check_provider_app_body(rec, tenant_id, provider) do
        {:ok, {tenant_id, provider_record(provider, rec)}}
      end
    end)
  end

  defp enumerate_default_apps do
    Keys.ctl_oauth_default_apps_prefix()
    |> enumerate_prefix(fn key, rec ->
      # key = ctl/oauth/default_apps/{provider}.json
      with {:ok, provider} <- parse_default_app_key(key),
           :ok <- check_provider_app_body(rec, nil, provider) do
        {:ok, {OAuthProviderApps.default_scope(), provider_record(provider, rec)}}
      end
    end)
  end

  # A provider_apps body must round-trip to its physical key and carry only
  # materializable typed fields.
  defp check_provider_app_body(rec, tenant_id, provider) do
    cond do
      tenant_id != nil and rec["tenant_id"] not in [nil, tenant_id] ->
        {:error, :record_address_mismatch}

      rec["provider"] not in [nil, provider] ->
        {:error, :record_address_mismatch}

      not optional_string?(rec["client_id"]) ->
        {:error, :invalid_record}

      not optional_string?(rec["client_secret"]) ->
        {:error, :invalid_record}

      not valid_updated_at?(rec["updated_at"]) ->
        {:error, :invalid_record}

      true ->
        :ok
    end
  end

  defp provider_record(provider, rec) do
    %{
      "provider" => provider,
      "client_id" => rec["client_id"],
      "client_secret" => rec["client_secret"],
      "updated_at" => rec["updated_at"]
    }
  end

  # --- shared enumeration + validation helpers ---

  # Fail-closed prefix walk: full pagination, every object fetched, decoded, and
  # validated by `check`; any error aborts the whole enumeration.
  defp enumerate_prefix(prefix, check) do
    with {:ok, objects} <- S3.list_all(prefix) do
      objects
      |> Enum.reduce_while({:ok, []}, fn %{key: key}, {:ok, acc} ->
        with {:ok, rec} <- read_json(key),
             {:ok, value} <- check.(key, rec) do
          {:cont, {:ok, [value | acc]}}
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

  # ctl/oauth/provider_apps/{tenant}/{provider}.json → {tenant, provider}. The
  # parsed pair must rebuild the EXACT canonical key, so a non-canonical object
  # (no `.json` suffix, a `.bak` variant, a trailing slash) fails closed rather
  # than being imported as an active credential under a derived identity.
  defp parse_provider_app_key(key) do
    middle =
      key
      |> String.replace_prefix("ctl/oauth/provider_apps/", "")
      |> String.replace_suffix(@suffix, "")

    with [tenant_id, provider] <- String.split(middle, "/"),
         true <- tenant_id != "" and provider != "",
         # The tenant segment becomes the PG scope, and the deployment default
         # occupies a reserved scope value in that same column. A tenant segment
         # equal to the reserved scope would import a per-tenant object AS the
         # deployment-wide default app (every other tenant would then fall back
         # to its credentials). Real tenant ids are generated and never take
         # this literal, so this is unreachable through the write path — fail
         # closed anyway rather than resolve the collision silently.
         true <- tenant_id != OAuthProviderApps.default_scope(),
         ^key <- Keys.ctl_oauth_provider_app(tenant_id, provider) do
      {:ok, tenant_id, provider}
    else
      _ -> {:error, :record_address_mismatch}
    end
  end

  # ctl/oauth/default_apps/{provider}.json → provider, with the same canonical
  # round-trip requirement.
  defp parse_default_app_key(key) do
    provider =
      key
      |> String.replace_prefix("ctl/oauth/default_apps/", "")
      |> String.replace_suffix(@suffix, "")

    if provider != "" and not String.contains?(provider, "/") and
         key == Keys.ctl_oauth_default_app(provider) do
      {:ok, provider}
    else
      {:error, :record_address_mismatch}
    end
  end

  # Require a JSON object: a top-level array/scalar body fails closed here, before
  # any caller accesses `rec["field"]` (Access on a non-map raises).
  defp read_json(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_record}
    end
  end

  # from_record feeds these into :string columns; a non-string JSON value raises
  # Ecto.ChangeError at insert. nil is fine (from_record substitutes a default).
  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  # updated_at is multiplied by 1_000_000 and converted with DateTime.from_unix!:
  # a non-integer or out-of-range value raises mid-import.
  defp valid_updated_at?(value),
    do: is_integer(value) and value >= 0 and value <= @max_epoch_seconds

  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp mark!(evidence, timeout_ms) when is_map(evidence) do
    now = DateTime.utc_now()

    case Repo.query(
           "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, $2, $3) ON CONFLICT (name) DO NOTHING",
           [@marker_name, now, evidence],
           timeout: timeout_ms
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:marker_write_failed, reason}}
    end
  end
end
