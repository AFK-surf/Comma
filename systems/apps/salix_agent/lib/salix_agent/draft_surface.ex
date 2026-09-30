defmodule SalixAgent.DraftSurface do
  @moduledoc """
  Agent-owner-local draft presentation for one runtime session.

  Drafts are transient participant status, never Message candidates or durable
  append intents. The exact Participant owner routes its SessionActivity read
  to the agent owner and decides whether the embedded scope belongs to it.
  """

  use GenServer

  @table __MODULE__
  @stale_after_ms 10 * 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  def put(agent_id, session_id, scope, text)
      when is_binary(agent_id) and is_binary(session_id) and is_map(scope) and
             is_binary(text) do
    response_key = scope["response_identity"]

    if SalixAgent.VisibleReplyScope.valid_activation_scope?(scope) do
      revision = next_revision(agent_id, session_id, response_key)
      now = System.system_time(:millisecond)

      draft = %{
        "agent_group_id" => scope["agent_group_id"],
        "conversation_id" => scope["conversation_id"],
        "participant_id" => scope["participant_id"],
        "response_key" => response_key,
        "revision" => revision,
        "status" => "streaming",
        "text" => text,
        "source_message_ids" => scope["source_message_ids"],
        "updated_at" => now
      }

      :ets.insert(@table, {{agent_id, session_id}, draft, monotonic_ms()})
      :changed
    else
      :unchanged
    end
  rescue
    ArgumentError -> :unchanged
  end

  def put(_agent_id, _session_id, _scope, _text), do: :unchanged

  def clear(agent_id, session_id, scope)
      when is_binary(agent_id) and is_binary(session_id) and is_map(scope) do
    case get(agent_id, session_id) do
      %{"response_key" => response_key} ->
        if response_key == scope["response_identity"] do
          :ets.delete(@table, {agent_id, session_id})
          :changed
        else
          :unchanged
        end

      _other ->
        :unchanged
    end
  rescue
    ArgumentError -> :unchanged
  end

  def clear(_agent_id, _session_id, _scope), do: :unchanged

  def get(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    case :ets.lookup(@table, {agent_id, session_id}) do
      [{{^agent_id, ^session_id}, draft, recorded_at}] ->
        if monotonic_ms() - recorded_at <= @stale_after_ms do
          draft
        else
          :ets.delete(@table, {agent_id, session_id})
          nil
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def get(_agent_id, _session_id), do: nil

  defp next_revision(agent_id, session_id, response_key) do
    case get(agent_id, session_id) do
      %{"response_key" => ^response_key, "revision" => revision} when is_integer(revision) ->
        revision + 1

      _other ->
        1
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
