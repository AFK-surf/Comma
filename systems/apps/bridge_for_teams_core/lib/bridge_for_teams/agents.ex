defmodule BridgeForTeams.Agents do
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

  alias BridgeForTeams.{Environments, Observability, Repo}
  alias BridgeForTeams.Outbox
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Salix.Identity
  alias BridgeForTeams.Schema.{Agent, Organization, Project, ReconcileOutbox}
  alias BillingCore.FeeControl.Request
  alias SalixStore.{Ids, RuntimeIds}

  @public_external_runtime_config_keys ~w(
    binding_revision
    kind
    owner_scope
    provider
    device_id
    runtime_id
    device_runtime_id
    model
    model_provider
    reasoning_effort
    runtime_spec
    workload_id
  )
  @compute_external_providers ~w(codex pi claude)

  @doc "Create a product association and enqueue the initial Salix-owned Agent configuration."
  @spec create_agent(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Agent.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_agent(project_id, attrs, opts \\ []) do
    attrs = normalize(attrs)
    attempted_attrs = attrs
    project = Repo.get(Project, project_id)

    result =
      with :ok <- reject_inline_model_config(attrs) do
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

    {runtime_config, attrs} = pop_runtime_config(attrs, project_id)

    Repo.transaction(fn ->
      with {:ok, runtime_config} <- runtime_config do
        changeset =
          %Agent{}
          |> Agent.changeset(maybe_put(attrs, "runtime_config", runtime_config))

        with {:ok, agent} <- insert_association(changeset) do
          enqueue_config(agent, runtime_config, opts)

          with {:ok, _audit} <-
                 maybe_record_agent_audit("agent.created", agent, opts,
                   redacted_diff: agent_create_diff(agent, runtime_config)
                 ) do
            agent
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, %Ecto.Changeset{} = cs} ->
            Repo.rollback(cs)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
        agent = Repo.one!(from a in Agent, where: a.id == ^id, lock: "FOR UPDATE")
        # Operator-only legacy read; product Agent DTO fields are virtual.
        archived_at =
          Repo.one(
            from a in Agent,
              where: a.id == ^id,
              select: type(fragment("archived_at"), :utc_datetime_usec)
          )

        if agent.configuration_authority == "legacy" do
          outstanding =
            Repo.exists?(
              from r in ReconcileOutbox,
                where: r.aggregate == "agent" and r.aggregate_id == ^id and r.status != "done"
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
        locked = Repo.one!(from a in Agent, where: a.id == ^id, lock: "FOR UPDATE")

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
        from r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^id and
              r.op == "create_owned_agent" and r.status in ["pending", "failed"],
          order_by: [desc: r.created_at],
          limit: 1
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
    if attrs["llm_config"] in [nil, %{}], do: :ok, else: {:error, :use_template_catalog}
  end

  defp configure_canonical(agent, attrs, opts) do
    with :ok <- reject_inline_model_config(attrs),
         {:ok, current} <- canonical_agent(agent),
         true <- is_nil(current.provisioning) || {:error, :agent_provisioning},
         true <- not Map.has_key?(current.salix, "archived_at") || {:error, :agent_archived},
         true <- attrs["role"] in [nil, current.role] || {:error, :agent_role_immutable},
         {:ok, _project, org} <- project_org(Repo.get!(Project, agent.project_id)) do
      audit_canonical_call(
        current,
        Keyword.get(opts, :audit_action, "agent.config_updated"),
        opts,
        fn ->
          with {:ok, record} <-
                 Client.impl().configure_agent(
                   agent.salix_agent_id,
                   org.salix_tenant_id,
                   Map.delete(attrs, "role")
                 ),
               do: {:ok, with_record(agent, record)}
        end
      )
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

  @doc "Read one bounded canonical Agent page, retaining existing product reference ids."
  def page_agents(%Project{} = project, opts \\ []) do
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
    query = from a in Agent, where: a.project_id == ^project.id and a.salix_agent_id in ^ids
    existing = Repo.all(query) |> Map.new(&{&1.salix_agent_id, &1})
    now = DateTime.utc_now()

    missing =
      records
      |> Enum.reject(&Map.has_key?(existing, &1["agent_id"]))
      |> Enum.filter(&(&1["configuration_authority"] == "salix"))
      |> Enum.map(fn record ->
        %{
          id: Ecto.UUID.generate(),
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

  @doc "List current project runtimes that can be used for external agent binding."
  @spec list_external_runtimes(Ecto.UUID.t()) :: {:ok, [map()]}
  def list_external_runtimes(project_id) do
    {:ok, environments} = Environments.list_projected_environments(project_id)
    {:ok, project_external_runtimes(environments)}
  end

  @doc "List one bounded page of Compute Workloads owned by a BFT Project."
  @spec page_external_worker_targets(Project.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def page_external_worker_targets(project, provider, opts \\ [])

  def page_external_worker_targets(%Project{} = project, provider, opts)
      when provider in @compute_external_providers and is_list(opts) do
    with {:ok, project, org} <- project_org(project) do
      Client.impl().page_external_worker_targets(
        org.salix_tenant_id,
        "project",
        project.id,
        project.salix_group_id,
        provider,
        Keyword.take(opts, [:cursor, :query, :node_id, :limit, :include_unavailable])
      )
    end
  end

  def page_external_worker_targets(%Project{}, _provider, _opts),
    do: {:error, :provider_unsupported}

  @doc "Create an external worker from a server-validated Connected or Compute target."
  @spec create_external_agent(Project.t(), map(), map(), keyword()) ::
          {:ok, Agent.t()} | {:error, term()}
  def create_external_agent(%Project{} = project, attrs, target, opts \\ [])
      when is_map(attrs) and is_map(target) do
    with {:ok, runtime_config} <- external_target_config(project, target, 1) do
      attrs =
        attrs
        |> normalize()
        |> Map.take(["name", "purpose"])
        |> Map.put("role", "worker")
        |> Map.put("runtime_config", runtime_config)

      create_agent(project.id, attrs, opts)
    end
  end

  @doc "CAS the canonical binding of an external worker after exact target validation."
  @spec rebind_external_target(Project.t(), Agent.t(), map(), non_neg_integer(), keyword()) ::
          {:ok, Agent.t()} | {:error, term()}
  def rebind_external_target(
        %Project{} = project,
        %Agent{} = agent,
        target,
        expected_binding_revision,
        opts \\ []
      )
      when is_map(target) and is_integer(expected_binding_revision) and
             expected_binding_revision >= 0 do
    result =
      with :ok <- require_agent_in_project(project, agent),
           :ok <- require_provisioned_agent(agent),
           :ok <- require_worker_runtime_rebind(agent),
           {:ok, _project, org} <- project_org(project),
           {:ok, runtime_config} <-
             external_target_config(project, target, expected_binding_revision + 1) do
        apply_external_target_rebind(
          agent,
          org,
          runtime_config,
          expected_binding_revision,
          opts
        )
      end

    maybe_record_agent_write_failure(result, "agent.runtime_rebound", agent, %{}, opts)
  end

  @doc "Patch the Salix-owned configuration synchronously."
  @spec update_agent(Agent.t(), map(), keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def update_agent(%Agent{} = agent, attrs, opts \\ []) do
    attrs = normalize(attrs)

    result =
      if Map.has_key?(attrs, "runtime_config") do
        {:error, :use_runtime_rebind}
      else
        write_canonical(agent, &configure_canonical(&1, attrs, opts))
      end

    maybe_record_agent_write_failure(result, "agent.config_updated", agent, attrs, opts)
  end

  @doc "Rebind a provisioned project worker to a current project external runtime."
  @spec rebind_external_runtime(Project.t(), Agent.t(), String.t()) ::
          {:ok, Agent.t()} | {:error, term()}
  def rebind_external_runtime(%Project{} = project, %Agent{} = agent, runtime_ref) do
    rebind_external_runtime(project, agent, runtime_ref, nil, [])
  end

  @spec rebind_external_runtime(Project.t(), Agent.t(), String.t(), String.t() | nil | keyword()) ::
          {:ok, Agent.t()} | {:error, term()}
  def rebind_external_runtime(%Project{} = project, %Agent{} = agent, runtime_ref, opts)
      when is_list(opts) do
    rebind_external_runtime(project, agent, runtime_ref, nil, opts)
  end

  def rebind_external_runtime(%Project{} = project, %Agent{} = agent, runtime_ref, device_ref) do
    rebind_external_runtime(project, agent, runtime_ref, device_ref, [])
  end

  @spec rebind_external_runtime(Project.t(), Agent.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Agent.t()} | {:error, term()}
  def rebind_external_runtime(
        %Project{} = project,
        %Agent{} = agent,
        runtime_ref,
        device_ref,
        opts
      )
      when is_list(opts) do
    preflight =
      with :ok <- require_agent_in_project(project, agent),
           {:ok, project, org} <- project_org(project),
           :ok <- require_provisioned_agent(agent),
           :ok <- require_worker_runtime_rebind(agent),
           {:ok, runtime_config} <-
             project_runtime_config(project.id, runtime_ref, device_ref) do
        {:ok, project, org, runtime_config}
      end

    case preflight do
      {:ok, project, org, runtime_config} ->
        enqueue_runtime_rebind(agent, project, org, runtime_config, opts)

      {:error, _reason} = err ->
        maybe_record_agent_write_failure(err, "agent.runtime_rebound", agent, %{}, opts)
    end
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

  @doc "The Swarm's current Triage assignment, read once for the agent list or archive confirmation."
  def triage_worker_binding(%Project{salix_group_id: group_id}),
    do: Client.impl().triage_worker_binding(group_id)

  @doc "Archive an agent (soft-delete via `archived_at`)."
  @spec archive_agent(Agent.t(), keyword()) :: {:ok, Agent.t()} | {:error, term()}
  def archive_agent(agent, opts \\ [])

  def archive_agent(%Agent{} = agent, opts) do
    result =
      write_canonical(agent, fn locked ->
        with {:ok, current} <- canonical_agent(locked),
             true <- current.role != "router" || {:error, :router_agent},
             {:ok, project, org} <- project_org(Repo.get!(Project, locked.project_id)),
             :ok <- confirm_triage_archive(project, locked.salix_agent_id, opts) do
          audit_canonical_call(current, "agent.archived", opts, fn ->
            with {:ok, record} <-
                   Client.impl().archive_agent_configuration(
                     locked.salix_agent_id,
                     org.salix_tenant_id
                   ),
                 do: {:ok, with_record(locked, record)}
          end)
        end
      end)

    maybe_record_agent_write_failure(result, "agent.archived", agent, %{}, opts)
  end

  defp confirm_triage_archive(project, agent_id, opts) do
    with {:ok, binding} <- triage_worker_binding(project) do
      if binding["worker_agent_id"] == agent_id &&
           Keyword.get(opts, :triage_worker_revision) != binding["revision"],
         do: {:error, :triage_worker_confirmation_required},
         else: :ok
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
          request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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
      "attempted_template_id" => blank_to_nil(attrs["template_id"]),
      "attempted_runtime_kind" => runtime_audit_value(attrs["runtime_config"], "kind"),
      "attempted_runtime_provider" => runtime_audit_value(attrs["runtime_config"], "provider"),
      "attempted_vm_enabled" => runtime_audit_value(attrs["vm"], "enabled"),
      "attempted_vm_provider" => runtime_audit_value(attrs["vm"], "provider"),
      "attempted_runtime_reference_configured" =>
        configured?(runtime_audit_value(attrs["runtime_config"], "device_runtime_id")),
      "attempted_instructions_configured" => configured?(attrs["system_prompt"]),
      "attempted_model_configured" =>
        configured?(attrs["template_id"]) || configured?(attrs["llm_config"]),
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
    opts = Keyword.put_new_lazy(opts, :request_id, &Ecto.UUID.generate/0)

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
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
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
      "template_id" => blank_to_nil(agent.salix["template_id"]),
      "vm_enabled" => runtime_audit_value(agent.salix["vm"], "enabled"),
      "vm_provider" => runtime_audit_value(agent.salix["vm"], "provider"),
      "instructions_configured" => configured?(agent.salix["system_prompt"]),
      "model_configured" => model_configured?(agent),
      "inline_model_configured" => configured?(agent.salix["llm_config"])
    }
  end

  defp agent_create_diff(%Agent{} = agent, runtime_config) do
    agent_config_diff(nil, agent)
    |> maybe_put_runtime_config_diff(nil, runtime_config)
  end

  defp agent_config_diff(nil, %Agent{} = agent) do
    agent
    |> agent_config_snapshot()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, %{"from" => nil, "to" => value}} end)
  end

  defp agent_config_diff(%Agent{} = before, %Agent{} = after_agent) do
    after_snapshot = agent_config_snapshot(after_agent)

    diff =
      before
      |> agent_config_snapshot()
      |> Enum.reject(fn {key, value} -> after_snapshot[key] == value end)
      |> Map.new(fn {key, value} -> {key, %{"from" => value, "to" => after_snapshot[key]}} end)

    if before.salix["runtime_config"] == after_agent.salix["runtime_config"],
      do: diff,
      else:
        maybe_put_runtime_config_diff(
          diff,
          before.salix["runtime_config"],
          after_agent.salix["runtime_config"]
        )
  end

  defp maybe_put_runtime_config_diff(diff, before_config, after_config) do
    case public_runtime_config(after_config) do
      nil ->
        diff

      config ->
        Map.put(diff, "runtime_config", %{
          "from" => public_runtime_config(before_config),
          "to" => config
        })
    end
  end

  defp agent_config_snapshot(%Agent{} = agent) do
    %{
      "name" => agent.salix["name"],
      "purpose" => agent.salix["management_purpose"],
      "role" => agent.role,
      "slot" => agent.slot,
      "status" => Agent.lifecycle(agent),
      "archived_at" => agent.salix["archived_at"],
      "template_id" => blank_to_nil(agent.salix["template_id"]),
      "vm_enabled" => runtime_audit_value(agent.salix["vm"], "enabled"),
      "vm_provider" => runtime_audit_value(agent.salix["vm"], "provider"),
      "instructions_configured" => configured?(agent.salix["system_prompt"]),
      "model_configured" => model_configured?(agent),
      "inline_model_configured" => configured?(agent.salix["llm_config"])
    }
  end

  defp agent_label(%Agent{salix: %{"name" => name}}) when is_binary(name) and name != "", do: name
  defp agent_label(%Agent{salix_agent_id: id}) when is_binary(id) and id != "", do: id
  defp agent_label(%Agent{id: id}), do: id

  defp model_configured?(%Agent{} = agent),
    do: configured?(agent.salix["template_id"]) || configured?(agent.salix["llm_config"])

  defp runtime_audit_value(config, key) when is_map(config), do: Map.get(config, key)
  defp runtime_audit_value(_config, _key), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

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
  # agent's model is its `template_id` (a Salix template-catalog entry); Salix
  # resolves model + provider config live from it (SalixAgent.LlmResolver).
  defp enqueue_config(%Agent{} = agent, runtime_config, _opts) do
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
      |> maybe_put("template_id", agent.salix["template_id"])
      |> maybe_put("runtime_config", runtime_config)
      |> maybe_put("vm", agent.salix["vm"])

    {:ok, _} = Outbox.enqueue("agent", agent.id, "create_owned_agent", %{"attrs" => attrs})

    :ok
  end

  # Reconcile an update to an already-provisioned agent. The control-plane
  # record is create-once, so model/template changes go through `update_agent`.
  defp enqueue_runtime_rebind(
         %Agent{} = agent,
         %Project{} = _project,
         %Organization{} = _org,
         runtime_config,
         opts
       ) do
    write_canonical(
      agent,
      fn canonical ->
        configure_canonical(
          canonical,
          %{"runtime_config" => runtime_config},
          Keyword.put(opts, :audit_action, "agent.runtime_rebound")
        )
        |> maybe_record_agent_write_failure("agent.runtime_rebound", canonical, %{}, opts)
      end
    )
  end

  defp apply_external_target_rebind(
         %Agent{} = agent,
         %Organization{} = org,
         runtime_config,
         expected_binding_revision,
         opts
       ) do
    write_canonical(agent, fn locked ->
      with {:ok, before} <- canonical_agent(locked) do
        audit_canonical_call(before, "agent.runtime_rebound", opts, fn ->
          with {:ok, _} <-
                 Client.impl().rebind_agent_configuration(
                   locked.salix_agent_id,
                   org.salix_tenant_id,
                   Map.delete(runtime_config, "binding_revision"),
                   expected_binding_revision,
                   Ecto.UUID.generate()
                 ),
               do: canonical_agent(locked)
        end)
      end
    end)
    |> case do
      {:error, :binding_conflict} -> {:error, :stale_binding_revision}
      result -> result
    end
  end

  defp pop_runtime_config(attrs, project_id) do
    case Map.pop(attrs, "runtime_config") do
      {nil, attrs} ->
        {{:ok, nil}, attrs}

      {%{"kind" => "internal"}, attrs} ->
        {{:ok, nil}, attrs}

      {%{"kind" => "external"} = config, attrs} ->
        {validate_external_runtime_config(
           project_id,
           Map.put(attrs, "runtime_config", config),
           config
         ), attrs}

      {%{"kind" => kind} = config, attrs}
      when kind in ["connected_runtime", "compute_workload"] ->
        changeset = Agent.changeset(%Agent{}, Map.put(attrs, "runtime_config", config))

        if changeset.valid?,
          do: {{:ok, stringify_nested(config)}, attrs},
          else: {{:error, changeset}, attrs}

      {_config, attrs} ->
        {{:error, runtime_config_changeset(attrs, project_id, "must be an object")}, attrs}
    end
  end

  defp validate_external_runtime_config(project_id, attrs, config) do
    with :ok <- validate_external_runtime_changeset(attrs),
         :ok <- validate_project_external_runtime(attrs, config),
         {:ok, runtime} <- project_runtime_from_config(project_id, config) do
      {:ok, external_runtime_config_from_runtime(runtime)}
    end
  end

  defp validate_external_runtime_changeset(attrs) do
    changeset = Agent.changeset(%Agent{}, attrs)

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp validate_project_external_runtime(attrs, config) do
    expected_id =
      RuntimeIds.device_runtime_id(config["device_id"], config["provider"], config["runtime_id"])

    if config["device_runtime_id"] == expected_id do
      :ok
    else
      {:error,
       runtime_config_changeset(
         attrs,
         attrs["project_id"],
         "device_runtime_id must match device_id/provider/runtime_id"
       )}
    end
  end

  defp project_runtime_from_config(project_id, config) do
    with {:ok, runtimes} <- list_external_runtimes(project_id) do
      case Enum.find(runtimes, &runtime_config_matches?(&1, config)) do
        nil -> {:error, :runtime_not_found}
        runtime -> with :ok <- ensure_bindable_runtime(runtime), do: {:ok, runtime}
      end
    end
  end

  defp runtime_config_matches?(runtime, config) do
    runtime["device_id"] == config["device_id"] and
      runtime["runtime_id"] == config["runtime_id"] and
      runtime["device_runtime_id"] == config["device_runtime_id"] and
      runtime["provider"] == config["provider"]
  end

  defp runtime_config_changeset(attrs, project_id, message, field \\ :runtime_config) do
    %Agent{}
    |> Agent.changeset(Map.put(attrs, "project_id", project_id))
    |> Ecto.Changeset.add_error(field, message)
  end

  defp require_provisioned_agent(%Agent{salix_agent_id: id}) when is_binary(id) and id != "",
    do: :ok

  defp require_provisioned_agent(%Agent{}), do: {:error, :not_provisioned}

  defp require_agent_in_project(%Project{id: project_id}, %Agent{project_id: project_id}),
    do: :ok

  defp require_agent_in_project(%Project{}, %Agent{}), do: {:error, :agent_not_in_project}

  defp require_router_agent(%Agent{role: "router"}), do: :ok
  defp require_router_agent(%Agent{}), do: {:error, :unsupported_agent_role}

  # Do not read the current Salix runtime_config here. BFT rebind is also the
  # repair path when the current agent projection is missing, stale, or broken;
  # the synchronous preflight is the BFT roster worker plus selected project
  # runtime inventory.
  defp require_worker_runtime_rebind(%Agent{role: "worker"}), do: :ok
  defp require_worker_runtime_rebind(%Agent{}), do: {:error, :unsupported_agent_role}

  defp public_runtime_config(config) when is_map(config) do
    config
    |> stringify_nested()
    |> Map.take(@public_external_runtime_config_keys)
  end

  defp public_runtime_config(_config), do: nil

  defp project_runtime_config(project_id, runtime_ref, device_ref) do
    with {:ok, runtimes} <- list_external_runtimes(project_id),
         {:ok, runtime} <- select_project_runtime(runtimes, runtime_ref, device_ref),
         :ok <- ensure_bindable_runtime(runtime) do
      {:ok, external_runtime_config_from_runtime(runtime)}
    end
  end

  defp external_runtime_config_from_runtime(runtime) do
    %{
      "kind" => "external",
      "provider" => runtime["provider"],
      "device_id" => runtime["device_id"],
      "runtime_id" => runtime["runtime_id"],
      "device_runtime_id" => runtime["device_runtime_id"]
    }
    |> put_runtime_config_optional_fields(runtime)
  end

  defp external_target_config(%Project{} = project, target, revision) do
    target = stringify_nested(target)

    case target["kind"] do
      "connected_runtime" -> connected_target_config(project, target, revision)
      "compute_workload" -> compute_target_config(project, target, revision)
      _ -> {:error, :unsupported_runtime_binding}
    end
  end

  defp connected_target_config(%Project{} = project, target, revision) do
    with {:ok, runtime_config} <-
           project_runtime_config(project.id, target["device_runtime_id"], target["device_id"]) do
      {:ok,
       %{
         "kind" => "connected_runtime",
         "provider" => runtime_config["provider"],
         "device_id" => runtime_config["device_id"],
         "runtime_id" => runtime_config["runtime_id"],
         "device_runtime_id" => runtime_config["device_runtime_id"],
         "owner_scope" => %{"type" => "group", "id" => project.salix_group_id},
         "binding_revision" => revision
       }}
    end
  end

  defp compute_target_config(%Project{} = project, target, revision) do
    workload_id = trim(target["workload_id"])
    fence = target["selection_fence"]

    if workload_id == "" or not is_map(fence) do
      {:error, :target_required}
    else
      validate_compute_provider(
        project,
        workload_id,
        fence,
        revision,
        @compute_external_providers
      )
    end
  end

  defp validate_compute_provider(_project, _workload_id, _fence, _revision, []),
    do: {:error, :target_not_found}

  defp validate_compute_provider(project, workload_id, fence, revision, [provider | rest]) do
    with {:ok, _project, org} <- project_org(project) do
      case Client.impl().validate_external_worker_target(
             org.salix_tenant_id,
             "project",
             project.id,
             project.salix_group_id,
             provider,
             workload_id,
             fence
           ) do
        {:ok, item} ->
          item = stringify_nested(item)
          derived_provider = item["provider"]

          if derived_provider == provider do
            {:ok,
             %{
               "kind" => "compute_workload",
               "workload_id" => item["workload_id"],
               "runtime_spec" => %{"provider" => derived_provider},
               "owner_scope" => %{"type" => "project", "id" => project.id},
               "binding_revision" => revision
             }}
          else
            {:error, :provider_mismatch}
          end

        {:error, reason} when reason in [:not_found, :scope_mismatch] ->
          validate_compute_provider(project, workload_id, fence, revision, rest)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp project_external_runtimes(environments) do
    environments
    |> connected_project_devices()
    |> Enum.flat_map(&external_runtimes_for_environment/1)
  end

  defp connected_project_devices(environments) do
    environments
    |> Enum.filter(&project_device_environment?/1)
    |> Enum.group_by(&trim(&1["device_id"]))
    |> Enum.map(fn {_device_id, records} ->
      Enum.max_by(records, &environment_sort_key/1, fn -> nil end)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp project_device_environment?(env) do
    trim(env["device_id"]) != "" and env["status"] == "connected"
  end

  defp external_runtimes_for_environment(env) do
    env
    |> Map.get("device_runtimes", [])
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&external_runtime?/1)
    |> Enum.map(&runtime_entry(env, &1))
  end

  defp external_runtime?(runtime) do
    RuntimeIds.external_runtime_provider?(runtime_value(runtime, "provider")) and
      trim(runtime_value(runtime, "device_runtime_id")) != "" and
      trim(runtime_value(runtime, "runtime_id")) != ""
  end

  defp runtime_entry(env, runtime) do
    %{
      "device_id" => trim(env["device_id"]),
      "device_name" => nonblank(env["name"], env["device_id"]),
      "connector_id" => trim(env["connector_id"]),
      "connector_run_id" => trim(env["connector_run_id"]),
      "runtime_id" => trim(runtime_value(runtime, "runtime_id")),
      "device_runtime_id" => trim(runtime_value(runtime, "device_runtime_id")),
      "provider" => trim(runtime_value(runtime, "provider")),
      "status" => nonblank(runtime_value(runtime, "status"), "unknown"),
      "issue" => runtime_value(runtime, "issue"),
      "updated_at" => runtime_value(runtime, "updated_at"),
      "readiness_valid_until" => runtime_value(runtime, "readiness_valid_until"),
      "model" => runtime_value(runtime, "model"),
      "model_provider" => runtime_value(runtime, "model_provider"),
      "reasoning_effort" => runtime_value(runtime, "reasoning_effort"),
      "version" => runtime_value(runtime, "version"),
      "readiness_checked_at" => runtime_value(runtime, "readiness_checked_at")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp select_project_runtime(runtimes, runtime_ref, device_ref) do
    ref = trim(runtime_ref)
    device_ref = trim(device_ref)

    if ref == "" do
      {:error, :runtime_required}
    else
      runtimes =
        if device_ref == "" do
          runtimes
        else
          Enum.filter(runtimes, fn runtime ->
            device_ref in [
              runtime["device_id"],
              runtime["device_name"],
              runtime["connector_id"],
              runtime["connector_run_id"]
            ]
          end)
        end

      matches =
        Enum.filter(runtimes, fn runtime ->
          ref in [runtime["device_runtime_id"], runtime["runtime_id"]]
        end)

      case matches do
        [runtime] -> {:ok, runtime}
        [] -> {:error, :runtime_not_found}
        _many -> {:error, :runtime_ambiguous}
      end
    end
  end

  defp ensure_bindable_runtime(runtime) do
    if runtime["status"] == "ready", do: :ok, else: {:error, :runtime_unavailable}
  end

  defp put_runtime_config_optional_fields(config, runtime) do
    config
    |> put_runtime_config_optional_field("model", runtime["model"])
    |> put_runtime_config_optional_field("model_provider", runtime["model_provider"])
    |> put_runtime_config_optional_field("reasoning_effort", runtime["reasoning_effort"])
  end

  defp put_runtime_config_optional_field(config, key, value) do
    case trim(value) do
      "" -> config
      trimmed -> Map.put(config, key, trimmed)
    end
  end

  defp environment_sort_key(env) do
    {if(env["status"] == "connected", do: 1, else: 0),
     integer(env["updated_at"] || env["connected_at"])}
  end

  defp runtime_value(runtime, key) when is_map(runtime) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(runtime, key) || (atom_key && Map.get(runtime, atom_key))
  rescue
    ArgumentError -> Map.get(runtime, key)
  end

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> trim(fallback)
      trimmed -> trimmed
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> 0
    end
  end

  defp integer(_value), do: 0

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

    case Application.get_env(:bridge_for_teams_core, :fee_control_observer) do
      observer when is_pid(observer) ->
        send(observer, {:bridge_fee_control_check, result, context})

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
    |> normalize_runtime_config()
    |> normalize_vm_config()
  end

  defp normalize_runtime_config(%{"runtime_config" => config} = attrs) when is_map(config) do
    config =
      config
      |> stringify_nested()
      |> normalize_runtime_config_by_kind()

    Map.put(attrs, "runtime_config", config)
  end

  defp normalize_runtime_config(attrs), do: attrs

  defp normalize_runtime_config_by_kind(%{"kind" => "internal"}), do: %{"kind" => "internal"}
  defp normalize_runtime_config_by_kind(config), do: config

  defp normalize_vm_config(%{"vm" => config} = attrs) when is_map(config) do
    Map.put(attrs, "vm", stringify_nested(config))
  end

  defp normalize_vm_config(attrs), do: attrs

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
