defmodule SalixMeet.LarkBot do
  @moduledoc """
  The bot of a Lark or Feishu app in a video meeting of its platform. Feishu
  sends the same events and answers the same OpenAPI as Lark
  (`SalixIM.Provider.Lark.MeetingBot`), so one path serves both; the connect's
  provider names the platform.

  A person invites the bot from the meeting. `vc.bot.meeting_invited_v1` makes
  one Meeting per invitation, owned by the connect's Group, and the bot joins
  with `bots/join`. The inviter's private chat with the bot is the Meeting's
  Lark or Feishu target, so status and the summary go to the inviter alone. Several
  meetings of a connect run side by side.

  No runtime is dispatched: Lark holds the bot in the meeting. The Meeting's
  leader reads `bots/events` on its tick (`poll/1`, the only way Lark gives a
  transcript to an app that keeps no socket per meeting), and the page cursor
  and the text it read are one write of the Meeting. Lark resends a sentence as
  it grows, so `sentence_id` replaces the sentence's earlier text, and
  `revised_at` tells the copilot when the text last changed.

  The copilot answers in the meeting (`send_chat/4`). Lark gives the bot its own
  message back as chat: that record is `outgoing`, so neither the copilot nor the
  summary reads it as a participant's.

  A calendar meeting with a Feishu/Lark link is joined the same way, by its
  meeting number (`join_scheduled/1`, from `SalixMeet.JoinDispatch`). Its
  Meeting belongs to the Group's meeting settings: status and the summary go
  to their destination (a Slack, Feishu or Lark chat), and `lark_bot` names
  the bot's own connect. A meeting not started yet, or one whose settings
  refuse the bot for now, leaves the join pending for the next calendar pass;
  a refusal tells the destination once why, and what the host can change. A
  meeting the bot is already in through an invitation stays one Meeting.

  A Meeting ends on `vc.bot.meeting_ended_v1`, on a meeting end time in
  `bots/events`, or when `bots/events` says the bot is out: a host removing the
  bot sends no ended event. Any other failure says nothing about the meeting.
  The summary then follows the path of every Meeting (`SalixMeet.Delivery`).
  """

  @behaviour SalixIM.Ports.LarkMeetingBot

  require Logger

  alias SalixIM.Provider.Lark.MeetingBot, as: LarkMeetingBot
  alias SalixMeet.{MeetingState, RuntimeEvents, Runtime, Store}
  alias SalixStore.{Crypto, S3}

  @source "lark_bot"
  @default_caption_language "Chinese, Mandarin (Simplified)"
  @pages_per_poll 5
  # How long a bot that Lark does not count as a participant yet may wait to be
  # admitted, in seconds.
  @admission_wait_s 600
  # A quiet meeting still records that the bot was seen (`last_seen_live_at`,
  # the watchdog's anchor), at most this often, in seconds.
  @seen_interval_s 300
  # A meeting whose settings refused the bot is asked again at most this
  # often, in seconds; one not started yet on every calendar join pass.
  @blocked_retry_s 300
  # bots/join answers. A meeting not started cannot hold a waiting bot.
  @not_started 121_014
  @gone [121_004, 121_005]
  @blocked %{
    121_003 => "app_permission",
    121_006 => "meeting_full",
    121_007 => "bot_busy",
    121_008 => "meeting_locked",
    121_009 => "password",
    121_010 => "password",
    121_011 => "password",
    121_012 => "password",
    121_013 => "no_permission",
    121_015 => "security_policy",
    121_016 => "ai_summary_off"
  }
  @links_label %{"minute" => {"Minutes", "妙记"}, "note" => {"AI notes", "智能纪要"}}

  def source, do: @source

  @spec bot_meeting?(map()) :: boolean()
  def bot_meeting?(state) when is_map(state), do: state["runtime_source"] == @source

  @doc "Whether the Meeting still needs its leader to read Lark."
  @spec live?(map() | nil) :: boolean()
  def live?(%{"state" => %{"runtime_source" => @source, "status" => status}}),
    do: status in ~w(active processing)

  def live?(_doc), do: false

  @doc "A live Meeting whose process went away with its node gets one again."
  @spec resume(String.t(), map()) :: :ok
  def resume(meeting_id, doc) do
    if live?(doc) and SystemsRuntime.Registry.lookup(SalixMeet.Registry, meeting_id) == [] do
      _ = SalixMeet.Application.start_meeting(meeting_id)
    end

    :ok
  end

  # ---- events of the Lark app ----

  @impl true
  def handle_event(connect, %{"header" => %{"event_type" => "vc.bot.meeting_invited_v1"}} = env),
    do: invited(connect, map(env["event"]), env)

  def handle_event(connect, %{"header" => %{"event_type" => "vc.bot.meeting_ended_v1"}} = env),
    do: ended(connect, map(env["event"]))

  def handle_event(_connect, _envelope), do: {:ignored, :event_not_routed}

  defp invited(connect, event, envelope) do
    meeting = map(event["meeting"])
    meeting_no = text(meeting["meeting_no"])
    lark_meeting_id = LarkMeetingBot.meeting_id(meeting["id"])
    inviter = LarkMeetingBot.open_id(event["inviter"])
    call_id = text(event["call_id"])

    cond do
      meeting_no == "" or inviter == "" ->
        {:error, :invalid_envelope}

      running?(connect, lark_meeting_id) or running_number?(connect, meeting_no) ->
        {:ok, :duplicate}

      true ->
        id = meeting_id(connect, meeting_no, lark_meeting_id, call_id)

        attrs = %{
          meeting_no: meeting_no,
          lark_meeting_id: lark_meeting_id,
          inviter: inviter,
          call_id: call_id,
          title: first_nonblank([meeting["topic"], default_title(connect)]),
          event_id: text(map(envelope["header"])["event_id"]),
          tenant_key: text(map(envelope["header"])["tenant_key"])
        }

        case Store.get(id) do
          {:ok, %{"state" => %{"status" => "provisioning"} = state}, _etag} ->
            join(connect, id, stringify(state), attrs)

          {:ok, _doc, _etag} ->
            {:ok, :duplicate}

          {:error, :not_found} ->
            create_and_join(connect, id, attrs)

          {:error, _} = error ->
            error
        end
    end
  end

  defp ended(connect, event) do
    lark_meeting_id = LarkMeetingBot.meeting_id(map(event["meeting"])["id"])

    with {:ok, id} <- indexed_meeting(connect, lark_meeting_id),
         {:ok, %{"state" => state}, _etag} <- Store.get(id),
         state = stringify(state),
         true <- bot_meeting?(state) and state["status"] == "active" do
      # Lark may still give the last sentences. Without them the meeting ends
      # all the same.
      _ = read_and_keep(connect, id, state)
      with :ok <- finish(id, state), do: {:ok, :handled}
    else
      {:error, :not_found} -> {:ignored, :meeting_not_found}
      false -> {:ok, :duplicate}
      {:error, _} = error -> error
    end
  end

  defp create_and_join(connect, id, attrs) do
    with {:ok, meeting_agent} <-
           Runtime.start_for_group(connect["tenant_id"], connect["group_id"]),
         {:ok, sent} <-
           LarkMeetingBot.post_direct_text(
             connect,
             attrs.inviter,
             joining_text(connect),
             operation_uuid(id, "joining")
           ),
         {:ok, state} <- new_state(connect, id, meeting_agent, attrs, sent) do
      case Store.create_once(id, state: state) do
        {:ok, _doc, _etag} ->
          join(connect, id, state, attrs)

        {:error, :exists} ->
          {:ok, :duplicate}

        {:error, _} = error ->
          error
      end
    else
      {:error, reason} = error ->
        Logger.warning("lark meeting invitation failed meeting=#{id}: #{inspect(reason)}")
        error
    end
  end

  defp new_state(connect, id, meeting_agent, attrs, sent) do
    now = SystemsClock.system_time(:second)
    message_id = text(sent["message_id"])

    new_meeting_state(connect, id, meeting_agent, %{
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      ref_key(connect) => %{
        "chat_id" => text(sent["chat_id"]),
        "chat_type" => "p2p",
        "thread_id" => "",
        "root_message_id" => "",
        "trigger_message_id" => message_id
      },
      "meet_url" => meeting_host(connect) <> "/j/" <> attrs.meeting_no,
      "title" => attrs.title,
      "bot_name" => text(connect["bot_name"]),
      "caption_language" => @default_caption_language,
      "start_at" => now,
      "end_at" => now + 3600,
      "runtime_source" => @source,
      "source" => %{
        "event_id" => attrs.event_id,
        "message_id" => message_id,
        "sender_open_id" => attrs.inviter,
        "tenant_key" => attrs.tenant_key
      }
    })
  end

  defp join(connect, id, state, attrs) do
    case LarkMeetingBot.join(connect, attrs.meeting_no, attrs.call_id) do
      {:ok, data} ->
        lark_meeting_id =
          first_nonblank([
            LarkMeetingBot.meeting_id(map(data["meeting"])["id"]),
            attrs.lark_meeting_id
          ])

        with {:ok, _doc, _etag} <- put_joined(id, lark_meeting_id, attrs.meeting_no),
             :ok <- put_index(connect, lark_meeting_id, id),
             :ok <- put_number_index(connect, attrs.meeting_no, id),
             :ok <- start_process(id),
             :ok <- status(state, id, "in_meeting") do
          {:ok, :handled}
        end

      {:error, reason} ->
        # Lark refused this invitation, and asking again gets the same answer.
        Logger.warning("lark meeting join refused meeting=#{id}: #{inspect(reason)}")

        with :ok <- status(state, id, "error", %{"message" => error_text(reason)}) do
          {:ok, :handled}
        end
    end
  end

  defp put_joined(id, lark_meeting_id, meeting_no) do
    now = SystemsClock.system_time(:second)

    Store.update_state_retrying(id, fn state ->
      bot =
        map(state["lark_bot"])
        |> Map.merge(%{
          "meeting_id" => lark_meeting_id,
          "meeting_no" => meeting_no,
          "page_token" => ""
        })
        |> Map.drop(~w(blocked retry_at))

      state
      |> Map.put("join_requested_at", now)
      |> Map.put("last_seen_live_at", now)
      |> Map.put("lark_bot", bot)
    end)
  end

  # ---- a calendar meeting ----

  @doc """
  The platform (`"feishu"` or `"lark"`) and meeting number of a Feishu/Lark
  meeting link (`SalixCalendar.OccurrenceQualification.canonical_meeting_url/1`).
  """
  @spec meeting_link(term()) :: {:ok, String.t(), String.t()} | :error
  def meeting_link(url) do
    with {:lark, canonical} <- SalixCalendar.OccurrenceQualification.canonical_meeting_url(url),
         %URI{host: host, path: path} <- URI.parse(canonical),
         [_, number] <- Regex.run(~r{\A/j/(\d+)/?\z}, path || "") do
      {:ok, if(String.ends_with?(host, ".feishu.cn"), do: "feishu", else: "lark"), number}
    else
      _ -> :error
    end
  end

  @doc """
  Joins a calendar meeting's bot by meeting number, for `SalixMeet.JoinDispatch`.
  `{:deferred, reason}` leaves the join pending for a later pass and
  `{:abandoned, reason}` ends it; any other refusal is a failed attempt.
  """
  @spec join_scheduled(map()) ::
          :ok | {:deferred, term()} | {:abandoned, term()} | {:error, term()}
  def join_scheduled(%{"id" => id, "state" => state}) do
    state = stringify(state)
    bot = map(state["lark_bot"])
    meeting_no = text(bot["meeting_no"])
    now = SystemsClock.system_time(:second)

    with {:ok, connect} <- bot_connect(state),
         true <- meeting_no != "" || {:abandoned, :lark_meeting_number_missing},
         true <-
           not running_number?(connect, meeting_no, id) || {:abandoned, :lark_meeting_joined},
         true <- not waiting?(bot, now) || {:deferred, {:lark_meeting_blocked, bot["blocked"]}} do
      case LarkMeetingBot.join(connect, meeting_no, "") do
        {:ok, data} -> scheduled_joined(connect, id, state, data, meeting_no)
        {:error, reason} -> scheduled_refused(id, state, reason, now)
      end
    else
      {:error, :not_found} -> {:error, :lark_meeting_connect_unavailable}
      {kind, _reason} = outcome when kind in [:deferred, :abandoned] -> outcome
      {:error, _} = error -> error
    end
  end

  defp waiting?(bot, now), do: is_integer(bot["retry_at"]) and bot["retry_at"] > now

  defp scheduled_joined(connect, id, state, data, meeting_no) do
    lark_meeting_id = LarkMeetingBot.meeting_id(map(data["meeting"])["id"])

    if running?(connect, lark_meeting_id, id) do
      {:abandoned, :lark_meeting_joined}
    else
      with {:ok, _doc, _etag} <- put_joined(id, lark_meeting_id, meeting_no),
           :ok <- put_index(connect, lark_meeting_id, id),
           :ok <- put_number_index(connect, meeting_no, id),
           :ok <- status(state, id, "in_meeting") do
        :ok
      end
    end
  end

  defp scheduled_refused(id, state, reason, now) do
    code = LarkMeetingBot.error_code(reason)

    cond do
      code == @not_started ->
        {:deferred, :lark_meeting_not_started}

      code in @gone ->
        {:abandoned, {:lark_meeting_unavailable, code}}

      Map.has_key?(@blocked, code) ->
        blocked = Map.fetch!(@blocked, code)

        with {:ok, _doc, _etag} <-
               Store.update_state_retrying(id, fn current ->
                 bot =
                   map(current["lark_bot"])
                   |> Map.put("blocked", blocked)
                   |> Map.put("retry_at", now + @blocked_retry_s)

                 Map.put(current, "lark_bot", bot)
               end) do
          # Told once per Meeting: the notice key of the status is its own.
          _ = status(state, id, "lark_join_blocked", %{"lark_reason" => blocked})
          {:deferred, {:lark_meeting_blocked, blocked}}
        end

      true ->
        Logger.warning("lark meeting join failed meeting=#{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "What a refused Feishu/Lark join means and what the host can change."
  @spec blocked_text(String.t(), String.t()) :: String.t()
  def blocked_text(reason, "zh") do
    "我没能加入会议：" <>
      case reason do
        "ai_summary_off" -> "主持人需要在会议设置中开启「智能纪要」并允许智能伙伴入会。"
        "password" -> "会议设置了密码。请取消密码，或在会议中邀请机器人。"
        "meeting_locked" -> "会议已锁定。主持人可以解锁，或在会议中邀请机器人。"
        "no_permission" -> "机器人没有入会权限。主持人可以放开入会范围，或在会议中邀请机器人。"
        "security_policy" -> "企业的安全策略不允许机器人入会。管理员可以在管理后台修改。"
        "app_permission" -> "应用缺少入会权限（vc:meeting.bot.join:write）。管理员可以在开发者后台添加并发布新版本。"
        "meeting_full" -> "会议人数已满。"
        _ -> "机器人正在另一个通话中。"
      end <> "会议结束前我会继续尝试。"
  end

  def blocked_text(reason, _locale) do
    "I could not join the meeting: " <>
      case reason do
        "ai_summary_off" ->
          "the host must turn on AI Summary and allow agents to join meetings in the meeting settings."

        "password" ->
          "it needs a password. Remove the password, or invite the bot from inside the meeting."

        "meeting_locked" ->
          "it is locked. The host can unlock it, or invite the bot from inside the meeting."

        "no_permission" ->
          "the bot may not join it. The host can let more people join, or invite the bot from inside the meeting."

        "security_policy" ->
          "the organization's security policy does not let bots join meetings. An administrator can change it in the admin console."

        "app_permission" ->
          "the app lacks the permission to join meetings (vc:meeting.bot.join:write). An administrator can add it in the developer console and publish a new version."

        "meeting_full" ->
          "it is full."

        _ ->
          "the bot is in another call."
      end <> " I will keep trying until the meeting ends."
  end

  # ---- Minutes and AI notes of the meeting ----

  @doc """
  Finds the Feishu/Lark Minutes and AI notes of a finished Meeting once, as
  the app or a signed-in participant (`lark.get_meeting`, `lark.get_note`),
  and keeps their links (`lark_bot.links`). Nothing readable keeps none. Only
  the link is kept, never content: the document's own permissions decide who
  can open it.
  """
  @spec collect_links(String.t(), map()) :: :ok
  def collect_links(id, state) do
    state = stringify(state)
    bot = map(state["lark_bot"])

    if bot_meeting?(state) and text(bot["meeting_id"]) != "" and
         not is_integer(bot["links_read_at"]) do
      links = read_links(state, text(bot["meeting_id"]))

      _ =
        Store.update_state_retrying(id, fn current ->
          Map.put(
            current,
            "lark_bot",
            map(current["lark_bot"])
            |> Map.put("links", links)
            |> Map.put("links_read_at", SystemsClock.system_time(:second))
          )
        end)
    end

    :ok
  end

  defp read_links(state, lark_meeting_id) do
    with {:ok, connect} <- bot_connect(state),
         {:ok, agent_id} <- router_agent(state),
         {:ok, meeting} <-
           meetings(connect).call(agent_id, connect, provider(connect) <> ".get_meeting", %{
             "meeting_id" => lark_meeting_id
           }) do
      minute = minute_link(meeting)
      [minute, note_link(agent_id, connect, meeting)] |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp minute_link(meeting) do
    case text(meeting["minute_url"]) do
      "https://" <> _ = url -> %{"kind" => "minute", "url" => url}
      _ -> nil
    end
  end

  defp note_link(agent_id, connect, meeting) do
    with note_id when note_id != "" <- text(meeting["note_id"]),
         {:ok, note} <-
           meetings(connect).call(agent_id, connect, provider(connect) <> ".get_note", %{
             "note_id" => note_id,
             "account" => meeting["account"] || "app"
           }),
         token when token != "" <- text(note["note_doc_token"]),
         {:ok, reader} <-
           meetings(connect).as_account(agent_id, connect, note["account"] || "app"),
         {:ok, "https://" <> _ = url} <- LarkMeetingBot.doc_url(reader, token) do
      %{"kind" => "note", "url" => url}
    else
      _ -> nil
    end
  end

  @doc "Lines that end delivered minutes with the meeting's Minutes and AI notes links."
  @spec link_lines(map(), String.t()) :: [String.t()]
  def link_lines(state, locale) do
    for {label, url} <- links(state, locale),
        do: label <> if(locale == "zh", do: "：", else: ": ") <> url
  end

  @doc "The meeting's Minutes and AI notes links with their labels, in `locale`."
  @spec links(map(), String.t()) :: [{String.t(), String.t()}]
  def links(state, locale) do
    state = stringify(state)

    for %{"kind" => kind, "url" => "https://" <> _ = url} <-
          List.wrap(map(state["lark_bot"])["links"]),
        Map.has_key?(@links_label, kind) do
      {en, zh} = Map.fetch!(@links_label, kind)
      {if(locale == "zh", do: "飞书" <> zh, else: platform_name(state) <> " " <> en), url}
    end
  end

  defp platform_name(state) do
    if first_nonblank([map(state["lark_bot"])["provider"], provider(state)]) == "feishu",
      do: "Feishu",
      else: "Lark"
  end

  defp router_agent(state) do
    case SalixIM.GroupDirectory.get_group(text(state["group_id"])) do
      {:ok, %{"router_agent_id" => agent_id}} when is_binary(agent_id) and agent_id != "" ->
        {:ok, agent_id}

      _ ->
        {:error, :router_agent_not_configured}
    end
  end

  defp meetings(%{"provider" => "feishu"}), do: SalixIM.Provider.Feishu.Meetings
  defp meetings(_connect), do: SalixIM.Provider.Lark.Meetings

  # The bot's connect: a calendar Meeting names it in `lark_bot`, since its
  # own connect is the destination's; an invited Meeting's is its own.
  defp bot_connect(state) do
    bot = map(state["lark_bot"])
    connect_id = first_nonblank([bot["connect_id"], state["connect_id"]])
    provider = first_nonblank([bot["provider"], provider(state)])

    SalixIM.ProviderConnects.get_active_connect_by_id(state["group_id"], connect_id, provider)
  end

  defp start_process(id) do
    case SalixMeet.Application.start_meeting(id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _pid}} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---- the live meeting ----

  @doc "Sends text into a live Meeting. One `message_id` posts one message."
  @spec send_chat(String.t(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_chat(id, state, text, message_id) do
    with {:ok, connect} <- bot_connect(stringify(state)) do
      LarkMeetingBot.post_meeting_text(
        connect,
        text(map(state["lark_bot"])["meeting_id"]),
        text,
        operation_uuid(id, message_id)
      )
    end
  end

  @doc "One read of a live Meeting, by its leader."
  @spec poll(String.t()) :: :ok | {:error, term()}
  def poll(id) do
    with {:ok, doc, _etag} <- Store.get(id),
         true <- live?(doc) || {:error, :not_live},
         state = stringify(doc["state"]) do
      case state["status"] do
        # A node stopped between the two writes of `finish/2`.
        "processing" -> finish(id, state)
        "active" -> poll_active(id, state)
      end
    end
  end

  defp poll_active(id, state) do
    with {:ok, connect} <- bot_connect(state) do
      case read_and_keep(connect, id, state) do
        {:ok, :ended} ->
          finish(id, state)

        {:ok, :live} ->
          :ok

        {:error, :absent} ->
          absent(id, state)

        {:error, reason} = error ->
          Logger.warning("lark meeting read failed meeting=#{id}: #{inspect(reason)}")
          error
      end
    end
  end

  defp absent(id, state) do
    waited = SystemsClock.system_time(:second) - (state["joined_at"] || 0)

    cond do
      is_integer(get_in(state, ["lark_bot", "confirmed_at"])) ->
        finish(id, state)

      waited >= @admission_wait_s ->
        status(state, id, "error", %{"reason_code" => "admission_timeout"})

      true ->
        :ok
    end
  end

  defp read_and_keep(connect, id, state) do
    bot = map(state["lark_bot"])
    token = text(bot["page_token"])

    with {:ok, read} <- read_pages(connect, text(bot["meeting_id"]), token, @pages_per_poll),
         :ok <- keep(connect, id, state, read) do
      {:ok, if(read.ended?, do: :ended, else: :live)}
    end
  end

  defp read_pages(connect, meeting_id, token, pages) do
    read_pages(connect, meeting_id, token, pages, %{events: [], token: token, ended?: false})
  end

  defp read_pages(_connect, _meeting_id, _token, 0, read), do: {:ok, read}

  defp read_pages(connect, meeting_id, token, pages, read) do
    case LarkMeetingBot.events(connect, meeting_id, token) do
      {:ok, data} ->
        next = first_nonblank([data["page_token"], token])

        read = %{
          events: read.events ++ Enum.filter(List.wrap(data["events"]), &is_map/1),
          token: next,
          ended?: read.ended? or meeting_over?(map(data["meeting"]))
        }

        if data["has_more"] == true and next != token,
          do: read_pages(connect, meeting_id, next, pages - 1, read),
          else: {:ok, read}

      {:error, reason} ->
        cond do
          LarkMeetingBot.absent?(reason) -> {:error, :absent}
          read.events != [] -> {:ok, read}
          true -> {:error, reason}
        end
    end
  end

  # A running meeting answers no end time, or one that is not after its start.
  defp meeting_over?(meeting) do
    with {:ok, start} <- integer(meeting["start_time"]),
         {:ok, finish} <- integer(meeting["end_time"]) do
      finish > start
    else
      _ -> false
    end
  end

  defp keep(connect, id, state, read) do
    now = SystemsClock.system_time(:second)
    bot = map(state["lark_bot"])
    seen = state["last_seen_live_at"] || 0

    changed? =
      read.events != [] or read.token != text(bot["page_token"]) or
        not is_integer(bot["confirmed_at"]) or now - seen >= @seen_interval_s

    if changed? do
      case Store.update_state_retrying(id, &absorb(&1, connect, read, now)) do
        {:ok, _doc, _etag} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp absorb(state, connect, read, now) do
    bot =
      map(state["lark_bot"])
      |> Map.put("page_token", read.token)
      |> Map.put_new("confirmed_at", now)

    state
    |> Map.put("lark_bot", bot)
    |> Map.put("last_seen_live_at", now)
    |> Map.put(
      "captions",
      Enum.reduce(items(read, "transcript_received"), captions(state), &caption(&1, &2, now))
    )
    |> Map.put(
      "chats",
      Enum.reduce(items(read, "chat_received"), chats(state), &chat(&1, &2, connect))
    )
  end

  defp captions(state), do: List.wrap(state["captions"])
  defp chats(state), do: List.wrap(state["chats"])

  defp items(read, type) do
    Enum.flat_map(read.events, fn event ->
      if event["event_type"] == type,
        do: List.wrap(map(event["payload"])[type <> "_items"]) |> Enum.filter(&is_map/1),
        else: []
    end)
  end

  defp caption(item, captions, now) do
    speaker = map(item["speaker"])

    record = %{
      "speaker" => first_nonblank([speaker["user_name"], "Unknown"]),
      "text" => text(item["text"]),
      "timestamp" => seconds(item["start_time_ms"]),
      "source" => @source,
      "sentence_id" => text(item["sentence_id"]),
      "revised_at" => now
    }

    cond do
      record["text"] == "" -> captions
      true -> upsert(captions, revised(captions, record), same_caption?(record))
    end
  end

  # Lark may send a sentence again unchanged: it has not been revised then.
  defp revised(captions, %{"text" => text} = record) do
    case Enum.find(captions, same_caption?(record)) do
      %{"text" => ^text, "revised_at" => at} -> Map.put(record, "revised_at", at)
      _ -> record
    end
  end

  defp same_caption?(%{"sentence_id" => ""} = record) do
    fn caption ->
      Map.take(caption, ~w(speaker text timestamp)) ==
        Map.take(record, ~w(speaker text timestamp))
    end
  end

  defp same_caption?(%{"sentence_id" => id}), do: &(&1["sentence_id"] == id)

  defp chat(item, chats, connect) do
    operator = map(item["operator"])

    record = %{
      "direction" => if(own?(connect, operator), do: "outgoing", else: "incoming"),
      "sender" => first_nonblank([operator["user_name"], "Unknown"]),
      "text" => text(item["content"]),
      "timestamp" => seconds(item["send_time"]),
      "source" => @source
    }

    if record["text"] == "", do: chats, else: upsert(chats, record, &(&1 == record))
  end

  # A connect that does not know its bot's id may be reading its own message, and
  # taking that for a participant's would make the bot answer itself.
  defp own?(connect, operator) do
    bot = text(connect["bot_open_id"])
    bot == "" or LarkMeetingBot.open_id(operator) in [bot, text(connect["app_id"])]
  end

  defp upsert(list, record, same?) do
    case Enum.find_index(list, same?) do
      nil -> list ++ [record]
      index -> List.replace_at(list, index, record)
    end
  end

  # ---- status of the Meeting ----

  defp finish(id, state) do
    with :ok <- status(state, id, "left") do
      event = %{
        "type" => "meeting_runtime_update",
        "event_id" => "lark-bot:" <> id <> ":done",
        "meeting_id" => id,
        "status" => "done",
        "transcript_source" => @source
      }

      deliver(state, event)
    end
  end

  defp status(state, id, status, attrs \\ %{}) do
    joiner =
      Map.merge(
        %{
          "type" => "status",
          "status" => status,
          "timestamp" => SystemsClock.system_time(:second)
        },
        attrs
      )

    deliver(state, %{
      "type" => "joiner_event",
      "event_id" => "lark-bot:" <> id <> ":" <> status,
      "meeting_id" => id,
      "joiner_event" => joiner
    })
  end

  defp deliver(state, event) do
    case Runtime.deliver_event(state["tenant_id"], state["group_id"], event) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---- the platform of the connect ----

  defp new_meeting_state(%{"provider" => "feishu"}, id, meeting_agent, attrs),
    do: MeetingState.new_feishu(id, meeting_agent, attrs)

  defp new_meeting_state(_connect, id, meeting_agent, attrs),
    do: MeetingState.new_lark(id, meeting_agent, attrs)

  defp ref_key(%{"provider" => "feishu"}), do: "feishu_ref"
  defp ref_key(_connect), do: "lark_ref"

  defp meeting_host(%{"provider" => "feishu"}), do: "https://vc.feishu.cn"
  defp meeting_host(_connect), do: "https://vc.larksuite.com"

  defp joining_text(%{"provider" => "feishu"}), do: "正在加入飞书会议…"
  defp joining_text(_connect), do: "Joining the Lark meeting…"

  defp default_title(%{"provider" => "feishu"}), do: "飞书会议"
  defp default_title(_connect), do: "Lark meeting"

  defp provider(%{"provider" => "feishu"}), do: "feishu"
  defp provider(_state), do: "lark"

  # ---- which Meeting a Lark meeting is ----

  defp running?(connect, lark_meeting_id, except \\ nil)
  defp running?(_connect, "", _except), do: false

  defp running?(connect, lark_meeting_id, except) do
    with {:ok, id} when id != except <- indexed_meeting(connect, lark_meeting_id),
         {:ok, %{"state" => state}, _etag} <- Store.get(id) do
      live_meeting?(state)
    else
      _ -> false
    end
  end

  # A meeting number names one meeting at a time: another live Meeting of the
  # same number holds the bot already.
  defp running_number?(connect, meeting_no, except \\ nil)
  defp running_number?(_connect, "", _except), do: false

  defp running_number?(connect, meeting_no, except) do
    with {:ok, %{body: body}} <- S3.get(number_index_key(connect, meeting_no)),
         {:ok, %{"meeting_id" => id}} when id != except <- Jason.decode(body),
         {:ok, %{"state" => state}, _etag} <- Store.get(id) do
      live_meeting?(state)
    else
      _ -> false
    end
  end

  defp live_meeting?(state) do
    state = stringify(state)

    state["status"] not in RuntimeEvents.terminal_statuses() and
      text(get_in(state, ["lark_bot", "meeting_id"])) != ""
  end

  defp put_number_index(_connect, "", _id), do: :ok

  defp put_number_index(connect, meeting_no, id) do
    case S3.put(number_index_key(connect, meeting_no), Jason.encode!(%{"meeting_id" => id})) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  defp number_index_key(connect, meeting_no) do
    digest = Crypto.hex([text(connect["connect_id"]), <<0>>, "no:", meeting_no])
    "meet/sources/lark-bot/#{text(connect["group_id"])}/#{digest}.json"
  end

  defp indexed_meeting(_connect, ""), do: {:error, :not_found}

  defp indexed_meeting(connect, lark_meeting_id) do
    case S3.get(index_key(connect, lark_meeting_id)) do
      {:ok, %{body: body}} -> {:ok, Map.fetch!(Jason.decode!(body), "meeting_id")}
      {:error, _} = error -> error
    end
  end

  defp put_index(_connect, "", _id), do: :ok

  defp put_index(connect, lark_meeting_id, id) do
    case S3.put(index_key(connect, lark_meeting_id), Jason.encode!(%{"meeting_id" => id})) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  defp index_key(connect, lark_meeting_id) do
    digest =
      Crypto.hex([
        text(connect["connect_id"]),
        <<0>>,
        lark_meeting_id
      ])

    "meet/sources/lark-bot/#{text(connect["group_id"])}/#{digest}.json"
  end

  # One Meeting per invitation, so inviting the bot back after it left is a
  # new Meeting and a repeated event is not.
  defp meeting_id(connect, meeting_no, lark_meeting_id, call_id) do
    digest =
      Crypto.hex([
        "comma30-lark-bot-meeting-v1",
        <<0>>,
        text(connect["tenant_id"]),
        <<0>>,
        text(connect["group_id"]),
        <<0>>,
        text(connect["connect_id"]),
        <<0>>,
        first_nonblank([lark_meeting_id, meeting_no]),
        <<0>>,
        call_id
      ])
      |> binary_part(0, 24)

    "mtg-" <> digest
  end

  defp operation_uuid(id, step) do
    :crypto.hash(:sha256, id <> ":" <> step)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  # ---- values ----

  defp seconds(value) do
    case integer(value) do
      {:ok, ms} when ms > 0 -> div(ms, 1000)
      _ -> SystemsClock.system_time(:second)
    end
  end

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp integer(_value), do: :error

  defp first_nonblank(values), do: Enum.find_value(values, "", &nonblank/1)

  defp nonblank(value) do
    case text(value) do
      "" -> nil
      text -> text
    end
  end

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
