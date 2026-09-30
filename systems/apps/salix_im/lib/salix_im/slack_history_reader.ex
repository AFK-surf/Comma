defmodule SalixIM.SlackHistoryReader do
  @moduledoc """
  Read-only, one-page Slack mirror boundary for BFT sourced-context imports.

  Every archive query is fenced by the exact active connect identity before
  and after transport. Channel audience authority is likewise read before and
  after the page. The module returns only a bounded normalized envelope: it
  never publishes product context, calls a model, mutates Slack, or exposes an
  installation credential.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixIM.ProviderConnects
  alias SalixIM.SlackMessageMirror
  alias SalixIM.Triage.CanonicalJSON
  alias SalixIM.Triage.ClickHouseReader
  alias SalixStore.SlackMirrorBackfillLedger

  @page_limit 15
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/
  @stream_kinds ~w(history replies)

  @type read_error ::
          :invalid_request
          | :source_unavailable
          | :source_authority_unavailable
          | :stale_source
          | :channel_ineligible
          | :channel_authority_changed
          | :invalid_cursor
          | :invalid_provider_page
          | {:rate_limited, pos_integer()}

  @doc "Returns a credential-free source/channel authority snapshot for run creation."
  @spec source_authority(map()) :: {:ok, map()} | {:error, read_error()}
  def source_authority(request) when is_map(request) do
    with {:ok, identity} <- normalize_identity_request(request),
         {:ok, connect} <- fetch_connect(identity, :pre),
         {:ok, channel} <- read_channel_authority(connect, identity.channel_id),
         {:ok, current} <- fetch_connect(identity, :post),
         :ok <- same_connect(connect, current),
         {:ok, current_channel} <- read_channel_authority(current, identity.channel_id),
         :ok <- same_channel(channel, current_channel) do
      {:ok,
       %{
         tenant_id: identity.tenant_id,
         group_id: identity.group_id,
         connect_id: connect["connect_id"],
         connect_generation: connect["connect_generation"],
         workspace_id: connect["workspace_id"],
         app_id: connect["app_id"],
         channel: current_channel
       }}
    end
  rescue
    error in SlackAPI.Error -> translate_provider_error(error)
    _error in ArgumentError -> {:error, :source_unavailable}
  end

  def source_authority(_request), do: {:error, :invalid_request}

  @doc "Reads exactly one bounded history or replies page under pinned authority."
  @spec read_page(map()) :: {:ok, map()} | {:error, read_error()}
  def read_page(request) when is_map(request) do
    with {:ok, page_request} <- normalize_page_request(request),
         {:ok, before_connect} <- fetch_connect(page_request, :pre),
         :ok <- expected_connect(before_connect, page_request),
         {:ok, before_channel} <-
           read_channel_authority(before_connect, page_request.channel_id),
         :ok <- expected_channel(before_channel, page_request),
         {:ok, messages, next_cursor} <- read_archive_page(before_connect, page_request),
         messages <- drop_repeated_reply_parent(messages, page_request),
         {:ok, normalized_messages} <- normalize_messages(messages),
         {:ok, after_connect} <- fetch_connect(page_request, :post),
         :ok <- expected_connect(after_connect, page_request),
         :ok <- same_connect(before_connect, after_connect),
         {:ok, after_channel} <-
           read_channel_authority(after_connect, page_request.channel_id),
         :ok <- expected_channel(after_channel, page_request),
         :ok <- same_channel(before_channel, after_channel),
         {:ok, next_cursor} <- normalize_cursor(next_cursor) do
      envelope =
        build_envelope(
          page_request,
          normalized_messages,
          next_cursor,
          after_connect["connect_generation"],
          after_channel.authority_revision
        )

      {:ok, Map.put(envelope, :response_sha256, page_sha256(envelope))}
    end
  rescue
    error in SlackAPI.Error -> translate_provider_error(error)
    _error in ArgumentError -> {:error, :source_unavailable}
  end

  def read_page(_request), do: {:error, :invalid_request}

  defp normalize_identity_request(request) do
    with {:ok, tenant_id} <- nonblank(value(request, :tenant_id)),
         {:ok, group_id} <- nonblank(value(request, :group_id)),
         {:ok, connect_id} <- nonblank(value(request, :connect_id)),
         {:ok, channel_id} <- nonblank(value(request, :channel_id)) do
      {:ok,
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         connect_id: connect_id,
         channel_id: channel_id
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp normalize_page_request(request) do
    with {:ok, identity} <- normalize_identity_request(request),
         {:ok, expected_connect_generation} <-
           nonblank(value(request, :expected_connect_generation)),
         {:ok, expected_workspace_id} <- nonblank(value(request, :expected_workspace_id)),
         {:ok, expected_app_id} <- nonblank(value(request, :expected_app_id)),
         {:ok, expected_channel_authority_revision} <-
           sha256(value(request, :expected_channel_authority_revision)),
         {:ok, stream_kind} <- stream_kind(value(request, :stream_kind)),
         {:ok, root_ts} <- root_ts(stream_kind, value(request, :root_ts)),
         {:ok, page_ordinal} <- nonnegative_integer(value(request, :page_ordinal)),
         {:ok, cursor} <- normalize_cursor(value(request, :cursor)),
         {:ok, resume_boundary} <- optional_provider_slack_ts(value(request, :resume_boundary)),
         %DateTime{} = range_start <- value(request, :range_start),
         %DateTime{} = range_end <- value(request, :range_end),
         true <- DateTime.compare(range_start, range_end) == :lt do
      {:ok,
       Map.merge(identity, %{
         expected_connect_generation: expected_connect_generation,
         expected_workspace_id: expected_workspace_id,
         expected_app_id: expected_app_id,
         expected_channel_authority_revision: expected_channel_authority_revision,
         stream_kind: stream_kind,
         root_ts: root_ts,
         page_ordinal: page_ordinal,
         cursor: cursor,
         resume_boundary: resume_boundary,
         range_start: range_start,
         range_end: range_end
       })}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp fetch_connect(request, phase) do
    case ProviderConnects.get_active_connect_by_id(
           request.group_id,
           request.connect_id,
           "slack"
         ) do
      {:ok, connect} ->
        if connect["tenant_id"] == request.tenant_id,
          do: {:ok, connect},
          else: {:error, :stale_source}

      {:error, :not_found} when phase == :post ->
        {:error, :stale_source}

      {:error, :not_found} ->
        {:error, :source_unavailable}

      {:error, _reason} ->
        {:error, :source_authority_unavailable}
    end
  end

  defp expected_connect(connect, request) do
    if connect_identity(connect) == %{
         tenant_id: request.tenant_id,
         group_id: request.group_id,
         connect_id: request.connect_id,
         connect_generation: request.expected_connect_generation,
         workspace_id: request.expected_workspace_id,
         app_id: request.expected_app_id
       },
       do: :ok,
       else: {:error, :stale_source}
  end

  defp same_connect(before_connect, after_connect) do
    if connect_identity(before_connect) == connect_identity(after_connect),
      do: :ok,
      else: {:error, :stale_source}
  end

  defp connect_identity(connect) do
    %{
      tenant_id: connect["tenant_id"],
      group_id: connect["group_id"],
      connect_id: connect["connect_id"],
      connect_generation: connect["connect_generation"],
      workspace_id: connect["workspace_id"],
      app_id: connect["app_id"]
    }
  end

  defp read_channel_authority(connect, channel_id) do
    channel = SlackAPI.conversation_info(SlackAPI.installation(connect), channel_id)

    with true <- channel["id"] == channel_id,
         true <- channel["is_member"],
         false <- channel["is_private"],
         false <- channel["is_archived"],
         false <- channel["is_shared"],
         false <- channel["is_ext_shared"],
         false <- channel["is_org_shared"],
         name when is_binary(name) and name != "" <- channel["name"] do
      authority = %{
        "channel_id" => channel_id,
        "is_archived" => false,
        "is_ext_shared" => channel["is_ext_shared"] == true,
        "is_member" => true,
        "is_org_shared" => channel["is_org_shared"] == true,
        "is_private" => false,
        "is_shared" => channel["is_shared"] == true
      }

      {:ok,
       %{
         id: channel_id,
         is_member: true,
         name: name,
         visibility: "public",
         authority_revision: canonical_sha256(authority)
       }}
    else
      _ineligible -> {:error, :channel_ineligible}
    end
  end

  defp expected_channel(channel, request) do
    if channel.authority_revision == request.expected_channel_authority_revision,
      do: :ok,
      else: {:error, :channel_authority_changed}
  end

  defp same_channel(before_channel, after_channel) do
    if before_channel.authority_revision == after_channel.authority_revision,
      do: :ok,
      else: {:error, :channel_authority_changed}
  end

  # Reuse the shared archive and its write-after-ack coverage ledger. This
  # read never schedules backfill or falls back to Slack history. Missing
  # coverage uses the existing bounded source-unavailable pause/retry path.
  defp read_archive_page(connect, request) do
    scope = %{
      "tenant_id" => connect["tenant_id"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => request.channel_id
    }

    with :ok <- archive_ready(scope, request),
         :ok <- archive_cursor(request.cursor) do
      archive_page(scope, request)
    end
  end

  defp archive_ready(scope, request) do
    lower_bound =
      if request.stream_kind == "replies",
        do: slack_datetime!(request.root_ts),
        else: request.range_start

    with true <- SlackMessageMirror.enabled?(),
         {:ok, watermark} <- SlackMirrorBackfillLedger.watermark(scope),
         true <-
           watermark["exhausted"] == true or
             (is_integer(watermark["indexed_from_ts_us"]) and
                watermark["indexed_from_ts_us"] <= DateTime.to_unix(lower_bound, :microsecond)) do
      :ok
    else
      _unavailable -> {:error, :source_unavailable}
    end
  end

  defp archive_cursor(nil), do: :ok

  defp archive_cursor(cursor) do
    case provider_slack_ts(cursor) do
      {:ok, _timestamp} -> :ok
      _invalid -> {:error, :invalid_cursor}
    end
  end

  defp archive_page(scope, request) do
    reader = ClickHouseReader.impl()
    kind = if request.stream_kind == "history", do: :history, else: :replies
    arity = if kind == :history, do: 2, else: 3

    if is_atom(reader) and not is_nil(reader) and Code.ensure_loaded?(reader) and
         function_exported?(reader, kind, arity) do
      query_archive(reader, kind, scope, request)
    else
      {:error, :source_unavailable}
    end
  end

  defp query_archive(reader, kind, scope, request) do
    case provider_bounds(request) do
      :exhausted ->
        {:ok, [], nil}

      {oldest, latest} ->
        opts = [
          cursor: request.cursor,
          oldest: slack_ts(oldest),
          latest: slack_ts(latest),
          inclusive: true,
          limit: @page_limit
        ]

        result =
          case kind do
            :history -> reader.history(scope, opts)
            :replies -> reader.replies(scope, request.root_ts, opts)
          end

        case result do
          {:ok, %{messages: messages, next_cursor: cursor, has_more?: has_more?}}
          when is_boolean(has_more?) ->
            with {:ok, cursor} <- normalize_cursor(cursor),
                 :ok <- archive_cursor(cursor),
                 true <- has_more? == not is_nil(cursor) do
              {:ok, messages, cursor}
            else
              _invalid -> {:error, :invalid_provider_page}
            end

          {:error, _reason} ->
            {:error, :source_unavailable}

          _invalid ->
            {:error, :invalid_provider_page}
        end
    end
  end

  # Slack conversations.replies repeats the thread parent on every page. The
  # parent is already authoritative in the history stream; accepting its later
  # reply_count/edit view under the same source identity would turn a normal
  # non-transactional Slack read into an object conflict. Reply pages therefore
  # contribute replies only.
  defp drop_repeated_reply_parent(messages, %{stream_kind: "replies", root_ts: root_ts})
       when is_list(messages) do
    Enum.reject(messages, &(&1["ts"] == root_ts))
  end

  defp drop_repeated_reply_parent(messages, _request), do: messages

  defp provider_bounds(request) do
    oldest = request.range_start
    latest = DateTime.add(request.range_end, -1, :microsecond)

    {oldest, latest} =
      case {request.stream_kind, request.resume_boundary} do
        {_stream, nil} ->
          {oldest, latest}

        {"history", boundary} ->
          {oldest,
           min_datetime(latest, DateTime.add(slack_datetime!(boundary), -1, :microsecond))}

        {"replies", boundary} ->
          {max_datetime(oldest, DateTime.add(slack_datetime!(boundary), 1, :microsecond)), latest}
      end

    if DateTime.compare(oldest, latest) in [:lt, :eq],
      do: {oldest, latest},
      else: :exhausted
  end

  defp min_datetime(left, right),
    do: if(DateTime.compare(left, right) == :gt, do: right, else: left)

  defp max_datetime(left, right),
    do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  defp slack_datetime!(timestamp) do
    [seconds, microseconds] = String.split(timestamp, ".", parts: 2)

    unix_microseconds =
      String.to_integer(seconds) * 1_000_000 +
        String.to_integer(String.pad_trailing(microseconds, 6, "0"))

    DateTime.from_unix!(unix_microseconds, :microsecond)
  end

  defp normalize_messages(messages) when is_list(messages) and length(messages) <= @page_limit do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_message(message) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_messages(_messages), do: {:error, :invalid_provider_page}

  defp normalize_message(message) when is_map(message) do
    with {:ok, message_ts} <- provider_slack_ts(message["ts"]),
         {:ok, thread_ts} <- optional_provider_slack_ts(message["thread_ts"]),
         {:ok, actor_id, actor_kind} <- actor(message),
         text when is_binary(text) <- message["text"] || "",
         text <- String.trim(text),
         true <- byte_size(text) <= 40_000,
         {:ok, reply_count} <- reply_count(message["reply_count"]),
         {:ok, file_metadata} <- file_metadata(message["files"] || []) do
      {:ok,
       %{
         "message_ts" => message_ts,
         "thread_ts" => thread_ts,
         "actor_id" => actor_id,
         "actor_kind" => actor_kind,
         "text" => text,
         "observable_version" => observable_version(message),
         "reply_count" => reply_count,
         "file_metadata" => file_metadata
       }}
    else
      _invalid -> {:error, :invalid_provider_page}
    end
  end

  defp normalize_message(_message), do: {:error, :invalid_provider_page}

  defp actor(%{"user" => user}) when is_binary(user) and user != "",
    do: {:ok, user, "user"}

  defp actor(%{"bot_id" => bot_id}) when is_binary(bot_id) and bot_id != "",
    do: {:ok, bot_id, "bot"}

  defp actor(%{"app_id" => app_id}) when is_binary(app_id) and app_id != "",
    do: {:ok, app_id, "app"}

  defp actor(message) do
    unknown_ref =
      message
      |> Map.take(["subtype", "username", "team"])
      |> canonical_sha256()

    {:ok, "unknown:" <> unknown_ref, "unknown"}
  end

  defp observable_version(%{"edited" => %{"ts" => edited_ts}})
       when is_binary(edited_ts) and edited_ts != "",
       do: "edited:" <> edited_ts

  defp observable_version(_message), do: "original"

  defp reply_count(nil), do: {:ok, 0}
  defp reply_count(value) when is_integer(value) and value in 0..1_000, do: {:ok, value}
  defp reply_count(_value), do: {:error, :invalid_provider_page}

  defp file_metadata(files) when is_list(files) and length(files) <= 10 do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      with true <- is_map(file),
           id when is_binary(id) and id != "" <- file["id"],
           true <- is_nil(file["name"]) or is_binary(file["name"]),
           true <- is_nil(file["mimetype"]) or is_binary(file["mimetype"]),
           true <-
             is_nil(file["size"]) or
               (is_integer(file["size"]) and file["size"] >= 0) do
        normalized = %{
          "id" => id,
          "name" => file["name"],
          "mimetype" => file["mimetype"],
          "size" => file["size"]
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        _invalid -> {:halt, {:error, :invalid_provider_page}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp file_metadata(_files), do: {:error, :invalid_provider_page}

  defp build_envelope(request, messages, next_cursor, generation, channel_revision) do
    %{
      channel_id: request.channel_id,
      stream_kind: request.stream_kind,
      root_ts: request.root_ts,
      page_ordinal: request.page_ordinal,
      request_cursor: request.cursor,
      next_cursor: next_cursor,
      stream_complete: is_nil(next_cursor),
      accepted_connect_generation: generation,
      accepted_channel_authority_revision: channel_revision,
      observed_at: DateTime.utc_now(),
      messages: messages
    }
  end

  defp page_sha256(envelope) do
    canonical_sha256(%{
      "messages" => envelope.messages,
      "next_cursor" => envelope.next_cursor || "",
      "stream_complete" => envelope.stream_complete
    })
  end

  defp canonical_sha256(value),
    do: value |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

  defp translate_provider_error(%SlackAPI.Error{retry_after: seconds})
       when is_integer(seconds) and seconds > 0,
       do: {:error, {:rate_limited, seconds * 1_000}}

  defp translate_provider_error(%SlackAPI.Error{message: "invalid_cursor"}),
    do: {:error, :invalid_cursor}

  defp translate_provider_error(%SlackAPI.Error{}), do: {:error, :source_unavailable}

  defp stream_kind(kind) when kind in @stream_kinds, do: {:ok, kind}
  defp stream_kind(_kind), do: {:error, :invalid_request}

  defp root_ts("history", value) when value in [nil, ""], do: {:ok, ""}
  defp root_ts("replies", value), do: provider_slack_ts(value)
  defp root_ts(_kind, _value), do: {:error, :invalid_request}

  defp provider_slack_ts(value) when is_binary(value) do
    if Regex.match?(@slack_ts, value), do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp provider_slack_ts(_value), do: {:error, :invalid_request}
  defp optional_provider_slack_ts(nil), do: {:ok, nil}
  defp optional_provider_slack_ts(""), do: {:ok, nil}
  defp optional_provider_slack_ts(value), do: provider_slack_ts(value)

  defp normalize_cursor(nil), do: {:ok, nil}
  defp normalize_cursor(""), do: {:ok, nil}

  defp normalize_cursor(value) when is_binary(value) and byte_size(value) <= 1_024 do
    if value == String.trim(value), do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp normalize_cursor(_value), do: {:error, :invalid_request}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative_integer(_value), do: {:error, :invalid_request}

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      normalized -> {:ok, normalized}
    end
  end

  defp nonblank(_value), do: {:error, :invalid_request}

  defp sha256(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(@sha256, value), do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp sha256(_value), do: {:error, :invalid_request}

  defp slack_ts(datetime) do
    unix_microseconds = DateTime.to_unix(datetime, :microsecond)
    seconds = div(unix_microseconds, 1_000_000)
    microseconds = rem(unix_microseconds, 1_000_000)
    "#{seconds}.#{microseconds |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
