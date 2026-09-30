defmodule SalixIM.ConversationSearchEnqueuer do
  @moduledoc """
  Best-effort low-latency relay into the durable Conversation search queue.

  Correctness does not depend on this relay: durable discovery rediscovers
  committed canonical versions. Each admission starts at most one monitored
  task in a globally bounded pool. A slow/unavailable PostgreSQL dependency
  therefore consumes only a bounded relay slot; callers drop the optimization
  instead of blocking or restarting Conversation owners. Loss and duplicate
  relay admission map to `tla/salix/ConversationTaskSearchQueue.tla`.
  """

  alias SalixStore.ConversationSearch

  @max_children 32

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    Task.Supervisor.start_link(
      Keyword.merge([name: __MODULE__, max_children: @max_children], opts)
    )
  end

  @spec submit(:rebuild | :delete, String.t(), String.t()) ::
          :ok | {:error, :full | :unavailable}
  def submit(operation, group_id, conversation_id) when operation in [:rebuild, :delete],
    do: start_task(fn -> persist(operation, group_id, conversation_id) end)

  @spec submit_message(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, :full | :unavailable}
  def submit_message(group_id, conversation_id, message_id, seq),
    do:
      start_task(fn ->
        ConversationSearch.enqueue_message(group_id, conversation_id, message_id, seq)
      end)

  @doc false
  def pending_count do
    __MODULE__
    |> Task.Supervisor.children()
    |> length()
  catch
    :exit, _reason -> 0
  end

  defp persist(:rebuild, group_id, conversation_id),
    do: ConversationSearch.enqueue_rebuild(group_id, conversation_id)

  defp persist(:delete, group_id, conversation_id),
    do: ConversationSearch.enqueue_delete(group_id, conversation_id)

  defp start_task(fun) do
    case Task.Supervisor.start_child(__MODULE__, fun, restart: :temporary) do
      {:ok, _pid} -> :ok
      {:error, :max_children} -> {:error, :full}
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
