defmodule SalixIM.DailyBriefSource do
  @moduledoc """
  Read-only Slack source for the BFT daily brief.

  Only public, non-shared, unarchived channels that the connect's bot belongs
  to are readable. Message text comes from the Salix Slack mirror; this module
  never reads Slack history, mutates Slack, or returns a credential. Every
  read checks the active connect and the channel's current audience first.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects
  alias SalixIM.SlackMessageMirror
  alias SalixIM.Triage.ClickHouseReader
  alias SalixStore.SlackMirrorBackfillLedger

  @channel_page_limit 200
  @max_channel_pages 10
  @max_members 50
  @max_window_limit 200
  @max_thread_channels 2_000
  # Enough for a month of an active person's messages.
  @max_thread_pages 15
  @max_emails 50

  @type error ::
          :invalid_request
          | :source_unavailable
          | :source_authority_unavailable
          | :channel_ineligible
          | {:rate_limited, pos_integer()}

  @doc """
  The bot's readable channels, and for each listed member the public channels
  the member is in that the bot is not (the coverage gap).
  """
  @spec channels(map()) :: {:ok, map()} | {:error, error()}
  def channels(%{member_slack_ids: member_ids} = request)
      when is_list(member_ids) and length(member_ids) <= @max_members do
    with {:ok, connect} <- fetch_connect(request) do
      token = SlackAPI.installation(connect)

      with {:ok, bot_channels, bot_complete?} <- list_channels(token, []) do
        # users.conversations lists only the bot's own channels and omits is_member.
        readable = Enum.filter(bot_channels, &public_unshared?/1)
        readable_ids = MapSet.new(readable, & &1["id"])

        gaps =
          Map.new(member_ids, fn member_id ->
            case member_channels(token, member_id) do
              {:ok, channels, complete?} ->
                missing =
                  channels
                  |> Enum.filter(&public_unshared?/1)
                  |> Enum.reject(&MapSet.member?(readable_ids, &1["id"]))
                  |> Enum.map(&channel_view/1)

                {member_id, %{channels: missing, complete?: complete?}}

              {:error, _reason} ->
                {member_id, %{channels: [], complete?: false}}
            end
          end)

        {:ok,
         %{
           workspace_id: connect["workspace_id"],
           channels: Enum.map(readable, &channel_view/1),
           complete?: bot_complete?,
           gaps: gaps
         }}
      end
    end
  rescue
    error in SlackAPI.Error -> provider_error(error)
  end

  def channels(_request), do: {:error, :invalid_request}

  # One member's failure (a rate limit, a deactivated user) leaves that
  # member's gap unknown instead of failing every member.
  defp member_channels(token, member_id) do
    list_channels(token, user: member_id)
  rescue
    _error in SlackAPI.Error -> {:error, :unavailable}
  end

  @doc """
  One page of a channel's current messages in `[after_us, before_us)`, oldest
  first, threads included. Edited messages carry their current text; deleted
  messages are absent.
  """
  @spec read_window(map()) :: {:ok, map()} | {:error, error()}
  def read_window(
        %{channel_id: channel_id, after_us: after_us, before_us: before_us, limit: limit} =
          request
      )
      when is_binary(channel_id) and is_integer(after_us) and is_integer(before_us) and
             after_us >= 0 and before_us > after_us and is_integer(limit) and
             limit in 1..@max_window_limit do
    with {:ok, connect} <- fetch_connect(request),
         :ok <- channel_readable(connect, channel_id),
         scope = scope(connect),
         :ok <- archive_covers(Map.put(scope, "channel_id", channel_id), after_us),
         {:ok, page} <-
           search(
             scope,
             [
               channel_id: channel_id,
               after_us: after_us,
               after_date: date(after_us),
               before_us: before_us,
               before_date: date(before_us + 86_400_000_000),
               sort_dir: :asc,
               limit: limit
             ] ++ cursor_opts(request[:cursor])
           ) do
      {:ok,
       %{
         messages: Enum.map(page.messages, &message_view/1),
         next_cursor: cursor_view(page.next_cursor),
         has_more?: page.has_more?
       }}
    end
  rescue
    error in SlackAPI.Error -> provider_error(error)
  end

  def read_window(_request), do: {:error, :invalid_request}

  @doc """
  The current state of named messages in one readable channel, at most 200,
  oldest first. Deleted and unknown messages are absent. The daily brief's
  shared scan names them, so a member's pass reads only its own messages.
  """
  @spec messages(map()) :: {:ok, map()} | {:error, error()}
  def messages(%{channel_id: channel_id, ts: ts} = request)
      when is_binary(channel_id) and is_list(ts) and length(ts) in 1..@max_window_limit do
    with {:ok, keys} <- ts_keys(ts),
         {:ok, connect} <- fetch_connect(request),
         :ok <- channel_readable(connect, channel_id),
         {:ok, rows} <-
           latest_states(Map.put(scope(connect), "channel_id", channel_id), keys) do
      {:ok,
       %{
         messages:
           rows
           |> Map.values()
           |> Enum.reject(&(&1["deleted"] == true))
           |> Enum.sort_by(& &1["message_ts_us"])
           |> Enum.map(&row_view/1)
       }}
    end
  rescue
    error in SlackAPI.Error -> provider_error(error)
  end

  def messages(_request), do: {:error, :invalid_request}

  @doc """
  Thread coordinates (channel and thread ts, no text) where the member wrote
  since `after_us`, limited to the channels the caller names. The caller
  passes the readable channels from `channels/1` of the same run. `complete?`
  is false when the bounded pages ran out.
  """
  @spec member_threads(map()) :: {:ok, map()} | {:error, error()}
  def member_threads(
        %{slack_user_id: user_id, channel_ids: channel_ids, after_us: after_us} = request
      )
      when is_binary(user_id) and is_list(channel_ids) and
             length(channel_ids) <= @max_thread_channels and is_integer(after_us) do
    with {:ok, connect} <- fetch_connect(request),
         {:ok, messages, complete?} <- own_messages(scope(connect), user_id, after_us, nil, 1, []) do
      allowed = MapSet.new(channel_ids)

      threads =
        messages
        |> Enum.filter(&MapSet.member?(allowed, &1["channel"]))
        |> Enum.map(fn message ->
          {message["channel"], present(message["thread_ts"]) || message["ts"]}
        end)
        |> Enum.uniq()
        |> Enum.map(fn {channel_id, thread_ts} ->
          %{channel_id: channel_id, thread_ts: thread_ts}
        end)

      {:ok, %{threads: threads, complete?: complete?}}
    end
  end

  def member_threads(_request), do: {:error, :invalid_request}

  # The member's own messages, newest first, a page at a time up to
  # `@max_thread_pages` pages.
  defp own_messages(scope, user_id, after_us, cursor, page_number, acc) do
    with {:ok, page} <-
           search(
             scope,
             [
               actor_id: user_id,
               after_us: after_us,
               after_date: date(after_us),
               sort_dir: :desc,
               limit: @max_window_limit
             ] ++ cursor_opts(cursor_view(cursor))
           ) do
      acc = acc ++ page.messages

      cond do
        not page.has_more? or is_nil(page.next_cursor) -> {:ok, acc, true}
        page_number >= @max_thread_pages -> {:ok, acc, false}
        true -> own_messages(scope, user_id, after_us, page.next_cursor, page_number + 1, acc)
      end
    end
  end

  @doc """
  Resolves BFT emails to Slack members of the connect's workspace. Deleted,
  bot, and guest users are not returned.
  """
  @spec lookup_members(map()) :: {:ok, map()} | {:error, error()}
  def lookup_members(%{emails: emails} = request)
      when is_list(emails) and length(emails) <= @max_emails do
    with {:ok, connect} <- fetch_connect(request) do
      token = SlackAPI.installation(connect)

      {:ok,
       emails
       |> Enum.map(&normalize_email/1)
       |> Enum.uniq()
       |> Enum.reduce(%{}, fn email, acc ->
         case lookup(token, connect, email) do
           {:ok, member} -> Map.put(acc, email, member)
           :error -> acc
         end
       end)}
    end
  rescue
    error in SlackAPI.Error -> provider_error(error)
  end

  def lookup_members(_request), do: {:error, :invalid_request}

  @doc """
  The names Slack shows for users of the connect's workspace, by user id. At
  most 200; a user Slack cannot read is left out.
  """
  @spec user_names(map()) :: {:ok, %{String.t() => String.t()}} | {:error, error()}
  def user_names(%{user_ids: ids} = request) when is_list(ids) and length(ids) <= 200 do
    with {:ok, connect} <- fetch_connect(request) do
      names =
        for id <- Enum.uniq(ids),
            is_binary(id) and Regex.match?(~r/^[UW][A-Z0-9]{2,32}$/, id),
            profile = SalixIM.ProviderHTTP.slack_api_user_profile(connect, id),
            name = profile["user_display_name"] || profile["user_real_name"],
            is_binary(name) and name != "",
            into: %{},
            do: {id, name}

      {:ok, names}
    end
  end

  def user_names(_request), do: {:error, :invalid_request}

  @doc "Permalinks for messages in readable channels, from the bot. At most 50."
  @spec permalinks(map()) :: {:ok, map()} | {:error, error()}
  def permalinks(%{messages: messages} = request)
      when is_list(messages) and length(messages) <= 50 do
    with {:ok, connect} <- fetch_connect(request) do
      token = SlackAPI.installation(connect)

      readable =
        messages
        |> Enum.map(& &1.channel_id)
        |> Enum.uniq()
        |> Enum.filter(&(channel_readable(connect, &1) == :ok))
        |> MapSet.new()

      {:ok,
       messages
       |> Enum.filter(&MapSet.member?(readable, &1.channel_id))
       |> Enum.reduce(%{}, fn %{channel_id: channel_id, ts: ts}, acc ->
         case permalink(token, channel_id, ts) do
           nil -> acc
           url -> Map.put(acc, {channel_id, ts}, url)
         end
       end)}
    end
  rescue
    error in SlackAPI.Error -> provider_error(error)
  end

  def permalinks(_request), do: {:error, :invalid_request}

  @doc false
  def permalink(token, channel_id, ts) do
    token
    |> SlackAPI.request_form("chat.getPermalink", channel: channel_id, message_ts: ts)
    |> Map.get("permalink")
  rescue
    _error in SlackAPI.Error -> nil
  end

  defp fetch_connect(%{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id})
       when is_binary(tenant_id) and is_binary(group_id) and is_binary(connect_id) do
    case ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack") do
      {:ok, %{"tenant_id" => ^tenant_id} = connect} -> {:ok, connect}
      {:ok, _other_tenant} -> {:error, :source_unavailable}
      {:error, :not_found} -> {:error, :source_unavailable}
      {:error, _reason} -> {:error, :source_authority_unavailable}
    end
  end

  defp fetch_connect(_request), do: {:error, :invalid_request}

  defp list_channels(token, opts) do
    Enum.reduce_while(1..@max_channel_pages, {[], nil}, fn page, {acc, cursor} ->
      result =
        SlackAPI.list_user_conversation_page(
          token,
          [
            limit: @channel_page_limit,
            cursor: cursor,
            types: ["public_channel"],
            exclude_archived: true
          ] ++ opts
        )

      acc = acc ++ result["channels"]

      cond do
        blank?(result["next_cursor"]) -> {:halt, {:ok, acc, true}}
        page == @max_channel_pages -> {:halt, {:ok, acc, false}}
        true -> {:cont, {acc, result["next_cursor"]}}
      end
    end)
  end

  @doc false
  # A public, non-shared channel the bot is in: the only kind a brief reads
  # or posts the team brief to.
  def channel_readable(connect, channel_id) do
    channel = SlackAPI.conversation_info(SlackAPI.installation(connect), channel_id)

    if channel["id"] == channel_id and readable?(channel),
      do: :ok,
      else: {:error, :channel_ineligible}
  end

  defp readable?(channel), do: channel["is_member"] == true and public_unshared?(channel)

  defp public_unshared?(channel) do
    is_binary(channel["id"]) and channel["is_private"] != true and channel["is_archived"] != true and
      channel["is_im"] != true and channel["is_mpim"] != true and channel["is_shared"] != true and
      channel["is_ext_shared"] != true and channel["is_org_shared"] != true and
      channel["is_pending_ext_shared"] != true
  end

  defp archive_covers(scope, after_us) do
    with true <- SlackMessageMirror.enabled?(),
         {:ok, watermark} <- SlackMirrorBackfillLedger.watermark(scope),
         true <-
           watermark["exhausted"] == true or
             (is_integer(watermark["indexed_from_ts_us"]) and
                watermark["indexed_from_ts_us"] <= after_us) do
      :ok
    else
      _unavailable -> {:error, :source_unavailable}
    end
  end

  defp search(scope, opts) do
    reader = ClickHouseReader.impl()

    if is_atom(reader) and not is_nil(reader) and SystemsRuntime.Proc.ensure_loaded?(reader) and
         function_exported?(reader, :search, 2) do
      case reader.search(scope, opts) do
        {:ok, page} -> {:ok, page}
        {:error, _reason} -> {:error, :source_unavailable}
      end
    else
      {:error, :source_unavailable}
    end
  end

  defp latest_states(scope, keys) do
    reader = ClickHouseReader.impl()

    if is_atom(reader) and not is_nil(reader) and SystemsRuntime.Proc.ensure_loaded?(reader) and
         function_exported?(reader, :latest_states, 2) do
      case reader.latest_states(scope, keys) do
        {:ok, rows} -> {:ok, rows}
        {:error, _reason} -> {:error, :source_unavailable}
      end
    else
      {:error, :source_unavailable}
    end
  end

  # Slack ts "1792700000.000100" is the mirror's microsecond key.
  defp ts_keys(ts) do
    keys =
      Enum.map(ts, fn
        value when is_binary(value) ->
          case Regex.run(~r/^(\d{1,12})\.(\d{6})$/, value) do
            [_, seconds, micros] ->
              String.to_integer(seconds) * 1_000_000 + String.to_integer(micros)

            nil ->
              nil
          end

        _other ->
          nil
      end)

    if Enum.all?(keys, &is_integer/1),
      do: {:ok, Enum.uniq(keys)},
      else: {:error, :invalid_request}
  end

  defp scope(connect),
    do: %{"tenant_id" => connect["tenant_id"], "workspace_id" => connect["workspace_id"]}

  defp lookup(token, connect, email) do
    user =
      token
      |> SlackAPI.request_form("users.lookupByEmail", [email: email],
        timeout_ms: 1_000,
        pool_retries: 0
      )
      |> Map.get("user", %{})

    if is_binary(user["id"]) and Regex.match?(~r/^[UW][A-Z0-9]+$/, user["id"]) and
         user["team_id"] == connect["workspace_id"] and
         normalize_email(get_in(user, ["profile", "email"]) || "") == email and
         not Enum.any?(
           ~w(deleted is_bot is_app_user is_restricted is_ultra_restricted),
           &(user[&1] == true)
         ) do
      profile = user["profile"] || %{}

      {:ok,
       %{
         slack_user_id: user["id"],
         workspace_id: connect["workspace_id"],
         timezone: present(user["tz"]) || "Etc/UTC",
         names:
           [profile["display_name"], profile["real_name"], user["real_name"], user["name"]]
           |> Enum.map(&present/1)
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
       }}
    else
      :error
    end
  rescue
    _error in SlackAPI.Error -> :error
  end

  defp channel_view(channel), do: %{id: channel["id"], name: channel["name"]}

  # The mirror serves Slack-shaped messages, with the channel added.
  defp message_view(message) do
    bot? = present(message["bot_id"]) != nil or message["subtype"] == "bot_message"

    %{
      channel_id: message["channel"],
      ts: message["ts"],
      thread_ts: present(message["thread_ts"]),
      actor_kind: if(bot?, do: "bot", else: "user"),
      actor_id: present(message["user"]) || present(message["bot_id"]),
      subtype: present(message["subtype"]),
      text: message["text"] || ""
    }
  end

  # A mirror row, in the same shape as `message_view/1`.
  defp row_view(row) do
    %{
      channel_id: row["channel_id"],
      ts: row["message_ts"],
      thread_ts: present(row["thread_ts"]),
      actor_kind:
        if(row["actor_kind"] in ["bot", "app"] or row["subtype"] == "bot_message",
          do: "bot",
          else: "user"
        ),
      actor_id: present(row["actor_id"]),
      subtype: present(row["subtype"]),
      text: row["text"] || ""
    }
  end

  defp cursor_opts(%{ts_us: ts_us, channel_id: channel_id})
       when is_integer(ts_us) and is_binary(channel_id),
       do: [cursor_ts_us: ts_us, cursor_channel_id: channel_id]

  defp cursor_opts(_cursor), do: []

  defp cursor_view({ts_us, channel_id}), do: %{ts_us: ts_us, channel_id: channel_id}
  defp cursor_view(_cursor), do: nil

  defp date(us),
    do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp provider_error(%SlackAPI.Error{retry_after: seconds})
       when is_integer(seconds) and seconds > 0,
       do: {:error, {:rate_limited, seconds}}

  defp provider_error(_error), do: {:error, :source_unavailable}

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  defp blank?(value), do: is_nil(present(value))
end
