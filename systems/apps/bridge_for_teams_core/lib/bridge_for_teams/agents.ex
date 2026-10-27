defmodule BridgeForTeams.Agents do
  require SystemsRuntime.Proc

  @moduledoc """
  Product associations and authorization for Salix-owned Agents. Configuration
  and lifecycle reads come from Salix. New creation retains an immutable outbox
  request until tenant/group provisioning permits Salix to accept the Agent.
  Consumers read the native Salix record on the product reference. Legacy
  physical columns are read only by the explicit transfer operation.
  `deliver/3` is a *live* erpc to the agent runtime (not reconciled),
  authorized in BridgeForTeams before the call.
  """
  import Ecto.Query

  alias BridgeForTeams.{Environments, Models, Observability, Repo}
  alias BridgeForTeams.Outbox
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Salix.Identity
  alias BridgeForTeams.Schema.{Agent, Organization, Project, ReconcileOutbox}
  alias BillingCore.FeeControl.Request
  alias SalixStore.{Ids, RuntimeIds}

  @doc """
  Create a Router's product association and enqueue its initial Salix-owned
  configuration. Workers are retired: a request for one answers
  `{:error, :workers_retired}` and enqueues nothing. Tasks run on the swarm's
  Task agent (`SalixAgent.TaskAgent`) at the swarm's default place and model.
  """
  @spec create_agent(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_agent(project_id, attrs, opts \\ []) do
    attrs = normalize(attrs)
    attempted_attrs = attrs
    project = Repo.get(Project, project_id)

    result =
      with :ok <- reject_worker(attrs),
           :ok <- reject_inline_model_config(attrs) do
        case project do
          %Project{} ->
            Identity.retry_generated(
              fn -> create_agent_once(project_id, attrs, project, opts) end,
              [:salix_agent_id]
            )

          nil ->
            {:error, :project_not_found}
        end
      end

    maybe_record_agent_write_failure(result, "agent.created", project_id, attempted_attrs, opts)
  end

  defp create_agent_once(project_id, attrs, project, opts) do
    attrs =
      attrs
      |> Map.put("project_id", project_id)
      |> Map.put("salix_agent_id", project_agent_id(project))
      |> put_default_model(project)

    with {:ok, attrs} <- reject_runtime_config(attrs, project_id) do
      Repo.transaction(fn ->
        changeset = Agent.changeset(%Agent{}, attrs)

        with {:ok, agent} <- insert_association(changeset),
             :ok <- enqueue_config(agent),
             {:ok, _audit} <-
               maybe_record_agent_audit("agent.created", agent, opts,
                 redacted_diff: agent_config_diff(nil, agent)
               ) do
          agent
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp reject_worker(%{"role" => "router"}), do: :ok
  defp reject_worker(_attrs), do: {:error, :workers_retired}

  # A new Router gets a copy of the org default Router model
  # (`BridgeForTeams.Models`); without one it follows the platform model.
  defp put_default_model(attrs, %Project{org_id: org_id}) do
    with false <- Map.has_key?(attrs, "model"),
         %Organization{} = org <- Repo.get(Organization, org_id) do
      maybe_put(attrs, "model", Models.default_for(org, attrs["role"]))
    else
      _keep -> attrs
    end
  end

  @doc false
  def insert_association(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:configuration_authority, "salix")
    |> Repo.insert()
    |> case do
      {:ok, reference} -> {:ok, %{reference | provisioning: "provisioning"}}
      error -> error
    end
  end

  defp project_agent_id(%Project{salix_group_id: group_id}), do: Ids.new_agent_id(group_id)

  @doc "Transfer one drained Agent to Salix; safe to retry after acknowledgement loss."
  # Model anchor: tla/salix/AgentConfigurationAuthority.tla (Freeze/Claim/Acknowledge).
  def transfer_configuration(id) do
    with :ok <- SalixStore.AgentConfigurationRollout.ensure_open(),
         do: do_transfer_configuration(id)
  end

  defp do_transfer_configuration(id) do
    if Ids.valid_agent_id?(id),
      do: transfer_canonical_configuration(id),
      else: transfer_product_configuration(id)
  end

  defp transfer_canonical_configuration(id) do
    case Repo.get_by(Agent, salix_agent_id: id) do
      %Agent{id: product_id} ->
        transfer_product_configuration(product_id)

      nil ->
        with %Project{} = project <-
               Repo.get_by(Project, salix_group_id: Ids.group_id_from_agent!(id)),
             {:ok, project, org} <- project_org(project),
             :ok <- ensure_transfer_product_scope(project, org),
             {:ok, record} <-
               Client.impl().claim_agent_configuration(id, org.salix_tenant_id, nil) do
          {:ok,
           with_record(
             %Agent{
               id: id,
               project_id: project.id,
               salix_agent_id: id,
               configuration_authority: "salix"
             },
             record
           )}
        else
          nil -> {:error, :project_not_found}
          error -> error
        end
    end
  end

  defp transfer_product_configuration(id) do
    frozen =
      Repo.transaction(fn ->
        agent = Repo.one!(from(a in Agent, where: a.id == ^id, lock: "FOR UPDATE"))
        # Operator-only legacy read; product Agent DTO fields are virtual.
        archived_at =
          Repo.one(
            from(a in Agent,
              where: a.id == ^id,
              select: type(fragment("archived_at"), :utc_datetime_usec)
            )
          )

        if agent.configuration_authority == "legacy" do
          outstanding =
            Repo.exists?(
              from(r in ReconcileOutbox,
                where: r.aggregate == "agent" and r.aggregate_id == ^id and r.status != "done"
              )
            )

          if outstanding, do: Repo.rollback(:drain_agent_configuration_outbox)
          agent = Repo.update!(Ecto.Changeset.change(agent, configuration_authority: "moving"))
          {agent, archived_at}
        else
          {agent, archived_at}
        end
      end)

    with {:ok, {agent, archived_at}} <- frozen,
         {:ok, project, org} <- project_org(Repo.get!(Project, agent.project_id)),
         :ok <- ensure_transfer_product_scope(project, org),
         {:ok, claimed} <-
           Client.impl().claim_agent_configuration(
             agent.salix_agent_id,
             org.salix_tenant_id,
             if(archived_at, do: DateTime.to_unix(archived_at), else: nil)
           ) do
      Repo.transaction(fn ->
        locked = Repo.one!(from(a in Agent, where: a.id == ^id, lock: "FOR UPDATE"))

        Repo.update!(
          Ecto.Changeset.change(locked, configuration_authority: "salix", role: claimed["role"])
        )
      end)
    end
  end

  defp ensure_transfer_product_scope(project, org) do
    with {:ok, group} <- Client.impl().get_group(project.salix_group_id) do
      case group["billing_owner"] do
        %{"surface" => "bridge", "project_id" => id} when id == project.id ->
          :ok

        nil ->
          with {:ok, _} <-
                 Client.impl().update_group(project.salix_group_id, org.salix_tenant_id, %{
                   "billing_owner" => group_billing_owner(org, project, group["router_agent_id"])
                 }) do
            :ok
          end

        _ ->
          {:error, :project_group_owner_mismatch}
      end
    end
  end

  defp write_canonical(%Agent{id: id} = agent, operation) do
    current = if Ecto.UUID.cast(id) == :error, do: agent, else: Repo.get(Agent, id)

    case current do
      %Agent{configuration_authority: "salix"} ->
        operation.(current)

      %Agent{configuration_authority: "moving"} ->
        {:error, :agent_configuration_transfer_in_progress}

      %Agent{} ->
        {:error, :agent_configuration_transfer_required}

      nil ->
        {:error, :not_found}
    end
  end

  defp resolve_association(agent), do: canonical_agent(agent)

  defp canonical_agent(%Agent{} = association) do
    with {:ok, project, org} <- project_org(Repo.get!(Project, association.project_id)),
         {:ok, record} <- Client.impl().get_agent(association.salix_agent_id, org.salix_tenant_id),
         true <- record["group_id"] == project.salix_group_id do
      association =
        if Ecto.UUID.cast(association.id) == :error,
          do: Map.fetch!(ensure_associations(project, [record]), record["agent_id"]),
          else: association

      {:ok, with_record(association, record)}
    else
      {:error, :not_found} -> pending_creation(association)
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp pending_creation(%Agent{} = association) do
    case Ecto.UUID.cast(association.id) do
      {:ok, _} -> pending_product_creation(association)
      :error -> {:error, :not_found}
    end
  end

  defp pending_product_creation(%Agent{id: id} = association) do
    row =
      Repo.one(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^id and
              r.op == "create_owned_agent" and r.status in ["pending", "failed"],
          order_by: [desc: r.created_at],
          limit: 1
        )
      )

    case row do
      %{payload: %{"attrs" => attrs}, status: status} ->
        {:ok,
         with_record(association, Map.put(attrs, "management_purpose", attrs["purpose"]))
         |> Map.put(
           :provisioning,
           if(status == "pending", do: "provisioning", else: "provisioning_failed")
         )}

      nil ->
        {:error, :not_found}
    end
  end

  defp with_record(association, record), do: %{association | salix: record, provisioning: nil}

  defp reject_inline_model_config(attrs) do
    if attrs["llm_config"] in [nil, %{}], do: :ok, else: {:error, :use_model_choice}
  end

  defp configure_canonical(agent, attrs, opts) do
    with :ok <- reject_inline_model_config(attrs),
         {:ok, current} <- canonical_agent(agent),
         true <- is_nil(current.provisioning) || {:error, :agent_provisioning},
         true <- not Map.has_key?(current.salix, "archived_at") || {:error, :agent_archived},
         true <- attrs["role"] in [nil, current.role] || {:error, :agent_role_immutable},
         {:ok, _project, org} <- project_org(Repo.get!(Project, agent.project_id)) do
      audit_canonical_call(current, "agent.config_updated", opts, fn ->
        with {:ok, record} <-
               Client.impl().configure_agent(
                 agent.salix_agent_id,
                 org.salix_tenant_id,
                 Map.delete(attrs, "role")
               ),
             do: {:ok, with_record(agent, record)}
      end)
    end
  end

  @doc "Fetch an agent by id."
  @spec get_agent(Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def get_agent(id) do
    cond do
      Ids.valid_agent_id?(id) ->
        case Repo.get_by(Project, salix_group_id: Ids.group_id_from_agent!(id)) do
          nil -> {:error, :not_found}
          project -> get_project_agent(project.id, id)
        end

      Ecto.UUID.cast(id) != :error ->
        case Repo.get(Agent, id) do
          nil -> {:error, :not_found}
          agent -> resolve_association(agent)
        end

      true ->
        {:error, :not_found}
    end
  end

  @doc "Resolve an association against its configuration authority before making product decisions."
  def resolve_agent(%Agent{} = agent), do: resolve_association(agent)
  def resolve_agent(_), do: {:error, :not_found}

  @doc "Read one provisioned agent's tenant-scoped Salix control projection."
  @spec get_salix_agent(Project.t(), Agent.t()) :: {:ok, map()} | {:error, term()}
  def get_salix_agent(%Project{} = project, %Agent{} = agent) do
    with :ok <- require_agent_in_project(project, agent),
         :ok <- require_provisioned_agent(agent),
         {:ok, _project, org} <- project_org(project) do
      Client.impl().get_agent_projection(agent.salix_agent_id, org.salix_tenant_id)
    end
  end

  @doc "Switch a Router agent to a fresh canonical Salix session."
  @spec switch_router_session(Project.t(), Agent.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def switch_router_session(
        %Project{} = project,
        %Agent{} = agent,
        expected_session_id,
        opts \\ []
      )
      when is_binary(expected_session_id) and is_list(opts) do
    result =
      with :ok <- require_agent_in_project(project, agent),
           :ok <- require_provisioned_agent(agent),
           :ok <- require_router_agent(agent),
           {:ok, _project, org} <- project_org(project) do
        Client.impl().switch_router_session(
          agent.salix_agent_id,
          org.salix_tenant_id,
          expected_session_id
        )
      end

    case result do
      {:ok, %{"router_session_id" => new_session_id} = switched} ->
        _ =
          maybe_record_agent_audit("agent.router_session_switched", agent, opts,
            redacted_diff: %{
              "router_session_id" => %{
                "from" => expected_session_id,
                "to" => new_session_id
              }
            }
          )

        {:ok, switched}

      {:error, reason} = error ->
        _ =
          record_agent_write_attempt(
            agent,
            "agent.router_session_switched",
            "failed",
            reason,
            opts,
            metadata: %{"expected_session_id" => expected_session_id}
          )

        error

      other ->
        {:error, {:bad_salix_router_session_switch, other}}
    end
  end

  @doc "Fetch an active project agent by local id, Salix agent id, or unique name."
  @spec get_project_agent(Ecto.UUID.t(), String.t()) ::
          {:ok, Agent.t()} | {:error, :not_found | :agent_ambiguous}
  def get_project_agent(project_id, ref) do
    ref = trim(ref)
    project = Repo.get(Project, project_id)

    cond do
      ref == "" or is_nil(project) ->
        {:error, :not_found}

      Ids.valid_agent_id_for_group?(ref, project.salix_group_id) ->
        association =
          Repo.get_by(Agent, project_id: project_id, salix_agent_id: ref) ||
            %Agent{
              id: ref,
              salix_agent_id: ref,
              project_id: project_id,
              configuration_authority: "salix"
            }

        resolve_association(association)

      Ecto.UUID.cast(ref) != :error ->
        case Repo.get_by(Agent, id: ref, project_id: project_id) do
          nil -> agent_by_name(project, ref)
          agent -> resolve_association(agent)
        end

      true ->
        agent_by_name(project, ref)
    end
    |> case do
      {:ok, %Agent{salix: record}} when is_map_key(record, "archived_at") -> {:error, :not_found}
      result -> result
    end
  end

  defp agent_by_name(project, ref) do
    with {:ok, %{items: items, next_cursor: nil}} <- page_agents(project, limit: 500, filter: ref) do
      case Enum.filter(items, &(&1.salix["name"] == ref)) do
        [agent] -> {:ok, agent}
        [] -> {:error, :not_found}
        _ -> {:error, :agent_ambiguous}
      end
    else
      {:ok, _} -> {:error, :agent_lookup_requires_id}
      error -> error
    end
  end

  @doc "Resolve the active BFT agent configured as a project's Salix Router."
  @spec current_router(Project.t()) ::
          {:ok, Agent.t()}
          | {:error, :router_not_configured | :router_agent_not_found | term()}
  def current_router(%Project{} = project) do
    with {:ok, group} <- Client.impl().get_group(project.salix_group_id),
         router_id = group["router_agent_id"] |> to_string() |> String.trim(),
         false <- router_id == "",
         true <- Ids.valid_agent_id_for_group?(router_id, project.salix_group_id),
         {:ok, agent} <- get_project_agent(project.id, router_id) do
      {:ok, agent}
    else
      true -> {:error, :router_not_configured}
      false -> {:error, :router_agent_not_found}
      {:error, :not_found} -> {:error, :router_agent_not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Read one bounded canonical Agent page, retaining existing product reference ids.
  The swarm's Task agent (`SalixAgent.TaskAgent`) belongs to Salix and is left out.
  """
  def page_agents(%Project{} = project, opts \\ []) do
    opts = Keyword.put(opts, :exclude_task_agent, true)

    with {:ok, _project, org} <- project_org(project),
         {:ok, page} <-
           Client.impl().page_group_agents(org.salix_tenant_id, project.salix_group_id, opts) do
      associations = ensure_associations(project, page.items)

      items =
        Enum.map(page.items, fn record ->
          association = Map.fetch!(associations, record["agent_id"])
          with_record(association, record)
        end)

      {:ok,
       %{
         items: items,
         next_cursor: page.next_cursor
       }}
    end
  end

  # Materialize only the product reference needed by existing URLs/FKs and
  # product-owned background work. No configuration fields are copied here.
  defp ensure_associations(project, records) do
    ids = Enum.map(records, & &1["agent_id"])
    query = from(a in Agent, where: a.project_id == ^project.id and a.salix_agent_id in ^ids)
    existing = Repo.all(query) |> Map.new(&{&1.salix_agent_id, &1})
    now = SystemsClock.utc_now()

    missing =
      records
      |> Enum.reject(&Map.has_key?(existing, &1["agent_id"]))
      |> Enum.filter(&(&1["configuration_authority"] == "salix"))
      |> Enum.map(fn record ->
        %{
          id: SystemsRuntime.Proc.uuid(),
          project_id: project.id,
          salix_agent_id: record["agent_id"],
          role: record["role"],
          configuration_authority: "salix",
          created_at: now,
          updated_at: now
        }
      end)

    existing =
      if missing == [] do
        existing
      else
        Repo.insert_all(Agent, missing, on_conflict: :nothing, conflict_target: [:salix_agent_id])
        Repo.all(query) |> Map.new(&{&1.salix_agent_id, &1})
      end

    # Reading an unclaimed Salix-only record must not manufacture a BFT owner.
    Enum.reduce(records, existing, fn record, refs ->
      id = record["agent_id"]

      Map.put_new(refs, id, %Agent{
        id: id,
        project_id: project.id,
        salix_agent_id: id,
        role: record["role"],
        configuration_authority: "salix"
      })
    end)
  end

  @doc "Read the canonical project roster within the product's 500-Agent view budget."
  @spec list_agents(Ecto.UUID.t()) :: [Agent.t()]
  def list_agents(project_id), do: list_agents(project_id, limit: 500)

  @doc "Read a bounded canonical roster; larger groups use page_agents/2 with its cursor."
  @spec list_agents(Ecto.UUID.t(), keyword()) :: [Agent.t()]
  def list_agents(project_id, opts) when is_list(opts) do
    case fetch_agents(project_id, opts) do
      {:ok, agents} ->
        agents

      {:error, :agent_roster_requires_pagination} ->
        raise "Agent roster exceeds the 500-Agent view budget; use page_agents/2 with its cursor"

      {:error, reason} ->
        raise "Canonical Agent roster unavailable: #{inspect(reason)}"
    end
  end

  @doc "Read a complete bounded roster, preserving owner errors for product callers."
  def fetch_agents(project_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 500) |> max(1) |> min(500)

    with %Project{} = project <- Repo.get(Project, project_id) || {:error, :project_not_found},
         {:ok, page} <- page_agents(project, Keyword.put(opts, :limit, 500)) do
      case page do
        %{items: items, next_cursor: nil} ->
          {:ok, items |> Enum.sort_by(&{&1.salix["name"] || "", &1.id}) |> Enum.take(limit)}

        _ ->
          {:error, :agent_roster_requires_pagination}
      end
    end
  end

  @doc """
  The stations of a project its Tasks can run on: its devices whose Comma
  station takes Tasks (`capabilities.tasks` 2), each with the models its
  profiles enable per runtime (`task_models`), and whether the project's
  Cloud VM is enabled. Each station's `station` is "ready", or why it cannot
  take Tasks: "device_needs_station" (no `tasks`: the old connector) or
  "station_outdated" (an older `tasks`); those are not selectable.
  """
  @spec list_stations(Project.t()) :: {:ok, map()}
  def list_stations(%Project{} = project) do
    {:ok, environments} = Environments.list_projected_environments(project.id)
    cloud_vm_device = RuntimeIds.cloud_vm_device_id(project.salix_group_id)

    stations =
      for env <- environments,
          is_binary(env["device_id"]),
          env["device_id"] != cloud_vm_device do
        %{
          "device_id" => env["device_id"],
          "name" => env["name"],
          "status" => env["status"],
          "station" => station_kind(env),
          "task_models" => task_models(env)
        }
      end

    cloud_vm = Enum.find(environments, &(&1["device_id"] == cloud_vm_device))

    {:ok,
     %{
       "stations" => stations,
       "cloud_vm" => %{
         "enabled" => project.vm_enabled == true,
         "task_models" => if(cloud_vm, do: task_models(cloud_vm), else: %{})
       }
     }}
  end

  # "ready", or why the device cannot take Tasks (`SalixStore.StationReadiness`):
  # "device_needs_station" (the old connector) or "station_outdated".
  defp station_kind(env) do
    case SalixStore.StationReadiness.check(env["capabilities"]) do
      :ready -> "ready"
      {reason, _info} -> Atom.to_string(reason)
    end
  end

  defp task_models(env) do
    case get_in(env, ["capabilities", "task_models"]) do
      %{} = models ->
        Map.new(
          ~w(codex claude),
          &{&1, Enum.filter(List.wrap(models[&1]), fn m -> is_binary(m) end)}
        )

      _none ->
        %{}
    end
  end

  @doc """
  Check a place the swarm's Tasks may run by default (`SalixAgent.TaskPlace`):
  `%{"kind" => "salix"}`, `%{"kind" => "cloud_vm"}` while the project's Cloud
  VM is enabled, or `%{"kind" => "station", "device_id" => id}` for a device
  of the project whose station takes Tasks. Answers the place to store.
  """
  @spec task_place(Project.t(), term()) :: {:ok, map()} | {:error, term()}
  def task_place(%Project{} = project, %{} = place) do
    case stringify_nested(place) do
      %{"kind" => "salix"} = salix when map_size(salix) == 1 ->
        {:ok, salix}

      %{"kind" => kind} = target when kind in ["cloud_vm", "station"] ->
        station_runs_on(project, target)

      _other ->
        {:error, :invalid_task_place}
    end
  end

  def task_place(%Project{}, _place), do: {:error, :invalid_task_place}

  defp station_runs_on(project, %{"kind" => "cloud_vm"}) do
    if project.vm_enabled == true,
      do: {:ok, %{"kind" => "cloud_vm"}},
      else: {:error, :cloud_vm_disabled}
  end

  defp station_runs_on(project, %{"kind" => "station"} = target) do
    device_id = trim(target["device_id"])
    {:ok, environments} = Environments.list_projected_environments(project.id)

    cond do
      device_id == "" ->
        {:error, :station_required}

      device_id == RuntimeIds.cloud_vm_device_id(project.salix_group_id) ->
        {:ok, %{"kind" => "cloud_vm"}}

      true ->
        case Enum.find(environments, &(&1["device_id"] == device_id)) do
          nil -> {:error, :station_not_found}
          env -> station_ready(env, device_id)
        end
    end
  end

  defp station_runs_on(_project, %{"kind" => kind})
       when kind in ["connected_runtime", "compute_workload", "external"],
       do: {:error, :external_runtime_retired}

  defp station_runs_on(_project, _target), do: {:error, :station_required}

  defp station_ready(env, device_id) do
    case station_kind(env) do
      "ready" -> {:ok, %{"kind" => "station", "device_id" => device_id}}
      "device_needs_station" -> {:error, :device_needs_station}
      "station_outdated" -> {:error, :station_outdated}
    end
  end

  @doc """
  Patch a Router's Salix-owned configuration synchronously. A Worker is
  read-only history (`{:error, :workers_retired}`).
  """
  @spec update_agent(Agent.t(), map(), keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def update_agent(%Agent{} = agent, attrs, opts \\ []) do
    attrs = normalize(attrs)

    result =
      cond do
        agent.role != "router" -> {:error, :workers_retired}
        Map.has_key?(attrs, "runtime_config") -> {:error, :use_runtime_rebind}
        true -> write_canonical(agent, &configure_canonical(&1, attrs, opts))
      end

    maybe_record_agent_write_failure(result, "agent.config_updated", agent, attrs, opts)
  end

  @doc """
  Make `agent` the router agent for its project's Salix group. Enqueues an
  `update_group` reconcile row that sets the group's `router_agent_id` to the
  agent's `salix_agent_id` (so inbound IM/bridge messages route to it).
  """
  @spec set_router_agent(Agent.t(), keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def set_router_agent(agent, opts \\ [])

  def set_router_agent(%Agent{salix_agent_id: nil} = agent, opts) do
    {:error, :not_provisioned}
    |> maybe_record_agent_write_failure("agent.router_set", agent, %{}, opts)
  end

  def set_router_agent(%Agent{} = agent, opts) do
    project = Repo.get(Project, agent.project_id)
    org = project && Repo.get(Organization, project.org_id)

    cond do
      is_nil(project) ->
        {:error, :project_not_found}
        |> maybe_record_agent_write_failure("agent.router_set", agent, %{}, opts)

      is_nil(org) ->
        {:error, :org_not_found}
        |> maybe_record_agent_write_failure("agent.router_set", project, %{}, opts)

      true ->
        agent
        |> set_router_agent(project, org, opts)
        |> maybe_record_agent_write_failure("agent.router_set", agent, %{}, opts)
    end
  end

  @doc "Record a failed or denied agent write attempt without mutating agents."
  @spec record_agent_write_attempt(
          Project.t() | Agent.t() | Ecto.UUID.t(),
          String.t(),
          String.t(),
          term(),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def record_agent_write_attempt(scope, action, result, reason, opts \\ [])

  def record_agent_write_attempt(scope, action, result, reason, opts) do
    record_agent_write_attempt(scope, action, result, reason, opts, [])
  end

  @doc """
  Deliver a message to an agent's Salix runtime (erpc `SalixAgent.deliver/3`,
  authorized in BridgeForTeams first). Returns the Salix result.
  """
  @spec deliver(Agent.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(%Agent{salix_agent_id: nil}, _payload, _opts), do: {:error, :not_provisioned}

  def deliver(%Agent{salix_agent_id: salix_agent_id} = agent, payload, opts) do
    with {:ok, context} <- billing_context(agent),
         {:ok, _check} <- authorize_fee_control(context) do
      payload =
        payload
        |> stringify_payload()
        |> Map.put("billing_context", context)

      Client.impl().deliver(salix_agent_id, payload, opts)
    end
  end

  # ---- internal ----

  defp maybe_record_agent_write_failure({:ok, _value} = result, _action, _scope, _attrs, _opts),
    do: result

  defp maybe_record_agent_write_failure(
         {:error, :mutation_outcome_unknown} = result,
         _action,
         _scope,
         _attrs,
         _opts
       ),
       do: result

  defp maybe_record_agent_write_failure({:error, reason} = result, action, scope, attrs, opts) do
    _ =
      record_agent_write_attempt(scope, action, "failed", reason, opts,
        metadata: attempted_agent_metadata(attrs)
      )

    result
  end

  defp record_agent_write_attempt(scope, action, result, reason, opts, extra) do
    if audit_enabled?(opts) do
      with {:ok, project, agent} <- audit_scope(scope) do
        Observability.record_audit(%{
          org_id: project.org_id,
          actor_user_id: Keyword.get(opts, :actor_user_id),
          actor_label: Keyword.get(opts, :actor_label),
          action: action,
          resource_type: "agent",
          resource_id: agent && agent.id,
          resource_label: agent_attempt_label(agent),
          result: result,
          reason_class: failure_reason_class(reason),
          request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
          metadata: agent_attempt_metadata(project, agent, reason, extra),
          redacted_diff: %{}
        })
      end
    else
      {:ok, nil}
    end
  end

  defp audit_scope(%Agent{} = agent) do
    case Repo.get(Project, agent.project_id) do
      %Project{} = project -> {:ok, project, agent}
      nil -> {:error, :project_not_found}
    end
  end

  defp audit_scope(%Project{} = project), do: {:ok, project, nil}

  defp audit_scope(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> {:ok, project, nil}
      nil -> {:error, :project_not_found}
    end
  end

  defp audit_scope(_scope), do: {:error, :project_not_found}

  defp project_org(%Project{} = project) do
    case Repo.get(Organization, project.org_id) do
      %Organization{} = org -> {:ok, project, org}
      nil -> {:error, :org_not_found}
    end
  end

  defp agent_attempt_metadata(%Project{} = project, nil, reason, extra) do
    %{
      "project_id" => project.id,
      "project_name" => project.name,
      "reason_class" => failure_reason_class(reason),
      "validation_fields" => validation_fields(reason)
    }
    |> Map.merge(Keyword.get(extra, :metadata, %{}))
    |> compact_metadata()
  end

  defp agent_attempt_metadata(%Project{} = project, %Agent{} = agent, reason, extra) do
    agent
    |> agent_audit_metadata(project)
    |> Map.merge(%{
      "reason_class" => failure_reason_class(reason),
      "validation_fields" => validation_fields(reason)
    })
    |> Map.merge(Keyword.get(extra, :metadata, %{}))
    |> compact_metadata()
  end

  defp attempted_agent_metadata(attrs) when is_map(attrs) do
    attrs = stringify_nested(attrs)

    %{
      "attempted_name_configured" => configured?(attrs["name"]),
      "attempted_role" => attrs["role"],
      "attempted_model" => model_audit_value(attrs["model"]),
      "attempted_instructions_configured" =>
        configured?(attrs["router_system_prompt"]) || configured?(attrs["system_prompt"]),
      "attempted_model_configured" =>
        configured?(attrs["model"]) || configured?(attrs["llm_config"]),
      "attempted_inline_model_configured" => configured?(attrs["llm_config"])
    }
    |> compact_metadata()
  end

  defp attempted_agent_metadata(_attrs), do: %{}

  defp failure_reason_class(%Ecto.Changeset{}), do: "validation_failed"
  defp failure_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_class({reason, _detail}) when is_binary(reason), do: reason
  defp failure_reason_class(_reason), do: "unknown"

  defp validation_fields(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validation_fields(_reason), do: []

  defp agent_attempt_label(%Agent{} = agent), do: agent_label(agent)
  defp agent_attempt_label(nil), do: "Agent write attempt"

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp set_router_agent(%Agent{} = agent, %Project{} = project, %Organization{} = org, opts) do
    if audit_enabled?(opts) do
      Repo.transaction(fn ->
        with {:ok, _} <- enqueue_router_update(agent, project, org),
             {:ok, _audit} <-
               record_agent_audit("agent.router_set", agent, project, opts,
                 redacted_diff: %{
                   "router_agent_id" => %{"from" => nil, "to" => agent.salix_agent_id}
                 }
               ) do
          agent
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      with {:ok, _} <- enqueue_router_update(agent, project, org) do
        {:ok, agent}
      end
    end
  end

  defp enqueue_router_update(%Agent{} = agent, %Project{} = project, %Organization{} = org) do
    Outbox.enqueue("project", project.id, "update_group", %{
      "group_id" => project.salix_group_id,
      "tenant_id" => org.salix_tenant_id,
      "attrs" => %{
        "router_agent_id" => agent.salix_agent_id,
        "billing_owner" => group_billing_owner(org, project, agent.salix_agent_id)
      }
    })
  end

  defp maybe_record_agent_audit(action, %Agent{} = agent, opts, extra) do
    if audit_enabled?(opts) do
      case Repo.get(Project, agent.project_id) do
        %Project{} = project -> record_agent_audit(action, agent, project, opts, extra)
        nil -> {:error, :project_not_found}
      end
    else
      {:ok, nil}
    end
  end

  # BFT records only calls initiated here. No audit callback or transport is
  # installed in Salix. A missing outcome never claims the remote write rolled back.
  defp audit_canonical_call(before, action, opts, operation) do
    opts = Keyword.put_new_lazy(opts, :request_id, &SystemsRuntime.Proc.uuid/0)

    with {:ok, _} <-
           record_agent_write_attempt(
             before,
             action <> ".requested",
             "unknown",
             :mutation_outcome_unknown,
             opts
           ) do
      case operation.() do
        {:ok, updated} ->
          case maybe_record_agent_audit(action, updated, opts,
                 redacted_diff: agent_config_diff(before, updated)
               ) do
            {:ok, _} -> {:ok, updated}
            _ -> {:error, :mutation_outcome_unknown}
          end

        {:error, reason} when reason in [:unavailable, :timeout] ->
          {:error, :mutation_outcome_unknown}

        error ->
          error
      end
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp record_agent_audit(action, %Agent{} = agent, %Project{} = project, opts, extra) do
    Observability.record_audit(%{
      org_id: project.org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: action,
      resource_type: "agent",
      resource_id: agent.id,
      resource_label: agent_label(agent),
      result: "ok",
      request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
      metadata: agent_audit_metadata(agent, project),
      redacted_diff: Keyword.get(extra, :redacted_diff, %{})
    })
  end

  defp agent_audit_metadata(%Agent{} = agent, %Project{} = project) do
    %{
      "agent_id" => agent.id,
      "runtime_agent_id" => agent.salix_agent_id,
      "project_id" => project.id,
      "project_name" => project.name,
      "agent_name" => agent.salix["name"],
      "role" => agent.role,
      "slot" => agent.slot,
      "status" => Agent.lifecycle(agent),
      "archived_at" => agent.salix["archived_at"],
      "model" => model_audit_value(agent.salix["model"]),
      "instructions_configured" => configured?(Agent.instructions(agent)),
      "model_configured" => model_configured?(agent),
      "inline_model_configured" => configured?(agent.salix["llm_config"])
    }
  end

  defp agent_config_diff(nil, %Agent{} = agent) do
    agent
    |> agent_config_snapshot()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, %{"from" => nil, "to" => value}} end)
  end

  defp agent_config_diff(%Agent{} = before, %Agent{} = after_agent) do
    after_snapshot = agent_config_snapshot(after_agent)

    before
    |> agent_config_snapshot()
    |> Enum.reject(fn {key, value} -> after_snapshot[key] == value end)
    |> Map.new(fn {key, value} -> {key, %{"from" => value, "to" => after_snapshot[key]}} end)
  end

  defp agent_config_snapshot(%Agent{} = agent) do
    %{
      "name" => agent.salix["name"],
      "purpose" => agent.salix["management_purpose"],
      "role" => agent.role,
      "slot" => agent.slot,
      "status" => Agent.lifecycle(agent),
      "archived_at" => agent.salix["archived_at"],
      "model" => model_audit_value(agent.salix["model"]),
      "instructions_configured" => configured?(Agent.instructions(agent)),
      "model_configured" => model_configured?(agent),
      "inline_model_configured" => configured?(agent.salix["llm_config"])
    }
  end

  defp agent_label(%Agent{salix: %{"name" => name}}) when is_binary(name) and name != "", do: name
  defp agent_label(%Agent{salix_agent_id: id}) when is_binary(id) and id != "", do: id
  defp agent_label(%Agent{id: id}), do: id

  defp model_configured?(%Agent{} = agent),
    do: configured?(agent.salix["model"]) || configured?(agent.salix["llm_config"])

  # A model choice names a model and no credential; a pinned Profile shows only
  # that one is pinned.
  defp model_audit_value(%{} = choice) do
    choice
    |> Map.take(~w(kind model provider tier reasoning_effort allow_paid))
    |> Map.put("profile_pinned", is_binary(choice["profile_id"]))
  end

  defp model_audit_value(_choice), do: nil

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(value) when is_map(value), do: map_size(value) > 0
  defp configured?(value), do: not is_nil(value)

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      configured?(Keyword.get(opts, :actor_user_id)) ||
      configured?(Keyword.get(opts, :actor_label))
  end

  # Provision the Salix control-plane agent record under the org's tenant +
  # project group (so connector tokens minted for it validate), then its LLM
  # config. The org tenant + project group come from the project's org. The
  # agent's model is its `model` choice (`BridgeForTeams.Models`); without one
  # it follows the platform model of its role.
  defp enqueue_config(%Agent{} = agent) do
    project = Repo.get(Project, agent.project_id)
    org = project && Repo.get(Organization, project.org_id)

    attrs =
      %{
        "agent_id" => agent.salix_agent_id,
        "group_id" => project && project.salix_group_id,
        "tenant_id" => org && org.salix_tenant_id,
        "role" => agent.role,
        "name" => agent.salix["name"]
      }
      |> maybe_put("system_prompt", agent.salix["system_prompt"])
      |> maybe_put("purpose", agent.salix["management_purpose"])
      |> maybe_put("model", agent.salix["model"])

    {:ok, _} = Outbox.enqueue("agent", agent.id, "create_owned_agent", %{"attrs" => attrs})

    :ok
  end

  # A Router is internal: `runtime_config` takes only the internal kind.
  defp reject_runtime_config(attrs, project_id) do
    case Map.pop(attrs, "runtime_config") do
      {nil, attrs} ->
        {:ok, attrs}

      {%{"kind" => "internal"}, attrs} ->
        {:ok, attrs}

      {%{"kind" => kind}, _attrs}
      when kind in ["external", "connected_runtime", "compute_workload"] ->
        {:error, :external_runtime_retired}

      {_config, attrs} ->
        {:error,
         %Agent{}
         |> Agent.changeset(Map.put(attrs, "project_id", project_id))
         |> Ecto.Changeset.add_error(:runtime_config, "must be an object")}
    end
  end

  defp require_provisioned_agent(%Agent{salix_agent_id: id}) when is_binary(id) and id != "",
    do: :ok

  defp require_provisioned_agent(%Agent{}), do: {:error, :not_provisioned}

  defp require_agent_in_project(%Project{id: project_id}, %Agent{project_id: project_id}),
    do: :ok

  defp require_agent_in_project(%Project{}, %Agent{}), do: {:error, :agent_not_in_project}

  defp require_router_agent(%Agent{role: "router"}), do: :ok
  defp require_router_agent(%Agent{}), do: {:error, :unsupported_agent_role}

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp trim(_value), do: ""

  defp billing_context(%Agent{} = agent) do
    project = Repo.get(Project, agent.project_id)
    org = project && Repo.get(Organization, project.org_id)

    cond do
      is_nil(project) ->
        {:error, :project_not_found}

      is_nil(org) ->
        {:error, :org_not_found}

      true ->
        {:ok,
         %{
           "billing_account_id" => org.billing_account_id,
           "surface" => "bridge",
           "product_owner_type" => "organization",
           "product_owner_id" => org.id,
           "project_id" => project.id,
           "agent_id" => agent.id,
           "salix_tenant_id" => org.salix_tenant_id,
           "salix_group_id" => project.salix_group_id,
           "salix_agent_id" => agent.salix_agent_id,
           "charge_policy" => "platform_paid",
           "entrypoint" => "direct_deliver",
           "actor_type" => "external_user"
         }}
    end
  end

  defp authorize_fee_control(context) do
    if SalixAgent.AccountPool.agent_uses_pool?(
         context["salix_agent_id"],
         context["salix_tenant_id"]
       ) do
      {:ok, %{allowed?: true, reason: "tenant_account_pool"}}
    else
      authorize_platform_fee(context)
    end
  end

  defp authorize_platform_fee(context) do
    request = %Request{
      billing_account_id: context["billing_account_id"],
      provider: "runtime",
      sku: "llm",
      resource_kind: :llm,
      action: :start,
      mode: :enforce,
      estimated_credits: 1,
      balance_snapshot: 0,
      row_context: %{
        "billing_account_id" => context["billing_account_id"],
        "surface" => context["surface"],
        "product_owner_type" => context["product_owner_type"],
        "product_owner_id" => context["product_owner_id"],
        "tenant_id" => context["salix_tenant_id"],
        "group_id" => context["salix_group_id"],
        "entrypoint" => context["entrypoint"],
        "actor_type" => context["actor_type"]
      }
    }

    result =
      case safe_fee_control(request) do
        {:ok, result} -> result
        {:error, reason} -> fee_control_fallback(request, reason)
      end

    case SystemsRuntime.get_env(:bridge_for_teams_core, :fee_control_observer) do
      observer when SystemsRuntime.Proc.is_process(observer) ->
        SystemsRuntime.Proc.send(observer, {:bridge_fee_control_check, result, context})

      _ ->
        :ok
    end

    if result.allowed? do
      {:ok, result}
    else
      {:error, {:billing_unavailable, result}}
    end
  end

  defp safe_fee_control(%Request{} = request) do
    BillingCore.FeeControl.authorize(request)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fee_control_fallback(%Request{} = request, reason) do
    %{
      mode: :enforce,
      allowed?: false,
      would_block: true,
      cache_hit: false,
      cache_age_ms: nil,
      cache_ttl_ms: nil,
      query_performed: false,
      query_duration_ms: 0,
      balance_snapshot: nil,
      provider: request.provider,
      sku: request.sku,
      resource_kind: request.resource_kind,
      action: request.action,
      reason: "fee_control_error",
      error: inspect(reason)
    }
  end

  defp stringify_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), value} end)
  end

  defp group_billing_owner(%Organization{} = org, %Project{} = project, router_agent_id) do
    %{
      "billing_account_id" => org.billing_account_id,
      "surface" => "bridge",
      "vm_profile_key" => "cf-standard-2",
      "product_owner_type" => "organization",
      "product_owner_id" => org.id,
      "project_id" => project.id,
      "salix_tenant_id" => org.salix_tenant_id,
      "salix_group_id" => project.salix_group_id,
      "router_agent_id" => router_agent_id,
      "charge_policy" => "platform_paid"
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> stringify_map("runtime_config")
  end

  defp stringify_map(attrs, key) do
    case attrs do
      %{^key => config} when is_map(config) -> Map.put(attrs, key, stringify_nested(config))
      _other -> attrs
    end
  end

  defp stringify_nested(%_{} = value), do: value

  defp stringify_nested(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        cond do
          is_map(value) -> stringify_nested(value)
          is_list(value) -> Enum.map(value, &stringify_list_value/1)
          true -> value
        end

      {to_string(key), value}
    end)
  end

  defp stringify_list_value(%_{} = value), do: value
  defp stringify_list_value(value) when is_map(value), do: stringify_nested(value)
  defp stringify_list_value(value), do: value
end
