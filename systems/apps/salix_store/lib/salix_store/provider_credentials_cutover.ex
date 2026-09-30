defmodule SalixStore.ProviderCredentialsCutover do
  @moduledoc """
  The provider-credentials authority cutover (docs/storage-search.md).

  Moves two credential classes from S3 to Postgres in one exclusive stage:
  Composio settings (`ctl/composio/tenants/*` + the single `ctl/composio/default.json`)
  and Feishu bot apps (`ctl/feishu/tenant_apps/*`). It imports both corpora,
  verifies strict per-class set equality, and persists a single terminal marker
  `provider_credentials_v1`.

  Same contract as `SalixStore.TenantApiKeyCutover`: `run/0` consults the
  three-state `marker_status/0` directly (present → no-op, absent → import,
  unreadable → abort, never re-import over PG-only deletes). Enumeration is
  fail-closed end to end; a record whose body does not round-trip to its
  physical key aborts the cutover rather than importing under a different
  identity. Readiness (`SalixStore.ProviderCredentialsReadiness` via
  `Comma.PodLifecycle.ready(:salix)`) keeps a pod out of service until the marker
  exists; the OAuth app credentials migrate later under their own marker.
  """

  alias SalixStore.{ComposioSettings, FeishuTenantApps, Keys, Repo, S3}

  @marker_name "provider_credentials_v1"

  # Largest epoch-seconds value `DateTime.from_unix!(x * 1_000_000, :microsecond)`
  # accepts (9999-12-31T23:59:59Z). from_record multiplies updated_at by 1_000_000
  # and builds a microsecond DateTime, so a larger value — e.g. a millisecond-
  # magnitude corrupt timestamp — raises ArgumentError mid-import. Bounding both
  # ends here keeps enumeration fail-closed before any PG write.
  @max_epoch_seconds 253_402_300_799

  @spec run() :: :ok | {:error, term()}
  def run do
    case marker_status() do
      :present ->
        :ok

      :absent ->
        with {:ok, composio} <- enumerate_composio(),
             {:ok, feishu} <- enumerate_feishu(),
             :ok <- import_composio(composio),
             :ok <- import_feishu(feishu),
             {:ok, evidence} <- verify_equality(),
             :ok <- mark!(evidence) do
          :ok
        end

      {:error, reason} ->
        {:error, {:marker_unreadable, reason}}
    end
  end

  @doc "Strict per-class S3↔PG set equality without writing anything."
  @spec verify_equality() :: {:ok, map()} | {:error, term()}
  def verify_equality do
    with {:ok, composio} <- enumerate_composio(),
         {:ok, feishu} <- enumerate_feishu() do
      composio_s3 = composio_set(composio)
      composio_pg = composio_set(ComposioSettings.all_scoped_records())
      feishu_s3 = feishu_set(feishu)
      feishu_pg = feishu_set(FeishuTenantApps.all_records())

      cond do
        not MapSet.equal?(composio_s3, composio_pg) ->
          {:error, {:mismatch, :composio}}

        not MapSet.equal?(feishu_s3, feishu_pg) ->
          {:error, {:mismatch, :feishu}}

        true ->
          {:ok,
           %{
             "composio_records" => MapSet.size(composio_s3),
             "feishu_records" => MapSet.size(feishu_s3)
           }}
      end
    end
  end

  @doc "Fail-closed importable counts per class (pre-cutover preflight)."
  @spec importable_count() :: {:ok, map()} | {:error, term()}
  def importable_count do
    with {:ok, composio} <- enumerate_composio(),
         {:ok, feishu} <- enumerate_feishu() do
      {:ok, %{"composio" => length(composio), "feishu" => length(feishu)}}
    end
  end

  @doc "True once the cutover marker exists; false when absent or unreadable."
  @spec marker_present?() :: boolean()
  def marker_present?, do: marker_status() == :present

  defp composio_set(scoped) do
    MapSet.new(scoped, fn {scope, rec} -> {scope, ComposioSettings.canonical(rec)} end)
  end

  defp feishu_set(records), do: MapSet.new(records, &FeishuTenantApps.canonical/1)

  defp import_composio(scoped) do
    reduce_ok(scoped, fn {scope, rec} ->
      case ComposioSettings.import_record(scope, rec) do
        :ok -> :ok
        {:error, reason} -> {:error, {:composio_import_failed, reason}}
      end
    end)
  end

  defp import_feishu(records) do
    reduce_ok(records, fn rec ->
      case FeishuTenantApps.import_record(rec) do
        :ok -> :ok
        {:error, reason} -> {:error, {:feishu_import_failed, reason}}
      end
    end)
  end

  # --- Composio: per-tenant prefix plus the single default object ---

  defp enumerate_composio do
    with {:ok, tenants} <- enumerate_composio_tenants(),
         {:ok, default} <- enumerate_composio_default() do
      {:ok, tenants ++ default}
    end
  end

  defp enumerate_composio_tenants do
    Keys.ctl_composio_tenants_prefix()
    |> enumerate_prefix(fn key, rec ->
      scope =
        String.replace_suffix(
          String.replace_prefix(key, "ctl/composio/tenants/", ""),
          ".json",
          ""
        )

      cond do
        key != Keys.ctl_composio_settings(scope) -> {:error, :record_address_mismatch}
        rec["tenant_id"] not in [nil, scope] -> {:error, :record_address_mismatch}
        not is_binary(rec["api_key"]) -> {:error, :invalid_record}
        not optional_string?(rec["base_url"]) -> {:error, :invalid_record}
        not valid_updated_at?(rec["updated_at"]) -> {:error, :invalid_record}
        true -> {:ok, {scope, rec}}
      end
    end)
  end

  defp enumerate_composio_default do
    key = Keys.ctl_composio_default_settings()

    case read_json(key) do
      {:ok, rec} when is_map(rec) ->
        cond do
          not is_binary(rec["api_key"]) ->
            {:error, {:enumerate_failed, key, :invalid_record}}

          not optional_string?(rec["base_url"]) ->
            {:error, {:enumerate_failed, key, :invalid_record}}

          not valid_updated_at?(rec["updated_at"]) ->
            {:error, {:enumerate_failed, key, :invalid_record}}

          true ->
            {:ok, [{ComposioSettings.default_scope(), rec}]}
        end

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:enumerate_failed, key, reason}}
    end
  end

  # --- Feishu: flat per-tenant prefix ---

  defp enumerate_feishu do
    Keys.ctl_feishu_tenant_apps_prefix()
    |> enumerate_prefix(fn key, rec ->
      tenant_id = rec["tenant_id"]

      cond do
        not is_binary(tenant_id) ->
          {:error, :invalid_record}

        key != Keys.ctl_feishu_tenant_app(tenant_id) ->
          {:error, :record_address_mismatch}

        not Enum.all?(
          ~w(app_id app_secret verification_token encrypt_key),
          &optional_string?(rec[&1])
        ) ->
          {:error, :invalid_record}

        not valid_updated_at?(rec["updated_at"]) ->
          {:error, :invalid_record}

        true ->
          {:ok, rec}
      end
    end)
  end

  # `ComposioSettings.from_record/2` and `FeishuTenantApps.from_record/1` treat
  # `updated_at` as epoch seconds and convert it with DateTime.from_unix!/2; a
  # non-integer (ISO-8601 string → ArithmeticError) or an out-of-range integer
  # (millisecond-magnitude value → ArgumentError) would raise mid-import. Require
  # an integer within the representable range so both the audit preflight
  # (importable_count/0) and run/0 fail closed during enumeration — before any PG
  # write or marker — instead of a partial import + crash in the ceremony.
  defp valid_updated_at?(value),
    do: is_integer(value) and value >= 0 and value <= @max_epoch_seconds

  # from_record feeds these into :string Ecto columns; a non-string JSON value
  # (int/list/map/bool) would raise Ecto.ChangeError at Repo.insert. nil is fine
  # (from_record substitutes ""). Validate here so the crash never reaches import.
  defp optional_string?(value), do: is_nil(value) or is_binary(value)

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

  # Require a JSON object: a top-level array/scalar body must fail closed here,
  # before any caller accesses `rec["field"]` (Access on a non-map raises).
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
