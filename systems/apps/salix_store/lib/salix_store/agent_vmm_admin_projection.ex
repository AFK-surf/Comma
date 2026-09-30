defmodule SalixStore.AgentVMMAdminProjection do
  @moduledoc """
  Tenant-scoped, bounded, secret-free read model for the Agent VMM dashboard.

  This module owns the dashboard interpretation of Compute and Agent VMM facts.
  Callers receive plain serializable DTOs and never Ecto structs or provider
  payloads.
  """

  import Ecto.Query

  alias SalixStore.{AgentVMM, AgentVMMInstallations, Compute, Repo}

  @default_limit 50
  @max_limit 50
  @observation_freshness_seconds 45

  @type filters :: %{optional(String.t()) => String.t() | boolean()}
  @type cursor :: map()

  @spec overview(String.t(), filters()) :: {:ok, map()} | {:error, atom()}
  def overview(tenant_id, filters \\ %{}) when is_binary(tenant_id) and is_map(filters) do
    with {:ok, filters} <- normalize_filters(filters) do
      registration_query =
        apply_registration_filters(from(r in AgentVMM.Registration), tenant_id, filters)

      registration_counts =
        Repo.all(
          from(r in registration_query,
            group_by: r.status,
            select: {r.status, count(r.id)}
          )
        )
        |> Map.new()

      disconnected_or_stale =
        registration_query
        |> where(
          [r, ...],
          r.id in subquery(
            registration_ids("disconnected", tenant_id)
            |> union_all(^registration_ids("stale", tenant_id))
          )
        )
        |> select([r, ...], count(r.id, :distinct))
        |> Repo.one()
        |> Kernel.||(0)

      unknown_outcomes =
        from(r in AgentVMM.Registration,
          join: b in Compute.ProviderBinding,
          on: b.provider_ref == r.id and b.provider == "agent_vmm",
          join: e in Compute.Environment,
          on: e.id == b.environment_id and e.tenant_id == r.tenant_id,
          join: a in Compute.Allocation,
          on: a.provider_binding_id == b.id,
          join: c in Compute.Command,
          on: c.allocation_id == a.id,
          where: c.status == "unknown_outcome"
        )
        |> apply_registration_filters(tenant_id, filters)
        |> select([_r, _b, _e, _a, c], count(c.id))
        |> Repo.one()
        |> Kernel.||(0)

      draining =
        from(r in AgentVMM.Registration,
          join: b in Compute.ProviderBinding,
          on: b.provider_ref == r.id and b.provider == "agent_vmm",
          join: e in Compute.Environment,
          on: e.id == b.environment_id and e.tenant_id == r.tenant_id,
          join: a in Compute.Allocation,
          on: a.provider_binding_id == b.id,
          join: w in Compute.Workload,
          on: w.allocation_id == a.id,
          where: w.desired_state == "draining" or w.observed_state == "draining"
        )
        |> apply_registration_filters(tenant_id, filters)
        |> select([_r, _b, _e, _a, w], count(w.id))
        |> Repo.one()
        |> Kernel.||(0)

      total = Enum.sum(Map.values(registration_counts))
      needs_attention = count_attention_nodes(tenant_id, filters)

      {:ok,
       %{
         "total" => total,
         "ready" => total - needs_attention,
         "needs_attention" => needs_attention,
         "disabled" => Map.get(registration_counts, "disabled", 0),
         "revoked" => Map.get(registration_counts, "revoked", 0),
         "enrolling" => Map.get(registration_counts, "enrolling", 0),
         "draining" => draining,
         "disconnected_or_stale" => disconnected_or_stale,
         "unknown_outcome" => unknown_outcomes
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec page_nodes(String.t(), filters(), cursor() | nil, pos_integer()) ::
          {:ok, %{nodes: [map()], next_cursor: cursor() | nil}} | {:error, atom()}
  def page_nodes(tenant_id, filters \\ %{}, cursor \\ nil, limit \\ @default_limit)

  def page_nodes(tenant_id, filters, cursor, limit)
      when is_binary(tenant_id) and is_map(filters) and is_integer(limit) and
             limit in 1..@max_limit do
    with {:ok, filters} <- normalize_filters(filters),
         {:ok, cursor} <- normalize_cursor(cursor) do
      priorities = node_priority_registrations()

      query =
        from(r in AgentVMM.Registration,
          left_join: p in subquery(priorities),
          on: p.registration_id == r.id and p.tenant_id == r.tenant_id,
          where: r.tenant_id == ^tenant_id
        )
        |> apply_registration_filters(tenant_id, filters)
        |> apply_node_cursor(cursor)
        |> order_by(
          [r, p],
          asc:
            fragment(
              "CASE WHEN ? IN ('enrolling','disabled','revoked') THEN 0 ELSE COALESCE(?, 4) END",
              r.status,
              p.rank
            ),
          desc: r.updated_at,
          desc: r.id
        )
        |> limit(^(limit + 1))
        |> select([r, p], {
          r,
          fragment(
            "CASE WHEN ? IN ('enrolling','disabled','revoked') THEN 0 ELSE COALESCE(?, 4) END",
            r.status,
            p.rank
          )
        })

      rows = Repo.all(query)
      page = Enum.take(rows, limit)
      ids = Enum.map(page, fn {registration, _rank} -> registration.id end)
      summaries = summaries(tenant_id, ids)

      nodes =
        Enum.map(page, fn {registration, _rank} ->
          project_node(registration, summaries)
        end)

      next_cursor =
        if length(rows) > limit do
          {registration, rank} = List.last(page)

          %{
            "rank" => rank,
            "updated_at" => DateTime.to_iso8601(registration.updated_at),
            "id" => registration.id
          }
        end

      {:ok, %{nodes: nodes, next_cursor: next_cursor}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def page_nodes(_tenant_id, _filters, _cursor, _limit), do: {:error, :invalid_query}

  @spec get_node(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def get_node(tenant_id, registration_id)
      when is_binary(tenant_id) and is_binary(registration_id) do
    case page_nodes(tenant_id, %{"registration_id" => registration_id}, nil, 1) do
      {:ok, %{nodes: [node]}} ->
        case node_environments(tenant_id, registration_id) do
          {:ok, environments} -> {:ok, Map.put(node, "environments", environments)}
          {:error, _} = error -> error
        end

      {:ok, %{nodes: []}} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp node_environments(tenant_id, registration_id) do
    rows =
      Repo.all(
        from(e in Compute.Environment,
          join: b in Compute.ProviderBinding,
          on:
            b.environment_id == e.id and b.provider == "agent_vmm" and
              b.provider_ref == ^registration_id,
          left_join: a in Compute.Allocation,
          on: a.provider_binding_id == b.id,
          left_join: w in Compute.Workload,
          on: w.allocation_id == a.id,
          left_join: r in Compute.RuntimeInstance,
          on: r.workload_id == w.id and r.allocation_id == a.id,
          where: e.tenant_id == ^tenant_id,
          group_by: [e.id, b.status],
          order_by: [desc: e.updated_at, desc: e.id],
          limit: 51,
          select: %{
            "id" => e.id,
            "owner_type" => e.owner_type,
            "owner_id" => e.owner_id,
            "desired_state" => e.desired_state,
            "observed_state" => e.observed_state,
            "generation" => e.generation,
            "revision" => e.revision,
            "binding_status" => b.status,
            "allocations" => count(a.id, :distinct),
            "workloads" => count(w.id, :distinct),
            "runtimes" => count(r.id, :distinct),
            "updated_at" => e.updated_at
          }
        )
      )

    if length(rows) <= 50, do: {:ok, rows}, else: {:error, :projection_too_large}
  end

  @spec page_workloads(String.t(), String.t(), cursor() | nil, pos_integer()) ::
          {:ok, %{workloads: [map()], next_cursor: cursor() | nil}} | {:error, atom()}
  def page_workloads(tenant_id, registration_id, cursor \\ nil, limit \\ @default_limit)

  def page_workloads(tenant_id, registration_id, cursor, limit)
      when is_binary(tenant_id) and is_binary(registration_id) and is_integer(limit) and
             limit in 1..@max_limit do
    with :ok <- registration_exists(tenant_id, registration_id),
         {:ok, cursor} <- normalize_simple_cursor(cursor) do
      base =
        from(w in Compute.Workload,
          join: e in Compute.Environment,
          on: e.id == w.environment_id,
          join: a in Compute.Allocation,
          on: a.id == w.allocation_id,
          join: b in Compute.ProviderBinding,
          on:
            b.id == a.provider_binding_id and b.provider == "agent_vmm" and
              b.provider_ref == ^registration_id,
          left_join: r in Compute.RuntimeInstance,
          on: r.workload_id == w.id and r.allocation_id == a.id,
          left_join: claim in Compute.ReconcilerClaim,
          on:
            claim.provider == "agent_vmm" and claim.workload_id == w.id and
              claim.generation == w.generation,
          where: e.tenant_id == ^tenant_id,
          group_by: [w.id, e.id, a.id, claim.last_error],
          order_by: [desc: w.updated_at, desc: w.id],
          select: %{
            "id" => w.id,
            "environment_id" => e.id,
            "allocation_id" => a.id,
            "kind" => w.kind,
            "template_key" => w.template_key,
            "desired_state" => w.desired_state,
            "observed_state" => w.observed_state,
            "generation" => w.generation,
            "allocation_status" => a.status,
            "operation_outcome" => a.operation_outcome,
            "runtime_status" => filter(max(r.status), r.generation == w.generation),
            "runtime_readiness" => filter(max(r.readiness), r.generation == w.generation),
            "generation_consistency" =>
              fragment(
                "CASE WHEN count(?) = 0 THEN 'not_reported' WHEN bool_and(? = ?) THEN 'current' ELSE 'mismatch' END",
                r.id,
                r.generation,
                w.generation
              ),
            "reconcile_error" => claim.last_error,
            "updated_at" => w.updated_at
          }
        )

      query = apply_simple_cursor(base, cursor, :workload) |> limit(^(limit + 1))

      rows =
        Enum.map(
          Repo.all(query),
          &Map.update!(&1, "reconcile_error", fn error ->
            AgentVMM.project_reconcile_error(error)
          end)
        )

      page = Enum.take(rows, limit)

      {:ok,
       %{
         workloads: page,
         next_cursor: if(length(rows) > limit, do: simple_cursor(List.last(page)), else: nil)
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def page_workloads(_, _, _, _), do: {:error, :invalid_query}

  @spec page_operations(String.t(), String.t(), cursor() | nil, pos_integer()) ::
          {:ok, %{operations: [map()], next_cursor: cursor() | nil}} | {:error, atom()}
  def page_operations(tenant_id, registration_id, cursor \\ nil, limit \\ @default_limit)

  def page_operations(tenant_id, registration_id, cursor, limit)
      when is_binary(tenant_id) and is_binary(registration_id) and is_integer(limit) and
             limit in 1..@max_limit do
    with :ok <- registration_exists(tenant_id, registration_id),
         {:ok, cursor} <- normalize_simple_cursor(cursor) do
      base =
        from(c in Compute.Command,
          join: a in Compute.Allocation,
          on: a.id == c.allocation_id,
          join: b in Compute.ProviderBinding,
          on:
            b.id == a.provider_binding_id and b.provider == "agent_vmm" and
              b.provider_ref == ^registration_id,
          join: e in Compute.Environment,
          on: e.id == a.environment_id,
          where: e.tenant_id == ^tenant_id,
          order_by: [desc: c.updated_at, desc: c.id],
          select: %{
            "id" => c.id,
            "allocation_id" => c.allocation_id,
            "workload_id" => c.workload_id,
            "kind" => c.kind,
            "classification" => c.classification,
            "status" => c.status,
            "outcome" => c.outcome,
            "duration_ms" =>
              type(
                fragment(
                  "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)) * 1000)::bigint",
                  c.updated_at,
                  c.created_at
                ),
                :integer
              ),
            "issue" =>
              fragment(
                "CASE WHEN ? = 'unknown_outcome' THEN 'command_unknown_outcome' WHEN ? = 'failed' THEN 'command_failed' ELSE NULL END",
                c.status,
                c.status
              ),
            "deadline_at" => c.deadline_at,
            "created_at" => c.created_at,
            "updated_at" => c.updated_at
          }
        )

      query = apply_simple_cursor(base, cursor, :operation) |> limit(^(limit + 1))
      rows = Repo.all(query)
      page = Enum.take(rows, limit)

      {:ok,
       %{
         operations: page,
         next_cursor: if(length(rows) > limit, do: simple_cursor(List.last(page)), else: nil)
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def page_operations(_, _, _, _), do: {:error, :invalid_query}

  @spec page_activity(String.t(), String.t(), cursor() | nil, pos_integer()) ::
          {:ok, %{activity: [map()], next_cursor: cursor() | nil}} | {:error, atom()}
  def page_activity(tenant_id, registration_id, cursor \\ nil, limit \\ @default_limit)

  def page_activity(tenant_id, registration_id, cursor, limit)
      when is_binary(tenant_id) and is_binary(registration_id) and is_integer(limit) and
             limit in 1..@max_limit do
    with :ok <- registration_exists(tenant_id, registration_id),
         {:ok, cursor} <- normalize_activity_cursor(cursor) do
      query =
        from(a in AgentVMM.AuditEvent,
          where:
            a.tenant_id == ^tenant_id and a.subject_type == "registration" and
              a.subject_id == ^registration_id,
          order_by: [desc: a.created_at, desc: a.id],
          select: %{
            "id" => a.id,
            "subject" => "registration",
            "action" =>
              fragment(
                "CASE WHEN ? IN ('enroll', 'revoked', 'connection_observed') THEN ? ELSE 'unknown_event' END",
                a.action,
                a.action
              ),
            "outcome" =>
              fragment(
                "CASE WHEN ? = 'succeeded' THEN 'succeeded' WHEN ? = 'failed' THEN 'failed' ELSE 'unknown' END",
                a.outcome,
                a.outcome
              ),
            "issue" =>
              fragment(
                "CASE WHEN ? = 'failed' THEN 'binding_unavailable' ELSE NULL END",
                a.outcome
              ),
            "created_at" => a.created_at
          }
        )
        |> apply_activity_cursor(cursor)
        |> limit(^(limit + 1))

      rows = Repo.all(query)
      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          row = List.last(page)

          %{
            "rank" => 0,
            "updated_at" => DateTime.to_iso8601(row["created_at"]),
            "id" => Integer.to_string(row["id"])
          }
        end

      {:ok, %{activity: page, next_cursor: next_cursor}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def page_activity(_, _, _, _), do: {:error, :invalid_query}

  defp summaries(_tenant_id, []), do: empty_summaries()

  defp summaries(tenant_id, ids) do
    %{
      bindings: binding_summaries(tenant_id, ids),
      observations: observation_summaries(tenant_id, ids),
      work: work_summaries(tenant_id, ids),
      commands: command_summaries(tenant_id, ids),
      sessions: session_summaries(tenant_id, ids),
      installs: installation_summaries(tenant_id, ids)
    }
  end

  defp empty_summaries,
    do: %{
      bindings: %{},
      observations: %{},
      work: %{},
      commands: %{},
      sessions: %{},
      installs: %{}
    }

  defp observation_summaries(tenant_id, ids) do
    Repo.all(
      from(o in AgentVMM.RegistrationObservation,
        join: r in AgentVMM.Registration,
        on: r.id == o.registration_id,
        where: r.tenant_id == ^tenant_id and o.registration_id in ^ids,
        select: {o.registration_id, o}
      )
    )
    |> Map.new()
  end

  defp binding_summaries(tenant_id, ids) do
    Repo.all(
      from(b in Compute.ProviderBinding,
        join: e in Compute.Environment,
        on: e.id == b.environment_id,
        where: e.tenant_id == ^tenant_id and b.provider == "agent_vmm" and b.provider_ref in ^ids,
        group_by: b.provider_ref,
        select: {
          b.provider_ref,
          %{
            count: count(b.id),
            available: filter(count(b.id), b.status == "available"),
            reported:
              filter(
                count(b.id),
                fragment("NULLIF(?->>'connection_epoch', '') IS NOT NULL", b.observation)
              ),
            last_observed_at: max(b.updated_at),
            inventory_watermark: max(e.inventory_watermark)
          }
        }
      )
    )
    |> Map.new()
  end

  defp work_summaries(tenant_id, ids) do
    Repo.all(
      from(b in Compute.ProviderBinding,
        join: e in Compute.Environment,
        on: e.id == b.environment_id,
        left_join: a in Compute.Allocation,
        on: a.provider_binding_id == b.id,
        left_join: w in Compute.Workload,
        on: w.allocation_id == a.id,
        left_join: r in Compute.RuntimeInstance,
        on: r.workload_id == w.id and r.allocation_id == a.id,
        where: e.tenant_id == ^tenant_id and b.provider == "agent_vmm" and b.provider_ref in ^ids,
        group_by: b.provider_ref,
        select: {
          b.provider_ref,
          %{
            environments: count(e.id, :distinct),
            allocations: count(a.id, :distinct),
            workloads: count(w.id, :distinct),
            draining:
              filter(
                count(w.id, :distinct),
                w.desired_state == "draining" or w.observed_state == "draining"
              ),
            ready_workloads: filter(count(w.id, :distinct), w.observed_state == "ready"),
            runtimes: filter(count(r.id, :distinct), r.generation == w.generation),
            ready_runtimes:
              filter(
                count(r.id, :distinct),
                r.generation == w.generation and r.readiness == "ready"
              ),
            runtime_generation_mismatch:
              filter(count(r.id, :distinct), r.generation != w.generation)
          }
        }
      )
    )
    |> Map.new()
  end

  defp command_summaries(tenant_id, ids) do
    Repo.all(
      from(c in Compute.Command,
        join: a in Compute.Allocation,
        on: a.id == c.allocation_id,
        join: b in Compute.ProviderBinding,
        on: b.id == a.provider_binding_id,
        join: e in Compute.Environment,
        on: e.id == a.environment_id,
        where: e.tenant_id == ^tenant_id and b.provider == "agent_vmm" and b.provider_ref in ^ids,
        group_by: b.provider_ref,
        select: {
          b.provider_ref,
          %{
            active: filter(count(c.id), c.status in ["pending", "admitted", "executing"]),
            failed: filter(count(c.id), c.status == "failed"),
            unknown_outcome: filter(count(c.id), c.status == "unknown_outcome"),
            oldest_active_at:
              filter(min(c.created_at), c.status in ["pending", "admitted", "executing"])
          }
        }
      )
    )
    |> Map.new()
  end

  defp session_summaries(tenant_id, ids) do
    current_fences = current_session_fences()

    Repo.all(
      from(s in AgentVMM.Session,
        join: r in AgentVMM.Registration,
        on: r.id == s.registration_id,
        join: current in subquery(current_fences),
        on:
          current.registration_id == s.registration_id and
            current.tenant_id == r.tenant_id and
            current.gateway_instance_id == s.gateway_instance_id and
            current.connection_epoch == s.connection_epoch,
        where: r.tenant_id == ^tenant_id and s.registration_id in ^ids,
        group_by: s.registration_id,
        select: {
          s.registration_id,
          %{
            count: count(s.id),
            ready: filter(count(s.id), s.status == "ready"),
            disconnected: filter(count(s.id), s.status == "disconnected"),
            expires_at: max(s.expires_at),
            updated_at: max(s.updated_at)
          }
        }
      )
    )
    |> Map.new()
  end

  defp installation_summaries(tenant_id, ids) do
    Repo.all(
      from(o in AgentVMMInstallations.Operation,
        where: o.tenant_id == ^tenant_id and o.registration_id in ^ids,
        select: {
          o.registration_id,
          %{
            id: o.id,
            status: o.authorization_status,
            revision: o.revision,
            ticket_status: o.ticket_status,
            error_code: o.error_code,
            retryable:
              o.delivery_target_type == "bft_runner" and
                o.authorization_status == "action_required" and
                o.error_code == "ticket_retry_exhausted" and
                is_nil(o.material_handed_off_at),
            issue:
              fragment(
                "CASE WHEN ? = 'action_required' THEN 'install_action_required' ELSE NULL END",
                o.authorization_status
              ),
            updated_at: o.updated_at
          }
        }
      )
    )
    |> Map.new()
  end

  defp project_node(registration, summaries) do
    binding = Map.get(summaries.bindings, registration.id, default_binding())
    observation = Map.get(summaries.observations, registration.id)
    work = Map.get(summaries.work, registration.id, default_work())
    commands = Map.get(summaries.commands, registration.id, default_commands())
    session = Map.get(summaries.sessions, registration.id, default_session())
    install = Map.get(summaries.installs, registration.id)

    connection_status =
      cond do
        is_nil(observation) ->
          "not_reported"

        not is_nil(observation.disconnected_at) ->
          "disconnected"

        DateTime.compare(
          observation.received_at,
          DateTime.add(DateTime.utc_now(), -@observation_freshness_seconds, :second)
        ) == :lt ->
          "stale"

        true ->
          "connected"
      end

    issue =
      top_issue(registration, install, binding, observation, connection_status, work, commands)

    %{
      "id" => registration.id,
      "device_id" => registration.device_id,
      "group_id" => registration.group_id,
      "status" => overall_status(registration, issue, work),
      "issue" => issue,
      "updated_at" => registration.updated_at,
      "registration" => %{
        "status" => registration.status,
        "desired_enabled" => registration.desired_enabled,
        "revision" => registration.revision,
        "policy_revision" => registration.policy_revision
      },
      "installation" => map_string_keys(install),
      "connection" => %{
        "status" => connection_status,
        "last_observed_at" => if(observation, do: observation.observed_at),
        "received_at" => if(observation, do: observation.received_at),
        "gateway_instance_id" => if(observation, do: observation.gateway_instance_id),
        "binding_count" => binding.count,
        "available_bindings" => binding.available,
        "inventory_watermark" =>
          if(observation, do: observation.inventory_watermark, else: binding.inventory_watermark),
        "protocol_version" => if(observation, do: observation.protocol_version),
        "host_api_version" => if(observation, do: observation.host_api_version),
        "connector_release" => if(observation, do: observation.connector_release),
        "supported_features" => if(observation, do: observation.supported_features, else: []),
        "capacity" => if(observation, do: observation.capacity),
        "health" =>
          if(observation,
            do: %{
              "status" => observation.health_status,
              "issue" => observation.health_issue,
              "message" => observation.health_message,
              "components" => observation.health_components
            }
          ),
        "usage" => if(observation, do: observation.usage)
      },
      "work" => map_string_keys(work),
      "operations" => map_string_keys(commands),
      "session" => map_string_keys(session)
    }
  end

  defp top_issue(registration, install, binding, observation, connection_status, work, commands) do
    cond do
      install && install.status == "action_required" -> "install_action_required"
      registration.status == "enrolling" -> "registration_enrolling"
      registration.status == "disabled" -> "registration_disabled"
      registration.status == "revoked" -> "registration_revoked"
      commands.unknown_outcome > 0 -> "command_unknown_outcome"
      commands.failed > 0 -> "command_failed"
      is_nil(observation) -> "observation_missing"
      connection_status == "stale" -> "observation_stale"
      connection_status == "disconnected" -> "binding_unavailable"
      observation.health_status == "unavailable" -> "host_unavailable"
      observation.health_status == "degraded" -> "host_degraded"
      binding.available < binding.count -> "binding_unavailable"
      work.draining > 0 -> "workload_not_converged"
      work.workloads > work.ready_workloads -> "workload_not_converged"
      work.runtime_generation_mismatch > 0 -> "runtime_not_ready"
      work.runtimes > work.ready_runtimes -> "runtime_not_ready"
      true -> nil
    end
  end

  defp overall_status(registration, issue, work) do
    cond do
      registration.status in ["enrolling", "disabled", "revoked"] ->
        "action_required"

      issue in ["command_unknown_outcome", "command_failed", "binding_unavailable"] ->
        "unavailable"

      work.draining > 0 ->
        "draining"

      issue in ["workload_not_converged", "runtime_not_ready"] ->
        "degraded"

      is_nil(issue) ->
        "ready"

      true ->
        "unknown"
    end
  end

  defp unknown_command_registrations do
    from(c in Compute.Command,
      join: a in Compute.Allocation,
      on: a.id == c.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      where: c.status == "unknown_outcome",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp failed_command_registrations do
    from(c in Compute.Command,
      join: a in Compute.Allocation,
      on: a.id == c.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      where: c.status == "failed",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp unavailable_binding_registrations do
    from(b in Compute.ProviderBinding,
      join: e in Compute.Environment,
      on: e.id == b.environment_id,
      where: b.provider == "agent_vmm" and b.status != "available",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp draining_workload_registrations do
    from(w in Compute.Workload,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      where: w.desired_state == "draining" or w.observed_state == "draining",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp unconverged_workload_registrations do
    from(w in Compute.Workload,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      where: w.observed_state != "ready",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp unready_runtime_registrations do
    from(runtime in Compute.RuntimeInstance,
      join: a in Compute.Allocation,
      on: a.id == runtime.allocation_id,
      join: w in Compute.Workload,
      on: w.id == runtime.workload_id and w.allocation_id == a.id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      where: runtime.generation != w.generation or runtime.readiness != "ready",
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp action_required_install_registrations do
    from(o in AgentVMMInstallations.Operation,
      where: o.authorization_status == "action_required" and not is_nil(o.registration_id),
      group_by: [o.tenant_id, o.registration_id],
      select: %{tenant_id: o.tenant_id, registration_id: o.registration_id}
    )
  end

  defp unreported_registration_registrations do
    reported = observed_registration_registrations()

    from(r in AgentVMM.Registration,
      left_join: reported in subquery(reported),
      on: reported.registration_id == r.id and reported.tenant_id == r.tenant_id,
      where: is_nil(reported.registration_id),
      select: %{tenant_id: r.tenant_id, registration_id: r.id}
    )
  end

  defp health_observation_registrations(status) do
    from(o in AgentVMM.RegistrationObservation,
      join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      where: o.health_status == ^status,
      select: %{tenant_id: r.tenant_id, registration_id: o.registration_id}
    )
  end

  defp observed_registration_registrations do
    from(o in AgentVMM.RegistrationObservation,
      join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      select: %{tenant_id: r.tenant_id, registration_id: o.registration_id}
    )
  end

  defp disconnected_observation_registrations do
    from(o in AgentVMM.RegistrationObservation,
      join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      where: not is_nil(o.disconnected_at),
      select: %{tenant_id: r.tenant_id, registration_id: o.registration_id}
    )
  end

  defp stale_observation_registrations do
    deadline = DateTime.add(DateTime.utc_now(), -@observation_freshness_seconds, :second)

    from(o in AgentVMM.RegistrationObservation,
      join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      where: is_nil(o.disconnected_at) and o.received_at < ^deadline,
      select: %{tenant_id: r.tenant_id, registration_id: o.registration_id}
    )
  end

  defp connected_observation_registrations do
    deadline = DateTime.add(DateTime.utc_now(), -@observation_freshness_seconds, :second)

    from(o in AgentVMM.RegistrationObservation,
      join: r in AgentVMM.Registration,
      on: r.id == o.registration_id,
      where: is_nil(o.disconnected_at) and o.received_at >= ^deadline,
      select: %{tenant_id: r.tenant_id, registration_id: o.registration_id}
    )
  end

  defp current_session_fences do
    latest =
      from(s in AgentVMM.Session,
        join: r in AgentVMM.Registration,
        on: r.id == s.registration_id,
        distinct: [r.tenant_id, s.registration_id],
        order_by: [asc: r.tenant_id, asc: s.registration_id, desc: s.updated_at, desc: s.id],
        select: %{
          tenant_id: r.tenant_id,
          registration_id: s.registration_id,
          gateway_instance_id: s.gateway_instance_id,
          connection_epoch: s.connection_epoch
        }
      )

    reported =
      from(o in AgentVMM.RegistrationObservation,
        join: r in AgentVMM.Registration,
        on: r.id == o.registration_id,
        select: %{
          tenant_id: r.tenant_id,
          registration_id: o.registration_id,
          gateway_instance_id: o.gateway_instance_id,
          connection_epoch: o.connection_epoch
        }
      )

    from(latest in subquery(latest),
      left_join: reported in subquery(reported),
      on:
        reported.tenant_id == latest.tenant_id and
          reported.registration_id == latest.registration_id,
      select: %{
        tenant_id: latest.tenant_id,
        registration_id: latest.registration_id,
        gateway_instance_id:
          fragment("COALESCE(?, ?)", reported.gateway_instance_id, latest.gateway_instance_id),
        connection_epoch:
          fragment("COALESCE(?, ?)", reported.connection_epoch, latest.connection_epoch)
      }
    )
  end

  defp workload_registrations do
    from(w in Compute.Workload,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id and b.provider == "agent_vmm",
      join: e in Compute.Environment,
      on: e.id == a.environment_id,
      group_by: [e.tenant_id, b.provider_ref],
      select: %{tenant_id: e.tenant_id, registration_id: b.provider_ref}
    )
  end

  defp node_priority_registrations do
    sources = [
      {action_required_install_registrations(), 0},
      {unknown_command_registrations(), 1},
      {failed_command_registrations(), 2},
      {unreported_registration_registrations(), 2},
      {disconnected_observation_registrations(), 2},
      {stale_observation_registrations(), 2},
      {health_observation_registrations("unavailable"), 2},
      {health_observation_registrations("degraded"), 2},
      {unavailable_binding_registrations(), 2},
      {unready_runtime_registrations(), 2},
      {draining_workload_registrations(), 3},
      {unconverged_workload_registrations(), 3}
    ]

    union =
      Enum.reduce(sources, nil, fn {source, rank}, union ->
        ranked = ranked_priority_source(source, rank)

        if union, do: union_all(union, ^ranked), else: ranked
      end)

    from(p in subquery(union),
      group_by: [p.tenant_id, p.registration_id],
      select: %{tenant_id: p.tenant_id, registration_id: p.registration_id, rank: min(p.rank)}
    )
  end

  defp ranked_priority_source(source, 0),
    do:
      from(s in subquery(source),
        select: %{tenant_id: s.tenant_id, registration_id: s.registration_id, rank: 0}
      )

  defp ranked_priority_source(source, 1),
    do:
      from(s in subquery(source),
        select: %{tenant_id: s.tenant_id, registration_id: s.registration_id, rank: 1}
      )

  defp ranked_priority_source(source, 2),
    do:
      from(s in subquery(source),
        select: %{tenant_id: s.tenant_id, registration_id: s.registration_id, rank: 2}
      )

  defp ranked_priority_source(source, 3),
    do:
      from(s in subquery(source),
        select: %{tenant_id: s.tenant_id, registration_id: s.registration_id, rank: 3}
      )

  defp count_attention_nodes(tenant_id, filters) do
    priority = node_priority_registrations()

    from(r in AgentVMM.Registration,
      left_join: priority in subquery(priority),
      on: priority.registration_id == r.id and priority.tenant_id == r.tenant_id,
      where: r.status != "ready" or not is_nil(priority.registration_id)
    )
    |> apply_registration_filters(tenant_id, filters)
    |> select([r, ...], count(r.id, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp apply_registration_filters(query, tenant_id, filters) do
    query = where(query, [r, ...], r.tenant_id == ^tenant_id)

    query =
      maybe_where(query, filters["registration_id"], fn q, value ->
        where(q, [r, ...], r.id == ^value)
      end)

    query =
      maybe_where(query, filters["group_id"], fn q, value ->
        where(q, [r, ...], r.group_id == ^value)
      end)

    query =
      maybe_where(query, filters["status"], fn q, value ->
        where(q, [r, ...], r.status == ^value)
      end)

    query =
      case filters["desired_enabled"] do
        value when is_boolean(value) -> where(query, [r, ...], r.desired_enabled == ^value)
        _ -> query
      end

    query =
      maybe_where(query, filters["q"], fn q, value ->
        prefix = escape_like(value) <> "%"

        where(
          q,
          [r, ...],
          r.id == ^value or r.device_id == ^value or ilike(r.id, ^prefix) or
            ilike(r.device_id, ^prefix)
        )
      end)

    query = apply_connection_filter(query, tenant_id, filters["connection"])
    query = apply_work_filter(query, tenant_id, filters["work"])
    query = apply_issue_filter(query, tenant_id, filters["issue"])

    query =
      maybe_where(query, filters["updated_from"], fn q, value ->
        where(q, [r, ...], r.updated_at >= ^value)
      end)

    maybe_where(query, filters["updated_to"], fn q, value ->
      where(q, [r, ...], r.updated_at <= ^value)
    end)
  end

  defp apply_connection_filter(query, _tenant_id, nil), do: query

  defp apply_connection_filter(query, tenant_id, "disconnected"),
    do: include_source(query, tenant_id, disconnected_observation_registrations())

  defp apply_connection_filter(query, tenant_id, "not_reported") do
    exclude_source(query, tenant_id, observed_registration_registrations())
  end

  defp apply_connection_filter(query, tenant_id, "stale") do
    include_source(query, tenant_id, stale_observation_registrations())
  end

  defp apply_connection_filter(query, tenant_id, "connected") do
    include_source(query, tenant_id, connected_observation_registrations())
  end

  defp apply_work_filter(query, _tenant_id, nil), do: query

  defp apply_work_filter(query, tenant_id, "draining"),
    do: include_source(query, tenant_id, draining_workload_registrations())

  defp apply_work_filter(query, tenant_id, "active") do
    query
    |> include_source(tenant_id, workload_registrations())
    |> exclude_source(tenant_id, draining_workload_registrations())
  end

  defp apply_work_filter(query, tenant_id, "idle"),
    do: exclude_source(query, tenant_id, workload_registrations())

  defp apply_issue_filter(query, _tenant_id, nil), do: query

  defp apply_issue_filter(query, _tenant_id, issue)
       when issue in ["registration_enrolling", "registration_disabled", "registration_revoked"] do
    status = String.replace_prefix(issue, "registration_", "")
    where(query, [r, ...], r.status == ^status)
  end

  defp apply_issue_filter(query, tenant_id, "install_action_required"),
    do: include_source(query, tenant_id, action_required_install_registrations())

  defp apply_issue_filter(query, tenant_id, "command_unknown_outcome"),
    do: include_source(query, tenant_id, unknown_command_registrations())

  defp apply_issue_filter(query, tenant_id, "command_failed"),
    do: include_source(query, tenant_id, failed_command_registrations())

  defp apply_issue_filter(query, tenant_id, "binding_unavailable"),
    do: include_source(query, tenant_id, unavailable_binding_registrations())

  defp apply_issue_filter(query, tenant_id, "workload_not_converged"),
    do: include_source(query, tenant_id, unconverged_workload_registrations())

  defp apply_issue_filter(query, tenant_id, "runtime_not_ready"),
    do: include_source(query, tenant_id, unready_runtime_registrations())

  defp apply_issue_filter(query, tenant_id, "observation_missing"),
    do: exclude_source(query, tenant_id, observed_registration_registrations())

  defp apply_issue_filter(query, tenant_id, "observation_stale"),
    do: apply_connection_filter(query, tenant_id, "stale")

  defp apply_issue_filter(query, tenant_id, "host_degraded"),
    do: include_source(query, tenant_id, health_observation_registrations("degraded"))

  defp apply_issue_filter(query, tenant_id, "host_unavailable"),
    do: include_source(query, tenant_id, health_observation_registrations("unavailable"))

  defp include_source(query, tenant_id, source) do
    ids =
      from(s in subquery(source),
        where: s.tenant_id == ^tenant_id,
        select: s.registration_id
      )

    where(query, [r, ...], r.id in subquery(ids))
  end

  defp exclude_source(query, tenant_id, source) do
    ids =
      from(s in subquery(source),
        where: s.tenant_id == ^tenant_id,
        select: s.registration_id
      )

    where(query, [r, ...], r.id not in subquery(ids))
  end

  defp registration_ids("disconnected", tenant_id) do
    from(s in subquery(disconnected_observation_registrations()),
      where: s.tenant_id == ^tenant_id,
      select: %{id: s.registration_id}
    )
  end

  defp registration_ids("stale", tenant_id) do
    from(s in subquery(stale_observation_registrations()),
      where: s.tenant_id == ^tenant_id,
      select: %{id: s.registration_id}
    )
  end

  defp apply_node_cursor(query, nil), do: query

  defp apply_node_cursor(query, %{rank: rank, updated_at: updated_at, id: id}) do
    where(
      query,
      [r, p],
      fragment(
        "CASE WHEN ? IN ('enrolling','disabled','revoked') THEN 0 ELSE COALESCE(?, 4) END",
        r.status,
        p.rank
      ) > ^rank or
        (fragment(
           "CASE WHEN ? IN ('enrolling','disabled','revoked') THEN 0 ELSE COALESCE(?, 4) END",
           r.status,
           p.rank
         ) == ^rank and
           (r.updated_at < ^updated_at or (r.updated_at == ^updated_at and r.id < ^id)))
    )
  end

  defp normalize_filters(filters) do
    allowed =
      MapSet.new(
        ~w(registration_id group_id status desired_enabled q connection work issue updated_from updated_to)
      )

    if Enum.all?(Map.keys(filters), &(is_binary(&1) and MapSet.member?(allowed, &1))) do
      desired =
        case filters["desired_enabled"] do
          value when value in [true, false] -> value
          "true" -> true
          "false" -> false
          nil -> nil
          _ -> :invalid
        end

      updated_from = parse_filter_datetime(filters["updated_from"])
      updated_to = parse_filter_datetime(filters["updated_to"])

      cond do
        desired == :invalid or updated_from == :invalid or updated_to == :invalid ->
          {:error, :invalid_query}

        Enum.any?(~w(registration_id group_id status q connection work issue), fn key ->
          invalid_filter?(filters[key])
        end) ->
          {:error, :invalid_query}

        filters["connection"] not in [nil, "not_reported", "disconnected", "stale", "connected"] ->
          {:error, :invalid_query}

        filters["work"] not in [nil, "idle", "active", "draining"] ->
          {:error, :invalid_query}

        filters["issue"] not in [
          nil,
          "install_action_required",
          "registration_enrolling",
          "registration_disabled",
          "registration_revoked",
          "observation_missing",
          "observation_stale",
          "host_degraded",
          "host_unavailable",
          "binding_unavailable",
          "workload_not_converged",
          "runtime_not_ready",
          "command_failed",
          "command_unknown_outcome"
        ] ->
          {:error, :invalid_query}

        true ->
          {:ok,
           filters
           |> Map.put("desired_enabled", desired)
           |> Map.put("updated_from", updated_from)
           |> Map.put("updated_to", updated_to)}
      end
    else
      {:error, :invalid_query}
    end
  end

  defp invalid_filter?(nil), do: false
  defp invalid_filter?(value), do: not is_binary(value) or byte_size(value) > 200

  defp parse_filter_datetime(nil), do: nil

  defp parse_filter_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _ -> :invalid
    end
  end

  defp parse_filter_datetime(_), do: :invalid

  defp normalize_cursor(nil), do: {:ok, nil}

  defp normalize_cursor(%{"rank" => rank, "updated_at" => at, "id" => id})
       when is_integer(rank) and rank >= 0 and is_binary(at) and is_binary(id) and
              byte_size(id) <= 200 do
    case DateTime.from_iso8601(at) do
      {:ok, updated_at, 0} -> {:ok, %{rank: rank, updated_at: updated_at, id: id}}
      _ -> {:error, :invalid_query}
    end
  end

  defp normalize_cursor(_), do: {:error, :invalid_query}

  defp normalize_simple_cursor(nil), do: {:ok, nil}

  defp normalize_simple_cursor(%{"updated_at" => at, "id" => id})
       when is_binary(at) and is_binary(id) and byte_size(id) <= 200 do
    case DateTime.from_iso8601(at) do
      {:ok, updated_at, 0} -> {:ok, %{updated_at: updated_at, id: id}}
      _ -> {:error, :invalid_query}
    end
  end

  defp normalize_simple_cursor(%{"rank" => _, "updated_at" => _, "id" => _} = cursor),
    do: normalize_simple_cursor(Map.delete(cursor, "rank"))

  defp normalize_simple_cursor(_), do: {:error, :invalid_query}

  defp normalize_activity_cursor(cursor), do: normalize_simple_cursor(cursor)

  defp apply_simple_cursor(query, nil, _kind), do: query

  defp apply_simple_cursor(query, %{updated_at: updated_at, id: id}, :workload) do
    where(
      query,
      [w, ...],
      w.updated_at < ^updated_at or (w.updated_at == ^updated_at and w.id < ^id)
    )
  end

  defp apply_simple_cursor(query, %{updated_at: updated_at, id: id}, :operation) do
    where(
      query,
      [c, ...],
      c.updated_at < ^updated_at or (c.updated_at == ^updated_at and c.id < ^id)
    )
  end

  defp apply_activity_cursor(query, nil), do: query

  defp apply_activity_cursor(query, %{updated_at: created_at, id: id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        where(
          query,
          [a],
          a.created_at < ^created_at or (a.created_at == ^created_at and a.id < ^int_id)
        )

      _ ->
        where(query, [a], false)
    end
  end

  defp simple_cursor(row) do
    %{
      "rank" => 0,
      "updated_at" => DateTime.to_iso8601(row["updated_at"]),
      "id" => row["id"]
    }
  end

  defp registration_exists(tenant_id, registration_id) do
    if Repo.exists?(
         from(r in AgentVMM.Registration,
           where: r.tenant_id == ^tenant_id and r.id == ^registration_id
         )
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp maybe_where(query, nil, _fun), do: query
  defp maybe_where(query, "", _fun), do: query
  defp maybe_where(query, value, fun), do: fun.(query, value)

  defp escape_like(value), do: String.replace(value, ["%", "_", "\\"], &"\\#{&1}")

  defp map_string_keys(nil), do: nil
  defp map_string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp default_binding,
    do: %{count: 0, available: 0, reported: 0, last_observed_at: nil, inventory_watermark: nil}

  defp default_work,
    do: %{
      environments: 0,
      allocations: 0,
      workloads: 0,
      draining: 0,
      ready_workloads: 0,
      runtimes: 0,
      ready_runtimes: 0,
      runtime_generation_mismatch: 0
    }

  defp default_commands,
    do: %{active: 0, failed: 0, unknown_outcome: 0, oldest_active_at: nil}

  defp default_session,
    do: %{count: 0, ready: 0, disconnected: 0, expires_at: nil, updated_at: nil}
end
