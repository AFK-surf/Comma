defmodule Comma.Compute do
  @moduledoc "Comma authorization and bounded projection adapter for Salix Compute."

  alias Comma.Workspaces
  alias SalixStore.{AgentVMMInstallations, Compute}

  @permissions ~w(runtime workspace service_route hosting)

  def get(user, session, workspace_id, options \\ %{}) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, projection} <-
           Compute.project_page(workspace["salix_tenant_id"], "project", workspace_id, options) do
      {:ok, Map.put(public_projection(projection), "workspace_name", workspace["name"])}
    end
  end

  def create_environment(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, pool} <- resolve_pool(workspace["salix_tenant_id"], attrs["pool_id"]),
         {:ok, environment} <-
           Compute.ensure_environment(%{
             id: new_id("env"),
             tenant_id: workspace["salix_tenant_id"],
             owner_type: "project",
             owner_id: workspace_id,
             pool_id: pool.id,
             retention: %{"mode" => "retain"}
           }) do
      {:ok, public_environment(environment)}
    end
  end

  def request_agent_vmm_install(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, request_id} <- id(attrs["request_id"]),
         {:ok, target_id} <- session_delivery_target(session),
         {:ok, pool} <-
           Compute.ensure_managed_default_pool(workspace["salix_tenant_id"], "agent_vmm"),
         {:ok, environment} <-
           Compute.ensure_environment(%{
             id: new_id("env"),
             tenant_id: workspace["salix_tenant_id"],
             owner_type: "project",
             owner_id: workspace_id,
             pool_id: pool.id,
             retention: %{"mode" => "retain"}
           }),
         {:ok, descriptor} <-
           AgentVMMInstallations.request(%{
             tenant_id: workspace["salix_tenant_id"],
             group_id: workspace["default_group_id"],
             surface: "comma",
             scope_key: workspace_id,
             client_request_id: request_id,
             provider: "agent-vmm",
             environment_id: environment.id,
             delivery_target_type: "comma_main_device",
             delivery_target_id: target_id
           }) do
      {:ok, descriptor}
    end
  end

  def get_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, operation} <- AgentVMMInstallations.get(operation_id),
         true <-
           (operation.tenant_id == workspace["salix_tenant_id"] and
              operation.group_id == workspace["default_group_id"] and
              operation.scope_key == workspace_id and operation.surface == "comma" and
              operation.delivery_target_id == session["id"]) ||
             {:error, :not_found} do
      {:ok, operation}
    else
      {:error, _} = error -> error
    end
  end

  def retry_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, _operation} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, descriptor} <- AgentVMMInstallations.retry(operation_id) do
      {:ok, descriptor}
    end
  end

  def revoke_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, _operation} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, operation} <- AgentVMMInstallations.revoke(operation_id) do
      {:ok, operation}
    end
  end

  def configure_agent_vmm_install(
        user,
        session,
        workspace_id,
        operation_id,
        enabled
      )
      when is_boolean(enabled) do
    with {:ok, _operation} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, operation} <-
           AgentVMMInstallations.configure_registration(operation_id, enabled) do
      {:ok, operation}
    end
  end

  def initialize_agent_vmm_workload(user, session, workspace_id, operation_id) do
    with {:ok, operation} <- get_agent_vmm_install(user, session, workspace_id, operation_id),
         true <- operation.status == "ready" || {:error, :compute_node_not_ready},
         {:ok, _workload} <-
           Compute.ensure_node_workload(
             operation.tenant_id,
             operation.environment_id,
             operation.registration_id
           ) do
      {:ok, operation}
    end
  end

  def create_workload(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, environment_id} <- id(attrs["environment_id"]),
         :ok <- environment_in_scope(workspace, workspace_id, environment_id),
         {:ok, kind} <- workload_kind(attrs["kind"]),
         {:ok, template_key} <- workload_template_key(kind, attrs),
         {:ok, request_id} <- creation_request_id(attrs["request_id"]),
         placement_input = %{
           tenant_id: workspace["salix_tenant_id"],
           allocation_id: new_id("allocation"),
           workload_id: new_id("workload"),
           environment_id: environment_id,
           kind: kind,
           template_key: template_key,
           spec: attrs["spec"] || %{},
           capability_requirements: attrs["capability_requirements"] || ["runtime_exec"]
         },
         {:ok, placed} <- place_creation(workspace_id, request_id, placement_input) do
      {:ok,
       %{
         "allocation" => public_allocation(placed.allocation),
         "workload" => public_workload(placed.workload)
       }}
    end
  end

  def issue_grant(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, environment_id} <- id(attrs["environment_id"]),
         :ok <- environment_in_scope(workspace, workspace_id, environment_id),
         {:ok, principal_type} <- principal_type(attrs["principal_type"]),
         {:ok, principal_id} <- id(attrs["principal_id"]),
         {:ok, permissions} <- permissions(attrs["permissions"]),
         {:ok, ttl} <- ttl(attrs["ttl_seconds"]),
         {:ok, grant} <-
           Compute.issue_grant(%{
             id: new_id("grant"),
             tenant_id: workspace["salix_tenant_id"],
             environment_id: environment_id,
             workload_id: attrs["workload_id"],
             principal_type: principal_type,
             principal_id: principal_id,
             permissions: permissions,
             expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
           }) do
      {:ok, public_grant(grant)}
    end
  end

  def retain(user, session, workspace_id, environment_id, attrs),
    do:
      update_environment(user, session, workspace_id, environment_id, attrs, %{
        retention: %{"mode" => attrs["mode"]}
      })

  def drain(user, session, workspace_id, environment_id, attrs),
    do:
      update_environment(user, session, workspace_id, environment_id, attrs, %{
        desired_state: "draining"
      })

  def revoke(user, session, workspace_id, environment_id, attrs),
    do:
      update_environment(user, session, workspace_id, environment_id, attrs, %{
        desired_state: "revoked"
      })

  defp update_environment(user, session, workspace_id, environment_id, attrs, update) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- environment_in_scope(workspace, workspace_id, environment_id),
         {:ok, revision} <- revision(attrs["expected_revision"]),
         {:ok, environment} <- Compute.update_environment_intent(environment_id, revision, update) do
      {:ok, public_environment(environment)}
    end
  end

  def get_creation(user, session, workspace_id, request_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, request_id} <- id(request_id),
         {:ok, placed} <-
           Compute.requested_workload(
             workspace["salix_tenant_id"],
             "comma:" <> workspace_id,
             request_id
           ) do
      {:ok, %{"workload" => public_workload(placed.workload)}}
    end
  end

  # Published clients without request_id retain their existing contract. New
  # clients always send a key and never fall back to non-idempotent creation.
  defp creation_request_id(nil), do: {:ok, nil}
  defp creation_request_id(value), do: id(value)
  defp place_creation(_workspace_id, nil, input), do: Compute.place_workload(input)

  defp place_creation(workspace_id, request_id, input) do
    if not is_map(input.spec) or not is_list(input.capability_requirements) do
      {:error, :invalid}
    else
      canonical = %{
        "environment_id" => input.environment_id,
        "kind" => input.kind,
        "template_key" => input.template_key,
        "spec" => input.spec,
        "capability_requirements" => Enum.sort(Enum.uniq(input.capability_requirements))
      }

      Compute.place_requested_workload(
        Map.merge(input, %{
          creation_request_scope: "comma:" <> workspace_id,
          creation_request_id: request_id,
          creation_request_input: canonical
        })
      )
    end
  end

  defp environment_in_scope(workspace, workspace_id, environment_id),
    do:
      Compute.environment_in_scope(
        workspace["salix_tenant_id"],
        "project",
        workspace_id,
        environment_id
      )

  defp public_projection(value) do
    %{
      "environments" => Enum.map(value.environments, &public_environment/1),
      "allocations" => Enum.map(value.allocations, &public_allocation/1),
      "workloads" => Enum.map(value.workloads, &public_workload/1),
      "runtimes" => Enum.map(value.runtimes, &public_runtime/1),
      "grants" => Enum.map(value.grants, &public_grant/1),
      "next_workload_cursor" => value.next_workload_cursor
    }
  end

  defp public_environment(row),
    do:
      take(
        row,
        ~w(id pool_id desired_state observed_state generation revision retention updated_at)a
      )
      |> Map.put("can_create", Map.get(row, :can_create, false))

  defp public_allocation(row),
    do: take(row, ~w(id environment_id status operation_outcome generation revision updated_at)a)

  defp public_workload(row),
    do:
      take(
        row,
        ~w(id environment_id kind desired_state observed_state generation revision updated_at)a
      )

  defp public_runtime(row),
    do: take(row, ~w(id workload_id status readiness generation revision updated_at)a)

  defp public_grant(row),
    do:
      take(
        row,
        ~w(id environment_id workload_id principal_type principal_id permissions revision revoked_at expires_at)a
      )

  defp take(struct, fields), do: struct |> Map.from_struct() |> Map.take(fields)
  defp resolve_pool(tenant_id, nil), do: Compute.resolve_pool(tenant_id)
  defp resolve_pool(tenant_id, ""), do: Compute.resolve_pool(tenant_id)

  defp resolve_pool(tenant_id, pool_id) do
    with {:ok, normalized} <- id(pool_id), do: Compute.resolve_pool(tenant_id, normalized)
  end

  defp id(value) when is_binary(value) and byte_size(value) in 1..160, do: {:ok, value}
  defp id(_), do: {:error, :invalid_id}
  defp session_delivery_target(%{"id" => id}), do: id(id)
  defp session_delivery_target(_), do: {:error, :invalid_session}
  defp revision(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp revision(_), do: {:error, :invalid_revision}
  defp principal_type(value) when value in ["agent", "workflow", "user"], do: {:ok, value}
  defp principal_type(_), do: {:error, :invalid_principal}
  defp ttl(value) when is_integer(value) and value in 1..86_400, do: {:ok, value}
  defp ttl(nil), do: {:ok, 3_600}
  defp ttl(_), do: {:error, :invalid_expiry}

  defp permissions(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(&1 in @permissions)),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_permission}
  end

  defp permissions(_), do: {:error, :invalid_permission}

  defp workload_kind(value)
       when value in ["external_worker", "meeting_runtime", "service", "shell"],
       do: {:ok, value}

  defp workload_kind(_), do: {:error, :invalid_workload_kind}

  defp workload_template_key("shell", attrs),
    do: id(attrs["template_key"] || "shell.default")

  defp workload_template_key(_kind, attrs) do
    case attrs["template_key"] do
      nil -> {:ok, nil}
      value -> id(value)
    end
  end

  defp new_id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
end
