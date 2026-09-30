defmodule Salix.Bindings.IMAgentDelivery do
  @moduledoc false

  @behaviour SalixIM.Ports.AgentDelivery

  @impl true
  def prepare_conversation_input(agent_id),
    do: SalixAgent.AgentActor.prepare_conversation_input(agent_id)

  @impl true
  def notify_conversation(agent_id, source),
    do: SalixAgent.AgentActor.notify_conversation(agent_id, source, timeout: 5_000)

  @impl true
  def conversation_progress(agent, session, participant) do
    with {:ok, sources, _} <- SalixAgent.ConversationConsumer.progress(agent, session),
         do: {:ok, sources[participant]}
  end

  @impl true
  def get_session(agent_id, session_id, opts),
    do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

  @impl true
  def get_session_messages(agent_id, session_id),
    do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)

  @impl true
  def consult_memory(agent_id, session_id, question, request_id, opts),
    do:
      SalixAgent.AgentActor.consult_worker_session(
        agent_id,
        session_id,
        question,
        request_id,
        opts
      )
end
