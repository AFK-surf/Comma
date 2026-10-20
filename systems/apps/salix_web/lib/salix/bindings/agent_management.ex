defmodule Salix.Bindings.AgentManagement do
  @moduledoc false
  @behaviour SalixAgent.AgentManagement.Ports
  alias Salix.Control.Groups

  def project_id(scope) do
    with {:ok, group} <- Groups.get(scope.group_id, scope.tenant_id) do
      case group["billing_owner"] do
        %{"surface" => "bridge", "project_id" => id} when is_binary(id) -> {:ok, id}
        _ -> {:error, :target_not_found}
      end
    end
  end

  # BridgeForTeams answers the org's model governance; naming the module as a
  # literal atom keeps Salix free of a runtime dependency on it.
  @bft_models :"Elixir.BridgeForTeams.Models"

  # A BridgeForTeams Worker takes the org default, or the catalog model the
  # Router chose when the org allows it. The Worker stores the choice itself.
  def internal_worker(scope, model, create) do
    with {:ok, choice} <- org_choice(scope, model),
         {:ok, attrs} <- worker_attrs(choice, scope.tenant_id),
         do: create.(attrs)
  end

  defp worker_attrs(nil, _tenant_id), do: {:ok, %{}}

  defp worker_attrs(choice, tenant_id) do
    with {:ok, model} <- SalixAgent.ModelChoice.choose(choice, tenant_id),
         do: {:ok, %{"model" => model}}
  end

  # A group outside BridgeForTeams, or a node without it, keeps the platform
  # model and takes no Router choice.
  defp org_choice(scope, model) do
    with {:ok, project_id} <- project_id(scope),
         true <- SystemsRuntime.Proc.ensure_loaded?(@bft_models) do
      @bft_models.router_choice(project_id, model)
    else
      _no_org when is_nil(model) -> {:ok, nil}
      _no_org -> {:error, :model_selection_unsupported}
    end
  end

  def user_context(_scope), do: {:ok, SalixAgent.AgentManagement.Ports.no_user_context()}

  # A BridgeForTeams Task's Worker Session may take its own model: a catalog
  # or platform model inside Salix, or a model of the station's runtime when
  # the Task runs on a station (a Worker bound to one, or a Task that names one).
  # A catalog model must be one the org allows.
  def session_model(scope, choice) do
    kinds = if scope[:runs_on], do: ["runtime"], else: ["catalog", "platform"]

    with true <- choice["kind"] in kinds,
         {:ok, choice} <- session_choice(scope, choice) do
      SalixAgent.ModelChoice.choose(choice, scope.tenant_id)
    else
      false -> {:error, :invalid_model_configuration}
      error -> error
    end
  end

  defp session_choice(scope, %{"kind" => "catalog"} = choice), do: org_choice(scope, choice)
  defp session_choice(_scope, choice), do: {:ok, choice}

  # A BridgeForTeams Router lists only the models the org lets it choose,
  # checked as `org_choice/2` checks them. Other groups list every model.
  def model_filter(scope) do
    with {:ok, project_id} <- project_id(scope),
         true <- SystemsRuntime.Proc.ensure_loaded?(@bft_models) do
      @bft_models.router_model_filter(project_id)
    else
      {:error, :target_not_found} -> SalixAgent.AgentManagement.Ports.no_model_filter()
      false -> SalixAgent.AgentManagement.Ports.no_model_filter()
      error -> error
    end
  end

  # A BridgeForTeams swarm without its own default Task model runs its org's
  # default Task model. Other groups have no product default.
  def default_task_model(scope) do
    with {:ok, project_id} <- project_id(scope),
         true <-
           SystemsRuntime.Proc.ensure_loaded?(@bft_models) and
             function_exported?(@bft_models, :default_task_model, 1) do
      @bft_models.default_task_model(project_id)
    else
      {:error, :target_not_found} -> {:ok, nil}
      false -> {:ok, nil}
      error -> error
    end
  end

  # A Task that names no Worker runs on the Group's Task agent.
  def task_worker(scope), do: SalixAgent.TaskAgent.ensure(scope)
end
