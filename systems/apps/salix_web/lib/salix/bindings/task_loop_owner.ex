defmodule Salix.Bindings.TaskLoopOwner do
  @moduledoc """
  The Task owner of Task Loops: the Loop runtime's wakes and ends
  (`SalixAgent.Loops.TaskOwner`) go to the Task's Conversation owner.
  """

  @behaviour SalixAgent.Loops.TaskOwner

  @impl true
  def loop_wake(loop, payload, source_id),
    do:
      SalixIM.ConversationServer.task_loop_wake(
        loop["group_id"],
        loop["conversation_id"],
        loop,
        payload,
        source_id
      )

  # A Task that is gone took its Loop's end with it.
  @impl true
  def loop_ended(loop, fact) do
    case SalixIM.ConversationServer.task_loop_ended(
           loop["group_id"],
           loop["conversation_id"],
           loop,
           fact
         ) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end
end
