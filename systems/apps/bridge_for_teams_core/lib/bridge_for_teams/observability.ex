defmodule BridgeForTeams.Observability do
  @moduledoc """
  Org-scoped Operations read model.

  This context owns the redaction and tenant-isolation checks for BFT
  observability rows. Source systems remain authoritative; Operations stores
  only redacted facts, bounded run metadata, check snapshots, and audit records.

  `create_operation_run_once/1` is the durable claim authority modeled by
  `tla/salix/MeetingSummaryReplay.tla`.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.Repo
  alias BridgeForTeams.RunChecks.GateContract

  alias BridgeForTeams.Schema.{
    AuditLog,
    CheckResult,
    MacMiniProvisioner,
    ObservabilityEvent,
    OperationRun,
    Project
  }

  @default_limit 50
  @default_payload_max_bytes 16_384
  @default_event_rate_limit_policy %{
    enabled: true,
    window_seconds: 60,
    max_events_per_source: 1_000,
    source_limits: %{}
  }
  @stderr_tail_max_chars 4_000
  @default_retention_policy %{
    observability_events_days: 60,
    operation_runs_days: 180,
    stderr_tail_days: 14,
    check_results_days: 365,
    audit_logs_days: 2_555,
    pruning: :manual
  }
  @default_freshness_policy %{
    event_history_seconds: 86_400,
    operation_run_history_seconds: 86_400,
    check_result_history_seconds: 86_400,
    integration_check_freshness_seconds: 86_400,
    runner_heartbeat_warning_seconds: 45,
    runner_heartbeat_stale_seconds: 300,
    audit_recent_action_seconds: 86_400
  }
  @runner_types ~w(mac_mini_provisioner)
  @health_classes [:critical, :action_required, :degraded, :healthy]
  @health_class_values %{
    runner_status: %{
      critical: ~w(critical),
      action_required: ~w(offline failed error),
      degraded: ~w(recently_lost stale unknown),
      healthy: ~w(online ok active)
    },
    event_severity: %{
      critical: ~w(critical),
      action_required: ~w(error),
      degraded: [],
      healthy: ~w(debug info notice warning)
    },
    run_status: %{
      critical: ~w(critical),
      action_required: ~w(failed canceled),
      degraded: ~w(needs_manual skipped),
      healthy: ~w(ok)
    },
    check_status: %{
      critical: ~w(critical),
      action_required: ~w(fail),
      degraded: ~w(needs_manual skipped),
      healthy: ~w(ok)
    }
  }
  @ingestion_log_keys ~w(org_id domain source event_type run_type check_family surface action resource_type result reason_class)

  @doc "Create a redacted org-scoped Operations event."
  @spec create_event(map()) :: {:ok, ObservabilityEvent.t()} | {:error, term()}
  def create_event(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("severity", "info")
      |> Map.put_new("occurred_at", DateTime.utc_now())
      |> redact_summary()
      |> put_sized_payload("evidence", "evidence_size_bytes")

    result =
      with :ok <- validate_common_scope(attrs),
           :ok <- validate_event_scope(attrs),
           :ok <- validate_event_rate_limit(attrs) do
        %ObservabilityEvent{}
        |> ObservabilityEvent.changeset(attrs)
        |> insert_observability_event(attrs)
      end

    maybe_log_ingestion_drop(result, "event", attrs)
  end

  @doc "List recent Operations events inside one org."
  @spec list_events(Ecto.UUID.t(), keyword()) :: [ObservabilityEvent.t()]
  def list_events(org_id, opts \\ []) do
    org_id
    |> page_events(opts)
    |> Map.fetch!(:entries)
  end

  @doc "Cursor-page Operations events inside one org."
  @spec page_events(Ecto.UUID.t(), keyword()) :: %{
          entries: [ObservabilityEvent.t()],
          next_cursor: String.t() | nil
        }
  def page_events(org_id, opts \\ []) do
    ObservabilityEvent
    |> where([e], e.org_id == ^org_id)
    |> maybe_filter(:domain, opts[:domain])
    |> maybe_filter_not(:domain, opts[:exclude_domain])
    |> maybe_filter(:severity, opts[:severity])
    |> maybe_filter(:source, opts[:source])
    |> maybe_filter(:event_type, opts[:event_type])
    |> maybe_filter(:status, opts[:status])
    |> maybe_filter(:reason_class, opts[:reason_class])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:runner_type, opts[:runner_type])
    |> maybe_filter(:runner_id, opts[:runner_id])
    |> maybe_filter(:run_record_id, opts[:run_record_id])
    |> maybe_filter(:check_result_id, opts[:check_result_id])
    |> maybe_filter(:audit_log_id, opts[:audit_log_id])
    |> maybe_filter(:resource_type, opts[:resource_type])
    |> maybe_filter(:resource_id, opts[:resource_id])
    |> maybe_filter(:correlation_id, opts[:correlation_id])
    |> maybe_since(:occurred_at, opts[:since])
    |> page_by(:occurred_at, opts)
  end

  @doc "Create a redacted bounded execution run row."
  @spec create_operation_run(map()) :: {:ok, OperationRun.t()} | {:error, term()}
  def create_operation_run(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "unknown")
      |> put_sized_payload("evidence", "evidence_size_bytes")
      |> redact_stderr_tail()

    result =
      with :ok <- validate_common_scope(attrs) do
        insert_operation_run(attrs)
      end

    maybe_log_ingestion_drop(result, "operation_run", attrs)
  end

  @doc "Create one execution run without replacing an existing external run id."
  @spec create_operation_run_once(map()) ::
          {:ok, OperationRun.t()} | {:error, :already_exists | term()}
  def create_operation_run_once(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("status", "unknown")
      |> put_sized_payload("evidence", "evidence_size_bytes")
      |> redact_stderr_tail()

    result =
      with :ok <- validate_common_scope(attrs) do
        insert_operation_run_once(attrs)
      end

    case result do
      {:error, :already_exists} -> result
      _other -> maybe_log_ingestion_drop(result, "operation_run", attrs)
    end
  end

  @doc "Update a bounded execution run row, preserving redaction rules."
  @spec update_operation_run(OperationRun.t(), map()) ::
          {:ok, OperationRun.t()} | {:error, term()}
  def update_operation_run(%OperationRun{} = run, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> maybe_put_sized_payload("evidence", "evidence_size_bytes")
      |> redact_stderr_tail()

    with :ok <- validate_common_scope(Map.put(attrs, "org_id", run.org_id)) do
      run
      |> OperationRun.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc "List recent bounded execution runs inside one org."
  @spec list_operation_runs(Ecto.UUID.t(), keyword()) :: [OperationRun.t()]
  def list_operation_runs(org_id, opts \\ []) do
    org_id
    |> page_operation_runs(opts)
    |> Map.fetch!(:entries)
  end

  @doc "Cursor-page bounded execution runs inside one org."
  @spec page_operation_runs(Ecto.UUID.t(), keyword()) :: %{
          entries: [OperationRun.t()],
          next_cursor: String.t() | nil
        }
  def page_operation_runs(org_id, opts \\ []) do
    OperationRun
    |> where([r], r.org_id == ^org_id)
    |> maybe_filter(:id, opts[:run_record_id])
    |> maybe_filter(:run_type, opts[:run_type])
    |> maybe_filter(:status, opts[:status])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:runner_type, opts[:runner_type])
    |> maybe_filter(:runner_id, opts[:runner_id])
    |> maybe_filter(:external_run_id, opts[:external_run_id])
    |> maybe_filter(:request_id, opts[:request_id])
    |> maybe_since(:created_at, opts[:since])
    |> page_by(:created_at, opts)
  end

  @doc """
  Persist a check result snapshot.

  If `invocation_id` is supplied, retries are idempotent and return the existing
  row for the same org/invocation pair.
  """
  @spec create_check_result(map()) :: {:ok, CheckResult.t()} | {:error, term()}
  def create_check_result(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("check_family", "run_checks")
      |> Map.put_new("ran_at", DateTime.utc_now())
      |> maybe_normalize_run_checks()
      |> maybe_derive_check_status()
      |> put_sized_check_result()

    result =
      with :ok <- validate_common_scope(attrs) do
        changeset = CheckResult.changeset(%CheckResult{}, attrs)

        case Repo.insert(changeset) do
          {:ok, result} ->
            {:ok, result}

          {:error, changeset} = error ->
            case existing_check_result(attrs, changeset) do
              nil -> error
              result -> {:ok, result}
            end
        end
      end

    maybe_log_ingestion_drop(result, "check_result", attrs)
  end

  @doc "Persist the shared Run checks contract shape."
  @spec record_run_checks(map(), keyword()) :: {:ok, CheckResult.t()} | {:error, term()}
  def record_run_checks(%{} = result, opts \\ []) do
    result = GateContract.normalize_result(result)
    org_id = result["org_ref"] || Keyword.get(opts, :org_id)
    project_id = result["project_ref"] || Keyword.get(opts, :project_id)
    surface = result["surface"] || Keyword.get(opts, :surface, "unknown")
    subject_type = Keyword.get(opts, :subject_type, default_subject_type(surface))
    subject_id = Keyword.get(opts, :subject_id, default_subject_id(surface, org_id, project_id))

    create_check_result(%{
      "org_id" => org_id,
      "project_id" => project_id,
      "check_family" => "run_checks",
      "surface" => surface,
      "subject_type" => subject_type,
      "subject_id" => subject_id,
      "status" => GateContract.aggregate_status(result["gates"] || []),
      "reason_class" => GateContract.aggregate_reason(result["gates"] || []),
      "result" => result,
      "ran_by_user_id" => Keyword.get(opts, :ran_by_user_id),
      "invocation_id" => Keyword.get(opts, :invocation_id),
      "ran_at" => result["ran_at"] || Keyword.get(opts, :ran_at) || DateTime.utc_now()
    })
  end

  @doc """
  Persist a dashboard-triggered Run checks result and its visibility trail.

  This writes the check snapshot, a linked operational event, and an audit row
  in one transaction so the Operations UI can show both current posture and who
  initiated the verification.
  """
  @spec record_run_checks_activity(map(), keyword()) :: {:ok, CheckResult.t()} | {:error, term()}
  def record_run_checks_activity(%{} = result, opts \\ []) do
    result = GateContract.normalize_result(result)
    request_id = Keyword.get(opts, :request_id) || Ecto.UUID.generate()
    ran_by_user_id = Keyword.get(opts, :ran_by_user_id)
    org_id = result["org_ref"] || Keyword.get(opts, :org_id)
    project_id = result["project_ref"] || Keyword.get(opts, :project_id)
    surface = result["surface"] || Keyword.get(opts, :surface, "unknown")

    Repo.transaction(fn ->
      with {:ok, %CheckResult{} = check} <-
             record_run_checks(result,
               org_id: org_id,
               project_id: project_id,
               ran_by_user_id: ran_by_user_id,
               invocation_id: Keyword.get(opts, :invocation_id, request_id),
               ran_at: result["ran_at"] || Keyword.get(opts, :ran_at)
             ),
           {:ok, _event} <-
             create_event(%{
               org_id: org_id,
               project_id: project_id,
               check_result_id: check.id,
               actor_user_id: ran_by_user_id,
               domain: "check",
               resource_type: "run_checks",
               resource_id: check.id,
               source: "bft.dashboard",
               event_type: "run_checks.completed",
               severity: check_status_severity(check.status),
               status: check.status,
               reason_class: check.reason_class,
               summary: run_checks_summary(surface, check.status),
               evidence: run_checks_activity_evidence(result, check),
               correlation_id: request_id,
               occurred_at: check.ran_at
             }),
           {:ok, _audit} <-
             record_audit(%{
               org_id: org_id,
               actor_user_id: ran_by_user_id,
               action: "run_checks.ran",
               resource_type: "check_result",
               resource_id: check.id,
               resource_label: "Run checks: #{surface}",
               result: audit_result(check.status),
               reason_class: check.reason_class,
               request_id: request_id,
               metadata: run_checks_activity_evidence(result, check)
             }) do
        check
      else
        {:error, reason} -> Repo.rollback(reason)
        reason -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Record a redacted settings/integration validation fact.

  This is intentionally lighter than a full Run checks invocation: save-time
  validators can use it to tell Operations whether SSO, OAuth, Feishu, or model
  configuration was accepted or rejected without storing submitted credentials
  or provider payloads.
  """
  @spec record_validation_event(map()) :: {:ok, ObservabilityEvent.t()} | {:error, term()}
  def record_validation_event(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    surface = validation_surface(attrs["surface"])
    status = validation_status(attrs["status"])
    reason_class = attrs["reason_class"]

    create_event(%{
      org_id: attrs["org_id"],
      project_id: attrs["project_id"],
      actor_user_id: attrs["actor_user_id"],
      domain: "integration",
      resource_type: attrs["resource_type"] || validation_resource_type(surface),
      resource_id: attrs["resource_id"],
      source: attrs["source"] || "bft.write_path",
      event_type: "#{validation_event_prefix(surface)}.validation.#{validation_outcome(status)}",
      severity: validation_severity(status),
      status: status,
      reason_class: reason_class,
      summary:
        attrs["summary"] ||
          validation_summary(surface, attrs["resource_label"], status, reason_class),
      evidence: validation_evidence(attrs, surface, status, reason_class),
      correlation_id: attrs["correlation_id"],
      occurred_at: attrs["occurred_at"] || DateTime.utc_now()
    })
  end

  @doc "List recent check result snapshots inside one org."
  @spec list_check_results(Ecto.UUID.t(), keyword()) :: [CheckResult.t()]
  def list_check_results(org_id, opts \\ []) do
    org_id
    |> page_check_results(opts)
    |> Map.fetch!(:entries)
  end

  @doc "Cursor-page check result snapshots inside one org."
  @spec page_check_results(Ecto.UUID.t(), keyword()) :: %{
          entries: [CheckResult.t()],
          next_cursor: String.t() | nil
        }
  def page_check_results(org_id, opts \\ []) do
    CheckResult
    |> where([c], c.org_id == ^org_id)
    |> maybe_filter(:id, opts[:check_result_id])
    |> maybe_filter(:check_family, opts[:check_family])
    |> maybe_filter(:surface, opts[:surface])
    |> maybe_filter(:status, opts[:status])
    |> maybe_filter_gate_status(opts[:gate_status])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:subject_type, opts[:subject_type])
    |> maybe_filter(:subject_id, opts[:subject_id])
    |> maybe_since(:ran_at, opts[:since])
    |> page_by(:ran_at, opts)
  end

  @doc "Create an expanded audit log row with legacy target compatibility."
  @spec record_audit(map()) :: {:ok, AuditLog.t()} | {:error, Ecto.Changeset.t()}
  def record_audit(attrs) when is_map(attrs) do
    attrs = prepare_audit(attrs)

    result =
      case %AuditLog{} |> AuditLog.changeset(attrs) |> Repo.insert() do
        {:ok, %AuditLog{} = audit} ->
          maybe_record_audit_event(audit)
          {:ok, audit}

        {:error, changeset} ->
          {:error, changeset}
      end

    maybe_log_ingestion_drop(result, "audit", attrs)
  end

  @doc """
  Create several audit rows in one transaction: either every row is stored or
  none is. Their event projections follow in a second transaction and stay
  best-effort, as in `record_audit/1`. One commit per batch instead of two per
  row keeps a page of audited reveals off the request path.
  """
  @spec record_audits([map()]) :: {:ok, [AuditLog.t()]} | {:error, term()}
  def record_audits([]), do: {:ok, []}

  def record_audits(attrs_list) when is_list(attrs_list) do
    changesets =
      Enum.map(attrs_list, &(%AuditLog{} |> AuditLog.changeset(prepare_audit(&1))))

    result =
      case Enum.find(changesets, &(not &1.valid?)) do
        nil -> Repo.transaction(fn -> Enum.map(changesets, &Repo.insert!/1) end)
        invalid -> {:error, invalid}
      end

    case result do
      {:ok, audits} ->
        record_audit_events(audits)
        {:ok, audits}

      {:error, reason} = error ->
        maybe_log_ingestion_drop(error, "audit", hd(attrs_list))
        {:error, reason}
    end
  rescue
    exception -> maybe_log_ingestion_drop({:error, exception}, "audit", hd(attrs_list))
  end

  defp record_audit_events(audits) do
    Repo.transaction(fn -> Enum.each(audits, &maybe_record_audit_event/1) end)
  rescue
    exception ->
      Logger.warning(
        "audit_event_projection_failed audit_log_count=#{length(audits)} reason=#{inspect(exception.__struct__)}"
      )
  end

  defp prepare_audit(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put_new("actor_type", actor_type(attrs))
    |> Map.put_new("resource_type", legacy_resource_type(attrs))
    |> Map.put_new("resource_id", legacy_resource_id(attrs))
    |> Map.put_new("resource_label", legacy_resource_label(attrs))
    |> Map.put_new("result", "ok")
    |> put_sized_payload("metadata", "metadata_size_bytes")
    |> put_bounded_redacted_payload("redacted_diff")
  end

  @doc """
  Record a failed or denied BFT write attempt without mutating the target.

  Callers should use this for authorization failures, validation failures, or
  degraded save paths that need the same audit contract as successful writes.
  """
  @spec record_write_attempt(map()) :: {:ok, AuditLog.t()} | {:error, Ecto.Changeset.t()}
  def record_write_attempt(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    reason = Map.get(attrs, "reason", attrs["reason_class"])
    result = write_attempt_result(attrs["result"])
    reason_class = attrs["reason_class"] || write_attempt_reason_class(reason)

    attrs
    |> Map.drop(["reason", "surface"])
    |> Map.put("result", result)
    |> Map.put("reason_class", reason_class)
    |> Map.put("metadata", write_attempt_metadata(attrs, result, reason_class, reason))
    |> record_audit()
  end

  @doc "List recent audit logs inside one org."
  @spec list_audit_logs(Ecto.UUID.t(), keyword()) :: [AuditLog.t()]
  def list_audit_logs(org_id, opts \\ []) do
    org_id
    |> page_audit_logs(opts)
    |> Map.fetch!(:entries)
  end

  @doc "Cursor-page audit logs inside one org."
  @spec page_audit_logs(Ecto.UUID.t(), keyword()) :: %{
          entries: [AuditLog.t()],
          next_cursor: String.t() | nil
        }
  def page_audit_logs(org_id, opts \\ []) do
    AuditLog
    |> where([a], a.org_id == ^org_id)
    |> maybe_filter(:id, opts[:audit_log_id])
    |> maybe_filter(:actor_user_id, opts[:actor_user_id])
    |> maybe_filter(:action, opts[:action])
    |> maybe_filter(:resource_type, opts[:resource_type])
    |> maybe_filter(:resource_id, opts[:resource_id])
    |> maybe_filter(:result, opts[:result])
    |> maybe_filter(:request_id, opts[:request_id])
    |> maybe_since(:created_at, opts[:since])
    |> page_by(:created_at, opts)
  end

  @doc """
  Backfill legacy audit `target` rows into the expanded audit contract.

  Early audit rows only had `target`, usually in the `resource_type:id` shape.
  This keeps the legacy column, preserves the exact value in
  `metadata.legacy_target`, and only fills missing/legacy expanded fields.
  """
  @spec backfill_legacy_audit_logs() :: {:ok, non_neg_integer()}
  def backfill_legacy_audit_logs do
    %{num_rows: count} = Repo.query!(legacy_audit_backfill_sql())
    {:ok, count}
  end

  defp maybe_record_audit_event(%AuditLog{org_id: org_id} = audit)
       when is_binary(org_id) and org_id != "" do
    case create_event(audit_event_attrs(audit)) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "audit_event_projection_failed audit_log_id=#{audit.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_record_audit_event(_audit), do: :ok

  defp audit_event_attrs(%AuditLog{} = audit) do
    %{
      org_id: audit.org_id,
      audit_log_id: audit.id,
      actor_user_id: audit.actor_user_id,
      domain: "audit",
      resource_type: audit.resource_type || "legacy",
      resource_id: audit.resource_id,
      source: "bft.write_path",
      event_type: audit_event_type(audit.action),
      severity: audit_event_severity(audit.result),
      status: audit.result,
      reason_class: audit.reason_class,
      summary: audit_event_summary(audit),
      evidence: audit_event_evidence(audit),
      correlation_id: audit.request_id || "audit:#{audit.id}",
      occurred_at: audit.created_at || DateTime.utc_now()
    }
  end

  defp audit_event_type(action) when is_binary(action) and action != "",
    do: "audit.#{action}"

  defp audit_event_type(_action), do: "audit.unknown"

  defp audit_event_severity("failed"), do: "error"
  defp audit_event_severity("denied"), do: "warning"
  defp audit_event_severity("unknown"), do: "warning"
  defp audit_event_severity(_result), do: "info"

  defp audit_event_summary(%AuditLog{} = audit) do
    label =
      audit.resource_label ||
        audit.resource_id ||
        audit.target ||
        audit.resource_type ||
        "resource"

    "Audit #{audit.action || "unknown"} #{audit.result || "unknown"} for #{label}"
  end

  defp audit_event_evidence(%AuditLog{} = audit) do
    %{
      audit_log_id: audit.id,
      action: audit.action,
      result: audit.result,
      request_id: audit.request_id,
      resource_type: audit.resource_type,
      resource_id: audit.resource_id,
      resource_label: audit.resource_label,
      actor_type: audit.actor_type,
      impersonated: not is_nil(audit.impersonator_user_id),
      metadata_present: map_size(audit.metadata || %{}) > 0,
      redacted_diff_present: map_size(audit.redacted_diff || %{}) > 0
    }
    |> compact_metadata()
  end

  defp write_attempt_metadata(attrs, result, reason_class, reason) do
    metadata =
      case normalize_payload(attrs["metadata"] || %{}) do
        %{} = metadata -> metadata
        _other -> %{}
      end

    base =
      %{
        "write_attempt" => true,
        "action" => attrs["action"],
        "result" => result,
        "reason_class" => reason_class,
        "resource_type" => attrs["resource_type"],
        "resource_id" => attrs["resource_id"],
        "surface" => attrs["surface"],
        "request_id" => attrs["request_id"]
      }
      |> Map.merge(write_attempt_reason_metadata(reason))
      |> compact_metadata()

    Map.merge(metadata, base)
  end

  defp write_attempt_result(nil), do: "failed"
  defp write_attempt_result(result) when is_atom(result), do: Atom.to_string(result)
  defp write_attempt_result(result) when is_binary(result) and result != "", do: result
  defp write_attempt_result(_result), do: "failed"

  defp write_attempt_reason_class(%Ecto.Changeset{}), do: "validation_failed"
  defp write_attempt_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp write_attempt_reason_class(reason) when is_binary(reason) and reason != "", do: reason

  defp write_attempt_reason_class({reason, _detail}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp write_attempt_reason_class({reason, _detail}) when is_binary(reason), do: reason
  defp write_attempt_reason_class(_reason), do: "unknown"

  defp write_attempt_reason_metadata(%Ecto.Changeset{} = changeset) do
    fields =
      changeset.errors
      |> Keyword.keys()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    %{"error_fields" => fields}
  end

  defp write_attempt_reason_metadata(_reason), do: %{}

  defp compact_metadata(metadata) do
    Map.reject(metadata, fn {_key, value} -> value in [nil, "", %{}, []] end)
  end

  defp maybe_log_ingestion_drop({:error, reason} = error, record_type, attrs) do
    Logger.warning(
      "bridge_for_teams.observability.ingest.dropped record_type=#{record_type} reason=#{drop_reason(reason)}#{ingestion_log_context(attrs)}#{drop_detail_context(reason)}"
    )

    error
  end

  defp maybe_log_ingestion_drop(result, _record_type, _attrs), do: result

  defp log_query_completed(query, field, entries, next_cursor, page_limit, duration_us) do
    Logger.debug(
      "bridge_for_teams.observability.query.completed record_type=#{query_record_type(query)} order_field=#{field} duration_us=#{duration_us} row_count=#{length(entries)} limit=#{page_limit} has_next=#{not is_nil(next_cursor)}"
    )
  end

  defp ingestion_log_context(attrs) do
    attrs
    |> stringify_keys()
    |> Map.take(@ingestion_log_keys)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("", fn {key, value} -> " #{key}=#{log_value(value)}" end)
  end

  defp drop_reason(%Ecto.Changeset{}), do: "changeset_invalid"
  defp drop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp drop_reason(reason) when is_binary(reason), do: log_value(reason)
  defp drop_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp drop_reason(_reason), do: "unknown"

  defp drop_detail_context({:backpressure, detail}) when is_map(detail) do
    detail
    |> Map.take(~w(limit window_seconds retry_after_ms)a)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("", fn {key, value} -> " #{key}=#{log_value(value)}" end)
  end

  defp drop_detail_context(_reason), do: ""

  defp query_record_type(%Ecto.Query{from: %{source: {_source, schema}}}) when is_atom(schema) do
    schema
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp query_record_type(_query), do: "unknown"

  defp log_value(value) when is_atom(value), do: value |> Atom.to_string() |> log_value()
  defp log_value(value) when is_integer(value), do: Integer.to_string(value)

  defp log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 128)
  end

  defp log_value(_value), do: "unknown"

  defp policy_integer(value, _default) when is_integer(value), do: value
  defp policy_integer(_value, default), do: default

  defp legacy_audit_backfill_sql do
    """
    WITH legacy_audit AS (
      SELECT
        id,
        target,
        CASE
          WHEN position(':' in target) > 0 THEN COALESCE(NULLIF(split_part(target, ':', 1), ''), 'legacy')
          ELSE COALESCE(NULLIF(target, ''), 'legacy')
        END AS parsed_resource_type,
        CASE
          WHEN position(':' in target) > 0 THEN NULLIF(substring(target from position(':' in target) + 1), '')
          ELSE NULL
        END AS parsed_resource_id,
        COALESCE(metadata, '{}'::jsonb) AS existing_metadata
      FROM audit_logs
      WHERE target IS NOT NULL AND target <> ''
    ),
    prepared AS (
      SELECT
        id,
        target,
        parsed_resource_type,
        parsed_resource_id,
        CASE
          WHEN existing_metadata ? 'legacy_target' THEN existing_metadata
          ELSE jsonb_set(existing_metadata, '{legacy_target}', to_jsonb(target), true)
        END AS backfilled_metadata
      FROM legacy_audit
    )
    UPDATE audit_logs AS a
    SET
      actor_type = CASE
        WHEN a.actor_type IS NOT NULL AND a.actor_type <> '' THEN a.actor_type
        WHEN a.actor_user_id IS NULL THEN 'system'
        ELSE 'user'
      END,
      resource_type = COALESCE(NULLIF(a.resource_type, 'legacy'), p.parsed_resource_type, 'legacy'),
      resource_id = COALESCE(NULLIF(a.resource_id, ''), p.parsed_resource_id),
      resource_label = COALESCE(NULLIF(a.resource_label, ''), p.target),
      metadata = p.backfilled_metadata,
      metadata_size_bytes = octet_length(p.backfilled_metadata::text)
    FROM prepared AS p
    WHERE a.id = p.id
      AND (
        a.actor_type IS NULL OR a.actor_type = '' OR
        a.resource_type IS NULL OR a.resource_type = 'legacy' OR
        (p.parsed_resource_id IS NOT NULL AND (a.resource_id IS NULL OR a.resource_id = '')) OR
        a.resource_label IS NULL OR a.resource_label = '' OR
        a.metadata IS NULL OR NOT (COALESCE(a.metadata, '{}'::jsonb) ? 'legacy_target') OR
        a.metadata_size_bytes IS NULL OR a.metadata_size_bytes = 0
      )
    """
  end

  @doc "Redact and normalize a payload for observability persistence."
  @spec redact_payload(term()) :: term()
  def redact_payload(value), do: value |> normalize_payload() |> redact()

  @doc """
  Quarantine an already-persisted observability record after a redaction miss.

  This is an incident-response tool: once a miss is reported, callers can remove
  the persisted payload immediately by id while the redaction corpus/fix follows.
  """
  @spec quarantine_record(atom() | String.t(), Ecto.UUID.t(), keyword() | map()) ::
          {:ok, ObservabilityEvent.t() | OperationRun.t() | CheckResult.t() | AuditLog.t()}
          | {:error, :not_found | :unsupported_record_type | Ecto.Changeset.t()}
  def quarantine_record(record_type, id, opts \\ []) do
    opts = normalize_quarantine_opts(opts)

    case normalize_quarantine_record_type(record_type) do
      :event -> quarantine_event(id, opts)
      :operation_run -> quarantine_operation_run(id, opts)
      :check_result -> quarantine_check_result(id, opts)
      :audit_log -> quarantine_audit_log(id, opts)
      :error -> {:error, :unsupported_record_type}
    end
  end

  @doc """
  Hard-delete all Operations records for an org/customer deletion request.

  Source systems remain authoritative for their own deletion workflows; this
  function owns the derived Operations read-model rows so customer deletion does
  not wait for normal retention windows.
  """
  @spec erase_org_observability(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def erase_org_observability(org_id) when is_binary(org_id) do
    with {:ok, counts} <-
           Repo.transaction(fn ->
             {events_deleted, _} = delete_org_rows(ObservabilityEvent, org_id)
             {runs_deleted, _} = delete_org_rows(OperationRun, org_id)
             {checks_deleted, _} = delete_org_rows(CheckResult, org_id)
             {audit_logs_deleted, _} = delete_org_rows(AuditLog, org_id)

             %{
               observability_events_deleted: events_deleted,
               operation_runs_deleted: runs_deleted,
               check_results_deleted: checks_deleted,
               audit_logs_deleted: audit_logs_deleted
             }
           end) do
      Logger.info(
        "bridge_for_teams.observability.org_erasure.completed org_id=#{log_value(org_id)} observability_events_deleted=#{counts.observability_events_deleted} operation_runs_deleted=#{counts.operation_runs_deleted} check_results_deleted=#{counts.check_results_deleted} audit_logs_deleted=#{counts.audit_logs_deleted}"
      )

      {:ok, counts}
    end
  end

  @doc """
  Remove user-identifying references from Operations records.

  This is for user deletion or PII erasure requests. It preserves operational
  and audit facts, but clears user foreign keys and replaces audit actor labels
  tied to the erased user. `:actor_label` or `:actor_labels` can be supplied to
  scrub legacy audit rows that only stored a label.
  """
  @spec erase_user_observability_references(Ecto.UUID.t(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def erase_user_observability_references(user_id, opts \\ []) when is_binary(user_id) do
    opts = normalize_erasure_opts(opts)
    actor_labels = erasure_actor_labels(opts)
    actor_label_replacement = erasure_actor_label_replacement(opts)

    with {:ok, counts} <-
           Repo.transaction(fn ->
             {events_updated, _} =
               ObservabilityEvent
               |> where([event], event.actor_user_id == ^user_id)
               |> Repo.update_all(set: [actor_user_id: nil])

             {checks_updated, _} =
               CheckResult
               |> where([check], check.ran_by_user_id == ^user_id)
               |> Repo.update_all(set: [ran_by_user_id: nil])

             {audit_actor_refs_erased, _} =
               AuditLog
               |> where([audit], audit.actor_user_id == ^user_id)
               |> maybe_or_actor_labels(actor_labels)
               |> Repo.update_all(set: [actor_user_id: nil, actor_label: actor_label_replacement])

             {audit_impersonator_refs_erased, _} =
               AuditLog
               |> where([audit], audit.impersonator_user_id == ^user_id)
               |> Repo.update_all(set: [impersonator_user_id: nil])

             %{
               observability_events_actor_refs_erased: events_updated,
               check_results_user_refs_erased: checks_updated,
               audit_actor_refs_erased: audit_actor_refs_erased,
               audit_impersonator_refs_erased: audit_impersonator_refs_erased
             }
           end) do
      Logger.info(
        "bridge_for_teams.observability.user_erasure.completed observability_events_actor_refs_erased=#{counts.observability_events_actor_refs_erased} check_results_user_refs_erased=#{counts.check_results_user_refs_erased} audit_actor_refs_erased=#{counts.audit_actor_refs_erased} audit_impersonator_refs_erased=#{counts.audit_impersonator_refs_erased}"
      )

      {:ok, counts}
    end
  end

  @doc "Retention defaults for the first Operations release."
  @spec retention_policy() :: map()
  def retention_policy do
    :bridge_for_teams_core
    |> Application.get_env(:observability_retention, [])
    |> Map.new()
    |> then(&Map.merge(@default_retention_policy, &1))
  end

  @doc "Freshness windows used by Operations health and posture rollups."
  @spec freshness_policy() :: map()
  def freshness_policy do
    :bridge_for_teams_core
    |> Application.get_env(:observability_freshness, [])
    |> Map.new()
    |> then(&Map.merge(@default_freshness_policy, &1))
  end

  @doc "Event ingestion rate-limit policy for high-volume Operations sources."
  @spec event_rate_limit_policy() :: map()
  def event_rate_limit_policy do
    case Application.get_env(:bridge_for_teams_core, :observability_event_rate_limit, []) do
      false ->
        Map.put(@default_event_rate_limit_policy, :enabled, false)

      nil ->
        @default_event_rate_limit_policy

      opts when is_list(opts) ->
        Map.merge(@default_event_rate_limit_policy, Map.new(opts))

      opts when is_map(opts) ->
        Map.merge(@default_event_rate_limit_policy, opts)
    end
  end

  @doc """
  Derive the org-level Operations health from already-scoped observability facts.

  This helper intentionally returns machine-stable reason codes instead of UI
  copy so Operations pages, tests, and later alerting can share the same rollup
  contract without duplicating status rules.
  """
  @spec org_health_summary(non_neg_integer(), list(), list(), list(), list()) :: %{
          health: String.t(),
          reason_codes: [atom()]
        }
  def org_health_summary(project_count, runners, events, runs, checks)
      when is_integer(project_count) and is_list(runners) and is_list(events) and is_list(runs) and
             is_list(checks) do
    reason_codes = org_health_reason_codes(project_count, runners, events, runs, checks)

    %{
      health: org_health_from_reasons(reason_codes, checks),
      reason_codes: reason_codes
    }
  end

  @doc """
  Derive org health from unpaginated, unfiltered Operations facts.

  UI list pages may be filtered or cursor-paginated; this query path is kept
  separate so the org health badge cannot turn green because a critical fact was
  pushed past the first page or excluded by the current tab filters.
  """
  @spec org_health_summary_for_org(Ecto.UUID.t(), non_neg_integer(), list(), keyword()) :: %{
          health: String.t(),
          reason_codes: [atom()]
        }
  def org_health_summary_for_org(org_id, project_count, runners, opts \\ [])
      when is_binary(org_id) and is_integer(project_count) and is_list(runners) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = Keyword.get(opts, :freshness_policy, freshness_policy())
    reason_codes = org_health_reason_codes_for_org(org_id, project_count, runners, now, policy)

    %{
      health: org_health_from_reasons(reason_codes, nil),
      reason_codes: reason_codes
    }
  end

  @doc """
  Classify a raw Operations fact value into the shared health scale.

  Supported `kind` values are `:runner_status`, `:event_severity`,
  `:run_status`, and `:check_status`. Unknown kinds or values return
  `:unknown` so callers can avoid accidentally rendering unsupported facts as
  healthy.
  """
  @spec health_class(atom(), term()) ::
          :critical | :action_required | :degraded | :healthy | :unknown
  def health_class(kind, value) when is_atom(kind) do
    normalized = normalize_health_value(value)
    class_values = Map.get(@health_class_values, kind, %{})

    Enum.find_value(@health_classes, :unknown, fn class ->
      if normalized in Map.get(class_values, class, []), do: class
    end)
  end

  def health_class(_kind, _value), do: :unknown

  @doc """
  Prune expired observability rows using the configured retention policy.

  This is the shared boundary used by explicit operator calls and the scheduled
  `BridgeForTeams.Observability.Pruner` worker.
  """
  @spec prune_expired(keyword()) :: {:ok, map()}
  def prune_expired(opts \\ []) do
    try do
      counts = do_prune_expired(opts)

      Logger.info("bridge_for_teams.observability.prune.completed #{inspect(counts)}",
        stderr_tails_cleared: counts.stderr_tails_cleared,
        observability_events_deleted: counts.observability_events_deleted,
        operation_runs_deleted: counts.operation_runs_deleted,
        check_results_deleted: counts.check_results_deleted,
        audit_logs_deleted: counts.audit_logs_deleted
      )

      {:ok, counts}
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.observability.prune.failed #{Exception.message(exception)}"
        )

        reraise exception, __STACKTRACE__
    end
  end

  defp do_prune_expired(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    policy = Keyword.get(opts, :policy, retention_policy())

    {stderr_tails_cleared, _} =
      case cutoff(now, policy[:stderr_tail_days]) do
        nil ->
          {0, nil}

        stderr_cutoff ->
          OperationRun
          |> where([r], r.created_at < ^stderr_cutoff and not is_nil(r.stderr_tail_redacted))
          |> Repo.update_all(set: [stderr_tail_redacted: nil])
      end

    {events_deleted, _} =
      delete_older_than(
        ObservabilityEvent,
        :occurred_at,
        cutoff(now, policy[:observability_events_days])
      )

    {runs_deleted, _} =
      delete_older_than(OperationRun, :created_at, cutoff(now, policy[:operation_runs_days]))

    {checks_deleted, _} =
      delete_older_than(CheckResult, :ran_at, cutoff(now, policy[:check_results_days]))

    {audit_deleted, _} =
      delete_older_than(AuditLog, :created_at, cutoff(now, policy[:audit_logs_days]))

    %{
      stderr_tails_cleared: stderr_tails_cleared,
      observability_events_deleted: events_deleted,
      operation_runs_deleted: runs_deleted,
      check_results_deleted: checks_deleted,
      audit_logs_deleted: audit_deleted
    }
  end

  defp validate_common_scope(%{"org_id" => org_id} = attrs) when is_binary(org_id) do
    with :ok <- validate_project_scope(org_id, attrs["project_id"]),
         :ok <- validate_runner_scope(org_id, attrs["runner_type"], attrs["runner_id"]) do
      :ok
    end
  end

  defp validate_common_scope(_attrs), do: :ok

  defp validate_event_scope(%{"org_id" => org_id} = attrs) do
    with :ok <- validate_run_scope(org_id, attrs["run_record_id"]),
         :ok <- validate_check_scope(org_id, attrs["check_result_id"]),
         :ok <- validate_audit_scope(org_id, attrs["audit_log_id"]) do
      :ok
    end
  end

  defp validate_event_rate_limit(%{"org_id" => org_id, "source" => source} = attrs)
       when is_binary(org_id) and is_binary(source) and source != "" do
    policy = event_rate_limit_policy()
    max_events = source_rate_limit(policy, source)
    window_seconds = policy_integer(policy[:window_seconds], 60)

    cond do
      policy[:enabled] == false ->
        :ok

      max_events in [nil, false] ->
        :ok

      not is_integer(max_events) or max_events <= 0 ->
        :ok

      not is_nil(existing_observability_event(attrs, nil)) ->
        :ok

      event_source_count(org_id, source, rate_limit_cutoff(attrs["occurred_at"], window_seconds)) >=
          max_events ->
        {:error,
         {:backpressure,
          %{
            limit: max_events,
            retry_after_ms: window_seconds * 1_000,
            window_seconds: window_seconds
          }}}

      true ->
        :ok
    end
  end

  defp validate_event_rate_limit(_attrs), do: :ok

  defp source_rate_limit(policy, source) do
    source_limits = policy[:source_limits] || %{}

    case source_limits do
      limits when is_map(limits) -> Map.get(limits, source, policy[:max_events_per_source])
      _other -> policy[:max_events_per_source]
    end
  end

  defp rate_limit_cutoff(%DateTime{} = occurred_at, window_seconds) do
    DateTime.add(occurred_at, -window_seconds, :second)
  end

  defp rate_limit_cutoff(_occurred_at, window_seconds) do
    DateTime.utc_now() |> DateTime.add(-window_seconds, :second)
  end

  defp event_source_count(org_id, source, %DateTime{} = cutoff) do
    ObservabilityEvent
    |> where([event], event.org_id == ^org_id)
    |> where([event], event.source == ^source)
    |> where([event], event.occurred_at >= ^cutoff)
    |> Repo.aggregate(:count, :id)
  end

  defp validate_project_scope(_org_id, nil), do: :ok
  defp validate_project_scope(_org_id, ""), do: :ok

  defp validate_project_scope(org_id, project_id) do
    if Repo.exists?(from(p in Project, where: p.id == ^project_id and p.org_id == ^org_id)) do
      :ok
    else
      {:error, :project_scope_mismatch}
    end
  end

  defp validate_runner_scope(_org_id, _runner_type, nil), do: :ok
  defp validate_runner_scope(_org_id, _runner_type, ""), do: :ok
  defp validate_runner_scope(_org_id, nil, _runner_id), do: {:error, :runner_type_required}
  defp validate_runner_scope(_org_id, "", _runner_id), do: {:error, :runner_type_required}

  defp validate_runner_scope(org_id, "mac_mini_provisioner", runner_id) do
    if Repo.exists?(
         from(r in MacMiniProvisioner, where: r.id == ^runner_id and r.org_id == ^org_id)
       ) do
      :ok
    else
      {:error, :runner_scope_mismatch}
    end
  end

  defp validate_runner_scope(_org_id, runner_type, _runner_id)
       when runner_type not in @runner_types,
       do: {:error, :unknown_runner_type}

  defp validate_run_scope(_org_id, nil), do: :ok
  defp validate_run_scope(_org_id, ""), do: :ok

  defp validate_run_scope(org_id, run_id) do
    if Repo.exists?(from(r in OperationRun, where: r.id == ^run_id and r.org_id == ^org_id)) do
      :ok
    else
      {:error, :run_scope_mismatch}
    end
  end

  defp validate_check_scope(_org_id, nil), do: :ok
  defp validate_check_scope(_org_id, ""), do: :ok

  defp validate_check_scope(org_id, check_id) do
    if Repo.exists?(from(c in CheckResult, where: c.id == ^check_id and c.org_id == ^org_id)) do
      :ok
    else
      {:error, :check_scope_mismatch}
    end
  end

  defp validate_audit_scope(_org_id, nil), do: :ok
  defp validate_audit_scope(_org_id, ""), do: :ok

  defp validate_audit_scope(org_id, audit_log_id) do
    if Repo.exists?(from(a in AuditLog, where: a.id == ^audit_log_id and a.org_id == ^org_id)) do
      :ok
    else
      {:error, :audit_scope_mismatch}
    end
  end

  defp maybe_filter(query, _field, value) when value in [nil, ""], do: query

  defp maybe_filter(query, field, value) do
    where(query, [row], field(row, ^field) == ^value)
  end

  defp maybe_filter_not(query, _field, value) when value in [nil, "", []], do: query

  defp maybe_filter_not(query, field, value) do
    values = List.wrap(value)
    where(query, [row], field(row, ^field) not in ^values)
  end

  defp maybe_filter_gate_status(query, value) when value in [nil, ""], do: query

  defp maybe_filter_gate_status(query, value) do
    where(
      query,
      [check],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM jsonb_array_elements(
            CASE
              WHEN jsonb_typeof(?->'gates') = 'array' THEN ?->'gates'
              ELSE '[]'::jsonb
            END
          ) AS gate
          WHERE gate->>'status' = ?
        )
        """,
        check.result,
        check.result,
        ^value
      )
    )
  end

  defp maybe_since(query, _field, nil), do: query

  defp maybe_since(query, field, %DateTime{} = since) do
    where(query, [row], field(row, ^field) >= ^since)
  end

  defp page_by(query, field, opts) do
    page_limit = limit(opts)
    started_at = System.monotonic_time()

    rows =
      query
      |> maybe_after_cursor(field, opts[:after])
      |> order_by([row], desc: field(row, ^field), desc: row.id)
      |> limit(^(page_limit + 1))
      |> Repo.all()

    duration_us =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)

    entries = Enum.take(rows, page_limit)
    next_cursor = if length(rows) > page_limit, do: encode_cursor(List.last(entries), field)

    log_query_completed(query, field, entries, next_cursor, page_limit, duration_us)

    %{entries: entries, next_cursor: next_cursor}
  end

  defp maybe_after_cursor(query, _field, cursor) when cursor in [nil, ""], do: query

  defp maybe_after_cursor(query, field, cursor) when is_binary(cursor) do
    case decode_cursor(cursor) do
      {:ok, %{at: at, id: id}} ->
        where(
          query,
          [row],
          field(row, ^field) < ^at or (field(row, ^field) == ^at and row.id < ^id)
        )

      :error ->
        query
    end
  end

  defp maybe_after_cursor(query, _field, _cursor), do: query

  defp health_values(kind, class) when is_atom(kind) and is_atom(class) do
    @health_class_values
    |> Map.get(kind, %{})
    |> Map.get(class, [])
  end

  defp health_class?(kind, value, class), do: health_class(kind, value) == class

  defp normalize_health_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_health_value(value) when is_binary(value), do: value
  defp normalize_health_value(_value), do: ""

  defp org_health_reason_codes(project_count, runners, events, runs, checks)
       when project_count == 0 and runners == [] and events == [] and runs == [] and checks == [],
       do: [:no_operations_facts]

  defp org_health_reason_codes(project_count, runners, events, runs, checks) do
    runner_statuses = Enum.map(runners, &runner_status/1)

    [
      if(project_count > 0 and runners == [], do: :projects_without_runners),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :critical)),
        do: :critical_runner_status
      ),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :action_required)),
        do: :runner_offline_or_failed
      ),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :degraded)),
        do: :runner_stale_or_unknown
      ),
      if(Enum.any?(events, &health_class?(:event_severity, &1.severity, :critical)),
        do: :critical_events
      ),
      if(Enum.any?(events, &health_class?(:event_severity, &1.severity, :action_required)),
        do: :error_events
      ),
      if(Enum.any?(runs, &health_class?(:run_status, &1.status, :critical)),
        do: :critical_runs
      ),
      if(Enum.any?(runs, &health_class?(:run_status, &1.status, :action_required)),
        do: :failed_or_canceled_runs
      ),
      if(Enum.any?(checks, &health_class?(:check_status, &1.status, :critical)),
        do: :critical_checks
      ),
      if(Enum.any?(checks, &health_class?(:check_status, &1.status, :action_required)),
        do: :failed_checks
      ),
      if(Enum.any?(runs, &health_class?(:run_status, &1.status, :degraded)),
        do: :manual_or_skipped_runs
      ),
      if(Enum.any?(checks, &health_class?(:check_status, &1.status, :degraded)),
        do: :manual_or_skipped_checks
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        if checks != [] and Enum.all?(checks, &(&1.status == "ok")) do
          [:checks_healthy]
        else
          [:signals_partial]
        end

      reasons ->
        reasons
    end
  end

  defp org_health_reason_codes_for_org(org_id, project_count, runners, now, policy) do
    event_since = freshness_since(now, policy[:event_history_seconds])
    run_since = freshness_since(now, policy[:operation_run_history_seconds])
    check_since = freshness_since(now, policy[:check_result_history_seconds])

    recent_events? = recent_rows?(ObservabilityEvent, org_id, :occurred_at, event_since)
    recent_runs? = recent_rows?(OperationRun, org_id, :created_at, run_since)
    recent_checks? = recent_rows?(CheckResult, org_id, :ran_at, check_since)

    if project_count == 0 and runners == [] and not recent_events? and not recent_runs? and
         not recent_checks? do
      [:no_operations_facts]
    else
      org_health_reason_codes_for_org(
        org_id,
        project_count,
        runners,
        event_since,
        run_since,
        check_since,
        recent_checks?
      )
    end
  end

  defp org_health_reason_codes_for_org(
         org_id,
         project_count,
         runners,
         event_since,
         run_since,
         check_since,
         recent_checks?
       ) do
    runner_statuses = Enum.map(runners, &runner_status/1)

    [
      if(project_count > 0 and runners == [], do: :projects_without_runners),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :critical)),
        do: :critical_runner_status
      ),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :action_required)),
        do: :runner_offline_or_failed
      ),
      if(Enum.any?(runner_statuses, &health_class?(:runner_status, &1, :degraded)),
        do: :runner_stale_or_unknown
      ),
      if(recent_event_with?(org_id, health_values(:event_severity, :critical), event_since),
        do: :critical_events
      ),
      if(
        recent_event_with?(
          org_id,
          health_values(:event_severity, :action_required),
          event_since
        ),
        do: :error_events
      ),
      if(recent_run_with?(org_id, health_values(:run_status, :critical), run_since),
        do: :critical_runs
      ),
      if(recent_run_with?(org_id, health_values(:run_status, :action_required), run_since),
        do: :failed_or_canceled_runs
      ),
      if(recent_check_with?(org_id, health_values(:check_status, :critical), check_since),
        do: :critical_checks
      ),
      if(recent_check_with?(org_id, health_values(:check_status, :action_required), check_since),
        do: :failed_checks
      ),
      if(recent_run_with?(org_id, health_values(:run_status, :degraded), run_since),
        do: :manual_or_skipped_runs
      ),
      if(recent_check_with?(org_id, health_values(:check_status, :degraded), check_since),
        do: :manual_or_skipped_checks
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        if recent_checks? and not recent_check_without?(org_id, ["ok"], check_since) do
          [:checks_healthy]
        else
          [:signals_partial]
        end

      reasons ->
        reasons
    end
  end

  defp recent_event_with?(org_id, severities, since) do
    recent_rows?(ObservabilityEvent, org_id, :occurred_at, since, :severity, severities)
  end

  defp recent_run_with?(org_id, statuses, since) do
    recent_rows?(OperationRun, org_id, :created_at, since, :status, statuses)
  end

  defp recent_check_with?(org_id, statuses, since) do
    recent_rows?(CheckResult, org_id, :ran_at, since, :status, statuses)
  end

  defp recent_check_without?(org_id, statuses, since) do
    CheckResult
    |> where([row], row.org_id == ^org_id)
    |> maybe_since(:ran_at, since)
    |> maybe_filter_not_in(:status, statuses)
    |> Repo.exists?()
  end

  defp recent_rows?(schema, org_id, since_field, since) do
    schema
    |> where([row], row.org_id == ^org_id)
    |> maybe_since(since_field, since)
    |> Repo.exists?()
  end

  defp recent_rows?(schema, org_id, since_field, since, field, values) do
    schema
    |> where([row], row.org_id == ^org_id)
    |> maybe_since(since_field, since)
    |> maybe_filter_in(field, values)
    |> Repo.exists?()
  end

  defp maybe_filter_in(query, _field, values) when values in [nil, []], do: query

  defp maybe_filter_in(query, field, values) do
    values = List.wrap(values)
    where(query, [row], field(row, ^field) in ^values)
  end

  defp maybe_filter_not_in(query, _field, values) when values in [nil, []], do: query

  defp maybe_filter_not_in(query, field, values) do
    values = List.wrap(values)
    where(query, [row], field(row, ^field) not in ^values)
  end

  defp freshness_since(_now, seconds) when seconds in [nil, :infinity], do: nil

  defp freshness_since(%DateTime{} = now, seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.add(now, -seconds, :second)
  end

  defp freshness_since(_now, _seconds), do: nil

  defp org_health_from_reasons([:no_operations_facts], _checks), do: "unknown"

  defp org_health_from_reasons(reason_codes, _checks) do
    cond do
      Enum.any?(
        reason_codes,
        &(&1 in [:critical_runner_status, :critical_events, :critical_runs, :critical_checks])
      ) ->
        "critical"

      Enum.any?(
        reason_codes,
        &(&1 in [
            :projects_without_runners,
            :runner_offline_or_failed,
            :error_events,
            :failed_or_canceled_runs,
            :failed_checks
          ])
      ) ->
        "action_required"

      reason_codes == [:checks_healthy] ->
        "healthy"

      true ->
        "degraded"
    end
  end

  defp runner_status(%{effective_status: status}) when is_binary(status) and status != "",
    do: status

  defp runner_status(%{status: status}) when is_binary(status) and status != "", do: status
  defp runner_status(_), do: "unknown"

  defp encode_cursor(nil, _field), do: nil

  defp encode_cursor(row, field) do
    at =
      row
      |> Map.fetch!(field)
      |> DateTime.to_iso8601()

    %{at: at, id: row.id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"at" => at, "id" => id}} <- Jason.decode(json),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, %{at: at, id: id}}
    else
      _ -> :error
    end
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(500)
    |> max(1)
  end

  defp maybe_derive_check_status(%{"status" => status} = attrs) when is_binary(status), do: attrs

  defp maybe_derive_check_status(%{"result" => %{"gates" => gates}} = attrs) do
    attrs
    |> Map.put("status", GateContract.aggregate_status(gates))
    |> Map.put("reason_class", GateContract.aggregate_reason(gates))
  end

  defp maybe_derive_check_status(attrs), do: Map.put_new(attrs, "status", "unknown")

  defp existing_check_result(%{"org_id" => org_id, "invocation_id" => invocation_id}, _changeset)
       when is_binary(invocation_id) and invocation_id != "" do
    Repo.get_by(CheckResult, org_id: org_id, invocation_id: invocation_id)
  end

  defp existing_check_result(_attrs, _changeset), do: nil

  defp insert_observability_event(changeset, attrs) do
    case attrs["correlation_id"] do
      correlation_id when is_binary(correlation_id) and correlation_id != "" ->
        Repo.insert(changeset,
          on_conflict: {:replace, Map.keys(changeset.changes)},
          conflict_target:
            {:unsafe_fragment,
             "(org_id, source, event_type, correlation_id) WHERE correlation_id IS NOT NULL"},
          returning: true
        )

      _ ->
        Repo.insert(changeset)
    end
  end

  defp existing_observability_event(
         %{
           "org_id" => org_id,
           "source" => source,
           "event_type" => event_type,
           "correlation_id" => correlation_id
         },
         _changeset
       )
       when is_binary(correlation_id) and correlation_id != "" do
    Repo.get_by(ObservabilityEvent,
      org_id: org_id,
      source: source,
      event_type: event_type,
      correlation_id: correlation_id
    )
  end

  defp existing_observability_event(_attrs, _changeset), do: nil

  defp insert_operation_run(attrs) do
    changeset = OperationRun.changeset(%OperationRun{}, attrs)

    case attrs["external_run_id"] do
      external_run_id when is_binary(external_run_id) and external_run_id != "" ->
        Repo.insert(changeset,
          on_conflict: {:replace, [:updated_at | Map.keys(changeset.changes)]},
          conflict_target:
            {:unsafe_fragment, "(org_id, external_run_id) WHERE external_run_id IS NOT NULL"},
          returning: true
        )

      _ ->
        Repo.insert(changeset)
    end
  end

  defp insert_operation_run_once(%{"external_run_id" => external_run_id} = attrs)
       when is_binary(external_run_id) and external_run_id != "" do
    changeset = OperationRun.changeset(%OperationRun{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(org_id, external_run_id) WHERE external_run_id IS NOT NULL"},
           returning: true
         ) do
      {:ok, %OperationRun{} = candidate} ->
        case Repo.get_by(OperationRun,
               id: candidate.id,
               org_id: candidate.org_id,
               external_run_id: external_run_id
             ) do
          %OperationRun{} = persisted -> {:ok, persisted}
          nil -> {:error, :already_exists}
        end

      other ->
        other
    end
  end

  defp insert_operation_run_once(_attrs), do: {:error, :external_run_id_required}

  defp quarantine_event(id, opts) do
    case Repo.get(ObservabilityEvent, id) do
      nil ->
        {:error, :not_found}

      %ObservabilityEvent{} = event ->
        {marker, size} = quarantine_payload("observability_event", "evidence", opts)

        event
        |> ObservabilityEvent.changeset(%{
          evidence: marker,
          evidence_size_bytes: size,
          summary: "Quarantined observability event",
          severity: "warning",
          status: "quarantined",
          reason_class: marker["reason_class"]
        })
        |> Repo.update()
    end
  end

  defp quarantine_operation_run(id, opts) do
    case Repo.get(OperationRun, id) do
      nil ->
        {:error, :not_found}

      %OperationRun{} = run ->
        {marker, size} = quarantine_payload("operation_run", "evidence", opts)

        run
        |> OperationRun.changeset(%{
          evidence: marker,
          evidence_size_bytes: size,
          stderr_tail_redacted: nil,
          status: "unknown",
          reason_class: marker["reason_class"]
        })
        |> Repo.update()
    end
  end

  defp quarantine_check_result(id, opts) do
    case Repo.get(CheckResult, id) do
      nil ->
        {:error, :not_found}

      %CheckResult{} = check ->
        {marker, size} = quarantine_payload("check_result", "result", opts)

        check
        |> CheckResult.changeset(%{
          result: marker,
          result_size_bytes: size,
          status: "unknown",
          reason_class: marker["reason_class"]
        })
        |> Repo.update()
    end
  end

  defp quarantine_audit_log(id, opts) do
    case Repo.get(AuditLog, id) do
      nil ->
        {:error, :not_found}

      %AuditLog{} = audit ->
        {metadata_marker, metadata_size} = quarantine_payload("audit_log", "metadata", opts)
        {diff_marker, _diff_size} = quarantine_payload("audit_log", "redacted_diff", opts)

        audit
        |> AuditLog.changeset(%{
          metadata: metadata_marker,
          redacted_diff: diff_marker,
          metadata_size_bytes: metadata_size,
          result: "unknown",
          reason_class: metadata_marker["reason_class"]
        })
        |> Repo.update()
    end
  end

  defp normalize_quarantine_opts(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_quarantine_opts()
  end

  defp normalize_quarantine_opts(opts) when is_map(opts), do: normalize_payload(opts)
  defp normalize_quarantine_opts(_opts), do: %{}

  defp normalize_quarantine_record_type(type) when is_atom(type) do
    type
    |> Atom.to_string()
    |> normalize_quarantine_record_type()
  end

  defp normalize_quarantine_record_type(type) when is_binary(type) do
    case type do
      value when value in ["event", "observability_event", "observability_events"] -> :event
      value when value in ["run", "operation_run", "operation_runs"] -> :operation_run
      value when value in ["check", "check_result", "check_results"] -> :check_result
      value when value in ["audit", "audit_log", "audit_logs"] -> :audit_log
      _ -> :error
    end
  end

  defp normalize_quarantine_record_type(_type), do: :error

  defp quarantine_payload(record_type, payload_field, opts) do
    payload =
      %{
        "quarantined" => true,
        "record_type" => record_type,
        "payload_field" => payload_field,
        "reason_class" => quarantine_reason_class(opts),
        "quarantined_at" => quarantine_timestamp(opts),
        "original_payload_removed" => true
      }
      |> maybe_put_quarantine_note(opts)
      |> redact_payload()

    {payload, payload_size(payload)}
  end

  defp quarantine_reason_class(opts) do
    opts
    |> Map.get("reason_class", "redaction_miss")
    |> to_string()
    |> blank_to("redaction_miss")
  end

  defp quarantine_timestamp(%{"now" => %DateTime{} = now}), do: DateTime.to_iso8601(now)
  defp quarantine_timestamp(%{"now" => timestamp}) when is_binary(timestamp), do: timestamp

  defp quarantine_timestamp(%{"quarantined_at" => %DateTime{} = now}),
    do: DateTime.to_iso8601(now)

  defp quarantine_timestamp(%{"quarantined_at" => timestamp}) when is_binary(timestamp),
    do: timestamp

  defp quarantine_timestamp(_opts), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp maybe_put_quarantine_note(payload, opts) do
    case Map.get(opts, "operator_note") || Map.get(opts, "note") do
      note when is_binary(note) and note != "" -> Map.put(payload, "operator_note", note)
      _ -> payload
    end
  end

  defp compact_attrs(attrs) do
    Map.reject(attrs, fn {_key, value} -> value in [nil, ""] end)
  end

  defp default_subject_type("bot"), do: "project"
  defp default_subject_type("slack_calendar"), do: "project"
  defp default_subject_type("sso"), do: "org"
  defp default_subject_type(_surface), do: "unknown"

  defp default_subject_id("bot", _org_id, project_id), do: project_id
  defp default_subject_id("slack_calendar", _org_id, project_id), do: project_id
  defp default_subject_id("sso", org_id, _project_id), do: org_id
  defp default_subject_id(_surface, org_id, _project_id), do: org_id

  defp check_status_severity("fail"), do: "error"
  defp check_status_severity("needs_manual"), do: "warning"
  defp check_status_severity("skipped"), do: "warning"
  defp check_status_severity("unknown"), do: "warning"
  defp check_status_severity(_status), do: "info"

  defp run_checks_summary(surface, status) do
    "Run checks completed for #{surface}: #{String.replace(status || "unknown", "_", " ")}"
  end

  defp audit_result(_status), do: "ok"

  defp validation_surface(surface) when is_binary(surface) and surface != "",
    do: surface

  defp validation_surface(_surface), do: "integration"

  defp validation_status(status) when status in ["ok", "fail", "needs_manual", "skipped"],
    do: status

  defp validation_status(status) when status in [:ok, :pass, :passed], do: "ok"
  defp validation_status(status) when status in [:error, :fail, :failed], do: "fail"
  defp validation_status(_status), do: "unknown"

  defp validation_outcome("ok"), do: "passed"
  defp validation_outcome(_status), do: "failed"

  defp validation_severity("ok"), do: "info"
  defp validation_severity("needs_manual"), do: "warning"
  defp validation_severity("skipped"), do: "warning"
  defp validation_severity(_status), do: "error"

  defp validation_event_prefix("sso"), do: "sso"
  defp validation_event_prefix("oauth"), do: "oauth"
  defp validation_event_prefix("feishu"), do: "feishu"
  defp validation_event_prefix("bot"), do: "feishu"
  defp validation_event_prefix("models"), do: "model"
  defp validation_event_prefix("model"), do: "model"

  defp validation_event_prefix(surface) do
    surface
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
    |> String.downcase()
  end

  defp validation_resource_type("sso"), do: "sso_connection"
  defp validation_resource_type("oauth"), do: "oauth_provider_app"
  defp validation_resource_type("feishu"), do: "feishu_app_binding"
  defp validation_resource_type("bot"), do: "feishu_app_binding"
  defp validation_resource_type("models"), do: "model_settings"
  defp validation_resource_type("model"), do: "model_settings"
  defp validation_resource_type(_surface), do: "integration_settings"

  defp validation_summary(surface, resource_label, "ok", _reason_class) do
    label = resource_label || surface
    "#{label} validation passed"
  end

  defp validation_summary(surface, resource_label, _status, reason_class) do
    label = resource_label || surface
    reason = reason_class || "unknown"
    reason = if is_binary(reason), do: reason, else: to_string(reason)

    "#{label} validation failed: #{String.replace(reason, "_", " ")}"
  end

  defp validation_evidence(attrs, surface, status, reason_class) do
    base =
      %{
        "surface" => surface,
        "settings_path" => attrs["settings_path"] || validation_settings_path(surface),
        "status" => status,
        "reason_class" => reason_class,
        "provider" => attrs["provider"],
        "resource_type" => attrs["resource_type"] || validation_resource_type(surface),
        "resource_id" => attrs["resource_id"]
      }
      |> compact_attrs()

    attrs
    |> Map.get("evidence", %{})
    |> normalize_payload()
    |> case do
      %{} = evidence -> Map.merge(base, evidence)
      _other -> base
    end
  end

  defp validation_settings_path("sso"), do: "settings/sso"
  defp validation_settings_path("oauth"), do: "settings/oauth"
  defp validation_settings_path("feishu"), do: "settings/feishu"
  defp validation_settings_path("bot"), do: "settings/feishu"
  defp validation_settings_path("models"), do: "settings/models"
  defp validation_settings_path("model"), do: "settings/models"
  defp validation_settings_path(_surface), do: "settings"

  defp run_checks_activity_evidence(result, %CheckResult{} = check) do
    gates =
      case result["gates"] do
        gates when is_list(gates) -> gates
        _other -> []
      end

    %{
      "surface" => result["surface"] || check.surface,
      "status" => check.status,
      "check_family" => check.check_family,
      "project_ref" => result["project_ref"],
      "connect_ref" => result["connect_ref"],
      "gate_count" => length(gates),
      "actionable_gate" => GateContract.first_actionable(gates)
    }
  end

  defp maybe_normalize_run_checks(%{"check_family" => "run_checks", "result" => result} = attrs)
       when is_map(result),
       do: Map.put(attrs, "result", GateContract.normalize_result(result))

  defp maybe_normalize_run_checks(attrs), do: attrs

  defp put_sized_check_result(%{"check_family" => "run_checks"} = attrs) do
    {payload, size} =
      attrs
      |> Map.get("result", %{})
      |> redact_payload()
      |> GateContract.normalize_result()
      |> fit_payload()

    attrs
    |> Map.put("result", payload)
    |> Map.put("result_size_bytes", size)
  end

  defp put_sized_check_result(attrs), do: put_sized_payload(attrs, "result", "result_size_bytes")

  defp put_sized_payload(attrs, payload_key, size_key) do
    {payload, size} =
      attrs
      |> Map.get(payload_key, %{})
      |> redact_payload()
      |> fit_payload()

    attrs
    |> Map.put(payload_key, payload)
    |> Map.put(size_key, size)
  end

  defp maybe_put_sized_payload(attrs, payload_key, size_key) do
    if Map.has_key?(attrs, payload_key) do
      put_sized_payload(attrs, payload_key, size_key)
    else
      attrs
    end
  end

  defp put_bounded_redacted_payload(attrs, payload_key) do
    {payload, _size} =
      attrs
      |> Map.get(payload_key, %{})
      |> redact_payload()
      |> fit_payload("#{payload_key}_truncated")

    Map.put(attrs, payload_key, payload)
  end

  defp redact_stderr_tail(%{"stderr_tail_redacted" => tail} = attrs) when is_binary(tail) do
    Map.put(attrs, "stderr_tail_redacted", tail |> redact_payload() |> tail_string())
  end

  defp redact_stderr_tail(attrs), do: attrs

  defp redact_summary(%{"summary" => summary} = attrs) when is_binary(summary) do
    Map.put(attrs, "summary", redact_string(summary))
  end

  defp redact_summary(attrs), do: attrs

  defp tail_string(value) do
    value
    |> to_string()
    |> String.slice(-@stderr_tail_max_chars, @stderr_tail_max_chars)
  end

  defp fit_payload(payload, truncated_key \\ "evidence_truncated") do
    size = payload_size(payload)
    max_bytes = payload_max_bytes()

    if size <= max_bytes do
      {payload, size}
    else
      truncated = %{
        truncated_key => true,
        "original_size_bytes" => size
      }

      truncated_size = payload_size(truncated)

      Logger.warning(
        "bridge_for_teams.observability.payload.truncated truncated_key=#{truncated_key} original_size_bytes=#{size} truncated_size_bytes=#{truncated_size} payload_max_bytes=#{max_bytes}"
      )

      {truncated, truncated_size}
    end
  end

  defp payload_size(payload), do: payload |> Jason.encode!() |> byte_size()

  defp payload_max_bytes do
    Application.get_env(
      :bridge_for_teams_core,
      :observability_payload_max_bytes,
      @default_payload_max_bytes
    )
  end

  defp cutoff(_now, days) when days in [nil, false], do: nil
  defp cutoff(_now, days) when is_integer(days) and days <= 0, do: nil

  defp cutoff(%DateTime{} = now, days) when is_integer(days) do
    DateTime.add(now, -days * 86_400, :second)
  end

  defp delete_older_than(_schema, _field, nil), do: {0, nil}

  defp delete_older_than(schema, field, %DateTime{} = cutoff) do
    schema
    |> where([row], field(row, ^field) < ^cutoff)
    |> Repo.delete_all()
  end

  defp delete_org_rows(schema, org_id) do
    schema
    |> where([row], row.org_id == ^org_id)
    |> Repo.delete_all()
  end

  defp normalize_erasure_opts(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> normalize_erasure_opts()
  end

  defp normalize_erasure_opts(opts) when is_map(opts), do: normalize_payload(opts)
  defp normalize_erasure_opts(_opts), do: %{}

  defp erasure_actor_labels(opts) do
    [Map.get(opts, "actor_label"), Map.get(opts, "actor_labels")]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp erasure_actor_label_replacement(opts) do
    opts
    |> Map.get("actor_label_replacement", "Erased user")
    |> to_string()
    |> redact_string()
    |> blank_to("Erased user")
  end

  defp maybe_or_actor_labels(query, []), do: query

  defp maybe_or_actor_labels(query, actor_labels) do
    or_where(query, [audit], audit.actor_label in ^actor_labels)
  end

  defp normalize_payload(nil), do: nil
  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp normalize_payload(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_payload(value)} end)
  end

  defp normalize_payload(list) when is_list(list), do: Enum.map(list, &normalize_payload/1)
  defp normalize_payload(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_payload(value), do: value

  defp redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value) when is_binary(value), do: redact_string(value)
  defp redact(value), do: value

  defp redact_string(value) do
    cond do
      Regex.match?(
        ~r/(bearer\s+[a-z0-9._-]+|authorization\s*[:=]|(?:app|client)?_?secret\s*[:=]|verification_?token\s*[:=]|encrypt_?key\s*[:=]|api_?key\s*[:=]|access_?token\s*[:=]|password\s*[:=]|private[_ -]?key|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-[a-z0-9_-]{16,}|xox[abprs]-[a-z0-9-]{16,}|gh[opsu]_[a-z0-9_]{16,}|glpat-[a-z0-9_-]{16,})/i,
        value
      ) ->
        "[REDACTED]"

      Regex.match?(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, value) ->
        "[REDACTED]"

      true ->
        value
    end
  end

  defp secret_key?(key) do
    key = key |> to_string() |> String.downcase()

    cond do
      String.ends_with?(key, "_configured") ->
        false

      key in ~w(app_id connect_id group_id project_id settings_path status_code http_status duration_ms exit_code component component_version heartbeat_age_seconds callback_mode challenge_mode delivery_state evidence_path_label request_id run_id conversation_id provider_event_id provider_event_type message_id source_message_id reply_message_id chat_id chat_type channel_id thread_ts message_ts user_id workspace_id operation_api receive_id_type response_time_ms content_length message_count prompt_tokens completion_tokens total_tokens input_tokens output_tokens command_sha256 command_hash runner failure_code install_code_id release_id next_action log_markers stdout_bytes stderr_bytes truncated provision_request_id agent_id salix_agent_id connector_run_id device_id connector_id runtime_id device_runtime_id runtime_status previous_status ready version version_detected app_server_startable auth_ready readiness_checked_at payload_field original_payload_removed quarantined quarantined_at) ->
        false

      path_key?(key) ->
        true

      String.contains?(key, [
        "secret",
        "token",
        "api_key",
        "key_hash",
        "encrypt_key",
        "authorization",
        "password",
        "raw_payload",
        "raw_command",
        "argv",
        "command_line",
        "payload",
        "body",
        "message",
        "prompt",
        "response",
        "content",
        "stdout",
        "stderr",
        "email",
        "phone",
        "mobile",
        "open_id",
        "union_id",
        "tenant_access",
        "user_access",
        "access_token"
      ]) ->
        true

      true ->
        false
    end
  end

  defp path_key?(key) do
    key in ~w(path paths) or
      String.starts_with?(key, ["path_", "paths_"]) or
      String.ends_with?(key, ["_path", "_paths"]) or
      String.contains?(key, ["_path_", "_paths_"])
  end

  defp actor_type(%{"actor_user_id" => actor_user_id}) when actor_user_id not in [nil, ""],
    do: "user"

  defp actor_type(%{actor_user_id: actor_user_id}) when actor_user_id not in [nil, ""], do: "user"
  defp actor_type(_attrs), do: "system"

  defp legacy_resource_type(attrs) do
    case legacy_target(attrs) do
      target when is_binary(target) ->
        target
        |> String.split(":", parts: 2)
        |> List.first()
        |> blank_to("legacy")

      _ ->
        "legacy"
    end
  end

  defp legacy_resource_id(attrs) do
    case legacy_target(attrs) do
      target when is_binary(target) ->
        case String.split(target, ":", parts: 2) do
          [_type, id] when id != "" -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp legacy_resource_label(attrs), do: legacy_target(attrs)

  defp legacy_target(%{"target" => target}), do: target
  defp legacy_target(%{target: target}), do: target
  defp legacy_target(_attrs), do: nil

  defp blank_to("", fallback), do: fallback
  defp blank_to(nil, fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
