defmodule SalixMeet.CommaProvider do
  @moduledoc """
  Google Meet meetings a person sends in a Comma chat.

  The Router's `meeting.join` tool is the only entry. The bot joins as a
  guest. Status and the notes go back to the same Conversation as messages of
  the Router, through `SalixMeet.Ports.CommaChat`.
  """

  alias SalixMeet.{MeetingState, OwnerAttributionSnapshot, Runtime, RuntimeEvents, Store}
  alias SalixMeet.Ports.CommaChat
  alias SalixStore.{Crypto, S3}

  @meet_url ~r|https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[^\s<>()\[\]]*)?|iu
  @default_bot_name "Cirno"
  @mandarin "Chinese, Mandarin (Simplified)"
  @english "English"
  @outcomes ~w(admission_denied meeting_full removed_from_meeting admission_timeout)

  @doc """
  Execute one Router-authorized join of the Google Meet in a person's Comma message.

  `source` is string-keyed: `tenant_id`, `group_id`, `conversation_id`,
  `message_id`, `user_id`, `agent_id` (the Router, who writes the status),
  `language` and `text`, all from the committed message. A `meet_url` in
  `params` must be one of the message's links. While a Meeting of the same
  Meet runs for the same Conversation, a later request reuses it.
  """
  @spec join_from_router(map(), map()) :: {:ok, map()} | {:error, term()}
  def join_from_router(source, params) when is_map(source) and is_map(params) do
    with true <-
           SalixMeet.RuntimeDriver.configured?() || {:error, :meeting_runtime_not_configured},
         {:ok, url} <- requested_url(meet_urls(source["text"]), trim(params["meet_url"])) do
      case find_active_meeting(source, url) do
        nil -> join_new(source, url)
        meeting_id -> rejoin(source, url, meeting_id)
      end
    end
  end

  # A running Meeting is reused, and its join is asked again: once dispatched
  # that changes nothing, and after a failed dispatch it is the store's gated
  # retry. A Meeting that ended or gave up its join meanwhile gives way to a
  # new one for this message.
  defp rejoin(source, url, meeting_id) do
    case request_meeting_join(meeting_id) do
      :ok -> {:ok, result(meeting_id, false)}
      {:error, reason} when reason in [:terminal_meeting, :abandoned] -> join_new(source, url)
      {:error, _} = error -> error
    end
  end

  defp join_new(source, url) do
    with {:ok, meeting_agent} <- Runtime.start_for_group(source["tenant_id"], source["group_id"]),
         {:ok, meeting_id, state, created?} <-
           create_meeting(source, comma_ref(source), url, meeting_agent),
         :ok <- put_source_index(source, url, meeting_id),
         :ok <- start(meeting_id, state, created?) do
      {:ok, result(meeting_id, created?)}
    end
  end

  defp result(meeting_id, created?),
    do: %{
      "meeting_id" => meeting_id,
      "status" => if(created?, do: "joining", else: "already_active"),
      "provider" => "comma"
    }

  defp requested_url([], _requested), do: {:error, :meet_url_not_in_current_source}
  defp requested_url([url], ""), do: {:ok, url}
  defp requested_url(_urls, ""), do: {:error, :ambiguous_meet_urls}

  defp requested_url(urls, requested),
    do:
      if(requested in urls, do: {:ok, requested}, else: {:error, :meet_url_not_in_current_source})

  defp meet_urls(text) when is_binary(text),
    do: Regex.scan(@meet_url, text) |> List.flatten() |> Enum.uniq()

  defp meet_urls(_text), do: []

  defp create_meeting(source, ref, url, meeting_agent) do
    meeting_id = meeting_id(source, url)
    now = SystemsClock.system_time(:second)

    with {:ok, state} <-
           MeetingState.new_comma(meeting_id, meeting_agent, %{
             "tenant_id" => source["tenant_id"],
             "group_id" => source["group_id"],
             "connect_id" => "",
             "comma_ref" => ref,
             "meet_url" => url,
             "title" => "Google Meet",
             "bot_name" =>
               SystemsRuntime.get_env(:salix_meet, :default_bot_name, @default_bot_name),
             "caption_language" => caption_language(source["text"], ref["language"]),
             "start_at" => now,
             "end_at" => now + 3600,
             "runtime_source" => SalixMeet.MeetingRuntimePolicy.default_source(),
             "join_as" => "guest",
             "source" => %{"message_id" => ref["message_id"], "user_id" => ref["user_id"]}
           }) do
      case Store.create_once(meeting_id, state: state) do
        {:ok, _doc, _etag} ->
          {:ok, meeting_id, state, true}

        {:error, :exists} ->
          with {:ok, %{"state" => existing}, _etag} <- Store.get(meeting_id),
               do: {:ok, meeting_id, stringify(existing), false}

        {:error, _} = error ->
          error
      end
    end
  end

  # The join is asked for an existing Meeting of this message too, so a retry
  # after a failed request reaches the runtime instead of stopping at the
  # stored Meeting.
  defp start(meeting_id, state, created?) do
    if created?,
      do: post(state, "meeting:#{meeting_id}:joining", text(:joining, language(state)))

    request_meeting_join(meeting_id)
  end

  defp request_meeting_join(meeting_id) do
    with :ok <- ensure_meeting_process(meeting_id), do: request_join(meeting_id, 5)
  end

  defp request_join(_meeting_id, 0), do: {:error, :meeting_join_not_leader}

  defp request_join(meeting_id, attempts) do
    case SalixMeet.Meeting.join(meeting_id) do
      {:ok, _joined_at} ->
        :ok

      {:error, :join_in_progress} ->
        :ok

      {:error, reason} when reason in [:not_leader, :not_running] ->
        SystemsClock.sleep(10)
        request_join(meeting_id, attempts - 1)

      {:error, _} = error ->
        error
    end
  end

  defp ensure_meeting_process(meeting_id) do
    case SalixMeet.Application.start_meeting(meeting_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _pid}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp find_active_meeting(source, url) do
    with {:ok, %{body: body}} <- S3.get(source_index_key(source, url)),
         {:ok, %{"meeting_id" => meeting_id}} <- Jason.decode(body),
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         true <- active_same_chat?(stringify(state), source, url) do
      meeting_id
    else
      _ -> nil
    end
  end

  defp active_same_chat?(state, source, url) do
    state["provider"] == "comma" and state["tenant_id"] == source["tenant_id"] and
      state["group_id"] == source["group_id"] and
      get_in(state, ["comma_ref", "conversation_id"]) == trim(source["conversation_id"]) and
      meeting_code(state["meet_url"]) == meeting_code(url) and
      state["status"] not in RuntimeEvents.terminal_statuses()
  end

  defp put_source_index(source, url, meeting_id) do
    record = %{
      "group_id" => source["group_id"],
      "conversation_id" => trim(source["conversation_id"]),
      "meeting_code" => meeting_code(url),
      "meeting_id" => meeting_id,
      "updated_at" => SystemsClock.system_time(:second)
    }

    case S3.put(source_index_key(source, url), Jason.encode!(record)) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  defp source_index_key(source, url) do
    digest =
      Crypto.hex([
        trim(source["tenant_id"]),
        <<0>>,
        trim(source["group_id"]),
        <<0>>,
        trim(source["conversation_id"]),
        <<0>>,
        meeting_code(url)
      ])

    "meet/sources/comma/#{trim(source["group_id"])}/#{digest}.json"
  end

  defp meeting_code(url) do
    case Regex.run(~r|meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})|iu, trim(url)) do
      [_, code] -> String.downcase(code)
      _ -> ""
    end
  end

  defp meeting_id(source, url) do
    digest =
      Crypto.hex([
        "comma30-comma-meeting-v1",
        <<0>>,
        trim(source["tenant_id"]),
        <<0>>,
        trim(source["group_id"]),
        <<0>>,
        trim(source["conversation_id"]),
        <<0>>,
        trim(source["message_id"]),
        <<0>>,
        url
      ])
      |> binary_part(0, 24)

    "mtg-" <> digest
  end

  defp comma_ref(source) do
    %{
      "conversation_id" => trim(source["conversation_id"]),
      "message_id" => trim(source["message_id"]),
      "user_id" => trim(source["user_id"]),
      "agent_id" => trim(source["agent_id"]),
      "language" => if(source["language"] == "zh-CN", do: "zh-CN", else: "en")
    }
  end

  @doc false
  def notify_status(meeting_id, state, event)
      when is_binary(meeting_id) and is_map(state) and is_map(event) do
    event = stringify(event)

    case status_text(event, language(state)) do
      nil ->
        :ok

      {status, text} ->
        with {:ok, _message} <- post(state, "meeting:#{meeting_id}:status:#{status}", text),
             do: :ok
    end
  end

  @doc "Terminal meeting publication used by `SalixMeet.ProviderDispatcher`."
  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(_meeting_agent, payload) when is_map(payload) do
    payload = stringify(payload)
    meeting_id = trim(payload["meeting_id"])
    claim = stringify(payload["delivery_claim"] || %{})

    with {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         state = stringify(state),
         true <- state["provider"] == "comma" || {:error, :not_comma_meeting},
         :ok <- check_claim(meeting_id, claim) do
      if payload["kind"] == "summary_generating",
        do: {:ok, %{"status_set" => false}},
        else: publish_terminal(meeting_id, state, claim)
    else
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = error -> error
    end
  end

  defp publish_terminal(meeting_id, state, claim) do
    delivery = stringify(state["delivery"] || %{})

    with :ok <- post_notes(meeting_id, state, claim, delivery),
         {:ok, _doc, _etag} <-
           Store.checkpoint_delivery(meeting_id, claim, %{
             "provider" => "comma",
             "status" => "published",
             "published_at" => SystemsClock.system_time(:second)
           }) do
      {:ok, %{"published" => true}}
    end
  end

  defp post_notes(_meeting_id, _state, _claim, %{"comma_notes" => _}), do: :ok

  defp post_notes(meeting_id, state, claim, _delivery) do
    with {:ok, _message} <-
           post(state, "meeting:#{meeting_id}:notes", terminal_text(state, language(state))),
         {:ok, _doc, _etag} <-
           Store.checkpoint_delivery(meeting_id, claim, %{"comma_notes" => "sent"}),
         do: :ok
  end

  defp check_claim(_meeting_id, claim) when claim == %{}, do: :ok
  defp check_claim(meeting_id, claim), do: Store.check_delivery_claim(meeting_id, claim)

  defp post(state, key, text) do
    ref = stringify(state["comma_ref"] || %{})

    CommaChat.post(
      trim(state["group_id"]),
      ref["conversation_id"],
      ref["agent_id"],
      key,
      text
    )
  end

  defp status_text(%{"type" => "status", "status" => "error", "reason_code" => code}, lang)
       when code in @outcomes,
       do: {"error", outcome_text(code, lang)}

  defp status_text(%{"type" => "status", "status" => "waiting_room"}, lang),
    do: {"waiting_room", text(:waiting_room, lang)}

  defp status_text(%{"type" => "status", "status" => "in_meeting"}, lang),
    do: {"in_meeting", text(:in_meeting, lang)}

  defp status_text(%{"type" => "status", "status" => "left"}, lang),
    do: {"left", text(:left, lang)}

  defp status_text(%{"type" => "status", "status" => "error"} = event, lang),
    do: {"error", text({:join_error, first_nonblank([event["message"], event["error"]])}, lang)}

  defp status_text(_event, _lang), do: nil

  defp text(:joining, "zh-CN"), do: "正在以访客身份加入 Google Meet…"
  defp text(:joining, _), do: "Joining the Google Meet as a guest…"
  defp text(:waiting_room, "zh-CN"), do: "等待主持人批准入会。"
  defp text(:waiting_room, _), do: "Waiting for a host to admit me."
  defp text(:in_meeting, "zh-CN"), do: "已加入会议。"
  defp text(:in_meeting, _), do: "Joined the meeting."
  defp text(:left, "zh-CN"), do: "已离开会议，正在生成纪要…"
  defp text(:left, _), do: "Left the meeting. Preparing the notes…"

  # The runtime's reason is English, so the Chinese text leaves it out.
  defp text({:join_error, _reason}, "zh-CN"), do: "无法加入会议。请重新发送会议链接再试。"
  defp text({:join_error, ""}, _), do: "Could not join the meeting. Send the link again to retry."

  defp text({:join_error, reason}, _),
    do: "Could not join the meeting: #{reason}. Send the link again to retry."

  defp outcome_text("admission_denied", "zh-CN"), do: "入会请求被拒绝。"
  defp outcome_text("admission_denied", _), do: "The request to join was denied."
  defp outcome_text("meeting_full", "zh-CN"), do: "会议人数已满，无法加入。"
  defp outcome_text("meeting_full", _), do: "The meeting is full, so I could not join."
  defp outcome_text("removed_from_meeting", "zh-CN"), do: "已被移出会议。"
  defp outcome_text("removed_from_meeting", _), do: "I was removed from the meeting."
  defp outcome_text("admission_timeout", "zh-CN"), do: "等待超时，没有人批准入会。"
  defp outcome_text("admission_timeout", _), do: "Nobody admitted me before the wait ended."
  defp outcome_text(_code, _lang), do: nil

  defp terminal_text(%{"status" => "failed", "watchdog" => %{"reason" => "runtime_lost"}}, lang),
    do:
      if(lang == "zh-CN",
        do: "会议记录不完整：会议进程在结束前丢失，所以没有纪要。",
        else:
          "The meeting record is incomplete: the meeting runtime was lost, so there are no notes."
      )

  defp terminal_text(%{"status" => "failed", "reason_code" => code} = state, lang)
       when code in @outcomes do
    if SalixMeet.Outcome.partial_recording?(state),
      do:
        if(lang == "zh-CN",
          do: "已被移出会议，会议记录不完整，所以没有纪要。",
          else: "I was removed from the meeting. The record is incomplete, so there are no notes."
        ),
      else: outcome_text(code, lang)
  end

  defp terminal_text(%{"status" => "failed"} = state, lang),
    do:
      if(lang == "zh-CN",
        do: "会议处理失败：" <> first_nonblank([state["error"], "未知错误"]),
        else:
          "The meeting could not be processed: " <>
            first_nonblank([state["error"], "unknown error"])
      )

  defp terminal_text(%{"status" => "cancelled"}, "zh-CN"), do: "会议已取消。"
  defp terminal_text(%{"status" => "cancelled"}, _), do: "The meeting was cancelled."

  defp terminal_text(state, lang) do
    summary =
      state
      |> OwnerAttributionSnapshot.current()
      |> OwnerAttributionSnapshot.bound_summary(stringify(state["summary"] || %{}))
      |> stringify()

    title = first_nonblank([summary["title"], state["title"], "Meeting"])
    labels = labels(lang)

    ["### #{labels.notes}#{title}"]
    |> maybe_line(outcome_text(state["reason_code"], lang))
    |> section(labels.key_points, summary["key_points"], &bullet/1)
    |> section(labels.action_items, summary["action_items"], &action_item(&1, labels))
    |> section(labels.decisions, summary["decisions"], &bullet/1)
    |> section(labels.open_questions, summary["open_questions"], &bullet/1)
    |> section(labels.blockers, summary["blockers"], &bullet/1)
    |> Enum.join("\n")
  end

  defp labels("zh-CN"),
    do: %{
      notes: "会议纪要：",
      key_points: "要点",
      action_items: "待办",
      decisions: "决定",
      open_questions: "待解决问题",
      blockers: "阻碍",
      owner: "负责人",
      due: "截止"
    }

  defp labels(_),
    do: %{
      notes: "Meeting notes: ",
      key_points: "Key points",
      action_items: "Action items",
      decisions: "Decisions",
      open_questions: "Open questions",
      blockers: "Blockers",
      owner: "Owner",
      due: "Due"
    }

  defp maybe_line(lines, nil), do: lines
  defp maybe_line(lines, line), do: lines ++ ["", line]

  defp section(lines, label, [_ | _] = values, formatter),
    do: lines ++ ["", "**#{label}**"] ++ Enum.map(values, formatter)

  defp section(lines, _label, _values, _formatter), do: lines

  defp bullet(value) when is_map(value),
    do: "- " <> first_nonblank([value["text"], value["title"], value["description"]])

  defp bullet(value), do: "- " <> trim(value)

  defp action_item(item, labels) when is_map(item) do
    owner = first_nonblank([item["owner"], item["assignee"]])
    due = first_nonblank([item["deadline"], item["due_date"], item["due"]])

    [
      first_nonblank([item["description"], item["text"], item["task"]]),
      if(owner != "", do: "#{labels.owner}: #{owner}"),
      if(due != "", do: "#{labels.due}: #{due}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
    |> then(&("- " <> &1))
  end

  defp action_item(value, _labels), do: bullet(value)

  defp language(state), do: get_in(stringify(state), ["comma_ref", "language"]) || "en"

  defp caption_language(text, language) do
    han = Regex.scan(~r/\p{Han}/u, trim(text)) |> length()
    latin = Regex.scan(~r/[A-Za-z]/u, @meet_url |> Regex.replace(trim(text), "")) |> length()

    cond do
      han >= 4 and han > latin -> @mandarin
      latin >= 8 -> @english
      language == "zh-CN" -> @mandarin
      true -> @english
    end
  end

  defp first_nonblank(values),
    do:
      Enum.find_value(values, "", fn value ->
        if(trim(value) == "", do: nil, else: trim(value))
      end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
