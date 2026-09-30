defmodule BridgeForTeams.Salix.Reconciler do
  @moduledoc """
  Drains `reconcile_outbox` to the Salix S3 control-plane (design §4.2). At-
  least-once, idempotent (salix control writes are create-once / CAS upserts).
  Reads rows `FOR UPDATE SKIP LOCKED`; applies each via `BridgeForTeams.Salix.Client`.
  Optionally gated by a `SalixStore.Lease` for single-drainer.

  A GenServer in the supervision tree; `drain_once/1` is the deterministic unit
  used by tests (the periodic loop calls it).

  ## Outbox ops

  `op` (a string) selects the erpc the row applies. Recognized ops and their
  `payload` shape (JSONB, so string keys after a round-trip — both atom and
  string keys are accepted):

    * `"create_tenant"`        — `%{"attrs" => map}`            → `create_tenant/1`
    * `"ensure_tenant_config"` — `%{"org_id" => org_id}` → current BFT tenant config ensure
    * `"create_group"`         — `%{"attrs" => map}`            → `create_group/1`
    * `"delete_group_im_connects"` — tenant/group-scoped route retirement after archival
    * `"update_group"`         — `%{"group_id" =>, "tenant_id" =>, "attrs" =>}` → `update_group/3`
    * `"update_agent"`         — `%{"agent_id" =>, "tenant_id" =>, "attrs" =>}` → `update_agent/3`
    * `"apply_external_worker_binding"` — monotonic Connected/Compute binding CAS

  ## Outcome handling

    * `{:ok, _}`                       → row `done`, `processed_at` stamped.
    * transient `{:error, reason}` → row stays `pending`, `attempts` bumped,
      `last_error` recorded — retried next drain.
    * any other `{:error, _}` or unknown op → row `failed`, `attempts` bumped.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias BridgeForTeams.{Observability, Repo, Telemetry}
  alias BridgeForTeams.Salix.{Client, TenantConfig}
  alias BridgeForTeams.Schema.{Agent, Organization, Project, ReconcileOutbox}

  @default_limit 50
  # Errors that mean "salix briefly unreachable" — keep the row pending.
  @transient [:unavailable, :timeout]

  @doc "Start the reconcile worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a reconcile op (called inside the domain mutation's transaction)."
  @spec enqueue(String.t(), String.t(), String.t(), map()) ::
          {:ok, ReconcileOutbox.t()} | {:error, term()}
  def enqueue(aggregate, aggregate_id, op, payload) do
    %ReconcileOutbox{}
    |> ReconcileOutbox.changeset(%{
      aggregate: aggregate,
      aggregate_id: aggregate_id,
      op: op,
      payload: payload,
      status: "pending"
    })
    |> Repo.insert()
  end

  @doc """
  Drain up to `limit` pending outbox rows once. Returns the count of rows whose
  status was advanced (done or failed). Transiently-deferred rows are not
  counted.

  Each batch is read inside a transaction with `FOR UPDATE SKIP LOCKED` so
  concurrent drainers (multiple web pods) never grab the same row. Options:

    * `:limit` — max rows per drain (default #{@default_limit}).
  """
  @spec drain_once(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def drain_once(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    started = System.monotonic_time()

    try do
      result =
        Repo.transaction(fn ->
          rows = lock_pending(limit)
          count = Enum.reduce(rows, 0, fn row, acc -> acc + process_row(row) end)
          count
        end)

      public_result =
        case result do
          {:ok, count} ->
            {:ok, count}

          other ->
            other
        end

      outcome = if match?({:ok, _}, public_result), do: "ok", else: "error"
      Telemetry.emit_operation(:reconcile, outcome, System.monotonic_time() - started)
      public_result
    rescue
      e ->
        Telemetry.emit_operation(:reconcile, "error", System.monotonic_time() - started)
        Logger.error("bridge_for_teams.salix_reconcile.failed", error_class: "internal")
        {:error, {:exception, e}}
    end
  end

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = Application.get_env(:bridge_for_teams_core, __MODULE__, [])

    state = %{
      interval: opts[:interval_ms] || cfg[:interval_ms] || 5_000,
      limit: opts[:limit] || cfg[:limit] || @default_limit,
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true))
    }

    if state.enabled, do: schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = drain_once(limit: state.limit)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :drain, interval)

  # ---- Draining -----------------------------------------------------------

  defp lock_pending(limit) do
    from(r in ReconcileOutbox,
      where: r.status == "pending",
      order_by: [asc: r.created_at],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.all()
  end

  # Returns 1 if the row's status advanced (done/failed), 0 if left pending.
  defp process_row(%ReconcileOutbox{} = row) do
    base = %{aggregate: row.aggregate, aggregate_id: row.aggregate_id, op: row.op}

    case apply_op(row.op, normalize(row.payload)) do
      {:ok, _} ->
        CommaLog.log("reconcile_applied", base)
        mark(row, "done", nil)
        1

      {:error, reason} ->
        if transient_reason?(row.op, reason) do
          retry_reason = transient_retry_reason(reason)
          CommaLog.log("reconcile_deferred", Map.put(base, :reason, retry_reason))
          defer(row, retry_reason)
          0
        else
          CommaLog.log("reconcile_failed", Map.put(base, :reason, reason))

          row
          |> mark("failed", inspect(reason))
          |> maybe_record_reconcile_failure(reason)

          1
        end

      :unknown_op ->
        CommaLog.log("reconcile_failed", Map.put(base, :reason, :unknown_op))

        row
        |> mark("failed", "unknown op #{inspect(row.op)}")
        |> maybe_record_reconcile_failure(:unknown_op)

        1
    end
  end

  defp transient_reason?(_op, {:transient, _reason}), do: true
  defp transient_reason?(_op, reason) when reason in @transient, do: true

  defp transient_reason?(_op, _reason), do: false

  defp transient_retry_reason({:transient, reason}), do: reason
  defp transient_retry_reason(reason), do: reason

  defp apply_op("create_tenant", payload) do
    Client.impl().create_tenant(fetch(payload, "attrs", %{}))
  end

  defp apply_op("ensure_tenant_config", payload) do
    case fetch(payload, "org_id") do
      org_id when is_binary(org_id) and org_id != "" ->
        TenantConfig.reconcile_ensure_org(org_id)

      _missing ->
        {:error, :missing_org_id}
    end
  end

  defp apply_op("create_group", payload) do
    Client.impl().create_group(fetch(payload, "attrs", %{}))
  end

  defp apply_op("delete_group_im_connects", payload) do
    case Client.impl().delete_group_im_connects(
           fetch(payload, "tenant_id"),
           fetch(payload, "group_id")
         ) do
      :ok ->
        {:ok, :deleted}

      {:error, reason}
      when reason in [:not_found, :invalid_connect_record, :connect_scan_limit_exceeded] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:transient, reason}}
    end
  end

  defp apply_op("update_group", payload) do
    Client.impl().update_group(
      fetch(payload, "group_id"),
      fetch(payload, "tenant_id"),
      fetch(payload, "attrs", %{})
    )
  end

  defp apply_op("create_owned_agent", payload) do
    attrs = fetch(payload, "attrs", %{})
    create_agent_with(attrs, fn attrs -> Client.impl().create_owned_agent(attrs) end)
  end

  defp apply_op("create_agent", payload) do
    attrs = fetch(payload, "attrs", %{})

    case create_agent(attrs) do
      {:ok, _agent} = created ->
        maybe_apply_created_external_binding(created, payload, attrs)

      other ->
        other
    end
  end

  # Product-wide VM policy remains a BFT operation. Its immutable delivery
  # command does not write or read an Agent configuration snapshot in BFT.
  defp apply_op(
         "apply_product_vm_default",
         %{"attrs" => %{"vm" => %{"enabled" => enabled}}} = payload
       )
       when is_boolean(enabled) do
    Client.impl().configure_agent(fetch(payload, "agent_id"), fetch(payload, "tenant_id"), %{
      "vm" => %{"enabled" => enabled}
    })
    |> case do
      {:error, reason}
      when reason in [:agent_archived, :agent_archiving, :agent_permanently_archived] ->
        {:ok, :skipped_archived_agent}

      result ->
        result
    end
  end

  defp apply_op("update_agent", payload) do
    agent_id = fetch(payload, "agent_id")
    tenant_id = fetch(payload, "tenant_id")
    attrs = fetch(payload, "attrs", %{})

    case Client.impl().update_agent(agent_id, tenant_id, attrs) do
      # Enabling VM with no configured provider (tenant or platform default)
      # fails soft: drop the VM request so the rest of the update still lands
      # and the agent simply stays VM-less until a provider is configured.
      {:error, {:bad_request, message}} = error ->
        stripped = Map.delete(attrs, "vm")

        cond do
          not vm_config_missing?(message) -> error
          not Map.has_key?(attrs, "vm") -> error
          stripped == %{} -> :ok
          true -> Client.impl().update_agent(agent_id, tenant_id, stripped)
        end

      result ->
        result
    end
  end

  defp apply_op("apply_external_worker_binding", payload) do
    Client.impl().apply_external_worker_binding(
      fetch(payload, "agent_id"),
      fetch(payload, "tenant_id"),
      fetch(payload, "runtime_config", %{})
    )
  end

  defp apply_op(_unknown, _payload), do: :unknown_op

  defp create_agent(attrs),
    do: create_agent_with(attrs, fn attrs -> Client.impl().create_agent(attrs) end)

  defp create_agent_with(attrs, create) do
    case create.(attrs) do
      # A VM-enabled swarm whose tenant (and the platform) has no VM provider
      # configured would otherwise strand its router: default-on VM must not
      # block provisioning. Retry once without the VM request — the agent comes
      # up VM-less, and enabling VM later (once a provider is configured) is an
      # ordinary update.
      {:error, {:bad_request, message}} = error ->
        if vm_config_missing?(message) and Map.has_key?(attrs, "vm") do
          create.(Map.delete(attrs, "vm"))
        else
          error
        end

      result ->
        result
    end
  end

  defp maybe_apply_created_external_binding(created, payload, attrs) do
    case fetch(payload, "external_binding") do
      binding when is_map(binding) ->
        Client.impl().apply_external_worker_binding(
          fetch(attrs, "agent_id"),
          fetch(attrs, "tenant_id"),
          binding
        )

      _ ->
        created
    end
  end

  # Salix's "vm.enabled requires tenant vm provider configuration[: provider]".
  defp vm_config_missing?(message) when is_binary(message),
    do: String.contains?(message, "vm provider configuration")

  defp vm_config_missing?(_message), do: false

  # ---- Row updates --------------------------------------------------------

  # `last_error` is a varchar(255) column and reasons are inspect/1 of arbitrary
  # terms (nested erpc errors easily exceed that). An oversized write aborts the
  # whole drain transaction (Postgres 22001), rolling back every row update and
  # wedging the queue at attempts=0 — clamp before writing.
  @last_error_limit 255

  defp clamp_error(nil), do: nil
  defp clamp_error(text) when is_binary(text), do: String.slice(text, 0, @last_error_limit)

  defp mark(row, status, last_error) do
    row
    |> ReconcileOutbox.changeset(%{
      status: status,
      attempts: row.attempts + 1,
      last_error: clamp_error(last_error),
      processed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp defer(row, reason) do
    row
    |> ReconcileOutbox.changeset(%{
      status: "pending",
      attempts: row.attempts + 1,
      last_error: clamp_error("transient: #{inspect(reason)}")
    })
    |> Repo.update()
  end

  defp maybe_record_reconcile_failure({:ok, %ReconcileOutbox{} = row}, reason) do
    case reconcile_scope(row) do
      nil ->
        :ok

      scope ->
        case Observability.create_event(reconcile_failure_event_attrs(row, reason, scope)) do
          {:ok, _event} ->
            :ok

          {:error, event_reason} ->
            Logger.warning(
              "reconcile_failure_observability_failed row_id=#{row.id} reason=#{inspect(event_reason)}"
            )

            :ok
        end
    end
  end

  defp maybe_record_reconcile_failure(_result, _reason), do: :ok

  defp reconcile_scope(%ReconcileOutbox{aggregate: "organization", aggregate_id: org_id})
       when is_binary(org_id) do
    with {:ok, org_id} <- cast_uuid(org_id),
         %Organization{} = org <- Repo.get(Organization, org_id) do
      %{
        org_id: org.id,
        project_id: nil,
        domain: "org",
        resource_type: "salix_tenant",
        resource_id: org.salix_tenant_id || org.id,
        resource_label: org.name
      }
    else
      _ -> nil
    end
  end

  defp reconcile_scope(%ReconcileOutbox{aggregate: "project", aggregate_id: project_id})
       when is_binary(project_id) do
    with {:ok, project_id} <- cast_uuid(project_id),
         %Project{} = project <- Repo.get(Project, project_id) do
      %{
        org_id: project.org_id,
        project_id: project.id,
        domain: "project",
        resource_type: "salix_group",
        resource_id: project.salix_group_id || project.id,
        resource_label: project.name
      }
    else
      _ -> nil
    end
  end

  defp reconcile_scope(%ReconcileOutbox{aggregate: "agent", aggregate_id: agent_id})
       when is_binary(agent_id) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         %Project{} = project <- Repo.get(Project, agent.project_id) do
      %{
        org_id: project.org_id,
        project_id: project.id,
        domain: "agent",
        resource_type: "salix_agent",
        resource_id: agent.salix_agent_id || agent.id,
        resource_label: agent.salix["name"] || agent.role || agent.salix_agent_id
      }
    else
      _ -> nil
    end
  end

  defp reconcile_scope(_row), do: nil

  defp cast_uuid(value), do: Ecto.UUID.cast(value)

  defp reconcile_failure_event_attrs(%ReconcileOutbox{} = row, reason, scope) do
    reason_class = reconcile_reason_class(reason)

    %{
      org_id: scope.org_id,
      project_id: scope.project_id,
      domain: scope.domain,
      resource_type: scope.resource_type,
      resource_id: scope.resource_id,
      source: "salix.control",
      event_type: "salix.reconcile.failed",
      severity: "error",
      status: "failed",
      reason_class: reason_class,
      summary: "Salix reconcile #{row.op} failed for #{scope.resource_label || row.aggregate}",
      evidence: %{
        aggregate: row.aggregate,
        aggregate_id: row.aggregate_id,
        op: row.op,
        attempts: to_string(row.attempts),
        reason_class: reason_class,
        reconcile_outbox_id: row.id
      },
      correlation_id: "reconcile:#{row.id}",
      occurred_at: row.processed_at || DateTime.utc_now()
    }
  end

  defp reconcile_reason_class(:unknown_op), do: "unknown_op"
  defp reconcile_reason_class(:invalid_role), do: "validation_failed"
  defp reconcile_reason_class(:not_found), do: "not_found"
  defp reconcile_reason_class(:conflict), do: "conflict"
  defp reconcile_reason_class(:precondition_failed), do: "conflict"
  defp reconcile_reason_class({:precondition_failed, _detail}), do: "conflict"
  defp reconcile_reason_class({:http, status}) when is_integer(status), do: "provider_http_error"
  defp reconcile_reason_class({:error, reason}), do: reconcile_reason_class(reason)
  defp reconcile_reason_class({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp reconcile_reason_class(reason) when is_atom(reason), do: to_string(reason)
  defp reconcile_reason_class(reason) when is_binary(reason) and reason != "", do: reason
  defp reconcile_reason_class(_reason), do: "runtime"

  # JSONB round-trips to string keys; accept atom-keyed payloads too (enqueue
  # from inside a transaction may pass atoms before a re-read).
  defp normalize(nil), do: %{}
  defp normalize(payload) when is_map(payload), do: payload

  defp fetch(payload, key, default \\ nil) do
    Map.get(payload, key, Map.get(payload, safe_atom(key), default))
  end

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :"#{key}__missing"
  end
end
