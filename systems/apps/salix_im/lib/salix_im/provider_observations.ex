defmodule SalixIM.ProviderObservations do
  @moduledoc false

  alias SalixStore.{CasRecord, Keys, S3}

  @scan_max_records 500
  # How many message ids a QQ chat remembers to recognize a redelivery.
  @qq_recent_message_ids 32
  @qq_message_refs 64

  def upsert_telegram_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_telegram_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "title" => trim(attrs["title"]),
        "username" => trim(attrs["username"]),
        "last_message_at" => attrs["last_message_at"] || now()
      })
    end
  end

  def upsert_telegram_user(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    user_id = trim(attrs["user_id"])

    if user_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_telegram_user(connect_id, user_id), %{
        "connect_id" => connect_id,
        "user_id" => user_id,
        "username" => trim(attrs["username"]),
        "display_name" => trim(attrs["display_name"]),
        "is_bot" => attrs["is_bot"] == true,
        "last_seen_at" => attrs["last_seen_at"] || now()
      })
    end
  end

  def list_telegram_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_telegram_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "title", "username"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def list_telegram_users(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_telegram_users_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["user_id", "username", "display_name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def get_telegram_chat(connect_id, chat_id),
    do: CasRecord.get(Keys.ctl_im_telegram_chat(connect_id, trim(chat_id)))

  @doc """
  Records the newest message a QQ chat sent to the bot. QQ accepts a reply to
  that message for a few minutes and a few times; `reserve_qq_reply/4` spends
  those replies.
  """
  def upsert_qq_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    message_id = trim(attrs["message_id"])
    # The index QQ quotes this message by; see `remember_qq_sent_message/4`.
    ref = trim(attrs["message_ref"])

    if chat_id == "" do
      :ok
    else
      now = now()

      observed = %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "last_sender_id" => trim(attrs["sender_id"]),
        "last_sender_name" => trim(attrs["sender_name"]),
        "last_message_id" => message_id,
        "last_message_at" => attrs["message_at"] || now,
        "reply_seq" => 0,
        # A chat that writes is one the bot is in; see `note_qq_chat/4`.
        "present" => true,
        "updated_at" => now
      }

      # The newest message is the one a reply answers, and it only moves
      # forward. A message seen before is a redelivery, whatever arrived since:
      # the replies made to it stay counted, because QQ refuses a second reply
      # with a used sequence number. QQ's send time has one-second precision,
      # so the ids seen lately decide, and the time only rejects a message
      # older than the newest one.
      CasRecord.update(Keys.ctl_im_qq_chat(connect_id, chat_id), fn
        nil ->
          observed
          |> Map.put("created_at", now)
          |> Map.put("recent_message_ids", [message_id])
          |> put_message_ref(message_id, ref)

        current ->
          seen = List.wrap(current["recent_message_ids"])

          if message_id == "" or message_id == current["last_message_id"] or message_id in seen or
               num(current["last_message_at"]) > observed["last_message_at"] do
            {:unchanged, current}
          else
            current
            |> Map.merge(observed)
            |> Map.put(
              "recent_message_ids",
              Enum.take([message_id | seen], @qq_recent_message_ids)
            )
            |> put_message_ref(message_id, ref)
          end
      end)
      |> case do
        {:ok, _chat} -> :ok
        other -> other
      end
    end
  end

  @doc "Records whether a QQ chat currently accepts proactive messages from the bot."
  def set_qq_chat_proactive(connect, chat_id, chat_type, proactive?)
      when is_map(connect) and is_boolean(proactive?) do
    connect_id = connect["connect_id"]
    chat_id = trim(chat_id)

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_qq_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => chat_type,
        "proactive" => proactive?
      })
    end
  end

  @doc """
  Records a message the bot sent to a QQ chat: its ID, so that the bot can
  take back what it sent and nothing else, and the index QQ quotes it by when
  QQ returned one.
  """
  def remember_qq_sent_message(connect, chat_id, message_id, ref) when is_map(connect) do
    {chat_id, message_id, ref} = {trim(chat_id), trim(message_id), trim(ref)}

    if chat_id == "" or message_id == "" do
      :ok
    else
      connect_id = connect["connect_id"]

      CasRecord.update(Keys.ctl_im_qq_chat(connect_id, chat_id), fn current ->
        chat =
          current ||
            %{
              "connect_id" => connect_id,
              "chat_id" => chat_id,
              "chat_type" =>
                if(String.starts_with?(chat_id, "group:"), do: "group", else: "private"),
              "created_at" => now()
            }

        sent = chat["sent_message_ids"] |> List.wrap() |> List.delete(message_id)

        chat
        |> Map.put("sent_message_ids", Enum.take([message_id | sent], @qq_message_refs))
        |> put_message_ref(message_id, ref)
      end)
      |> case do
        {:ok, _chat} -> :ok
        other -> other
      end
    end
  end

  @doc "True when the bot sent this message to the chat lately."
  def qq_sent_message?(connect_id, chat_id, message_id) do
    case get_qq_chat(connect_id, chat_id) do
      {:ok, %{"sent_message_ids" => sent}} when is_list(sent) -> trim(message_id) in sent
      _none -> false
    end
  end

  defp put_message_ref(chat, message_id, ref) when message_id != "" and ref != "" do
    kept = chat["message_refs"] |> List.wrap() |> Enum.reject(&match?([^message_id, _ref], &1))
    Map.put(chat, "message_refs", Enum.take([[message_id, ref] | kept], @qq_message_refs))
  end

  defp put_message_ref(chat, _message_id, _ref), do: chat

  @doc "The quote index kept for a message of a QQ chat, or `nil`."
  def qq_message_ref(connect_id, chat_id, message_id) do
    message_id = trim(message_id)

    case get_qq_chat(connect_id, chat_id) do
      {:ok, %{"message_refs" => refs}} when is_list(refs) ->
        Enum.find_value(refs, fn
          [^message_id, ref] -> ref
          _other -> nil
        end)

      _none ->
        nil
    end
  end

  @doc """
  Records facts QQ reported about a chat outside a message: the bot joined or
  left a group, a person added or removed the bot, or the group's name.
  """
  def note_qq_chat(connect, chat_id, chat_type, facts)
      when is_map(connect) and is_map(facts) do
    connect_id = connect["connect_id"]
    chat_id = trim(chat_id)

    if chat_id == "" do
      :ok
    else
      upsert(
        Keys.ctl_im_qq_chat(connect_id, chat_id),
        facts
        |> Map.take(~w(present name added_by added_from))
        |> Map.merge(%{
          "connect_id" => connect_id,
          "chat_id" => chat_id,
          "chat_type" => chat_type
        })
      )
    end
  end

  def get_qq_chat(connect_id, chat_id),
    do: CasRecord.get(Keys.ctl_im_qq_chat(connect_id, trim(chat_id)))

  def list_qq_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_qq_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "chat_type", "name", "last_sender_name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  @doc """
  Takes the next reply to the chat's newest message.

  Returns `{:ok, message_id, seq}` while that message is younger than
  `window_ms` and has fewer than `max_replies` replies, and `:none` otherwise
  or for a chat that never wrote to the bot.
  """
  def reserve_qq_reply(connect_id, chat_id, window_ms, max_replies) do
    now = now()

    CasRecord.update(
      Keys.ctl_im_qq_chat(connect_id, trim(chat_id)),
      fn current ->
        message_id = trim(current["last_message_id"])
        seq = num(current["reply_seq"])

        if message_id != "" and now - num(current["last_message_at"]) < window_ms and
             seq < max_replies,
           do: Map.put(current, "reply_seq", seq + 1),
           else: {:error, :no_reply_window}
      end,
      create: false
    )
    |> case do
      {:ok, %{"last_message_id" => message_id, "reply_seq" => seq}} -> {:ok, message_id, seq}
      _none -> :none
    end
  end

  def upsert_feishu_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_feishu_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "name" => trim(attrs["name"]),
        "last_message_at" => attrs["last_message_at"] || now()
      })
    end
  end

  def upsert_feishu_user(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    open_id = trim(attrs["open_id"])

    if open_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_feishu_user(connect_id, open_id), %{
        "connect_id" => connect_id,
        "open_id" => open_id,
        "union_id" => trim(attrs["union_id"]),
        "user_id" => trim(attrs["user_id"]),
        "name" => trim(attrs["name"]),
        "email" => trim(attrs["email"]),
        "last_seen_at" => attrs["last_seen_at"] || now()
      })
    end
  end

  def list_feishu_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_feishu_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "chat_type", "name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def list_feishu_users(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_feishu_users_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["open_id", "union_id", "user_id", "name", "email"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def upsert_lark_chat(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    chat_id = trim(attrs["chat_id"])

    if chat_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_lark_chat(connect_id, chat_id), %{
        "connect_id" => connect_id,
        "chat_id" => chat_id,
        "chat_type" => trim(attrs["chat_type"]),
        "name" => trim(attrs["name"]),
        "last_message_at" => attrs["last_message_at"] || now()
      })
    end
  end

  def upsert_lark_user(connect, attrs) when is_map(connect) and is_map(attrs) do
    connect_id = connect["connect_id"]
    open_id = trim(attrs["open_id"])

    if open_id == "" do
      :ok
    else
      upsert(Keys.ctl_im_lark_user(connect_id, open_id), %{
        "connect_id" => connect_id,
        "open_id" => open_id,
        "union_id" => trim(attrs["union_id"]),
        "user_id" => trim(attrs["user_id"]),
        "name" => trim(attrs["name"]),
        "email" => trim(attrs["email"]),
        "last_seen_at" => attrs["last_seen_at"] || now()
      })
    end
  end

  def list_lark_chats(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_lark_chats_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["chat_id", "chat_type", "name"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  def list_lark_users(connect_id, query, limit) do
    with {:ok, records} <- scan_records(Keys.ctl_im_lark_users_prefix(connect_id)) do
      {:ok,
       records
       |> filter(query, ["open_id", "union_id", "user_id", "name", "email"])
       |> Enum.take(clamp_limit(limit))}
    end
  end

  defp scan_records(prefix) do
    with {:ok, %{objects: objects, next: nil}} when length(objects) <= @scan_max_records <-
           S3.list(prefix, max_keys: @scan_max_records) do
      Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, records} ->
        case CasRecord.get(key, :invalid_observation_record) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:observation_record_unavailable, key, reason}}}
        end
      end)
      |> then(fn
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end)
    else
      {:ok, %{next: _continuation}} -> {:error, :observation_scan_limit_exceeded}
      {:error, _reason} = error -> error
      other -> {:error, {:observation_scan_failed, other}}
    end
  end

  defp upsert(key, attrs) do
    now = now()

    rec =
      attrs
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.put_new("created_at", now)
      |> Map.put("updated_at", now)

    CasRecord.update(key, fn
      nil ->
        rec

      current ->
        rec
        |> Map.put("created_at", current["created_at"] || now)
        |> then(&Map.merge(current, &1))
    end)
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp filter(records, query, fields) do
    query = String.downcase(trim(query))

    records
    |> Enum.sort_by(&(&1["updated_at"] || 0), :desc)
    |> Enum.filter(fn rec ->
      query == "" or
        Enum.any?(fields, fn field ->
          rec[field]
          |> trim()
          |> String.downcase()
          |> String.contains?(query)
        end)
    end)
  end

  defp clamp_limit(limit) do
    case num(limit) do
      n when n <= 0 -> 50
      n when n > 100 -> 100
      n -> n
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp num(value) when is_integer(value), do: value
  defp num(value) when is_float(value), do: trunc(value)

  defp num(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp num(_), do: 0
  defp now, do: SystemsClock.system_time(:millisecond)
end
