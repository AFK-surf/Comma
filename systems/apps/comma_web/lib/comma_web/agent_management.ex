defmodule CommaWeb.AgentManagement do
  @moduledoc """
  Comma composition of the agent-management ports.

  New Workers copy the tenant creation choice. Existing Workers keep their choice.
  """
  @behaviour SalixAgent.AgentManagement.Ports

  defdelegate project_id(scope), to: Salix.Bindings.AgentManagement
  defdelegate connected_target(id, scope), to: Salix.Bindings.AgentManagement
  defdelegate page_targets(caller, args), to: Salix.Bindings.AgentManagement

  def worker_template(scope) do
    with {:ok, group} <- Salix.Control.Groups.get(scope.group_id, scope.tenant_id) do
      case group["billing_owner"] do
        %{"surface" => "comma", "product_owner_type" => "workspace", "product_owner_id" => id} ->
          workspace_template(id, scope)

        _ ->
          Salix.Bindings.AgentManagement.worker_template(scope)
      end
    end
  end

  defp workspace_template(id, scope) do
    with {:ok, workspace} <- Comma.Workspaces.get(id),
         true <-
           workspace["salix_tenant_id"] == scope.tenant_id and
             workspace["default_group_id"] == scope.group_id,
         {:ok, template_id} <-
           SalixAgent.AgentDefaults.creation_template("worker", scope.tenant_id) do
      {:ok, template_id}
    else
      false -> {:error, :worker_default_unavailable}
      {:error, :not_found} -> {:error, :worker_default_unavailable}
      {:error, :agent_template_unresolved} -> {:error, :worker_default_unavailable}
      {:error, _reason} = error -> error
    end
  end
end
