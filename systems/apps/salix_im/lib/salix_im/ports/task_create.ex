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
    do: Application.get_env(:salix_im, :task_create_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator_agent_id, _target_agent_id, _attrs),
      do: {:error, :task_create_not_configured}
  end
end
