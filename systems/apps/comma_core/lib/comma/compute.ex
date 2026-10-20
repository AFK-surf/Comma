defmodule Comma.Compute do
  @moduledoc "Comma authorization and bounded projection adapter for Salix Compute."

  import Ecto.Query
  alias Comma.Workspaces
  alias SalixStore.{AgentVMMInstallations, Compute}

  @permissions ~w(runtime workspace service_route hosting)

  def get(user, session, workspace_id, options \\ %{}) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, projection} <-
           Compute.project_page(workspace["salix_tenant_id"], "project", workspace_id, options) do
      {:ok,
       public_projection(projection)
       |> Map.put("workspace_name", workspace["name"])
       |> Map.put("can_manage", true)}
    end
  end

  def local_mappings(user, session, workspace_id, targets)
      when is_list(targets) and length(targets) <= 32 do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         true <- Enum.all?(targets, &valid_local_target?/1) || {:error, :invalid} do
      ids = Enum.map(targets, & &1["allocation_id"])

      rows =
        SalixStore.Repo.all(
          from(a in Compute.Allocation,
            join: e in Compute.Environment,
            on: e.id == a.environment_id,
            join: b in Compute.ProviderBinding,
            on: b.id == a.provider_binding_id,
            where:
              a.id in ^ids and e.tenant_id == ^workspace["salix_tenant_id"] and
                e.owner_type == "project" and e.owner_id == ^workspace_id and
                b.provider == "agent_vmm",
            select: %{
              allocation_id: a.id,
              generation: a.generation,
              registration_id: b.provider_ref
            }
          )
        )

      mappings =
        Enum.flat_map(rows, fn row ->
          if Enum.any?(
               targets,
               &(&1["allocation_id"] == row.allocation_id and
                   &1["registration_id"] == row.registration_id and
                   &1["generation"] == Integer.to_string(row.generation))
             ),
             do: [
               %{
                 "allocation_id" => row.allocation_id,
                 "registration_id" => row.registration_id,
                 "generation" => Integer.to_string(row.generation),
                 "can_read" => true,
                 "can_operate" => false
               }
             ],
             else: []
        end)

      {:ok, mappings}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  def local_mappings(_, _, _, _), do: {:error, :invalid}

  def local_workloads(user, session, workspace_id, target, after_id)
      when is_binary(after_id) and byte_size(after_id) <= 200 do
    with {:ok, [_mapping]} <- local_mappings(user, session, workspace_id, [target]) do
      rows =
        SalixStore.Repo.all(
          from(w in Compute.Workload,
            join: a in Compute.Allocation,
            on: a.id == w.allocation_id,
            join: b in Compute.ProviderBinding,
            on: b.id == a.provider_binding_id,
            join: e in Compute.Environment,
            on: e.id == a.environment_id,
            where:
              a.id == ^target["allocation_id"] and
                a.generation == ^String.to_integer(target["generation"]) and
                b.provider == "agent_vmm" and b.provider_ref == ^target["registration_id"] and
                e.owner_type == "project" and e.owner_id == ^workspace_id and w.id > ^after_id,
            order_by: w.id,
            limit: 33,
            select: {w, a, b}
          )
        )

      items = Enum.take(rows, 32)
      page = Enum.map(items, &elem(&1, 0))
      ids = Enum.map(page, & &1.id)

      projection = %{
        allocations: Enum.map(items, &elem(&1, 1)),
        bindings: Enum.map(items, &elem(&1, 2)),
        runtimes:
          SalixStore.Repo.all(
            from(r in Compute.RuntimeInstance,
              join: w in Compute.Workload,
              on: w.id == r.workload_id and w.generation == r.generation,
              where: r.workload_id in ^ids
            )
          ),
        claims:
          SalixStore.Repo.all(
            from(c in Compute.ReconcilerClaim,
              join: w in Compute.Workload,
              on: w.id == c.workload_id and w.generation == c.generation,
              where: c.workload_id in ^ids
            )
          )
      }

      {:ok,
       %{
         "workloads" => Enum.map(page, &public_workload_phase(&1, projection)),
         "next_cursor" => if(length(rows) > 32, do: List.last(page).id, else: nil)
       }}
    else
      {:ok, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def local_workloads(_, _, _, _, _), do: {:error, :invalid}

  defp valid_local_target?(target) when is_map(target) do
    Enum.all?(
      ["allocation_id", "registration_id"],
      &(is_binary(target[&1]) and byte_size(target[&1]) in 1..200)
    ) and
      is_binary(target["generation"]) and byte_size(target["generation"]) in 1..20 and
      case Integer.parse(target["generation"]) do
        {value, ""} when value > 0 and value <= 9_223_372_036_854_775_807 ->
          Integer.to_string(value) == target["generation"]

        _ ->
          false
      end
  end

  defp valid_local_target?(_), do: false

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
         {:ok, descriptor} <-
           AgentVMMInstallations.request(
             %{
               tenant_id: workspace["salix_tenant_id"],
               group_id: workspace["default_group_id"],
               surface: "comma",
               scope_key: workspace_id,
               client_request_id: request_id,
               provider: "agent-vmm",
               delivery_target_type: "comma_main_device",
               delivery_target_id: target_id,
               authorizing_subject_id: user["id"],
               authorizing_audience: recovery_audience()
             },
             authorize: current_install_authority(user, session, workspace_id),
             create_environment: fn ->
               Compute.ensure_environment(%{
                 id: new_id("env"),
                 tenant_id: workspace["salix_tenant_id"],
                 owner_type: "project",
                 owner_id: workspace_id,
                 pool_id: pool.id,
                 retention: %{"mode" => "retain"}
               })
             end
           ) do
      {:ok, descriptor}
    end
  end

  def agent_vmm_recovery_challenge(user, session, workspace_id, operation_id) do
    with {:ok, authority, options} <- recovery_authority(user, session, workspace_id) do
      AgentVMMInstallations.recovery_challenge(operation_id, authority, options)
    end
  end

  def agent_vmm_recovery_candidates(user, session, workspace_id, registration_ids) do
    with {:ok, authority, options} <- recovery_authority(user, session, workspace_id) do
      AgentVMMInstallations.recovery_candidates(registration_ids, authority, options)
    end
  end

  def recover_agent_vmm_install(user, session, workspace_id, operation_id, proof, consume) do
    with {:ok, authority, options} <- recovery_authority(user, session, workspace_id) do
      AgentVMMInstallations.recover(operation_id, authority, proof, consume, options)
    end
  end

  def get_unexchanged_agent_vmm_request(user, session, workspace_id, request_id) do
    with {:ok, authority, options} <- recovery_authority(user, session, workspace_id) do
      AgentVMMInstallations.get_by_request("comma", workspace_id, request_id, authority, options)
    end
  end

  def abandon_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, authority, options} <- recovery_authority(user, session, workspace_id) do
      AgentVMMInstallations.abandon_unexchanged(operation_id, authority, options)
    end
  end

  defp recovery_authority(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, session_id} <- session_delivery_target(session),
         audience when is_binary(audience) <- recovery_audience() do
      authority = %{
        subject: user["id"],
        audience: audience,
        session_id: session_id,
        tenant_id: workspace["salix_tenant_id"],
        group_id: workspace["default_group_id"],
        scope_key: workspace_id
      }

      # Workspace and install owners use separate repositories. Recheck the current
      # active owner while the install row is locked; the Session scope is still required.
      options = [
        authorize: fn ->
          case {Comma.Accounts.Sessions.authorize_current(user["id"], session_id),
                Workspaces.authorize(user, session, workspace_id)} do
            {:ok, {:ok, current}} ->
              if current["salix_tenant_id"] == authority.tenant_id and
                   current["default_group_id"] == authority.group_id,
                 do: :ok,
                 else: {:error, :not_found}

            _ ->
              {:error, :not_found}
          end
        end,
        original_subject: &original_install_subject/2
      ]

      {:ok, authority, options}
    else
      {:error, _} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp recovery_audience do
    case SystemsRuntime.get_env(:salix_web, :public_base_url) do
      value when is_binary(value) ->
        uri = URI.parse(value)

        if uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo),
          do:
            URI.to_string(%{
              uri
              | scheme: String.downcase(uri.scheme),
                host: String.downcase(uri.host),
                path: nil,
                query: nil,
                fragment: nil
            }),
          else: nil

      _ ->
        nil
    end
  end

  defp original_install_subject("comma_main_device", session_id) do
    live =
      case Ecto.UUID.cast(session_id) do
        {:ok, id} -> Comma.Repo.get(Comma.Accounts.AuthSession, id)
        :error -> nil
      end

    case live || Comma.Repo.get(Comma.Data.Session, session_id) do
      %{user_id: subject} when is_binary(subject) -> {:ok, subject}
      _ -> {:error, :original_subject_unknown}
    end
  end

  defp original_install_subject(_, _), do: {:error, :original_subject_unknown}

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

  def observe_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, operation} <- get_agent_vmm_install(user, session, workspace_id, operation_id) do
      activity =
        case Compute.work_activity(operation.tenant_id, operation.registration_id) do
          {:ok, %{"activity" => activity}} -> activity
          {:error, _} -> "unknown"
        end

      shell_phase =
        case operation[:initial_workload_id] &&
               get_workload(user, session, workspace_id, operation.initial_workload_id) do
          {:ok, %{"workload" => %{"phase" => "ready"}}} -> "ready"
          {:ok, %{"workload" => %{"phase" => "action_required"}}} -> "failed"
          {:ok, %{"workload" => %{"phase" => "deleted"}}} -> "deleted"
          {:ok, %{"workload" => %{"phase" => "deleting"}}} -> "deleting"
          {:ok, _} -> "preparing"
          _ -> "not_initialized"
        end

      {:ok, operation |> Map.put(:work_activity, activity) |> Map.put(:shell_phase, shell_phase)}
    end
  end

  def retry_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, operation} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, descriptor} <-
           AgentVMMInstallations.retry(operation_id,
             expected_authorization: operation,
             authorize: current_install_authority(user, session, workspace_id)
           ) do
      {:ok, descriptor}
    end
  end

  def revoke_agent_vmm_install(user, session, workspace_id, operation_id) do
    with {:ok, expected} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, operation} <-
           AgentVMMInstallations.revoke(operation_id,
             expected_authorization: expected,
             authorize: current_install_authority(user, session, workspace_id)
           ) do
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
    with {:ok, expected} <-
           get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, operation} <-
           AgentVMMInstallations.configure_registration(operation_id, enabled,
             expected_authorization: expected,
             authorize: current_install_authority(user, session, workspace_id)
           ) do
      {:ok, operation}
    end
  end

  def initialize_agent_vmm_workload(user, session, workspace_id, operation_id) do
    with {:ok, operation} <- get_agent_vmm_install(user, session, workspace_id, operation_id),
         {:ok, initialized} <-
           AgentVMMInstallations.initialize_workload(operation_id,
             expected_authorization: operation,
             authorize: current_install_authority(user, session, workspace_id)
           ) do
      {:ok, initialized}
    end
  end

  defp current_install_authority(user, session, workspace_id) do
    fn ->
      with {:ok, session_id} <- session_delivery_target(session),
           :ok <- Comma.Accounts.Sessions.authorize_current(user["id"], session_id),
           {:ok, _} <- Workspaces.authorize(user, session, workspace_id) do
        :ok
      else
        _ -> {:error, :not_found}
      end
    end
  end

  def create_workload(user, session, workspace_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, environment_id} <- id(attrs["environment_id"]),
         :ok <- environment_in_scope(workspace, workspace_id, environment_id),
         {:ok, kind} <- workload_kind(attrs["kind"]),
         {:ok, template_key} <- workload_template_key(kind, attrs),
         {:ok, request_id} <- creation_request_id(attrs["request_id"]),
         {:ok, name} <- SalixStore.ComputeWorkloadManagement.name(attrs["name"]),
         placement_input = %{
           tenant_id: workspace["salix_tenant_id"],
           allocation_id: new_id("allocation"),
           workload_id: new_id("workload"),
           environment_id: environment_id,
           kind: kind,
           name: name,
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

  def get_workload(user, session, workspace_id, workload_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         %Compute.Workload{} = workload <-
           SalixStore.Repo.one(
             SalixStore.ComputeWorkloadManagement.owned_query(
               workspace["salix_tenant_id"],
               workspace_id,
               workload_id
             )
           ) do
      allocation = SalixStore.Repo.get!(Compute.Allocation, workload.allocation_id)
      binding = SalixStore.Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

      page = %{
        allocations: [allocation],
        bindings: [binding],
        runtimes:
          SalixStore.Repo.all(
            from(r in Compute.RuntimeInstance,
              where: r.workload_id == ^workload.id and r.generation == ^workload.generation,
              order_by: [desc: r.updated_at],
              limit: 1
            )
          ),
        claims:
          SalixStore.Repo.all(
            from(c in Compute.ReconcilerClaim,
              where: c.workload_id == ^workload.id and c.generation == ^workload.generation,
              limit: 1
            )
          )
      }

      uses = workload_uses(workload)
      public = public_workload_phase(workload, page)

      public =
        if uses.items == [],
          do: public,
          else: put_in(public, ["actions", "delete"], false)

      {:ok,
       %{
         "workload" =>
           public
           |> Map.put("uses", uses.items)
           |> Map.put("uses_truncated", uses.truncated)
           |> Map.put("runtime_policy", runtime_policy(workload))
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def rename_workload(user, session, workspace_id, workload_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, expected} <- revision(attrs["revision"]),
         {:ok, _} <-
           SalixStore.ComputeWorkloadManagement.rename(
             workspace["salix_tenant_id"],
             workspace_id,
             workload_id,
             expected,
             attrs["name"],
             fn -> reauthorize(user, session, workspace_id) end
           ) do
      get_workload(user, session, workspace_id, workload_id)
    end
  end

  def delete_workload(user, session, workspace_id, workload_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, expected} <- revision(attrs["revision"]),
         {:ok, generation} <- revision(attrs["generation"]),
         {:ok, request} <- id(attrs["request_id"]),
         {:ok, _} <-
           SalixStore.ComputeWorkloadDeletion.start(
             workspace["salix_tenant_id"],
             workspace_id,
             workload_id,
             expected,
             generation,
             request,
             fn -> reauthorize(user, session, workspace_id) end
           ) do
      get_workload(user, session, workspace_id, workload_id)
    end
  end

  def retry_workload(user, session, workspace_id, workload_id, attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, expected} <- revision(attrs["revision"]),
         {:ok, generation} <- revision(attrs["generation"]),
         {:ok, _} <-
           SalixStore.ComputeWorkloadManagement.retry(
             workspace["salix_tenant_id"],
             workspace_id,
             workload_id,
             expected,
             generation,
             fn -> reauthorize(user, session, workspace_id) end
           ) do
      get_workload(user, session, workspace_id, workload_id)
    end
  end

  defp reauthorize(user, session, workspace_id),
    do: current_install_authority(user, session, workspace_id).()

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
             expires_at: DateTime.add(SystemsClock.utc_now(), ttl, :second)
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

      canonical = if input.name, do: Map.put(canonical, "name", input.name), else: canonical

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
    template_available =
      match?({:ok, _}, SalixStore.RuntimeBundleCatalog.resolve("shell.default"))

    %{
      "environments" => Enum.map(value.environments, &public_environment(&1, template_available)),
      "allocations" => Enum.map(value.allocations, &public_allocation/1),
      "workloads" => Enum.map(value.workloads, &public_workload_phase(&1, value)),
      "runtimes" => Enum.map(value.runtimes, &public_runtime/1),
      "grants" => Enum.map(value.grants, &public_grant/1),
      "next_workload_cursor" => value.next_workload_cursor
    }
  end

  defp public_environment(row, template_available \\ true),
    do:
      take(
        row,
        ~w(id pool_id desired_state observed_state generation revision retention updated_at)a
      )
      |> Map.put("can_create", Map.get(row, :can_create, false) and template_available)
      |> Map.put(
        "create_unavailable_reason",
        cond do
          not template_available -> "template_unavailable"
          Map.get(row, :can_create, false) -> nil
          row.desired_state != "ready" -> "node_not_enabled"
          true -> "node_unavailable"
        end
      )

  defp public_allocation(row),
    do: take(row, ~w(id environment_id status operation_outcome generation revision updated_at)a)

  defp public_workload_phase(workload, page) do
    allocation = Enum.find(page.allocations, &(&1.id == workload.allocation_id))
    binding = allocation && Enum.find(page.bindings, &(&1.id == allocation.provider_binding_id))

    runtime =
      Enum.find(
        page.runtimes,
        &(&1.workload_id == workload.id and &1.generation == workload.generation)
      )

    claim =
      Enum.find(
        page.claims,
        &(&1.workload_id == workload.id and &1.generation == workload.generation)
      )

    epoch = binding && (binding.observation || %{})["connection_epoch"]

    phase =
      cond do
        workload.desired_state == "stopped" ->
          "stopped"

        workload.desired_state == "draining" ->
          "draining"

        workload.observed_state == "failed" or
            (claim && (claim.last_error || %{})["kind"] == "action_required") ->
          "action_required"

        not is_nil(binding) and binding.provider == "agent_vmm" and not is_nil(epoch) and
            not match?({:ok, _}, SalixStore.ComputeContract.connection_epoch(epoch)) ->
          "action_required"

        not is_nil(binding) and binding.provider == "agent_vmm" and
            (is_nil(epoch) or binding.status != "available") ->
          "waiting_connection"

        workload.kind == "shell" and workload.observed_state == "ready" and not is_nil(epoch) and
          not is_nil(allocation) and allocation.status == "ready" and
          get_in(allocation.provider_observation || %{}, ["container_status"]) == "running" and
            get_in(allocation.provider_observation || %{}, ["runtime_verified_host_epoch"]) ==
              epoch ->
          "ready"

        workload.kind == "shell" and workload.observed_state == "ready" ->
          "starting"

        (workload.observed_state == "ready" and runtime) && runtime.readiness == "ready" ->
          "ready"

        not is_nil(binding) and binding.provider == "agent_vmm" and is_nil(epoch) ->
          "waiting_connection"

        allocation && allocation.status in ["pending", "allocating"] ->
          "allocating"

        runtime && runtime.readiness in ["catching_up", "pending"] ->
          "starting"

        true ->
          "unknown"
      end

    phase =
      cond do
        workload.deletion && workload.deletion["phase"] == "complete" ->
          "deleted"

        workload.deletion && workload.deletion["phase"] == "cloud_retired" ->
          "cloud_retired"

        allocation && (allocation.provider_observation || %{})["cloud_retired"] ->
          "cloud_retired"

        workload.deletion && workload.deletion["error"] == "original_device_offline" ->
          "waiting_connection"

        workload.deletion ->
          "deleting"

        true ->
          phase
      end

    public_workload(workload)
    |> Map.put(
      "location",
      case binding do
        %{provider: "agent_vmm"} ->
          %{
            "provider" => binding.provider,
            "registration_id" => binding.provider_ref,
            "allocation_id" => allocation.id
          }

        nil ->
          %{"provider" => "unknown"}

        _ ->
          %{"provider" => binding.provider, "allocation_id" => allocation.id}
      end
    )
    |> Map.put("actions", %{
      "rename" => true,
      "retry" =>
        workload.kind == "shell" and is_nil(workload.deletion) and
          workload.desired_state == "ready" and phase == "action_required",
      "delete" =>
        (workload.kind in ["shell", "external_worker"] and is_nil(workload.deletion) and binding) &&
          binding.provider == "agent_vmm"
    })
    |> Map.put(
      "owner",
      # external_worker: its retired External Worker no longer manages it.
      if(workload.kind in ["shell", "external_worker"],
        do: nil,
        else: %{
          "kind" => workload.kind,
          "workload_id" => workload.id,
          "environment_id" => workload.environment_id
        }
      )
    )
    |> Map.put("phase", phase)
    |> Map.put("phase_observed_at", if(claim, do: claim.updated_at, else: workload.updated_at))
  end

  defp runtime_policy(workload) do
    spec = workload.spec || %{}

    %{
      "image" => get_in(spec, ["runtime_artifact", "reference"]),
      "entrypoint" => spec["entrypoint"],
      "command" => spec["command"],
      "egress_mode" => spec["egress_mode"],
      "resources" => Map.take(spec["resources"] || %{}, ["pid_max", "writable_quota_bytes"])
    }
  end

  defp workload_uses(workload) do
    # A retired External Worker's leftover binding is not a use; deleting the
    # external_worker Workload removes it.
    agents =
      if workload.kind == "external_worker",
        do: [],
        else:
          SalixStore.Repo.all(
            from(b in Compute.ExternalWorkerBinding,
              where: b.workload_id == ^workload.id,
              order_by: b.id,
              limit: 33,
              select: %{kind: "agent", id: b.agent_id, relation_id: b.id}
            )
          )

    exports =
      SalixStore.Repo.all(
        from(e in SalixStore.ServiceRoutes.Export,
          where: e.workload_id == ^workload.id and is_nil(e.revoked_at),
          order_by: e.id,
          limit: 33,
          select: %{kind: "service_export", id: e.id, label: e.logical_endpoint}
        )
      )

    imports =
      SalixStore.Repo.all(
        from(i in SalixStore.ServiceRoutes.Import,
          where: i.destination_workload_id == ^workload.id and is_nil(i.revoked_at),
          order_by: i.id,
          limit: 33,
          select: %{kind: "service_import", id: i.id, label: i.virtual_service_name}
        )
      )

    meeting =
      if workload.owner_ref && workload.owner_ref["kind"] == "meeting",
        do: [workload.owner_ref],
        else: []

    pages = [agents, exports, imports]

    %{
      items: meeting ++ Enum.flat_map(pages, &Enum.take(&1, 32)),
      truncated: Enum.any?(pages, &(length(&1) > 32))
    }
  end

  defp public_workload(row),
    do:
      take(
        row,
        ~w(id environment_id kind desired_state observed_state generation revision updated_at name deletion)a
      )
      |> Map.update!(:name, fn name -> name || default_workload_name(row.kind) end)

  defp default_workload_name("shell"), do: "Shell"
  defp default_workload_name("external_worker"), do: "Worker"
  defp default_workload_name("meeting_runtime"), do: "Meeting"
  defp default_workload_name("service"), do: "Service"

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
       when value in ["meeting_runtime", "service", "shell"],
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
    do:
      prefix <> "_" <> (SystemsRuntime.Proc.random_bytes(16) |> Base.url_encode64(padding: false))
end
