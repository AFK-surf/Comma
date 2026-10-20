defmodule CommaWeb.AgentManagement do
  @moduledoc """
  Comma composition of the agent-management ports.

  New Workers follow the platform model, or take the catalog model the Router
  chose. Internal Workers take the Workspace's VM settings. Existing Workers
  keep their choice. A Task's Worker Session can take its own catalog model, or
  a runtime model when the Task runs on a station.
  """
  @behaviour SalixAgent.AgentManagement.Ports

  defdelegate project_id(scope), to: Salix.Bindings.AgentManagement

  # Only a BridgeForTeams org has a default Task model above its Groups; a
  # Workspace's Group has its own (Settings > Models) or none.
  defdelegate default_task_model(scope), to: Salix.Bindings.AgentManagement

  def internal_worker(scope, model, create) do
    case workspace_for(scope) do
      {:ok, _workspace} -> workspace_worker(scope, model, create)
      :other_product -> Salix.Bindings.AgentManagement.internal_worker(scope, model, create)
      error -> error
    end
  end

  def session_model(scope, choice) do
    case workspace_for(scope) do
      # An internal Session runs a catalog choice or the platform model; a
      # Session on a station runs a runtime choice.
      {:ok, _workspace} ->
        kinds =
          if scope[:runs_on],
            do: ["runtime"],
            else: ["catalog", "platform"]

        if choice["kind"] in kinds,
          do: SalixAgent.ModelChoice.choose(choice, scope.tenant_id),
          else: {:error, :invalid_model_configuration}

      :other_product ->
        Salix.Bindings.AgentManagement.session_model(scope, choice)

      error ->
        error
    end
  end

  # A Comma Workspace has no model governance: its Router may choose every model.
  def model_filter(scope) do
    case workspace_for(scope) do
      {:ok, _workspace} -> SalixAgent.AgentManagement.Ports.no_model_filter()
      :other_product -> Salix.Bindings.AgentManagement.model_filter(scope)
      error -> error
    end
  end

  # A Comma Workspace's Tasks run on its Group's Task agent.
  def task_worker(scope) do
    case workspace_for(scope) do
      {:ok, _workspace} -> SalixAgent.TaskAgent.ensure(scope)
      :other_product -> Salix.Bindings.AgentManagement.task_worker(scope)
      error -> error
    end
  end

  @doc """
  The Agent that runs a Task Comma starts for a Workspace, such as a mail
  draft or a desktop meeting recording: its Group's Task agent
  (`SalixAgent.TaskAgent`).
  """
  def workspace_task_agent(workspace) do
    SalixAgent.TaskAgent.ensure(%{
      tenant_id: workspace["salix_tenant_id"],
      group_id: workspace["default_group_id"]
    })
  end

  def user_context(scope) do
    case workspace_for(scope) do
      {:ok, workspace} ->
        {:ok, Comma.Accounts.agent_context(workspace["owner_user_id"], workspace["id"])}

      :other_product ->
        Salix.Bindings.AgentManagement.user_context(scope)

      error ->
        error
    end
  end

  defp workspace_for(scope) do
    with {:ok, group} <- Salix.Control.Groups.get(scope.group_id, scope.tenant_id) do
      case group["billing_owner"] do
        %{"surface" => "comma", "product_owner_type" => "workspace", "product_owner_id" => id} ->
          workspace(id, scope)

        _ ->
          :other_product
      end
    end
  end

  defp workspace(id, scope) do
    with {:ok, workspace} <- Comma.Workspaces.get(id),
         true <-
           workspace["salix_tenant_id"] == scope.tenant_id and
             workspace["default_group_id"] == scope.group_id do
      {:ok, workspace}
    else
      false -> {:error, :worker_default_unavailable}
      {:error, :not_found} -> {:error, :worker_default_unavailable}
    end
  end

  defp workspace_worker(_scope, nil, create), do: create.(%{})

  # The settings path's check (`SalixAgent.ModelChoice.choose/2`): the effort
  # must be one of the model's efforts and a pinned Profile must serve the
  # model. The Worker stores the choice itself.
  defp workspace_worker(scope, %{"kind" => "catalog"} = choice, create) do
    with {:ok, model} <- SalixAgent.ModelChoice.choose(choice, scope.tenant_id) do
      create.(%{"model" => model})
    end
  end

  defp workspace_worker(_scope, _model, _create), do: {:error, :invalid_model_configuration}
end
