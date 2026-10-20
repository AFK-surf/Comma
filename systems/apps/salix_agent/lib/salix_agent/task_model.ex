defmodule SalixAgent.TaskModel do
  @moduledoc """
  A Group's default Task model: the Model Choice (`SalixAgent.ModelChoice`) a
  Task of the Group runs when it names no model and no station. It is a value
  on the Group record (`default_task_model`), which the Group's product sets
  (Comma Settings > Models, the BridgeForTeams swarm settings).

    * The value is a catalog choice, or the platform model of the `worker`
      tier (`%{"kind" => "platform", "tier" => "worker"}`, Comma's built-in
      model).
    * A Group that has set none, or cleared it, leaves a Task's model to its
      Worker: the platform model, unless the Worker has its own (a
      BridgeForTeams Worker configured in the dashboard).

  The choice is checked when it is set, as an Agent's `model` is; a catalog
  model that later leaves the catalog fails the Task's rounds, not its
  creation.
  """

  alias SalixAgent.ModelChoice
  alias SalixStore.{CasRecord, Ids, Keys}

  @field "default_task_model"
  @platform %{"kind" => "platform", "tier" => "worker"}

  @doc "The platform model as a default Task model."
  def platform, do: @platform

  @doc "The Group's default Task model, or nil when it has set none."
  @spec get(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         {:ok, group} <- CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, of_group(group)}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc "The default Task model a Group record holds, or nil."
  @spec of_group(map()) :: map() | nil
  def of_group(group) when is_map(group) do
    value = group[@field]
    if valid?(value), do: value
  end

  @doc "Whether `value` is a stored default Task model."
  def valid?(@platform), do: true
  def valid?(%{"kind" => "catalog"} = value), do: ModelChoice.value?(value)
  def valid?(_value), do: false

  @doc """
  Check a requested default Task model and answer the value to store: a
  catalog choice as `agent.create_worker` takes it, or the platform model.
  """
  @spec choose(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def choose(@platform, _tenant_id), do: {:ok, @platform}

  def choose(%{"kind" => "catalog"} = choice, tenant_id),
    do: ModelChoice.choose(choice, tenant_id)

  def choose(_choice, _tenant_id), do: {:error, :invalid_model_configuration}

  @doc """
  Check `choice` and store it as the default Task model of the Group of
  `tenant_id`. `nil` clears it: the Group has set none again.
  """
  @spec put(String.t(), String.t(), term()) :: {:ok, map() | nil} | {:error, term()}
  def put(tenant_id, group_id, nil), do: write(tenant_id, group_id, fn _current -> nil end)

  def put(tenant_id, group_id, choice) do
    with {:ok, value} <- choose(choice, tenant_id),
         do: write(tenant_id, group_id, fn _current -> value end)
  end

  @doc """
  Store `value`, already a stored choice, only while the Group has set none:
  the first default a release derives from earlier settings. Answers the
  Group's default afterwards.
  """
  @spec put_new(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_new(tenant_id, group_id, value) do
    if valid?(value),
      do: write(tenant_id, group_id, fn current -> current || value end),
      else: {:error, :invalid_model_configuration}
  end

  defp write(tenant_id, group_id, next) do
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, group} <-
           CasRecord.update(
             Keys.ctl_group(group_id),
             fn
               %{"tenant_id" => ^tenant_id} = group ->
                 current = of_group(group)

                 case next.(current) do
                   ^current -> {:unchanged, group}
                   nil -> Map.delete(group, @field)
                   value -> Map.put(group, @field, value)
                 end

               _other_tenant ->
                 {:error, :not_found}
             end,
             create: false
           ) do
      SalixStore.ReadScope.invalidate({:record, Keys.ctl_group(group_id)})
      {:ok, of_group(group)}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end
end
