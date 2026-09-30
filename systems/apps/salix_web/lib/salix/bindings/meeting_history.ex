defmodule Salix.Bindings.MeetingHistory do
  @moduledoc "Link-only history for the explicitly configured, public team preparation channel."

  alias SalixIM.Provider.Slack.API
  alias SalixIM.ProviderConnects
  alias SalixMeet.Store
  alias SalixStore.{MeetingGroupProjectionReadiness, MeetingGroupProjections}

  # A Dashboard role is not a Slack identity. Do not return private-channel
  # metadata or use the bot's channel membership as the viewer's membership.
  # The existing group configuration identifies the shared team channel.
  # Slack checks the human's access when they open a source link. This read
  # never returns a summary, transcript, preview, token, or storage URL.
  def list(group, settings, cursor) do
    with {:ok, connect, channel} <- shared_channel(group, settings),
         true <- MeetingGroupProjectionReadiness.ready?(),
         {:ok, page} <- MeetingGroupProjections.list_group_page(group["group_id"], cursor),
         {:ok, meetings} <- read_page(page.meeting_ids, group, connect, channel) do
      {:ok,
       %{
         "meetings" => Enum.sort_by(meetings, &(&1["start_ms"] || 0), :desc),
         "next_cursor" => page.next_cursor,
         "channel" => channel["name"]
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
         channel_id when is_binary(channel_id) and channel_id != "" <- settings["channel_id"],
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(group["group_id"], connect_id, "slack"),
         true <- connect["tenant_id"] == group["tenant_id"],
         %{"id" => ^channel_id, "is_private" => false, "is_member" => true} = channel <-
           API.conversation_info(API.installation(connect), channel_id),
         true <- channel["is_im"] != true and channel["is_mpim"] != true do
      {:ok, connect, channel}
    else
      _ -> {:error, :meeting_history_scope_unavailable}
    end
  end

  # At most 20 authoritative state reads and one provider channel lookup per
  # requested page. No polling, deployment-wide scan, or per-meeting RPC.
  defp read_page(ids, group, connect, channel) do
    ids
    |> Task.async_stream(
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
    if state["tenant_id"] == group["tenant_id"] and
         state["group_id"] == group["group_id"] and state["provider"] == "slack" and
         state["connect_id"] == connect["connect_id"] and
         get_in(state, ["slack_ref", "channel_id"]) == channel["id"] and
         state["status"] in ~w(processing done failed cancelled) do
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
  end

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
end
