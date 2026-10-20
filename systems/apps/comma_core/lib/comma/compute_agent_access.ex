defmodule Comma.ComputeAgentAccess do
  @moduledoc "Workspace membership authorizes shared Shell use without per-Agent grants."
  @behaviour SalixAgent.ComputeAccess
  import Ecto.Query
  alias SalixStore.{Compute, Repo}

  @page_size 20

  @impl true
  def list(ctx, args) do
    cursor = Map.get(args, "after_id", "")

    with true <- is_binary(cursor) and byte_size(cursor) <= 128,
         {:ok, scope} <- scope(ctx) do
      rows =
        Repo.all(
          from([w, e] in shared_query(scope),
            where: w.id > ^cursor,
            order_by: w.id,
            limit: ^(@page_size + 1),
            select: {w, e}
          )
        )

      page = Enum.take(rows, @page_size)

      {:ok,
       %{
         "workloads" => Enum.map(page, &public/1),
         "next_cursor" => if(length(rows) > @page_size, do: elem(List.last(page), 0).id)
       }}
    else
      false -> {:error, :invalid_cursor}
      {:error, _} = error -> error
    end
  end

  @impl true
  def authorize(ctx, id, permission) when permission in ["runtime", "workspace"] do
    with {:ok, scope} <- scope(ctx),
         {workload, _} <-
           Repo.one(from([w, e] in shared_query(scope), where: w.id == ^id, select: {w, e})) do
      {:ok, workload}
    else
      nil -> {:error, :workload_not_available}
      {:error, _} = error -> error
    end
  end

  def authorize(_, _, _), do: {:error, :compute_grant_required}

  defp scope(%{agent_id: agent_id, tenant_id: tenant, group_id: group}) do
    with {:ok, agent} <- SalixAgent.Control.get(agent_id, tenant),
         true <- agent["group_id"] == group,
         %Comma.Data.Workspace{} = workspace <-
           Comma.Repo.get_by(Comma.Data.Workspace, salix_group_id: group),
         true <- workspace.salix_tenant_id == tenant and workspace.status == "active" do
      {:ok, %{tenant: tenant, workspace: workspace.id}}
    else
      _ -> {:error, :compute_workspace_unavailable}
    end
  end

  defp scope(_), do: {:error, :compute_workspace_unavailable}

  # Shared Shells differ from the private carriers of external Agent Sessions.
  # New shared runtime kinds must define their capabilities here before admission.
  defp shared_query(scope) do
    from(w in Compute.Workload,
      join: e in Compute.Environment,
      on: e.id == w.environment_id,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id,
      where: a.environment_id == e.id and a.generation == e.generation,
      where:
        e.tenant_id == ^scope.tenant and e.owner_type == "project" and
          e.owner_id == ^scope.workspace and e.desired_state == "ready" and
          w.kind == "shell" and w.desired_state == "ready" and is_nil(w.deletion)
    )
  end

  defp public({w, e}) do
    spec = w.spec || %{}

    %{
      "workload_id" => w.id,
      "name" => w.name,
      "kind" => w.kind,
      "template" => w.template_key,
      "status" => w.observed_state,
      "environment_status" => e.observed_state,
      "capabilities" => w.capability_requirements || [],
      "egress_mode" => spec["egress_mode"],
      "resources" => Map.take(spec["resources"] || %{}, ["pid_max", "writable_quota_bytes"])
    }
  end
end
