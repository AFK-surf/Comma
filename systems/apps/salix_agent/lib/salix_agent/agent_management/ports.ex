defmodule SalixAgent.AgentManagement.Ports do
  @moduledoc "Product scope and defaults supplied by the composition root."

  @callback project_id(map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Create an internal Worker. `model` is nil (the product default) or a catalog
  choice: `%{"kind" => "catalog", "model" => id}` with optional
  `reasoning_effort`, `allow_paid` and `profile_id`. The port calls `create`
  once with the product attributes (`model`, and `vm` where the product has
  one) and returns its result. A Worker without `model` follows the platform
  model of its role (`SalixAgent.AgentModel`). A product that does not let the Router
  choose a model rejects a non-nil `model`.
  """
  @callback internal_worker(map(), map() | nil, (map() -> {:ok, map()} | {:error, term()})) ::
              {:ok, map()} | {:error, term()}

  @doc "The Group owner's `locale` and `timezone`, each nil when the product has none."
  @callback user_context(map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Check a Router's model choice for one Task's Worker Session and answer the
  value the Session stores (`SalixAgent.ModelChoice`). The choice has the
  shape `internal_worker/3` takes. A product that does not let the Router choose
  a model rejects it.
  """
  @callback session_model(map(), map()) :: {:ok, map()} | {:error, term()}

  @doc """
  The models a Router may choose, as a function that narrows the
  `agent.models` list (`SalixAgent.AccountPool.servable_models/2`). A product
  that governs models keeps only those its `session_model/2` accepts.
  """
  @callback model_filter(map()) :: {:ok, ([map()] -> [map()])} | {:error, term()}

  @doc """
  The Worker a Task takes when the Router names none: the Group's Task agent
  (`SalixAgent.TaskAgent.ensure/2`). A product whose Group already ran its
  Tasks on one Worker gives it as the Task agent to adopt.
  """
  @callback task_worker(map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  The product's default Task model for a Group that has set none of its own
  (`SalixAgent.TaskModel`), or nil: a BridgeForTeams org's default Task model.
  """
  @callback default_task_model(map()) :: {:ok, map() | nil} | {:error, term()}
  @optional_callbacks default_task_model: 1

  def project_id(scope), do: impl().project_id(scope)
  def internal_worker(scope, model, create), do: impl().internal_worker(scope, model, create)
  def user_context(scope), do: impl().user_context(scope)
  def session_model(scope, choice), do: impl().session_model(scope, choice)
  def model_filter(scope), do: impl().model_filter(scope)
  def task_worker(scope), do: impl().task_worker(scope)

  def default_task_model(scope) do
    impl = impl()

    if SystemsRuntime.Proc.ensure_loaded?(impl) and
         function_exported?(impl, :default_task_model, 1),
       do: impl.default_task_model(scope),
       else: {:ok, nil}
  end

  defp impl,
    do: SystemsRuntime.get_env(:salix_agent, :agent_management_ports, __MODULE__.Standalone)

  @doc """
  Internal Worker creation for a product without a Router model choice: the
  Worker follows the platform model of its role.
  """
  def default_internal_worker(model, _create) when not is_nil(model),
    do: {:error, :model_selection_unsupported}

  def default_internal_worker(nil, create), do: create.(%{})

  @doc "Session model choice for a product without a Router model choice."
  def default_session_model(_scope, _choice), do: {:error, :model_selection_unsupported}

  @doc "Model filter for a product without model governance: every model."
  def no_model_filter, do: {:ok, &Function.identity/1}

  @no_user_context %{"locale" => nil, "timezone" => nil}
  def no_user_context, do: @no_user_context

  defmodule Standalone do
    @moduledoc "Explicit Salix-only composition used when no product adapter is installed."
    @behaviour SalixAgent.AgentManagement.Ports

    def project_id(_), do: {:error, :target_not_found}

    def internal_worker(_scope, model, create),
      do: SalixAgent.AgentManagement.Ports.default_internal_worker(model, create)

    def user_context(_scope), do: {:ok, SalixAgent.AgentManagement.Ports.no_user_context()}

    def session_model(scope, choice),
      do: SalixAgent.AgentManagement.Ports.default_session_model(scope, choice)

    def model_filter(_scope), do: SalixAgent.AgentManagement.Ports.no_model_filter()

    def task_worker(scope), do: SalixAgent.TaskAgent.ensure(scope)
  end
end
