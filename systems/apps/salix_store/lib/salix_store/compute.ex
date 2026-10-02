defmodule SalixStore.Compute do
  @moduledoc """
  The single provider-neutral Compute control-plane writer and SSOT.

  Stable product ownership ends at Environment and Workload IDs. Provider
  bindings, allocation generations, RuntimeInstance epochs, and command outcomes are
  fenced execution facts and are never product identity. Pool onboarding and
  binding selection remain implementation-test contracts. The retained
  `tla/salix/ComputeCapacityAction.tla` model covers the Agent VMM
  import-capacity retry boundary. It does not model the generation and
  connection-epoch transitions that this module owns.

  External worker placement is modeled in
  `tla/salix/ExternalWorkerProvisioning.tla`; the durable operation owns the
  Postgres half before AgentControl creation.
  """

  import Ecto.Query
  require Logger

  alias SalixStore.{AgentVMM, Keys, Repo, S3}
  alias SalixStore.ComputeContract
  alias SalixStore.Compute.WorkloadCredential

  @providers ~w(cloudflare agent_vmm)
  @environment_states ~w(pending ready draining stopped revoked)
  @allocation_states ~w(pending allocating ready draining released failed)
  @command_classes ~w(read_only desired_state side_effecting)
  @command_states ~w(pending admitted executing succeeded failed unknown_outcome cancelled)
  @permissions ~w(runtime workspace service_route hosting)
  @compute_capabilities ~w(runtime_exec runtime_process service_private service_public_http)
  @managed_default_key "default"
  @managed_default_name "Managed Default"
  @cloudflare_gateway_release_lock "cloudflare-gateway-release-admission"
  @cloudflare_gateway_attempt_limit 64
  @managed_provider_capabilities %{
    "agent_vmm" => ~w(runtime_exec runtime_process service_private),
    "cloudflare" => ~w(runtime_exec service_public_http)
  }
  @agent_vmm_remote_policy %{
    "per_environment_limits" => %{
      "pids" => 512,
      "disk_bytes" => 2_147_483_648
    },
    "max_egress_mode" => "public_internet",
    "stop_grace_seconds" => 10
  }
  @runtime_carrier_features [
    "runtime.input.v1",
    "runtime.event.v1",
    "runtime.execution.v1",
    "runtime.auth.v1",
    "runtime.agent_stop.v1",
    "runtime.subscription.v1"
  ]
  @binding_keys MapSet.new(~w(kind device_runtime_id workload_id runtime_spec))
  @provider_native_keys MapSet.new(
                          ~w(provider_id provider_ref allocation_id endpoint connection_epoch gateway_instance_id container_id namespace_id)
                        )

  defmodule Pool do
    use Ecto.Schema
    @primary_key false
    schema "compute_pools" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:managed_key, :string)
      field(:name, :string)
      field(:region, :string)
      field(:provider_policy, :map)
      field(:capabilities, {:array, :string})
      field(:capacity, :map)
      field(:quota, :map)
      field(:status, :string)
      field(:revision, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Environment do
    use Ecto.Schema
    @primary_key false
    schema "compute_environments" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:owner_type, :string)
      field(:owner_id, :string)
      field(:pool_id, :string)
      field(:desired_state, :string)
      field(:observed_state, :string)
      field(:generation, :integer)
      field(:revision, :integer)
      field(:retention, :map)
      field(:inventory_watermark, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ProviderBinding do
    use Ecto.Schema
    @primary_key false
    schema "compute_provider_bindings" do
      field(:id, :string, primary_key: true)
      field(:pool_id, :string)
      field(:environment_id, :string)
      field(:provider, :string)
      field(:provider_ref, :string)
      field(:status, :string)
      field(:generation, :integer)
      field(:revision, :integer)
      field(:observation, :map)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Allocation do
    use Ecto.Schema
    @primary_key false
    schema "compute_allocations" do
      field(:id, :string, primary_key: true)
      field(:environment_id, :string)
      field(:provider_binding_id, :string)
      field(:status, :string)
      field(:operation_outcome, :string)
      field(:generation, :integer)
      field(:provider_observation, :map)
      field(:revision, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Workload do
    use Ecto.Schema
    @primary_key false
    schema "compute_workloads" do
      field(:id, :string, primary_key: true)
      field(:environment_id, :string)
      field(:allocation_id, :string)
      field(:kind, :string)
      field(:spec, :map)
      field(:template_key, :string)
      field(:runtime_revision, :string)
      field(:runtime_update, :map)
      field(:creation_request_scope, :string)
      field(:creation_request_id, :string)
      field(:creation_request_input, :map)
      field(:capability_requirements, {:array, :string})
      field(:desired_state, :string)
      field(:observed_state, :string)
      field(:generation, :integer)
      field(:revision, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule RuntimeInstance do
    use Ecto.Schema
    @primary_key false
    schema "compute_runtime_instances" do
      field(:id, :string, primary_key: true)
      field(:workload_id, :string)
      field(:allocation_id, :string)
      field(:status, :string)
      field(:readiness, :string)
      field(:generation, :integer)
      field(:connection_epoch, :string)
      field(:caught_up_epoch, :string)
      field(:bootstrap_consumed_epoch, :string)
      field(:input_cursor, :string)
      field(:event_cursor, :string)
      field(:revision, :integer)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule Grant do
    use Ecto.Schema
    @primary_key false
    schema "compute_grants" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:environment_id, :string)
      field(:workload_id, :string)
      field(:principal_type, :string)
      field(:principal_id, :string)
      field(:permissions, {:array, :string})
      field(:revision, :integer)
      field(:revoked_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Command do
    use Ecto.Schema
    @primary_key false
    schema "compute_commands" do
      field(:id, :string, primary_key: true)
      field(:allocation_id, :string)
      field(:workload_id, :string)
      field(:request_id, :string)
      field(:operation_id, :string)
      field(:target_ref, :string)
      field(:kind, :string)
      field(:classification, :string)
      field(:target_generation, :integer)
      field(:target_revision, :integer)
      field(:connection_epoch, :string)
      field(:status, :string)
      field(:outcome, :string)
      field(:payload, :map)
      field(:evidence, :map)
      field(:deadline_at, :utc_datetime_usec)
      field(:release_incarnation, :string)
      field(:next_attempt_at, :utc_datetime_usec)
      field(:attempt_count, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ExternalWorkerBinding do
    use Ecto.Schema
    @primary_key false
    schema "external_worker_bindings" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:agent_id, :string)
      field(:source_kind, :string)
      field(:device_runtime_id, :string)
      field(:workload_id, :string)
      field(:runtime_spec, :map)
      field(:status, :string)
      field(:binding_revision, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ExternalWorkerOperation do
    use Ecto.Schema
    @primary_key false
    schema "external_worker_operations" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:operation_hash, :string)
      field(:tool_call_id, :string)
      field(:environment_id, :string)
      field(:provider, :string)
      field(:template_key, :string)
      field(:allocation_id, :string)
      field(:workload_id, :string)
      field(:worker_id, :string)
      field(:state, :string)
      field(:attempt_count, :integer)
      field(:next_retry_at, :utc_datetime_usec)
      field(:claim_token, :string)
      field(:lease_expires_at, :utc_datetime_usec)
      field(:last_error, :map)
      field(:revision, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ReconcilerCursor do
    use Ecto.Schema
    @primary_key false

    schema "compute_reconciler_cursors" do
      field(:id, :string, primary_key: true)
      field(:provider, :string)
      field(:cursor_tenant_id, :string)
      field(:cursor_updated_at, :utc_datetime_usec)
      field(:cursor_workload_id, :string)
      field(:high_watermark_tenant_id, :string)
      field(:high_watermark_updated_at, :utc_datetime_usec)
      field(:high_watermark_workload_id, :string)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  defmodule ReconcilerClaim do
    use Ecto.Schema
    @primary_key false

    schema "compute_reconciler_claims" do
      field(:id, :string, primary_key: true)
      field(:provider, :string)
      field(:workload_id, :string)
      field(:generation, :integer)
      field(:claim_token, :string)
      field(:attempt_count, :integer)
      field(:next_retry_at, :utc_datetime_usec)
      field(:lease_expires_at, :utc_datetime_usec)
      field(:last_error, :map)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def create_pool(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    capabilities = Map.get(attrs, :capabilities, [])

    with :ok <- required_strings(attrs, [:id, :tenant_id, :name, :region]),
         :ok <- validate_provider_policy(Map.get(attrs, :provider_policy, %{})),
         :ok <- validate_capability_requirements(capabilities) do
      insert_one(Pool, %{
        id: attrs.id,
        tenant_id: attrs.tenant_id,
        name: attrs.name,
        region: attrs.region,
        provider_policy: Map.get(attrs, :provider_policy, %{}),
        capabilities: capabilities,
        capacity: Map.get(attrs, :capacity, %{}),
        quota: Map.get(attrs, :quota, %{}),
        status: "active",
        revision: 1,
        created_at: now,
        updated_at: now
      })
    end
  end

  @doc "Materialize the one managed default Pool for an explicit provider-onboarding intent."
  def ensure_managed_default_pool(tenant_id, provider)
      when is_binary(tenant_id) and is_binary(provider) do
    with true <- tenant_id != "" || {:error, :invalid},
         true <- provider in @providers || {:error, :unsupported_provider} do
      case Repo.transaction(fn ->
             Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
               "compute-managed-default:" <> tenant_id
             ])

             case Repo.one(
                    from(p in Pool,
                      where: p.tenant_id == ^tenant_id and p.managed_key == @managed_default_key,
                      lock: "FOR UPDATE"
                    )
                  ) do
               nil ->
                 now = DateTime.utc_now()
                 id = new_compute_id("pool")

                 {1, _} =
                   Repo.insert_all(Pool, [
                     %{
                       id: id,
                       tenant_id: tenant_id,
                       managed_key: @managed_default_key,
                       name: @managed_default_name,
                       region: "auto",
                       provider_policy: %{"providers" => [provider]},
                       capabilities: Map.fetch!(@managed_provider_capabilities, provider),
                       capacity: managed_pool_capacity(provider),
                       quota: %{},
                       status: "active",
                       revision: 1,
                       created_at: now,
                       updated_at: now
                     }
                   ])

                 Repo.get!(Pool, id)

               %Pool{status: "active"} = pool ->
                 if provider_allowed?(pool, provider) do
                   ensure_managed_pool_capacity!(pool, provider)
                 else
                   Repo.rollback(:managed_pool_provider_conflict)
                 end

               %Pool{} ->
                 Repo.rollback(:managed_pool_inactive)
             end
           end) do
        {:ok, pool} -> {:ok, pool}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def ensure_managed_default_pool(_tenant_id, _provider), do: {:error, :invalid}

  @doc "Project the exact Agent VMM Host admission policy owned by an Environment's Pool."
  def agent_vmm_remote_policy(environment_id) when is_binary(environment_id) do
    case Repo.one(
           from(e in Environment,
             join: p in Pool,
             on: p.id == e.pool_id,
             where: e.id == ^environment_id and p.status == "active",
             select: {p.provider_policy, p.capacity, p.revision}
           )
         ) do
      {provider_policy, %{"agent_vmm_remote_policy" => policy}, revision}
      when is_map(policy) and is_integer(revision) and revision > 0 ->
        if "agent_vmm" in provider_policy_providers(provider_policy),
          do: {:ok, %{policy: policy, revision: revision}},
          else: {:error, :provider_not_allowed}

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :remote_policy_unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def agent_vmm_remote_policy(_), do: {:error, :invalid}

  defp managed_pool_capacity("agent_vmm"),
    do: %{"agent_vmm_remote_policy" => @agent_vmm_remote_policy}

  defp managed_pool_capacity(_), do: %{}

  defp ensure_managed_pool_capacity!(%Pool{} = pool, "agent_vmm") do
    case pool.capacity do
      %{"agent_vmm_remote_policy" => @agent_vmm_remote_policy} ->
        pool

      capacity when is_map(capacity) ->
        now = DateTime.utc_now()
        next_capacity = Map.put(capacity, "agent_vmm_remote_policy", @agent_vmm_remote_policy)

        {1, _} =
          Repo.update_all(
            from(p in Pool, where: p.id == ^pool.id and p.revision == ^pool.revision),
            set: [capacity: next_capacity, revision: pool.revision + 1, updated_at: now]
          )

        Repo.get!(Pool, pool.id)
    end
  end

  defp ensure_managed_pool_capacity!(%Pool{} = pool, _provider), do: pool

  @doc "Resolve an explicit active Pool or the already-materialized managed default."
  def resolve_pool(tenant_id, pool_id \\ nil)

  def resolve_pool(tenant_id, nil) when is_binary(tenant_id) do
    case Repo.one(
           from(p in Pool,
             where:
               p.tenant_id == ^tenant_id and p.managed_key == @managed_default_key and
                 p.status == "active"
           )
         ) do
      %Pool{} = pool -> {:ok, pool}
      nil -> {:error, :compute_pool_not_configured}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def resolve_pool(tenant_id, pool_id) when is_binary(tenant_id) and is_binary(pool_id) do
    case Repo.get(Pool, pool_id) do
      %Pool{tenant_id: ^tenant_id, status: "active"} = pool -> {:ok, pool}
      %Pool{} -> {:error, :scope_mismatch}
      nil -> {:error, :pool_not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def resolve_pool(_tenant_id, _pool_id), do: {:error, :invalid}

  def update_pool(id, expected_revision, attrs) when is_map(attrs) do
    provider_policy = Map.get(attrs, :provider_policy)
    capabilities = Map.get(attrs, :capabilities)
    capacity = Map.get(attrs, :capacity)
    quota = Map.get(attrs, :quota)

    with :ok <-
           if(is_nil(provider_policy), do: :ok, else: validate_provider_policy(provider_policy)),
         :ok <-
           if(is_nil(capabilities),
             do: :ok,
             else: validate_capability_requirements(capabilities)
           ),
         :ok <- validate_optional_map(capacity, :invalid_capacity),
         :ok <- validate_optional_map(quota, :invalid_quota) do
      changes =
        [updated_at: DateTime.utc_now()]
        |> maybe_put(:provider_policy, provider_policy)
        |> maybe_put(:capabilities, capabilities)
        |> maybe_put(:capacity, capacity)
        |> maybe_put(:quota, quota)

      case Repo.update_all(
             from(p in Pool, where: p.id == ^id and p.revision == ^expected_revision),
             set: changes,
             inc: [revision: 1]
           ) do
        {1, _} -> {:ok, Repo.get!(Pool, id)}
        {0, _} -> {:error, :revision_conflict}
      end
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # Group runtime facts reuse Workload and Allocation. The compatibility-shaped
  # return value is a projection for current product callers, never stored JSON.
  @group_device_fields ~w(env_id device_id connector_id alias name workspace_dir)
  @group_archive_fields ~w(archive_diagnostics wake_requested_at archive_started_at archive archive_ref connector_archive archive_operation_id archive_reason archive_progress archive_cancel_requested archive_last_operation archived_at wake_operation_id last_wake_at archive_gc_operations archive_previous connector_archive_previous)
  @group_activity_fields ~w(active_operations last_operation_at last_operation_result last_vm_operation_agent_id last_agent_settled_after_vm_at)
  @group_runtime_fields ~w(runtime_targets runtime_connector runtime_activity runtime_idle runtime_idle_token runtime_selection_until runtime_wake_at runtime_wake_claim cloudflare_control)
  @group_provider_fields ~w(provider_resource_id provider_resource_name provider_spec current_worker_version_id desired_worker_version_id worker_release_id worker_release_kind rollout_state cloudflare_worker operation_drain_summary)
  @group_lifecycle_fields ~w(provider_migration node_id attempt_at ready_at error last_error billing_decision last_metered_at created_by_agent_id)

  @doc "Read the Group's default Workload through its indexed owner relationship."
  def group_workload(group_id) when is_binary(group_id) do
    with :ok <- SalixStore.ComputeMigration.ensure_open(),
         {:ok, environment, workload, allocation, binding} <- group_workload_rows(group_id) do
      {:ok, group_workload_projection(environment, workload, allocation, binding)}
    end
  rescue
    ArgumentError -> {:error, :invalid_group}
  end

  @doc "Resolve Group Compute ownership without treating an unreadable Workload as absent."
  @spec group_provider_ownership(String.t(), String.t()) ::
          {:managed, map()} | :unmanaged | {:error, :group_workload_unavailable}
  def group_provider_ownership(tenant_id, group_id)
      when is_binary(tenant_id) and is_binary(group_id) do
    if SalixStore.Ids.tenant_id_from_group!(group_id) == tenant_id do
      case group_workload(group_id) do
        {:ok, %{"tenant_id" => ^tenant_id} = workload} ->
          {:managed, workload}

        {:ok, _} ->
          {:error, :group_workload_unavailable}

        {:error, _} ->
          # A missing join or an unreadable handoff marker cannot establish
          # absence. Only the indexed owner row can prove this Group unmanaged.
          if Repo.exists?(
               from(e in Environment,
                 where:
                   e.tenant_id == ^tenant_id and e.owner_type == "group" and
                     e.owner_id == ^group_id
               )
             ),
             do: {:error, :group_workload_unavailable},
             else: :unmanaged
      end
    else
      {:error, :group_workload_unavailable}
    end
  rescue
    _ -> {:error, :group_workload_unavailable}
  end

  def group_provider_ownership(_, _), do: {:error, :group_workload_unavailable}

  @doc "Check the exact Group/Device admission hold after a provider cutover."
  def group_provider_mutation_admission(tenant_id, group_id, device_id)
      when is_binary(device_id) do
    case group_provider_ownership(tenant_id, group_id) do
      {:managed,
       %{
         "device_id" => ^device_id,
         "provider" => "cloudflare",
         "provider_migration" => %{
           "phase" => "committed",
           "archive_hold" => "awaiting_durable_archive"
         }
       }} ->
        {:error, :provider_cutover_archive_pending}

      {:managed,
       %{
         "provider_migration" => %{
           "phase" => "committed",
           "archive_hold" => "awaiting_durable_archive"
         }
       }} ->
        {:error, :group_workload_unavailable}

      {:managed, _} ->
        :ok

      :unmanaged ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  def group_provider_mutation_admission(_, _, _), do: {:error, :group_workload_unavailable}

  @doc "Create a Group default only after the release handoff has admitted this writer."
  def ensure_group_workload(facts) do
    with :ok <- SalixStore.ComputeMigration.ensure_open(), do: do_ensure_group_workload(facts)
  end

  @doc false
  def import_group_workload(facts) do
    with :ok <- SalixStore.ComputeMigration.ensure_copying(),
         :ok <- validate_group_import(facts) do
      do_ensure_group_workload(facts)
    end
  end

  def validate_group_import(facts) when is_map(facts) do
    allowed =
      @group_device_fields ++
        @group_archive_fields ++
        @group_activity_fields ++
        @group_runtime_fields ++
        @group_provider_fields ++
        @group_lifecycle_fields ++
        ~w(tenant_id group_id provider status created_at schema_version active_operation_count)

    unknown = Map.keys(facts) -- allowed

    cond do
      unknown != [] ->
        {:error, {:unmapped_group_fields, Enum.sort(unknown)}}

      facts["provider"] != "cloudflare" ->
        {:error, :unsupported_provider}

      facts["status"] not in ~w(creating ready failed absent archived archiving waking billing_suspended eligible_for_resume) ->
        {:error, :unsupported_group_state}

      true ->
        :ok
    end
  end

  def validate_group_import(_), do: {:error, :invalid_group_workload}

  defp do_ensure_group_workload(
         %{"tenant_id" => tenant, "group_id" => group, "provider" => provider} = facts
       )
       when provider == "cloudflare" do
    if SalixStore.Ids.valid_group_id_for_tenant?(group, tenant) do
      Repo.transaction(fn ->
        # Pool acquisition comes first for every Group, so concurrent Groups
        # cannot deadlock while materializing their shared provider Pool.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "group-compute-pool:" <> tenant <> ":" <> provider
        ])

        pool = ensure_group_pool!(tenant, provider)

        environment =
          group_result!(
            ensure_environment(%{
              id: new_compute_id("env"),
              tenant_id: tenant,
              owner_type: "group",
              owner_id: group,
              pool_id: pool.id
            })
          )

        Repo.one!(from(e in Environment, where: e.id == ^environment.id, lock: "FOR UPDATE"))

        case group_workload_rows(group) do
          {:ok, e, w, a, b} ->
            {group_workload_projection(e, w, a, b), :existing}

          {:error, :not_found} ->
            binding =
              group_result!(
                ensure_provider_binding(%{
                  id: new_compute_id("binding"),
                  pool_id: pool.id,
                  environment_id: environment.id,
                  provider: provider,
                  provider_ref: facts["provider_resource_id"] || facts["provider_resource_name"]
                })
              )

            allocation =
              group_result!(
                allocate(%{
                  id: new_compute_id("allocation"),
                  environment_id: environment.id,
                  provider_binding_id: binding.id,
                  generation: environment.generation
                })
              )

            now = DateTime.utc_now()
            # Cloudflare owns its released container image. This imported shell
            # does not request an Agent VMM RuntimeBundle template.
            workload =
              group_result!(
                insert_one(Workload, %{
                  id: new_compute_id("workload"),
                  environment_id: environment.id,
                  allocation_id: allocation.id,
                  kind: "shell",
                  spec: %{"group_default" => true},
                  capability_requirements: ["runtime_exec"],
                  desired_state: "ready",
                  observed_state: "pending",
                  generation: environment.generation,
                  revision: 1,
                  created_at: now,
                  updated_at: now
                })
              )

            {workload, allocation} = store_group_facts!(workload, allocation, facts)
            {group_workload_projection(environment, workload, allocation, binding), :created}
        end
      end)
      |> case do
        {:ok, {projection, outcome}} -> {:ok, projection, outcome}
        error -> error
      end
    else
      {:error, :scope_mismatch}
    end
  end

  defp do_ensure_group_workload(_), do: {:error, :invalid_group_workload}

  defp ensure_group_pool!(tenant, provider) do
    pool_id = "pool_group_" <> tenant <> "_" <> provider

    case Repo.get(Pool, pool_id) do
      nil ->
        group_result!(
          create_pool(%{
            id: pool_id,
            tenant_id: tenant,
            name: "Group " <> provider,
            region: "auto",
            provider_policy: %{"providers" => [provider]},
            capabilities: Map.fetch!(@managed_provider_capabilities, provider)
          })
        )

      pool ->
        pool
    end
  end

  def with_group_provider(group, provider, resource, callback) do
    Repo.transaction(fn ->
      case SalixStore.ComputeMigration.ensure_open() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      case group_workload_rows(group, true) do
        {:ok, _environment, _workload, allocation,
         %ProviderBinding{provider: ^provider} = binding} ->
          observation = allocation.provider_observation || %{}
          resource_name = resource["name"]
          profile_key = resource["profile_key"]

          if is_binary(profile_key) and
               get_in(observation, ["provider_spec", "profile_key"]) == profile_key and
               (observation["provider_resource_name"] == resource_name or
                  binding.provider_ref == resource_name),
             do: callback.(),
             else: Repo.rollback(:managed_provider_changed)

        _ ->
          Repo.rollback(:managed_provider_changed)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Serialize a Group Workload mutation with activity/archive changes on the same row."
  def update_group_workload(group, update) when is_function(update, 1) do
    Repo.transaction(fn ->
      case SalixStore.ComputeMigration.ensure_open() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      with {:ok, environment, workload, allocation, binding} <- group_workload_rows(group, true) do
        previous = group_workload_projection(environment, workload, allocation, binding)

        case update.(previous) do
          {:error, reason} ->
            Repo.rollback(reason)

          next when is_map(next) ->
            identity_keys = ~w(tenant_id group_id provider env_id device_id connector_id)

            if Map.take(previous, identity_keys) != Map.take(next, identity_keys),
              do: Repo.rollback(:identity_mismatch)

            {workload, allocation} = store_group_facts!(workload, allocation, next)
            {group_workload_projection(environment, workload, allocation, binding), previous}

          _ ->
            Repo.rollback(:invalid_group_workload)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {current, previous}} -> {:ok, current, previous}
      error -> error
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Find one owned, unreferenced Cloudflare archive generation awaiting cleanup."
  def next_group_archive_gc do
    query =
      from(w in Workload,
        join: e in Environment,
        on: e.id == w.environment_id,
        where:
          e.owner_type == "group" and
            fragment(
              "jsonb_array_length(COALESCE(? #> '{archive,archive_gc_operations}', '[]'::jsonb)) > 0",
              w.spec
            ),
        order_by: w.id,
        limit: 1,
        select: {e.owner_id, w.spec}
      )

    case Repo.one(query) do
      nil ->
        :none

      {group_id, %{"archive" => archive}} ->
        [entry | _] = archive["archive_gc_operations"]
        operation = if is_map(entry), do: entry["operation"], else: entry
        storage = if is_map(entry), do: entry["storage"], else: "salix_s3"
        current = archive["archive"] || %{}
        current_storage = current["storage"] || "salix_s3"

        if is_binary(operation) and storage in ["r2", "salix_s3"] and
             not (operation == current["operation"] and storage == current_storage) and
             operation != archive["archive_operation_id"] do
          {:ok, group_id, entry}
        else
          {:error, :archive_gc_references_live_generation}
        end
    end
  rescue
    _ -> {:error, :compute_storage_unavailable}
  end

  @doc "Clear a GC intent only after the exact object's prefix is empty."
  def finish_group_archive_gc(group_id, entry) do
    operation = if is_map(entry), do: entry["operation"], else: entry
    storage = if is_map(entry), do: entry["storage"], else: "salix_s3"

    Repo.transaction(fn ->
      tenant = SalixStore.Ids.tenant_id_from_group!(group_id)

      query =
        from(w in Workload,
          join: e in Environment,
          on: e.id == w.environment_id,
          where: e.tenant_id == ^tenant and e.owner_type == "group" and e.owner_id == ^group_id,
          select: w,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        workload ->
          archive = workload.spec["archive"] || %{}

          current = archive["archive"] || %{}
          current_storage = current["storage"] || "salix_s3"

          if (operation == current["operation"] and storage == current_storage) or
               operation == archive["archive_operation_id"] do
            Repo.rollback(:archive_gc_references_live_generation)
          end

          pending = archive["archive_gc_operations"] || []

          if entry in pending do
            spec =
              put_in(
                workload.spec,
                ["archive", "archive_gc_operations"],
                List.delete(pending, entry)
              )

            workload
            |> Ecto.Changeset.change(
              spec: spec,
              revision: workload.revision + 1,
              updated_at: DateTime.utc_now()
            )
            |> Repo.update!()
          end

          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  rescue
    _ -> {:error, :compute_storage_unavailable}
  end

  def begin_group_operation(group, attrs, maintenance \\ nil) do
    group_operation(
      group,
      {:begin, Map.put_new(attrs, :started_at, System.system_time(:millisecond))},
      maintenance
    )
  end

  @doc "Project one fixed owner permit for the current Cloudflare transition."
  def prepare_cloudflare_control(group_id, target_resource, action)
      when action in [:open, :seal, :resume] do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      {environment, workload, allocation, binding} =
        case group_workload_rows(group_id, true) do
          {:ok, e, w, a, b} -> {e, w, a, b}
          {:error, reason} -> Repo.rollback(reason)
        end

      record = group_workload_projection(environment, workload, allocation, binding)

      if binding.provider != "cloudflare" or cloudflare_location_key(record) != target_resource,
        do: Repo.rollback(:gateway_target_changed)

      if action == :resume and
           (record["status"] != "archiving" or record["archive_reason"] != "idle"),
         do: Repo.rollback(:archive_commit_recovery_required)

      case cloudflare_gateway_maintenance() do
        :open ->
          :ok

        {:held, %{"reason" => "sandbox_image_release", "phase" => "prepared"}}
        when action in [:seal, :resume] ->
          :ok

        {:held, held} ->
          Repo.rollback({:vm_service_upgrading, held})

        {:error, reason} ->
          Repo.rollback(reason)
      end

      previous = get_in(workload.spec, ["runtime", "cloudflare_control"])

      operation =
        record["archive_operation_id"] || record["wake_operation_id"] ||
          (previous && previous["operation_id"]) || "provision-" <> workload.id

      sealed = action == :seal

      rebuild =
        action == :open and record["status"] == "waking" and
          record["archive_reason"] == "recovery_rebuild" and is_map(previous) and
          previous["sealed"] == true and is_map(record["archive"])

      reopen_ready =
        action == :open and record["status"] == "ready" and
          is_map(previous) and previous["sealed"] == true and
          is_nil(record["archive_operation_id"])

      same =
        action != :resume and not rebuild and not reopen_ready and is_map(previous) and
          previous["operation_id"] == operation and
          previous["generation"] == workload.generation

      if action == :open and same and previous["sealed"] == true,
        do: Repo.rollback(:cloudflare_control_sealed)

      next =
        if same,
          do: Map.put(previous, "sealed", sealed),
          else: %{
            "owner_id" => workload.id,
            "operation_id" => operation,
            "generation" => workload.generation,
            "revision" => workload.revision + 1,
            "sealed" => sealed
          }

      if next != previous do
        runtime = Map.put(workload.spec["runtime"] || %{}, "cloudflare_control", next)
        spec = Map.put(workload.spec, "runtime", runtime)

        spec =
          if rebuild do
            archive = spec["archive"] || %{}

            Map.put(
              spec,
              "archive",
              archive
              |> Map.put("archive_reason", "recovery_restoring")
              |> Map.put("last_wake_at", System.system_time(:millisecond))
            )
          else
            spec
          end

        workload
        |> Ecto.Changeset.change(
          spec: spec,
          revision: workload.revision + 1,
          updated_at: DateTime.utc_now()
        )
        |> Repo.update!()
      end

      next
    end)
  end

  def cloudflare_control(group_id) do
    with {:ok, record} <- group_workload(group_id),
         control when is_map(control) <- record["cloudflare_control"] do
      {:ok, control}
    else
      {:error, _} = error -> error
      _ -> {:error, :cloudflare_control_unbound}
    end
  end

  @doc "Settle one qualified claim from its exact carrier terminal observation."
  def settle_cloudflare_terminal(group_id, target_resource, observation) do
    Repo.transaction(fn ->
      with {:ok, environment, workload, allocation, binding} <-
             group_workload_rows(group_id, true) do
        record = group_workload_projection(environment, workload, allocation, binding)
        expected = record["cloudflare_control"]
        observed = observation["control"]
        terminal = is_map(observed) && observed["last_terminal"]
        keys = ~w(owner_id operation_id generation revision)

        if cloudflare_location_key(record) != target_resource,
          do: Repo.rollback(:gateway_target_changed)

        if not is_map(expected) or not is_map(observed) or
             Map.take(expected, keys) != Map.take(observed, keys) do
          :ok
        else
          operations = get_in(workload.spec, ["activity", "active_operations"]) || %{}
          claim = is_map(terminal) && terminal["claim_id"]
          operation = operations[claim]

          if is_map(operation) and is_map(terminal) and
               terminal["outcome"] in ["completed", "not_issued"] and
               terminal["owner_id"] == workload.id and
               terminal["generation"] == workload.generation and
               operation["kind"] == "cloudflare_gateway_attempt" and
               operation["target_resource"] == target_resource and
               operation["action"] == terminal["action"] and
               operation["owner_operation"] == terminal["operation_id"] and
               operation["generation"] == terminal["generation"] and
               operation["control_revision"] == terminal["revision"] do
            workload
            |> Ecto.Changeset.change(
              spec:
                put_in(
                  workload.spec,
                  ["activity", "active_operations"],
                  Map.delete(operations, claim)
                ),
              revision: workload.revision + 1,
              updated_at: DateTime.utc_now()
            )
            |> Repo.update!()
          end

          :ok
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Settle only managed commands covered by the exact sealed carrier observation."
  def settle_cloudflare_control(group_id, target_resource, observation) do
    Repo.transaction(fn ->
      case group_workload_rows(group_id, true) do
        {:ok, _environment, workload, _allocation, _binding} ->
          expected = get_in(workload.spec, ["runtime", "cloudflare_control"])
          observed = observation["control"]
          keys = ~w(owner_id operation_id generation revision)

          if not is_map(expected) or not is_map(observed) or expected["sealed"] != true or
               observed["sealed"] != true or observed["pending"] != nil or
               observation["managed_commands_settled"] != true or
               Map.take(expected, keys) != Map.take(observed, keys),
             do: Repo.rollback(:cloudflare_control_unsettled)

          operations = get_in(workload.spec, ["activity", "active_operations"]) || %{}

          next =
            Map.reject(operations, fn {_id, op} ->
              op["kind"] == "cloudflare_gateway_attempt" and
                op["target_resource"] == target_resource and
                is_integer(op["control_revision"]) and
                op["control_revision"] <= expected["revision"] and
                op["generation"] == expected["generation"]
            end)

          if next != operations do
            workload
            |> Ecto.Changeset.change(
              spec: put_in(workload.spec, ["activity", "active_operations"], next),
              revision: workload.revision + 1,
              updated_at: DateTime.utc_now()
            )
            |> Repo.update!()
          end

          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Claim one start-capable Gateway attempt before its network call."
  def begin_cloudflare_gateway_attempt(
        group_id,
        operation_id,
        purpose \\ :normal,
        target_resource \\ nil,
        metadata \\ %{}
      )
      when is_binary(group_id) and is_binary(operation_id) and
             purpose in [:normal, :archive] do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case group_workload_rows(group_id, true) do
        {:ok, environment, workload, allocation, binding} ->
          record = group_workload_projection(environment, workload, allocation, binding)

          case cloudflare_gateway_maintenance() do
            :open ->
              :ok

            {:held, %{"reason" => "sandbox_image_release", "phase" => "prepared"} = maintenance} ->
              if purpose == :archive and record["provider"] == "cloudflare" and
                   ((record["status"] == "archiving" and is_binary(target_resource) and
                       cloudflare_location_key(record) == target_resource) or
                      (record["status"] == "ready" and is_binary(target_resource) and
                         cloudflare_location_key(record) == target_resource and
                         metadata["action"] in ["observe", "seal", "connector_control"]) or
                      (record["status"] == "waking" and is_binary(target_resource) and
                         cloudflare_location_key(record) == target_resource and
                         metadata["action"] in [
                           "observe",
                           "seal",
                           "connector_control",
                           "export",
                           "connect_repair",
                           "destroy"
                         ]) or
                      archived_release_cleanup?(record, target_resource)) do
                :ok
              else
                Repo.rollback({:vm_service_upgrading, maintenance})
              end

            {:held, maintenance} ->
              Repo.rollback({:vm_service_upgrading, maintenance})

            {:error, reason} ->
              Repo.rollback({:vm_maintenance_unavailable, reason})
          end

          activity = workload.spec["activity"] || %{}
          operations = activity["active_operations"] || %{}
          control = get_in(workload.spec, ["runtime", "cloudflare_control"])

          if is_map(control) and is_binary(metadata["action"]) and
               cloudflare_location_key(record) != target_resource,
             do: Repo.rollback(:gateway_target_changed)

          metadata =
            if is_map(control) and is_binary(metadata["action"]) and
                 cloudflare_location_key(record) == target_resource,
               do: %{
                 "action" => metadata["action"],
                 "owner_operation" => control["operation_id"],
                 "generation" => control["generation"],
                 "control_revision" => control["revision"]
               },
               else: %{}

          cond do
            Map.has_key?(operations, operation_id) ->
              :ok

            map_size(operations) >= @cloudflare_gateway_attempt_limit ->
              Repo.rollback(:cloudflare_gateway_attempt_limit)

            true ->
              operation =
                Map.merge(
                  Map.take(metadata, ~w(action owner_operation generation control_revision)),
                  %{
                    "operation_id" => operation_id,
                    "kind" => "cloudflare_gateway_attempt",
                    "target_resource" => target_resource,
                    "started_at" => System.system_time(:millisecond),
                    "state" => "active"
                  }
                )

              updated =
                workload.spec
                |> Map.put(
                  "activity",
                  Map.put(
                    activity,
                    "active_operations",
                    Map.put(operations, operation_id, operation)
                  )
                )

              workload
              |> Ecto.Changeset.change(
                spec: updated,
                revision: workload.revision + 1,
                updated_at: DateTime.utc_now()
              )
              |> Repo.update!()

              :ok
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> {:ok, operation_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Keep one pending start claim for a Sandbox until a ready response settles it."
  def mark_cloudflare_gateway_starting(group_id, operation_id, target_resource)
      when is_binary(group_id) and is_binary(operation_id) and is_binary(target_resource) do
    Repo.transaction(fn ->
      case group_workload_rows(group_id, true) do
        {:ok, _environment, workload, _allocation, _binding} ->
          activity = workload.spec["activity"] || %{}
          operations = activity["active_operations"] || %{}

          if not Map.has_key?(operations, operation_id),
            do: Repo.rollback(:gateway_attempt_not_found)

          existing =
            Enum.any?(operations, fn {id, operation} ->
              id != operation_id and operation["kind"] == "cloudflare_gateway_attempt" and
                operation["state"] == "pending_start" and
                operation["target_resource"] == target_resource and
                operation["control_revision"] == operations[operation_id]["control_revision"]
            end)

          next =
            if existing,
              do: Map.delete(operations, operation_id),
              else: put_in(operations, [operation_id, "state"], "pending_start")

          workload
          |> Ecto.Changeset.change(
            spec: put_in(workload.spec, ["activity", "active_operations"], next),
            revision: workload.revision + 1,
            updated_at: DateTime.utc_now()
          )
          |> Repo.update!()

          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  rescue
    _ -> {:error, :compute_storage_unavailable}
  end

  defp archived_release_cleanup?(record, target_resource) do
    archive = record["archive"] || %{}
    metadata = record["connector_archive"] || %{}

    saved_archive? =
      case metadata["type"] do
        type when type in ["connector_tar_gz_chunks", "connector_tar_zst_chunks"] ->
          archive["type"] == metadata["type"] and
            metadata["storage"] in ["salix_s3", "r2"] and
            is_integer(metadata["byte_size"]) and metadata["byte_size"] > 0 and
            is_integer(metadata["chunk_count"]) and metadata["chunk_count"] > 0 and
            is_binary(metadata["operation"]) and metadata["operation"] != "" and
            metadata["operation"] == archive["operation"] and
            metadata["storage"] == archive["storage"] and
            metadata["byte_size"] == archive["byte_size"] and
            metadata["chunk_count"] == archive["chunk_count"]

        "connector_tar_gz" ->
          archive["type"] == metadata["type"] and
            metadata["encoding"] == "base64" and archive["encoding"] == "base64" and
            is_binary(archive["data"]) and archive["data"] != ""

        _ ->
          false
      end

    record["status"] == "archived" and is_binary(target_resource) and
      target_resource == cloudflare_location_key(record) and
      saved_archive?
  end

  defp cloudflare_location_key(record) do
    case get_in(record, ["provider_spec", "profile_key"]) do
      profile when profile in ["cf-standard-1", "cf-standard-2"] ->
        profile <> ":" <> record["provider_resource_name"]

      _ ->
        nil
    end
  end

  @doc "A ready Gateway response settles prior accepted starts for the exact Sandbox."
  def finish_cloudflare_gateway_starting(group_id, target_resource, control_revision \\ nil)
      when is_binary(group_id) and is_binary(target_resource) do
    Repo.transaction(fn ->
      case group_workload_rows(group_id, true) do
        {:ok, _environment, workload, _allocation, _binding} ->
          activity = workload.spec["activity"] || %{}
          operations = activity["active_operations"] || %{}

          next =
            Map.reject(operations, fn {_id, operation} ->
              operation["kind"] == "cloudflare_gateway_attempt" and
                operation["state"] == "pending_start" and
                operation["target_resource"] == target_resource and
                (is_nil(control_revision) or operation["control_revision"] == control_revision)
            end)

          if next != operations do
            workload
            |> Ecto.Changeset.change(
              spec: put_in(workload.spec, ["activity", "active_operations"], next),
              revision: workload.revision + 1,
              updated_at: DateTime.utc_now()
            )
            |> Repo.update!()
          end

          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  rescue
    _ -> {:error, :compute_storage_unavailable}
  end

  @doc "Release one settled Gateway attempt without changing VM idle activity."
  def finish_cloudflare_gateway_attempt(group_id, operation_id)
      when is_binary(group_id) and is_binary(operation_id) do
    Repo.transaction(fn ->
      case group_workload_rows(group_id, true) do
        {:ok, _environment, workload, _allocation, _binding} ->
          activity = workload.spec["activity"] || %{}
          operations = activity["active_operations"] || %{}

          if Map.has_key?(operations, operation_id) do
            updated =
              workload.spec
              |> Map.put(
                "activity",
                Map.put(activity, "active_operations", Map.delete(operations, operation_id))
              )

            workload
            |> Ecto.Changeset.change(
              spec: updated,
              revision: workload.revision + 1,
              updated_at: DateTime.utc_now()
            )
            |> Repo.update!()
          end

          :ok

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Serialize a release fence with every start-capable Gateway claim."
  def cloudflare_gateway_release_status do
    case S3.get(Keys.ctl_vm_maintenance()) do
      {:error, :not_found} ->
        {:ok, nil}

      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"enabled" => enabled} = record} when is_boolean(enabled) ->
            {:ok, record}

          _ ->
            {:error, :vm_maintenance_invalid}
        end

      {:error, reason} ->
        {:error, {:vm_maintenance_unavailable, reason}}
    end
  end

  @doc "Serialize a release fence with every start-capable Gateway claim."
  def begin_cloudflare_gateway_release(maintenance_id, metadata)
      when is_binary(maintenance_id) and maintenance_id != "" and is_map(metadata) do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case S3.get(Keys.ctl_vm_maintenance()) do
        {:error, :not_found} ->
          record =
            metadata
            |> Map.new(fn {key, value} -> {to_string(key), value} end)
            |> Map.merge(%{
              "enabled" => true,
              "maintenance_id" => maintenance_id,
              "phase" => "prepared",
              "started_at" => System.system_time(:millisecond)
            })

          case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(record), if_none_match: "*") do
            {:ok, _} -> record
            {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
          end

        {:ok, %{body: body, etag: etag}} ->
          case Jason.decode(body) do
            {:ok, %{"enabled" => true, "maintenance_id" => ^maintenance_id} = record} ->
              record

            {:ok,
             %{
               "enabled" => true,
               "maintenance_id" => previous_id,
               "phase" => phase,
               "reason" => "sandbox_image_release"
             } = record}
            when phase in ["prepared", "deploying"] ->
              next =
                record
                |> Map.merge(metadata |> Map.new(fn {key, value} -> {to_string(key), value} end))
                |> Map.merge(%{
                  "maintenance_id" => maintenance_id,
                  "superseded_maintenance_id" => previous_id,
                  "started_at" => System.system_time(:millisecond),
                  "phase" => phase
                })

              case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(next), if_match: etag) do
                {:ok, _} -> next
                {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
              end

            {:ok, %{"enabled" => false} = record} ->
              next =
                record
                |> Map.merge(metadata |> Map.new(fn {key, value} -> {to_string(key), value} end))
                |> Map.merge(%{
                  "enabled" => true,
                  "maintenance_id" => maintenance_id,
                  "phase" => "prepared",
                  "started_at" => System.system_time(:millisecond)
                })

              case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(next), if_match: etag) do
                {:ok, _} -> next
                {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
              end

            {:ok, _} ->
              Repo.rollback(:vm_maintenance_owned_by_other_release)

            _ ->
              Repo.rollback(:vm_maintenance_invalid)
          end

        {:error, reason} ->
          Repo.rollback({:vm_maintenance_unavailable, reason})
      end
    end)
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Track a standalone operator probe that can start a Container."
  def begin_cloudflare_direct_gateway_attempt(operation_id) when is_binary(operation_id) do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case S3.get(Keys.ctl_vm_maintenance()) do
        {:error, :not_found} ->
          record = %{
            "enabled" => false,
            "active_direct_attempts" => %{operation_id => System.system_time(:millisecond)}
          }

          case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(record), if_none_match: "*") do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
          end

        {:ok, %{body: body, etag: etag}} ->
          case Jason.decode(body) do
            {:ok, %{"enabled" => false} = record} ->
              attempts = record["active_direct_attempts"] || %{}

              if map_size(attempts) >= 16 and not Map.has_key?(attempts, operation_id),
                do: Repo.rollback(:cloudflare_gateway_attempt_limit)

              next =
                Map.put(
                  record,
                  "active_direct_attempts",
                  Map.put(attempts, operation_id, System.system_time(:millisecond))
                )

              case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(next), if_match: etag) do
                {:ok, _} -> :ok
                {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
              end

            {:ok, %{"enabled" => true} = record} ->
              Repo.rollback({:vm_service_upgrading, record})

            _ ->
              Repo.rollback(:vm_maintenance_invalid)
          end

        {:error, reason} ->
          Repo.rollback({:vm_maintenance_unavailable, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> {:ok, operation_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Remove only a confirmed settled standalone Gateway probe."
  def finish_cloudflare_direct_gateway_attempt(operation_id) when is_binary(operation_id) do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case S3.get(Keys.ctl_vm_maintenance()) do
        {:ok, %{body: body, etag: etag}} ->
          case Jason.decode(body) do
            {:ok, record} when is_map(record) ->
              attempts = record["active_direct_attempts"] || %{}

              if Map.has_key?(attempts, operation_id) do
                next =
                  Map.put(record, "active_direct_attempts", Map.delete(attempts, operation_id))

                result =
                  if next["enabled"] == false and map_size(next["active_direct_attempts"]) == 0 do
                    S3.delete(Keys.ctl_vm_maintenance(), if_match: etag)
                  else
                    S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(next), if_match: etag)
                  end

                case result do
                  :ok -> :ok
                  {:ok, _} -> :ok
                  {:error, reason} -> Repo.rollback({:vm_maintenance_clear_uncertain, reason})
                end
              else
                Repo.rollback(:cloudflare_gateway_attempt_not_found)
              end

            _ ->
              Repo.rollback(:vm_maintenance_invalid)
          end

        {:error, reason} ->
          Repo.rollback({:vm_maintenance_unavailable, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Record that full Container deployment may start; later failures need forward repair."
  def mark_cloudflare_gateway_release_deploying(maintenance_id)
      when is_binary(maintenance_id) and maintenance_id != "" do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case S3.get(Keys.ctl_vm_maintenance()) do
        {:ok, %{body: body, etag: etag}} ->
          case Jason.decode(body) do
            {:ok, %{"maintenance_id" => ^maintenance_id, "phase" => "deploying"} = record} ->
              record

            {:ok, %{"maintenance_id" => ^maintenance_id, "phase" => "prepared"} = record} ->
              attempts = record["active_direct_attempts"] || %{}

              if not is_map(attempts) or map_size(attempts) > 0,
                do: Repo.rollback(:direct_gateway_attempts_pending)

              next = Map.put(record, "phase", "deploying")

              case S3.put(Keys.ctl_vm_maintenance(), Jason.encode!(next), if_match: etag) do
                {:ok, _} -> next
                {:error, reason} -> Repo.rollback({:vm_maintenance_write_uncertain, reason})
              end

            _ ->
              Repo.rollback(:vm_maintenance_owned_by_other_release)
          end

        {:error, reason} ->
          Repo.rollback({:vm_maintenance_unavailable, reason})
      end
    end)
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  @doc "Clear only the matching release fence after convergence."
  def clear_cloudflare_gateway_release(maintenance_id, expected_phase \\ nil)
      when is_binary(maintenance_id) and maintenance_id != "" do
    Repo.transaction(fn ->
      lock_cloudflare_gateway_release!()

      case S3.get(Keys.ctl_vm_maintenance()) do
        {:error, :not_found} ->
          if is_nil(expected_phase), do: :ok, else: Repo.rollback(:vm_maintenance_missing)

        {:ok, %{body: body, etag: etag}} ->
          case Jason.decode(body) do
            {:ok, %{"maintenance_id" => ^maintenance_id, "phase" => phase} = record}
            when is_nil(expected_phase) or phase == expected_phase ->
              attempts = record["active_direct_attempts"] || %{}

              result =
                cond do
                  not is_map(attempts) ->
                    Repo.rollback(:vm_maintenance_invalid)

                  map_size(attempts) > 0 and phase == "prepared" ->
                    S3.put(
                      Keys.ctl_vm_maintenance(),
                      Jason.encode!(%{"enabled" => false, "active_direct_attempts" => attempts}),
                      if_match: etag
                    )

                  map_size(attempts) > 0 ->
                    Repo.rollback(:direct_gateway_attempts_pending)

                  true ->
                    S3.delete(Keys.ctl_vm_maintenance(), if_match: etag)
                end

              case result do
                :ok -> :ok
                {:ok, _} -> :ok
                {:error, reason} -> Repo.rollback({:vm_maintenance_clear_uncertain, reason})
              end

            {:ok, %{"maintenance_id" => ^maintenance_id}} ->
              Repo.rollback(:vm_maintenance_phase_mismatch)

            _ ->
              Repo.rollback(:vm_maintenance_owned_by_other_release)
          end

        {:error, reason} ->
          Repo.rollback({:vm_maintenance_unavailable, reason})
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  defp lock_cloudflare_gateway_release! do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@cloudflare_gateway_release_lock])
  end

  defp cloudflare_gateway_maintenance do
    case S3.get(Keys.ctl_vm_maintenance()) do
      {:error, :not_found} ->
        :open

      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"enabled" => true} = maintenance} -> {:held, maintenance}
          {:ok, %{"enabled" => false}} -> :open
          _ -> {:error, :invalid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def finish_group_operation(group, attrs) do
    attrs =
      attrs
      |> Map.put_new(:finished_at, System.system_time(:millisecond))
      |> Map.update(:result, "", &(inspect(&1) |> String.slice(0, 500)))

    group_operation(group, {:finish, attrs}, nil)
  end

  defp group_operation(group, command, maintenance) do
    Repo.transaction(fn ->
      case SalixStore.ComputeMigration.ensure_open() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      rows = group_workload_rows(group, true)

      case rows do
        {:ok, environment, workload, allocation, binding} ->
          record = group_workload_projection(environment, workload, allocation, binding)

          case reduce_group_operation(record, command, maintenance) do
            {:unchanged, reply} ->
              reply

            {:changed, updated, reply} ->
              store_group_facts!(workload, allocation, updated)
              reply
          end

        {:error, :not_found} ->
          {:unchanged, reply} = reduce_group_operation(nil, command, maintenance)
          reply
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :compute_storage_unavailable}
  end

  defp reduce_group_operation(nil, {:begin, _attrs}, _maintenance), do: {:unchanged, {:ok, nil}}

  defp reduce_group_operation(
         %{
           "provider_migration" => %{
             "phase" => "committed",
             "archive_hold" => "awaiting_durable_archive"
           }
         },
         {:begin, _attrs},
         _maintenance
       ),
       do: {:unchanged, {:error, :provider_cutover_archive_pending}}

  defp reduce_group_operation(
         %{"provider_migration" => %{"phase" => phase}},
         {:begin, _attrs},
         _maintenance
       )
       when phase in ~w(preparing exported restored retired),
       do: {:unchanged, {:error, :provider_migration_in_progress}}

  defp reduce_group_operation(%{"provider" => provider}, {:begin, _attrs}, _maintenance)
       when provider != "cloudflare",
       do: {:unchanged, {:ok, nil}}

  defp reduce_group_operation(record, {:begin, attrs}, maintenance) do
    operation_id = attrs.operation_id

    cond do
      record["desired_state"] == "stopped" ->
        {:unchanged, {:error, :workload_stopped}}

      record["status"] == "archiving" ->
        {:unchanged, {:error, {:vm_archiving, group_retry_metadata(record)}}}

      record["status"] == "archived" ->
        {:unchanged, {:wake, {:error, {:vm_waking, group_retry_metadata(record)}}}}

      record["status"] == "waking" ->
        {:unchanged, {:error, {:vm_waking, group_retry_metadata(record)}}}

      attrs.mutating? and is_map(maintenance) ->
        {:unchanged,
         {:error, {:vm_service_upgrading, group_maintenance_metadata(record, maintenance)}}}

      attrs.mutating? and record["rollout_state"] == "draining" ->
        {:unchanged,
         {:error,
          {:vm_rolling_update,
           %{
             "retry_after_ms" => 1_000,
             "rollout_id" => record["worker_release_id"],
             "active_operation_count" => record["active_operation_count"] || 0
           }}}}

      true ->
        operations = record["active_operations"] || %{}

        if Map.has_key?(operations, operation_id) do
          {:unchanged, {:ok, operation_id}}
        else
          operation = %{
            "operation_id" => operation_id,
            "kind" => attrs.kind,
            "started_at" => attrs.started_at,
            "idempotency_class" => attrs.idempotency_class,
            "state" => "active"
          }

          operations = Map.put(operations, operation_id, operation)

          updated =
            record
            |> Map.put("active_operations", operations)
            |> Map.put("active_operation_count", map_size(operations))
            |> Map.put("last_operation_at", attrs.started_at)
            |> group_maybe_put("last_vm_operation_agent_id", attrs.agent_id)

          {:changed, updated, {:ok, operation_id}}
        end
    end
  end

  defp reduce_group_operation(nil, {:finish, _attrs}, _maintenance), do: {:unchanged, :ok}

  defp reduce_group_operation(record, {:finish, attrs}, _maintenance) do
    operations = record["active_operations"] || %{}

    if Map.has_key?(operations, attrs.operation_id) do
      operations = Map.delete(operations, attrs.operation_id)

      updated =
        record
        |> Map.put("active_operations", operations)
        |> Map.put("active_operation_count", map_size(operations))
        |> Map.put("last_operation_at", attrs.finished_at)
        |> Map.put("last_operation_result", %{
          "operation_id" => attrs.operation_id,
          "state" => attrs.state,
          "finished_at" => attrs.finished_at,
          "result" => attrs.result
        })

      {:changed, updated, :ok}
    else
      {:unchanged, :ok}
    end
  end

  defp group_retry_metadata(record),
    do: %{"retry_after_ms" => 1_000, "env_id" => record["env_id"]}

  defp group_maintenance_metadata(record, maintenance) do
    %{
      "retry_after_ms" => maintenance["retry_after_ms"] || maintenance[:retry_after_ms] || 1_000,
      "env_id" => record["env_id"],
      "reason" => maintenance["reason"] || maintenance[:reason] || "vm_service_upgrading"
    }
    |> group_maybe_put(
      "maintenance_id",
      maintenance["maintenance_id"] || maintenance[:maintenance_id]
    )
    |> group_maybe_put("started_at", maintenance["started_at"] || maintenance[:started_at])
  end

  defp group_maybe_put(map, _key, nil), do: map
  defp group_maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Commit Group release intent without running provider work in the caller."
  def request_group_stop(group) do
    case Repo.transaction(fn ->
           with :ok <- SalixStore.ComputeMigration.ensure_open(),
                {:ok, _environment, workload, _allocation, _binding} <-
                  group_workload_rows(group, true) do
             workload
             |> Ecto.Changeset.change(
               desired_state: "stopped",
               revision: workload.revision + 1,
               updated_at: DateTime.utc_now()
             )
             |> Repo.update!()

             :ok
           else
             {:error, :not_found} -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :compute_storage_unavailable}
  end

  @doc "Retire the default selection after provider release; retain Workload facts and archives."
  def retire_group_workload(group) do
    Repo.transaction(fn ->
      case SalixStore.ComputeMigration.ensure_open() do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      case group_workload_rows(group, true) do
        {:ok, _environment, workload, allocation, _binding} ->
          workload
          |> Ecto.Changeset.change(
            spec: Map.put(workload.spec, "group_default", false),
            desired_state: "stopped",
            observed_state: "stopped",
            revision: workload.revision + 1,
            updated_at: DateTime.utc_now()
          )
          |> Repo.update!()

          allocation
          |> Ecto.Changeset.change(
            status: "released",
            operation_outcome: "succeeded",
            revision: allocation.revision + 1,
            updated_at: DateTime.utc_now()
          )
          |> Repo.update!()

          :ok

        {:error, :not_found} ->
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Page current Group default projections without per-Group reads or Provider probes."
  def page_group_workloads(opts \\ []) do
    with :ok <- SalixStore.ComputeMigration.ensure_open(), do: do_page_group_workloads(opts)
  end

  defp do_page_group_workloads(opts) do
    page_size = Keyword.get(opts, :limit, 50)
    cursor = Keyword.get(opts, :cursor, "") || ""
    tenant = Keyword.get(opts, :tenant_id)

    if page_size in 1..100 and is_binary(cursor) and byte_size(cursor) <= 256 do
      query =
        from(e in Environment,
          join: w in Workload,
          on: w.environment_id == e.id,
          join: a in Allocation,
          on: a.id == w.allocation_id,
          join: b in ProviderBinding,
          on: b.id == a.provider_binding_id,
          where:
            e.owner_type == "group" and w.id > ^cursor and
              fragment("?->>'group_default' = 'true'", w.spec),
          order_by: w.id,
          limit: ^(page_size + 1),
          select:
            {e,
             %{
               id: w.id,
               desired_state: w.desired_state,
               observed_state: w.observed_state,
               created_at: w.created_at,
               spec:
                 fragment(
                   "jsonb_set(?, '{archive,archive}', COALESCE(? #> '{archive,archive}', '{}'::jsonb) - 'data', false)",
                   w.spec,
                   w.spec
                 )
             }, a, b}
        )

      query = if is_binary(tenant), do: where(query, [e], e.tenant_id == ^tenant), else: query
      rows = Repo.all(query)
      items = Enum.take(rows, page_size)

      next =
        if length(rows) > page_size,
          do: items |> List.last() |> elem(1) |> Map.fetch!(:id),
          else: nil

      {:ok,
       %{
         records: Enum.map(items, fn {e, w, a, b} -> group_workload_projection(e, w, a, b) end),
         next_cursor: next
       }}
    else
      {:error, :invalid_page}
    end
  end

  defp group_workload_rows(group, lock? \\ false) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    query =
      from(e in Environment,
        join: w in Workload,
        on: w.environment_id == e.id,
        join: a in Allocation,
        on: a.id == w.allocation_id,
        join: b in ProviderBinding,
        on: b.id == a.provider_binding_id,
        where:
          e.tenant_id == ^tenant and e.owner_type == "group" and e.owner_id == ^group and
            fragment("?->>'group_default' = 'true'", w.spec),
        select: {e, w, a, b}
      )

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query

    case Repo.one(query) do
      {e, w, a, b} -> {:ok, e, w, a, b}
      nil -> {:error, :not_found}
    end
  end

  defp store_group_facts!(workload, allocation, facts) do
    spec =
      (workload.spec || %{})
      |> Map.put("device", Map.take(facts, @group_device_fields))
      |> Map.put("archive", Map.take(facts, @group_archive_fields))
      |> Map.put("activity", Map.take(facts, @group_activity_fields))
      |> Map.put("runtime", Map.take(facts, @group_runtime_fields))
      |> Map.put(
        "lifecycle",
        Map.take(facts, @group_lifecycle_fields)
        |> Map.put("provision_started_at", facts["created_at"])
      )

    workload =
      workload
      |> Ecto.Changeset.change(
        spec: spec,
        observed_state: facts["status"] || "pending",
        revision: workload.revision + 1,
        updated_at: DateTime.utc_now()
      )
      |> Repo.update!()

    allocation =
      allocation
      |> Ecto.Changeset.change(
        provider_observation: Map.take(facts, @group_provider_fields),
        revision: allocation.revision + 1,
        updated_at: DateTime.utc_now()
      )
      |> Repo.update!()

    {workload, allocation}
  end

  defp group_workload_projection(environment, workload, allocation, binding) do
    Enum.reduce(
      ~w(device archive activity runtime lifecycle),
      allocation.provider_observation || %{},
      fn key, facts -> Map.merge(facts, workload.spec[key] || %{}) end
    )
    |> Map.merge(%{
      "tenant_id" => environment.tenant_id,
      "group_id" => environment.owner_id,
      "provider" => binding.provider,
      "workload_id" => workload.id,
      "compute_environment_id" => environment.id,
      "desired_state" => workload.desired_state,
      "allocation_id" => allocation.id,
      "status" => workload.observed_state,
      "created_at" =>
        get_in(workload.spec, ["lifecycle", "provision_started_at"]) ||
          DateTime.to_unix(workload.created_at, :millisecond),
      "active_operation_count" =>
        map_size(get_in(workload.spec, ["activity", "active_operations"]) || %{})
    })
  end

  defp group_result!({:ok, value}), do: value
  defp group_result!({:error, reason}), do: Repo.rollback(reason)

  def create_environment(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    with :ok <- required_strings(attrs, [:id, :tenant_id, :owner_type, :owner_id, :pool_id]),
         true <- attrs.owner_type in ["project", "swarm", "group"] || {:error, :invalid_owner},
         %Pool{tenant_id: tenant_id, status: "active"} <- Repo.get(Pool, attrs.pool_id),
         true <- tenant_id == attrs.tenant_id || {:error, :scope_mismatch},
         :ok <- validate_retention(Map.get(attrs, :retention, %{"mode" => "retain"})) do
      insert_one(Environment, %{
        id: attrs.id,
        tenant_id: attrs.tenant_id,
        owner_type: attrs.owner_type,
        owner_id: attrs.owner_id,
        pool_id: attrs.pool_id,
        desired_state: "ready",
        observed_state: "pending",
        generation: 1,
        revision: 1,
        retention: Map.get(attrs, :retention, %{"mode" => "retain"}),
        inventory_watermark: 0,
        created_at: now,
        updated_at: now
      })
    else
      nil -> {:error, :pool_not_found}
      {:error, _} = error -> error
      false -> {:error, :invalid}
    end
  end

  @doc "Idempotently materialize one owner Environment on one exact Pool."
  def ensure_environment(attrs) when is_map(attrs) do
    with :ok <- required_strings(attrs, [:id, :tenant_id, :owner_type, :owner_id, :pool_id]),
         true <- attrs.owner_type in ["project", "swarm", "group"] || {:error, :invalid_owner},
         {:ok, %Pool{}} <- resolve_pool(attrs.tenant_id, attrs.pool_id) do
      case Repo.transaction(fn ->
             lock_key =
               Enum.join(
                 ["compute-environment", attrs.tenant_id, attrs.owner_type, attrs.owner_id],
                 ":"
               )

             Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

             case Repo.one(
                    from(e in Environment,
                      where:
                        e.tenant_id == ^attrs.tenant_id and e.owner_type == ^attrs.owner_type and
                          e.owner_id == ^attrs.owner_id,
                      lock: "FOR UPDATE"
                    )
                  ) do
               nil ->
                 case create_environment(attrs) do
                   {:ok, environment} -> environment
                   {:error, reason} -> Repo.rollback(reason)
                 end

               %Environment{pool_id: pool_id} = environment when pool_id == attrs.pool_id ->
                 environment

               %Environment{} ->
                 Repo.rollback(:pool_selection_conflict)
             end
           end) do
        {:ok, environment} -> {:ok, environment}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Create one provider-private binding under an existing pool."
  def create_provider_binding(attrs) when is_map(attrs) do
    with :ok <- required_strings(attrs, [:id, :pool_id, :provider]),
         true <- attrs.provider in @providers || {:error, :unsupported_provider},
         :ok <- validate_agent_vmm_scope_rollout(attrs.provider),
         %Pool{tenant_id: tenant_id, status: "active"} = pool <- Repo.get(Pool, attrs.pool_id),
         true <- provider_allowed?(pool, attrs.provider) || {:error, :provider_not_allowed},
         :ok <-
           validate_binding_environment(pool, attrs.provider, Map.get(attrs, :environment_id)),
         :ok <-
           validate_provider_ref_scope(attrs.provider, Map.get(attrs, :provider_ref), tenant_id) do
      insert_one(ProviderBinding, %{
        id: attrs.id,
        pool_id: attrs.pool_id,
        environment_id: Map.get(attrs, :environment_id),
        provider: attrs.provider,
        provider_ref: Map.get(attrs, :provider_ref),
        status: if(attrs.provider == "agent_vmm", do: "disabled", else: "available"),
        generation: Map.get(attrs, :generation, 1),
        revision: 1,
        observation: %{},
        updated_at: DateTime.utc_now()
      })
    else
      nil -> {:error, :pool_not_found}
      {:error, _} = error -> error
      false -> {:error, :invalid}
    end
  end

  @doc "Ensure one exact provider binding under retry without widening its scope."
  def ensure_provider_binding(attrs) when is_map(attrs) do
    environment_id = Map.get(attrs, :environment_id)
    provider_ref = Map.get(attrs, :provider_ref)

    with :ok <- required_strings(attrs, [:id, :pool_id, :provider]),
         true <- attrs.provider in @providers || {:error, :unsupported_provider},
         :ok <- validate_agent_vmm_scope_rollout(attrs.provider),
         %Pool{tenant_id: tenant_id, status: "active"} = pool <- Repo.get(Pool, attrs.pool_id),
         true <- provider_allowed?(pool, attrs.provider) || {:error, :provider_not_allowed},
         :ok <- validate_binding_environment(pool, attrs.provider, environment_id),
         :ok <- validate_provider_ref_scope(attrs.provider, provider_ref, tenant_id) do
      case Repo.transaction(fn ->
             lock_key =
               Enum.join(
                 [
                   "compute-provider-binding",
                   attrs.pool_id,
                   attrs.provider,
                   provider_ref || "none",
                   environment_id || "pool"
                 ],
                 ":"
               )

             Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

             query =
               from(b in ProviderBinding,
                 where:
                   b.pool_id == ^attrs.pool_id and b.provider == ^attrs.provider and
                     b.provider_ref == ^provider_ref
               )
               |> binding_environment_query(environment_id)

             case Repo.one(query) do
               %ProviderBinding{} = binding ->
                 binding

               nil ->
                 case create_provider_binding(attrs) do
                   {:ok, binding} -> binding
                   {:error, reason} -> Repo.rollback(reason)
                 end
             end
           end) do
        {:ok, binding} -> {:ok, binding}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :pool_not_found}
      {:error, _} = error -> error
      false -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def update_provider_binding(id, expected_revision, attrs)
      when is_binary(id) and is_integer(expected_revision) and is_map(attrs) do
    status = Map.get(attrs, :status)
    provider_ref = Map.get(attrs, :provider_ref, :unchanged)

    with true <- (is_nil(status) or status in ~w(available disabled)) || {:error, :invalid_status},
         true <-
           (provider_ref == :unchanged or is_nil(provider_ref) or is_binary(provider_ref)) ||
             {:error, :invalid_provider_ref} do
      Repo.transaction(fn ->
        binding =
          Repo.one!(from(b in ProviderBinding, where: b.id == ^id, lock: "FOR UPDATE"))

        if binding.revision != expected_revision do
          Repo.rollback(:revision_conflict)
        end

        if binding.provider == "agent_vmm" do
          Repo.rollback(:provider_managed_by_observation)
        end

        pool = Repo.get!(Pool, binding.pool_id)

        case validate_provider_ref_scope(binding.provider, provider_ref, pool.tenant_id) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        changes =
          [updated_at: DateTime.utc_now()]
          |> maybe_put(:status, status)
          |> then(fn changes ->
            if provider_ref == :unchanged,
              do: changes,
              else: Keyword.put(changes, :provider_ref, provider_ref)
          end)

        {1, _} =
          Repo.update_all(from(b in ProviderBinding, where: b.id == ^id),
            set: changes,
            inc: [revision: 1, generation: 1]
          )

        Repo.get!(ProviderBinding, id)
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  def allocate(attrs) when is_map(attrs) do
    with :ok <- required_strings(attrs, [:id, :environment_id, :provider_binding_id]),
         true <-
           (is_integer(attrs.generation) and attrs.generation > 0) ||
             {:error, :invalid_generation} do
      Repo.transaction(fn ->
        environment =
          Repo.one!(
            from(e in Environment, where: e.id == ^attrs.environment_id, lock: "FOR UPDATE")
          )

        binding = Repo.get!(ProviderBinding, attrs.provider_binding_id)

        if environment.generation != attrs.generation or environment.desired_state != "ready" do
          Repo.rollback(:stale_generation)
        end

        pool = Repo.get!(Pool, environment.pool_id)

        if not binding_eligible_for_environment?(binding, environment) or
             binding.status != "available" or not provider_allowed?(pool, binding.provider) do
          Repo.rollback(:provider_unavailable)
        end

        now = DateTime.utc_now()

        row = %{
          id: attrs.id,
          environment_id: environment.id,
          provider_binding_id: binding.id,
          status: "allocating",
          operation_outcome: "pending",
          generation: environment.generation,
          provider_observation: %{},
          revision: 1,
          created_at: now,
          updated_at: now
        }

        case Repo.insert_all(Allocation, [row], on_conflict: :nothing, conflict_target: [:id]) do
          {1, _} -> Repo.get!(Allocation, attrs.id)
          {0, _} -> Repo.rollback(:already_exists)
        end
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def create_workload(attrs) when is_map(attrs) do
    capability_requirements = Map.get(attrs, :capability_requirements, [])
    template_key = Map.get(attrs, :template_key)

    with :ok <- required_strings(attrs, [:id, :environment_id, :allocation_id, :kind]),
         true <-
           (is_integer(attrs.generation) and attrs.generation > 0) ||
             {:error, :invalid_generation},
         :ok <- ComputeContract.validate_workload(attrs.kind, capability_requirements),
         :ok <- validate_capability_requirements(capability_requirements),
         {:ok, template} <- materialize_workload_template(attrs, template_key) do
      Repo.transaction(fn ->
        allocation =
          Repo.one(from(a in Allocation, where: a.id == ^attrs.allocation_id, lock: "FOR UPDATE"))

        environment = Repo.get(Environment, attrs.environment_id)
        pool = environment && Repo.get(Pool, environment.pool_id)

        cond do
          allocation == nil or environment == nil or pool == nil ->
            Repo.rollback(:not_found)

          allocation.status == "released" ->
            Repo.rollback(:allocation_released)

          allocation.environment_id != environment.id or
            allocation.generation != attrs.generation or
              environment.generation != attrs.generation ->
            Repo.rollback(:stale_generation)

          not capabilities_supported?(pool, capability_requirements) ->
            Repo.rollback(:unsupported_capability)

          true ->
            now = DateTime.utc_now()

            case insert_one(Workload, %{
                   id: attrs.id,
                   environment_id: environment.id,
                   allocation_id: allocation.id,
                   kind: attrs.kind,
                   spec: template.spec,
                   template_key: template.template_key,
                   runtime_revision: template.runtime_revision,
                   creation_request_scope: Map.get(attrs, :creation_request_scope),
                   creation_request_id: Map.get(attrs, :creation_request_id),
                   creation_request_input: Map.get(attrs, :creation_request_input),
                   capability_requirements: capability_requirements,
                   desired_state: "ready",
                   observed_state: "pending",
                   generation: attrs.generation,
                   revision: 1,
                   created_at: now,
                   updated_at: now
                 }) do
              {:ok, workload} -> workload
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, workload} -> {:ok, workload}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Place a Workload from Environment pool policy without a user-selected Provider."
  def place_workload(attrs) when is_map(attrs) do
    case Repo.transaction(fn ->
           case do_place_workload(attrs) do
             {:ok, placement} -> placement
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, placement} -> {:ok, placement}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Recover one authorized creation request without repeating placement."
  def requested_workload(tenant_id, scope, request_id) do
    case Repo.one(
           from(w in Workload,
             join: e in Environment,
             on: e.id == w.environment_id,
             where:
               e.tenant_id == ^tenant_id and w.creation_request_scope == ^scope and
                 w.creation_request_id == ^request_id
           )
         ) do
      nil ->
        {:error, :not_found}

      workload ->
        {:ok, %{workload: workload, allocation: Repo.get!(Allocation, workload.allocation_id)}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Commit a request association and its placement in the same transaction."
  def place_requested_workload(attrs) do
    result =
      Repo.transaction(fn ->
        # Reuse the Environment lock used by initial-node placement. The unique
        # request index also fences conflicting requests targeting another Environment.
        Repo.one(from(e in Environment, where: e.id == ^attrs.environment_id, lock: "FOR UPDATE"))

        case requested_workload(
               attrs.tenant_id,
               attrs.creation_request_scope,
               attrs.creation_request_id
             ) do
          {:ok, placed} ->
            match_creation_request!(placed, attrs.creation_request_input)

          {:error, :not_found} ->
            case do_place_workload(attrs) do
              {:ok, placed} -> placed
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, placed} ->
        {:ok, placed}

      {:error, reason} ->
        # A conflicting insert rolls back the losing Allocation too. Read the
        # committed winner after leaving the aborted transaction.
        case requested_workload(
               attrs.tenant_id,
               attrs.creation_request_scope,
               attrs.creation_request_id
             ) do
          {:ok, placed} ->
            if placed.workload.creation_request_input == attrs.creation_request_input,
              do: {:ok, placed},
              else: {:error, :idempotency_conflict}

          _ ->
            {:error, reason}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp match_creation_request!(placed, input) do
    if placed.workload.creation_request_input == input,
      do: placed,
      else: Repo.rollback(:idempotency_conflict)
  end

  @doc "Check an exact owner relationship without relying on a truncated projection."
  def environment_in_scope(tenant_id, owner_type, owner_id, environment_id) do
    if Repo.exists?(
         from(e in Environment,
           where:
             e.id == ^environment_id and e.tenant_id == ^tenant_id and
               e.owner_type == ^owner_type and e.owner_id == ^owner_id
         )
       ), do: :ok, else: {:error, :not_found}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Ensure one initial workload for an enabled registration, preserving existing work."
  def ensure_node_workload(tenant_id, environment_id, registration_id) do
    Repo.transaction(fn ->
      environment =
        Repo.one(from(e in Environment, where: e.id == ^environment_id, lock: "FOR UPDATE"))

      unless environment && environment.tenant_id == tenant_id &&
               environment.desired_state == "ready",
             do: Repo.rollback(:not_found)

      registration = Repo.get(AgentVMM.Registration, registration_id)

      unless registration && registration.tenant_id == tenant_id && registration.status == "ready" &&
               registration.desired_enabled,
             do: Repo.rollback(:compute_node_not_ready)

      binding =
        Repo.one(
          from(b in ProviderBinding,
            where:
              b.environment_id == ^environment_id and b.pool_id == ^environment.pool_id and
                b.provider == "agent_vmm" and b.provider_ref == ^registration_id and
                b.status == "available",
            order_by: b.id,
            limit: 1
          )
        )

      unless binding, do: Repo.rollback(:compute_node_not_ready)

      existing =
        Repo.one(
          from(w in Workload,
            join: a in Allocation,
            on: a.id == w.allocation_id,
            where:
              w.environment_id == ^environment_id and a.provider_binding_id == ^binding.id and
                w.kind == "shell" and w.desired_state == "ready" and
                w.observed_state in ["pending", "ready", "failed"] and
                a.status in ["pending", "allocating", "ready"] and
                w.generation == ^environment.generation and
                a.generation == ^environment.generation,
            order_by: w.id,
            limit: 1
          )
        )

      if existing do
        existing
      else
        case do_place_workload(%{
               tenant_id: tenant_id,
               environment_id: environment_id,
               provider_binding_id: binding.id,
               allocation_id: "allocation_" <> Ecto.UUID.generate(),
               workload_id: "workload_" <> Ecto.UUID.generate(),
               kind: "shell",
               template_key: "shell.default",
               capability_requirements: ["runtime_exec"]
             }) do
          {:ok, %{workload: workload}} -> workload
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  defp do_place_workload(attrs) when is_map(attrs) do
    capability_requirements = Map.get(attrs, :capability_requirements, [])

    with :ok <-
           required_strings(attrs, [
             :tenant_id,
             :allocation_id,
             :workload_id,
             :environment_id,
             :kind
           ]),
         :ok <- validate_capability_requirements(capability_requirements),
         %Environment{} = environment <- Repo.get(Environment, attrs.environment_id),
         true <- environment.tenant_id == attrs.tenant_id || {:error, :tenant_scope_mismatch},
         %Pool{} = pool <- Repo.get(Pool, environment.pool_id),
         true <-
           capabilities_supported?(pool, capability_requirements) ||
             {:error, :unsupported_capability},
         allowed_providers = provider_policy_providers(pool.provider_policy),
         %ProviderBinding{} = binding <-
           environment
           |> eligible_binding_query(allowed_providers)
           |> exact_placement_binding(Map.get(attrs, :provider_binding_id))
           |> Repo.one(),
         {:ok, allocation} <-
           allocate(%{
             id: attrs.allocation_id,
             environment_id: environment.id,
             provider_binding_id: binding.id,
             generation: environment.generation
           }),
         {:ok, workload} <-
           create_workload(%{
             id: attrs.workload_id,
             environment_id: environment.id,
             allocation_id: allocation.id,
             kind: attrs.kind,
             spec: Map.get(attrs, :spec, %{}),
             template_key: Map.get(attrs, :template_key),
             capability_requirements: capability_requirements,
             generation: environment.generation,
             creation_request_scope: Map.get(attrs, :creation_request_scope),
             creation_request_id: Map.get(attrs, :creation_request_id),
             creation_request_input: Map.get(attrs, :creation_request_input)
           }) do
      {:ok, %{allocation: allocation, workload: workload}}
    else
      nil -> {:error, :capacity_unavailable}
      false -> {:error, :unsupported_capability}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Ensure the durable placement half of a compute external-worker operation.

  The operation row is the retry and recovery SSOT for the boundary between
  Postgres placement and the AgentControl worker store. It deliberately stops
  at `placement_ready`: the caller creates the worker only after this function
  has committed the Workload, then calls `complete_external_worker_operation/3`.
  A synchronous caller supplies one bounded claim in `opts`; that claim fences
  the AgentControl crossing from the background reconciler. The reconciler
  already owns its claim before it enters this function and therefore omits
  the options.
  """
  def ensure_external_worker_placement(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    claim_token = Keyword.get(opts, :claim_token)
    claim_lease_expires_at = Keyword.get(opts, :claim_lease_expires_at)

    with :ok <-
           required_strings(attrs, [
             :tenant_id,
             :group_id,
             :operation_hash,
             :tool_call_id,
             :environment_id,
             :provider,
             :template_key,
             :allocation_id,
             :workload_id
           ]),
         :ok <- validate_external_worker_claim(claim_token, claim_lease_expires_at),
         {:ok, operation} <-
           get_or_insert_external_worker_operation(
             attrs,
             claim_token,
             claim_lease_expires_at
           ),
         {:ok, operation} <-
           claim_external_worker_operation(
             operation,
             claim_token,
             claim_lease_expires_at
           ) do
      reconcile_external_worker_placement(operation, attrs)
    end
  end

  @doc "Return one durable external-worker operation by its idempotency key."
  def get_external_worker_operation(tenant_id, group_id, operation_hash)
      when is_binary(tenant_id) and is_binary(group_id) and is_binary(operation_hash) do
    Repo.one(
      from(o in ExternalWorkerOperation,
        where:
          o.tenant_id == ^tenant_id and o.group_id == ^group_id and
            o.operation_hash == ^operation_hash
      )
    )
  end

  @doc "Mark the external-worker operation complete after AgentControl creation."
  def complete_external_worker_operation(operation_id, worker_id, claim_token \\ nil)
      when is_binary(operation_id) and is_binary(worker_id) and worker_id != "" do
    case Repo.transaction(fn ->
           operation =
             Repo.one!(
               from(o in ExternalWorkerOperation,
                 where: o.id == ^operation_id,
                 lock: "FOR UPDATE"
               )
             )

           cond do
             operation.state == "worker_ready" and operation.worker_id == worker_id ->
               operation

             operation.state == "placement_ready" and is_nil(operation.worker_id) and
                 claim_matches?(operation, claim_token) ->
               {1, _} =
                 Repo.update_all(
                   from(o in ExternalWorkerOperation, where: o.id == ^operation.id),
                   set: [
                     worker_id: worker_id,
                     state: "worker_ready",
                     next_retry_at: nil,
                     claim_token: nil,
                     lease_expires_at: nil,
                     last_error: %{},
                     updated_at: DateTime.utc_now()
                   ],
                   inc: [revision: 1]
                 )

               Repo.get!(ExternalWorkerOperation, operation.id)

             true ->
               Repo.rollback(:placement_required)
           end
         end) do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  @doc "Record a recoverable worker-side failure and apply bounded retry backoff."
  def record_external_worker_operation_error(operation_id, reason, claim_token \\ nil)
      when is_binary(operation_id) do
    case Repo.transaction(fn ->
           operation =
             Repo.one!(
               from(o in ExternalWorkerOperation,
                 where: o.id == ^operation_id,
                 lock: "FOR UPDATE"
               )
             )

           if not claim_matches?(operation, claim_token), do: Repo.rollback(:operation_claim_lost)

           now = DateTime.utc_now()
           delay_ms = min(60_000, 1_000 * Integer.pow(2, min(operation.attempt_count, 6)))

           {1, _} =
             Repo.update_all(
               from(o in ExternalWorkerOperation, where: o.id == ^operation.id),
               set: [
                 last_error: %{"code" => external_worker_error_code(reason)},
                 next_retry_at: DateTime.add(now, delay_ms, :millisecond),
                 claim_token: nil,
                 lease_expires_at: nil,
                 updated_at: now
               ],
               inc: [attempt_count: 1, revision: 1]
             )

           Repo.get!(ExternalWorkerOperation, operation.id)
         end) do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  defp get_or_insert_external_worker_operation(attrs, claim_token, claim_lease_expires_at) do
    operation_id =
      external_worker_operation_id(
        attrs.tenant_id,
        attrs.group_id,
        attrs.operation_hash
      )

    now = DateTime.utc_now()

    row = %{
      id: operation_id,
      tenant_id: attrs.tenant_id,
      group_id: attrs.group_id,
      operation_hash: attrs.operation_hash,
      tool_call_id: attrs.tool_call_id,
      environment_id: attrs.environment_id,
      provider: attrs.provider,
      template_key: attrs.template_key,
      allocation_id: nil,
      workload_id: nil,
      state: "placement_pending",
      attempt_count: 0,
      claim_token: claim_token,
      lease_expires_at: claim_lease_expires_at,
      last_error: %{},
      revision: 1,
      created_at: now,
      updated_at: now
    }

    case Repo.insert_all(ExternalWorkerOperation, [row],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :group_id, :tool_call_id]
         ) do
      {1, _} ->
        {:ok, Repo.get!(ExternalWorkerOperation, operation_id)}

      {0, _} ->
        operation =
          Repo.one(
            from(o in ExternalWorkerOperation,
              where:
                o.tenant_id == ^attrs.tenant_id and o.group_id == ^attrs.group_id and
                  o.tool_call_id == ^attrs.tool_call_id
            )
          ) ||
            Repo.one(
              from(o in ExternalWorkerOperation,
                where:
                  o.tenant_id == ^attrs.tenant_id and o.group_id == ^attrs.group_id and
                    o.operation_hash == ^attrs.operation_hash
              )
            )

        if operation, do: {:ok, operation}, else: {:error, :operation_conflict}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp validate_external_worker_claim(nil, nil), do: :ok

  defp validate_external_worker_claim(claim_token, %DateTime{} = expires_at)
       when is_binary(claim_token) and claim_token != "" do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :invalid_operation_claim}
  end

  defp validate_external_worker_claim(_claim_token, _expires_at),
    do: {:error, :invalid_operation_claim}

  defp claim_external_worker_operation(operation, nil, nil), do: {:ok, operation}

  defp claim_external_worker_operation(operation, claim_token, claim_lease_expires_at) do
    case Repo.transaction(fn ->
           current =
             Repo.one!(
               from(o in ExternalWorkerOperation,
                 where: o.id == ^operation.id,
                 lock: "FOR UPDATE"
               )
             )

           cond do
             current.state == "worker_ready" ->
               current

             claim_matches?(current, claim_token) ->
               current

             is_nil(current.claim_token) or claim_expired?(current) ->
               {1, _} =
                 Repo.update_all(
                   from(o in ExternalWorkerOperation, where: o.id == ^current.id),
                   set: [
                     claim_token: claim_token,
                     lease_expires_at: claim_lease_expires_at,
                     updated_at: DateTime.utc_now()
                   ]
                 )

               Repo.get!(ExternalWorkerOperation, current.id)

             true ->
               Repo.rollback(:operation_claimed)
           end
         end) do
      {:ok, current} -> {:ok, current}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  defp reconcile_external_worker_placement(operation, attrs) do
    case lock_external_worker_operation(operation, attrs) do
      {:ok, {:ready, current, placement}} ->
        {:ok, %{operation: current, workload: placement.workload}}

      {:ok, {:needs_placement, current}} ->
        case place_external_worker_workload(current, attrs) do
          {:ok, placement} -> commit_external_worker_placement(current, attrs, placement)
          {:error, reason} -> persist_external_worker_placement_error(current, reason)
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  defp lock_external_worker_operation(operation, attrs) do
    Repo.transaction(fn ->
      current =
        Repo.one!(
          from(o in ExternalWorkerOperation,
            where: o.id == ^operation.id,
            lock: "FOR UPDATE"
          )
        )

      case validate_external_worker_operation(current, attrs) do
        {:error, reason} ->
          {:error, reason}

        :ok ->
          case current.state do
            state when state in ["placement_ready", "worker_ready"] ->
              case existing_external_worker_placement(current, attrs) do
                {:ok, placement} -> {:ready, current, placement}
                {:error, reason} -> {:error, reason}
              end

            "placement_pending" ->
              {:needs_placement, current}

            _ ->
              {:error, :invalid_operation_state}
          end
      end
    end)
  end

  defp commit_external_worker_placement(operation, attrs, placement) do
    case Repo.transaction(fn ->
           current =
             Repo.one!(
               from(o in ExternalWorkerOperation,
                 where: o.id == ^operation.id,
                 lock: "FOR UPDATE"
               )
             )

           case validate_external_worker_operation(current, attrs) do
             {:error, reason} ->
               {:error, reason}

             :ok when current.state in ["placement_ready", "worker_ready"] ->
               case existing_external_worker_placement(current, attrs) do
                 {:ok, existing} ->
                   {:ok, %{operation: current, workload: existing.workload}}

                 {:error, reason} ->
                   {:error, reason}
               end

             :ok ->
               {1, _} =
                 Repo.update_all(
                   from(o in ExternalWorkerOperation, where: o.id == ^current.id),
                   set: [
                     allocation_id: placement.allocation.id,
                     workload_id: placement.workload.id,
                     state: "placement_ready",
                     next_retry_at: nil,
                     last_error: %{},
                     updated_at: DateTime.utc_now()
                   ],
                   inc: [revision: 1]
                 )

               {:ok,
                %{
                  operation: Repo.get!(ExternalWorkerOperation, current.id),
                  workload: placement.workload
                }}
           end
         end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  defp validate_external_worker_operation(operation, attrs) do
    immutable = [
      {:tenant_id, operation.tenant_id, attrs.tenant_id},
      {:group_id, operation.group_id, attrs.group_id},
      {:operation_hash, operation.operation_hash, attrs.operation_hash},
      {:tool_call_id, operation.tool_call_id, attrs.tool_call_id},
      {:environment_id, operation.environment_id, attrs.environment_id},
      {:provider, operation.provider, attrs.provider},
      {:template_key, operation.template_key, attrs.template_key},
      {:allocation_id, operation.allocation_id, attrs.allocation_id},
      {:workload_id, operation.workload_id, attrs.workload_id}
    ]

    if Enum.all?(immutable, fn
         {:allocation_id, nil, _expected} -> true
         {:workload_id, nil, _expected} -> true
         {_field, actual, expected} -> actual == expected
       end) do
      :ok
    else
      {:error, :operation_conflict}
    end
  end

  defp existing_external_worker_placement(operation, attrs) do
    with %Allocation{} = allocation <- Repo.get(Allocation, operation.allocation_id),
         %Workload{} = workload <- Repo.get(Workload, operation.workload_id),
         :ok <- validate_external_worker_placement(allocation, workload, attrs) do
      {:ok, %{allocation: allocation, workload: workload}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp place_external_worker_workload(operation, attrs) do
    placement_attrs = %{
      allocation_id: operation.allocation_id || attrs.allocation_id,
      workload_id: operation.workload_id || attrs.workload_id,
      environment_id: attrs.environment_id,
      kind: "external_worker",
      template_key: attrs.template_key,
      capability_requirements: ["runtime_exec", "runtime_process"],
      tenant_id: attrs.tenant_id
    }

    case place_workload(placement_attrs) do
      {:ok, placement} -> {:ok, placement}
      {:error, :already_exists} -> recover_external_worker_placement(operation, attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_external_worker_placement(operation, attrs) do
    allocation_id = operation.allocation_id || attrs.allocation_id
    workload_id = operation.workload_id || attrs.workload_id
    allocation = Repo.get(Allocation, allocation_id)
    workload = Repo.get(Workload, workload_id)

    cond do
      match?(%Workload{}, workload) and match?(%Allocation{}, allocation) ->
        case validate_external_worker_placement(allocation, workload, attrs) do
          :ok -> {:ok, %{allocation: allocation, workload: workload}}
          {:error, _} = error -> error
        end

      match?(%Allocation{}, allocation) ->
        case Repo.get(Environment, attrs.environment_id) do
          %Environment{} = environment ->
            workload_attrs = %{
              id: workload_id,
              environment_id: environment.id,
              allocation_id: allocation.id,
              kind: "external_worker",
              template_key: attrs.template_key,
              capability_requirements: ["runtime_exec", "runtime_process"],
              generation: environment.generation
            }

            case create_workload(workload_attrs) do
              {:ok, workload} ->
                case validate_external_worker_placement(allocation, workload, attrs) do
                  :ok -> {:ok, %{allocation: allocation, workload: workload}}
                  {:error, _} = error -> error
                end

              {:error, :already_exists} ->
                recover_external_worker_placement(operation, attrs)

              {:error, reason} ->
                {:error, reason}
            end

          nil ->
            {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  defp validate_external_worker_placement(allocation, workload, attrs) do
    environment = Repo.get(Environment, attrs.environment_id)

    cond do
      environment == nil ->
        {:error, :not_found}

      allocation.environment_id != environment.id ->
        {:error, :scope_mismatch}

      allocation.generation != environment.generation ->
        {:error, :stale_generation}

      workload.environment_id != environment.id ->
        {:error, :scope_mismatch}

      workload.allocation_id != allocation.id ->
        {:error, :scope_mismatch}

      workload.kind != "external_worker" ->
        {:error, :operation_conflict}

      workload.template_key != attrs.template_key ->
        {:error, :operation_conflict}

      workload.capability_requirements != ["runtime_exec", "runtime_process"] ->
        {:error, :operation_conflict}

      true ->
        :ok
    end
  end

  defp persist_external_worker_placement_error(operation, reason) do
    updated =
      Repo.update_all(
        from(o in ExternalWorkerOperation,
          where: o.id == ^operation.id and o.state == "placement_pending"
        ),
        set: [
          state: "placement_pending",
          next_retry_at: external_worker_next_retry_at(operation.attempt_count),
          claim_token: nil,
          lease_expires_at: nil,
          last_error: %{"code" => external_worker_error_code(reason)},
          updated_at: DateTime.utc_now()
        ],
        inc: [attempt_count: 1, revision: 1]
      )

    case updated do
      {1, _} -> {:error, reason}
      {0, _} -> {:error, :operation_changed}
    end
  end

  defp external_worker_operation_id(tenant_id, group_id, operation_hash) do
    digest =
      :crypto.hash(:sha256, Enum.join([tenant_id, group_id, operation_hash], ":"))
      |> Base.encode16(case: :lower)

    "external-worker-operation-" <> digest
  end

  defp external_worker_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp external_worker_error_code(_reason), do: "unavailable"

  defp claim_matches?(%ExternalWorkerOperation{claim_token: nil}, nil), do: true

  defp claim_matches?(
         %ExternalWorkerOperation{claim_token: token, lease_expires_at: expires_at},
         token
       )
       when is_binary(token) do
    match?(%DateTime{}, expires_at) and
      DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp claim_matches?(_, _), do: false

  defp claim_expired?(%ExternalWorkerOperation{lease_expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp claim_expired?(_operation), do: true

  defp external_worker_next_retry_at(attempt_count) do
    delay_ms = min(60_000, 1_000 * Integer.pow(2, min(attempt_count, 6)))
    DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
  end

  @doc "Record one provider observation for the exact Workload generation."
  def observe_workload(workload_id, expected_revision, generation, observed_state)
      when observed_state in ~w(pending ready draining stopped failed) do
    case Repo.update_all(
           from(w in Workload,
             where:
               w.id == ^workload_id and w.revision == ^expected_revision and
                 w.generation == ^generation
           ),
           set: [
             observed_state: observed_state,
             updated_at: DateTime.utc_now()
           ],
           inc: [revision: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(Workload, workload_id)}
      {0, _} -> {:error, :stale_generation}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Stop one exact Workload generation before its business owner becomes terminal."
  def stop_workload(workload_id, expected_revision, _reason)
      when is_binary(workload_id) and is_integer(expected_revision) do
    case Repo.transaction(fn ->
           workload =
             Repo.one!(from(w in Workload, where: w.id == ^workload_id, lock: "FOR UPDATE"))

           cond do
             workload.revision != expected_revision ->
               Repo.rollback(:revision_conflict)

             workload.desired_state == "stopped" ->
               workload

             workload.desired_state != "ready" ->
               Repo.rollback(:revision_conflict)

             true ->
               now = DateTime.utc_now()

               {1, _} =
                 Repo.update_all(
                   from(w in Workload, where: w.id == ^workload_id),
                   set: [desired_state: "stopped", updated_at: now],
                   inc: [revision: 1]
                 )

               # Revoke runtime admission in the same transaction as the
               # business stop. ComputeRuntimeCarrier takes the same workload
               # row lock before accepting a frame, so a terminal transition
               # cannot race a post-terminal insert.
               Repo.update_all(
                 from(r in RuntimeInstance,
                   where: r.workload_id == ^workload_id and r.generation == ^workload.generation
                 ),
                 set: [status: "closed", readiness: "pending", updated_at: now],
                 inc: [revision: 1]
               )

               Repo.delete_all(
                 from(c in ReconcilerClaim,
                   where:
                     c.provider == "agent_vmm" and c.workload_id == ^workload_id and
                       c.generation == ^workload.generation
                 )
               )

               # The Allocation owns its one terminal release obligation. The
               # state transition and Command insert share this transaction,
               # so a crash cannot leave a newly draining Allocation orphaned.
               drain_allocations_with_release!([workload.allocation_id], now)

               Repo.get!(Workload, workload_id)
           end
         end) do
      {:ok, workload} -> {:ok, workload}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  @doc "Accept a Provider completion only under the exact allocation generation and CAS revision."
  def observe_allocation(
        id,
        expected_revision,
        generation,
        status,
        outcome,
        observation \\ %{},
        opts \\ []
      )
      when status in @allocation_states and
             outcome in ~w(pending succeeded failed unknown_outcome) and
             is_map(observation) and is_list(opts) do
    now = DateTime.utc_now()
    retired_generation_release? = Keyword.get(opts, :retired_generation_release, false)
    merge_provider_observation? = Keyword.get(opts, :merge_provider_observation, false)
    authoritative_inventory? = Keyword.get(opts, :authoritative_inventory, false)

    Repo.transaction(fn ->
      locked_allocation =
        Repo.one(from(a in Allocation, where: a.id == ^id, lock: "FOR UPDATE"))

      if is_nil(locked_allocation), do: Repo.rollback(:not_found)
      if locked_allocation.status == "released", do: Repo.rollback(:allocation_released)

      # Host residency does not cancel the owner's terminal release intent.
      status =
        if authoritative_inventory? and locked_allocation.status == "draining" and
             status == "ready",
           do: "draining",
           else: status

      effective_observation =
        if merge_provider_observation? do
          Map.merge(locked_allocation.provider_observation || %{}, observation)
        else
          observation
        end

      updates = [
        status: status,
        operation_outcome: outcome,
        provider_observation: effective_observation,
        updated_at: now
      ]

      unchanged_authoritative_facts? =
        authoritative_inventory? and
          allocation_observation_current?(
            locked_allocation,
            expected_revision,
            generation,
            status,
            retired_generation_release?
          ) and
          locked_allocation.status == status and
          locked_allocation.operation_outcome == outcome and
          (locked_allocation.provider_observation || %{}) == effective_observation

      if unchanged_authoritative_facts? do
        sync_exact_release_obligation_revision!(locked_allocation, now)
        {:ok, locked_allocation}
      else
        case Repo.update_all(
               from(a in Allocation,
                 join: e in Environment,
                 on: e.id == a.environment_id,
                 where:
                   a.id == ^id and a.revision == ^expected_revision and
                     a.generation == ^generation and
                     (e.generation == ^generation or
                        (^retired_generation_release? and ^status == "released" and
                           e.generation > ^generation and
                           (a.status == "draining" or
                              (a.status == "ready" and
                                 fragment("?->>'allocation_state'", a.provider_observation) ==
                                   "retained"))))
               ),
               set: updates,
               inc: [revision: 1]
             ) do
          {1, _} ->
            allocation = Repo.get!(Allocation, id)

            if authoritative_inventory?,
              do: sync_exact_release_obligation_revision!(allocation, now)

            update_binding_observation(allocation.provider_binding_id, generation, observation)

            {:ok, allocation}

          {0, _} ->
            {:error, :stale_generation}
        end
      end
    end)
    |> case do
      {:ok, {:ok, allocation}} -> {:ok, allocation}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp allocation_observation_current?(
         allocation,
         expected_revision,
         generation,
         status,
         retired_generation_release?
       ) do
    environment = Repo.get!(Environment, allocation.environment_id)

    allocation.revision == expected_revision and allocation.generation == generation and
      (environment.generation == generation or
         (retired_generation_release? and status == "released" and
            environment.generation > generation and
            (allocation.status == "draining" or
               Map.get(allocation.provider_observation || %{}, "allocation_state") ==
                 "retained")))
  end

  @doc false
  def complete_discarded_release(id, expected_revision, generation, provider_revision)
      when is_binary(id) and is_integer(expected_revision) and is_integer(generation) and
             generation > 0 and is_integer(provider_revision) and provider_revision > 0 do
    Repo.transaction(fn ->
      allocation = Repo.one!(from(a in Allocation, where: a.id == ^id, lock: "FOR UPDATE"))
      environment = Repo.get!(Environment, allocation.environment_id)
      binding = Repo.get!(ProviderBinding, allocation.provider_binding_id)
      incarnation = release_incarnation(allocation.id, allocation.generation)

      command =
        Repo.one(
          from(c in Command,
            where:
              c.allocation_id == ^allocation.id and c.kind == "allocation.release" and
                c.release_incarnation == ^incarnation,
            lock: "FOR UPDATE"
          )
        )

      cond do
        binding.provider != "agent_vmm" ->
          Repo.rollback(:unsupported_provider)

        allocation.status == "released" ->
          Repo.rollback(:allocation_released)

        allocation.revision != expected_revision or allocation.generation != generation or
            environment.generation < generation ->
          Repo.rollback(:stale_generation)

        is_nil(command) ->
          Repo.rollback(:release_obligation_missing)

        command.workload_id != nil or command.target_generation != generation or
            command.target_revision != expected_revision ->
          Repo.rollback(:stale_release_obligation)

        allocation.status != "draining" and
            not (allocation.status == "ready" and
                     Map.get(allocation.provider_observation || %{}, "allocation_state") ==
                       "retained") ->
          Repo.rollback(:release_intent_not_current)

        true ->
          now = DateTime.utc_now()

          {1, _} =
            Repo.update_all(from(c in Command, where: c.id == ^command.id),
              set: [
                status: "succeeded",
                outcome: "succeeded",
                next_attempt_at: nil,
                evidence: %{"reason" => "authoritative_inventory_discarded"},
                updated_at: now
              ]
            )

          observation = %{
            "allocation_revision" => provider_revision,
            "allocation_state" => "discarded"
          }

          {1, _} =
            Repo.update_all(from(a in Allocation, where: a.id == ^allocation.id),
              set: [
                status: "released",
                operation_outcome: "succeeded",
                provider_observation:
                  Map.merge(allocation.provider_observation || %{}, observation),
                updated_at: now
              ],
              inc: [revision: 1]
            )

          update_binding_observation(allocation.provider_binding_id, generation, observation)
          {:ok, Repo.get!(Allocation, allocation.id)}
      end
    end)
    |> case do
      {:ok, {:ok, allocation}} -> {:ok, allocation}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  @doc "Merge one exact provider observation and remove obsolete facts."
  def observe_allocation_facts(id, expected_revision, generation, facts, obsolete_keys)
      when is_binary(id) and is_integer(expected_revision) and is_integer(generation) and
             is_map(facts) and is_list(obsolete_keys) do
    Repo.transaction(fn ->
      allocation =
        Repo.one!(from(a in Allocation, where: a.id == ^id, lock: "FOR UPDATE"))

      environment = Repo.get!(Environment, allocation.environment_id)

      if allocation.revision != expected_revision or allocation.generation != generation or
           environment.generation != generation do
        Repo.rollback(:stale_generation)
      end

      merged =
        (allocation.provider_observation || %{})
        |> Map.merge(facts)
        |> Map.drop(obsolete_keys)

      if merged == (allocation.provider_observation || %{}) do
        allocation
      else
        {1, _} =
          Repo.update_all(from(a in Allocation, where: a.id == ^id),
            set: [provider_observation: merged, updated_at: DateTime.utc_now()],
            inc: [revision: 1]
          )

        Repo.get!(Allocation, id)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def observe_runtime(attrs) when is_map(attrs) do
    with :ok <- required_strings(attrs, [:id, :workload_id, :allocation_id]),
         true <-
           (is_integer(attrs.generation) and attrs.generation > 0) ||
             {:error, :invalid_generation},
         true <- canonical_nonzero_uint64?(attrs.connection_epoch) || {:error, :invalid_epoch} do
      Repo.transaction(fn ->
        workload = Repo.get!(Workload, attrs.workload_id)
        allocation = Repo.get!(Allocation, attrs.allocation_id)

        if workload.allocation_id != allocation.id or workload.generation != attrs.generation do
          Repo.rollback(:stale_generation)
        end

        now = DateTime.utc_now()

        case Repo.get(RuntimeInstance, attrs.id) do
          nil ->
            {1, _} =
              Repo.insert_all(RuntimeInstance, [
                %{
                  id: attrs.id,
                  workload_id: workload.id,
                  allocation_id: allocation.id,
                  status: "connected",
                  readiness: "catching_up",
                  generation: attrs.generation,
                  connection_epoch: attrs.connection_epoch,
                  caught_up_epoch: "0",
                  revision: 1,
                  updated_at: now
                }
              ])

          current
          when current.generation == attrs.generation and
                 current.connection_epoch != attrs.connection_epoch ->
            # Agent VMM connection epochs are opaque random fences. A fresh
            # epoch replaces the previous owner regardless of numeric value;
            # old credentials and provider sessions are fenced by exact epoch
            # equality at their respective admission boundaries.
            {1, _} =
              Repo.update_all(from(r in RuntimeInstance, where: r.id == ^attrs.id),
                set: [
                  status: "connected",
                  readiness: "catching_up",
                  connection_epoch: attrs.connection_epoch,
                  bootstrap_consumed_epoch: nil,
                  updated_at: now
                ],
                inc: [revision: 1]
              )

            # A Runtime Agent may disappear after claiming a frame. Rebinding
            # pending and in-flight rows to the new fenced epoch makes a
            # reconnect a recovery boundary instead of stranding accepted work
            # in the old epoch.
            rebind_runtime_inputs(attrs, workload, now)

          current
          when current.generation == attrs.generation and
                 current.connection_epoch == attrs.connection_epoch and
                 current.status == "connected" ->
            :ok

          current
          when current.generation == attrs.generation and
                 current.connection_epoch == attrs.connection_epoch ->
            # A Host session can disappear while the connector connection (and
            # therefore its epoch) remains current. Re-opening that exact
            # fenced session is a runtime recovery boundary too: the gateway
            # must be able to admit the replacement tunnel before the new
            # Runtime Agent catches up.
            {1, _} =
              Repo.update_all(from(r in RuntimeInstance, where: r.id == ^attrs.id),
                set: [
                  status: "connected",
                  readiness: "catching_up",
                  caught_up_epoch: "0",
                  bootstrap_consumed_epoch: nil,
                  updated_at: now
                ],
                inc: [revision: 1]
              )

            rebind_runtime_inputs(attrs, workload, now)

          _ ->
            Repo.rollback(:stale_epoch)
        end

        Repo.get!(RuntimeInstance, attrs.id)
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Prepare the epoch-fenced bootstrap target without claiming Runtime Agent connectivity."
  def prepare_runtime_bootstrap(attrs) when is_map(attrs) do
    with :ok <- required_strings(attrs, [:id, :workload_id, :allocation_id]),
         true <-
           (is_integer(attrs.generation) and attrs.generation > 0) ||
             {:error, :invalid_generation},
         true <- canonical_nonzero_uint64?(attrs.connection_epoch) || {:error, :invalid_epoch} do
      Repo.transaction(fn ->
        workload = Repo.get!(Workload, attrs.workload_id)
        allocation = Repo.get!(Allocation, attrs.allocation_id)

        if workload.allocation_id != allocation.id or workload.generation != attrs.generation or
             workload.desired_state != "ready" do
          Repo.rollback(:stale_generation)
        end

        now = DateTime.utc_now()

        case Repo.one(from(r in RuntimeInstance, where: r.id == ^attrs.id, lock: "FOR UPDATE")) do
          nil ->
            {1, _} =
              Repo.insert_all(RuntimeInstance, [
                %{
                  id: attrs.id,
                  workload_id: workload.id,
                  allocation_id: allocation.id,
                  status: "disconnected",
                  readiness: "pending",
                  generation: attrs.generation,
                  connection_epoch: attrs.connection_epoch,
                  caught_up_epoch: "0",
                  revision: 1,
                  updated_at: now
                }
              ])

          current
          when current.generation == attrs.generation and
                 current.connection_epoch == attrs.connection_epoch ->
            :ok

          current when current.generation <= attrs.generation ->
            if Repo.exists?(
                 from(i in "compute_runtime_inputs",
                   where:
                     i.workload_id == ^attrs.workload_id and i.generation == ^attrs.generation and
                       i.status == "in_flight"
                 )
               ) do
              Repo.rollback(:runtime_execution_unresolved)
            end

            {1, _} =
              Repo.update_all(from(r in RuntimeInstance, where: r.id == ^attrs.id),
                set: [
                  status: "disconnected",
                  readiness: "pending",
                  connection_epoch: attrs.connection_epoch,
                  generation: attrs.generation,
                  allocation_id: attrs.allocation_id,
                  caught_up_epoch: "0",
                  bootstrap_consumed_epoch: nil,
                  updated_at: now
                ],
                inc: [revision: 1]
              )

          _ ->
            Repo.rollback(:stale_generation)
        end

        Repo.update_all(
          from(i in "compute_runtime_inputs",
            where:
              i.workload_id == ^attrs.workload_id and i.generation == ^attrs.generation and
                i.status == "pending"
          ),
          set: [connection_epoch: attrs.connection_epoch, updated_at: now]
        )

        Repo.get!(RuntimeInstance, attrs.id)
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp rebind_runtime_inputs(attrs, workload, now) do
    Repo.update_all(
      from(i in "compute_runtime_inputs",
        where:
          i.runtime_instance_id == ^attrs.id and i.workload_id == ^workload.id and
            i.generation == ^attrs.generation and i.status in ["pending", "in_flight"]
      ),
      set: [
        connection_epoch: attrs.connection_epoch,
        status: "pending",
        updated_at: now
      ]
    )
  end

  def complete_runtime_catch_up(id, expected_revision, connection_epoch) do
    if not canonical_nonzero_uint64?(connection_epoch) do
      {:error, :invalid_epoch}
    else
      already_caught_up =
        Repo.one(
          from(r in RuntimeInstance,
            join: w in Workload,
            on: w.id == r.workload_id,
            where:
              r.id == ^id and r.connection_epoch == ^connection_epoch and
                r.caught_up_epoch == ^connection_epoch and r.status == "connected" and
                r.readiness == "ready" and r.generation == w.generation and
                w.desired_state == "ready",
            select: r
          )
        )

      case already_caught_up do
        %RuntimeInstance{} = runtime ->
          {:ok, runtime}

        nil ->
          case Repo.update_all(
                 from(r in RuntimeInstance,
                   join: w in Workload,
                   on: w.id == r.workload_id,
                   where:
                     r.id == ^id and r.revision == ^expected_revision and
                       r.connection_epoch == ^connection_epoch and
                       r.caught_up_epoch != ^connection_epoch and
                       r.generation == w.generation and w.desired_state == "ready"
                 ),
                 set: [
                   readiness: "ready",
                   caught_up_epoch: connection_epoch,
                   updated_at: DateTime.utc_now()
                 ],
                 inc: [revision: 1]
               ) do
            {1, _} -> {:ok, Repo.get!(RuntimeInstance, id)}
            {0, _} -> {:error, :stale_epoch}
          end
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Open the Workload-scoped Runtime Agent carrier after validating its handshake."
  def open_runtime_carrier(token, attrs) when is_binary(token) and is_map(attrs) do
    Repo.transaction(fn ->
      case do_open_runtime_carrier(token, attrs) do
        {:ok, opened} -> opened
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def open_runtime_carrier(_, _), do: {:error, :invalid_runtime_handshake}

  defp do_open_runtime_carrier(token, attrs) do
    with 1 <- attrs["protocol_version"],
         supported_features when is_list(supported_features) <- attrs["supported_features"],
         input_cursor when is_binary(input_cursor) <- Map.get(attrs, "input_cursor", ""),
         event_cursor when is_binary(event_cursor) <- Map.get(attrs, "event_cursor", ""),
         {:ok, claims} <- WorkloadCredential.verify_unscoped(token),
         id when is_binary(id) <- claims["runtime_instance_id"],
         workload_id when is_binary(workload_id) <- claims["workload_id"],
         generation when is_integer(generation) and generation > 0 <- claims["generation"],
         connection_epoch when is_binary(connection_epoch) <- claims["connection_epoch"],
         true <- canonical_nonzero_uint64?(connection_epoch),
         %RuntimeInstance{workload_id: ^workload_id, generation: ^generation} = runtime <-
           Repo.get(RuntimeInstance, id),
         %Workload{
           id: ^workload_id,
           generation: ^generation,
           kind: kind,
           environment_id: environment_id,
           allocation_id: allocation_id
         } = workload <- Repo.get(Workload, workload_id),
         true <- kind in ["external_worker", "meeting_runtime"],
         %Environment{id: ^environment_id, tenant_id: tenant_id} <-
           Repo.get(Environment, environment_id),
         :ok <- validate_runtime_carrier_features(kind, supported_features),
         {:ok, auth} <- runtime_carrier_auth(claims),
         {:ok, runtime} <-
           maybe_observe_runtime_carrier(auth, runtime, workload, generation, connection_epoch),
         {:ok, runtime, credential} <-
           finish_runtime_carrier_open(auth, token, runtime, connection_epoch),
         {:ok, runtime} <-
           complete_runtime_catch_up_with_credential(
             credential["token"],
             runtime.id,
             runtime.revision,
             connection_epoch
           ),
         {:ok, input_cursor} <-
           reconcile_runtime_cursor(
             runtime.input_cursor,
             input_cursor,
             runtime.id,
             workload_id,
             generation
           ),
         {:ok, event_cursor} <-
           reconcile_runtime_cursor(
             runtime.event_cursor,
             event_cursor,
             runtime.id,
             workload_id,
             generation
           ) do
      {:ok,
       %{
         runtime: runtime,
         workload: workload,
         tenant_id: tenant_id,
         environment_id: environment_id,
         allocation_id: allocation_id,
         credential: credential,
         features: Enum.filter(@runtime_carrier_features, &(&1 in supported_features)),
         input_cursor: input_cursor,
         event_cursor: event_cursor
       }}
    else
      nil -> {:error, :runtime_not_found}
      false -> {:error, :invalid_runtime_handshake}
      {:error, _} = error -> error
      _ -> {:error, :invalid_runtime_handshake}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp validate_runtime_carrier_features(kind, supported) when is_list(supported) do
    server_required = required_features_for_kind(kind)

    if Enum.all?(server_required, &(&1 in supported)) and
         Enum.all?(supported, &(&1 in @runtime_carrier_features)) do
      :ok
    else
      {:error, :required_runtime_feature_missing}
    end
  end

  defp required_features_for_kind("external_worker"),
    do: ["runtime.input.v1", "runtime.event.v1", "runtime.auth.v1", "runtime.execution.v1"]

  defp required_features_for_kind("meeting_runtime"),
    do: ["runtime.input.v1", "runtime.event.v1"]

  defp runtime_carrier_auth(%{"scopes" => scopes, "credential_kind" => "runtime_epoch"}) do
    if scopes == ["runtime"], do: {:ok, :runtime}, else: {:error, :invalid_runtime_handshake}
  end

  defp runtime_carrier_auth(%{"scopes" => scopes}) do
    if scopes == ["bootstrap"],
      do: {:ok, :bootstrap},
      else: {:error, :invalid_runtime_handshake}
  end

  defp runtime_carrier_auth(_claims), do: {:error, :invalid_runtime_handshake}

  # A credential can resume only the execution identity already prepared by
  # the provider. It cannot choose an epoch or replay accepted work under a new one.
  defp maybe_observe_runtime_carrier(_auth, runtime, workload, generation, connection_epoch) do
    current =
      Repo.one!(from(r in RuntimeInstance, where: r.id == ^runtime.id, lock: "FOR UPDATE"))

    workload = Repo.one!(from(w in Workload, where: w.id == ^workload.id, lock: "FOR UPDATE"))

    cond do
      current.generation != generation or current.connection_epoch != connection_epoch or
        workload.generation != generation or workload.desired_state != "ready" ->
        {:error, :stale_epoch}

      not runtime_control_current?(current) ->
        {:error, runtime_control_error(current)}

      true ->
        if current.status != "connected" do
          Repo.update_all(from(r in RuntimeInstance, where: r.id == ^current.id),
            set: [
              status: "connected",
              readiness: "catching_up",
              caught_up_epoch: "0",
              updated_at: DateTime.utc_now()
            ],
            inc: [revision: 1]
          )
        end

        {:ok, Repo.get!(RuntimeInstance, current.id)}
    end
  end

  @doc false
  def runtime_control_error(runtime) do
    claim =
      Repo.get_by(ReconcilerClaim,
        provider: "agent_vmm",
        workload_id: runtime.workload_id,
        generation: runtime.generation
      )

    if claim && (claim.last_error || %{})["code"] == "runtime_recovery_expired",
      do: :runtime_recovery_expired,
      else: :runtime_control_unavailable
  end

  @doc "Check the current provider control authority without comparing its epoch to execution identity."
  def runtime_control_current?(runtime) do
    allocation = Repo.get(Allocation, runtime.allocation_id)
    binding = allocation && Repo.get(ProviderBinding, allocation.provider_binding_id)

    case binding do
      %ProviderBinding{provider: "agent_vmm"} ->
        case AgentVMM.current_host_session_for_workload(runtime.workload_id) do
          {:ok, session} ->
            facts = allocation.provider_observation || %{}

            session.allocation_id == runtime.allocation_id and
              facts["container_status"] == "running" and
              facts["runtime_container_instance_id"] not in [nil, ""] and
              facts["runtime_verified_host_epoch"] == session.connection_epoch and
              facts["runtime_execution_epoch"] == runtime.connection_epoch and
              facts["runtime_container_instance_id"] ==
                get_in(facts, ["current_container", "instance_id"]) and
              is_binary(facts["runtime_container_instance_id"])

          _ ->
            false
        end

      %ProviderBinding{} ->
        true

      _ ->
        false
    end
  end

  defp finish_runtime_carrier_open(:bootstrap, token, runtime, connection_epoch) do
    with {:ok, %{runtime: runtime, credential: credential}} <-
           exchange_runtime_bootstrap(
             token,
             runtime.id,
             connection_epoch
           ) do
      {:ok, runtime, credential}
    end
  end

  defp finish_runtime_carrier_open(:runtime, token, runtime, _connection_epoch),
    do: {:ok, runtime, %{"token" => token}}

  defp reconcile_runtime_cursor(nil, "", _runtime_id, _workload_id, _generation), do: {:ok, ""}

  defp reconcile_runtime_cursor(nil, cursor, runtime_id, workload_id, generation)
       when is_binary(cursor) and cursor != "" do
    case Repo.get_by(
           SalixStore.ComputeRuntimeCarrier.Input,
           id: cursor,
           runtime_instance_id: runtime_id,
           workload_id: workload_id
         ) do
      %SalixStore.ComputeRuntimeCarrier.Input{generation: ^generation} ->
        {:error, :stale_runtime_cursor}

      %SalixStore.ComputeRuntimeCarrier.Input{} ->
        # A cursor from a retired Workload generation cannot order inputs in
        # the new generation. Start at the beginning of the current fenced
        # stream; generation transitions reset the durable cursor as well.
        {:ok, ""}

      nil ->
        {:error, :invalid_runtime_cursor}
    end
  end

  defp reconcile_runtime_cursor(cursor, _requested, _runtime_id, _workload_id, _generation)
       when is_binary(cursor) and cursor == "",
       do: {:ok, ""}

  defp reconcile_runtime_cursor(cursor, _requested, runtime_id, workload_id, generation)
       when is_binary(cursor) do
    case Repo.get_by(
           SalixStore.ComputeRuntimeCarrier.Input,
           id: cursor,
           runtime_instance_id: runtime_id,
           workload_id: workload_id
         ) do
      %SalixStore.ComputeRuntimeCarrier.Input{generation: ^generation} ->
        {:ok, cursor}

      %SalixStore.ComputeRuntimeCarrier.Input{} ->
        # Keep reconnects across a generation fence self-contained even if a
        # pre-fix RuntimeInstance still contains its retired cursor.
        {:ok, ""}

      nil ->
        {:error, :invalid_runtime_cursor}
    end
  end

  @doc "Exchange the current epoch-bound bootstrap credential for a runtime credential."
  def exchange_runtime_bootstrap(token, id, connection_epoch)
      when is_binary(token) and is_binary(id) and is_binary(connection_epoch) do
    if not canonical_nonzero_uint64?(connection_epoch) do
      {:error, :invalid_epoch}
    else
      case Repo.transaction(fn ->
             runtime =
               Repo.one(
                 from(r in RuntimeInstance,
                   where: r.id == ^id,
                   lock: "FOR UPDATE"
                 )
               )

             if is_nil(runtime), do: Repo.rollback(:runtime_not_found)

             workload =
               Repo.one(
                 from(w in Workload,
                   where: w.id == ^runtime.workload_id,
                   lock: "FOR UPDATE"
                 )
               )

             if is_nil(workload), do: Repo.rollback(:runtime_not_found)

             if runtime.workload_id != workload.id or
                  runtime.generation != workload.generation or
                  runtime.connection_epoch != connection_epoch or
                  runtime.status != "connected" or workload.desired_state != "ready" do
               Repo.rollback(:stale_runtime_bootstrap)
             end

             case WorkloadCredential.verify_for_runtime(
                    token,
                    workload.id,
                    runtime.id,
                    workload.generation,
                    "bootstrap"
                  ) do
               {:ok, _claims} -> :ok
               {:error, reason} -> Repo.rollback(reason)
             end

             if runtime.bootstrap_consumed_epoch != connection_epoch do
               {1, _} =
                 Repo.update_all(
                   from(r in RuntimeInstance, where: r.id == ^runtime.id),
                   set: [
                     bootstrap_consumed_epoch: connection_epoch,
                     updated_at: DateTime.utc_now()
                   ],
                   inc: [revision: 1]
                 )
             end

             {:ok, credential} =
               WorkloadCredential.issue_for_runtime(
                 workload.id,
                 runtime.id,
                 ["runtime"],
                 900
               )

             %{runtime: Repo.get!(RuntimeInstance, runtime.id), credential: credential}
           end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def exchange_runtime_bootstrap(_, _, _), do: {:error, :invalid_runtime_bootstrap}

  @doc "Complete catch-up only for the current Runtime Agent credential."
  def complete_runtime_catch_up_with_credential(
        token,
        id,
        expected_revision,
        connection_epoch
      )
      when is_binary(token) and is_binary(id) and is_integer(expected_revision) and
             is_binary(connection_epoch) do
    with %RuntimeInstance{workload_id: workload_id, generation: generation} <-
           Repo.get(RuntimeInstance, id),
         {:ok, _claims} <-
           SalixStore.Compute.WorkloadCredential.verify_for_runtime(
             token,
             workload_id,
             id,
             generation,
             "runtime"
           ) do
      complete_runtime_catch_up(id, expected_revision, connection_epoch)
    else
      nil -> {:error, :runtime_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_workload_credential}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def update_environment_intent(id, expected_revision, attrs) when is_map(attrs) do
    desired_state = Map.get(attrs, :desired_state)
    retention = Map.get(attrs, :retention)
    pool_id = Map.get(attrs, :pool_id)

    with true <-
           (is_nil(desired_state) or desired_state in ~w(ready draining stopped revoked)) ||
             {:error, :invalid_desired_state},
         :ok <- if(is_nil(retention), do: :ok, else: validate_retention(retention)),
         true <- (is_nil(pool_id) or is_binary(pool_id)) || {:error, :invalid_pool} do
      Repo.transaction(fn ->
        environment = Repo.one!(from(e in Environment, where: e.id == ^id, lock: "FOR UPDATE"))

        if environment.revision != expected_revision or environment.desired_state == "revoked" do
          Repo.rollback(:revision_conflict)
        end

        validate_pool_assignment!(environment, pool_id)

        generation_change =
          (not is_nil(pool_id) and pool_id != environment.pool_id) or
            (not is_nil(desired_state) and desired_state != environment.desired_state)

        changes =
          [updated_at: DateTime.utc_now()]
          |> maybe_put(:desired_state, desired_state)
          |> maybe_put(:retention, retention)
          |> maybe_put(:pool_id, pool_id)
          |> maybe_put(:observed_state, if(generation_change, do: "pending"))

        increments = if generation_change, do: [revision: 1, generation: 1], else: [revision: 1]

        if generation_change do
          now = DateTime.utc_now()

          drain_environment_allocations_with_release!(
            environment.id,
            environment.generation,
            now
          )

          Repo.update_all(
            from(w in Workload,
              join: a in Allocation,
              on: a.id == w.allocation_id,
              where:
                w.environment_id == ^environment.id and
                  a.generation == ^environment.generation and w.desired_state == "ready"
            ),
            set: [desired_state: "draining", updated_at: now],
            inc: [revision: 1]
          )
        end

        {1, _} =
          Repo.update_all(from(e in Environment, where: e.id == ^id),
            set: changes,
            inc: increments
          )

        Repo.get!(Environment, id)
      end)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc false
  def drain_allocations_with_release!(allocation_ids, %DateTime{} = now)
      when is_list(allocation_ids) do
    ids = allocation_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [] do
      %{drained: 0, obligations_created: 0}
    else
      drain_release_rows!("a.id = ANY($2::text[])", [now, ids])
    end
  end

  defp drain_environment_allocations_with_release!(environment_id, generation, now) do
    drain_release_rows!(
      "a.environment_id = $2 AND a.generation = $3",
      [now, environment_id, generation]
    )
  end

  defp drain_release_rows!(scope_sql, params) do
    sql = """
    WITH drained AS (
      UPDATE compute_allocations AS a
      SET status = 'draining', revision = a.revision + 1, updated_at = $1
      WHERE #{scope_sql}
        AND a.status NOT IN ('draining', 'released', 'failed')
      RETURNING a.*
    ), agent_vmm_drained AS (
      SELECT d.*
      FROM drained AS d
      JOIN compute_provider_bindings AS b ON b.id = d.provider_binding_id
      WHERE b.provider = 'agent_vmm'
    ), release_shape AS (
      SELECT
        d.id AS allocation_id,
        count(c.id)::bigint AS release_count,
        COALESCE(
          bool_and(
            c.target_generation = d.generation
            AND c.status IN (
              'pending', 'admitted', 'executing', 'succeeded',
              'failed', 'unknown_outcome', 'cancelled'
            )
            AND (
              c.release_incarnation IS NULL
              OR c.release_incarnation = 'allocation.release:' || d.id || ':' || d.generation
            )
          ),
          TRUE
        ) AS exact
      FROM agent_vmm_drained AS d
      LEFT JOIN compute_commands AS c
        ON c.allocation_id = d.id AND c.kind = 'allocation.release'
      GROUP BY d.id
    ), invalid_release_shape AS (
      SELECT allocation_id
      FROM release_shape
      WHERE release_count > 1 OR (release_count = 1 AND NOT exact)
    ), adopted AS (
      UPDATE compute_commands AS c
      SET
        workload_id = NULL,
        target_ref = d.id,
        target_generation = d.generation,
        target_revision = d.revision,
        connection_epoch = '0',
        status = CASE WHEN c.status = 'cancelled' THEN 'failed' ELSE c.status END,
        outcome = CASE WHEN c.status = 'cancelled' THEN 'failed' ELSE c.outcome END,
        payload = jsonb_build_object(
          'command_json',
          jsonb_build_object(
            'commandId', c.id,
            'deadlineUnixMillis', floor(extract(epoch FROM (
              CASE WHEN c.status = 'cancelled' THEN $1 + interval '60 seconds' ELSE c.deadline_at END
            )) * 1000)::bigint,
            'targetRevision', COALESCE((d.provider_observation->>'allocation_revision')::bigint, 0),
            'releaseAllocation', jsonb_build_object(
              'allocationId', d.id,
              'expectedRevision', COALESCE((d.provider_observation->>'allocation_revision')::bigint, 0),
              'expectedGeneration', d.generation
            )
          )
        ),
        evidence = CASE WHEN c.status = 'cancelled' THEN '{}'::jsonb ELSE c.evidence END,
        deadline_at = CASE
          WHEN c.status = 'cancelled' THEN $1 + interval '60 seconds'
          ELSE c.deadline_at
        END,
        release_incarnation = 'allocation.release:' || d.id || ':' || d.generation,
        next_attempt_at = CASE
          WHEN c.status = 'cancelled' THEN $1
          WHEN c.status IN ('failed', 'unknown_outcome') THEN COALESCE(c.next_attempt_at, $1)
          ELSE c.next_attempt_at
        END,
        updated_at = $1
      FROM agent_vmm_drained AS d
      JOIN release_shape AS shape ON shape.allocation_id = d.id
      WHERE c.allocation_id = d.id
        AND c.kind = 'allocation.release'
        AND shape.release_count = 1
        AND shape.exact
      RETURNING c.id, c.allocation_id, c.status
    ), inserted AS (
      INSERT INTO compute_commands (
        id, allocation_id, workload_id, request_id, operation_id, target_ref,
        kind, classification, target_generation, target_revision,
        connection_epoch, status, outcome, payload, evidence,
        deadline_at, release_incarnation, next_attempt_at, attempt_count,
        created_at, updated_at
      )
      SELECT
        'release:' || d.id || ':' || d.generation,
        d.id,
        NULL,
        'allocation.release:' || d.id || ':' || d.generation,
        'release:' || d.id || ':' || d.generation,
        d.id,
        'allocation.release',
        'desired_state',
        d.generation,
        d.revision,
        '0',
        'pending',
        'pending',
        jsonb_build_object(
          'command_json',
          jsonb_build_object(
            'commandId', 'release:' || d.id || ':' || d.generation,
            'deadlineUnixMillis', floor(extract(epoch FROM ($1 + interval '60 seconds')) * 1000)::bigint,
            'targetRevision', COALESCE((d.provider_observation->>'allocation_revision')::bigint, 0),
            'releaseAllocation', jsonb_build_object(
              'allocationId', d.id,
              'expectedRevision', COALESCE((d.provider_observation->>'allocation_revision')::bigint, 0),
              'expectedGeneration', d.generation
            )
          )
        ),
        '{}'::jsonb,
        $1 + interval '60 seconds',
        'allocation.release:' || d.id || ':' || d.generation,
        NULL,
        0,
        $1,
        $1
      FROM agent_vmm_drained AS d
      JOIN release_shape AS shape ON shape.allocation_id = d.id
      WHERE shape.release_count = 0
      RETURNING id, allocation_id
    )
    SELECT
      (SELECT count(*) FROM drained)::bigint,
      (SELECT count(*) FROM agent_vmm_drained)::bigint,
      (SELECT count(*) FROM adopted)::bigint,
      (SELECT count(*) FROM inserted)::bigint,
      (SELECT count(*) FROM invalid_release_shape)::bigint,
      ARRAY(
        SELECT DISTINCT allocation_id
        FROM adopted
        WHERE status = 'succeeded'
        ORDER BY allocation_id
      )
    """

    try do
      case Repo.query!(sql, params).rows do
        [[drained, agent_vmm_drained, adopted, inserted, 0, succeeded_allocation_ids]]
        when agent_vmm_drained == adopted + inserted ->
          _settled_binding_ids =
            case succeeded_allocation_ids do
              [] ->
                []

              ids ->
                rows =
                  Repo.query!(
                    """
                    UPDATE compute_allocations
                    SET status = 'released', operation_outcome = 'succeeded',
                        revision = revision + 1, updated_at = $1
                    WHERE id = ANY($2::text[]) AND status = 'draining'
                    RETURNING provider_binding_id
                    """,
                    [hd(params), ids]
                  ).rows

                if length(rows) != length(ids), do: Repo.rollback(:release_obligation_conflict)
                List.flatten(rows)
            end

          %{drained: drained, obligations_created: inserted, obligations_adopted: adopted}

        [[drained, agent_vmm_drained, adopted, inserted, invalid, _succeeded_allocation_ids]] ->
          Logger.error("release obligation write mismatch",
            drained: drained,
            agent_vmm_drained: agent_vmm_drained,
            obligations_adopted: adopted,
            obligations_created: inserted,
            invalid_release_shapes: invalid
          )

          Repo.rollback(:release_obligation_conflict)
      end
    rescue
      Postgrex.Error -> Repo.rollback(:release_obligation_conflict)
    end
  end

  @doc "Return the allocation-owned release obligation for one exact incarnation."
  def release_obligation(allocation_id, generation)
      when is_binary(allocation_id) and is_integer(generation) and generation > 0 do
    incarnation = release_incarnation(allocation_id, generation)

    case Repo.get_by(Command,
           allocation_id: allocation_id,
           target_generation: generation,
           release_incarnation: incarnation,
           kind: "allocation.release"
         ) do
      %Command{} = command -> {:ok, command}
      nil -> {:error, :release_obligation_missing}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def release_incarnation(allocation_id, generation)
      when is_binary(allocation_id) and is_integer(generation) and generation > 0,
      do: "allocation.release:#{allocation_id}:#{generation}"

  @doc false
  def refresh_due_release_obligation(command_id, %DateTime{} = now)
      when is_binary(command_id) do
    case Repo.one(
           from(c in Command,
             join: a in Allocation,
             on: a.id == c.allocation_id,
             join: e in Environment,
             on: e.id == a.environment_id,
             join: b in ProviderBinding,
             on: b.id == a.provider_binding_id,
             where: c.id == ^command_id,
             select: {c, a, e.generation, b.provider, b.status}
           )
         ) do
      {%Command{} = command, %Allocation{} = allocation, environment_generation, "agent_vmm",
       binding_status} ->
        incarnation = release_incarnation(allocation.id, allocation.generation)

        cond do
          command.kind != "allocation.release" or command.release_incarnation != incarnation or
            command.workload_id != nil or command.target_generation != allocation.generation ->
            block_release_retry(command, "invalid_release_obligation", now)

          allocation.status == "released" ->
            {1, _} =
              Repo.update_all(from(c in Command, where: c.id == ^command.id),
                set: [
                  status: "succeeded",
                  outcome: "succeeded",
                  next_attempt_at: nil,
                  evidence: %{"reason" => "allocation_already_released"},
                  updated_at: now
                ]
              )

            {:ok, :settled}

          binding_status == "revoked" ->
            fail_revoked_release(command, allocation, now)

          environment_generation >= allocation.generation and
              (allocation.status == "draining" or
                 (allocation.status == "ready" and
                    Map.get(allocation.provider_observation || %{}, "allocation_state") ==
                      "retained")) ->
            deadline_at = DateTime.add(now, 60, :second)

            {1, _} =
              Repo.update_all(from(c in Command, where: c.id == ^command.id),
                set: [
                  status: "pending",
                  outcome: "pending",
                  target_revision: allocation.revision,
                  connection_epoch: "0",
                  payload: release_command_payload(allocation, command.id, deadline_at),
                  evidence: %{},
                  deadline_at: deadline_at,
                  next_attempt_at: nil,
                  updated_at: now
                ],
                inc: [attempt_count: 1]
              )

            {:ok, :reissued}

          true ->
            block_release_retry(command, "release_intent_not_current", now)
        end

      nil ->
        {:error, :not_found}

      {%Command{} = command, _allocation, _generation, _provider, _binding_status} ->
        block_release_retry(command, "unsupported_provider", now)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp fail_revoked_release(command, allocation, now) do
    case Repo.transaction(fn ->
           {allocation_updates, _} =
             Repo.update_all(
               from(a in Allocation,
                 where:
                   a.id == ^allocation.id and a.generation == ^allocation.generation and
                     a.status in ["ready", "draining"]
               ),
               set: [status: "failed", operation_outcome: "failed", updated_at: now],
               inc: [revision: 1]
             )

           if allocation_updates != 1 and allocation.status != "failed" do
             Repo.rollback(:release_obligation_conflict)
           end

           {1, _} =
             Repo.update_all(from(c in Command, where: c.id == ^command.id),
               set: [
                 status: "failed",
                 outcome: "failed",
                 next_attempt_at: nil,
                 evidence: %{
                   "reason" => "provider_binding_revoked",
                   "action" => "rebuild_provider_scope"
                 },
                 updated_at: now
               ]
             )

           {:error, :provider_binding_revoked}
         end) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp block_release_retry(command, reason, now) do
    {1, _} =
      Repo.update_all(from(c in Command, where: c.id == ^command.id),
        set: [
          next_attempt_at: nil,
          evidence: %{"reason" => reason, "action" => "run_release_obligation_audit"},
          updated_at: now
        ]
      )

    error =
      case reason do
        "invalid_release_obligation" -> :invalid_release_obligation
        "release_intent_not_current" -> :release_intent_not_current
        "unsupported_provider" -> :unsupported_provider
      end

    {:error, error}
  end

  defp release_command_payload(allocation, command_id, deadline_at) do
    provider_revision =
      case Map.get(allocation.provider_observation || %{}, "allocation_revision", 0) do
        revision when is_integer(revision) and revision >= 0 -> revision
        _ -> 0
      end

    %{
      "command_json" => %{
        "commandId" => command_id,
        "deadlineUnixMillis" => DateTime.to_unix(deadline_at, :millisecond),
        "targetRevision" => provider_revision,
        "releaseAllocation" => %{
          "allocationId" => allocation.id,
          "expectedRevision" => provider_revision,
          "expectedGeneration" => allocation.generation
        }
      }
    }
  end

  defp sync_exact_release_obligation_revision!(allocation, now) do
    binding = Repo.get!(ProviderBinding, allocation.provider_binding_id)

    if binding.provider == "agent_vmm" and allocation.status in ["ready", "draining"] do
      incarnation = release_incarnation(allocation.id, allocation.generation)

      command =
        Repo.one(
          from(c in Command,
            where:
              c.allocation_id == ^allocation.id and c.kind == "allocation.release" and
                is_nil(c.workload_id) and c.target_generation == ^allocation.generation and
                c.release_incarnation == ^incarnation and
                c.status in ["pending", "admitted", "executing", "failed", "unknown_outcome"],
            lock: "FOR UPDATE"
          )
        )

      if command && command.target_revision != allocation.revision do
        {1, _} =
          Repo.update_all(from(c in Command, where: c.id == ^command.id),
            set: [
              target_revision: allocation.revision,
              payload: release_command_payload(allocation, command.id, command.deadline_at),
              updated_at: now
            ]
          )
      end
    end

    :ok
  end

  @doc false
  def backfill_release_obligation(allocation_id, %DateTime{} = now)
      when is_binary(allocation_id) do
    provider =
      Repo.one(
        from(a in Allocation,
          join: b in ProviderBinding,
          on: b.id == a.provider_binding_id,
          where: a.id == ^allocation_id,
          select: {b.provider, b.provider_ref}
        )
      )

    Repo.transaction(fn ->
      allocation =
        Repo.one!(from(a in Allocation, where: a.id == ^allocation_id, lock: "FOR UPDATE"))

      binding = Repo.get!(ProviderBinding, allocation.provider_binding_id)

      if provider != {binding.provider, binding.provider_ref} do
        Repo.rollback(:provider_binding_changed)
      end

      release_required? = release_required?(allocation, binding)

      commands =
        Repo.all(
          from(c in Command,
            where: c.allocation_id == ^allocation.id and c.kind == "allocation.release",
            order_by: [asc: c.created_at, asc: c.id],
            lock: "FOR UPDATE"
          )
        )

      incarnation = release_incarnation(allocation.id, allocation.generation)

      case {binding.provider, commands} do
        {provider, [_ | _]} when provider != "agent_vmm" ->
          Repo.rollback(:unsupported_provider_release_obligation)

        {_provider, []} when release_required? ->
          row = release_command_row(allocation, now)

          case Repo.insert_all(Command, [row], on_conflict: :nothing) do
            {1, _} -> :inserted
            {0, _} -> :present
          end

        {_provider, []} ->
          :not_required

        {_provider,
         [
           %Command{
             target_generation: generation,
             release_incarnation: existing_incarnation,
             status: status
           } = command
         ]}
        when generation == allocation.generation and
               existing_incarnation in [nil, incarnation] and status in @command_states ->
          if command.status == "succeeded" and command.target_revision != allocation.revision do
            Repo.rollback(:stale_succeeded_release_obligation)
          end

          deadline_at = DateTime.add(now, 60, :second)

          restored_cancelled? = command.status == "cancelled"

          retry_at =
            if command.status in ["failed", "unknown_outcome", "cancelled"],
              do: now,
              else: command.next_attempt_at

          {1, _} =
            Repo.update_all(from(c in Command, where: c.id == ^command.id),
              set: [
                workload_id: nil,
                release_incarnation: incarnation,
                target_revision: allocation.revision,
                status: if(restored_cancelled?, do: "failed", else: command.status),
                outcome: if(restored_cancelled?, do: "failed", else: command.outcome),
                payload: release_command_payload(allocation, command.id, deadline_at),
                deadline_at: deadline_at,
                next_attempt_at: retry_at,
                evidence: if(restored_cancelled?, do: %{}, else: command.evidence),
                updated_at: now
              ]
            )

          if command.status == "succeeded" and allocation.status not in ["released", "failed"] do
            {1, _} =
              Repo.update_all(from(a in Allocation, where: a.id == ^allocation.id),
                set: [
                  status: "released",
                  operation_outcome: "succeeded",
                  updated_at: now
                ],
                inc: [revision: 1]
              )
          end

          cond do
            is_nil(existing_incarnation) -> :adopted
            restored_cancelled? -> :restored
            true -> :present
          end

        {_provider, [_command]} ->
          Repo.rollback(:invalid_release_obligation)

        {_provider, _commands} ->
          Repo.rollback(:duplicate_release_obligations)
      end
    end)
    |> case do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end

  defp release_required?(allocation, binding) do
    binding.provider == "agent_vmm" and
      (allocation.status == "draining" or
         (allocation.status == "ready" and
            Map.get(allocation.provider_observation || %{}, "allocation_state") == "retained"))
  end

  defp release_command_row(allocation, now) do
    incarnation = release_incarnation(allocation.id, allocation.generation)
    command_id = "release:#{allocation.id}:#{allocation.generation}"
    deadline_at = DateTime.add(now, 60, :second)

    %{
      id: command_id,
      allocation_id: allocation.id,
      workload_id: nil,
      request_id: incarnation,
      operation_id: command_id,
      target_ref: allocation.id,
      kind: "allocation.release",
      classification: "desired_state",
      target_generation: allocation.generation,
      target_revision: allocation.revision,
      connection_epoch: "0",
      status: "pending",
      outcome: "pending",
      payload: release_command_payload(allocation, command_id, deadline_at),
      evidence: %{},
      deadline_at: deadline_at,
      release_incarnation: incarnation,
      next_attempt_at: nil,
      attempt_count: 0,
      created_at: now,
      updated_at: now
    }
  end

  def issue_grant(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    with :ok <-
           required_strings(attrs, [
             :id,
             :tenant_id,
             :environment_id,
             :principal_type,
             :principal_id
           ]),
         %Environment{tenant_id: tenant_id} <- Repo.get(Environment, attrs.environment_id),
         true <- tenant_id == attrs.tenant_id || {:error, :scope_mismatch},
         :ok <- validate_grant_workload(attrs.environment_id, Map.get(attrs, :workload_id)),
         true <-
           (is_list(attrs.permissions) and Enum.all?(attrs.permissions, &(&1 in @permissions))) ||
             {:error, :invalid_permission},
         true <-
           (match?(%DateTime{}, attrs.expires_at) and
              DateTime.compare(attrs.expires_at, now) == :gt) || {:error, :invalid_expiry} do
      insert_one(Grant, %{
        id: attrs.id,
        tenant_id: attrs.tenant_id,
        environment_id: attrs.environment_id,
        workload_id: Map.get(attrs, :workload_id),
        principal_type: attrs.principal_type,
        principal_id: attrs.principal_id,
        permissions: attrs.permissions,
        revision: 1,
        expires_at: attrs.expires_at,
        created_at: now
      })
    else
      nil -> {:error, :environment_not_found}
      {:error, _} = error -> error
      false -> {:error, :invalid}
    end
  end

  def revoke_grant(tenant_id, id, expected_revision) do
    case Repo.update_all(
           from(g in Grant,
             where:
               g.id == ^id and g.tenant_id == ^tenant_id and g.revision == ^expected_revision and
                 is_nil(g.revoked_at)
           ),
           set: [revoked_at: DateTime.utc_now()],
           inc: [revision: 1]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :revision_conflict}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Resolve a stable grant to its current Workload only at the point of use."
  def authorize_workload_grant(tenant_id, grant_id, environment_id, principal_id, permission)
      when is_binary(permission) do
    now = DateTime.utc_now()

    with %Grant{} = grant <- Repo.get(Grant, grant_id),
         true <- grant.tenant_id == tenant_id || {:error, :scope_mismatch},
         true <- grant.environment_id == environment_id || {:error, :scope_mismatch},
         true <-
           (grant.principal_type == "agent" and grant.principal_id == principal_id) ||
             {:error, :unauthorized},
         true <- is_nil(grant.revoked_at) || {:error, :revoked},
         true <- DateTime.compare(grant.expires_at, now) == :gt || {:error, :expired},
         true <- permission in grant.permissions || {:error, :unauthorized},
         %Workload{} = workload <- Repo.get(Workload, grant.workload_id),
         %Environment{} = environment <- Repo.get(Environment, environment_id),
         %Allocation{} = allocation <- Repo.get(Allocation, workload.allocation_id),
         true <- workload.environment_id == environment.id || {:error, :scope_mismatch},
         true <- allocation.environment_id == environment.id || {:error, :scope_mismatch},
         true <- allocation.generation == environment.generation || {:error, :stale_generation},
         true <-
           (workload.desired_state == "ready" and environment.desired_state == "ready") ||
             {:error, :revoked} do
      {:ok, workload}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Dispatch a Workload operation without exposing the Provider host client to agents."
  def call_workload(operation, args, workload_id) do
    case workload_provider(workload_id) do
      {:ok, "agent_vmm"} ->
        SalixStore.AgentVMMHostClient.call(operation, args, workload_id)

      {:ok, _provider} ->
        {:error, :unsupported_workload_operation}

      {:error, _} = error ->
        error
    end
  end

  @doc "Build the non-secret exact target carried by one authenticated Runtime Agent."
  def runtime_execution_target(%RuntimeInstance{} = runtime, %Workload{} = workload) do
    with true <- runtime.workload_id == workload.id || {:error, :scope_mismatch},
         true <- runtime.generation == workload.generation || {:error, :stale_generation},
         {:ok, target} <- SalixStore.AgentVMMHostClient.execution_target(workload.id) do
      {:ok,
       Map.merge(target, %{
         "runtime_instance_id" => runtime.id,
         "runtime_generation" => runtime.generation,
         "runtime_connection_epoch" => runtime.connection_epoch
       })}
    else
      {:error, _} = error -> error
      false -> {:error, :scope_mismatch}
    end
  end

  @doc "Apply a bounded execution operation for the exact authenticated Runtime Agent."
  def runtime_execution(action, attrs, runtime_identity)
      when action in ~w(acquire release list) and is_map(attrs) and is_map(runtime_identity) do
    target = attrs["target"]

    with true <- is_map(target) || {:error, :invalid_runtime_execution_target},
         true <-
           target["runtime_instance_id"] == runtime_identity.runtime_instance_id ||
             {:error, :runtime_execution_target_changed},
         true <-
           target["runtime_generation"] == runtime_identity.generation ||
             {:error, :runtime_execution_target_changed},
         true <-
           target["workload_id"] == runtime_identity.workload_id ||
             {:error, :runtime_execution_target_changed},
         true <-
           action != "acquire" ||
             target["runtime_connection_epoch"] == runtime_identity.connection_epoch ||
             {:error, :runtime_execution_target_changed} do
      SalixStore.AgentVMMHostClient.runtime_execution(
        action,
        attrs,
        runtime_identity.workload_id
      )
    else
      {:error, _} = error -> error
    end
  end

  def runtime_execution(_, _, _), do: {:error, :invalid_runtime_execution}

  @doc "Dispatch through the provider-neutral runtime operation vocabulary."
  def dispatch_workload(operation, args, workload_id)
      when operation in [
             "compute.exec",
             "process.start",
             "process.list",
             "process.write",
             "process.tail",
             "process.stop",
             "compute.build.run"
           ] do
    case workload_provider(workload_id) do
      {:ok, "agent_vmm"} ->
        client = SalixStore.AgentVMMHostClient

        function =
          case operation do
            "compute.exec" -> :exec_workload
            "process.start" -> :start_process
            "process.list" -> :list_processes
            "process.write" -> :write_process
            "process.tail" -> :tail_process
            "process.stop" -> :stop_process
            "compute.build.run" -> :build_workload
          end

        apply(client, function, [args, workload_id])

      {:ok, _provider} ->
        {:error, :unsupported_workload_operation}

      {:error, _} = error ->
        error
    end
  end

  @doc "Return a bounded Workload activity projection for one local provider binding."
  def work_activity(tenant_id, provider_ref)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(provider_ref) and
             provider_ref != "" do
    binding_exists? =
      Repo.exists?(
        from(b in ProviderBinding,
          join: p in Pool,
          on: p.id == b.pool_id,
          where:
            p.tenant_id == ^tenant_id and b.provider == "agent_vmm" and
              b.provider_ref == ^provider_ref,
          select: 1
        )
      )

    if binding_exists? do
      ready_workloads =
        Repo.one(
          from(w in Workload,
            join: a in Allocation,
            on: a.id == w.allocation_id,
            join: b in ProviderBinding,
            on: b.id == a.provider_binding_id,
            join: e in Environment,
            on: e.id == w.environment_id,
            where:
              e.tenant_id == ^tenant_id and b.provider == "agent_vmm" and
                b.provider_ref == ^provider_ref and e.desired_state == "ready" and
                w.desired_state == "ready" and w.observed_state == "ready" and
                a.status == "ready",
            select: count(w.id)
          )
        ) || 0

      active_operations =
        Repo.one(
          from(c in Command,
            join: w in Workload,
            on: w.id == c.workload_id,
            join: a in Allocation,
            on: a.id == w.allocation_id,
            join: b in ProviderBinding,
            on: b.id == a.provider_binding_id,
            join: e in Environment,
            on: e.id == w.environment_id,
            where:
              e.tenant_id == ^tenant_id and b.provider == "agent_vmm" and
                b.provider_ref == ^provider_ref and e.desired_state == "ready" and
                w.desired_state == "ready" and c.status in ["admitted", "executing"],
            select: count(c.id)
          )
        ) || 0

      {:ok,
       %{
         "activity" => if(active_operations > 0, do: "active", else: "idle"),
         "active_operation_count" => active_operations,
         "workload_count" => ready_workloads
       }}
    else
      {:error, :invalid_provider_binding}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def work_activity(_, _), do: {:error, :invalid_provider_binding}

  @doc false
  def park_capacity_action_required_locked(%Command{} = command, evidence)
      when is_map(evidence) do
    dimension = get_in(evidence, ["result", "capacityDimension"])

    resource =
      case dimension do
        "CAPACITY_DIMENSION_STORAGE_HEADROOM" -> "storage_headroom"
        "CAPACITY_DIMENSION_IMPORT_SLOT" -> "import_slot"
        _ -> nil
      end

    if is_binary(command.workload_id) and is_binary(resource) do
      now = DateTime.utc_now()

      row = %{
        id: "agent_vmm:#{command.workload_id}:#{command.target_generation}",
        provider: "agent_vmm",
        workload_id: command.workload_id,
        generation: command.target_generation,
        claim_token: "capacity-action-required",
        attempt_count: 1,
        next_retry_at: nil,
        lease_expires_at: nil,
        last_error: %{
          "kind" => "action_required",
          "code" => "resource_capacity_exhausted",
          "resource" => resource
        },
        created_at: now,
        updated_at: now
      }

      Repo.insert_all(ReconcilerClaim, [row],
        conflict_target: [:provider, :workload_id, :generation],
        on_conflict: [
          set: [
            claim_token: row.claim_token,
            next_retry_at: nil,
            lease_expires_at: nil,
            last_error: row.last_error,
            updated_at: now
          ]
        ]
      )

      :ok
    else
      {:error, :capacity_dimension_required}
    end
  end

  @doc false
  def lock_provider_bindings!(provider_ref) when is_binary(provider_ref) do
    Repo.all(
      from(b in ProviderBinding,
        where: b.provider == "agent_vmm" and b.provider_ref == ^provider_ref,
        order_by: [asc: b.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp workload_provider(workload_id) do
    case Repo.one(
           from(w in Workload,
             join: a in Allocation,
             on: a.id == w.allocation_id,
             join: b in ProviderBinding,
             on: b.id == a.provider_binding_id,
             where: w.id == ^workload_id,
             select: b.provider
           )
         ) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def enqueue_command(attrs) when is_map(attrs) do
    case enqueue_command_with_status(attrs) do
      {:ok, command, _status} -> {:ok, command}
      other -> other
    end
  end

  @doc false
  def enqueue_command_with_status(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    cond do
      Map.get(attrs, :classification) not in @command_classes ->
        {:error, :invalid_classification}

      not match?(%DateTime{}, Map.get(attrs, :deadline_at)) ->
        {:error, :invalid_deadline}

      DateTime.compare(attrs.deadline_at, now) != :gt ->
        {:error, :expired}

      true ->
        Repo.transaction(fn ->
          allocation =
            Repo.one(
              from(a in Allocation, where: a.id == ^attrs.allocation_id, lock: "FOR UPDATE")
            )

          environment = allocation && Repo.get(Environment, allocation.environment_id)

          cond do
            allocation == nil or environment == nil ->
              Repo.rollback(:stale_generation)

            allocation.status == "released" ->
              Repo.rollback(:allocation_released)

            not command_generation_current?(allocation, environment, attrs) or
                allocation.revision != attrs.target_revision ->
              Repo.rollback(:stale_generation)

            true ->
              row = %{
                id: attrs.id,
                allocation_id: attrs.allocation_id,
                workload_id: Map.get(attrs, :workload_id),
                request_id: attrs.request_id,
                operation_id: Map.get(attrs, :operation_id, attrs.id),
                target_ref:
                  Map.get(attrs, :target_ref, Map.get(attrs, :workload_id, attrs.allocation_id)),
                kind: attrs.kind,
                classification: attrs.classification,
                target_generation: attrs.target_generation,
                target_revision: attrs.target_revision,
                connection_epoch:
                  Map.get(attrs, :connection_epoch, provider_connection_epoch(allocation)),
                status: "pending",
                outcome: "pending",
                payload: Map.get(attrs, :payload, %{}),
                evidence: %{},
                deadline_at: attrs.deadline_at,
                created_at: now,
                updated_at: now
              }

              case Repo.insert_all(Command, [row],
                     on_conflict: :nothing,
                     conflict_target: [:allocation_id, :request_id]
                   ) do
                {1, _} ->
                  {Repo.get!(Command, attrs.id), :created}

                {0, _} ->
                  existing =
                    Repo.one!(
                      from(c in Command,
                        where:
                          c.allocation_id == ^attrs.allocation_id and
                            c.request_id == ^attrs.request_id,
                        lock: "FOR UPDATE"
                      )
                    )

                  if retryable_attempt?(existing, row, now) do
                    {1, _} =
                      Repo.update_all(from(c in Command, where: c.id == ^existing.id),
                        set: [
                          id: row.id,
                          workload_id: row.workload_id,
                          status: "pending",
                          operation_id: row.operation_id,
                          target_ref: row.target_ref,
                          target_revision: row.target_revision,
                          connection_epoch: row.connection_epoch,
                          outcome: "pending",
                          payload: row.payload,
                          evidence: %{},
                          deadline_at: row.deadline_at,
                          created_at: now,
                          updated_at: now
                        ]
                      )

                    {Repo.get!(Command, attrs.id), :reissued}
                  else
                    {existing, :existing}
                  end
              end
          end
        end)
        |> case do
          {:ok, {command, status}} -> {:ok, command, status}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp command_generation_current?(allocation, environment, attrs) do
    exact_allocation_generation? = allocation.generation == attrs.target_generation

    current_generation? = allocation.generation == environment.generation

    retired_generation_release? =
      attrs.kind == "allocation.release" and allocation.generation < environment.generation and
        (allocation.status == "draining" or
           Map.get(allocation.provider_observation || %{}, "allocation_state") == "retained")

    exact_allocation_generation? and (current_generation? or retired_generation_release?)
  end

  defp retryable_attempt?(existing, incoming, now) do
    existing.kind == incoming.kind and
      existing.classification == incoming.classification and
      existing.classification in ["read_only", "desired_state"] and
      (existing.status == "failed" or
         (existing.status in ["pending", "admitted", "executing"] and
            DateTime.compare(existing.deadline_at, now) != :gt))
  end

  def claim_commands(provider_binding_id, generation, limit \\ 32)
      when is_binary(provider_binding_id) and is_integer(generation) and limit in 1..32 do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      commands =
        Repo.all(
          from(c in Command,
            join: a in Allocation,
            on: a.id == c.allocation_id,
            where:
              a.provider_binding_id == ^provider_binding_id and a.generation == ^generation and
                a.status != "released" and
                c.target_generation == a.generation and c.target_revision == a.revision and
                c.status == "pending" and c.deadline_at > ^now,
            order_by: [asc: c.created_at, asc: c.id],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      ids = Enum.map(commands, & &1.id)

      if ids != [],
        do:
          Repo.update_all(from(c in Command, where: c.id in ^ids),
            set: [status: "admitted", updated_at: now]
          )

      Enum.map(ids, &Repo.get!(Command, &1))
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def record_command_result(id, from_states, status, evidence)
      when is_list(from_states) and status in @command_states and is_map(evidence) do
    case Repo.get(Command, id) do
      %Command{kind: "allocation.release"} ->
        {:error, :release_requires_commit}

      %Command{} ->
        case Repo.update_all(
               from(c in Command,
                 where:
                   c.id == ^id and c.kind != "allocation.release" and c.status in ^from_states
               ),
               set: [
                 status: status,
                 outcome: command_outcome(status),
                 evidence: evidence,
                 updated_at: DateTime.utc_now()
               ]
             ) do
          {1, _} -> {:ok, Repo.get!(Command, id)}
          {0, _} -> {:error, :stale_command}
        end

      nil ->
        {:error, :stale_command}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "On transport loss, replay reads/desired-state and fence side effects as unknown."
  def mark_provider_connection_lost(provider_binding_id) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      base =
        from(c in Command,
          join: a in Allocation,
          on: a.id == c.allocation_id,
          where:
            a.provider_binding_id == ^provider_binding_id and
              c.target_generation == a.generation and c.status in ["admitted", "executing"]
        )

      {unknown, _} =
        Repo.update_all(from(c in base, where: c.classification == "side_effecting"),
          set: [status: "unknown_outcome", outcome: "unknown", updated_at: now]
        )

      {pending, _} =
        Repo.update_all(
          from(c in base, where: c.classification in ["read_only", "desired_state"]),
          set: [status: "pending", outcome: "pending", updated_at: now]
        )

      %{unknown_outcome: unknown, pending: pending}
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def mark_provider_connections_lost(provider, provider_ref)
      when is_binary(provider) and is_binary(provider_ref) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      base =
        from(c in Command,
          join: a in Allocation,
          on: a.id == c.allocation_id,
          join: b in ProviderBinding,
          on: b.id == a.provider_binding_id,
          where:
            b.provider == ^provider and b.provider_ref == ^provider_ref and
              c.target_generation == a.generation and c.status in ["admitted", "executing"]
        )

      {unknown, _} =
        Repo.update_all(from(c in base, where: c.classification == "side_effecting"),
          set: [status: "unknown_outcome", outcome: "unknown", updated_at: now]
        )

      {pending, _} =
        Repo.update_all(
          from(c in base, where: c.classification in ["read_only", "desired_state"]),
          set: [status: "pending", outcome: "pending", updated_at: now]
        )

      %{unknown_outcome: unknown, pending: pending}
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  def reconcile_inventory(environment_id, expected_revision, watermark, observed_state)
      when observed_state in @environment_states and is_integer(watermark) and watermark >= 0 do
    case Repo.update_all(
           from(e in Environment,
             where:
               e.id == ^environment_id and e.revision == ^expected_revision and
                 e.inventory_watermark <= ^watermark
           ),
           set: [
             inventory_watermark: watermark,
             observed_state: observed_state,
             updated_at: DateTime.utc_now()
           ],
           inc: [revision: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(Environment, environment_id)}
      {0, _} -> {:error, :revision_conflict}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "A bounded, pre-shaped projection for one exact product owner."
  def project(tenant_id, owner_type, owner_id, limit \\ 50)
      when is_binary(tenant_id) and owner_type in ["project", "swarm", "group"] and
             is_binary(owner_id) and
             limit in 1..100 do
    environments =
      Repo.all(
        from(e in Environment,
          where:
            e.tenant_id == ^tenant_id and e.owner_type == ^owner_type and e.owner_id == ^owner_id,
          order_by: [desc: e.updated_at, desc: e.id],
          limit: ^limit
        )
      )

    environment_ids = Enum.map(environments, & &1.id)

    allocations =
      Repo.all(
        from(a in Allocation,
          where: a.environment_id in ^environment_ids,
          order_by: [desc: a.updated_at, desc: a.id],
          limit: ^limit
        )
      )

    allocation_ids = Enum.map(allocations, & &1.id)

    workloads =
      Repo.all(
        from(w in Workload,
          where: w.environment_id in ^environment_ids,
          order_by: [desc: w.updated_at, desc: w.id],
          limit: ^limit
        )
      )

    workload_ids = Enum.map(workloads, & &1.id)

    runtimes =
      Repo.all(
        from(r in RuntimeInstance,
          where: r.allocation_id in ^allocation_ids and r.workload_id in ^workload_ids,
          order_by: [desc: r.updated_at, desc: r.id],
          limit: ^limit
        )
      )

    grants =
      Repo.all(
        from(g in Grant,
          where: g.tenant_id == ^tenant_id and g.environment_id in ^environment_ids,
          order_by: [desc: g.created_at, desc: g.id],
          limit: ^limit
        )
      )

    {:ok,
     %{
       environments: environments,
       allocations: allocations,
       workloads: workloads,
       runtimes: runtimes,
       grants: grants
     }}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Page one owner's Workloads with an immutable ID cursor."
  def project_page(tenant_id, owner_type, owner_id, options) do
    limit = Map.get(options, :limit, 50)

    if is_integer(limit) and limit in 1..100,
      do: do_project_page(tenant_id, owner_type, owner_id, options, limit),
      else: {:error, :invalid}
  end

  defp do_project_page(tenant_id, owner_type, owner_id, options, limit) do
    workload_after = Map.get(options, :workload_after, "")

    environments =
      Repo.all(
        from(e in Environment,
          where:
            e.tenant_id == ^tenant_id and e.owner_type == ^owner_type and e.owner_id == ^owner_id,
          order_by: e.id,
          limit: ^(limit + 1)
        )
      )

    workloads =
      Repo.all(
        from(w in Workload,
          join: e in Environment,
          on: e.id == w.environment_id,
          where:
            e.tenant_id == ^tenant_id and e.owner_type == ^owner_type and e.owner_id == ^owner_id and
              w.id > ^workload_after,
          order_by: w.id,
          limit: ^(limit + 1)
        )
      )

    {workloads, workload_cursor} = resource_page(workloads, limit)
    page_environment_ids = Enum.map(environments, & &1.id)

    available_ids =
      Repo.all(
        from(e in Environment,
          join: p in Pool,
          on: p.id == e.pool_id,
          join: b in ProviderBinding,
          on: b.pool_id == p.id,
          where:
            e.id in ^page_environment_ids and e.desired_state == "ready" and p.status == "active" and
              b.status == "available" and (is_nil(b.environment_id) or b.environment_id == e.id),
          distinct: e.id,
          select: e.id
        )
      )

    environments = Enum.map(environments, &Map.put(&1, :can_create, &1.id in available_ids))

    allocation_ids = Enum.map(workloads, & &1.allocation_id)
    workload_ids = Enum.map(workloads, & &1.id)
    environment_ids = Enum.map(environments, & &1.id)
    allocations = Repo.all(from(a in Allocation, where: a.id in ^allocation_ids))

    runtimes =
      Repo.all(
        from(r in RuntimeInstance,
          where: r.workload_id in ^workload_ids and r.allocation_id in ^allocation_ids,
          distinct: r.workload_id,
          order_by: [asc: r.workload_id, desc: r.updated_at, desc: r.id]
        )
      )

    binding_ids = Enum.map(allocations, & &1.provider_binding_id)
    bindings = Repo.all(from(b in ProviderBinding, where: b.id in ^binding_ids))

    claims =
      Repo.all(
        from(c in ReconcilerClaim,
          join: w in Workload,
          on: w.id == c.workload_id and w.generation == c.generation,
          where: w.id in ^workload_ids,
          select: c
        )
      )

    grants =
      Repo.all(
        from(g in Grant,
          where: g.tenant_id == ^tenant_id and g.environment_id in ^environment_ids,
          order_by: [desc: g.created_at, desc: g.id],
          limit: ^limit
        )
      )

    {:ok,
     %{
       environments: environments,
       workloads: workloads,
       allocations: allocations,
       runtimes: runtimes,
       grants: grants,
       bindings: bindings,
       claims: claims,
       next_workload_cursor: workload_cursor
     }}
  rescue
    _ -> {:error, :unavailable}
  end

  defp resource_page(rows, limit) do
    page = Enum.take(rows, limit)
    {page, if(length(rows) > limit, do: List.last(page).id, else: nil)}
  end

  def validate_external_worker_binding(binding) when is_map(binding) do
    keys = binding |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()
    kind = Map.get(binding, "kind") || Map.get(binding, :kind)
    runtime_spec = Map.get(binding, "runtime_spec") || Map.get(binding, :runtime_spec) || %{}

    cond do
      not MapSet.subset?(keys, @binding_keys) -> {:error, :unknown_field}
      contains_provider_native_key?(runtime_spec) -> {:error, :provider_native_identity}
      kind == "connected_runtime" -> validate_connected_binding(binding, runtime_spec)
      kind == "compute_workload" -> validate_compute_binding(binding, runtime_spec)
      true -> {:error, :unknown_binding_kind}
    end
  end

  def put_external_worker_binding(attrs, binding) when is_map(attrs) and is_map(binding) do
    with :ok <- required_strings(attrs, [:id, :tenant_id, :agent_id]),
         {:ok, normalized} <- validate_external_worker_binding(binding) do
      now = DateTime.utc_now()

      row =
        Map.merge(normalized, %{
          id: attrs.id,
          tenant_id: attrs.tenant_id,
          agent_id: attrs.agent_id,
          status: "inactive",
          binding_revision: 1,
          created_at: now,
          updated_at: now
        })

      insert_one(ExternalWorkerBinding, row)
    end
  end

  defp validate_connected_binding(binding, runtime_spec) do
    device_runtime_id =
      Map.get(binding, "device_runtime_id") || Map.get(binding, :device_runtime_id)

    workload_id = Map.get(binding, "workload_id") || Map.get(binding, :workload_id)

    if is_binary(device_runtime_id) and device_runtime_id != "" and is_nil(workload_id) and
         is_map(runtime_spec) do
      {:ok,
       %{
         source_kind: "connected_runtime",
         device_runtime_id: device_runtime_id,
         workload_id: nil,
         runtime_spec: runtime_spec
       }}
    else
      {:error, :invalid_connected_runtime}
    end
  end

  defp validate_compute_binding(binding, runtime_spec) do
    workload_id = Map.get(binding, "workload_id") || Map.get(binding, :workload_id)

    device_runtime_id =
      Map.get(binding, "device_runtime_id") || Map.get(binding, :device_runtime_id)

    if is_binary(workload_id) and workload_id != "" and is_nil(device_runtime_id) and
         is_map(runtime_spec) do
      {:ok,
       %{
         source_kind: "compute_workload",
         device_runtime_id: nil,
         workload_id: workload_id,
         runtime_spec: runtime_spec
       }}
    else
      {:error, :invalid_compute_workload}
    end
  end

  defp contains_provider_native_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      MapSet.member?(@provider_native_keys, to_string(key)) or
        contains_provider_native_key?(value)
    end)
  end

  defp contains_provider_native_key?(list) when is_list(list),
    do: Enum.any?(list, &contains_provider_native_key?/1)

  defp contains_provider_native_key?(_), do: false

  defp validate_capability_requirements(requirements)
       when is_list(requirements) do
    if Enum.all?(requirements, &(&1 in @compute_capabilities)) and
         length(requirements) == length(Enum.uniq(requirements)),
       do: :ok,
       else: {:error, :invalid_capability}
  end

  defp validate_capability_requirements(_), do: {:error, :invalid_capability}

  defp materialize_workload_template(%{kind: "shell", generation: generation, id: id}, key)
       when is_binary(key) do
    with {:ok, materialized} <-
           SalixStore.RuntimeBundleCatalog.materialize(key, %{
             owner_id: id,
             generation: generation
           }) do
      {:ok,
       %{
         spec: materialized.spec,
         template_key: materialized.template_key,
         runtime_revision: materialized.runtime_revision
       }}
    end
  end

  defp materialize_workload_template(%{kind: "shell"}, _),
    do: {:error, :runtime_template_required}

  defp materialize_workload_template(%{id: id, generation: generation}, key)
       when is_binary(key) do
    with {:ok, materialized} <-
           SalixStore.RuntimeBundleCatalog.materialize(key, %{
             owner_id: id,
             generation: generation
           }) do
      {:ok,
       %{
         spec: materialized.spec,
         template_key: materialized.template_key,
         runtime_revision: materialized.runtime_revision
       }}
    end
  end

  defp materialize_workload_template(attrs, _key) do
    {:ok,
     %{
       spec: Map.get(attrs, :spec, %{}),
       template_key: nil,
       runtime_revision: nil
     }}
  end

  defp capabilities_supported?(%Pool{capabilities: capabilities}, requirements),
    do: MapSet.subset?(MapSet.new(requirements), MapSet.new(capabilities || []))

  defp provider_connection_epoch(%Allocation{provider_observation: observation}) do
    case Map.get(observation || %{}, "connection_epoch") do
      epoch when is_binary(epoch) and epoch != "" -> epoch
      _ -> "0"
    end
  end

  defp command_outcome(status) when status in ["pending", "admitted", "executing"], do: "pending"
  defp command_outcome("succeeded"), do: "succeeded"
  defp command_outcome("unknown_outcome"), do: "unknown"
  defp command_outcome(status) when status in ["failed", "cancelled"], do: "failed"

  defp validate_pool_assignment!(_environment, nil), do: :ok

  defp validate_pool_assignment!(environment, pool_id) do
    case Repo.get(Pool, pool_id) do
      %Pool{tenant_id: tenant_id, status: "active"} when tenant_id == environment.tenant_id ->
        :ok

      %Pool{tenant_id: tenant_id} when tenant_id != environment.tenant_id ->
        Repo.rollback(:scope_mismatch)

      %Pool{} ->
        Repo.rollback(:pool_unavailable)

      nil ->
        Repo.rollback(:pool_not_found)
    end
  end

  defp validate_grant_workload(_environment_id, nil), do: :ok

  defp validate_grant_workload(environment_id, workload_id) when is_binary(workload_id) do
    case Repo.get(Workload, workload_id) do
      %Workload{environment_id: ^environment_id} -> :ok
      %Workload{} -> {:error, :scope_mismatch}
      nil -> {:error, :workload_not_found}
    end
  end

  defp validate_grant_workload(_environment_id, _workload_id),
    do: {:error, :invalid_workload}

  defp update_binding_observation(_binding_id, _generation, observation)
       when map_size(observation) == 0,
       do: :ok

  defp update_binding_observation(binding_id, generation, observation) do
    now = DateTime.utc_now()

    from(b in ProviderBinding,
      where: b.id == ^binding_id and b.generation <= ^generation,
      update: [
        set: [
          observation:
            fragment("coalesce(?, '{}'::jsonb) || ?::jsonb", b.observation, ^observation),
          generation: ^generation,
          updated_at: ^now
        ],
        inc: [revision: 1]
      ]
    )
    |> Repo.update_all([])
  end

  defp insert_one(schema, row) do
    case Repo.insert_all(schema, [row], on_conflict: :nothing, conflict_target: [:id]) do
      {1, _} -> {:ok, Repo.get!(schema, row.id)}
      {0, _} -> {:error, :already_exists}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp required_strings(attrs, keys) do
    if Enum.all?(keys, fn key -> is_binary(Map.get(attrs, key)) and Map.get(attrs, key) != "" end),
       do: :ok,
       else: {:error, :invalid}
  end

  defp canonical_nonzero_uint64?(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..18_446_744_073_709_551_615 ->
        Integer.to_string(parsed) == value

      _ ->
        false
    end
  end

  defp canonical_nonzero_uint64?(_), do: false

  defp validate_optional_map(nil, _error), do: :ok
  defp validate_optional_map(value, _error) when is_map(value), do: :ok
  defp validate_optional_map(_, error), do: {:error, error}

  defp validate_provider_policy(policy) when is_map(policy) do
    providers = provider_policy_providers(policy)

    if is_list(providers) and providers == Enum.uniq(providers) and
         Enum.all?(providers, &(&1 in @providers)),
       do: :ok,
       else: {:error, :invalid_provider_policy}
  end

  defp validate_provider_policy(_), do: {:error, :invalid_provider_policy}

  defp provider_policy_providers(policy) when is_map(policy),
    do: Map.get(policy, "providers", Map.get(policy, :providers, []))

  defp provider_policy_providers(_), do: []

  defp provider_allowed?(%Pool{} = pool, provider),
    do: provider in provider_policy_providers(pool.provider_policy)

  defp validate_provider_ref_scope("agent_vmm", provider_ref, tenant_id)
       when is_binary(provider_ref) and is_binary(tenant_id) do
    case Repo.get(AgentVMM.Registration, provider_ref) do
      %AgentVMM.Registration{tenant_id: ^tenant_id} -> :ok
      %AgentVMM.Registration{} -> {:error, :provider_scope_mismatch}
      nil -> {:error, :provider_not_found}
    end
  end

  defp validate_provider_ref_scope("agent_vmm", _provider_ref, _tenant_id),
    do: {:error, :provider_not_found}

  defp validate_provider_ref_scope(_provider, _provider_ref, _tenant_id), do: :ok

  defp validate_binding_environment(%Pool{} = pool, "agent_vmm", environment_id)
       when is_binary(environment_id) and environment_id != "" do
    validate_binding_environment_scope(pool, environment_id)
  end

  defp validate_binding_environment(%Pool{}, "agent_vmm", _environment_id),
    do: {:error, :environment_scope_required}

  defp validate_binding_environment(%Pool{} = pool, _provider, environment_id)
       when is_binary(environment_id) and environment_id != "" do
    validate_binding_environment_scope(pool, environment_id)
  end

  defp validate_binding_environment(%Pool{}, _provider, nil), do: :ok

  defp validate_binding_environment(%Pool{}, _provider, _environment_id),
    do: {:error, :invalid_environment_scope}

  defp validate_agent_vmm_scope_rollout("agent_vmm") do
    if environment_scope_enforced?(),
      do: :ok,
      else: {:error, :environment_scope_rollout_pending}
  end

  defp validate_agent_vmm_scope_rollout(_provider), do: :ok

  defp validate_binding_environment_scope(pool, environment_id) do
    case Repo.get(Environment, environment_id) do
      %Environment{pool_id: pool_id, tenant_id: tenant_id}
      when pool_id == pool.id and tenant_id == pool.tenant_id ->
        :ok

      %Environment{} ->
        {:error, :environment_scope_mismatch}

      nil ->
        {:error, :environment_not_found}
    end
  end

  defp binding_eligible_for_environment?(binding, environment) do
    binding.pool_id == environment.pool_id and
      (binding.environment_id == environment.id or
         (is_nil(binding.environment_id) and
            (binding.provider != "agent_vmm" or not environment_scope_enforced?())))
  end

  defp exact_placement_binding(query, nil), do: query
  defp exact_placement_binding(query, id), do: from(b in query, where: b.id == ^id)

  defp eligible_binding_query(environment, allowed_providers) do
    query =
      from(b in ProviderBinding,
        where:
          b.pool_id == ^environment.pool_id and b.status == "available" and
            b.provider in ^allowed_providers,
        order_by: [
          asc: fragment("array_position(?::text[], ?)", ^allowed_providers, b.provider),
          asc: b.id
        ],
        limit: 1
      )

    if environment_scope_enforced?() do
      from(b in query,
        where:
          b.environment_id == ^environment.id or
            (is_nil(b.environment_id) and b.provider != "agent_vmm")
      )
    else
      from(b in query, where: b.environment_id == ^environment.id or is_nil(b.environment_id))
    end
  end

  defp environment_scope_enforced? do
    Application.get_env(
      :salix_store,
      :agent_vmm_environment_scoped_bindings_enabled,
      false
    )
  end

  defp binding_environment_query(query, nil),
    do: from(b in query, where: is_nil(b.environment_id))

  defp binding_environment_query(query, environment_id),
    do: from(b in query, where: b.environment_id == ^environment_id)

  defp validate_retention(%{"mode" => mode}) when mode in ["retain", "release_on_stop"], do: :ok
  defp validate_retention(%{mode: mode}) when mode in ["retain", "release_on_stop"], do: :ok
  defp validate_retention(_), do: {:error, :invalid_retention}

  defp maybe_put(changes, _key, nil), do: changes
  defp maybe_put(changes, key, value), do: Keyword.put(changes, key, value)

  defp new_compute_id(prefix), do: prefix <> "_" <> Ecto.UUID.generate()
end
