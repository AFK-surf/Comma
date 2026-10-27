defmodule SalixStore.CodingSandboxes do
  @moduledoc """
  The sandbox of a coding session (a Task that runs `{kind: sandbox}`): one
  Compute Workload of kind `coding_sandbox` on the `l4es` provider.

  Each coding Task owns one Compute Environment (`owner_type` `task`, its
  conversation id as owner). The Environment holds the provider binding (the
  Comma Workspace's L4ES workspace), one Allocation per sandbox run and the
  one Workload. The Environment's generation counts the runs the Task has
  had: starting its sandbox again advances it, releases the old Allocation and
  moves the Workload to a new one, so the old station's connect credential,
  which names the generation, stops working (`WorkloadCredential.verify_connect/1`).
  The L4ES sandbox (`disk`) usually stays the same across runs: L4ES keeps
  its data disk while it is stopped.

  The Workload's `spec` holds what the lifecycle owner (`SalixWeb.CodingSandboxes`)
  needs: the Task, the Group, the repository, the device the station
  registers as, and the sandbox's state (`state`): `starting`, `ready`,
  `stopped` (Salix stopped it while idle), `lost` (it ended without Salix),
  `failed` or `ended` (the Task ended). The device id stays the same for every
  sandbox of the Task, so the Task's `runs_on` stays valid.

  Writes lock the Workload row. `claim_due/2` claims rows with `FOR UPDATE
  SKIP LOCKED` and a lease, so the owner may run on every node.
  """

  import Ecto.Query

  alias SalixStore.Compute.{Allocation, Environment, Pool, ProviderBinding, Workload}
  alias SalixStore.Repo

  @kind "coding_sandbox"
  @provider "l4es"
  @states ~w(starting ready stopped lost failed ended)

  def kind, do: @kind
  def provider, do: @provider
  def states, do: @states

  @doc "The device a coding Task's stations register as, the same for every sandbox."
  def device_id(conversation_id), do: "dev-sbx-" <> conversation_id
  def connector_id(conversation_id), do: "conn-sbx-" <> conversation_id
  def transport_id(conversation_id), do: "sbx-" <> conversation_id

  @doc "Whether `device_id` is a coding sandbox's device."
  def device?(device_id) when is_binary(device_id), do: String.starts_with?(device_id, "dev-sbx-")
  def device?(_), do: false

  @doc """
  Creates the Environment, provider binding, first Allocation and the
  Workload of coding Task `conversation_id`, in state `starting`. Idempotent:
  a Task that has one answers it.

  `attrs`: `tenant_id`, `group_id`, `conversation_id`, `workspace` (the L4ES
  workspace reference, `comma:<id>`) and optional `repo` (a map; a coding
  Task's repository), `size`, `account_id` and `requester`.
  """
  def create(%{tenant_id: tenant, group_id: group, conversation_id: conversation} = attrs)
      when is_binary(tenant) and is_binary(group) and is_binary(conversation) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "coding-sandbox:" <> conversation
      ])

      case environment(tenant, conversation) do
        %Environment{} = env ->
          workload_of!(env)

        nil ->
          pool = ensure_pool!(tenant)
          now = SystemsClock.utc_now()
          env_id = new_id("env")

          insert!(Environment, %{
            id: env_id,
            tenant_id: tenant,
            owner_type: "task",
            owner_id: conversation,
            pool_id: pool.id,
            desired_state: "ready",
            observed_state: "pending",
            generation: 1,
            revision: 1,
            retention: %{"mode" => "delete"},
            inventory_watermark: 0,
            created_at: now,
            updated_at: now
          })

          binding =
            insert!(ProviderBinding, %{
              id: new_id("binding"),
              pool_id: pool.id,
              environment_id: env_id,
              provider: @provider,
              provider_ref: Map.fetch!(attrs, :workspace),
              status: "available",
              generation: 1,
              revision: 1,
              observation: %{},
              updated_at: now
            })

          allocation = insert_allocation!(env_id, binding.id, 1, now)

          insert!(Workload, %{
            id: new_id("workload"),
            environment_id: env_id,
            allocation_id: allocation.id,
            kind: @kind,
            owner_ref: %{"kind" => "task", "group_id" => group, "conversation_id" => conversation},
            spec: %{
              "tenant_id" => tenant,
              "group_id" => group,
              "conversation_id" => conversation,
              "device_id" => device_id(conversation),
              "connector_id" => connector_id(conversation),
              "transport_id" => transport_id(conversation),
              "workspace" => attrs.workspace,
              "repo" => Map.get(attrs, :repo),
              "size" => Map.get(attrs, :size),
              "account_id" => Map.get(attrs, :account_id),
              "requester" => Map.get(attrs, :requester),
              # What its station is invited with once it connects.
              "agent_id" => Map.get(attrs, :agent_id),
              "start" => Map.get(attrs, :start),
              "state" => "starting",
              "state_at" => DateTime.to_iso8601(now),
              "next_check_at" => DateTime.to_iso8601(now),
              "invited" => false
            },
            capability_requirements: [],
            desired_state: "ready",
            observed_state: "pending",
            generation: 1,
            revision: 1,
            created_at: now,
            updated_at: now
          })
      end
    end)
  end

  @doc "The Workload of coding Task `conversation_id`, if it has one."
  def get_by_conversation(tenant, conversation) do
    case environment(tenant, conversation) do
      %Environment{} = env -> {:ok, workload_of!(env)}
      nil -> {:error, :not_found}
    end
  end

  @doc "The Workloads of those of Tasks `conversations` that have one, by Task, in one read."
  def get_by_conversations(tenant, conversations) when is_list(conversations) do
    from(w in Workload,
      join: e in Environment,
      on: e.id == w.environment_id,
      where:
        e.tenant_id == ^tenant and e.owner_type == "task" and e.owner_id in ^conversations and
          w.kind == @kind,
      select: {e.owner_id, w}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The Workload whose stations register as `device_id`."
  def get_by_device(tenant, device_id) do
    case device_id do
      "dev-sbx-" <> conversation -> get_by_conversation(tenant, conversation)
      _ -> {:error, :not_found}
    end
  end

  def get(id) when is_binary(id) do
    case Repo.get(Workload, id) do
      %Workload{kind: @kind} = w -> {:ok, w}
      _ -> {:error, :not_found}
    end
  end

  @doc "The Workload's current generation and its Environment."
  def environment_of(%Workload{environment_id: id}), do: Repo.get(Environment, id)

  @doc """
  Changes the Workload under its row lock. `fun` gets the locked Workload
  and answers `{:ok, spec}` (the new spec), `{:ok, spec, observed_state}` or
  `{:error, reason}`, which leaves it unchanged.
  """
  def update(id, fun) when is_binary(id) and is_function(fun, 1) do
    Repo.transaction(fn ->
      workload = lock!(id)

      case fun.(workload) do
        {:ok, spec} -> write!(workload, spec, observed(spec, workload))
        {:ok, spec, observed} -> write!(workload, spec, observed)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Replaces the Workload's sandbox: advances the Environment's generation,
  releases the current Allocation and moves the Workload to a new one, in
  state `starting`, with the spec changes `changes`. The old sandbox's
  connect credential stops working at once.
  """
  def advance(id, changes \\ %{}) when is_binary(id) and is_map(changes) do
    Repo.transaction(fn ->
      workload = lock!(id)

      if workload.spec["state"] not in ~w(stopped lost failed ended) or
           List.wrap(workload.spec["leftover"]) != [],
         do: Repo.rollback(:carrier_not_stopped)

      env =
        Repo.one!(
          from(e in Environment, where: e.id == ^workload.environment_id, lock: "FOR UPDATE")
        )

      old = Repo.get!(Allocation, workload.allocation_id)
      now = SystemsClock.utc_now()
      generation = env.generation + 1

      {1, _} =
        Repo.update_all(from(e in Environment, where: e.id == ^env.id),
          set: [generation: generation, updated_at: now],
          inc: [revision: 1]
        )

      {1, _} =
        Repo.update_all(from(a in Allocation, where: a.id == ^old.id),
          set: [status: "released", updated_at: now],
          inc: [revision: 1]
        )

      allocation = insert_allocation!(env.id, old.provider_binding_id, generation, now)

      spec =
        workload.spec
        |> Map.merge(changes)
        |> Map.merge(%{
          "state" => "starting",
          "state_at" => DateTime.to_iso8601(now),
          "sandbox" => nil,
          "idle" => nil,
          "reason" => nil
        })

      {1, _} =
        Repo.update_all(from(w in Workload, where: w.id == ^workload.id),
          set: [
            allocation_id: allocation.id,
            generation: generation,
            spec: spec,
            desired_state: "ready",
            observed_state: "pending",
            updated_at: now
          ],
          inc: [revision: 1]
        )

      Repo.get!(Workload, workload.id)
    end)
  end

  @doc """
  Claims at most `limit` Workloads whose `next_check_at` has passed: moves
  their next check `lease_ms` later, so no other node takes them meanwhile,
  and answers them. The caller then checks each and writes with `update/2`.
  """
  def claim_due(limit, lease_ms) when is_integer(limit) and limit > 0 do
    now = SystemsClock.utc_now()
    lease = now |> DateTime.add(lease_ms, :millisecond) |> DateTime.to_iso8601()
    now_iso = DateTime.to_iso8601(now)

    Repo.transaction(fn ->
      from(w in Workload,
        where:
          w.kind == @kind and
            fragment("?->>'next_check_at' <= ?", w.spec, ^now_iso),
        order_by: [asc: fragment("?->>'next_check_at'", w.spec)],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()
      |> Enum.map(fn workload ->
        write!(workload, Map.put(workload.spec, "next_check_at", lease), workload.observed_state)
      end)
    end)
  end

  @doc "How many of the Group's coding Tasks have a sandbox now (not stopped or ended)."
  def live_count(tenant, group) do
    from(w in Workload,
      join: e in Environment,
      on: e.id == w.environment_id,
      where:
        e.tenant_id == ^tenant and e.owner_type == "task" and w.kind == @kind and
          fragment("?->>'group_id' = ?", w.spec, ^group) and
          fragment("?->>'state' IN ('starting', 'ready')", w.spec),
      select: count(w.id)
    )
    |> Repo.one()
  end

  @doc "The sandbox state as Compute's observed state."
  def observed_state("starting"), do: "pending"
  def observed_state("ready"), do: "ready"
  def observed_state("failed"), do: "failed"
  def observed_state(_), do: "stopped"

  defp observed(spec, workload) do
    case spec["state"] do
      state when state in @states -> observed_state(state)
      _ -> workload.observed_state
    end
  end

  defp write!(workload, spec, observed) do
    desired = if spec["state"] in ~w(stopped lost failed ended), do: "stopped", else: "ready"

    {1, _} =
      Repo.update_all(from(w in Workload, where: w.id == ^workload.id),
        set: [
          spec: spec,
          observed_state: observed,
          desired_state: desired,
          updated_at: SystemsClock.utc_now()
        ],
        inc: [revision: 1]
      )

    Repo.get!(Workload, workload.id)
  end

  defp lock!(id) do
    case Repo.one(from(w in Workload, where: w.id == ^id and w.kind == @kind, lock: "FOR UPDATE")) do
      %Workload{} = w -> w
      nil -> Repo.rollback(:not_found)
    end
  end

  defp environment(tenant, conversation) do
    Repo.one(
      from(e in Environment,
        where: e.tenant_id == ^tenant and e.owner_type == "task" and e.owner_id == ^conversation
      )
    )
  end

  defp workload_of!(%Environment{id: id}) do
    Repo.one!(from(w in Workload, where: w.environment_id == ^id and w.kind == @kind))
  end

  # One Pool per tenant for its coding sandboxes, made on first use.
  defp ensure_pool!(tenant) do
    id = "pool_coding_" <> tenant

    case Repo.get(Pool, id) do
      %Pool{} = pool ->
        pool

      nil ->
        now = SystemsClock.utc_now()

        Repo.insert_all(
          Pool,
          [
            %{
              id: id,
              tenant_id: tenant,
              name: "Coding sandboxes",
              region: "auto",
              provider_policy: %{"providers" => [@provider]},
              capabilities: [],
              capacity: %{},
              quota: %{},
              status: "active",
              revision: 1,
              created_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:id]
        )

        Repo.get!(Pool, id)
    end
  end

  defp insert_allocation!(env_id, binding_id, generation, now) do
    insert!(Allocation, %{
      id: new_id("allocation"),
      environment_id: env_id,
      provider_binding_id: binding_id,
      status: "allocating",
      operation_outcome: "pending",
      generation: generation,
      provider_observation: %{},
      revision: 1,
      created_at: now,
      updated_at: now
    })
  end

  defp insert!(schema, row) do
    {1, _} = Repo.insert_all(schema, [row])
    Repo.get!(schema, row.id)
  end

  defp new_id(prefix), do: prefix <> "_" <> SystemsRuntime.Proc.uuid()
end
