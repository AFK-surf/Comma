defmodule SalixIM.LarkSocket.CatchUp do
  @moduledoc """
  What was said while a Lark or Feishu connect's long connection was down.

  Lark and Feishu keep no events for a long connection that is not there, so a message
  sent while the socket was down (a rollout, a lease moving to another node)
  never arrives on it. When the socket opens, `run/3` reads the history of
  the connect's chats with the Router since then and hands each message to
  the handler as the `im.message.receive_v1` event it would have been. A
  message that did arrive has its receipt (`SalixIM.LarkInbound`,
  `SalixIM.ProviderHTTP`), so it reaches the Router once either way.

  The chats read back are those the connect heard a message for the bot in
  (`ProviderObservations`), and the groups the bot is in. A private chat
  whose first message comes while the socket is down is not: nothing names
  that chat until a message in it arrives.

  A message the handler failed to hand over (the Router or its storage was
  unavailable) is tried again after `@retry_delays_ms`, as a live event that
  got no answer is sent again by the platform. Its receipt keeps a message
  that did reach the Router from reaching it twice.

  Bounds: the `@max_chats` chats with the latest messages for the bot and
  the first `@max_chats` groups the bot is in, at most `@max_pages` pages of
  `@page_size` messages each, and at most `length(@retry_delays_ms)` more
  attempts of each failed message.
  """

  require Logger

  alias SalixIM.Provider.{Feishu, Lark}
  alias SalixIM.{ProviderConnects, ProviderObservations}

  @max_chats 20
  @max_pages 3
  @page_size 50
  @retry_delays_ms [15_000, 60_000, 5 * 60_000]

  @doc """
  Hands each message of the connect's recent chats sent at or after
  `since_ms` (system time) to `handler.(connect, envelope)`, oldest first per
  chat, and the ones it failed again later. The handler succeeded when it
  returns `{:ok, _}`. Returns the number handed over.

  `opts[:sleep]` waits between attempts (`SystemsClock.sleep/1`).
  """
  @spec run(map(), integer(), (map(), map() -> term()), keyword()) :: non_neg_integer()
  def run(connect, since_ms, handler, opts \\ []) do
    {count, failed} =
      connect
      |> chats()
      |> Enum.reduce({0, []}, fn chat, acc -> chat(connect, chat, since_ms, handler, acc) end)

    retry(connect, Enum.reverse(failed), handler, @retry_delays_ms, count, opts)
  end

  defp retry(_connect, [], _handler, _delays, count, _opts), do: count

  defp retry(connect, failed, _handler, [], count, _opts) do
    Logger.warning("lark socket catch-up: messages not handed over",
      connect_id: connect["connect_id"],
      message_ids: Enum.map(failed, &get_in(&1, ["event", "message", "message_id"]))
    )

    count
  end

  defp retry(connect, failed, handler, [delay | delays], count, opts) do
    (opts[:sleep] || (&SystemsClock.sleep/1)).(delay)
    {count, failed} = Enum.reduce(failed, {count, []}, &hand(connect, &1, handler, &2))
    retry(connect, Enum.reverse(failed), handler, delays, count, opts)
  end

  defp hand(connect, envelope, handler, {count, failed}) do
    case handler.(connect, envelope) do
      {:ok, _answer} -> {count + 1, failed}
      _failed -> {count, [envelope | failed]}
    end
  end

  # The chats with a message for the bot, latest first, then the groups the
  # bot is in that none of them is: a group added while the socket was down
  # has nothing heard yet.
  defp chats(connect) do
    known =
      case list_chats(connect) do
        {:ok, chats} ->
          chats
          |> Enum.sort_by(&(&1["last_message_at"] || 0), :desc)
          |> Enum.take(@max_chats)

        {:error, reason} ->
          Logger.warning("lark socket catch-up: chats not read",
            connect_id: connect["connect_id"],
            reason: inspect(reason)
          )

          []
      end

    seen = MapSet.new(known, & &1["chat_id"])

    groups =
      case api(connect).get(connect, "/im/v1/chats", %{page_size: @max_chats}) do
        {:ok, data} ->
          for chat <- List.wrap(map(data)["items"]),
              is_map(chat),
              id = chat["chat_id"],
              is_binary(id) and id != "" and not MapSet.member?(seen, id),
              do: %{"chat_id" => id, "chat_type" => "group"}

        {:error, reason} ->
          Logger.warning("lark socket catch-up: the bot's groups not read",
            connect_id: connect["connect_id"],
            reason: inspect(reason)
          )

          note_missing_scope(connect, reason)
          []
      end

    known ++ groups
  end

  @doc "A message of a chat's history as Lark's `im.message.receive_v1` event of it."
  def envelope(connect, item) when is_map(item) do
    sender = map(item["sender"])

    %{
      "schema" => "2.0",
      "header" => %{
        "event_type" => "im.message.receive_v1",
        "event_id" => "catch-up:" <> to_string(item["message_id"]),
        "app_id" => connect["app_id"]
      },
      "event" => %{
        "sender" => %{
          "sender_type" => if(sender["sender_type"] == "app", do: "app", else: "user"),
          "sender_id" => %{"open_id" => to_string(sender["id"] || "")}
        },
        "message" =>
          item
          |> Map.take(~w(message_id root_id parent_id thread_id chat_id create_time update_time))
          |> Map.merge(%{
            "chat_type" => item["chat_type"] || "",
            "message_type" => item["msg_type"],
            "content" => get_in(item, ["body", "content"]),
            "mentions" =>
              Enum.map(List.wrap(item["mentions"]), fn mention ->
                %{
                  "key" => mention["key"],
                  "name" => mention["name"],
                  "id" =>
                    if(is_binary(mention["id"]),
                      do: %{"open_id" => mention["id"]},
                      else: mention["id"]
                    )
                }
              end)
          })
      }
    }
  end

  defp chat(connect, chat, since_ms, handler, acc) do
    where = %{chat_id: chat["chat_id"], chat_type: chat["chat_type"] || ""}
    pages(connect, where, div(since_ms, 1_000), nil, @max_pages, acc, handler)
  end

  defp pages(_connect, _where, _since_s, _token, 0, acc, _handler), do: acc

  defp pages(connect, %{chat_id: chat_id} = where, since_s, token, left, acc, handler) do
    params =
      %{
        container_id_type: "chat",
        container_id: chat_id,
        start_time: Integer.to_string(since_s),
        sort_type: "ByCreateTimeAsc",
        page_size: @page_size
      }
      |> then(&if(token, do: Map.put(&1, :page_token, token), else: &1))

    case api(connect).get(connect, "/im/v1/messages", params) do
      {:ok, data} ->
        acc =
          for item <- data |> map() |> Map.get("items") |> List.wrap(),
              is_map(item),
              item["deleted"] != true,
              reduce: acc do
            acc ->
              item =
                item
                |> Map.put_new("chat_id", chat_id)
                |> Map.put_new("chat_type", where.chat_type)

              hand(connect, envelope(connect, item), handler, acc)
          end

        case data do
          %{"has_more" => true, "page_token" => next} when is_binary(next) and next != "" ->
            pages(connect, where, since_s, next, left - 1, acc, handler)

          _done ->
            acc
        end

      {:error, reason} ->
        Logger.warning("lark socket catch-up: history not read",
          connect_id: connect["connect_id"],
          chat_id: chat_id,
          reason: inspect(reason)
        )

        note_missing_scope(connect, reason)
        acc
    end
  end

  # The member sees which scope the app lacks (`ProviderConnects`).
  defp note_missing_scope(connect, reason) do
    case api(connect).missing_scope(reason) do
      nil -> :ok
      scope -> ProviderConnects.note_missing_scope(connect, scope)
    end
  end

  defp api(%{"provider" => "feishu"}), do: Feishu.API
  defp api(_connect), do: Lark.API

  defp list_chats(%{"provider" => "feishu"} = connect),
    do: ProviderObservations.list_feishu_chats(connect["connect_id"], "", 1_000)

  defp list_chats(connect),
    do: ProviderObservations.list_lark_chats(connect["connect_id"], "", 1_000)

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
end
