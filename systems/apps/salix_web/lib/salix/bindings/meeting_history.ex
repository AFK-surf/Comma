defmodule Salix.Bindings.MeetingHistory do
  @moduledoc "Link-only history for the explicitly configured, public team preparation channel or group chat."

  alias SalixIM.Provider.Feishu.API, as: FeishuAPI
  alias SalixIM.Provider.Lark.API, as: LarkAPI
  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixMeet.Store
  alias SalixStore.{MeetingGroupProjectionReadiness, MeetingGroupProjections}

  @lark_chat_id ~r/\Aoc_[A-Za-z0-9_-]{1,125}\z/
  @feishu_domains ~w(feishu.cn)
  @lark_domains ~w(larksuite.com larkoffice.com)

  # A Dashboard role is not a Slack or Feishu/Lark identity. Do not return
  # private-channel metadata or use the bot's membership as the viewer's
  # membership. The existing group configuration identifies the shared team
  # channel or public group chat. The platform checks the human's access when
  # they open a source link. This read never returns a summary, transcript,
  # preview, token, or storage URL.
  def list(group, settings, cursor) do
    with {:ok, connect, channel} <- shared_channel(group, settings),
         true <- MeetingGroupProjectionReadiness.ready?(),
         {:ok, page} <- MeetingGroupProjections.list_group_page(group["group_id"], cursor),
         {:ok, meetings} <- read_page(page.meeting_ids, group, connect, channel) do
      {:ok,
       %{
         "meetings" => Enum.sort_by(meetings, &(&1["start_ms"] || 0), :desc),
         "next_cursor" => page.next_cursor,
         "channel" => channel["name"],
         "provider" => connect["provider"]
       }}
    else
      false -> {:error, :meeting_source_unsealed}
      {:error, _} = error -> error
    end
  rescue
    _ in [API.Error, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :meeting_history_unavailable}
  end

  defp shared_channel(group, settings) do
    with connect_id when is_binary(connect_id) <- settings["connect_id"],
         channel_id when is_binary(channel_id) and channel_id != "" <-
           settings["channel_id"] || settings["chat_id"],
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group["group_id"], connect_id),
         true <- connect["tenant_id"] == group["tenant_id"],
         {:ok, channel} <- public_channel(connect, channel_id) do
      {:ok, connect, channel}
    else
      _ -> {:error, :meeting_history_scope_unavailable}
    end
  end

  defp public_channel(%{"provider" => "slack"} = connect, channel_id) do
    case API.conversation_info(API.installation(connect), channel_id) do
      %{"id" => ^channel_id, "is_private" => false, "is_member" => true} = channel ->
        if channel["is_im"] != true and channel["is_mpim"] != true,
          do: {:ok, channel},
          else: {:error, :meeting_history_scope_unavailable}

      _ ->
        {:error, :meeting_history_scope_unavailable}
    end
  end

  defp public_channel(%{"provider" => provider, "status" => "connected"} = connect, chat_id)
       when provider in ~w(feishu lark) do
    api = lark_api(provider)
    encoded = URI.encode(chat_id, &URI.char_unreserved?/1)

    with true <- Regex.match?(@lark_chat_id, chat_id),
         {:ok, %{} = info} <- api.get(connect, "/im/v1/chats/#{encoded}"),
         true <-
           info["chat_mode"] in ["group", "topic"] and
             info["chat_type"] == "public" and
             info["external"] != true and
             info["chat_status"] in [nil, "normal"],
         {:ok, %{"is_in_chat" => true}} <-
           api.get(connect, "/im/v1/chats/#{encoded}/members/is_in_chat") do
      {:ok, %{"id" => chat_id, "name" => present_or_nil(info["name"]) || chat_id}}
    else
      _ -> {:error, :meeting_history_scope_unavailable}
    end
  end

  defp public_channel(_connect, _channel_id), do: {:error, :meeting_history_scope_unavailable}

  # At most 20 authoritative state reads and one provider channel lookup per
  # requested page. No polling, deployment-wide scan, or per-meeting RPC.
  defp read_page(ids, group, connect, channel) do
    ids
    |> SystemsClock.async_stream(
      fn id ->
        case Store.get_indexed(id) do
          {:ok, %{"id" => ^id, "state" => state} = doc, _} ->
            {:ok, record(doc, state, group, connect, channel)}

          {:error, :not_found} ->
            {:ok, nil}

          _ ->
            {:error, :meeting_history_unavailable}
        end
      end,
      max_concurrency: 8,
      timeout: 2_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, nil}}, acc -> {:cont, acc}
      {:ok, {:ok, record}}, {:ok, records} -> {:cont, {:ok, [record | records]}}
      _, _ -> {:halt, {:error, :meeting_history_unavailable}}
    end)
  end

  defp record(doc, state, group, connect, channel) do
    provider = connect["provider"]

    if state["tenant_id"] == group["tenant_id"] and
         state["group_id"] == group["group_id"] and
         state["provider"] == provider and
         state["connect_id"] == connect["connect_id"] and
         channel_matches?(provider, state, channel["id"]) and
         state["status"] in ~w(processing done failed cancelled) do
      provider_record(provider, doc, state, connect, channel)
    end
  end

  defp provider_record("slack", doc, state, connect, channel) do
    delivery = state["delivery"] || %{}
    audio = safe_slack_url(get_in(delivery, ["artifacts", "audio", "permalink"]))
    canvas = safe_slack_url(delivery["canvas_url"])
    published = delivery["published_at"] not in [nil, "", false]
    canvas_shared = get_in(delivery, ["canvas_access", "status"]) in ~w(granted link_shared)

    %{
      "meeting_id" => doc["id"],
      "title" => state["title"],
      "status" => state["status"],
      "start_ms" => start_ms(state["start_at"], doc["created_at"]),
      "recording_url" => audio,
      "recording_status" => recording_status(state, delivery, audio),
      "canvas_url" => if(published or canvas_shared, do: canvas),
      "thread_url" => thread_url(connect["workspace_id"], channel["id"], state),
      "channel" => channel["name"]
    }
  end

  defp provider_record(provider, doc, state, _connect, channel)
       when provider in ~w(feishu lark) do
    delivery = state["delivery"] || %{}
    links = lark_links(provider, state)
    minute = links["minute"]
    note = links["note"]

    %{
      "meeting_id" => doc["id"],
      "title" => state["title"],
      "status" => state["status"],
      "start_ms" => start_ms(state["start_at"], doc["created_at"]),
      "recording_url" => minute,
      "recording_status" => recording_status(state, delivery, minute),
      "canvas_url" => note,
      "thread_url" => lark_chat_link(provider, channel["id"]),
      "channel" => channel["name"]
    }
  end

  defp channel_matches?("slack", state, channel_id),
    do: get_in(state, ["slack_ref", "channel_id"]) == channel_id

  defp channel_matches?("feishu", state, chat_id),
    do: get_in(state, ["feishu_ref", "chat_id"]) == chat_id

  defp channel_matches?("lark", state, chat_id),
    do: get_in(state, ["lark_ref", "chat_id"]) == chat_id

  defp channel_matches?(_provider, _state, _channel_id), do: false

  defp lark_links(provider, state) do
    bot = if is_map(state["lark_bot"]), do: state["lark_bot"], else: %{}

    bot["links"]
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      %{"kind" => kind, "url" => url}, acc when kind in ~w(minute note) ->
        case safe_lark_url(provider, url) do
          nil -> acc
          safe -> Map.put_new(acc, kind, safe)
        end

      _other, acc ->
        acc
    end)
  end

  defp lark_chat_link(provider, chat_id) do
    base =
      if provider == "feishu",
        do: "https://applink.feishu.cn",
        else: "https://applink.larksuite.com"

    base <> "/client/chat/open?" <> URI.encode_query(openChatId: chat_id)
  end

  defp lark_api("feishu"), do: FeishuAPI
  defp lark_api("lark"), do: LarkAPI

  defp recording_status(_state, _delivery, url) when is_binary(url), do: "available"
  defp recording_status(%{"status" => "processing"}, _delivery, _url), do: "pending"

  defp recording_status(state, delivery, _url) do
    if is_map(state["artifacts"]) and Map.has_key?(state["artifacts"], "audio") do
      if delivery["status"] in ~w(pending publishing retrying),
        do: "processing",
        else: "unavailable"
    else
      "not_recorded"
    end
  end

  defp start_ms(seconds, _created) when is_integer(seconds), do: seconds * 1000
  defp start_ms(_seconds, created) when is_integer(created), do: created
  defp start_ms(_, _), do: nil

  defp thread_url(workspace_id, channel_id, state) do
    thread = get_in(state, ["slack_ref", "thread_ts"])

    if is_binary(workspace_id) and Regex.match?(~r/\AT[A-Z0-9]+\z/, workspace_id) and
         Regex.match?(~r/\AC[A-Z0-9]+\z/, channel_id) and is_binary(thread) and
         Regex.match?(~r/\A[0-9]+\.[0-9]+\z/, thread) do
      "https://app.slack.com/client/#{workspace_id}/#{channel_id}/thread/#{channel_id}-#{thread}"
    end
  end

  defp safe_slack_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443} when is_binary(host) ->
        if host == "slack.com" or String.ends_with?(host, ".slack.com"), do: url

      _ ->
        nil
    end
  end

  defp safe_slack_url(_url), do: nil

  defp safe_lark_url(provider, url) when is_binary(url) do
    domains = if provider == "feishu", do: @feishu_domains, else: @lark_domains

    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443} = uri
      when is_binary(host) and host != "" ->
        host = String.downcase(host)

        if Enum.any?(domains, &(host == &1 or String.ends_with?(host, "." <> &1))),
          do: URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp safe_lark_url(_provider, _url), do: nil

  defp present_or_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_or_nil(_value), do: nil
end
