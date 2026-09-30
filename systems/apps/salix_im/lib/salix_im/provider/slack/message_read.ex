defmodule SalixIM.Provider.Slack.MessageRead do
  @moduledoc """
  Agent-facing Slack reads: history, replies, and search.

  History and replies share one request contract with Slack HTTP as a
  fallback. Search is `im_api.slack.search` against the local index only:
  there is no Slack `search.messages` path and no `search:read` scope.
  Mirror-only facts belong on the response: `stale` on a message that has a
  newer undrained observation, and `incomplete` when the request reached a
  range that is not indexed yet.
  """

  import SalixIM.Provider.Util

  alias SalixIM.Provider.Slack.{API, SearchQuery, ThreadHistory}
  alias SalixIM.SlackMessageMirror
  alias SalixIM.SlackMessageMirror.Row
  alias SalixIM.Triage.ClickHouseReader
  alias SalixStore.{SlackMirrorBackfillLedger, SlackMirrorOutbox}

  @max_limit 1_000
  @default_limit 100
  @search_max 200
  @search_default 30
  @search_params ~w(query count cursor sort sort_dir)

  @spec history(term(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def history(_tenant, connect, params) when is_map(connect) and is_map(params) do
    with :ok <- require_fields(params, ["channel"]),
         {:ok, page_opts} <- page_opts(params) do
      serve(:history, connect, str(params["channel"]), nil, params, page_opts)
    end
  end

  @spec replies(term(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def replies(_tenant, connect, params) when is_map(connect) and is_map(params) do
    before_ts = presence(str(params["before_ts"]))
    cursor = presence(str(params["cursor"]))

    with :ok <- require_fields(params, ["channel", "ts"]),
         :ok <- validate_thread_bounds(params, before_ts),
         {:ok, page_opts} <- page_opts(params) do
      opts =
        page_opts
        |> Keyword.put(:cursor, cursor)
        |> Keyword.put(:latest, before_ts || page_opts[:latest])
        |> Keyword.put(:inclusive, if(before_ts, do: false, else: page_opts[:inclusive]))

      serve(:replies, connect, str(params["channel"]), str(params["ts"]), params, opts)
    end
  end

  @spec search(term(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def search(_tenant, connect, params) when is_map(connect) and is_map(params) do
    with :ok <- reject_unknown_search_params(params),
         :ok <- reject_search_flags(params),
         {:ok, parsed} <- SearchQuery.parse(params["query"]),
         {:ok, count} <- search_count(params["count"]),
         {:ok, sort_dir} <- search_sort(params["sort"], params["sort_dir"]),
         {:ok, cursor} <- decode_search_cursor(params["cursor"], sort_dir) do
      after_us = date_us(parsed.after_date)
      opts = search_reader_opts(parsed, count, sort_dir, cursor)

      case mirror_search(connect, opts) do
        {:ok, page} ->
          {:ok, annotate_search(connect, parsed, params["query"], page, after_us, sort_dir)}

        {:error, reason} ->
          {:error, search_error(reason)}
      end
    end
  end

  defp serve(kind, connect, channel, root_ts, params, opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, envelope} <- fetch_page(kind, connect, channel, root_ts, opts) do
      exclude_ts =
        if kind == :replies and
             (params["root_already_preloaded"] == true or presence(str(params["cursor"]))),
           do: str(params["ts"])

      projected =
        ThreadHistory.result(envelope,
          before_ts: presence(str(params["before_ts"])),
          limit: limit,
          exclude_ts: exclude_ts
        )

      projected = annotate(kind, connect, channel, root_ts, projected, envelope, opts[:oldest])

      # Every message here came from the one channel the caller named, so the
      # result carries that channel's audience and needs no per-hit items
      # (docs/verification.md).
      {:ok, put_ifc(projected, SalixIM.IFC.ReadLabels.for_scope(connect, channel))}
    end
  end

  # The block rides out under a reserved key that `SalixAgent.Tools.IMRouter`
  # pops before the result is encoded, so it never reaches the model as content.
  defp put_ifc(projected, nil), do: projected
  defp put_ifc(projected, ifc), do: Map.put(projected, "__ifc__", ifc)

  defp fetch_page(kind, connect, channel, root_ts, opts) do
    case mirror_page(kind, connect, channel, root_ts, opts) do
      :disabled ->
        slack_page(kind, connect, channel, root_ts, opts)

      {:ok, page} ->
        {:ok, page_envelope(page)}

      {:error, reason} ->
        {:error, mirror_error(reason)}
    end
  end

  defp mirror_page(kind, connect, channel, root_ts, opts) do
    reader = ClickHouseReader.impl()

    cond do
      not SlackMessageMirror.enabled?() ->
        :disabled

      not is_atom(reader) ->
        :disabled

      true ->
        _ = Code.ensure_loaded(reader)
        arity = if(kind == :history, do: 2, else: 3)

        if function_exported?(reader, kind, arity) do
          scope = scope(connect, channel)
          opts = Enum.reject(opts, fn {_key, value} -> is_nil(value) or value == "" end)

          case kind do
            :history -> reader.history(scope, opts)
            :replies -> reader.replies(scope, root_ts, opts)
          end
        else
          :disabled
        end
    end
  end

  defp slack_page(kind, connect, channel, root_ts, opts) do
    body =
      %{
        "channel" => channel,
        "limit" => Keyword.fetch!(opts, :limit),
        "cursor" => opts[:cursor],
        "oldest" => opts[:oldest],
        "latest" => opts[:latest],
        "inclusive" => opts[:inclusive]
      }
      |> then(&if(kind == :replies, do: Map.put(&1, "ts", root_ts), else: &1))

    method = if(kind == :history, do: "conversations.history", else: "conversations.replies")
    slack_http(connect, method, body)
  end

  defp page_envelope(%{messages: messages, next_cursor: cursor, has_more?: has_more?}) do
    %{
      "messages" => messages,
      "has_more" => has_more?,
      "response_metadata" => %{"next_cursor" => cursor || ""},
      "source" => :mirror
    }
  end

  defp annotate(kind, connect, channel, root_ts, projected, %{"source" => :mirror}, oldest) do
    scope = scope(connect, channel)
    messages = List.wrap(projected["messages"])
    stale_set = MapSet.new(pending_ts(scope, Enum.map(messages, & &1["ts"])))

    messages =
      Enum.map(messages, fn message ->
        if MapSet.member?(stale_set, message["ts"]),
          do: Map.put(message, "stale", true),
          else: message
      end)

    projected
    |> Map.put("messages", messages)
    |> put_incomplete(kind, scope, root_ts, projected, oldest)
  end

  defp annotate(_kind, _connect, _channel, _root_ts, projected, _envelope, _oldest), do: projected

  defp put_incomplete(projected, kind, scope, root_ts, original, oldest) do
    case SlackMirrorBackfillLedger.watermark(scope) do
      {:ok, watermark} ->
        if older_unindexed?(kind, watermark, original, root_ts, oldest) do
          Map.put(projected, "incomplete", %{
            "reason" => "not_synced",
            "older_than" => slack_ts(watermark["indexed_from_ts_us"])
          })
        else
          projected
        end

      {:error, :not_found} ->
        if original["has_more"] == true do
          projected
        else
          Map.put(projected, "incomplete", %{"reason" => "not_synced"})
        end

      {:error, _reason} ->
        projected
    end
  end

  defp older_unindexed?(:replies, watermark, _projected, root_ts, _oldest) do
    with false <- watermark["exhausted"] == true,
         from when is_integer(from) and from > 0 <- watermark["indexed_from_ts_us"],
         {:ok, root_us} <- Row.slack_ts_micros(root_ts || "") do
      root_us < from
    else
      _other -> false
    end
  end

  defp older_unindexed?(:history, watermark, projected, _root_ts, oldest) do
    from = watermark["indexed_from_ts_us"]

    cond do
      watermark["exhausted"] == true -> false
      projected["has_more"] == true -> false
      not is_integer(from) or from <= 0 -> true
      true -> window_reaches_floor?(oldest, from)
    end
  end

  defp window_reaches_floor?(oldest, from_us) do
    case Row.slack_ts_micros(oldest || "") do
      {:ok, oldest_us} -> oldest_us < from_us
      _missing -> true
    end
  end

  defp pending_ts(scope, ts_list) do
    case SlackMirrorOutbox.pending_message_ts(scope, ts_list) do
      {:ok, pending} -> pending
      {:error, _reason} -> []
    end
  end

  defp page_opts(params) do
    limit =
      case int_or(params["limit"], 0) do
        n when n <= 0 -> @default_limit
        n when n > @max_limit -> @max_limit
        n -> n
      end

    {:ok,
     [
       limit: limit,
       cursor: presence(str(params["cursor"])),
       oldest: presence(str(params["oldest"])),
       latest: presence(str(params["latest"])),
       inclusive: bool?(params["inclusive"])
     ]}
  end

  defp slack_http(connect, method, body) do
    with {:ok, token} <- slack_token(connect) do
      fields =
        body
        |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
        |> Map.new(fn {key, value} -> {key, form_value(value)} end)

      {:ok, API.request_form(token, method, fields)}
    end
  rescue
    e in API.Error -> {:error, API.provider_error_message(e)}
  end

  defp slack_token(connect) do
    case Enum.map(~w(bot_token app_id workspace_id), &str(connect[&1])) do
      [token, _app_id, workspace_id] when token != "" and workspace_id != "" ->
        {:ok, API.installation(connect)}

      _missing ->
        {:error, "Slack connect is not OAuth-complete"}
    end
  end

  defp scope(connect, channel) do
    %{
      "tenant_id" => connect["tenant_id"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => channel
    }
  end

  defp validate_thread_bounds(params, nil) do
    if params["root_already_preloaded"] in [nil, true, false],
      do: :ok,
      else: {:error, "root_already_preloaded must be a boolean"}
  end

  defp validate_thread_bounds(params, before_ts) do
    conflicting =
      ["cursor", "oldest", "latest", "inclusive"]
      |> Enum.filter(fn key ->
        case params[key] do
          nil -> false
          value when is_binary(value) -> str(value) != ""
          _value -> true
        end
      end)

    cond do
      params["root_already_preloaded"] not in [nil, true, false] ->
        {:error, "root_already_preloaded must be a boolean"}

      not ThreadHistory.valid_timestamp?(before_ts) ->
        {:error, "before_ts must be a Slack message timestamp"}

      conflicting == [] ->
        :ok

      true ->
        {:error, "before_ts cannot be combined with #{Enum.join(conflicting, ", ")}"}
    end
  end

  defp require_fields(params, fields) do
    missing = Enum.filter(fields, &(str(params[&1]) == ""))

    if missing == [],
      do: :ok,
      else: {:error, Enum.join(missing, ", ") <> " required"}
  end

  defp mirror_error(:invalid_slack_mirror_read), do: "Slack history read is invalid"
  defp mirror_error(:invalid_slack_mirror_scope), do: "Slack history scope is invalid"
  defp mirror_error(reason), do: "Slack history is unavailable (#{inspect(reason)})"

  defp slack_ts(nil), do: nil

  defp slack_ts(micros) when is_integer(micros) and micros >= 0 do
    seconds = div(micros, 1_000_000)
    fraction = micros |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  defp slack_ts(_other), do: nil

  defp bool?(value) when is_boolean(value), do: value

  defp bool?(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      _other -> false
    end
  end

  defp bool?(_value), do: false

  defp form_value(value) when is_binary(value), do: value
  defp form_value(value) when is_boolean(value), do: to_string(value)
  defp form_value(value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(value), do: to_string(value)

  defp reject_unknown_search_params(params) do
    extra =
      params
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @search_params))

    if extra == [],
      do: :ok,
      else: {:error, "invalid_arguments"}
  end

  defp reject_search_flags(params) do
    cond do
      present?(params["page"]) -> {:error, "invalid_arguments"}
      present?(params["highlight"]) -> {:error, "invalid_arguments"}
      present?(params["backend"]) -> {:error, "invalid_arguments"}
      str(params["cursor"]) == "*" -> {:error, "invalid_arguments"}
      true -> :ok
    end
  end

  defp search_count(value) do
    case int_or(value, 0) do
      n when n <= 0 -> {:ok, @search_default}
      n when n > @search_max -> {:ok, @search_max}
      n -> {:ok, n}
    end
  end

  defp search_sort(sort, sort_dir) do
    sort = String.downcase(str(sort))
    dir = String.downcase(str(sort_dir))

    cond do
      sort in ["score"] ->
        {:error, "sort=score is not supported; sort is timestamp only"}

      sort not in ["", "timestamp"] ->
        {:error, "invalid_arguments"}

      dir not in ["", "asc", "desc"] ->
        {:error, "invalid_arguments"}

      dir == "asc" ->
        {:ok, :asc}

      true ->
        {:ok, :desc}
    end
  end

  defp search_reader_opts(parsed, count, sort_dir, cursor) do
    [
      limit: count,
      patterns: search_patterns(parsed.clauses),
      exclude_patterns: Enum.map(parsed.exclude_terms, &like_pattern/1),
      actor_id: parsed.actor_id,
      channel_id: parsed.channel_id,
      after_us: date_us(parsed.after_date),
      after_date: date_iso(parsed.after_date),
      before_us: date_us(parsed.before_date),
      before_date: date_iso(parsed.before_date),
      has_file: parsed.has_file,
      sort_dir: sort_dir,
      cursor_ts_us: cursor[:ts_us],
      cursor_channel_id: cursor[:channel_id]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
  end

  # One AND-group stays a flat list so existing readers keep a simple bind.
  # Several OR-groups nest: [[a, b], [c]] means (a AND b) OR c.
  defp search_patterns([terms]) when is_list(terms), do: Enum.map(terms, &like_pattern/1)

  defp search_patterns(clauses) when is_list(clauses),
    do: Enum.map(clauses, fn terms -> Enum.map(terms, &like_pattern/1) end)

  defp like_pattern(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  defp date_iso(nil), do: nil
  defp date_iso(%Date{} = date), do: Date.to_iso8601(date)

  defp date_us(nil), do: nil

  defp date_us(%Date{} = date) do
    days = Date.to_gregorian_days(date) - Date.to_gregorian_days(~D[1970-01-01])
    days * 86_400 * 1_000_000
  end

  defp decode_search_cursor(nil, _sort_dir), do: {:ok, nil}
  defp decode_search_cursor("", _sort_dir), do: {:ok, nil}

  defp decode_search_cursor(value, sort_dir) when is_binary(value) do
    dir = if(sort_dir == :asc, do: "a", else: "d")

    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- not String.contains?(decoded, <<0>>),
         [decoded_dir, ts, channel] <- String.split(decoded, ":", parts: 3),
         true <- decoded_dir == dir,
         {ts_us, ""} <- Integer.parse(ts),
         true <- ts_us >= 0,
         true <- channel != "" do
      {:ok, %{ts_us: ts_us, channel_id: channel}}
    else
      _invalid -> {:error, "invalid_arguments"}
    end
  end

  defp decode_search_cursor(_value, _sort_dir), do: {:error, "invalid_arguments"}

  defp encode_search_cursor(nil, _sort_dir), do: ""

  defp encode_search_cursor({ts_us, channel_id}, sort_dir)
       when is_integer(ts_us) and is_binary(channel_id) do
    dir = if(sort_dir == :asc, do: "a", else: "d")
    Base.url_encode64("#{dir}:#{ts_us}:#{channel_id}", padding: false)
  end

  defp encode_search_cursor(_cursor, _sort_dir), do: ""

  defp mirror_search(connect, opts) do
    reader = ClickHouseReader.impl()

    cond do
      not SlackMessageMirror.enabled?() ->
        {:error, :search_unavailable}

      not is_atom(reader) ->
        {:error, :search_unavailable}

      true ->
        _ = Code.ensure_loaded(reader)

        if function_exported?(reader, :search, 2) do
          reader.search(workspace_scope(connect), opts)
        else
          {:error, :search_unavailable}
        end
    end
  end

  defp annotate_search(connect, parsed, query, page, after_us, sort_dir) do
    messages = List.wrap(page.messages)
    stale_set = search_stale_set(connect, parsed.channel_id, messages)

    messages =
      Enum.map(messages, fn message ->
        channel = message["channel"] || parsed.channel_id
        ts = message["ts"]

        if MapSet.member?(stale_set, {channel, ts}),
          do: Map.put(message, "stale", true),
          else: message
      end)

    %{
      "query" => to_string(query || ""),
      "messages" => messages,
      "has_more" => page.has_more? == true,
      "response_metadata" => %{
        "next_cursor" => encode_search_cursor(page.next_cursor, sort_dir)
      }
    }
    |> put_search_incomplete(connect, parsed, after_us)
    # A workspace search is the one read whose hits can span audiences, so each
    # is labelled by the channel it came from and the result's own label is
    # their join (§15). Citing one hit by ref is then exactly as restrictive as
    # that hit, not as its most private neighbour.
    |> put_ifc(SalixIM.IFC.ReadLabels.for_messages(connect, messages))
  end

  defp search_stale_set(connect, channel_id, messages) when is_binary(channel_id) do
    ts_list = Enum.map(messages, & &1["ts"])

    case SlackMirrorOutbox.pending_message_ts(scope(connect, channel_id), ts_list) do
      {:ok, pending} -> MapSet.new(Enum.map(pending, &{channel_id, &1}))
      {:error, _reason} -> MapSet.new()
    end
  end

  defp search_stale_set(connect, _channel_id, messages) do
    pairs =
      messages
      |> Enum.map(&{&1["channel"], &1["ts"]})
      |> Enum.reject(fn {channel, ts} -> channel in [nil, ""] or ts in [nil, ""] end)

    case SlackMirrorOutbox.pending_message_keys(workspace_scope(connect), pairs) do
      {:ok, pending} -> MapSet.new(pending)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp put_search_incomplete(projected, connect, parsed, after_us) do
    after_us = after_us || 0

    case search_watermarks(connect, parsed.channel_id) do
      {:ok, []} ->
        Map.put(projected, "incomplete", %{"reason" => "not_synced"})

      {:ok, watermarks} ->
        holes = Enum.filter(watermarks, &search_hole?(&1, after_us))

        if holes == [] do
          projected
        else
          older =
            holes
            |> Enum.map(& &1["indexed_from_ts_us"])
            |> Enum.filter(&(is_integer(&1) and &1 > 0))
            |> Enum.max(fn -> nil end)

          incomplete = %{"reason" => "not_synced"}

          incomplete =
            if older, do: Map.put(incomplete, "older_than", slack_ts(older)), else: incomplete

          Map.put(projected, "incomplete", incomplete)
        end

      {:error, :not_found} ->
        Map.put(projected, "incomplete", %{"reason" => "not_synced"})

      {:error, _reason} ->
        projected
    end
  end

  defp search_watermarks(connect, channel_id) when is_binary(channel_id) do
    case SlackMirrorBackfillLedger.watermark(scope(connect, channel_id)) do
      {:ok, watermark} -> {:ok, [watermark]}
      {:error, _reason} = error -> error
    end
  end

  defp search_watermarks(connect, _channel_id) do
    SlackMirrorBackfillLedger.list_watermarks(workspace_scope(connect))
  end

  defp search_hole?(watermark, after_us) do
    from = watermark["indexed_from_ts_us"]

    watermark["exhausted"] != true and
      (not is_integer(from) or from <= 0 or from > after_us)
  end

  defp workspace_scope(connect) do
    %{
      "tenant_id" => connect["tenant_id"],
      "workspace_id" => connect["workspace_id"]
    }
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp search_error(:search_unavailable),
    do: "Slack search is unavailable (message index is not configured)"

  defp search_error(:invalid_slack_mirror_read), do: "Slack search is invalid"
  defp search_error(:invalid_slack_mirror_scope), do: "Slack search scope is invalid"

  defp search_error({:read_over_budget, _detail}),
    do: "Slack search is unavailable; narrow with in:, from:, after:, or a longer keyword"

  defp search_error(reason), do: "Slack search is unavailable (#{inspect(reason)})"
end
