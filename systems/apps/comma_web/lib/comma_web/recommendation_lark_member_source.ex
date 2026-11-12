defmodule CommaWeb.RecommendationLarkMemberSource do
  @moduledoc """
  A member's Feishu or Lark for their Routine, read with their own sign-in
  (the bot app their scan made; `CommaWeb.PluginConnections`).

  Three relationships from the platform's own APIs, as the official
  larksuite/cli reads them: messages of the last seven days that mention the
  member (`im/v1/messages/search`, `is_at_me`), their direct messages of the
  same days, and calendar events of the next three days that wait for their
  answer. The newest message per chat stands for that chat, and a message
  the member sent is never one waiting for them.
  """

  alias CommaWeb.{
    RecommendationMemberRead,
    RecommendationSourceContext,
    RecommendationSourceQuote
  }

  @days 7
  @event_days 3
  @search_page 40
  @chats 20
  @events 10
  @applink %{"feishu" => "https://applink.feishu.cn", "lark" => "https://applink.larksuite.com"}

  @doc """
  Reads with `request.(method, path, options)`, where `path` starts at the
  platform's `/open-apis` and the answer is the body's `data`. The token's
  user must be the member the grant was made for (`identity`).
  """
  def read(provider, request, now, %{"provider_user_id" => me} = _identity)
      when is_map_key(@applink, provider) and is_binary(me) do
    with {:ok, %{"open_id" => ^me}} <- request.(:get, "/authen/v1/user_info", []) do
      since = DateTime.add(now, -@days * 86_400, :second)

      [mentions, direct, events] =
        RecommendationMemberRead.map(
          [
            {:search, %{"is_at_me" => true}},
            {:search, %{"chat_type" => "p2p"}},
            :events
          ],
          fn
            {:search, filter} -> search(request, filter, since, now)
            :events -> events(request, now)
          end,
          3
        )

      reads = [mentions, direct, events]

      if Enum.all?(reads, &match?({:error, _}, &1)) do
        mentions
      else
        ids =
          (ids(mentions) ++ ids(direct))
          |> Enum.uniq()
          |> Enum.take(50)

        # Group and direct messages need different scopes: a batch of each, so
        # a scope one lacks leaves the other readable.
        direct_ids = MapSet.new(ids(direct))
        {direct_ids, group_ids} = Enum.split_with(ids, &MapSet.member?(direct_ids, &1))
        {group_messages, group_failure} = messages(request, group_ids)
        {direct_messages, direct_failure} = messages(request, direct_ids)
        messages = group_messages ++ direct_messages
        relation = Map.new(ids(direct), &{&1, "direct_message_to_you"})

        matches =
          messages
          |> Enum.reject(&(get_in(&1, ["sender", "id"]) == me or &1["deleted"] == true))
          |> Enum.sort_by(&timestamp(&1["create_time"]), :desc)
          |> Enum.uniq_by(& &1["chat_id"])
          |> Enum.take(@chats)

        names = chat_names(request, Enum.map(matches, & &1["chat_id"]))

        records =
          Enum.flat_map(matches, fn message ->
            message_record(
              provider,
              message,
              Map.get(relation, message["message_id"], "mentioned_you"),
              names[message["chat_id"]]
            )
          end) ++ Enum.flat_map(list(events), &event_record/1)

        failures =
          for({:error, reason} <- reads, do: reason) ++
            List.wrap(group_failure) ++ List.wrap(direct_failure)

        {:ok,
         RecommendationMemberRead.warn(
           %{"messages" => %{"matches" => records}, "memberRelation" => "involves_you"},
           failures
         )}
      end
    else
      {:ok, _other_user} -> {:error, :member_source_identity_mismatch}
      {:error, _} = error -> error
    end
  end

  def read(_provider, _request, _now, _identity), do: {:error, :member_identity_unavailable}

  defp search(request, filter, since, now) do
    body = %{
      "query" => "",
      "filter" =>
        Map.put(filter, "time_range", %{
          "start_time" => DateTime.to_iso8601(since),
          "end_time" => DateTime.to_iso8601(now)
        })
    }

    with {:ok, data} <-
           request.(:post, "/im/v1/messages/search",
             params: [page_size: @search_page],
             json: body
           ) do
      {:ok,
       for(%{"meta_data" => %{"message_id" => id}} <- list(data["items"]), is_binary(id), do: id)}
    end
  end

  # Invitations the member has not answered, cancelled ones aside.
  defp events(request, now) do
    with {:ok, data} <-
           request.(:get, "/calendar/v4/calendars/primary/events/instance_view",
             params: [
               start_time: DateTime.to_unix(now),
               end_time: DateTime.to_unix(DateTime.add(now, @event_days * 86_400, :second))
             ]
           ) do
      {:ok,
       data["items"]
       |> list()
       |> Enum.filter(&(&1["self_rsvp_status"] == "needs_action" and &1["status"] != "cancelled"))
       |> Enum.take(@events)}
    end
  end

  defp messages(_request, []), do: {[], nil}

  defp messages(request, ids) do
    params = [with_sender_name: true] ++ Enum.map(ids, &{:message_ids, &1})

    case request.(:get, "/im/v1/messages/mget", params: params) do
      {:ok, data} -> {list(data["items"]), nil}
      {:error, reason} -> {[], reason}
    end
  end

  # Names are context only: a chat whose name could not be read keeps its record.
  defp chat_names(_request, []), do: %{}

  defp chat_names(request, chat_ids) do
    case request.(:post, "/im/v1/chats/batch_query",
           params: [user_id_type: "open_id"],
           json: %{"chat_ids" => Enum.uniq(chat_ids)}
         ) do
      {:ok, data} ->
        for %{"chat_id" => id} = chat <- list(data["items"]),
            is_binary(chat["name"]) and chat["name"] != "",
            into: %{},
            do: {id, chat["name"]}

      {:error, _} ->
        %{}
    end
  end

  defp message_record(provider, %{"chat_id" => chat} = message, relation, chat_name)
       when is_binary(chat) do
    text = text(message)
    sender = get_in(message, ["sender", "sender_name"]) || get_in(message, ["sender", "id"])

    if text == "" do
      []
    else
      [
        %{
          "text" => text,
          "permalink" =>
            "#{@applink[provider]}/client/chat/open?openChatId=#{URI.encode_www_form(chat)}",
          "messageTimestamp" => iso(message["create_time"]),
          "memberRelation" => relation,
          "chat" => chat_name,
          "sender" => sender
        }
        |> RecommendationSourceContext.attach(~w(sender chat text), "message")
        |> RecommendationSourceQuote.put(title: chat_name, author: sender, body: {:plain, text})
      ]
    end
  end

  defp message_record(_provider, _message, _relation, _chat_name), do: []

  defp event_record(%{"summary" => summary, "app_link" => link} = event)
       when is_binary(summary) and summary != "" and is_binary(link) do
    if String.starts_with?(link, "https://") do
      [
        %{
          "text" => summary,
          "permalink" => link,
          "start" => iso_seconds(get_in(event, ["start_time", "timestamp"])),
          "end" => iso_seconds(get_in(event, ["end_time", "timestamp"])),
          "memberRelation" => "invited_you"
        }
        |> RecommendationSourceContext.attach(~w(text start end), "calendar_event")
        |> RecommendationSourceQuote.put(title: summary)
      ]
    else
      []
    end
  end

  defp event_record(_event), do: []

  # A text message's mentions are `@_user_N` keys; a post is paragraphs of
  # elements. Other kinds (images, files, cards) have no words to act on.
  defp text(%{"msg_type" => kind, "body" => %{"content" => content}} = message)
       when kind in ~w(text post) and is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        message
        |> mentions()
        |> Enum.reduce(text, fn {key, name}, text -> String.replace(text, key, "@" <> name) end)

      {:ok, %{} = post} ->
        post_text(post)

      _ ->
        ""
    end
    |> String.trim()
    |> String.slice(0, 1_200)
  end

  defp text(_message), do: ""

  defp post_text(%{"content" => paragraphs} = post) when is_list(paragraphs) do
    body =
      Enum.map_join(paragraphs, "\n", fn
        elements when is_list(elements) ->
          Enum.map_join(elements, fn
            %{"tag" => "text", "text" => text} when is_binary(text) -> text
            %{"tag" => "a", "text" => text} when is_binary(text) -> text
            %{"tag" => "at", "user_name" => name} when is_binary(name) -> "@" <> name
            _ -> ""
          end)

        _ ->
          ""
      end)

    case post["title"] do
      title when is_binary(title) and title != "" -> title <> "\n" <> body
      _ -> body
    end
  end

  # A post sent in several languages keys each by its locale.
  defp post_text(post) when is_map(post) do
    case Enum.find(Map.values(post), &match?(%{"content" => [_ | _]}, &1)) do
      nil -> ""
      localized -> post_text(localized)
    end
  end

  defp mentions(message) do
    for %{"key" => key, "name" => name} <- list(message["mentions"]),
        is_binary(key) and is_binary(name),
        do: {key, name}
  end

  defp ids({:ok, ids}) when is_list(ids), do: ids
  defp ids(_read), do: []

  defp list({:ok, items}) when is_list(items), do: items
  defp list(items) when is_list(items), do: items
  defp list(_), do: []

  defp timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> ms
      _ -> 0
    end
  end

  defp timestamp(_value), do: 0

  defp iso(ms) do
    case timestamp(ms) do
      0 -> nil
      value -> value |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    end
  end

  defp iso_seconds(seconds) do
    case timestamp(seconds) do
      0 -> nil
      value -> value |> DateTime.from_unix!() |> DateTime.to_iso8601()
    end
  end
end
