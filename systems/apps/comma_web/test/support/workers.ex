defmodule CommaWeb.TestWorkers do
  @moduledoc false

  import Ecto.Query

  @doc """
  Give a fixture Workspace the Worker that Workspaces created before the
  Router created Workers still have: their stored default Worker, which
  migration `20261019230001_adopt_group_task_agents` made their Group's Task
  agent. New Workspaces start without one; tests of that path must not call
  this. `adopt: false` leaves the Worker as it was before that migration.
  """
  def with_default_worker!(workspace, opts \\ [])

  def with_default_worker!(%{"default_worker_agent_id" => id} = workspace, _opts)
      when is_binary(id),
      do: workspace

  def with_default_worker!(workspace, opts) do
    :ok = CommaWeb.SalixClient.provision_workspace_scope(workspace)
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    id = SalixStore.Ids.new_agent_id(group_id)

    {:ok, _worker} =
      SalixAgent.Control.create_preallocated(
        %{
          "group_id" => group_id,
          "name" => workspace["name"] <> " Worker",
          "role" => "worker",
          "purpose" => "comma_workspace_default_worker"
        },
        tenant_id,
        id
      )

    if Keyword.get(opts, :adopt, true),
      do: {:ok, ^id} = SalixAgent.TaskAgent.adopt(tenant_id, group_id, id)

    {1, _} =
      Comma.Repo.update_all(
        from(w in Comma.Data.Workspace, where: w.id == ^workspace["id"]),
        set: [salix_worker_agent_id: id]
      )

    Map.put(workspace, "default_worker_agent_id", id)
  end
end
