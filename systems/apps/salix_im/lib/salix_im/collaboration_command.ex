defmodule SalixIM.CollaborationCommand do
  @moduledoc """
  Whether a Collaborative Task's Worker round was started by its host's own
  words: the Message that woke it carries `task_command`, which only the
  host's Messages in a Task together carry (`SalixIM.ConversationActor`).
  What only the host decides (a Loop, which runs on the host's credits until
  stopped) asks this first.
  """

  alias SalixIM.Conversations

  @doc """
  True when the Messages that woke this round are the host's commands: at
  least one host command that asks the Worker (`task_command`, not
  `context_only`), and no other person's Message asking it. Words kept only
  as context (a host's message that named no one) never count.
  """
  def host_command?(ctx) when is_map(ctx) do
    group_id = Map.get(ctx, :group_id) || Map.get(ctx, "group_id")

    origins =
      [
        Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin")
        | List.wrap(Map.get(ctx, :trusted_origins) || Map.get(ctx, "trusted_origins"))
      ]
      |> Enum.filter(&is_map/1)
      |> Enum.uniq()

    with true <- is_binary(group_id) and origins != [],
         {:ok, messages} <- read_all(group_id, origins) do
      asking = Enum.reject(messages, &(get_in(&1, ["metadata", "context_only"]) == true))

      asking != [] and
        Enum.all?(asking, &(get_in(&1, ["metadata", "task_command"]) == true))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def host_command?(_ctx), do: false

  defp read_all(group_id, origins) do
    Enum.reduce_while(origins, {:ok, []}, fn origin, {:ok, read} ->
      case Conversations.get_group_conversation_message(
             group_id,
             origin["conversation_id"],
             origin["message_id"]
           ) do
        {:ok, message} -> {:cont, {:ok, [message | read]}}
        _ -> {:halt, :error}
      end
    end)
  end
end
