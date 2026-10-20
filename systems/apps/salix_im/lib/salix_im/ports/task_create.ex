defmodule SalixIM.Ports.TaskCreate do
  @moduledoc """
  Outbound port for the durable Task-conversation create primitive.

  SalixIM owns command preparation and authorization. The configured
  application binding crosses the application boundary only to reach the
  Schedule-aware canonical Conversation owner.
  """

  @callback create_task_conversation(
              group_id :: String.t(),
              delegator_agent_id :: String.t(),
              target_agent_id :: String.t(),
              attrs :: map()
            ) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Check the Router's model choice for the Task's Worker Session and answer the
  value that Session stores. `scope` carries `tenant_id`, `group_id` and
  `runs_on`, the resolved place the Task runs (nil inside Salix).
  """
  @callback session_model(scope :: map(), choice :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Check where the Router asked the Task to run and answer the value its Worker
  Participant stores: `%{"kind" => "station" | "cloud_vm", "device_id" => id}`.
  `scope` carries `tenant_id`, `group_id`, the Worker's `agent_id` and `loop`,
  true for a Loop Task (`SalixIM.TaskLoop`): its Loop must run while every app
  is closed, so a person's own computer is refused for it
  (`:personal_station_for_loop`).
  """
  @callback runs_on(scope :: map(), request :: map()) :: {:ok, map()} | {:error, term()}
  @doc """
  The Worker a Task takes when the Router names none. `scope` carries
  `tenant_id` and `group_id`.
  """
  @callback task_worker(scope :: map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  The product's default Task model, for a Group that has set none of its own
  (`SalixAgent.TaskModel`): a stored Model Choice, or nil when the product has
  none (a BridgeForTeams org's default Task model). `scope` carries
  `tenant_id` and `group_id`.
  """
  @callback default_task_model(scope :: map()) :: {:ok, map() | nil} | {:error, term()}
  @optional_callbacks session_model: 2, runs_on: 2, task_worker: 1, default_task_model: 1

  @spec task_worker(map()) :: {:ok, String.t()} | {:error, term()}
  def task_worker(scope) when is_map(scope) do
    impl = impl()

    if SystemsRuntime.Proc.ensure_loaded?(impl) and function_exported?(impl, :task_worker, 1),
      do: impl.task_worker(scope),
      else: {:error, :task_worker_required}
  end

  @spec default_task_model(map()) :: {:ok, map() | nil} | {:error, term()}
  def default_task_model(scope) when is_map(scope) do
    impl = impl()

    if SystemsRuntime.Proc.ensure_loaded?(impl) and
         function_exported?(impl, :default_task_model, 1),
       do: impl.default_task_model(scope),
       else: {:ok, nil}
  end

  @spec session_model(map(), map()) :: {:ok, map()} | {:error, term()}
  def session_model(scope, choice) when is_map(scope) do
    impl = impl()

    if SystemsRuntime.Proc.ensure_loaded?(impl) and function_exported?(impl, :session_model, 2),
      do: impl.session_model(scope, choice),
      else: {:error, :model_selection_unsupported}
  end

  @spec runs_on(map(), map()) :: {:ok, map()} | {:error, term()}
  def runs_on(scope, request) when is_map(scope) do
    impl = impl()

    if SystemsRuntime.Proc.ensure_loaded?(impl) and function_exported?(impl, :runs_on, 2),
      do: impl.runs_on(scope, request),
      else: {:error, :runs_on_unsupported}
  end

  @spec create_task_conversation(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs)
      when is_map(attrs),
      do:
        impl().create_task_conversation(
          group_id,
          delegator_agent_id,
          target_agent_id,
          attrs
        )

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :task_create_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator_agent_id, _target_agent_id, _attrs),
      do: {:error, :task_create_not_configured}
  end
end
