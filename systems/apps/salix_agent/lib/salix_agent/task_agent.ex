defmodule SalixAgent.TaskAgent do
  @moduledoc """
  A Group's Task agent: the Agent whose Session runs a Task of the Group when
  the Task names no Worker. Salix owns it. Products, Routers and people do not
  create, name, configure, bind or archive it. The Group record holds its id
  (`task_agent_id`), next to `default_task_model`.

    * `ensure/2` answers the recorded id. A Group without one gets an internal
      Worker with a fixed id made from the Group id (`id/1`), so concurrent and
      repeated calls make one Agent, and the Group then records it.
    * A product that already ran its Group's Tasks on one Worker (Comma's
      Workspace Worker) gives that Worker as `adopt`. The Group records it
      instead and no Agent is made.
    * A guest (router-only) Tenant has no Task agent.
    * It is not `hidden`: Task code treats it as any Worker (memory
      consultation reads `Control.visible?/1`). Product lists leave it out
      (`SalixAgent.Control.page_agents/3` with `exclude_task_agent: true`).
  """

  alias SalixAgent.Control
  alias SalixStore.{CasRecord, Ids, Keys}

  @field "task_agent_id"
  # A snowflake body is the time since 2010; this one is never generated.
  @body "0000000000000000001"

  @doc "The fixed id of the Task agent that Salix makes for `group_id`."
  @spec id(String.t()) :: String.t()
  def id(group_id), do: Ids.agent_id_prefix_for_group!(group_id) <> @body

  @doc "The Task agent id a Group record holds, or nil."
  @spec of_group(map()) :: String.t() | nil
  def of_group(%{"group_id" => group_id} = group) do
    value = group[@field]
    if Ids.valid_agent_id_for_group?(value, group_id), do: value
  end

  def of_group(_group), do: nil

  @doc "The Group's Task agent id, or nil when it has none yet."
  @spec get(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         {:ok, group} <- CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, of_group(group)}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  The Group's Task agent: the recorded one, else the Worker `adopt` answers,
  else one Salix makes. `scope` carries `tenant_id` and `group_id`.
  """
  @spec ensure(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%{tenant_id: tenant_id, group_id: group_id}, opts \\ []) do
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, %{"tenant_id" => ^tenant_id} = group} <- CasRecord.get(Keys.ctl_group(group_id)) do
      case of_group(group) do
        nil -> first(tenant_id, group_id, opts[:adopt])
        id -> {:ok, id}
      end
    else
      false -> {:error, :not_found}
      {:ok, _other_tenant} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Record `agent_id`, a Worker of the Group, as its Task agent while the Group
  has none. Answers the Group's Task agent afterwards.
  """
  @spec adopt(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def adopt(tenant_id, group_id, agent_id) do
    with :ok <- not_guest(tenant_id),
         :ok <- usable(group_id, agent_id),
         do: put_new(tenant_id, group_id, agent_id)
  end

  # A racing create of the fixed id can find it taken before the winner's
  # record is readable; the Group's lock makes the others wait for it. Nodes
  # that do not share the lock still converge on the one id, and a loser's
  # `:unavailable` is retryable.
  defp first(tenant_id, group_id, nil) do
    with :ok <- not_guest(tenant_id) do
      SystemsRuntime.Proc.global_trans({{__MODULE__, group_id}, SystemsRuntime.Proc.self()}, fn ->
        with {:ok, id} <- create(tenant_id, group_id),
             do: put_new(tenant_id, group_id, id)
      end)
    end
  end

  defp first(tenant_id, group_id, adopt) when is_function(adopt, 0) do
    with :ok <- not_guest(tenant_id),
         {:ok, id} <- adopt.(),
         do: adopt(tenant_id, group_id, id)
  end

  defp not_guest(tenant_id) do
    if SalixStore.TenantProfiles.router_only?(tenant_id),
      do: {:error, :guest_group},
      else: :ok
  end

  # A preallocated create of the fixed id answers the stored Agent when it
  # exists.
  defp create(tenant_id, group_id) do
    attrs = %{
      "group_id" => group_id,
      "role" => "worker",
      "name" => "Task agent",
      "management_purpose" => "Run this Group's Tasks",
      "management_creation_audit" => %{"kind" => "task_agent"},
      "runtime_config" => %{"kind" => "internal"}
    }

    with {:ok, %{"agent_id" => id}} <-
           Control.create_owned_preallocated(attrs, tenant_id, id(group_id)),
         do: {:ok, id}
  end

  defp usable(group_id, agent_id) do
    with true <- Ids.valid_agent_id_for_group?(agent_id, group_id),
         {:ok, %{"group_id" => ^group_id, "role" => "worker"} = record} <-
           Control.get_record(agent_id),
         true <- Control.visible?(record) do
      :ok
    else
      {:error, reason} when reason not in [:not_found] -> {:error, reason}
      _ -> {:error, {:unavailable, :task_agent}}
    end
  end

  defp put_new(tenant_id, group_id, agent_id) do
    with {:ok, group} <-
           CasRecord.update(
             Keys.ctl_group(group_id),
             fn
               %{"tenant_id" => ^tenant_id} = group ->
                 if of_group(group),
                   do: {:unchanged, group},
                   else: Map.put(group, @field, agent_id)

               _other_tenant ->
                 {:error, :not_found}
             end,
             create: false
           ) do
      SalixStore.ReadScope.invalidate({:record, Keys.ctl_group(group_id)})
      {:ok, of_group(group)}
    end
  end
end
