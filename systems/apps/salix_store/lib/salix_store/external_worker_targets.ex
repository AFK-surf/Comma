defmodule SalixStore.ExternalWorkerTargets do
  @moduledoc """
  Project-scoped read and validation owner for Agent VMM External Workers.

  The projection is deliberately UI-shaped and bounded. Compute lifecycle and
  provider-private observations remain owned by their existing domains; this
  module only decides whether one current Workload is a legal External Worker
  target for an exact tenant/project/group/provider scope.
  """

  import Ecto.Query

  alias SalixStore.{AgentVMM, Compute, Repo}

  @max_limit 50
  @providers %{
    "claude" => "external.claude",
    "codex" => "external.codex",
    "pi" => "external.pi"
  }

  @type scope :: %{
          required(:tenant_id) => String.t(),
          required(:owner_type) => String.t(),
          required(:owner_id) => String.t(),
          required(:group_id) => String.t(),
          required(:provider) => String.t()
        }

  @doc "Select one exact existing Workload, deriving its provider inside the target owner."
  def select(tenant_id, group_id, project_id, workload_id, fence) do
    with %Compute.Workload{} = workload <- Repo.get(Compute.Workload, workload_id),
         provider when is_binary(provider) <- provider_for_template(workload.template_key) do
      validate(
        %{
          tenant_id: tenant_id,
          group_id: group_id,
          owner_type: "project",
          owner_id: project_id,
          provider: provider
        },
        workload_id,
        fence
      )
    else
      _ -> {:error, :target_not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Return one opaque-keyset page for an exact BFT Project scope."
  @spec page(scope(), keyword()) :: {:ok, map()} | {:error, atom()}
  def page(scope, opts \\ [])

  def page(scope, opts) when is_map(scope) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @max_limit)

    with {:ok, scope} <- normalize_scope(scope),
         true <- (is_integer(limit) and limit in 1..@max_limit) || {:error, :invalid_query},
         {:ok, cursor} <- decode_cursor(Keyword.get(opts, :cursor)),
         {:ok, query} <- normalize_query(Keyword.get(opts, :query)),
         {:ok, node_id} <- optional_string(Keyword.get(opts, :node_id)),
         {:ok, include_unavailable} <-
           include_unavailable(Keyword.get(opts, :include_unavailable, false)) do
      rows =
        page_query(scope, node_id, query, cursor, limit + 1)
        |> Repo.all()

      page = Enum.take(rows, limit)
      items = page |> Enum.map(&project/1) |> filter_unavailable(include_unavailable)

      {:ok,
       %{
         read_at: DateTime.utc_now(),
         items: items,
         next_cursor: if(length(rows) > limit, do: encode_cursor(List.last(page)), else: nil)
       }}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def page(_, _), do: {:error, :invalid_query}

  @doc "Validate an echoed selection fence against the exact current target."
  @spec validate(scope(), String.t(), map()) :: {:ok, map()} | {:error, atom() | tuple()}
  def validate(scope, workload_id, selection_fence)
      when is_map(scope) and is_binary(workload_id) and is_map(selection_fence) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, row} <- exact_row(scope, workload_id),
         item <- project(row),
         true <-
           canonical_fence(selection_fence) == item.selection_fence ||
             {:error, :selection_changed},
         true <- item.selectable || {:error, {:target_unavailable, item.reason}} do
      {:ok, item}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def validate(_, _, _), do: {:error, :invalid_query}

  @doc "Resolve immutable scope/provider facts for Agent Control apply."
  @spec validate_binding(scope(), String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_binding(scope, workload_id) when is_map(scope) and is_binary(workload_id) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, row} <- exact_row(scope, workload_id),
         nil <- selection_reason(row) do
      {:ok,
       %{
         workload_id: row.workload_id,
         provider: provider_for_template(row.template_key),
         owner_scope: %{type: "project", id: row.owner_id},
         group_id: row.registration_group_id
       }}
    else
      reason when is_binary(reason) -> {:error, reason_atom(reason)}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def validate_binding(_, _), do: {:error, :invalid_query}

  @doc "Return exact current Compute facts used by dispatch without N+1 reads."
  @spec current(scope(), String.t()) :: {:ok, map()} | {:error, atom()}
  def current(scope, workload_id) when is_map(scope) and is_binary(workload_id) do
    with {:ok, scope} <- normalize_scope(scope),
         {:ok, row} <- exact_row(scope, workload_id) do
      {:ok, %{row: row, item: project(row)}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def current(_, _), do: {:error, :invalid_query}

  defp exact_row(scope, workload_id) do
    query = from(row in subquery(base_query(scope)), where: row.workload_id == ^workload_id)

    case Repo.one(query) do
      nil -> classify_missing_scope(scope, workload_id)
      row -> {:ok, row}
    end
  end

  # The lateral candidate is a deliberate query boundary. It lets PostgreSQL
  # walk the Environment keyset index and stop at the page bound before loading
  # the wider current-state projection. All scope predicates remain inside the
  # same SQL statement; the outer joins only hydrate at most `limit` candidates.
  defp page_query(scope, node_id, search, cursor, limit) do
    template_key = Map.fetch!(@providers, scope.provider)
    membership = candidate_membership_query(scope, node_id)

    candidates =
      from(w in Compute.Workload,
        as: :candidate,
        where:
          w.environment_id == parent_as(:environment).id and
            w.kind == "external_worker" and w.template_key == ^template_key and
            w.desired_state == "ready" and
            exists(subquery(membership)),
        select: %{
          workload_id: w.id,
          workload_kind: w.kind,
          template_key: w.template_key,
          workload_desired_state: w.desired_state,
          workload_observed_state: w.observed_state,
          workload_generation: w.generation,
          workload_revision: w.revision,
          workload_updated_at: w.updated_at,
          allocation_id: w.allocation_id
        }
      )
      |> apply_candidate_search(search, scope)
      |> apply_candidate_cursor(cursor)
      |> order_by([w], desc: w.updated_at, desc: w.id)
      |> limit(^limit)

    from(e in Compute.Environment,
      as: :environment,
      inner_lateral_join: candidate in subquery(candidates),
      on: true,
      join: a in Compute.Allocation,
      on: a.id == candidate.allocation_id and a.environment_id == e.id,
      join: b in Compute.ProviderBinding,
      on:
        b.id == a.provider_binding_id and b.environment_id == e.id and
          b.provider == "agent_vmm",
      join: registration in AgentVMM.Registration,
      on:
        registration.id == b.provider_ref and registration.tenant_id == e.tenant_id and
          registration.group_id == ^scope.group_id,
      left_join: runtime in Compute.RuntimeInstance,
      on:
        runtime.workload_id == candidate.workload_id and runtime.allocation_id == a.id and
          runtime.generation == candidate.workload_generation,
      left_join: claim in Compute.ReconcilerClaim,
      on:
        claim.provider == "agent_vmm" and claim.workload_id == candidate.workload_id and
          claim.generation == candidate.workload_generation,
      where:
        e.tenant_id == ^scope.tenant_id and e.owner_type == ^scope.owner_type and
          e.owner_id == ^scope.owner_id,
      order_by: [desc: candidate.workload_updated_at, desc: candidate.workload_id],
      select: %{
        workload_id: candidate.workload_id,
        workload_kind: candidate.workload_kind,
        workload_template_key: candidate.template_key,
        template_key: candidate.template_key,
        workload_desired_state: candidate.workload_desired_state,
        workload_observed_state: candidate.workload_observed_state,
        workload_generation: candidate.workload_generation,
        workload_revision: candidate.workload_revision,
        workload_updated_at: candidate.workload_updated_at,
        environment_id: e.id,
        owner_id: e.owner_id,
        environment_desired_state: e.desired_state,
        environment_observed_state: e.observed_state,
        environment_generation: e.generation,
        environment_revision: e.revision,
        provider_binding_status: b.status,
        provider_binding_generation: b.generation,
        provider_binding_revision: b.revision,
        allocation_id: a.id,
        allocation_status: a.status,
        allocation_generation: a.generation,
        allocation_revision: a.revision,
        registration_id: registration.id,
        registration_device_id: registration.device_id,
        registration_group_id: registration.group_id,
        registration_status: registration.status,
        registration_desired_enabled: registration.desired_enabled,
        runtime_instance_id: runtime.id,
        runtime_status: runtime.status,
        runtime_readiness: runtime.readiness,
        runtime_generation: runtime.generation,
        runtime_revision: runtime.revision,
        runtime_connection_epoch: runtime.connection_epoch,
        runtime_caught_up_epoch: runtime.caught_up_epoch,
        current_container_id: fragment("?->'current_container'->>'id'", a.provider_observation),
        current_container_instance_id:
          fragment("?->'current_container'->>'instance_id'", a.provider_observation),
        current_container_status: fragment("?->>'container_status'", a.provider_observation),
        current_container_observed:
          fragment("jsonb_exists(?, 'current_container')", a.provider_observation),
        reconcile_error: claim.last_error
      }
    )
  end

  defp candidate_membership_query(scope, node_id) do
    query =
      from(a in Compute.Allocation,
        join: b in Compute.ProviderBinding,
        on:
          b.id == a.provider_binding_id and b.environment_id == a.environment_id and
            b.provider == "agent_vmm",
        join: registration in AgentVMM.Registration,
        on:
          registration.id == b.provider_ref and
            registration.tenant_id == ^scope.tenant_id and
            registration.group_id == ^scope.group_id,
        where:
          a.id == parent_as(:candidate).allocation_id and
            a.environment_id == parent_as(:candidate).environment_id,
        select: 1,
        limit: 1,
        offset: 0
      )

    if is_nil(node_id),
      do: query,
      else: where(query, [_a, _b, registration], registration.id == ^node_id)
  end

  defp classify_missing_scope(scope, workload_id) do
    if Repo.exists?(
         from(w in Compute.Workload,
           join: e in Compute.Environment,
           on: e.id == w.environment_id,
           where: w.id == ^workload_id and e.tenant_id == ^scope.tenant_id
         )
       ),
       do: {:error, :scope_mismatch},
       else: {:error, :not_found}
  end

  defp base_query(scope) do
    template_key = Map.fetch!(@providers, scope.provider)

    from(w in Compute.Workload,
      join: e in Compute.Environment,
      on:
        e.id == w.environment_id and e.tenant_id == ^scope.tenant_id and
          e.owner_type == ^scope.owner_type and e.owner_id == ^scope.owner_id,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id and a.environment_id == e.id,
      join: b in Compute.ProviderBinding,
      on:
        b.id == a.provider_binding_id and b.environment_id == e.id and
          b.provider == "agent_vmm",
      join: registration in AgentVMM.Registration,
      on:
        registration.id == b.provider_ref and registration.tenant_id == e.tenant_id and
          registration.group_id == ^scope.group_id,
      left_join: runtime in Compute.RuntimeInstance,
      on:
        runtime.workload_id == w.id and runtime.allocation_id == a.id and
          runtime.generation == w.generation,
      left_join: claim in Compute.ReconcilerClaim,
      on:
        claim.provider == "agent_vmm" and claim.workload_id == w.id and
          claim.generation == w.generation,
      where: w.kind == "external_worker" and w.template_key == ^template_key,
      select: %{
        workload_id: w.id,
        workload_kind: w.kind,
        workload_template_key: w.template_key,
        template_key: w.template_key,
        workload_desired_state: w.desired_state,
        workload_observed_state: w.observed_state,
        workload_generation: w.generation,
        workload_revision: w.revision,
        workload_updated_at: w.updated_at,
        environment_id: e.id,
        owner_id: e.owner_id,
        environment_desired_state: e.desired_state,
        environment_observed_state: e.observed_state,
        environment_generation: e.generation,
        environment_revision: e.revision,
        provider_binding_status: b.status,
        provider_binding_generation: b.generation,
        provider_binding_revision: b.revision,
        allocation_id: a.id,
        allocation_status: a.status,
        allocation_generation: a.generation,
        allocation_revision: a.revision,
        registration_id: registration.id,
        registration_device_id: registration.device_id,
        registration_group_id: registration.group_id,
        registration_status: registration.status,
        registration_desired_enabled: registration.desired_enabled,
        runtime_instance_id: runtime.id,
        runtime_status: runtime.status,
        runtime_readiness: runtime.readiness,
        runtime_generation: runtime.generation,
        runtime_revision: runtime.revision,
        runtime_connection_epoch: runtime.connection_epoch,
        runtime_caught_up_epoch: runtime.caught_up_epoch,
        current_container_id: fragment("?->'current_container'->>'id'", a.provider_observation),
        current_container_instance_id:
          fragment("?->'current_container'->>'instance_id'", a.provider_observation),
        current_container_status: fragment("?->>'container_status'", a.provider_observation),
        current_container_observed:
          fragment("jsonb_exists(?, 'current_container')", a.provider_observation),
        reconcile_error: claim.last_error
      }
    )
  end

  defp project(row) do
    reason = selection_reason(row)
    {availability, availability_issue} = availability(row, reason)

    %{
      workload_id: row.workload_id,
      label:
        "#{provider_label(provider_for_template(row.template_key))} 工作负载 · #{short(row.workload_id)}",
      provider: provider_for_template(row.template_key),
      node: %{id: row.registration_id, label: node_label(row)},
      selectable: is_nil(reason),
      reason: reason,
      availability: availability,
      availability_issue: availability_issue,
      reconcile_error: AgentVMM.project_reconcile_error(row.reconcile_error),
      updated_at: row.workload_updated_at,
      selection_fence: %{
        environment_generation: row.environment_generation,
        allocation_id: row.allocation_id,
        allocation_generation: row.allocation_generation,
        workload_generation: row.workload_generation
      }
    }
  end

  defp selection_reason(row) do
    cond do
      is_nil(provider_for_template(row.template_key)) ->
        "provider_unsupported"

      row.registration_desired_enabled != true ->
        "registration_unavailable"

      row.provider_binding_generation != row.environment_generation ->
        "binding_unavailable"

      row.environment_desired_state != "ready" ->
        "environment_not_ready"

      row.allocation_status in ["released", "failed"] or
          row.allocation_generation != row.environment_generation ->
        "allocation_not_ready"

      row.workload_desired_state != "ready" ->
        "workload_not_ready"

      true ->
        nil
    end
  end

  defp availability(_row, reason) when is_binary(reason), do: {"action_required", reason}

  defp availability(row, nil) do
    cond do
      is_map(row.reconcile_error) and row.reconcile_error["code"] == "runtime_recovery_expired" ->
        {"starting", "runtime_recovery_expired"}

      row.registration_status != "ready" ->
        {"action_required", "registration_unavailable"}

      row.provider_binding_status != "available" ->
        {"action_required", "binding_unavailable"}

      row.environment_observed_state != "ready" ->
        {"action_required", "environment_not_ready"}

      is_map(row.reconcile_error) and row.reconcile_error["kind"] == "action_required" ->
        {"action_required", row.reconcile_error["code"] || "provider_action_required"}

      row.current_container_observed and
          row.current_container_status in ["absent", "created", "stopped"] ->
        {"sleeping", nil}

      row.current_container_status == "running" and is_binary(row.current_container_id) and
        is_binary(row.current_container_instance_id) and
        row.runtime_generation == row.workload_generation and
        row.runtime_status == "connected" and row.runtime_readiness == "ready" and
          row.runtime_connection_epoch == row.runtime_caught_up_epoch ->
        {"ready", nil}

      is_nil(row.runtime_instance_id) ->
        if(row.current_container_status == "running",
          do: {"action_required", "runtime_not_connected"},
          else: {"starting", nil}
        )

      row.runtime_generation != row.workload_generation ->
        {"action_required", "runtime_generation_mismatch"}

      row.runtime_status != "connected" ->
        {"action_required", "runtime_not_connected"}

      row.runtime_readiness != "ready" ->
        {"starting", "runtime_not_ready"}

      row.runtime_connection_epoch != row.runtime_caught_up_epoch ->
        {"starting", "runtime_catching_up"}

      true ->
        {"starting", nil}
    end
  end

  defp reason_atom("registration_unavailable"), do: :registration_unavailable
  defp reason_atom("binding_unavailable"), do: :binding_unavailable
  defp reason_atom("environment_not_ready"), do: :environment_not_ready
  defp reason_atom("allocation_not_ready"), do: :allocation_not_ready
  defp reason_atom("workload_not_ready"), do: :workload_not_ready
  defp reason_atom("provider_unsupported"), do: :provider_unsupported
  defp reason_atom(_reason), do: :unavailable

  defp normalize_scope(scope) do
    scope = Map.new(scope, fn {key, value} -> {normalize_key(key), value} end)

    with tenant_id when is_binary(tenant_id) and tenant_id != "" <- scope[:tenant_id],
         "project" <- scope[:owner_type],
         owner_id when is_binary(owner_id) and owner_id != "" <- scope[:owner_id],
         group_id when is_binary(group_id) and group_id != "" <- scope[:group_id],
         provider when is_map_key(@providers, provider) <- scope[:provider] do
      {:ok,
       %{
         tenant_id: tenant_id,
         owner_type: "project",
         owner_id: owner_id,
         group_id: group_id,
         provider: provider
       }}
    else
      _ -> {:error, :invalid_query}
    end
  end

  @scope_keys %{
    "tenant_id" => :tenant_id,
    "owner_type" => :owner_type,
    "owner_id" => :owner_id,
    "group_id" => :group_id,
    "provider" => :provider
  }

  @fence_keys %{
    "environment_revision" => :environment_revision,
    "environment_generation" => :environment_generation,
    "provider_binding_revision" => :provider_binding_revision,
    "allocation_id" => :allocation_id,
    "allocation_revision" => :allocation_revision,
    "allocation_generation" => :allocation_generation,
    "workload_revision" => :workload_revision,
    "workload_generation" => :workload_generation,
    "runtime_instance_id" => :runtime_instance_id,
    "runtime_revision" => :runtime_revision,
    "runtime_connection_epoch" => :runtime_connection_epoch
  }

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@scope_keys, key, key)

  defp optional_string(nil), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) and byte_size(value) in 1..256,
    do: {:ok, value}

  defp optional_string(_), do: {:error, :invalid_query}

  defp include_unavailable(value) when is_boolean(value), do: {:ok, value}
  defp include_unavailable(_value), do: {:error, :invalid_query}

  defp filter_unavailable(items, true), do: items
  defp filter_unavailable(items, false), do: Enum.filter(items, & &1.selectable)

  defp normalize_query(nil), do: {:ok, nil}

  defp normalize_query(value) when is_binary(value) do
    value = String.trim(value)
    if byte_size(value) <= 128, do: {:ok, value}, else: {:error, :invalid_query}
  end

  defp normalize_query(_), do: {:error, :invalid_query}

  defp apply_candidate_search(query, value, _scope) when value in [nil, ""], do: query

  defp apply_candidate_search(query, value, scope) do
    prefix = escaped_prefix(value)
    registration_match = candidate_registration_search_query(scope, prefix)

    where(
      query,
      [w],
      ilike(w.id, ^prefix) or exists(subquery(registration_match))
    )
  end

  defp candidate_registration_search_query(scope, prefix) do
    candidate_membership_query(scope, nil)
    |> where(
      [_a, _b, registration],
      ilike(registration.id, ^prefix) or ilike(registration.device_id, ^prefix)
    )
  end

  defp apply_candidate_cursor(query, nil), do: query

  defp apply_candidate_cursor(query, {updated_at, workload_id}) do
    where(
      query,
      [w],
      w.updated_at < ^updated_at or (w.updated_at == ^updated_at and w.id < ^workload_id)
    )
  end

  defp escaped_prefix(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> Kernel.<>("%")
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"updated_at" => updated_at, "workload_id" => workload_id}} <- Jason.decode(json),
         {:ok, updated_at, 0} <- DateTime.from_iso8601(updated_at),
         true <- is_binary(workload_id) and workload_id != "" do
      {:ok, {updated_at, workload_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_), do: {:error, :invalid_cursor}

  defp encode_cursor(row) do
    Jason.encode!(%{
      "updated_at" => DateTime.to_iso8601(row.workload_updated_at),
      "workload_id" => row.workload_id
    })
    |> Base.url_encode64(padding: false)
  end

  defp canonical_fence(fence) do
    Map.new(fence, fn {key, value} -> {normalize_fence_key(key), value} end)
    |> Map.take(
      ~w(environment_generation allocation_id allocation_generation workload_generation)a
    )
  rescue
    _ -> %{}
  end

  defp normalize_fence_key(key) when is_atom(key), do: key
  defp normalize_fence_key(key) when is_binary(key), do: Map.get(@fence_keys, key, key)

  defp provider_for_template("external.claude"), do: "claude"
  defp provider_for_template("external.codex"), do: "codex"
  defp provider_for_template("external.pi"), do: "pi"
  defp provider_for_template(_), do: nil

  defp provider_label("claude"), do: "Claude"
  defp provider_label("codex"), do: "Codex"
  defp provider_label("pi"), do: "Pi"

  defp node_label(%{registration_device_id: id}) when is_binary(id) and id != "", do: id
  defp node_label(row), do: short(row.registration_id)

  defp short(value) when byte_size(value) <= 12, do: value
  defp short(value), do: String.slice(value, -12, 12)
end
