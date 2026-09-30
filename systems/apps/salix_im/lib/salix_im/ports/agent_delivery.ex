defmodule SalixIM.Ports.AgentDelivery do
  @moduledoc """
  Outbound port used by SalixIM when an IM fact needs to wake or inspect an
  agent runtime.
  """

  @callback get_session(agent_id :: String.t(), session_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback get_session_messages(agent_id :: String.t(), session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback consult_memory(
              agent_id :: String.t(),
              session_id :: String.t(),
              question :: String.t(),
              request_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback prepare_conversation_input(String.t()) :: :ok | {:error, term()}
  @callback notify_conversation(String.t(), map()) :: :ok | {:error, term()}
  @callback conversation_progress(String.t(), String.t(), String.t()) ::
              {:ok, map() | nil} | {:error, term()}
  @optional_callbacks consult_memory: 5,
                      notify_conversation: 2,
                      conversation_progress: 3,
                      prepare_conversation_input: 1

  def conversation_progress(agent_id, session_id, participant_id) do
    module = impl()

    if Code.ensure_loaded?(module) and function_exported?(module, :conversation_progress, 3),
      do: module.conversation_progress(agent_id, session_id, participant_id),
      else: {:error, :agent_delivery_not_configured}
  end

  def prepare_conversation_input(agent_id) do
    module = impl()

    if Code.ensure_loaded?(module) and function_exported?(module, :prepare_conversation_input, 1),
      do: module.prepare_conversation_input(agent_id),
      else: :ok
  end

  def notify_conversation(agent_id, source) do
    module = impl()

    if Code.ensure_loaded?(module) and function_exported?(module, :notify_conversation, 2),
      do: module.notify_conversation(agent_id, source),
      else: {:error, :agent_delivery_not_configured}
  end

  @spec get_session(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_session(agent_id, session_id, opts \\ []),
    do: impl().get_session(agent_id, session_id, opts)

  @spec get_session_messages(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_session_messages(agent_id, session_id),
    do: impl().get_session_messages(agent_id, session_id)

  @spec consult_memory(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def consult_memory(agent_id, session_id, question, request_id, opts \\ []),
    do: impl().consult_memory(agent_id, session_id, question, request_id, opts)

  defp impl, do: Application.get_env(:salix_im, :agent_delivery_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :agent_delivery_not_configured}

    @impl true
    def get_session_messages(_agent_id, _session_id),
      do: {:error, :agent_delivery_not_configured}

    @impl true
    def consult_memory(_agent_id, _session_id, _question, _request_id, _opts),
      do: {:error, :agent_delivery_not_configured}
  end
end
