defmodule SalixIM.ConversationPlacement do
  @moduledoc """
  Placement seam for group-level and conversation-local owner actors.

  `salix_im` owns conversation semantics but does not depend on the cluster
  app. Single-node/dev/test runs use the local fleet. Cluster deployments
  install an implementation that routes to the owner node.
  """

  @callback ensure_started(
              group_id :: String.t(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, pid()} | {:error, term()}

  @callback ensure_group_started(group_id :: String.t(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @callback notify_group_conversation_mutation_if_running(
              group_id :: String.t(),
              mutation :: map()
            ) :: :ok

  @spec ensure_started(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(group_id, conversation_id, opts \\ []),
    do: impl().ensure_started(group_id, conversation_id, opts)

  @spec ensure_group_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_group_started(group_id, opts \\ []),
    do: impl().ensure_group_started(group_id, opts)

  @spec notify_group_conversation_mutation_if_running(String.t(), map()) :: :ok
  def notify_group_conversation_mutation_if_running(group_id, mutation),
    do: impl().notify_group_conversation_mutation_if_running(group_id, mutation)

  defp impl, do: Application.get_env(:salix_im, :conversation_placement, __MODULE__.LocalFleet)

  defmodule LocalFleet do
    @moduledoc false
    @behaviour SalixIM.ConversationPlacement

    @impl true
    def ensure_started(group_id, conversation_id, opts),
      do: SalixIM.ConversationFleet.ensure_started(group_id, conversation_id, opts)

    @impl true
    def ensure_group_started(group_id, opts),
      do: SalixIM.ConversationFleet.ensure_group_started(group_id, opts)

    @impl true
    def notify_group_conversation_mutation_if_running(group_id, mutation),
      do:
        SalixIM.ConversationGroupActor.notify_conversation_mutation_if_running(
          group_id,
          mutation
        )
  end
end
