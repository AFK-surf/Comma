defmodule SalixIM.LarkThreads do
  @moduledoc """
  The Lark threads a connect's bot answers in.

  A group message reaches the Router when it mentions the bot. A reply of the
  bot opens a thread under that message, and people then go on in the thread
  without another mention. `join/3` marks a thread when the bot sends into it;
  `joined?/3` is what `SalixIM.LarkInbound` asks about a group message of a
  thread that does not mention the bot.

  A mark lasts 30 days from the last message of the thread that used it, so a
  thread people left stops reaching the Router. The mark is a fact about one
  connect, chat and thread; it is no grant: a message admitted by it never
  runs a control command (`SalixIM.LarkInbound`).
  """

  alias SalixStore.{CasRecord, Keys}

  @ttl_ms 30 * 24 * 60 * 60 * 1_000

  @doc "Marks a thread the bot sent into. Best effort for the caller: the send already happened."
  @spec join(map(), term(), term()) :: :ok | {:error, term()}
  def join(connect, chat_id, thread_id) when is_map(connect) do
    with {:ok, key} <- key(connect, chat_id, thread_id) do
      mark = %{"expires_at" => SystemsClock.system_time(:millisecond) + @ttl_ms}

      case CasRecord.create(key, mark) do
        {:ok, _record} -> :ok
        {:error, :exists} -> extend(key)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "True for a thread the bot sent into and people still use. A hit extends the mark."
  @spec joined?(map(), term(), term()) :: boolean()
  def joined?(connect, chat_id, thread_id) when is_map(connect) do
    with {:ok, key} <- key(connect, chat_id, thread_id),
         {:ok, %{"expires_at" => expires_at}} when is_integer(expires_at) <- CasRecord.get(key),
         true <- expires_at > SystemsClock.system_time(:millisecond) do
      _ = extend(key)
      true
    else
      _unknown -> false
    end
  end

  defp extend(key) do
    expires_at = SystemsClock.system_time(:millisecond) + @ttl_ms

    case CasRecord.update(key, &Map.put(&1, "expires_at", expires_at)) do
      {:ok, _record} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp key(connect, chat_id, thread_id) do
    ids = [connect["group_id"], connect["connect_id"], chat_id, thread_id]

    if Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) do
      [group_id, connect_id, chat_id, thread_id] = Enum.map(ids, &String.trim/1)
      {:ok, Keys.ctl_im_lark_thread(group_id, connect_id, chat_id, thread_id)}
    else
      {:error, :invalid_lark_thread}
    end
  end
end
