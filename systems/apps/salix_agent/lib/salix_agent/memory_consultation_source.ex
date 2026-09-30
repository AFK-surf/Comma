defmodule SalixAgent.MemoryConsultationSource do
  @moduledoc """
  Read-only port from `memory.ask_worker` to Conversation discovery and the
  Conversation-owned target route.

  Discovery returns candidate Worker Session targets. Consultation re-resolves
  the private Agent Participant payload through the IM owner boundary before
  invoking the Worker owner. Private identifiers are consumed by the tool
  executor and are never disclosed as tool input.
  """

  @type target :: %{
          required(:agent_id) => String.t(),
          required(:session_id) => String.t(),
          required(:participant_id) => String.t(),
          required(:worker_role) => String.t(),
          required(:runtime_kind) => String.t(),
          required(:conversation_ref) => map(),
          required(:rank_at) => integer()
        }

  @callback search_worker_sessions(
              group_id :: String.t(),
              keywords :: String.t(),
              conversation_refs :: [map()],
              limit :: pos_integer()
            ) :: {:ok, %{targets: [target()], truncated: boolean()}} | {:error, term()}

  @callback consult_worker_session(
              group_id :: String.t(),
              target :: target(),
              question :: String.t(),
              request_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @spec search(String.t(), String.t(), [map()], pos_integer()) ::
          {:ok, %{targets: [target()], truncated: boolean()}} | {:error, term()}
  def search(group_id, keywords, conversation_refs, limit) do
    case Application.get_env(:salix_agent, :memory_consultation_source_mod) do
      module when is_atom(module) and not is_nil(module) ->
        module.search_worker_sessions(group_id, keywords, conversation_refs, limit)

      _ ->
        {:error, :memory_consultation_source_not_configured}
    end
  end

  @spec consult(String.t(), target(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def consult(group_id, target, question, request_id, opts \\ []) do
    case Application.get_env(:salix_agent, :memory_consultation_source_mod) do
      module when is_atom(module) and not is_nil(module) ->
        module.consult_worker_session(group_id, target, question, request_id, opts)

      _ ->
        {:error, :memory_consultation_source_not_configured}
    end
  end
end
