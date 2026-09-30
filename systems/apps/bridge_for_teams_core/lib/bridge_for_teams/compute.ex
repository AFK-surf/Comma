defmodule BridgeForTeams.Compute do
  @moduledoc "BFT project ACL and bounded projection adapter for Salix Compute."

  alias BridgeForTeams.Environments
  alias BridgeForTeams.Repo, as: BFTRepo
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{MacMiniProvisioner, Organization, Project}
  alias SalixStore.{AgentVMMInstallations, Compute, Repo}

  @permissions ~w(runtime workspace service_route hosting)

  def project(%Organization{} = org, %Project{} = project) do
    with :ok <- scope_matches(org, project),
         {:ok, projection} <- Compute.project(org.salix_tenant_id, "project", project.id, 50) do
      {:ok, public_projection(projection)}
    end
  end

  def managed_auth(%Organization{} = org, %Project{} = project, workload_id, operation, attrs)
      when operation in [:read, :bind, :unbind] and is_map(attrs) do
    with :ok <- scope_matches(org, project) do
      Client.impl().compute_managed_auth_operation(
        org.salix_tenant_id,
        project.id,
        workload_id,
        operation,
        attrs
      )
    end
  end

  def create_environment(%Organization{} = org, %Project{} = project, attrs) do
    with :ok <- scope_matches(org, project),
         {:ok, pool} <- resolve_pool(org.salix_tenant_id, attrs["pool_id"]),
         {:ok, environment} <-
           Compute.ensure_environment(%{
             id: new_id("env"),
             tenant_id: org.salix_tenant_id,
             owner_type: "project",
             owner_id: project.id,
             pool_id: pool.id,
             retention: %{"mode" => "retain"}
           }) do
      {:ok, public_environment(environment)}
    end
  end

  def create_workload(%Organization{} = org, %Project{} = project, attrs) do
    with :ok <- scope_matches(org, project),
         {:ok, environment_id} <- id(attrs["environment_id"]),
         :ok <- environment_in_scope(org, project, environment_id),
         {:ok, kind} <- workload_kind(attrs["kind"]),
         {:ok, template_key} <- workload_template_key(kind, attrs),
         {:ok, placed} <-
           Compute.place_workload(%{
             tenant_id: org.salix_tenant_id,
             allocation_id: new_id("allocation"),
             workload_id: new_id("workload"),
             environment_id: environment_id,
             kind: kind,
             template_key: template_key,
             spec: attrs["spec"] || %{},
             capability_requirements: attrs["capability_requirements"] || ["runtime_exec"]
           }) do
      {:ok,
       %{
         "allocation" => public_allocation(placed.allocation),
         "workload" => public_workload(placed.workload)
       }}
    end
  end

  def create_pool(%Organization{} = org, attrs) do
    with {:ok, name} <- id(attrs["name"]),
         {:ok, region} <- id(attrs["region"]),
         {:ok, pool} <-
           Compute.create_pool(%{
             id: new_id("pool"),
             tenant_id: org.salix_tenant_id,
             name: name,
             region: region,
             provider_policy: attrs["provider_policy"] || %{},
             capabilities: attrs["capabilities"] || [],
             capacity: attrs["capacity"] || %{},
             quota: attrs["quota"] || %{}
           }) do
      {:ok, public_pool(pool)}
    end
  end

  def update_pool(%Organization{} = org, pool_id, attrs) do
    with %Compute.Pool{tenant_id: tenant_id} <- Repo.get(Compute.Pool, pool_id),
         true <- tenant_id == org.salix_tenant_id || {:error, :forbidden},
         {:ok, expected_revision} <- revision(attrs["expected_revision"]),
         {:ok, pool} <-
           Compute.update_pool(pool_id, expected_revision, %{
             provider_policy: attrs["provider_policy"],
             capacity: attrs["capacity"],
             quota: attrs["quota"]
           }) do
      {:ok, public_pool(pool)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :forbidden}
    end
  end

  def configure_provider(%Organization{} = org, pool_id, attrs) do
    with %Compute.Pool{tenant_id: tenant_id} <- Repo.get(Compute.Pool, pool_id),
         true <- tenant_id == org.salix_tenant_id || {:error, :forbidden},
         {:ok, provider} <- id(attrs["provider"]),
         true <-
           provider == "cloudflare" ||
             {:error, :provider_managed_by_observation},
         {:ok, config_ref} <- id(attrs["config_ref"]),
         {:ok, binding} <-
           Compute.ensure_provider_binding(%{
             id: new_id("provider"),
             pool_id: pool_id,
             environment_id: attrs["environment_id"],
             provider: provider,
             provider_ref: config_ref
           }) do
      {:ok, public_provider_binding(binding)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :forbidden}
    end
  end

  def configure_default_provider(%Organization{} = org, attrs) do
    with {:ok, provider} <- id(attrs["provider"]),
         true <- provider == "cloudflare" || {:error, :environment_scope_required},
         {:ok, config_ref} <- id(attrs["config_ref"]),
         {:ok, pool} <- Compute.ensure_managed_default_pool(org.salix_tenant_id, provider),
         {:ok, binding} <-
           Compute.ensure_provider_binding(%{
             id: new_id("provider"),
             pool_id: pool.id,
             provider: provider,
             provider_ref: config_ref
           }) do
      {:ok, %{pool: public_pool(pool), provider: public_provider_binding(binding)}}
    else
      {:error, _} = error -> error
    end
  end

  def request_agent_vmm_install(%Organization{} = org, %Project{} = project, attrs) do
    with :ok <- scope_matches(org, project),
         {:ok, request_id} <- id(attrs["request_id"]),
         {:ok, runner_id} <- id(attrs["runner_id"]),
         %MacMiniProvisioner{} = runner <-
           BFTRepo.get_by(MacMiniProvisioner, org_id: org.id, stable_id: runner_id),
         "online" <- Environments.effective_mac_mini_provisioner_status(runner),
         {:ok, pool} <- Compute.ensure_managed_default_pool(org.salix_tenant_id, "agent_vmm"),
         {:ok, environment} <-
           Compute.ensure_environment(%{
             id: new_id("env"),
             tenant_id: org.salix_tenant_id,
             owner_type: "project",
             owner_id: project.id,
             pool_id: pool.id,
             retention: %{"mode" => "retain"}
           }),
         {:ok, descriptor} <-
           AgentVMMInstallations.request(%{
             tenant_id: org.salix_tenant_id,
             group_id: project.salix_group_id,
             surface: "bft",
             scope_key: project.id,
             client_request_id: request_id,
             provider: "agent-vmm",
             environment_id: environment.id,
             delivery_target_type: "bft_runner",
             delivery_target_id: runner.stable_id
           }) do
      {:ok, descriptor.operation}
    else
      nil -> {:error, :runner_not_found}
      "online" -> {:error, :runner_offline}
      status when is_binary(status) -> {:error, :runner_offline}
      {:error, _} = error -> error
    end
  end

  def get_agent_vmm_install(%Organization{} = org, %Project{} = project, operation_id) do
    with :ok <- scope_matches(org, project),
         {:ok, operation} <- AgentVMMInstallations.get(operation_id),
         true <-
           (operation.tenant_id == org.salix_tenant_id and
              operation.group_id == project.salix_group_id and
              operation.scope_key == project.id and operation.surface == "bft") ||
             {:error, :not_found} do
      {:ok, operation}
    else
      {:error, _} = error -> error
    end
  end

  def retry_agent_vmm_install(org, project, operation_id) do
    with {:ok, _operation} <- get_agent_vmm_install(org, project, operation_id),
         {:ok, descriptor} <- AgentVMMInstallations.retry(operation_id) do
      {:ok, descriptor.operation}
    end
  end

  def revoke_agent_vmm_install(org, project, operation_id) do
    with {:ok, _operation} <- get_agent_vmm_install(org, project, operation_id),
         {:ok, operation} <- AgentVMMInstallations.revoke(operation_id) do
      {:ok, operation}
    end
  end

  def configure_agent_vmm_install(org, project, operation_id, enabled)
      when is_boolean(enabled) do
    with {:ok, _operation} <- get_agent_vmm_install(org, project, operation_id),
         {:ok, operation} <-
           AgentVMMInstallations.configure_registration(operation_id, enabled) do
      {:ok, operation}
    end
  end

  def deliver_agent_vmm_install(%MacMiniProvisioner{} = runner) do
    AgentVMMInstallations.deliver_next("bft_runner", runner.stable_id)
  end

  def report_agent_vmm_install_failures(%MacMiniProvisioner{} = runner, reports)
      when is_list(reports) and length(reports) <= 8 do
    Enum.reduce_while(reports, {:ok, []}, fn report, {:ok, operation_ids} ->
      with %{"operation_id" => operation_id, "failure_code" => failure_code} <- report,
           {:ok, operation} <-
             AgentVMMInstallations.report_delivery_failure(
               "bft_runner",
               runner.stable_id,
               operation_id,
               failure_code
             ) do
        {:cont, {:ok, [operation.id | operation_ids]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_install_failure_report}}
      end
    end)
    |> case do
      {:ok, operation_ids} -> {:ok, Enum.reverse(operation_ids)}
      {:error, _} = error -> error
    end
  end

  def report_agent_vmm_install_failures(_, _),
    do: {:error, :invalid_install_failure_reports}

  def agent_vmm_control_page(%MacMiniProvisioner{} = runner, cursor) do
    AgentVMMInstallations.control_page("bft_runner", runner.stable_id, cursor)
  end

  def update_provider(%Organization{} = org, binding_id, attrs) do
    updates =
      %{status: attrs["status"]}
      |> then(fn updates ->
        if Map.has_key?(attrs, "config_ref"),
          do: Map.put(updates, :provider_ref, attrs["config_ref"]),
          else: updates
      end)

    with %Compute.ProviderBinding{} = binding <- Repo.get(Compute.ProviderBinding, binding_id),
         %Compute.Pool{tenant_id: tenant_id} <- Repo.get(Compute.Pool, binding.pool_id),
         true <- tenant_id == org.salix_tenant_id || {:error, :forbidden},
         true <-
           binding.provider != "agent_vmm" || {:error, :provider_managed_by_observation},
         {:ok, expected_revision} <- revision(attrs["expected_revision"]),
         {:ok, updated} <-
           Compute.update_provider_binding(binding_id, expected_revision, updates) do
      {:ok, public_provider_binding(updated)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :forbidden}
    end
  end

  def issue_grant(%Organization{} = org, %Project{} = project, attrs) do
    with :ok <- scope_matches(org, project),
         {:ok, environment_id} <- id(attrs["environment_id"]),
         :ok <- environment_in_scope(org, project, environment_id),
         {:ok, principal_type} <- principal_type(attrs["principal_type"]),
         {:ok, principal_id} <- id(attrs["principal_id"]),
         {:ok, permissions} <- permissions(attrs["permissions"]),
         {:ok, ttl} <- ttl(attrs["ttl_seconds"]),
         {:ok, grant} <-
           Compute.issue_grant(%{
             id: new_id("grant"),
             tenant_id: org.salix_tenant_id,
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

  def retain(org, project, environment_id, attrs),
    do:
      update_environment(org, project, environment_id, attrs, %{
        retention: %{"mode" => attrs["mode"]}
      })

  def drain(org, project, environment_id, attrs),
    do: update_environment(org, project, environment_id, attrs, %{desired_state: "draining"})

  def revoke(org, project, environment_id, attrs),
    do: update_environment(org, project, environment_id, attrs, %{desired_state: "revoked"})

  defp update_environment(org, project, environment_id, attrs, update) do
    with :ok <- scope_matches(org, project),
         :ok <- environment_in_scope(org, project, environment_id),
         {:ok, expected_revision} <- revision(attrs["expected_revision"]),
         {:ok, environment} <-
           Compute.update_environment_intent(environment_id, expected_revision, update) do
      {:ok, public_environment(environment)}
    end
  end

  defp environment_in_scope(org, project, environment_id) do
    with {:ok, value} <- Compute.project(org.salix_tenant_id, "project", project.id, 50),
         true <- Enum.any?(value.environments, &(&1.id == environment_id)) do
      :ok
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp scope_matches(%Organization{id: id}, %Project{org_id: id}), do: :ok
  defp scope_matches(_, _), do: {:error, :forbidden}

  defp public_projection(value) do
    %{
      "environments" => Enum.map(value.environments, &public_environment/1),
      "allocations" => Enum.map(value.allocations, &public_allocation/1),
      "workloads" => Enum.map(value.workloads, &public_workload/1),
      "runtimes" => Enum.map(value.runtimes, &public_runtime/1),
      "grants" => Enum.map(value.grants, &public_grant/1)
    }
  end

  defp public_environment(row),
    do:
      take(
        row,
        ~w(id pool_id desired_state observed_state generation revision retention updated_at)a
      )

  defp public_allocation(row),
    do: take(row, ~w(id environment_id status operation_outcome generation revision updated_at)a)

  defp public_workload(row),
    do:
      take(
        row,
        ~w(id environment_id kind template_key desired_state observed_state generation revision updated_at)a
      )

  defp public_runtime(row),
    do: take(row, ~w(id workload_id status readiness generation revision updated_at)a)

  defp public_grant(row),
    do:
      take(
        row,
        ~w(id environment_id workload_id principal_type principal_id permissions revision revoked_at expires_at)a
      )

  defp public_pool(row),
    do:
      take(
        row,
        ~w(id managed_key name region provider_policy capabilities capacity quota status revision updated_at)a
      )

  defp public_provider_binding(row) do
    row
    |> take(~w(id pool_id environment_id provider status generation revision updated_at)a)
    |> Map.put(:configured, is_binary(row.provider_ref) and row.provider_ref != "")
  end

  defp take(struct, fields) do
    struct
    |> Map.from_struct()
    |> Map.take(fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      {key, %NaiveDateTime{} = value} -> {key, NaiveDateTime.to_iso8601(value)}
      pair -> pair
    end)
  end

  defp resolve_pool(tenant_id, nil), do: Compute.resolve_pool(tenant_id)
  defp resolve_pool(tenant_id, ""), do: Compute.resolve_pool(tenant_id)

  defp resolve_pool(tenant_id, pool_id) do
    with {:ok, normalized} <- id(pool_id), do: Compute.resolve_pool(tenant_id, normalized)
  end

  defp id(value) when is_binary(value) and byte_size(value) in 1..160, do: {:ok, value}
  defp id(_), do: {:error, :invalid_id}
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
