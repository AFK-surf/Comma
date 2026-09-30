defmodule SalixMeet.SlackProvider do
  @moduledoc """
  Slack meeting provider for the COMMA-30 meeting-agent model.

  The entry point is called by `SalixIM.ProviderHTTP` after Slack signature,
  team, and event-receipt validation. It ports Willow's Slack meeting trigger
  behavior into Salix's provider-connect and group-scoped meeting-agent model:
  detect a Google Meet request, create/reuse meeting state, stage a meeting
  event into the hidden group meeting agent, and publish terminal results back through
  the Slack connect.

  The durable Canvas create/fallback/share/access protocol is modeled in
  `tla/salix/SlackCanvasDelivery.tla`.
  """

  require Logger

  alias SalixIM.Provider.Slack.API
  alias SalixIM.SlackMarkdown

  alias SalixMeet.{
    FallbackMessageManifest,
    MeetingState,
    Runtime,
    RuntimeEvents,
    SlackThreadIndex,
    Store
  }

  alias SalixStore.{Crypto, Keys, S3}

  @chinese_caption_language "Chinese, Mandarin (Simplified)"
  @english_caption_language "English"
  @default_caption_language @chinese_caption_language
  @default_bot_name "Cirno"

  @generating_status "Summarizing…"
  @canvas_reconcile_grace_seconds 300
  @canvas_reconcile_min_attempts 12
  @canvas_reconcile_max_pages 10
  @canvas_link_grace_seconds 300
  @canvas_link_min_attempts 12
  @canvas_body_grace_seconds 300
  @canvas_body_min_attempts 12
  @canvas_body_probe_prefix "comma-canvas-body-"
  @artifact_retry_grace_seconds 300
  @artifact_retry_min_attempts 12
  @message_reconcile_grace_seconds 300
  @message_reconcile_min_attempts 12
  @fallback_summary_content_kind "summary_fallback_v1"
  @fallback_multipart_content_kind "summary_fallback_multipart_v1"
  @fallback_manifest_version 1
  @fallback_message_max_bytes 29_000
  @fallback_block_text_max_chars 3_000
  @fallback_block_max_count 50
  @fallback_summary_footer ":warning: Slack Canvas is unavailable, so the complete meeting notes are included in this message."

  @retryable_slack_errors ~w(ratelimited rate_limited service_unavailable internal_error fatal_error timeout request_timeout team_added_to_org org_login_required)

  @slack_mention_pattern ~r/<@[^>]+>/
  @slack_autolink_pattern ~r/<((?:https?:\/\/)[^>|]+)(?:\|[^>]+)?>/
  @slack_protected_token_pattern ~r/(<[^>\n]+>|https?:\/\/[^\s<>]+)/u
  @google_meet_url_pattern ~r/https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[^\s<>]*)?/
  @slack_permalink_pattern ~r/https:\/\/[^\/\s]+\.slack\.com\/archives\/([A-Z0-9]+)\/p(\d{10})(\d{6})(?:\?[^\s<>]*)?/
  @chinese_hint_pattern ~r/\b(chinese|mandarin)\b|中文|汉语|普通话/iu
  @english_hint_pattern ~r/\benglish\b|英文/iu
  @started_meeting_title_pattern ~r/\bstarted new meeting\b(?:\s*[:：-]\s*|\s+)(.+)$/iu
  @meeting_label_title_pattern ~r/\bmeeting\b\s*[:：-]\s*(.+)$/iu
  @generic_meeting_title_pattern ~r/^(google meet|join meet|confirm join|dismiss|started new meeting|meeting summary|join( this)?( meeting)? please|please join( this)?( meeting)?|can you join( this)?( meeting)?\??|let'?s join)$/iu
  @negated_join_intent_pattern ~r/(?:不要|别|请勿|不用|无需|不需要)\s*(?:让\S*\s*)?(?:入会|进会|加入(?:这个|这场|该)?会议|总结(?:这个|这场|该)?会议)|(?:do\s+not|don['’]?t|never)\s+(?:let\s+\S+\s+)?(?:join|summari[sz]e)\b/iu
  @english_join_command_pattern ~r/^(?:(?:please\s+)?join(?:\s+(?:it|here|this|the|our|my))?(?:\s+(?:meeting|meet|call|google\s+meet))?(?:\s+again)?(?:\s+please)?(?:\s+and\s+summari[sz]e(?:\s+(?:it|this|the))?(?:\s+(?:meeting|meet|call))?)?|(?:can|could|would|will)\s+you\s+(?:please\s+)?join(?:\s+(?:it|this|the))?(?:\s+(?:meeting|meet|call))?|let['’]?s\s+join(?:\s+(?:it|this|the))?(?:\s+(?:meeting|meet|call))?|(?:please\s+)?summari[sz]e\s+(?:it|this|the)(?:\s+(?:meeting|meet|call))?|(?:set\s+up|create)\b.{0,200}(?:,|;|\band\b)\s*(?:please\s+)?join\s+it)[.!?:;,\-]*$/iu
  @chinese_join_command_pattern ~r/^(?:(?:请|请你|麻烦|麻烦你|帮我|帮忙|能否|能不能|可以请你)\s*)?(?:入会|进会|加入(?:(?:这个|这场|该)?会议|\s*Google\s+Meet)?|总结(?:这个|这场|该)?会议)(?:并总结(?:这个|这场|该)?会议)?(?:吧|一下|可以吗|吗)?[。！？!?：:，,；;\-]*$/iu

  @doc """
  Return `{:ok, :handled}` when this Slack event is a meeting trigger,
  `:ignored` otherwise.
  """
  def handle_event(connect, envelope) when is_map(connect) and is_map(envelope) do
    if runtime_driver_configured?() do
      do_handle_event(connect, envelope)
    else
      :ignored
    end
  end

  @doc "Execute one Router-authorized manual join after validating its sealed Slack source."
  @spec join_from_router(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def join_from_router(connect, source, params)
      when is_map(connect) and is_map(source) and is_map(params) do
    metadata = stringify(source["metadata"] || %{})
    text = trim(source["text"])

    event = %{
      "type" => blank_default(metadata["event_type"], "message"),
      "channel" => metadata["channel_id"],
      "channel_id" => metadata["channel_id"],
      "thread_ts" => metadata["thread_ts"],
      "ts" => blank_default(metadata["message_ts"], metadata["event_ts"]),
      "event_ts" => metadata["event_ts"],
      "user" => metadata["user_id"],
      "text" => text,
      "files" => []
    }

    envelope = %{
      "event_id" => blank_default(metadata["event_id"], source["source_message_id"]),
      "event" => event
    }

    with true <- runtime_driver_configured?() || {:error, :meeting_runtime_not_configured},
         true <-
           trim(source["connect_id"]) == trim(connect["connect_id"]) ||
             {:error, :meeting_source_connect_mismatch},
         true <-
           (channel_id(event) != "" and thread_ts(event) != "" and trim(event["user"]) != "") ||
             {:error, :invalid_meeting_source},
         {:ok, request} <- resolve_router_request(connect, event, params),
         {:ok, meeting_agent} <-
           Runtime.start_for_group(connect["tenant_id"], connect["group_id"]),
         {:ok, meeting_id, meeting_state} <-
           ensure_meeting(connect, meeting_agent, envelope, event, request),
         true <-
           trim(meeting_state["meet_url"]) == trim(request["meet_url"]) ||
             {:error, :meeting_thread_has_different_meeting},
         :ok <- maybe_request_meeting_join(meeting_id, meeting_state),
         :ok <-
           deliver_meeting_trigger(
             connect,
             meeting_agent,
             meeting_id,
             meeting_state,
             envelope,
             event
           ) do
      {:ok,
       %{
         "meeting_id" => meeting_id,
         "status" =>
           if(meeting_state["already_scheduled"], do: "already_active", else: "joining"),
         "provider" => "slack"
       }}
    else
      {:error, :terminal_thread} -> {:error, :meeting_thread_already_completed}
      {:error, :thread_owned} -> {:error, :meeting_thread_owned}
      {:error, _} = error -> error
      false -> {:error, :invalid_meeting_source}
      other -> {:error, other}
    end
  end

  @doc false
  defdelegate fallback_notes_manifest_complete?(delivery, meeting_id),
    to: FallbackMessageManifest,
    as: :complete?

  defp do_handle_event(connect, envelope) do
    event = stringify(envelope["event"] || %{})

    with true <- List.wrap(event["files"]) == [] || :ignored,
         {:ok, request} <- resolve_meeting_request(connect, event),
         {:ok, meeting_agent} <-
           Runtime.start_for_group(connect["tenant_id"], connect["group_id"]),
         {:ok, meeting_id, meeting_state} <-
           ensure_meeting(connect, meeting_agent, envelope, event, request),
         :ok <- maybe_request_meeting_join(meeting_id, meeting_state),
         :ok <- maybe_notice_existing(connect, request, meeting_state),
         :ok <-
           deliver_meeting_trigger(
             connect,
             meeting_agent,
             meeting_id,
             meeting_state,
             envelope,
             event
           ) do
      {:ok, :handled}
    else
      :ignored -> :ignored
      {:error, :ignored} -> :ignored
      {:error, :terminal_thread} -> {:ok, :handled}
      {:error, :thread_owned} -> {:ok, :handled}
      {:error, :ambiguous_meet_urls} -> {:ok, :handled}
      {:error, _} = err -> err
      false -> :ignored
      other -> other
    end
  end

  defp runtime_driver_configured?, do: SalixMeet.RuntimeDriver.configured?()

  @doc "Meeting provider boundary used by `SalixMeet.Runtime.publish/2`."
  def publish(meeting_agent, payload) when is_map(meeting_agent) and is_map(payload) do
    payload = stringify(payload)
    meeting_id = trim(payload["meeting_id"])
    claim = stringify(payload["delivery_claim"] || %{})

    if trim(payload["kind"]) == "summary_generating" do
      set_generating_status(meeting_id, claim)
    else
      publish_summary(meeting_agent, meeting_id, claim)
    end
  end

  defp publish_summary(meeting_agent, meeting_id, claim) do
    with :ok <- require_nonblank(meeting_id, "meeting_id is required"),
         {:ok, doc, _} <- Store.get(meeting_id),
         state = stringify(doc["state"] || %{}),
         :ok <- ensure_slack_meeting(state),
         :ok <- ensure_not_published(state),
         :ok <- Store.check_delivery_claim(meeting_id, claim),
         {:ok, connect} <- read_connect(state["group_id"], state["connect_id"]),
         :ok <- connect_publishable?(connect),
         {:ok, result} <- publish_state(meeting_agent, connect, meeting_id, state, claim) do
      {:ok, result}
    else
      {:ok, already_published} -> {:ok, already_published}
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp set_generating_status(meeting_id, claim) do
    with :ok <- require_nonblank(meeting_id, "meeting_id is required"),
         {:ok, doc, _} <- Store.get(meeting_id),
         state = stringify(doc["state"] || %{}),
         :ok <- ensure_slack_meeting(state),
         true <- generating_status_applicable?(state),
         :ok <- maybe_check_delivery_claim(meeting_id, claim),
         {:ok, connect} <- read_connect(state["group_id"], state["connect_id"]),
         :ok <- connect_publishable?(connect) do
      token = API.installation(connect)
      channel = get_in(state, ["slack_ref", "channel_id"]) || ""
      thread = get_in(state, ["slack_ref", "thread_ts"]) || ""

      if channel == "" or thread == "" do
        {:error, "Slack meeting thread is missing"}
      else
        _ =
          API.set_assistant_status(token, channel, thread, @generating_status,
            loading_messages: [@generating_status]
          )

        {:ok, %{"status_set" => true}}
      end
    else
      false -> {:ok, %{"status_set" => false}}
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in API.Error -> {:error, API.error_message(e)}
  end

  defp maybe_check_delivery_claim(_meeting_id, claim) when claim == %{}, do: :ok

  defp maybe_check_delivery_claim(meeting_id, claim),
    do: Store.check_delivery_claim(meeting_id, claim)

  defp generating_status_applicable?(state) do
    trim(state["status"]) == "done" and not published?(state) and
      SalixMeet.OwnerAttributionSnapshot.complete?(
        SalixMeet.OwnerAttributionSnapshot.current(state)
      )
  end

  # ---- trigger path ----

  defp resolve_meeting_request(connect, event) do
    ignored = ignored_bot_mentions(connect)
    text = trim(event["text"])
    current_meet_urls = meet_urls(text, ignored)

    cond do
      bot_authored_event?(event) ->
        {:error, :ignored}

      not explicit_join_intent?(connect, event) ->
        {:error, :ignored}

      length(current_meet_urls) > 1 ->
        {:error, :ambiguous_meet_urls}

      length(current_meet_urls) == 1 ->
        match = hd(current_meet_urls)

        {:ok,
         %{
           "meet_url" => match,
           "title" => "Google Meet",
           "context_texts" => compact([text]),
           "source" => "message"
         }}

      not explicitly_addressed?(event) ->
        {:error, :ignored}

      target = extract_single_slack_permalink(text, ignored) ->
        tag_source(resolve_permalink_request(connect, target), "permalink")

      thread_ts(event) != "" ->
        tag_source(resolve_thread_request(connect, channel_id(event), thread_ts(event)), "thread")

      true ->
        {:error, :ignored}
    end
  end

  defp resolve_router_request(connect, event, params) do
    ignored = ignored_bot_mentions(connect)
    text = trim(event["text"])
    current_urls = meet_urls(text, ignored)

    with {:ok, requested_url} <- requested_meet_url(params, ignored) do
      cond do
        requested_url != "" and requested_url in current_urls ->
          {:ok, router_request(requested_url, [text], "message")}

        requested_url != "" ->
          case resolve_thread_request(connect, channel_id(event), thread_ts(event)) do
            {:ok, request} ->
              if trim(request["meet_url"]) == requested_url,
                do: {:ok, Map.put(request, "source", "thread")},
                else: {:error, :meet_url_not_in_current_source}

            {:error, _reason} ->
              {:error, :meet_url_not_in_current_source}
          end

        length(current_urls) > 1 ->
          {:error, :ambiguous_meet_urls}

        length(current_urls) == 1 ->
          {:ok, router_request(hd(current_urls), [text], "message")}

        true ->
          tag_source(
            resolve_thread_request(connect, channel_id(event), thread_ts(event)),
            "thread"
          )
      end
    end
  end

  defp requested_meet_url(params, ignored) do
    case trim(params["meet_url"]) do
      "" ->
        {:ok, ""}

      raw ->
        case meet_urls(raw, ignored) do
          [url] when url == raw -> {:ok, url}
          _ -> {:error, :invalid_google_meet_url}
        end
    end
  end

  defp router_request(url, texts, source) do
    %{
      "meet_url" => url,
      "title" => "Google Meet",
      "context_texts" => compact(texts),
      "source" => source
    }
  end

  defp explicitly_addressed?(event) do
    trim(event["type"]) == "app_mention" or
      (trim(event["type"]) == "message" and trim(event["channel_type"]) == "im")
  end

  defp bot_authored_event?(event) do
    trim(event["subtype"]) == "bot_message" or trim(event["bot_id"]) != "" or
      trim(event["app_id"]) != "" or is_map(event["bot_profile"])
  end

  defp explicit_join_intent?(connect, event) do
    raw = trim(event["text"])
    text = normalize_join_intent_text(raw)

    text != "" and not Regex.match?(@negated_join_intent_pattern, text) and
      (join_command?(text) or terminal_bot_join_command?(connect, event, raw))
  end

  defp terminal_bot_join_command?(connect, event, raw) do
    bot_user_id = trim(connect["bot_user_id"])

    with true <- trim(event["type"]) == "app_mention",
         true <- bot_user_id != "",
         line when is_binary(line) <- terminal_nonblank_line(raw),
         [_, command] <-
           Regex.run(~r/^<@#{Regex.escape(bot_user_id)}>\s+(.+)$/u, line) do
      command
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> join_command?()
    else
      _ -> false
    end
  end

  defp terminal_nonblank_line(raw) do
    raw
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end

  defp join_command?(text) do
    Regex.match?(@english_join_command_pattern, text) or
      Regex.match?(@chinese_join_command_pattern, text)
  end

  defp normalize_join_intent_text(raw) do
    raw
    |> trim()
    |> html_unescape()
    |> then(&Regex.replace(@slack_autolink_pattern, &1, " "))
    |> then(&Regex.replace(@google_meet_url_pattern, &1, " "))
    |> then(&Regex.replace(@slack_permalink_pattern, &1, " "))
    |> then(&Regex.replace(@slack_mention_pattern, &1, " "))
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp tag_source({:ok, request}, source) when is_map(request),
    do: {:ok, Map.put(request, "source", source)}

  defp tag_source(other, _source), do: other

  defp resolve_permalink_request(
         connect,
         %{"channel_id" => channel, "message_ts" => message_ts} = target
       ) do
    root_ts = blank_default(target["thread_ts"], message_ts)
    resolve_thread_request(connect, channel, root_ts)
  end

  defp resolve_thread_request(connect, channel, thread_ts) do
    bot_token = trim(connect["bot_token"])

    if bot_token == "" or channel == "" or thread_ts == "" do
      {:error, :ignored}
    else
      token = API.installation(connect)

      {messages, _cursor} =
        API.conversation_replies(token, channel, thread_ts,
          limit: 200,
          include_all_metadata: true
        )

      case build_request_from_messages(messages, ignored_bot_mentions(connect)) do
        nil -> {:error, :ignored}
        request -> {:ok, request}
      end
    end
  rescue
    e in API.Error ->
      require Logger

      Logger.warning(
        "slack meeting thread detection failed after explicit join intent: #{API.error_message(e)}"
      )

      {:error, API.error_message(e)}
  end

  defp build_request_from_messages(messages, ignored) do
    messages = List.wrap(messages) |> Enum.map(&stringify/1)

    urls =
      messages
      |> Enum.flat_map(&meet_urls(message_text(&1), ignored))
      |> Enum.uniq()

    selected =
      case urls do
        [url] ->
          messages
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.find_value(fn {message, idx} ->
            if url in meet_urls(message_text(message), ignored), do: {idx, url}
          end)

        _ ->
          nil
      end

    case selected do
      nil ->
        nil

      {idx, url} ->
        selected_message = Enum.at(messages, idx) || %{}
        texts = messages |> Enum.drop(idx) |> Enum.flat_map(&collect_message_texts/1) |> compact()

        title =
          extract_meeting_title_from_message(selected_message, ignored) ||
            messages
            |> Enum.take(idx + 1)
            |> Enum.reverse()
            |> Enum.find_value(&extract_meeting_title_from_message(&1, ignored))

        %{
          "meet_url" => url,
          "title" => blank_default(title, "Google Meet"),
          "context_texts" => texts,
          "thread_owner_meeting_id" => calendar_root_meeting_id(messages),
          "thread_owner_conflict" => calendar_root_owner_conflict?(messages)
        }
    end
  end

  defp calendar_root_meeting_id(messages) do
    case calendar_root_meeting_ids(messages) do
      [meeting_id] -> meeting_id
      _ -> ""
    end
  end

  defp calendar_root_owner_conflict?(messages),
    do: length(calendar_root_meeting_ids(messages)) > 1

  defp calendar_root_meeting_ids(messages) do
    messages
    |> List.wrap()
    |> Enum.map(&stringify/1)
    |> Enum.flat_map(fn message ->
      metadata = stringify(message["metadata"] || %{})
      payload = stringify(metadata["event_payload"] || %{})
      meeting_id = trim(payload["meeting_id"])

      if payload["kind"] == "calendar_root" and String.starts_with?(meeting_id, "mtg-cal-"),
        do: [meeting_id],
        else: []
    end)
    |> Enum.uniq()
  end

  defp ensure_meeting(connect, meeting_agent, envelope, event, request) do
    channel = channel_id(event)
    thread = thread_ts(event)
    indexed = resolve_indexed_meeting(connect, channel, thread)

    case indexed do
      {:ok, :active, existing} ->
        reuse_meeting(existing, event)

      {:ok, :terminal, _existing} ->
        {:error, :terminal_thread}

      {:error, {:thread_owner_missing, owner_id}} ->
        expected_id = meeting_id(connect, envelope, event, channel, thread, request["meet_url"])

        if owner_id == expected_id do
          claim_and_create_meeting(
            connect,
            meeting_agent,
            envelope,
            event,
            request,
            channel,
            thread
          )
        else
          {:error, :thread_owned}
        end

      {:error, :not_found} ->
        case recover_calendar_thread_owner(connect, event, request, channel, thread) do
          {:ok, :active, existing} ->
            reuse_meeting(existing, event)

          {:ok, :terminal, _existing} ->
            {:error, :terminal_thread}

          {:ok, :not_found} ->
            claim_and_create_meeting(
              connect,
              meeting_agent,
              envelope,
              event,
              request,
              channel,
              thread
            )

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp reuse_meeting(existing, event) do
    state =
      existing.state
      |> Map.put("already_scheduled", true)
      |> Map.put("trigger_message_ts", trim(event["ts"]))

    {:ok, existing.id, state}
  end

  defp claim_and_create_meeting(
         connect,
         meeting_agent,
         envelope,
         event,
         request,
         channel,
         thread
       ) do
    meeting_id = meeting_id(connect, envelope, event, channel, thread, request["meet_url"])
    now = System.system_time(:second)
    caption_language = infer_caption_language(request["context_texts"])

    with {:ok, state} <-
           MeetingState.new_slack(meeting_id, meeting_agent, %{
             "tenant_id" => connect["tenant_id"],
             "group_id" => connect["group_id"],
             "connect_id" => connect["connect_id"],
             "slack_ref" => %{"channel_id" => channel, "thread_ts" => thread},
             "meet_url" => request["meet_url"],
             "title" => blank_default(request["title"], "Google Meet"),
             "bot_name" => default_bot_name(),
             "caption_language" => caption_language,
             "start_at" => now,
             "end_at" => now + 3600,
             "runtime_source" => "connected_runtime",
             "source" => %{
               "event_id" => trim(envelope["event_id"]),
               "event_ts" => trim(event["event_ts"]),
               "message_ts" => trim(event["ts"]),
               "user_id" => trim(event["user"]),
               "workspace_id" => connect["workspace_id"]
             }
           }) do
      case SlackThreadIndex.claim(connect, channel, thread, meeting_id) do
        {:ok, %{"meeting_id" => ^meeting_id}} ->
          create_claimed_meeting(meeting_id, state, connect, channel, thread)

        {:error, {:thread_owned, _existing_id}} ->
          case resolve_indexed_meeting(connect, channel, thread) do
            {:ok, :active, existing} -> reuse_meeting(existing, event)
            {:ok, :terminal, _existing} -> {:error, :terminal_thread}
            {:error, {:thread_owner_missing, _owner_id}} -> {:error, :thread_owned}
            {:error, _} = error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp create_claimed_meeting(meeting_id, state, connect, channel, thread) do
    case Store.create_once(meeting_id, state: state) do
      {:ok, _doc, _etag} ->
        {:ok, meeting_id, state}

      {:error, :exists} ->
        with {:ok, %{"state" => existing_state}, _} <- Store.get(meeting_id),
             existing_state = stringify(existing_state),
             true <- same_slack_conversation?(existing_state, connect, channel, thread) do
          {:ok, meeting_id, existing_state}
        else
          false -> {:error, :thread_owner_scope_mismatch}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp deliver_meeting_trigger(
         _connect,
         _meeting_agent,
         _meeting_id,
         %{"already_scheduled" => true},
         _envelope,
         _event
       ),
       do: :ok

  defp deliver_meeting_trigger(connect, _meeting_agent, meeting_id, state, envelope, event) do
    trigger = %{
      "type" => "meeting_trigger",
      "event_id" => trim(envelope["event_id"]) |> blank_default("slack:" <> meeting_id),
      "meeting_id" => meeting_id,
      "provider" => "slack",
      "connect_id" => connect["connect_id"],
      "meet_url" => state["meet_url"],
      "title" => state["title"],
      "caption_language" => state["caption_language"],
      "slack_ref" => state["slack_ref"],
      "source" => state["source"],
      "text" => trim(event["text"])
    }

    case Runtime.deliver_event(connect["tenant_id"], connect["group_id"], trigger) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_request_meeting_join(_meeting_id, %{"already_scheduled" => true}), do: :ok

  defp maybe_request_meeting_join(meeting_id, _state), do: request_meeting_join(meeting_id, 5)

  defp request_meeting_join(_meeting_id, 0), do: {:error, :meeting_join_not_leader}

  defp request_meeting_join(meeting_id, retries) do
    with :ok <- ensure_meeting_process(meeting_id) do
      case SalixMeet.Meeting.join(meeting_id) do
        {:ok, _joined_at} ->
          :ok

        {:error, :not_leader} ->
          Process.sleep(10)
          request_meeting_join(meeting_id, retries - 1)

        {:error, :not_running} ->
          Process.sleep(10)
          request_meeting_join(meeting_id, retries - 1)

        {:error, _} = err ->
          err
      end
    end
  end

  defp ensure_meeting_process(meeting_id) do
    case SalixMeet.Application.start_meeting(meeting_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _pid}} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_notice_existing(_connect, %{"source" => "thread"}, %{"already_scheduled" => true}),
    do: :ok

  defp maybe_notice_existing(connect, request, %{"already_scheduled" => true} = state) do
    channel = get_in(state, ["slack_ref", "channel_id"]) || ""
    thread = get_in(state, ["slack_ref", "thread_ts"]) || ""
    bot_token = trim(connect["bot_token"])
    ts = trim(state["trigger_message_ts"])

    cond do
      channel == "" or thread == "" or bot_token == "" ->
        :ok

      same_source_message?(state) or already_noticed?(state, ts) ->
        :ok

      true ->
        token = API.installation(connect)
        _ = API.post_message(token, channel, notice_text(request, state), thread_ts: thread)
        _ = mark_noticed(state, ts)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_notice_existing(_connect, _request, _state), do: :ok

  # Same meeting re-requested → reassure; a DIFFERENT meeting requested in a
  # thread that already holds an active one → say so (one meeting per thread).
  defp notice_text(request, state) do
    if trim(request["meet_url"]) == trim(state["meet_url"]) do
      ":calendar: Meeting already scheduled. I'll post a summary here when it ends."
    else
      ":warning: This thread already has a meeting in progress — start another in a new thread."
    end
  end

  # A message + app_mention twin (or Slack redelivery) of the same message —
  # the one that created the meeting, or one we already replied to — repeats
  # that message's ts, so it must not post again.
  defp same_source_message?(state) do
    trigger = trim(state["trigger_message_ts"])
    trigger != "" and trigger == trim(get_in(state, ["source", "message_ts"]))
  end

  defp already_noticed?(state, ts), do: ts != "" and trim(state["last_notice_ts"]) == ts

  defp mark_noticed(_state, ""), do: :ok

  defp mark_noticed(state, ts) do
    case trim(state["meeting_id"]) do
      "" -> :ok
      id -> Store.update_state_retrying(id, &Map.put(&1, "last_notice_ts", ts))
    end
  end

  defp resolve_indexed_meeting(connect, channel, thread) do
    case SlackThreadIndex.fetch(connect, channel, thread) do
      {:ok, %{"meeting_id" => meeting_id}} ->
        case Store.get(meeting_id) do
          {:ok, %{"state" => state}, _} ->
            state = stringify(state)

            if same_slack_conversation?(state, connect, channel, thread) do
              status =
                if state["status"] in RuntimeEvents.terminal_statuses(),
                  do: :terminal,
                  else: :active

              {:ok, status, %{id: meeting_id, state: state}}
            else
              {:error, :thread_owner_scope_mismatch}
            end

          {:error, :not_found} ->
            {:error, {:thread_owner_missing, meeting_id}}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp recover_calendar_thread_owner(connect, event, request, channel, thread) do
    with {:ok, meeting_id} <-
           legacy_calendar_owner_id(connect, event, request, channel, thread) do
      if meeting_id == "" do
        {:ok, :not_found}
      else
        with {:ok, %{"state" => state}, _} <- Store.get(meeting_id),
             state = stringify(state),
             true <- same_slack_conversation?(state, connect, channel, thread),
             {:ok, %{"meeting_id" => ^meeting_id}} <-
               SlackThreadIndex.claim(connect, channel, thread, meeting_id) do
          status =
            if state["status"] in RuntimeEvents.terminal_statuses(),
              do: :terminal,
              else: :active

          {:ok, status, %{id: meeting_id, state: state}}
        else
          false -> {:error, :thread_owner_scope_mismatch}
          {:error, {:thread_owned, _owner_id}} -> {:error, :thread_owned}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp legacy_calendar_owner_id(connect, event, request, channel, thread) do
    cond do
      request["thread_owner_conflict"] ->
        {:error, :calendar_thread_owner_conflict}

      request["source"] == "thread" ->
        {:ok, trim(request["thread_owner_meeting_id"])}

      request["source"] == "message" and trim(event["thread_ts"]) != "" ->
        read_calendar_root_meeting_id(connect, channel, thread)

      true ->
        {:ok, ""}
    end
  end

  defp read_calendar_root_meeting_id(connect, channel, thread) do
    bot_token = trim(connect["bot_token"])

    if bot_token == "" do
      {:error, :slack_token_missing}
    else
      token = API.installation(connect)

      {messages, _cursor} =
        API.conversation_replies(token, channel, thread,
          limit: 200,
          include_all_metadata: true
        )

      if calendar_root_owner_conflict?(messages),
        do: {:error, :calendar_thread_owner_conflict},
        else: {:ok, calendar_root_meeting_id(messages)}
    end
  rescue
    e in API.Error -> {:error, API.error_message(e)}
  end

  defp same_slack_conversation?(state, connect, channel, thread) do
    state["tenant_id"] == connect["tenant_id"] and state["group_id"] == connect["group_id"] and
      state["provider"] == "slack" and state["connect_id"] == connect["connect_id"] and
      get_in(state, ["slack_ref", "channel_id"]) == channel and
      get_in(state, ["slack_ref", "thread_ts"]) == thread
  end

  # ---- publish path ----

  defp publish_state(meeting_agent, connect, meeting_id, state, claim) do
    token = API.installation(connect)
    channel = get_in(state, ["slack_ref", "channel_id"]) || ""
    thread = get_in(state, ["slack_ref", "thread_ts"]) || ""

    cond do
      channel == "" or thread == "" ->
        {:error, "Slack meeting thread is missing"}

      state["status"] == "failed" ->
        uploads =
          if SalixMeet.Outcome.partial_recording?(state) do
            ensure_artifacts_uploaded(
              meeting_id,
              claim,
              meeting_agent,
              token,
              channel,
              thread,
              state,
              state["delivery"] || %{}
            )
          else
            {:ok, %{}}
          end

        with {:ok, _uploads} <- uploads do
          publish_terminal_notice(
            meeting_id,
            claim,
            token,
            channel,
            thread,
            failed_text(state),
            "failed",
            state["delivery"] || %{}
          )
        end

      state["status"] == "cancelled" ->
        publish_terminal_notice(
          meeting_id,
          claim,
          token,
          channel,
          thread,
          ":stop_sign: Meeting cancelled.",
          "cancelled",
          state["delivery"] || %{}
        )

      true ->
        with :ok <- ensure_complete_owner_attribution(state) do
          publish_done(meeting_agent, connect, token, channel, thread, meeting_id, state, claim)
        end
    end
  end

  defp ensure_complete_owner_attribution(state) do
    if SalixMeet.OwnerAttributionSnapshot.complete?(
         SalixMeet.OwnerAttributionSnapshot.current(state)
       ) do
      :ok
    else
      {:error, :owner_attribution_checkpoint_missing}
    end
  end

  defp publish_done(meeting_agent, connect, token, channel, thread, meeting_id, state, fence) do
    delivery = stringify(state["delivery"] || %{})
    bot_user_id = trim(connect["bot_user_id"])
    workspace_id = trim(connect["workspace_id"])

    with {:ok, uploads} <-
           ensure_artifacts_uploaded(
             meeting_id,
             fence,
             meeting_agent,
             token,
             channel,
             thread,
             state,
             delivery
           ),
         {:ok, canvas_id, canvas_url} <-
           ensure_canvas(
             meeting_id,
             fence,
             token,
             bot_user_id,
             workspace_id,
             state,
             uploads,
             delivery
           ),
         :ok <- ensure_canvas_body_verified(meeting_id, fence, token, canvas_id),
         :ok <-
           ensure_canvas_access_target(
             meeting_id,
             fence,
             token,
             channel,
             bot_user_id,
             canvas_id,
             canvas_url
           ),
         {:ok, message_ts} <-
           ensure_summary_posted(
             meeting_id,
             fence,
             token,
             channel,
             thread,
             state,
             uploads,
             canvas_url,
             bot_user_id,
             delivery
           ),
         :ok <- ensure_canvas_access_finalized(meeting_id, fence, token, canvas_id),
         {:ok, _doc, _etag} <-
           mark_published(meeting_id, fence, message_ts, canvas_id, canvas_url, uploads) do
      {:ok,
       %{
         "published" => true,
         "message_ts" => message_ts,
         "canvas_id" => canvas_id,
         "canvas_url" => canvas_url,
         "artifacts" => uploads
       }}
    else
      {:error, {:terminal, {:canvas_unavailable, _reason}}} = terminal_error ->
        case ensure_canvas_failure_summary(
               meeting_id,
               fence,
               token,
               channel,
               thread,
               state,
               bot_user_id
             ) do
          {:ok, _message_ts} -> terminal_error
          {:error, {:message_post_conflict, _event_type}} -> terminal_error
          {:error, {:message_post_abandoned, _reason}} -> terminal_error
          {:error, {:fallback_manifest_staged, _reason}} -> terminal_error
          {:error, _reason} = notice_error -> notice_error
        end

      other ->
        other
    end
  rescue
    e in API.Error -> {:error, API.error_message(e)}
  end

  defp ensure_canvas_failure_summary(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         state,
         bot_user_id
       ) do
    with {:ok, doc, _etag} <- Store.get(meeting_id) do
      delivery = stringify(get_in(doc, ["state", "delivery"]) || %{})
      message_ts = trim(delivery["summary_message_ts"])

      cond do
        durable_summary_link_shared?(delivery) ->
          checkpoint_notes_visible(
            meeting_id,
            fence,
            delivery,
            message_ts,
            "canvas_link_message",
            "summary"
          )

        durable_fallback_summary_visible?(delivery, meeting_id) ->
          checkpoint_notes_visible(
            meeting_id,
            fence,
            delivery,
            message_ts,
            "message_fallback",
            "summary_fallback",
            fallback_manifest: delivery["fallback_message_manifest"]
          )

        legacy_confirmed_single_fallback?(delivery, meeting_id) ->
          # A pre-multipart worker already proved that its complete single-part
          # fallback reached Slack. Preserve that proof without rerendering or
          # reposting: the renderer can legitimately differ across releases.
          checkpoint_notes_visible(
            meeting_id,
            fence,
            delivery,
            message_ts,
            "message_fallback",
            "summary_fallback"
          )

        legacy_single_fallback_intent?(delivery) ->
          # Replacing an unresolved pre-multipart intent would reuse its
          # deterministic event id with potentially different bytes. Fail
          # closed and let an operator inspect the preserved outbox state.
          {:error,
           {:message_post_abandoned,
            "legacy fallback intent cannot be safely replaced or reconciled"}}

        legacy_canvas_failure_intent?(delivery) ->
          # A rolling old worker may already own the legacy thin-warning intent.
          # Reuse it without claiming that complete notes are visible; this is
          # deliberately conservative and prevents duplicate provider messages.
          ensure_message_posted(
            meeting_id,
            fence,
            token,
            channel,
            thread,
            legacy_canvas_failure_text(),
            "canvas_failure",
            delivery
          )

        true ->
          with {:ok, manifest, origin} <-
                 prepare_fallback_manifest(
                   meeting_id,
                   fence,
                   token,
                   delivery,
                   state,
                   bot_user_id
                 ) do
            case post_and_checkpoint_fallback_summary(
                   meeting_id,
                   fence,
                   token,
                   channel,
                   thread,
                   manifest,
                   origin
                 ) do
              {:ok, _message_ts} = ok -> ok
              {:error, reason} -> {:error, {:fallback_manifest_staged, reason}}
            end
          end
      end
    end
  end

  defp post_and_checkpoint_fallback_summary(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         manifest,
         origin
       ) do
    with :ok <-
           ensure_fallback_manifest_posted(
             meeting_id,
             fence,
             token,
             channel,
             thread,
             manifest,
             origin
           ),
         {:ok, refreshed_doc, _etag} <- Store.get(meeting_id) do
      refreshed = stringify(get_in(refreshed_doc, ["state", "delivery"]) || %{})
      fallback_ts = trim(refreshed["summary_message_ts"])

      if fallback_notes_manifest_complete?(refreshed, meeting_id) do
        checkpoint_notes_visible(
          meeting_id,
          fence,
          refreshed,
          fallback_ts,
          "message_fallback",
          "summary_fallback",
          fallback_manifest: refreshed["fallback_message_manifest"]
        )
      else
        {:error, {:message_post_unknown, fallback_manifest_event_type(manifest)}}
      end
    end
  end

  defp checkpoint_notes_visible(
         meeting_id,
         fence,
         delivery,
         message_ts,
         surface,
         kind,
         opts \\ []
       ) do
    now = System.system_time(:millisecond)

    visible_at =
      case get_in(delivery, ["notes_delivery", "visible_at"]) do
        value when is_integer(value) and value > 0 -> value
        _ -> div(now, 1_000)
      end

    notes_delivery = %{
      "status" => "visible",
      "surface" => surface,
      "kind" => kind,
      "message_ts" => message_ts,
      "visible_at" => visible_at
    }

    notes_delivery =
      case opts[:fallback_manifest] do
        manifest when is_map(manifest) and map_size(manifest) > 0 ->
          manifest = stringify(manifest)

          notes_delivery
          |> Map.put("manifest_content_sha256", manifest["content_sha256"])
          |> Map.put("part_count", manifest["part_count"])

        _ ->
          notes_delivery
      end

    attrs = %{
      "notes_delivery" => notes_delivery
    }

    attrs =
      case trim(get_in(delivery, ["activation", "status"])) do
        "" ->
          Map.put(attrs, "activation", %{
            "status" => "pending",
            "attempt_count" => 0,
            "updated_at" => now
          })

        _existing ->
          attrs
      end

    case checkpoint(meeting_id, fence, attrs) do
      {:ok, _doc, _etag} -> {:ok, message_ts}
      {:error, _} = error -> error
    end
  end

  defp durable_fallback_summary_visible?(delivery, meeting_id) do
    FallbackMessageManifest.notes_visible?(delivery, meeting_id)
  end

  defp legacy_confirmed_single_fallback?(delivery, meeting_id) do
    delivery = stringify(delivery || %{})
    intent = stringify(delivery["message_post"] || %{})

    legacy_single_fallback_intent?(delivery) and intent["status"] == "created" and
      trim(delivery["summary_message_ts"]) != "" and
      trim(delivery["summary_message_kind"]) == "canvas_failure" and
      intent["event_type"] == fallback_part_event_type(meeting_id, 1) and
      trim(intent["content_sha256"]) != "" and
      intent["confirmed_content_sha256"] == intent["content_sha256"]
  end

  defp legacy_single_fallback_intent?(delivery) do
    delivery = stringify(delivery || %{})
    intent = stringify(delivery["message_post"] || %{})
    manifest = stringify(delivery["fallback_message_manifest"] || %{})

    manifest == %{} and intent["kind"] == "canvas_failure" and
      intent["content_kind"] == @fallback_summary_content_kind
  end

  defp legacy_canvas_failure_intent?(delivery) do
    intent = stringify(delivery["message_post"] || %{})
    manifest = stringify(delivery["fallback_message_manifest"] || %{})

    manifest == %{} and intent["kind"] == "canvas_failure" and
      intent["content_kind"] not in [
        @fallback_summary_content_kind,
        @fallback_multipart_content_kind
      ]
  end

  defp legacy_canvas_failure_text do
    ":warning: Meeting notes could not be published because Slack Canvas is unavailable. " <>
      "The meeting record and delivery intent were preserved."
  end

  defp prepare_fallback_manifest(
         meeting_id,
         fence,
         token,
         delivery,
         state,
         bot_user_id
       ) do
    case stringify(delivery["fallback_message_manifest"] || %{}) do
      %{} = manifest when map_size(manifest) > 0 ->
        if fallback_manifest_valid?(manifest, meeting_id) do
          # Persisted part text is the canonical outbox payload. Never rerender
          # it from mutable meeting state or transient files.info responses.
          {:ok, manifest, :existing}
        else
          {:error, {:message_post_conflict, fallback_manifest_event_type(manifest)}}
        end

      %{} ->
        with {:ok, uploads} <-
               strict_hydrate_fallback_artifacts(delivery["artifacts"] || %{}, token) do
          fallback_text =
            fallback_summary_notice_text(state, uploads, bot_user_id) <>
              "\n\n" <> @fallback_summary_footer

          ensure_fallback_manifest(
            meeting_id,
            fence,
            delivery,
            fallback_text,
            fallback_message_parts(fallback_text)
          )
        end

      malformed ->
        {:error, {:message_post_conflict, fallback_manifest_event_type(malformed)}}
    end
  end

  defp strict_hydrate_fallback_artifacts(artifacts, token) do
    artifacts
    |> stringify()
    |> Enum.reduce_while({:ok, %{}}, fn {kind, artifact}, {:ok, acc} ->
      artifact = stringify(artifact || %{})

      case strict_hydrate_fallback_artifact(token, artifact) do
        {:ok, hydrated} -> {:cont, {:ok, Map.put(acc, kind, hydrated)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp strict_hydrate_fallback_artifact(_token, %{"permalink" => permalink} = artifact)
       when is_binary(permalink) and permalink != "",
       do: {:ok, artifact}

  defp strict_hydrate_fallback_artifact(token, %{"file_id" => file_id} = artifact)
       when is_binary(file_id) and file_id != "" do
    case token |> API.file_info(file_id) |> Map.get("permalink", "") |> trim() do
      "" -> {:error, "Slack artifact permalink is not available yet"}
      permalink -> {:ok, Map.put(artifact, "permalink", permalink)}
    end
  rescue
    error in API.Error -> {:error, API.error_message(error)}
  end

  defp strict_hydrate_fallback_artifact(_token, artifact), do: {:ok, artifact}

  defp ensure_fallback_manifest(meeting_id, fence, delivery, fallback_text, fallback_parts) do
    existing = stringify(delivery["fallback_message_manifest"] || %{})
    expected = build_fallback_manifest(meeting_id, fallback_text, fallback_parts)

    cond do
      existing != %{} and fallback_manifest_matches?(existing, expected) ->
        {:ok, existing, :existing}

      existing != %{} ->
        {:error, {:message_post_conflict, fallback_manifest_event_type(existing)}}

      true ->
        first = expected["parts"] |> List.first() |> stringify()

        attrs = %{
          "fallback_message_manifest" => expected,
          # The first part intentionally mirrors the legacy single-message
          # outbox. A rolling old worker therefore reconciles the same event
          # instead of creating a competing Canvas-failure notice.
          "message_post" => fallback_legacy_message_mirror(expected, first)
        }

        attrs =
          case trim(first["message_ts"]) do
            "" ->
              attrs

            message_ts ->
              attrs
              |> Map.put("summary_message_ts", message_ts)
              |> Map.put("summary_message_kind", "canvas_failure")
          end

        case checkpoint(meeting_id, fence, attrs) do
          {:ok, _doc, _etag} -> {:ok, expected, :staged}
          {:error, _} = error -> error
        end
    end
  end

  defp build_fallback_manifest(meeting_id, fallback_text, fallback_parts) do
    part_count = length(fallback_parts)
    content_kind = fallback_manifest_content_kind(part_count)
    now = System.system_time(:second)

    parts =
      fallback_parts
      |> Enum.with_index(1)
      |> Enum.map(fn {text, index} ->
        kind = if index == 1, do: "canvas_failure", else: "summary_fallback_part"
        event_type = fallback_part_event_type(meeting_id, index)
        blocks = fallback_message_blocks(text)

        %{
          "index" => index,
          "part_count" => part_count,
          "kind" => kind,
          "content_kind" => content_kind,
          "content_sha256" => Crypto.hex(text),
          "text" => text,
          "blocks" => blocks,
          "blocks_sha256" => Crypto.hex(Jason.encode!(blocks)),
          "event_type" => event_type,
          "metadata" => %{
            "event_type" => event_type,
            "event_payload" => %{
              "meeting_id" => meeting_id,
              "kind" => kind,
              "content_kind" => content_kind,
              "content_sha256" => Crypto.hex(text),
              "part_index" => index,
              "part_count" => part_count
            }
          },
          "status" => if(index == 1, do: "posting", else: "pending"),
          "started_at" => now,
          "post_attempts" => 0,
          "reconcile_attempts" => 0
        }
      end)

    %{
      "version" => @fallback_manifest_version,
      "content_kind" => content_kind,
      "content_sha256" => Crypto.hex(fallback_text),
      "part_count" => part_count,
      "status" => "posting",
      "parts" => parts
    }
  end

  defp fallback_manifest_content_kind(1), do: @fallback_summary_content_kind
  defp fallback_manifest_content_kind(_part_count), do: @fallback_multipart_content_kind

  defp fallback_legacy_message_mirror(
         %{"version" => @fallback_manifest_version},
         %{
           "status" => status
         } = part
       )
       when status != "created" do
    part
    |> Map.put("status", "abandoned")
    |> Map.put("last_error", "manifest-backed fallback requires a current worker")
  end

  defp fallback_legacy_message_mirror(_manifest, part), do: part

  defp fallback_manifest_matches?(existing, expected) do
    existing = stringify(existing)

    existing["version"] == expected["version"] and
      existing["content_kind"] == expected["content_kind"] and
      existing["content_sha256"] == expected["content_sha256"] and
      existing["part_count"] == expected["part_count"] and
      Enum.map(
        List.wrap(existing["parts"]),
        &Map.take(stringify(&1), ["index", "text", "content_sha256", "event_type"])
      ) ==
        Enum.map(
          expected["parts"],
          &Map.take(&1, ["index", "text", "content_sha256", "event_type"])
        )
  end

  defp fallback_manifest_valid?(manifest, meeting_id) do
    FallbackMessageManifest.valid_manifest?(manifest, meeting_id)
  end

  defp ensure_fallback_manifest_posted(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         manifest,
         origin
       ) do
    manifest["parts"]
    |> List.wrap()
    |> Enum.reduce_while({:ok, manifest}, fn part, {:ok, current_manifest} ->
      part = current_manifest |> fallback_manifest_part(part["index"])

      case ensure_fallback_part_posted(
             meeting_id,
             fence,
             token,
             channel,
             thread,
             current_manifest,
             part,
             origin
           ) do
        {:ok, updated_manifest} -> {:cont, {:ok, updated_manifest}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _manifest} -> :ok
      {:error, _} = error -> error
    end
  end

  defp ensure_fallback_part_posted(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         manifest,
         part,
         _origin
       ) do
    cond do
      fallback_part_confirmed?(part, part["index"], manifest["part_count"]) ->
        {:ok, manifest}

      part["status"] == "pending" or part["status"] == "retryable" or
          (part["status"] == "posting" and (part["post_attempts"] || 0) == 0) ->
        with {:ok, staged_manifest, posting} <-
               stage_fallback_part_attempt(meeting_id, fence, manifest, part) do
          post_fallback_part(
            meeting_id,
            fence,
            token,
            channel,
            thread,
            staged_manifest,
            posting
          )
        end

      part["status"] in ["posting", "unknown", "created"] ->
        reconcile_fallback_part(
          meeting_id,
          fence,
          token,
          channel,
          thread,
          manifest,
          part
        )

      part["status"] == "conflict" ->
        {:error, {:message_post_conflict, part["event_type"]}}

      part["status"] == "abandoned" ->
        {:error, {:message_post_abandoned, part["last_error"]}}

      true ->
        {:error, {:message_post_unresolved, part["status"]}}
    end
  end

  defp stage_fallback_part_attempt(meeting_id, fence, manifest, part) do
    posting =
      part
      |> Map.put("status", "posting")
      |> Map.update("post_attempts", 1, &(&1 + 1))
      |> Map.put("last_attempted_at", System.system_time(:second))

    case checkpoint_fallback_part(meeting_id, fence, manifest, posting) do
      {:ok, staged_manifest} -> {:ok, staged_manifest, posting}
      {:error, _} = error -> error
    end
  end

  defp post_fallback_part(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         manifest,
         part
       ) do
    with :ok <- ensure_owns_claim(meeting_id, fence) do
      try do
        resp =
          API.post_message(token, channel, part["text"],
            thread_ts: thread,
            metadata: part["metadata"],
            blocks: part["blocks"]
          )

        message_ts = trim(resp["ts"])
        response_message = stringify(resp["message"] || %{})
        response_text = response_message["text"]

        updated =
          part
          |> Map.put("message_ts", message_ts)
          |> confirm_fallback_message(response_message)

        updated = fallback_response_part_status(updated, message_ts, response_text)

        with {:ok, updated_manifest} <-
               checkpoint_fallback_part(meeting_id, fence, manifest, updated) do
          cond do
            updated["status"] == "conflict" ->
              {:error, {:message_post_conflict, updated["event_type"]}}

            fallback_part_confirmed?(updated, updated["index"], manifest["part_count"]) ->
              {:ok, updated_manifest}

            true ->
              {:error, {:message_post_unknown, updated["event_type"]}}
          end
        end
      rescue
        e in API.Error -> fallback_part_post_failed(meeting_id, fence, manifest, part, e)
      end
    end
  end

  defp fallback_response_confirmation_error("", _response_text),
    do: "chat.postMessage returned no ts"

  defp fallback_response_confirmation_error(_message_ts, response_text)
       when not is_binary(response_text),
       do: "chat.postMessage returned no message text"

  defp fallback_part_post_failed(meeting_id, fence, manifest, part, error) do
    cond do
      definitely_rejected_create?(error) ->
        retryable =
          part
          |> Map.put("status", "retryable")
          |> Map.put("last_error", API.error_message(error))

        with {:ok, _manifest} <- checkpoint_fallback_part(meeting_id, fence, manifest, retryable) do
          {:error, API.error_message(error)}
        end

      ambiguous_write_error?(error) ->
        unknown =
          part
          |> Map.put("status", "unknown")
          |> Map.put("last_error", API.error_message(error))

        with {:ok, _manifest} <- checkpoint_fallback_part(meeting_id, fence, manifest, unknown) do
          {:error, {:message_post_unknown, part["event_type"]}}
        end

      true ->
        abandon_fallback_part(
          meeting_id,
          fence,
          manifest,
          part,
          part["reconcile_attempts"] || 0,
          "Slack message post failed: " <> API.error_message(error)
        )
    end
  end

  defp reconcile_fallback_part(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         manifest,
         part
       ) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, matches} <- matching_messages(token, channel, thread, part) do
      attempts = (part["reconcile_attempts"] || 0) + 1

      case matches do
        [%{"ts" => message_ts} = message] when is_binary(message_ts) and message_ts != "" ->
          found =
            part
            |> Map.put("message_ts", message_ts)
            |> Map.put("reconcile_attempts", attempts)
            |> confirm_fallback_message(message)

          found = fallback_readback_part_status(found)

          with {:ok, updated_manifest} <-
                 checkpoint_fallback_part(meeting_id, fence, manifest, found) do
            cond do
              found["status"] == "conflict" ->
                {:error, {:message_post_conflict, found["event_type"]}}

              fallback_part_confirmed?(found, found["index"], manifest["part_count"]) ->
                {:ok, updated_manifest}

              true ->
                {:error, {:message_post_unknown, found["event_type"]}}
            end
          end

        [] ->
          now = System.system_time(:second)

          if message_reconciliation_expired?(part, attempts, now) do
            if (part["post_attempts"] || 0) < 2 do
              retryable =
                part
                |> Map.put("status", "retryable")
                |> Map.put("reconcile_attempts", attempts)
                |> Map.put("last_reconciled_at", now)
                |> Map.put(
                  "last_error",
                  "Slack read-back completed without this part; one safe repost is authorized"
                )

              with {:ok, _manifest} <-
                     checkpoint_fallback_part(meeting_id, fence, manifest, retryable) do
                {:error, {:message_post_unknown, part["event_type"]}}
              end
            else
              abandon_fallback_part(
                meeting_id,
                fence,
                manifest,
                part,
                attempts,
                "Slack message part could not be confirmed after bounded reconciliation"
              )
            end
          else
            unknown =
              part
              |> Map.put("status", "unknown")
              |> Map.put("reconcile_attempts", attempts)
              |> Map.put("last_reconciled_at", now)

            with {:ok, _manifest} <-
                   checkpoint_fallback_part(meeting_id, fence, manifest, unknown) do
              {:error, {:message_post_unknown, part["event_type"]}}
            end
          end

        _multiple ->
          conflict =
            part
            |> Map.put("status", "conflict")
            |> Map.put("reconcile_attempts", attempts)

          with {:ok, _manifest} <-
                 checkpoint_fallback_part(meeting_id, fence, manifest, conflict) do
            {:error, {:message_post_conflict, part["event_type"]}}
          end
      end
    end
  rescue
    e in API.Error ->
      if retryable_api_error?(e) do
        {:error, API.error_message(e)}
      else
        abandon_fallback_part(
          meeting_id,
          fence,
          manifest,
          part,
          (part["reconcile_attempts"] || 0) + 1,
          "Slack message reconciliation failed: " <> API.error_message(e)
        )
      end
  end

  defp abandon_fallback_part(meeting_id, fence, manifest, part, attempts, reason) do
    abandoned =
      part
      |> Map.put("status", "abandoned")
      |> Map.put("reconcile_attempts", attempts)
      |> Map.put("last_error", reason)

    with {:ok, _manifest} <- checkpoint_fallback_part(meeting_id, fence, manifest, abandoned) do
      {:error, {:message_post_abandoned, reason}}
    end
  end

  defp checkpoint_fallback_part(meeting_id, fence, manifest, part) do
    updated_manifest =
      manifest
      |> put_fallback_manifest_part(part)
      |> refresh_fallback_manifest_status()

    attrs = %{"fallback_message_manifest" => updated_manifest}

    attrs =
      if part["index"] == 1 do
        message_mirror = fallback_legacy_message_mirror(updated_manifest, part)

        attrs
        |> Map.put("message_post", message_mirror)
        |> maybe_put_nonblank("summary_message_ts", trim(part["message_ts"]))
        |> Map.put("summary_message_kind", "canvas_failure")
      else
        attrs
      end

    case checkpoint(meeting_id, fence, attrs) do
      {:ok, _doc, _etag} -> {:ok, updated_manifest}
      {:error, _} = error -> error
    end
  end

  defp put_fallback_manifest_part(manifest, updated_part) do
    parts =
      manifest["parts"]
      |> List.wrap()
      |> Enum.map(fn part ->
        if part["index"] == updated_part["index"], do: updated_part, else: part
      end)

    Map.put(manifest, "parts", parts)
  end

  defp refresh_fallback_manifest_status(manifest) do
    if Enum.with_index(List.wrap(manifest["parts"]), 1)
       |> Enum.all?(fn {part, index} ->
         fallback_part_confirmed?(part, index, manifest["part_count"])
       end) do
      Map.put(manifest, "status", "confirmed")
    else
      Map.put(manifest, "status", "posting")
    end
  end

  defp fallback_manifest_part(manifest, index) do
    Enum.find(List.wrap(manifest["parts"]), %{}, &(&1["index"] == index))
  end

  defp fallback_part_confirmed?(part, index, part_count) when is_map(part) do
    part = stringify(part)

    part["index"] == index and part["part_count"] == part_count and
      part["status"] == "created" and trim(part["message_ts"]) != "" and
      trim(part["event_type"]) != "" and trim(part["content_sha256"]) != "" and
      trim(part["provider_payload_sha256"]) != "" and part["content_proof"] == "exact_blocks" and
      fallback_provider_proof_valid?(part) and
      part["confirmed_content_sha256"] == part["content_sha256"]
  end

  defp fallback_part_confirmed?(_part, _index, _part_count), do: false

  defp fallback_provider_proof_valid?(%{"content_proof" => "exact_blocks"} = part),
    do: part["provider_payload_sha256"] == part["blocks_sha256"]

  defp fallback_provider_proof_valid?(_part), do: false

  defp fallback_part_content_confirmed?(part) do
    expected = trim(part["content_sha256"])
    expected != "" and part["confirmed_content_sha256"] == expected
  end

  defp confirm_fallback_message(part, message) do
    part = stringify(part)
    message = if is_map(message), do: stringify(message), else: %{}
    expected_blocks = if is_list(part["blocks"]), do: part["blocks"], else: []
    provider_blocks = if is_list(message["blocks"]), do: message["blocks"], else: []

    if expected_blocks != [] and fallback_blocks_match?(provider_blocks, expected_blocks) do
      provider_payload = fallback_blocks_payload(provider_blocks)

      part
      |> Map.put("confirmed_content_sha256", part["content_sha256"])
      |> Map.put("provider_payload_sha256", Crypto.hex(provider_payload))
      |> Map.put("content_proof", "exact_blocks")
    else
      part
      |> Map.delete("confirmed_content_sha256")
      |> Map.delete("provider_payload_sha256")
      |> Map.delete("content_proof")
    end
  end

  defp fallback_blocks_match?(provider_blocks, expected_blocks)
       when is_list(provider_blocks) and is_list(expected_blocks) do
    Enum.map(provider_blocks, &fallback_block_proof_fields/1) ==
      Enum.map(expected_blocks, &fallback_block_proof_fields/1)
  end

  defp fallback_blocks_match?(_provider_blocks, _expected_blocks), do: false

  defp fallback_blocks_payload(blocks) do
    blocks
    |> Enum.map(&fallback_block_proof_fields/1)
    |> Jason.encode!()
  end

  defp fallback_block_proof_fields(block) when is_map(block) do
    block = stringify(block)

    case block["text"] do
      text when is_map(text) ->
        %{
          "type" => block["type"],
          "block_id" => block["block_id"],
          "text" => %{
            "type" => text["type"],
            "text" => text["text"],
            "verbatim" => text["verbatim"]
          }
        }

      _invalid ->
        %{"invalid" => true}
    end
  end

  defp fallback_block_proof_fields(_block), do: %{"invalid" => true}

  defp fallback_response_part_status(part, message_ts, response_text) do
    cond do
      message_ts == "" ->
        part
        |> Map.put("status", "unknown")
        |> Map.put("last_error", fallback_response_confirmation_error("", response_text))

      fallback_part_content_confirmed?(part) ->
        part
        |> Map.put("status", "created")
        |> Map.delete("last_error")

      not is_binary(response_text) ->
        part
        |> Map.put("status", "unknown")
        |> Map.put("last_error", fallback_response_confirmation_error(message_ts, response_text))

      true ->
        part
        |> Map.put("status", "conflict")
        |> Map.put("last_error", "chat.postMessage returned mismatched text and blocks")
    end
  end

  defp fallback_readback_part_status(part) do
    if fallback_part_content_confirmed?(part) do
      part
      |> Map.put("status", "created")
      |> Map.delete("last_error")
    else
      part
      |> Map.put("status", "conflict")
      |> Map.put("last_error", "Slack read-back content did not match expected part")
    end
  end

  defp fallback_manifest_event_type(manifest) when is_map(manifest) do
    first_part =
      manifest
      |> stringify()
      |> Map.get("parts", [])
      |> List.wrap()
      |> List.first()
      |> stringify()

    if is_map(first_part), do: Map.get(first_part, "event_type", ""), else: ""
  end

  defp fallback_manifest_event_type(_manifest), do: ""

  defp fallback_part_event_type(meeting_id, index),
    do: FallbackMessageManifest.part_event_type(meeting_id, index)

  defp fallback_message_parts(text) when byte_size(text) <= @fallback_message_max_bytes,
    do: [text]

  defp fallback_message_parts(text), do: build_labeled_fallback_parts(text, 2)

  defp build_labeled_fallback_parts(text, assumed_count) do
    max_label_bytes =
      1..assumed_count
      |> Enum.map(&byte_size(fallback_part_label(&1, assumed_count)))
      |> Enum.max()

    chunks = utf8_chunks(text, @fallback_message_max_bytes - max_label_bytes)
    actual_count = length(chunks)

    if actual_count == assumed_count do
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} -> fallback_part_label(index, actual_count) <> chunk end)
    else
      build_labeled_fallback_parts(text, actual_count)
    end
  end

  defp fallback_part_label(index, count),
    do: "*Meeting notes fallback (part #{index}/#{count})*\n\n"

  defp fallback_message_blocks(text) do
    content_id = text |> Crypto.hex() |> binary_part(0, 16)

    blocks =
      text
      |> bounded_text_chunks(@fallback_block_text_max_chars, &String.length/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} ->
        %{
          "type" => "section",
          "block_id" => "comma_meeting_fallback_#{content_id}_#{index}",
          "text" => %{"type" => "mrkdwn", "text" => chunk, "verbatim" => true}
        }
      end)

    if length(blocks) <= @fallback_block_max_count do
      blocks
    else
      raise ArgumentError, "fallback message exceeds Slack's Block Kit block limit"
    end
  end

  defp utf8_chunks(text, max_bytes) when max_bytes > 0,
    do: bounded_text_chunks(text, max_bytes, &byte_size/1)

  defp bounded_text_chunks(text, limit, measure) do
    text
    |> preferred_text_units(limit, measure)
    |> Enum.flat_map(&split_oversized_text_unit(&1, limit, measure))
    |> pack_text_units(limit, measure)
  end

  defp preferred_text_units(text, limit, measure) do
    lines = String.split(text, "\n", trim: false)
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      segment = if index < last_index, do: line <> "\n", else: line

      cond do
        segment == "" -> []
        measure.(segment) <= limit -> [segment]
        true -> protected_text_units(segment)
      end
    end)
  end

  defp protected_text_units(segment) do
    @slack_protected_token_pattern
    |> Regex.split(segment, include_captures: true, trim: true)
    |> Enum.flat_map(fn piece ->
      if Regex.match?(~r/\A(?:<[^>\n]+>|https?:\/\/[^\s<>]+)\z/u, piece) do
        [piece]
      else
        Regex.scan(~r/\s+|[^\s]+/u, piece, capture: :first)
        |> List.flatten()
      end
    end)
  end

  defp split_oversized_text_unit(unit, limit, measure) do
    if measure.(unit) <= limit do
      [unit]
    else
      unit
      |> String.graphemes()
      |> pack_text_units(limit, measure)
    end
  end

  defp pack_text_units(units, limit, measure) do
    {chunks, current, _size} =
      Enum.reduce(units, {[], [], 0}, fn unit, {chunks, current, size} ->
        unit_size = measure.(unit)

        if size > 0 and size + unit_size > limit do
          {[IO.iodata_to_binary(Enum.reverse(current)) | chunks], [unit], unit_size}
        else
          {chunks, [unit | current], size + unit_size}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        _ -> [IO.iodata_to_binary(Enum.reverse(current)) | chunks]
      end

    Enum.reverse(chunks)
  end

  # A durable write that belongs to this claim attempt: reject it if the delivery
  # was reclaimed by a newer attempt or already published, so a stale worker can
  # neither overwrite the winning attempt's ids nor mutate a published delivery.
  defp checkpoint(meeting_id, fence, attrs) do
    Store.checkpoint_delivery(meeting_id, fence, stringify(attrs))
  end

  defp ensure_owns_claim(meeting_id, fence), do: Store.check_delivery_claim(meeting_id, fence)

  defp mark_published(meeting_id, fence, message_ts, canvas_id, canvas_url, uploads) do
    now = System.system_time(:millisecond)

    checkpoint(meeting_id, fence, %{
      "provider" => "slack",
      "status" => "published",
      "summary_message_ts" => message_ts,
      "canvas_id" => canvas_id,
      "canvas_url" => canvas_url,
      "artifacts" => uploads,
      "published_at" => System.system_time(:second),
      "notes_delivery" => %{
        "status" => "visible",
        "surface" => "canvas",
        "kind" => "summary",
        "message_ts" => message_ts,
        "visible_at" => System.system_time(:second)
      },
      "activation" => %{
        "status" => "pending",
        "attempt_count" => 0,
        "updated_at" => now
      }
    })
  end

  defp ensure_artifacts_uploaded(
         meeting_id,
         fence,
         meeting_agent,
         token,
         channel,
         thread,
         state,
         delivery
       ) do
    staged = stringify(delivery["artifacts"] || %{})
    intents = stringify(delivery["artifact_uploads"] || %{})

    seed =
      for {kind, artifact} <- staged, match?({:ok, _}, reusable_artifact(artifact)), into: %{} do
        {kind, artifact}
      end

    result =
      Enum.reduce_while(
        ["transcript", "audio"],
        {:ok, seed, intents},
        fn kind, {:ok, acc, current_intents} ->
          case Map.get(acc, kind) do
            %{"file_id" => _} = existing ->
              {:ok, hydrated} = hydrate_artifact_permalink(token, existing)
              {:cont, {:ok, Map.put(acc, kind, hydrated), current_intents}}

            _ ->
              case ensure_artifact_uploaded(
                     meeting_id,
                     fence,
                     meeting_agent,
                     token,
                     channel,
                     thread,
                     state,
                     kind,
                     acc,
                     current_intents
                   ) do
                {:ok, acc2, intents2} -> {:cont, {:ok, acc2, intents2}}
                {:error, _} = err -> {:halt, err}
              end
          end
        end
      )

    case result do
      {:ok, uploads, _intents} -> {:ok, uploads}
      {:error, _} = err -> err
    end
  end

  defp reusable_artifact(%{"file_id" => id} = artifact) when is_binary(id) and id != "",
    do: {:ok, artifact}

  defp reusable_artifact(_artifact), do: :none

  defp ensure_artifact_uploaded(
         meeting_id,
         fence,
         meeting_agent,
         token,
         channel,
         thread,
         state,
         kind,
         acc,
         intents
       ) do
    intent = stringify(intents[kind] || %{})

    case intent["status"] do
      "uploading" ->
        authorize_artifact_completion(meeting_id, fence, token, kind, acc, intents, intent)

      "completing" ->
        reconcile_artifact_upload(meeting_id, fence, token, kind, acc, intents, intent)

      "retryable" ->
        start_artifact_upload(
          meeting_id,
          fence,
          meeting_agent,
          token,
          channel,
          thread,
          state,
          kind,
          acc,
          intents,
          intent
        )

      "abandoned" ->
        {:ok, acc, intents}

      nil ->
        start_artifact_upload(
          meeting_id,
          fence,
          meeting_agent,
          token,
          channel,
          thread,
          state,
          kind,
          acc,
          intents,
          %{}
        )

      status ->
        {:error, {:artifact_upload_unresolved, kind, status}}
    end
  end

  # The provider-issued file id is checkpointed before bytes leave this
  # process. It remains a provisional upload intent until completion is either
  # returned or verified with files.info; only then is it promoted to
  # delivery.artifacts.
  defp start_artifact_upload(
         meeting_id,
         fence,
         meeting_agent,
         token,
         channel,
         thread,
         state,
         kind,
         acc,
         intents,
         prior_intent
       ) do
    artifact = get_in(state, ["artifacts", kind]) || %{}
    path = trim(artifact["path"])

    if path == "" do
      if prior_intent == %{} do
        {:ok, acc, intents}
      else
        abandon_artifact(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          prior_intent,
          path,
          "source_missing",
          :artifact_path_missing
        )
      end
    else
      case workspace_artifact_stream(meeting_agent["meeting_agent_id"], path) do
        {:ok, :empty} ->
          abandon_artifact(
            meeting_id,
            fence,
            kind,
            acc,
            intents,
            prior_intent,
            path,
            "source_empty",
            :artifact_empty
          )

        {:ok, stream, size, sha256} ->
          request_artifact_upload(
            meeting_id,
            fence,
            token,
            channel,
            thread,
            state,
            artifact,
            kind,
            acc,
            intents,
            prior_intent,
            path,
            stream,
            size,
            sha256
          )

        {:error, reason} ->
          handle_artifact_source_failure(
            meeting_id,
            fence,
            kind,
            acc,
            intents,
            prior_intent,
            path,
            reason
          )
      end
    end
  end

  defp request_artifact_upload(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         state,
         artifact,
         kind,
         acc,
         intents,
         prior_intent,
         path,
         stream,
         size,
         sha256
       ) do
    with :ok <- ensure_owns_claim(meeting_id, fence) do
      title = artifact_upload_title(state["title"], kind, artifact["filename"])

      try do
        url_resp = API.get_upload_url_external(token, title, size)
        file_id = trim(url_resp["file_id"])
        upload_url = trim(url_resp["upload_url"])

        if file_id == "" or upload_url == "" do
          retry_or_abandon_artifact(
            meeting_id,
            fence,
            kind,
            acc,
            intents,
            prior_intent,
            path,
            "upload_ticket_unavailable",
            :artifact_upload_ticket_invalid
          )
        else
          attempt = artifact_attempt(prior_intent, path)

          intent = %{
            "file_id" => file_id,
            "status" => "uploading",
            "path" => path,
            "title" => title,
            "size" => size,
            "sha256" => sha256,
            # Completing with a channel/thread publishes a standalone file message.
            # Failed removal shares captured files directly; successful results use Canvas.
            "delivery_mode" =>
              if(SalixMeet.Outcome.partial_recording?(state), do: "thread", else: "canvas_embed"),
            "channel_id" => channel,
            "thread_ts" => thread,
            "started_at" => attempt.started_at,
            "attempt_count" => attempt.attempt_count,
            "reconcile_attempts" => 0
          }

          intents2 = Map.put(intents, kind, intent)

          case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
            {:ok, _doc, _etag} ->
              upload_artifact_stream(
                meeting_id,
                fence,
                token,
                kind,
                acc,
                intents2,
                intent,
                upload_url,
                stream
              )

            {:error, _} = err ->
              err
          end
        end
      rescue
        error in API.Error ->
          if retryable_api_error?(error) do
            retry_or_abandon_artifact(
              meeting_id,
              fence,
              kind,
              acc,
              intents,
              prior_intent,
              path,
              "upload_ticket_unavailable",
              API.error_message(error)
            )
          else
            abandon_artifact(
              meeting_id,
              fence,
              kind,
              acc,
              intents,
              prior_intent,
              path,
              "upload_ticket_rejected",
              API.error_message(error)
            )
          end
      end
    end
  end

  defp workspace_artifact_stream(agent_id, path) do
    with {:ok, stat} <- SalixMeet.Ports.AgentRuntime.stat_workspace(agent_id, path),
         {:ok, size, sha256} <- normalize_artifact_stat(stat) do
      if size == 0 do
        {:ok, :empty}
      else
        case SalixMeet.Ports.AgentRuntime.stream_workspace_read(agent_id, path) do
          {:ok, stream, ^size} -> {:ok, stream, size, sha256}
          {:ok, _stream, _reported_size} -> {:error, :artifact_size_mismatch}
          {:error, _reason} = error -> error
        end
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp normalize_artifact_stat(stat) when is_map(stat) do
    size = stat[:size] || stat["size"]
    sha256 = trim(stat[:hash] || stat["hash"])

    if is_integer(size) and size >= 0,
      do: {:ok, size, sha256},
      else: {:error, :artifact_stat_invalid}
  end

  defp normalize_artifact_stat(_stat), do: {:error, :artifact_stat_invalid}

  defp handle_artifact_source_failure(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         path,
         reason
       ) do
    case artifact_source_failure(reason) do
      {:permanent, failure_kind} ->
        abandon_artifact(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          intent,
          path,
          failure_kind,
          reason
        )

      {:retryable, failure_kind} ->
        retry_or_abandon_artifact(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          intent,
          path,
          failure_kind,
          reason
        )
    end
  end

  defp artifact_source_failure(:not_found), do: {:permanent, "source_missing"}

  defp artifact_source_failure(reason)
       when reason in [:artifact_stat_invalid, :artifact_size_mismatch],
       do: {:permanent, "source_invalid"}

  defp artifact_source_failure(_reason), do: {:retryable, "source_unavailable"}

  defp retry_or_abandon_artifact(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         path,
         failure_kind,
         reason
       ) do
    now = System.system_time(:second)
    attempt = artifact_attempt(intent, path)
    attempt_count = attempt.attempt_count + 1

    retryable = %{
      "status" => "retryable",
      "path" => path,
      "failure_kind" => failure_kind,
      "attempt_count" => attempt_count,
      "started_at" => attempt.started_at,
      "last_error" => artifact_failure_reason(reason)
    }

    if artifact_retry_expired?(attempt_count, attempt.started_at, now) do
      checkpoint_abandoned_artifact(
        meeting_id,
        fence,
        kind,
        acc,
        intents,
        Map.put(retryable, "status", "abandoned")
      )
    else
      intents2 = Map.put(intents, kind, retryable)

      case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
        {:ok, _doc, _etag} ->
          {:error, {:artifact_upload_retryable, kind, failure_kind}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp abandon_artifact(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         path,
         failure_kind,
         reason
       ) do
    attempt = artifact_attempt(intent, path)

    abandoned =
      intent
      |> Map.take(~w(file_id title size sha256 channel_id thread_ts reconcile_attempts))
      |> Map.merge(%{
        "status" => "abandoned",
        "path" => path,
        "failure_kind" => failure_kind,
        "attempt_count" => attempt.attempt_count + 1,
        "started_at" => attempt.started_at,
        "last_error" => artifact_failure_reason(reason)
      })

    checkpoint_abandoned_artifact(meeting_id, fence, kind, acc, intents, abandoned)
  end

  defp checkpoint_abandoned_artifact(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         abandoned
       ) do
    intents2 = Map.put(intents, kind, abandoned)

    case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
      {:ok, _doc, _etag} -> {:ok, acc, intents2}
      {:error, _} = error -> error
    end
  end

  defp artifact_attempt(intent, path) when is_map(intent) do
    same_path? = trim(intent["path"]) == path

    started_at =
      if same_path? and is_integer(intent["started_at"]) and intent["started_at"] > 0,
        do: intent["started_at"],
        else: System.system_time(:second)

    attempt_count =
      if same_path? and is_integer(intent["attempt_count"]) and intent["attempt_count"] >= 0,
        do: intent["attempt_count"],
        else: 0

    %{started_at: started_at, attempt_count: attempt_count}
  end

  defp artifact_attempt(_intent, _path),
    do: %{started_at: System.system_time(:second), attempt_count: 0}

  defp artifact_retry_expired?(attempt_count, started_at, now) do
    attempt_count >= @artifact_retry_min_attempts and
      now - started_at >= @artifact_retry_grace_seconds
  end

  defp artifact_failure_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp artifact_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp artifact_failure_reason(reason),
    do: reason |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)

  defp upload_artifact_stream(
         meeting_id,
         fence,
         token,
         kind,
         acc,
         intents,
         intent,
         upload_url,
         stream
       ) do
    case upload_stream_result(upload_url, stream, intent["size"]) do
      :ok ->
        authorize_artifact_completion(meeting_id, fence, token, kind, acc, intents, intent)

      {:api_error, error} ->
        cond do
          ambiguous_write_error?(error) ->
            authorize_artifact_completion(
              meeting_id,
              fence,
              token,
              kind,
              acc,
              intents,
              Map.put(intent, "last_error", API.error_message(error))
            )

          retryable_api_error?(error) ->
            retry_or_abandon_artifact(
              meeting_id,
              fence,
              kind,
              acc,
              intents,
              intent,
              intent["path"],
              "upload_retry_exhausted",
              API.error_message(error)
            )

          true ->
            abandon_artifact(
              meeting_id,
              fence,
              kind,
              acc,
              intents,
              intent,
              intent["path"],
              "upload_rejected",
              API.error_message(error)
            )
        end

      {:stream_error, reason} ->
        retry_or_abandon_artifact(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          intent,
          intent["path"],
          "source_unavailable",
          reason
        )
    end
  end

  defp upload_stream_result(upload_url, stream, size) do
    API.upload_stream_to_url(upload_url, stream, size)
  rescue
    error in API.Error -> {:api_error, error}
    error -> {:stream_error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:stream_error, {kind, reason}}
  end

  # Checkpointing "completing" is the one durable authorization for
  # files.completeUploadExternal. A later claim never blindly completes that
  # intent again; it reconciles the known file id instead.
  defp authorize_artifact_completion(meeting_id, fence, token, kind, acc, intents, intent) do
    completing =
      intent
      |> Map.put("status", "completing")
      |> Map.put_new("started_at", System.system_time(:second))
      |> Map.put_new("reconcile_attempts", 0)

    intents2 = Map.put(intents, kind, completing)

    case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
      {:ok, _doc, _etag} ->
        complete_artifact_once(meeting_id, fence, token, kind, acc, intents2, completing)

      {:error, _} = err ->
        err
    end
  end

  defp complete_artifact_once(meeting_id, fence, token, kind, acc, intents, intent) do
    try do
      completed =
        complete_artifact_upload(token, intent)

      case completed["files"] do
        [%{"id" => file_id}] when is_binary(file_id) and file_id != "" ->
          if trim(file_id) == trim(intent["file_id"]) do
            finalize_artifact_upload(meeting_id, fence, token, kind, acc, intents, intent, %{})
          else
            {:error, {:artifact_file_id_mismatch, intent["file_id"], file_id}}
          end

        _unverified ->
          {:error, {:artifact_completion_unknown, kind, intent["file_id"]}}
      end
    rescue
      e in API.Error ->
        handle_artifact_completion_error(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          intent,
          e
        )
    end
  end

  defp handle_artifact_completion_error(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         error
       ) do
    message = API.error_message(error)

    cond do
      completion_definitely_not_started?(error) ->
        retryable =
          intent
          |> Map.put("status", "uploading")
          |> Map.put("last_error", message)

        intents2 = Map.put(intents, kind, retryable)

        case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
          {:ok, _doc, _etag} -> {:error, message}
          {:error, _} = err -> err
        end

      dead_upload_ticket?(error) ->
        retry_or_abandon_artifact(
          meeting_id,
          fence,
          kind,
          acc,
          intents,
          intent,
          intent["path"],
          "upload_ticket_dead",
          message
        )

      true ->
        unresolved = Map.put(intent, "last_error", message)
        intents2 = Map.put(intents, kind, unresolved)

        case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
          {:ok, _doc, _etag} -> {:error, message}
          {:error, _} = err -> err
        end
    end
  end

  defp reconcile_artifact_upload(meeting_id, fence, token, kind, acc, intents, intent) do
    with :ok <- ensure_owns_claim(meeting_id, fence) do
      try do
        info = API.file_info(token, intent["file_id"])

        if artifact_info_matches?(info, intent) do
          finalize_artifact_upload(meeting_id, fence, token, kind, acc, intents, intent, info)
        else
          artifact_reconciliation_missing(
            meeting_id,
            fence,
            kind,
            acc,
            intents,
            intent,
            "files.info did not return the staged file"
          )
        end
      rescue
        e in API.Error ->
          cond do
            dead_upload_ticket?(e) ->
              artifact_reconciliation_missing(
                meeting_id,
                fence,
                kind,
                acc,
                intents,
                intent,
                API.error_message(e)
              )

            retryable_api_error?(e) ->
              artifact_reconciliation_missing(
                meeting_id,
                fence,
                kind,
                acc,
                intents,
                intent,
                API.error_message(e)
              )

            true ->
              abandon_artifact_reconciliation(
                meeting_id,
                fence,
                kind,
                acc,
                intents,
                Map.update(intent, "reconcile_attempts", 1, &(&1 + 1)),
                API.error_message(e)
              )
          end
      end
    end
  end

  defp artifact_reconciliation_missing(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         reason
       ) do
    attempts = (intent["reconcile_attempts"] || 0) + 1
    now = System.system_time(:second)

    if artifact_reconciliation_expired?(intent, attempts, now) do
      abandon_artifact_reconciliation(
        meeting_id,
        fence,
        kind,
        acc,
        intents,
        Map.put(intent, "reconcile_attempts", attempts),
        reason
      )
    else
      unresolved =
        intent
        |> Map.put("reconcile_attempts", attempts)
        |> Map.put("last_reconciled_at", now)
        |> Map.put("last_error", reason)

      intents2 = Map.put(intents, kind, unresolved)

      case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
        {:ok, _doc, _etag} -> {:error, {:artifact_upload_unknown, kind, intent["file_id"]}}
        {:error, _} = err -> err
      end
    end
  end

  defp artifact_reconciliation_expired?(intent, attempts, now) do
    started_at = intent["started_at"] || 0

    attempts >= @artifact_retry_min_attempts and is_integer(started_at) and
      now - started_at >= @artifact_retry_grace_seconds
  end

  # Strict at-most-once fallback: once completion may have happened, an
  # unresolved ticket is never replaced by a second file id. After bounded
  # reconciliation the summary is allowed to publish without that artifact.
  defp abandon_artifact_reconciliation(
         meeting_id,
         fence,
         kind,
         acc,
         intents,
         intent,
         reason
       ) do
    abandoned =
      intent
      |> Map.put("status", "abandoned")
      |> Map.put("failure_kind", "completion_unavailable")
      |> Map.put("last_error", reason)

    intents2 = Map.put(intents, kind, abandoned)

    case checkpoint(meeting_id, fence, %{"artifact_uploads" => intents2}) do
      {:ok, _doc, _etag} -> {:ok, acc, intents2}
      {:error, _} = err -> err
    end
  end

  # Persist the verified file id BEFORE the fallible permalink lookup, so any
  # files.info failure loses only the re-derivable permalink.
  defp finalize_artifact_upload(
         meeting_id,
         fence,
         token,
         kind,
         acc,
         intents,
         intent,
         info
       ) do
    file_id = trim(intent["file_id"])

    record = %{"file_id" => file_id, "path" => intent["path"]}

    record =
      case trim(info["permalink"]) do
        "" -> record
        permalink -> Map.put(record, "permalink", permalink)
      end

    acc2 = Map.put(acc, kind, record)
    intents2 = Map.delete(intents, kind)

    case checkpoint(meeting_id, fence, %{
           "artifacts" => acc2,
           "artifact_uploads" => intents2
         }) do
      {:ok, _doc, _etag} ->
        {:ok, hydrated} = hydrate_artifact_permalink(token, record)
        {:ok, Map.put(acc, kind, hydrated), intents2}

      {:error, _} = err ->
        _ =
          compensate_unreferenced_paths(
            meeting_id,
            [
              ["artifacts", kind, "file_id"],
              ["artifact_uploads", kind, "file_id"]
            ],
            file_id,
            "file",
            fn -> if file_id != "", do: API.delete_file(token, file_id) end
          )

        err
    end
  end

  defp artifact_info_matches?(info, intent) when is_map(info) do
    id_matches? = trim(info["id"]) == trim(intent["file_id"])
    size = info["size"]
    size_matches? = not is_integer(size) or size == intent["size"]

    destinations =
      List.wrap(info["channels"]) ++ List.wrap(info["groups"]) ++ List.wrap(info["ims"])

    channel = trim(intent["channel_id"])

    destination_matches? =
      intent["delivery_mode"] == "canvas_embed" or channel == "" or channel in destinations

    thread_matches? =
      intent["delivery_mode"] == "canvas_embed" or artifact_thread_matches?(info, intent, channel)

    id_matches? and size_matches? and destination_matches? and thread_matches?
  end

  defp artifact_info_matches?(_info, _intent), do: false

  defp artifact_thread_matches?(info, intent, channel) do
    thread = trim(intent["thread_ts"])

    if thread == "" do
      true
    else
      info
      |> Map.get("shares", %{})
      |> Map.values()
      |> Enum.flat_map(fn sharing_scope -> List.wrap(sharing_scope[channel]) end)
      |> Enum.any?(&(trim(&1["thread_ts"]) == thread))
    end
  end

  # Failed-removal and legacy intents retain destination sharing. Canvas embeds
  # omit it so successful summaries do not emit one file message per artifact.
  defp complete_artifact_upload(token, %{"delivery_mode" => "canvas_embed"} = intent) do
    API.complete_upload_external(token, [
      %{"id" => intent["file_id"], "title" => intent["title"]}
    ])
  end

  defp complete_artifact_upload(token, intent) do
    API.complete_upload_external(
      token,
      [%{"id" => intent["file_id"], "title" => intent["title"]}],
      channel: intent["channel_id"],
      thread_ts: intent["thread_ts"]
    )
  end

  defp completion_definitely_not_started?(%API.Error{retry_after: secs})
       when is_integer(secs),
       do: true

  defp completion_definitely_not_started?(%API.Error{status: 429}), do: true

  defp completion_definitely_not_started?(%API.Error{message: message}),
    do: to_string(message) in ["ratelimited", "rate_limited"]

  defp dead_upload_ticket?(%API.Error{message: message}),
    do: to_string(message) == "file_not_found"

  defp hydrate_artifact_permalink(_token, %{"permalink" => p} = artifact)
       when is_binary(p) and p != "",
       do: {:ok, artifact}

  defp hydrate_artifact_permalink(token, %{"file_id" => file_id} = artifact) do
    case token |> API.file_info(file_id) |> Map.get("permalink", "") |> trim() do
      "" -> {:ok, artifact}
      permalink -> {:ok, Map.put(artifact, "permalink", permalink)}
    end
  rescue
    _error in API.Error -> {:ok, artifact}
  end

  defp ensure_canvas(
         meeting_id,
         fence,
         token,
         bot_user_id,
         workspace_id,
         state,
         uploads,
         delivery
       ) do
    with {:ok, canvas_id} <-
           ensure_canvas_created(
             meeting_id,
             fence,
             token,
             bot_user_id,
             state,
             uploads,
             delivery
           ),
         :ok <- require_canvas_id(canvas_id),
         :ok <- ensure_canvas_titled(meeting_id, fence, token, canvas_id),
         {:ok, canvas_url} <-
           ensure_canvas_url(meeting_id, fence, token, workspace_id, canvas_id) do
      {:ok, canvas_id, canvas_url}
    end
  end

  defp require_canvas_id(canvas_id) do
    if trim(canvas_id) == "" do
      canvas_unavailable("Canvas creation completed without a canvas_id")
    else
      :ok
    end
  end

  defp ensure_canvas_created(
         meeting_id,
         fence,
         token,
         bot_user_id,
         state,
         uploads,
         delivery
       ) do
    canvas_id = trim(delivery["canvas_id"])
    intent = stringify(delivery["canvas_create"] || %{})

    provisional_canvas_id =
      if intent["schema_version"] in [2, 3, 4], do: trim(intent["canvas_id"]), else: ""

    cond do
      canvas_id != "" ->
        {:ok, canvas_id}

      provisional_canvas_id != "" ->
        {:ok, provisional_canvas_id}

      intent == %{} ->
        stage_canvas_create(meeting_id, fence, token, bot_user_id, state, uploads)

      intent["status"] in [
        "v4_creating",
        "v4_unknown",
        "v4_fallback_creating",
        "v4_fallback_unknown",
        "v3_creating",
        "v3_unknown",
        "v2_creating",
        "v2_fallback_creating",
        "v2_fallback_unknown",
        "v2_unknown",
        "creating",
        "unknown",
        "conflict"
      ] ->
        reconcile_canvas_create(meeting_id, fence, token, bot_user_id, intent)

      intent["status"] in [
        "v4_create_retryable",
        "v4_fallback_retryable",
        "v3_create_retryable",
        "v2_create_retryable",
        "v2_fallback_retryable",
        "create_retryable"
      ] ->
        retry_canvas_create(meeting_id, fence, token, bot_user_id, state, uploads, intent)

      intent["status"] == "retryable" ->
        # Older unversioned documents used this status for both a definitely
        # rejected create and a successful create whose coupled access grant
        # was rate limited. Reconcile before authorizing a new create, or a
        # rolling deploy can leak a duplicate Canvas.
        if intent["schema_version"] == 2 and intent["retry_create_after_empty"] != true do
          retry_canvas_create(meeting_id, fence, token, bot_user_id, state, uploads, intent)
        else
          reconcile_canvas_create(meeting_id, fence, token, bot_user_id, intent)
        end

      intent["status"] in ["abandoned", "v2_abandoned", "v4_abandoned"] ->
        canvas_unavailable(intent["last_error"] || "Canvas creation was abandoned")

      true ->
        {:error, {:canvas_create_unresolved, intent["status"]}}
    end
  end

  defp stage_canvas_create(meeting_id, fence, token, bot_user_id, state, uploads) do
    ref = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    now = System.system_time(:second)
    {markdown, body_probe} = canvas_content_with_body_probe(canvas_markdown(state, uploads))

    intent =
      %{
        "schema_version" => 4,
        "ref" => ref,
        "temporary_title" => "Comma summary delivery " <> ref,
        "target_title" => canvas_title(state),
        "content_variant" => "rich",
        "content_fingerprint" => canvas_content_fingerprint(markdown),
        "body_probe" => body_probe,
        # Exact-body base workers deliberately do not recognize v4 statuses.
        # During rolling deploys they must fail this claim rather than adopting a
        # standalone Canvas before its body proof and publication are durable.
        "status" => "v4_creating",
        "started_at" => now,
        "reconcile_ts_from" => max(now - 60, 0),
        "reconcile_ts_to" => now + @canvas_reconcile_grace_seconds,
        "reconcile_attempts" => 0
      }
      |> put_canvas_creator(bot_user_id)

    case checkpoint(meeting_id, fence, %{"canvas_create" => intent}) do
      {:ok, _doc, _etag} ->
        create_canvas_once(meeting_id, fence, token, state, uploads, intent)

      {:error, _} = err ->
        err
    end
  end

  defp retry_canvas_create(meeting_id, fence, token, bot_user_id, state, uploads, intent) do
    now = System.system_time(:second)

    creating =
      intent
      |> Map.put("schema_version", canvas_intent_schema(intent))
      |> Map.put("status", canvas_creating_status(intent))
      |> Map.put("started_at", now)
      |> Map.put("reconcile_ts_from", max(now - 60, 0))
      |> Map.put("reconcile_ts_to", now + @canvas_reconcile_grace_seconds)
      |> put_canvas_creator(bot_user_id)
      |> Map.put("reconcile_attempts", 0)
      |> Map.delete("canvas_id")
      |> Map.delete("retry_create_after_empty")
      |> Map.delete("last_error")

    case checkpoint(meeting_id, fence, %{"canvas_create" => creating}) do
      {:ok, _doc, _etag} ->
        create_canvas_once(meeting_id, fence, token, state, uploads, creating)

      {:error, _} = err ->
        err
    end
  end

  # A staged intent permits exactly one create call. If Slack's response or the
  # following id checkpoint is uncertain, the uniquely titled Canvas is left in
  # place so a later claim can find it instead of creating another one.
  defp create_canvas_once(meeting_id, fence, token, state, uploads, intent) do
    with :ok <- ensure_owns_claim(meeting_id, fence) do
      try do
        canvas_id =
          token
          |> API.create_canvas(
            intent["temporary_title"],
            canvas_content_for_intent(intent, state, uploads)
          )
          |> trim()

        if canvas_id == "" do
          unknown =
            intent
            |> Map.put("status", canvas_unknown_status(intent))
            |> Map.put("last_error", "canvases.create returned no canvas_id")

          with {:ok, _doc, _etag} <-
                 checkpoint(meeting_id, fence, %{"canvas_create" => unknown}) do
            {:error, {:canvas_create_unknown, "missing_canvas_id"}}
          end
        else
          created =
            intent
            |> Map.put("schema_version", canvas_intent_schema(intent))
            |> Map.put("status", canvas_created_status(intent))
            |> Map.put("canvas_id", canvas_id)
            |> Map.delete("retry_create_after_empty")

          case checkpoint(meeting_id, fence, %{
                 "canvas_create" => created,
                 "canvas_access" => new_canvas_access_intent()
               }) do
            {:ok, _doc, _etag} -> {:ok, canvas_id}
            {:error, _} = err -> err
          end
        end
      rescue
        e in API.Error ->
          canvas_create_failed(meeting_id, fence, token, state, uploads, e, intent)
      end
    end
  end

  defp canvas_create_failed(meeting_id, fence, token, state, uploads, error, intent) do
    reason = canvas_create_error_message(error)

    cond do
      canvas_content_rejected?(error) and intent["content_variant"] != "plain" ->
        retry_canvas_with_plain_content(
          meeting_id,
          fence,
          token,
          state,
          uploads,
          intent,
          reason
        )

      definitely_rejected_create?(error) ->
        retryable =
          intent
          |> Map.put("status", canvas_retryable_status(intent))
          |> Map.put("last_error", reason)

        with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_create" => retryable}) do
          {:error, reason}
        end

      ambiguous_write_error?(error) ->
        unknown =
          intent
          |> Map.put("status", canvas_unknown_status(intent))
          |> Map.put("last_error", reason)

        with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_create" => unknown}) do
          {:error, {:canvas_create_unknown, reason}}
        end

      true ->
        abandoned =
          intent
          |> Map.put("status", canvas_abandoned_status(intent))
          |> Map.put("last_error", reason)

        case checkpoint(meeting_id, fence, %{
               "canvas_create" => abandoned,
               "canvas_error" => reason
             }) do
          {:ok, _doc, _etag} -> canvas_unavailable(reason)
          {:error, _} = err -> err
        end
    end
  end

  defp retry_canvas_with_plain_content(
         meeting_id,
         fence,
         token,
         state,
         uploads,
         intent,
         rich_content_error
       ) do
    {plain_markdown, body_probe} =
      canvas_content_with_body_probe(canvas_plain_markdown(state, uploads))

    fallback =
      intent
      |> Map.put("content_variant", "plain")
      |> Map.put("content_fingerprint", canvas_content_fingerprint(plain_markdown))
      |> Map.put("body_probe", body_probe)
      |> Map.put("rich_content_error", rich_content_error)

    fallback = Map.put(fallback, "status", canvas_creating_status(fallback))

    case checkpoint(meeting_id, fence, %{"canvas_create" => fallback}) do
      {:ok, _doc, _etag} ->
        create_canvas_once(meeting_id, fence, token, state, uploads, fallback)

      {:error, _} = error ->
        error
    end
  end

  defp canvas_content_for_intent(intent, state, uploads) do
    markdown =
      if intent["content_variant"] == "plain",
        do: canvas_plain_markdown(state, uploads),
        else: canvas_markdown(state, uploads)

    append_canvas_body_probe(markdown, trim(intent["body_probe"]))
  end

  defp canvas_content_with_body_probe(markdown) do
    body_probe =
      @canvas_body_probe_prefix <> (markdown |> Crypto.hex() |> binary_part(0, 24))

    {append_canvas_body_probe(markdown, body_probe), body_probe}
  end

  defp append_canvas_body_probe(markdown, ""), do: markdown

  defp append_canvas_body_probe(markdown, body_probe) do
    markdown <> "\n\n_Comma delivery ID: `#{body_probe}`_"
  end

  defp canvas_content_fingerprint(markdown), do: "sha256:" <> Crypto.hex(markdown)

  defp ensure_canvas_body_verified(meeting_id, fence, token, canvas_id) do
    # Protocol anchor: SlackCanvasDelivery.VerifyCanvasBodyProbe,
    # RetryCanvasBodyReadback, and AbandonCanvasBodyAfterBound. Current-schema
    # delivery cannot share or publish before the durable "verified" state;
    # verification means Slack returned the per-document visible body probe.
    # Slack creates from Markdown but downloads rendered Quip HTML, so the probe
    # crosses that representation boundary without comparing the whole body.
    # Only the explicit pre-v3 branch below bypasses body proof.
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, doc, _etag} <- Store.get(meeting_id) do
      delivery = stringify(get_in(doc, ["state", "delivery"]) || %{})
      intent = stringify(delivery["canvas_create"] || %{})
      verification = stringify(delivery["canvas_body"] || %{})
      submitted = trim(intent["content_fingerprint"])
      body_probe = trim(intent["body_probe"])

      cond do
        verification["status"] == "abandoned" ->
          canvas_unavailable(
            verification["last_error"] || delivery["canvas_error"] ||
              "Canvas body verification was abandoned"
          )

        submitted == "" ->
          # Rolling records created before schema v3 have no submitted-body
          # identity and retain the legacy bypass.
          :ok

        canvas_body_verified_for_submitted?(verification, submitted, body_probe) ->
          :ok

        true ->
          verify_canvas_body(
            meeting_id,
            fence,
            token,
            canvas_id,
            submitted,
            body_probe,
            verification
          )
      end
    end
  end

  defp canvas_body_verified_for_submitted?(verification, submitted, body_probe) do
    current_contract? =
      body_probe != "" and
        verification["status"] == "verified" and
        verification["verification_contract"] == "provider_body_probe_v1" and
        verification["submitted_fingerprint"] == submitted and
        verification["body_probe"] == body_probe

    # Schema-v1 workers persisted this record only after exact fingerprint
    # equality. Preserve that stronger durable proof across a rolling upgrade.
    legacy_exact_contract? =
      verification["schema_version"] == 1 and
        verification["status"] == "verified" and
        verification["expected_fingerprint"] == submitted and
        verification["observed_fingerprint"] == submitted

    current_contract? or legacy_exact_contract?
  end

  defp verify_canvas_body(
         meeting_id,
         fence,
         token,
         canvas_id,
         submitted,
         body_probe,
         verification
       ) do
    attempts = (verification["attempt_count"] || 0) + 1

    try do
      {_file, content} = API.canvas_file_and_content(token, canvas_id)
      observed = canvas_content_fingerprint(content)
      failure = canvas_body_verification_failure(content, observed, submitted, body_probe)

      if is_nil(failure) do
        verified =
          %{
            "schema_version" => 3,
            "status" => "verified",
            "verification_contract" => canvas_body_verification_contract(body_probe),
            "submitted_fingerprint" => submitted,
            "observed_fingerprint" => observed,
            "observed_bytes" => byte_size(content),
            "attempt_count" => attempts,
            "started_at" => verification["started_at"] || System.system_time(:second),
            "verified_at" => System.system_time(:millisecond)
          }
          |> put_canvas_body_probe(body_probe)

        with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_body" => verified}) do
          :ok
        end
      else
        retry_canvas_body(
          meeting_id,
          fence,
          verification,
          attempts,
          submitted,
          body_probe,
          failure
        )
      end
    rescue
      error in API.Error ->
        reason = "Canvas body read-back failed: " <> API.error_message(error)

        if retryable_api_error?(error) do
          retry_canvas_body(
            meeting_id,
            fence,
            verification,
            attempts,
            submitted,
            body_probe,
            reason
          )
        else
          abandon_canvas_body(
            meeting_id,
            fence,
            verification,
            attempts,
            submitted,
            body_probe,
            reason
          )
        end
    end
  end

  defp canvas_body_verification_failure(content, _observed, _submitted, _body_probe)
       when byte_size(content) == 0,
       do: "Canvas body read-back was empty"

  defp canvas_body_verification_failure(content, observed, submitted, body_probe) do
    cond do
      String.trim(content) == "" ->
        "Canvas body read-back was empty"

      body_probe != "" and not String.contains?(content, body_probe) ->
        "Canvas body read-back did not contain the staged body probe"

      body_probe == "" and observed != submitted ->
        "Canvas body read-back did not match the submitted content"

      true ->
        nil
    end
  end

  defp canvas_body_verification_contract(""), do: "exact_body_sha256_v1"
  defp canvas_body_verification_contract(_body_probe), do: "provider_body_probe_v1"

  defp retry_canvas_body(
         meeting_id,
         fence,
         verification,
         attempts,
         submitted,
         body_probe,
         reason
       ) do
    now = System.system_time(:second)
    started_at = verification["started_at"] || now

    if attempts >= @canvas_body_min_attempts and
         now - started_at >= @canvas_body_grace_seconds do
      abandon_canvas_body(
        meeting_id,
        fence,
        verification,
        attempts,
        submitted,
        body_probe,
        reason
      )
    else
      pending =
        verification
        |> Map.put("schema_version", 3)
        |> Map.put("status", "pending")
        |> Map.put("verification_contract", canvas_body_verification_contract(body_probe))
        |> Map.put("submitted_fingerprint", submitted)
        |> Map.put("attempt_count", attempts)
        |> Map.put("started_at", started_at)
        |> Map.put("last_checked_at", now)
        |> Map.put("last_error", reason)
        |> put_canvas_body_probe(body_probe)

      with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_body" => pending}) do
        {:error, :canvas_body_unverified}
      end
    end
  end

  defp abandon_canvas_body(
         meeting_id,
         fence,
         verification,
         attempts,
         submitted,
         body_probe,
         reason
       ) do
    abandoned =
      verification
      |> Map.put("schema_version", 3)
      |> Map.put("status", "abandoned")
      |> Map.put("verification_contract", canvas_body_verification_contract(body_probe))
      |> Map.put("submitted_fingerprint", submitted)
      |> Map.put("attempt_count", attempts)
      |> Map.put("started_at", verification["started_at"] || System.system_time(:second))
      |> Map.put("last_checked_at", System.system_time(:second))
      |> Map.put("last_error", reason)
      |> put_canvas_body_probe(body_probe)

    case checkpoint(meeting_id, fence, %{
           "canvas_body" => abandoned,
           "canvas_error" => reason
         }) do
      {:ok, _doc, _etag} -> canvas_unavailable(reason)
      {:error, _} = error -> error
    end
  end

  defp put_canvas_body_probe(verification, ""), do: Map.delete(verification, "body_probe")

  defp put_canvas_body_probe(verification, body_probe),
    do: Map.put(verification, "body_probe", body_probe)

  # Schema-v4 create statuses are deliberately unknown to the exact-body base
  # worker. It must fail closed while current workers own provider-body probes.
  defp canvas_creating_status(%{"schema_version" => 4, "content_variant" => "plain"}),
    do: "v4_fallback_creating"

  defp canvas_creating_status(%{"schema_version" => 4}), do: "v4_creating"

  defp canvas_creating_status(%{"content_variant" => "plain"}),
    do: "v2_fallback_creating"

  defp canvas_creating_status(_intent), do: "v3_creating"

  defp canvas_retryable_status(%{"schema_version" => 4, "content_variant" => "plain"}),
    do: "v4_fallback_retryable"

  defp canvas_retryable_status(%{"schema_version" => 4}), do: "v4_create_retryable"

  defp canvas_retryable_status(%{"content_variant" => "plain"}),
    do: "v2_fallback_retryable"

  defp canvas_retryable_status(_intent), do: "v3_create_retryable"

  defp canvas_unknown_status(%{"schema_version" => 4, "content_variant" => "plain"}),
    do: "v4_fallback_unknown"

  defp canvas_unknown_status(%{"schema_version" => 4}), do: "v4_unknown"

  defp canvas_unknown_status(%{"content_variant" => "plain"}),
    do: "v2_fallback_unknown"

  defp canvas_unknown_status(_intent), do: "v3_unknown"

  defp canvas_created_status(%{"schema_version" => 4}), do: "v4_created"
  defp canvas_created_status(_intent), do: "v3_created"

  defp canvas_abandoned_status(%{"schema_version" => 4}), do: "v4_abandoned"
  defp canvas_abandoned_status(_intent), do: "v2_abandoned"

  defp canvas_intent_schema(%{"schema_version" => 4}), do: 4
  defp canvas_intent_schema(_intent), do: 3

  defp canvas_content_rejected?(%API.Error{
         message: "canvas_creation_failed",
         body: %{"detail" => detail}
       })
       when is_binary(detail) do
    String.match?(String.trim(detail), ~r/\A'?content'?\s+error:/i) or
      String.contains?(String.downcase(detail), "document_content")
  end

  defp canvas_content_rejected?(_error), do: false

  defp canvas_create_error_message(%API.Error{body: body} = error) do
    detail =
      if is_map(body) and is_binary(body["detail"]), do: String.trim(body["detail"]), else: ""

    message = API.error_message(error)

    if detail == "", do: message, else: message <> ": " <> String.slice(detail, 0, 500)
  end

  defp reconcile_canvas_create(meeting_id, fence, token, bot_user_id, intent) do
    normalized_intent = normalize_canvas_reconciliation_intent(intent, bot_user_id)

    try do
      with :ok <- ensure_owns_claim(meeting_id, fence) do
        case matching_canvases(token, normalized_intent, bot_user_id) do
          {:ok, [%{"id" => canvas_id}]} when is_binary(canvas_id) and canvas_id != "" ->
            attempts = (normalized_intent["reconcile_attempts"] || 0) + 1

            found =
              normalized_intent
              |> Map.put("schema_version", canvas_intent_schema(normalized_intent))
              |> Map.put("status", canvas_created_status(normalized_intent))
              |> Map.put("canvas_id", canvas_id)
              |> Map.put("reconcile_attempts", attempts)

            case checkpoint(meeting_id, fence, %{
                   "canvas_create" => found,
                   "canvas_access" => new_canvas_access_intent()
                 }) do
              {:ok, _doc, _etag} -> {:ok, canvas_id}
              {:error, _} = err -> err
            end

          {:ok, []} ->
            if canvas_retry_authorizable?(normalized_intent) do
              authorize_canvas_create_retry(meeting_id, fence, normalized_intent)
            else
              advance_canvas_reconciliation(
                meeting_id,
                fence,
                normalized_intent,
                "Canvas creation could not be confirmed after bounded reconciliation",
                {:canvas_create_unknown, normalized_intent["ref"]}
              )
            end

          {:ok, _multiple} ->
            advance_canvas_reconciliation(
              meeting_id,
              fence,
              normalized_intent,
              "Canvas reconciliation found multiple matching Canvases",
              {:canvas_create_conflict, normalized_intent["ref"]}
            )

          {:error, reason} ->
            message = "Canvas reconciliation incomplete: " <> canvas_reconciliation_reason(reason)

            advance_canvas_reconciliation(
              meeting_id,
              fence,
              normalized_intent,
              message,
              {:canvas_reconciliation_incomplete, reason}
            )
        end
      end
    rescue
      e in API.Error ->
        canvas_reconciliation_api_error(meeting_id, fence, normalized_intent, e)
    end
  end

  defp normalize_canvas_reconciliation_intent(intent, bot_user_id) do
    started_at = intent["started_at"]

    intent =
      intent
      |> Map.put("schema_version", canvas_intent_schema(intent))
      |> maybe_put_canvas_reconcile_bound(
        "reconcile_ts_from",
        if(is_integer(started_at), do: max(started_at - 60, 0))
      )
      |> maybe_put_canvas_reconcile_bound(
        "reconcile_ts_to",
        if(is_integer(started_at), do: started_at + @canvas_reconcile_grace_seconds)
      )

    intent = put_canvas_creator(intent, intent["creator_user_id"] || bot_user_id)

    cond do
      intent["content_variant"] == "plain" ->
        Map.delete(intent, "retry_create_after_empty")

      intent["status"] == "retryable" ->
        Map.put(intent, "retry_create_after_empty", true)

      true ->
        intent
    end
  end

  defp put_canvas_creator(intent, creator_user_id) do
    case trim(creator_user_id) do
      "" -> Map.delete(intent, "creator_user_id")
      creator_user_id -> Map.put(intent, "creator_user_id", creator_user_id)
    end
  end

  defp maybe_put_canvas_reconcile_bound(intent, _key, nil), do: intent

  defp maybe_put_canvas_reconcile_bound(intent, key, value) do
    if is_integer(intent[key]), do: intent, else: Map.put(intent, key, value)
  end

  defp canvas_retry_authorizable?(intent) do
    attempts = (intent["reconcile_attempts"] || 0) + 1

    intent["content_variant"] != "plain" and intent["retry_create_after_empty"] == true and
      canvas_reconciliation_expired?(intent, attempts, System.system_time(:second))
  end

  defp authorize_canvas_create_retry(meeting_id, fence, intent) do
    retryable =
      intent
      |> Map.put("status", canvas_retryable_status(intent))
      |> Map.put("reconcile_attempts", (intent["reconcile_attempts"] || 0) + 1)
      |> Map.put("last_reconciled_at", System.system_time(:second))
      |> Map.put("last_error", "No Canvas was found after bounded legacy reconciliation")
      |> Map.delete("retry_create_after_empty")

    with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_create" => retryable}) do
      {:error, {:canvas_create_retry_authorized, intent["ref"]}}
    end
  end

  defp canvas_reconciliation_expired?(intent, attempts, now) do
    started_at = intent["started_at"] || 0

    attempts >= @canvas_reconcile_min_attempts and is_integer(started_at) and
      now - started_at >= @canvas_reconcile_grace_seconds
  end

  defp canvas_reconciliation_api_error(meeting_id, fence, intent, error) do
    if retryable_api_error?(error) do
      message = "Canvas reconciliation incomplete: " <> API.error_message(error)

      advance_canvas_reconciliation(
        meeting_id,
        fence,
        intent,
        message,
        API.error_message(error)
      )
    else
      abandon_canvas_reconciliation(
        meeting_id,
        fence,
        intent,
        (intent["reconcile_attempts"] || 0) + 1,
        "Canvas reconciliation failed: " <> API.error_message(error)
      )
    end
  end

  defp advance_canvas_reconciliation(meeting_id, fence, intent, reason, error_result) do
    attempts = (intent["reconcile_attempts"] || 0) + 1
    now = System.system_time(:second)

    if canvas_reconciliation_expired?(intent, attempts, now) do
      abandon_canvas_reconciliation(meeting_id, fence, intent, attempts, reason)
    else
      unknown =
        intent
        |> Map.put("status", canvas_unknown_status(intent))
        |> Map.put("reconcile_attempts", attempts)
        |> Map.put("last_reconciled_at", now)
        |> Map.put("last_error", reason)

      with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_create" => unknown}) do
        {:error, error_result}
      end
    end
  end

  defp abandon_canvas_reconciliation(meeting_id, fence, intent, attempts, reason) do
    abandoned =
      intent
      |> Map.put("status", canvas_abandoned_status(intent))
      |> Map.put("reconcile_attempts", attempts)
      |> Map.put("last_error", reason)

    case checkpoint(meeting_id, fence, %{
           "canvas_create" => abandoned,
           "canvas_error" => reason
         }) do
      {:ok, _doc, _etag} -> canvas_unavailable(reason)
      {:error, _} = err -> err
    end
  end

  defp canvas_unavailable(reason),
    do: {:error, {:terminal, {:canvas_unavailable, to_string(reason)}}}

  defp matching_canvases(token, intent, bot_user_id) do
    with {:ok, opts} <- canvas_list_opts(intent, bot_user_id),
         {:ok, files} <- list_canvas_pages(token, opts, 1, []) do
      matches =
        files
        |> Enum.filter(fn file ->
          trim(file["id"]) != "" and file["title"] == intent["temporary_title"]
        end)
        |> Enum.uniq_by(&trim(&1["id"]))

      {:ok, matches}
    end
  end

  defp canvas_list_opts(intent, bot_user_id) do
    started_at = intent["started_at"]

    if is_integer(started_at) do
      ts_from =
        case intent["reconcile_ts_from"] do
          value when is_integer(value) -> value
          _ -> max(started_at - 60, 0)
        end

      ts_to =
        case intent["reconcile_ts_to"] do
          value when is_integer(value) -> value
          _ -> started_at + @canvas_reconcile_grace_seconds
        end

      creator_user_id = trim(intent["creator_user_id"] || bot_user_id)
      opts = [ts_from: ts_from, ts_to: ts_to]
      opts = if creator_user_id == "", do: opts, else: Keyword.put(opts, :user, creator_user_id)
      {:ok, opts}
    else
      {:error, :canvas_reconcile_window_missing}
    end
  end

  defp list_canvas_pages(token, base_opts, page, acc) when page <= @canvas_reconcile_max_pages do
    body = API.list_canvases(token, Keyword.merge(base_opts, count: 100, page: page))

    files = acc ++ Map.get(body, "files", [])
    pages = get_in(body, ["paging", "pages"]) || page

    cond do
      pages == 0 and page == 1 and files == [] -> {:ok, []}
      not is_integer(pages) or pages < 1 -> {:error, :invalid_canvas_paging}
      pages > @canvas_reconcile_max_pages -> {:error, :canvas_list_incomplete}
      page < pages -> list_canvas_pages(token, base_opts, page + 1, files)
      true -> {:ok, files}
    end
  end

  defp list_canvas_pages(_token, _base_opts, _page, _acc), do: {:error, :canvas_list_incomplete}

  defp canvas_reconciliation_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp canvas_reconciliation_reason(reason), do: inspect(reason)

  defp new_canvas_access_intent do
    %{
      "schema_version" => 2,
      # Previous-release workers understand `pending` but run access.set before
      # sharing the link. Keep the v2 pre-grant state fail-closed during a
      # rolling deploy; only this release may advance it after the durable post.
      "status" => "v2_pending",
      "access_level" => "write",
      "target_ids" => [],
      "attempt_count" => 0
    }
  end

  defp ensure_canvas_access_target(
         _meeting_id,
         _fence,
         _token,
         _channel,
         _bot_user_id,
         "",
         _canvas_url
       ),
       do: :ok

  defp ensure_canvas_access_target(
         meeting_id,
         fence,
         token,
         channel,
         bot_user_id,
         _canvas_id,
         canvas_url
       ) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, doc, _etag} <- Store.get(meeting_id) do
      delivery = stringify(get_in(doc, ["state", "delivery"]) || %{})
      access = stringify(delivery["canvas_access"] || %{})

      cond do
        # Existing Canvas ids predate the standalone-access state machine and
        # were already channel-tabbed/shared. Do not add a new side effect when
        # resuming those documents.
        access == %{} ->
          :ok

        access["status"] in ["granted", "v2_granted"] ->
          :ok

        access["status"] in ["link_shared", "v2_link_shared"] ->
          abandon_canvas_access(
            meeting_id,
            fence,
            access,
            "Canvas access was not verified for every direct-message recipient"
          )

        access["status"] in ["abandoned", "v2_abandoned"] ->
          canvas_unavailable(access["last_error"] || "Canvas access was abandoned")

        access["status"] not in ["pending", "v2_pending"] ->
          {:error, {:canvas_access_unresolved, access["status"]}}

        trim(canvas_url) == "" ->
          abandon_canvas_access(
            meeting_id,
            fence,
            access,
            "Canvas access skipped because its permalink is unavailable"
          )

        valid_canvas_access_target?(access) ->
          :ok

        true ->
          resolve_and_stage_canvas_access(
            meeting_id,
            fence,
            token,
            channel,
            bot_user_id,
            access
          )
      end
    end
  end

  defp durable_summary_link_shared?(delivery) do
    trim(delivery["summary_message_ts"]) != "" and
      matching_message_kind?(trim(delivery["summary_message_kind"]), "summary")
  end

  defp resolve_and_stage_canvas_access(
         meeting_id,
         fence,
         token,
         channel,
         bot_user_id,
         access
       ) do
    case resolve_canvas_access_target(token, channel, bot_user_id) do
      {:ok, target_type, target_ids, strategy} ->
        targeted =
          access
          |> Map.put("target_type", target_type)
          |> Map.put("target_ids", target_ids)
          |> Map.put("grant_strategy", strategy)

        case checkpoint(meeting_id, fence, %{"canvas_access" => targeted}) do
          {:ok, _doc, _etag} -> :ok
          {:error, _} = err -> err
        end

      {:error, reason} ->
        abandon_canvas_access(
          meeting_id,
          fence,
          access,
          "Canvas access target could not be resolved: " <> canvas_access_reason(reason)
        )
    end
  rescue
    e in API.Error -> canvas_access_target_api_error(meeting_id, fence, access, e)
  end

  defp resolve_canvas_access_target(token, channel, _bot_user_id) do
    info = API.conversation_info(token, channel)

    cond do
      info["is_im"] == true ->
        case trim(info["user"]) do
          "" -> {:error, :dm_user_missing}
          user_id -> {:ok, "user_ids", [user_id], "set_access"}
        end

      info["is_mpim"] == true ->
        # Slack does not accept an MPDM channel id for Canvas access. It
        # requires individual user_ids, and each user must first receive the
        # Canvas directly. This delivery owns only the meeting thread post, so
        # do not claim publication from an unverified group link. A future
        # per-recipient durable DM protocol can add that capability explicitly.
        {:error, :mpdm_requires_individual_direct_shares}

      true ->
        case trim(channel) do
          "" -> {:error, :channel_missing}
          channel_id -> {:ok, "channel_ids", [channel_id], "set_access"}
        end
    end
  end

  defp canvas_access_target_api_error(meeting_id, fence, access, error) do
    reason = API.error_message(error)

    if retryable_api_error?(error) do
      retry_canvas_access(meeting_id, fence, access, reason)
    else
      abandon_canvas_access(
        meeting_id,
        fence,
        access,
        "Canvas access target could not be resolved: " <> reason
      )
    end
  end

  defp ensure_canvas_access_finalized(_meeting_id, _fence, _token, ""), do: :ok

  defp ensure_canvas_access_finalized(meeting_id, fence, token, canvas_id) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, doc, _etag} <- Store.get(meeting_id) do
      delivery = stringify(get_in(doc, ["state", "delivery"]) || %{})
      access = stringify(delivery["canvas_access"] || %{})

      cond do
        access == %{} and trim(delivery["canvas_id"]) != "" ->
          :ok

        access == %{} ->
          {:error, :canvas_access_checkpoint_missing}

        not durable_summary_link_shared?(delivery) ->
          {:error, :canvas_link_not_shared}

        access["status"] in ["granted", "v2_granted"] ->
          finalize_canvas_id_visibility(meeting_id, fence, canvas_id, delivery)

        access["status"] in ["abandoned", "v2_abandoned"] ->
          canvas_unavailable(access["last_error"] || "Canvas access was abandoned")

        access["status"] in ["pending", "v2_pending"] and
            valid_canvas_access_target?(access) ->
          with :ok <- grant_canvas_access(meeting_id, fence, token, canvas_id, access) do
            finalize_canvas_id_visibility(meeting_id, fence, canvas_id, delivery)
          end

        true ->
          {:error, {:canvas_access_unresolved, access["status"]}}
      end
    end
  end

  # Schema-v4 keeps the provisional id inside its exact-base-unknown intent
  # until mark_published/6 atomically exposes canvas_id with published_at.
  defp finalize_canvas_id_visibility(meeting_id, fence, canvas_id, delivery) do
    if get_in(delivery, ["canvas_create", "schema_version"]) == 4 do
      :ok
    else
      promote_canvas_id(meeting_id, fence, canvas_id)
    end
  end

  # Top-level canvas_id is the compatibility signal old workers use to assume
  # a Canvas is already channel-tabbed/shared. Publish it only after the v2
  # access result is terminal; the summary notice is checkpointed separately.
  defp promote_canvas_id(meeting_id, fence, canvas_id) do
    case checkpoint(meeting_id, fence, %{"canvas_id" => canvas_id}) do
      {:ok, _doc, _etag} -> :ok
      {:error, _} = err -> err
    end
  end

  defp grant_canvas_access(meeting_id, fence, token, canvas_id, access) do
    try do
      _ =
        API.set_canvas_access(
          token,
          canvas_id,
          access["target_type"],
          access["target_ids"],
          access["access_level"] || "write"
        )

      granted =
        access
        |> Map.put("status", canvas_access_granted_status(access))
        |> Map.put("attempt_count", (access["attempt_count"] || 0) + 1)
        |> Map.delete("last_error")

      case checkpoint(meeting_id, fence, %{"canvas_access" => granted}) do
        {:ok, _doc, _etag} -> :ok
        {:error, _} = err -> err
      end
    rescue
      e in API.Error -> canvas_access_api_error(meeting_id, fence, access, e)
    end
  end

  defp canvas_access_api_error(meeting_id, fence, access, error) do
    reason = API.error_message(error)

    if retryable_api_error?(error) do
      retry_canvas_access(meeting_id, fence, access, reason)
    else
      abandon_canvas_access(meeting_id, fence, access, reason)
    end
  end

  defp retry_canvas_access(meeting_id, fence, access, reason) do
    pending =
      access
      |> Map.put("status", canvas_access_pending_status(access))
      |> Map.put("attempt_count", (access["attempt_count"] || 0) + 1)
      |> Map.put("last_error", reason)

    with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_access" => pending}) do
      {:error, reason}
    end
  end

  defp abandon_canvas_access(meeting_id, fence, access, reason) do
    abandoned =
      access
      |> Map.put("status", "v2_abandoned")
      |> Map.put("attempt_count", (access["attempt_count"] || 0) + 1)
      |> Map.put("last_error", reason)

    case checkpoint(meeting_id, fence, %{
           "canvas_access" => abandoned,
           "canvas_access_error" => reason
         }) do
      {:ok, _doc, _etag} -> canvas_unavailable(reason)
      {:error, _} = err -> err
    end
  end

  defp valid_canvas_access_target?(access) do
    access["grant_strategy"] == "set_access" and
      access["target_type"] in ["channel_ids", "user_ids"] and
      match?([_ | _], access["target_ids"]) and
      Enum.all?(access["target_ids"], &(trim(&1) != ""))
  end

  defp canvas_access_pending_status(%{"schema_version" => 2}), do: "v2_pending"
  defp canvas_access_pending_status(_access), do: "pending"

  defp canvas_access_granted_status(%{"schema_version" => 2}), do: "v2_granted"
  defp canvas_access_granted_status(_access), do: "granted"

  defp canvas_access_reason(reason), do: Atom.to_string(reason)

  defp ensure_canvas_titled(_meeting_id, _fence, _token, ""), do: :ok

  defp ensure_canvas_titled(meeting_id, fence, token, canvas_id) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, doc, _etag} <- Store.get(meeting_id) do
      intent = stringify(get_in(doc, ["state", "delivery", "canvas_create"]) || %{})

      cond do
        intent == %{} or intent["status"] in ["ready", "v2_ready", "v3_ready", "v4_ready"] ->
          :ok

        trim(intent["target_title"]) == "" ->
          {:error, :canvas_title_missing}

        true ->
          rename_canvas_title(meeting_id, fence, token, canvas_id, intent)
      end
    end
  end

  defp rename_canvas_title(meeting_id, fence, token, canvas_id, intent) do
    _ = API.rename_canvas(token, canvas_id, intent["target_title"])
    ready = Map.put(intent, "status", canvas_ready_status(intent))

    case checkpoint(meeting_id, fence, %{"canvas_create" => ready}) do
      {:ok, _doc, _etag} -> :ok
      {:error, _} = err -> err
    end
  rescue
    e in API.Error ->
      if retryable_api_error?(e) do
        {:error, API.error_message(e)}
      else
        ready =
          intent
          |> Map.put("status", canvas_ready_status(intent))
          |> Map.put("title_error", API.error_message(e))

        case checkpoint(meeting_id, fence, %{
               "canvas_create" => ready,
               "canvas_title_error" => API.error_message(e)
             }) do
          {:ok, _doc, _etag} -> :ok
          {:error, _} = err -> err
        end
      end
  end

  defp canvas_ready_status(%{"schema_version" => 4}), do: "v4_ready"
  defp canvas_ready_status(%{"schema_version" => 3}), do: "v3_ready"
  defp canvas_ready_status(%{"schema_version" => 2}), do: "v2_ready"
  defp canvas_ready_status(_intent), do: "ready"

  defp ensure_canvas_url(_meeting_id, _fence, _token, _workspace_id, ""),
    do: canvas_unavailable("Canvas permalink requested without a canvas_id")

  defp ensure_canvas_url(meeting_id, fence, token, workspace_id, canvas_id) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, doc, _etag} <- Store.get(meeting_id) do
      delivery = stringify(get_in(doc, ["state", "delivery"]) || %{})

      case trim(delivery["canvas_url"]) do
        "" ->
          fetch_and_checkpoint_canvas_url(
            meeting_id,
            fence,
            token,
            workspace_id,
            canvas_id,
            delivery
          )

        canvas_url ->
          ensure_existing_canvas_url_source(meeting_id, fence, delivery, canvas_url)
      end
    end
  end

  defp ensure_existing_canvas_url_source(meeting_id, fence, delivery, canvas_url) do
    case trim(delivery["canvas_url_source"]) do
      "" ->
        case checkpoint(meeting_id, fence, %{"canvas_url_source" => "legacy"}) do
          {:ok, _doc, _etag} -> {:ok, canvas_url}
          {:error, _} = error -> error
        end

      _source ->
        {:ok, canvas_url}
    end
  end

  defp fetch_and_checkpoint_canvas_url(
         meeting_id,
         fence,
         token,
         workspace_id,
         canvas_id,
         delivery
       ) do
    canvas_url = token |> API.file_info(canvas_id) |> Map.get("permalink", "") |> trim()

    if canvas_url == "" do
      fallback_or_retry_canvas_link(
        meeting_id,
        fence,
        workspace_id,
        canvas_id,
        delivery,
        "Canvas permalink is blank"
      )
    else
      checkpoint_canvas_link(meeting_id, fence, delivery, canvas_url, "files_info")
    end
  rescue
    e in API.Error ->
      reason = API.error_message(e)

      fallback_or_fail_canvas_link(
        meeting_id,
        fence,
        workspace_id,
        canvas_id,
        delivery,
        reason,
        e
      )
  end

  # Legacy Oneesama did not depend on files.info: once Slack returned the
  # standalone Canvas id it linked to Slack's canonical docs route directly.
  # Keep files.info as the verified primary source, but preserve that shortest
  # useful path as an explicitly-derived fallback when metadata lookup fails.
  defp fallback_or_retry_canvas_link(
         meeting_id,
         fence,
         workspace_id,
         canvas_id,
         delivery,
         reason
       ) do
    case derived_canvas_url(workspace_id, canvas_id) do
      {:ok, canvas_url} ->
        checkpoint_canvas_link(meeting_id, fence, delivery, canvas_url, "derived", reason)

      :error ->
        retry_canvas_link(meeting_id, fence, delivery, reason)
    end
  end

  defp fallback_or_fail_canvas_link(
         meeting_id,
         fence,
         workspace_id,
         canvas_id,
         delivery,
         reason,
         error
       ) do
    case derived_canvas_url(workspace_id, canvas_id) do
      {:ok, canvas_url} ->
        checkpoint_canvas_link(meeting_id, fence, delivery, canvas_url, "derived", reason)

      :error ->
        if retryable_api_error?(error) do
          retry_canvas_link(meeting_id, fence, delivery, reason)
        else
          case checkpoint(meeting_id, fence, %{"canvas_link_error" => reason}) do
            {:ok, _doc, _etag} -> canvas_unavailable(reason)
            {:error, _} = checkpoint_error -> checkpoint_error
          end
        end
    end
  end

  defp checkpoint_canvas_link(
         meeting_id,
         fence,
         delivery,
         canvas_url,
         source,
         fallback_reason \\ nil
       ) do
    link =
      delivery
      |> Map.get("canvas_link", %{})
      |> stringify()
      |> Map.put("status", "resolved")
      |> Map.put("source", source)
      |> Map.put("resolved_at", System.system_time(:second))
      |> maybe_put_canvas_link_error(fallback_reason)

    attrs = %{
      "canvas_url" => canvas_url,
      "canvas_url_source" => source,
      "canvas_link" => link
    }

    attrs =
      if is_binary(fallback_reason) and fallback_reason != "",
        do: Map.put(attrs, "canvas_link_error", fallback_reason),
        else: Map.put(attrs, "canvas_link_error", nil)

    case checkpoint(meeting_id, fence, attrs) do
      {:ok, _doc, _etag} -> {:ok, canvas_url}
      {:error, _} = error -> error
    end
  end

  defp maybe_put_canvas_link_error(link, reason) when is_binary(reason) and reason != "",
    do: Map.put(link, "last_error", reason)

  defp maybe_put_canvas_link_error(link, _reason), do: Map.delete(link, "last_error")

  defp derived_canvas_url(workspace_id, canvas_id) do
    workspace_id = trim(workspace_id)
    canvas_id = trim(canvas_id)

    if valid_slack_path_id?(workspace_id) and valid_slack_path_id?(canvas_id) do
      {:ok, "https://app.slack.com/docs/#{workspace_id}/#{canvas_id}"}
    else
      :error
    end
  end

  defp valid_slack_path_id?(id),
    do: id != "" and String.match?(id, ~r/\A[A-Za-z0-9_-]+\z/)

  defp retry_canvas_link(meeting_id, fence, delivery, reason) do
    link = stringify(delivery["canvas_link"] || %{})
    now = System.system_time(:second)
    attempts = (link["attempt_count"] || 0) + 1
    started_at = link["started_at"] || now

    if attempts >= @canvas_link_min_attempts and now - started_at >= @canvas_link_grace_seconds do
      abandoned =
        link
        |> Map.put("status", "abandoned")
        |> Map.put("attempt_count", attempts)
        |> Map.put("started_at", started_at)
        |> Map.put("last_error", reason)

      case checkpoint(meeting_id, fence, %{
             "canvas_link" => abandoned,
             "canvas_link_error" => reason
           }) do
        {:ok, _doc, _etag} -> canvas_unavailable(reason)
        {:error, _} = error -> error
      end
    else
      pending =
        link
        |> Map.put("status", "pending")
        |> Map.put("attempt_count", attempts)
        |> Map.put("started_at", started_at)
        |> Map.put("last_error", reason)

      with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"canvas_link" => pending}) do
        {:error, :canvas_permalink_unavailable}
      end
    end
  end

  defp definitely_rejected_create?(%API.Error{retry_after: secs}) when is_integer(secs), do: true
  defp definitely_rejected_create?(%API.Error{status: 429}), do: true

  defp definitely_rejected_create?(%API.Error{message: message}),
    do: to_string(message) in ["ratelimited", "rate_limited"]

  defp ambiguous_write_error?(%API.Error{status: status}) when is_integer(status),
    do: status in [408, 425] or status >= 500

  defp ambiguous_write_error?(%API.Error{message: message}) do
    message = to_string(message)

    String.starts_with?(message, "slack api request failed:") or
      Enum.any?(
        ~w(internal_error fatal_error service_unavailable timeout request_timeout team_added_to_org org_login_required),
        &String.contains?(message, &1)
      )
  end

  defp retryable_api_error?(%API.Error{retry_after: secs}) when is_integer(secs), do: true

  defp retryable_api_error?(%API.Error{status: status}) when is_integer(status),
    do: status in [408, 425, 429] or status >= 500

  defp retryable_api_error?(%API.Error{message: message}) do
    message = to_string(message)

    String.starts_with?(message, "slack api request failed:") or
      Enum.any?(@retryable_slack_errors, &String.contains?(message, &1))
  end

  defp retryable_api_error?(_error), do: false

  defp ensure_summary_posted(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         state,
         uploads,
         canvas_url,
         bot_user_id,
         delivery
       ) do
    ensure_message_posted(
      meeting_id,
      fence,
      token,
      channel,
      thread,
      summary_notice_text(state, uploads, canvas_url, bot_user_id),
      "summary",
      delivery
    )
  end

  defp ensure_message_posted(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         text,
         kind,
         delivery,
         opts \\ []
       ) do
    message_ts = trim(delivery["summary_message_ts"])
    message_kind = trim(delivery["summary_message_kind"])
    intent = stringify(delivery["message_post"] || %{})

    cond do
      message_ts != "" and matching_message_kind?(message_kind, kind) ->
        {:ok, message_ts}

      intent == %{} or intent["kind"] != kind ->
        stage_message_post(meeting_id, fence, token, channel, thread, text, kind, opts)

      intent["status"] in ["posting", "unknown", "created"] ->
        reconcile_message_post(meeting_id, fence, token, channel, thread, kind, intent)

      intent["status"] == "retryable" ->
        retry_message_post(meeting_id, fence, token, channel, thread, text, kind, intent)

      intent["status"] == "conflict" ->
        {:error, {:message_post_conflict, intent["event_type"]}}

      intent["status"] == "abandoned" ->
        {:error, {:message_post_abandoned, intent["last_error"]}}

      true ->
        {:error, {:message_post_unresolved, intent["status"]}}
    end
  end

  defp matching_message_kind?("", "summary"), do: true
  defp matching_message_kind?(kind, kind), do: true
  defp matching_message_kind?(_stored, _expected), do: false

  defp stage_message_post(meeting_id, fence, token, channel, thread, text, kind, opts) do
    event_type = message_event_type(meeting_id, kind)

    content_kind = opts |> Keyword.get(:content_kind, "") |> trim()
    content_sha256 = opts |> Keyword.get(:content_sha256, "") |> trim()

    metadata = %{
      "event_type" => event_type,
      "event_payload" =>
        %{"meeting_id" => meeting_id, "kind" => kind}
        |> maybe_put_nonblank("content_kind", content_kind)
    }

    intent =
      %{
        "kind" => kind,
        "event_type" => event_type,
        "metadata" => metadata,
        "status" => "posting",
        "started_at" => System.system_time(:second),
        "reconcile_attempts" => 0
      }
      |> maybe_put_nonblank("content_kind", content_kind)
      |> maybe_put_nonblank("content_sha256", content_sha256)

    case checkpoint(meeting_id, fence, %{"message_post" => intent}) do
      {:ok, _doc, _etag} ->
        post_message_once(meeting_id, fence, token, channel, thread, text, kind, intent)

      {:error, _} = err ->
        err
    end
  end

  defp retry_message_post(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         text,
         kind,
         intent
       ) do
    posting = Map.put(intent, "status", "posting")

    case checkpoint(meeting_id, fence, %{"message_post" => posting}) do
      {:ok, _doc, _etag} ->
        post_message_once(meeting_id, fence, token, channel, thread, text, kind, posting)

      {:error, _} = err ->
        err
    end
  end

  defp post_message_once(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         text,
         kind,
         intent
       ) do
    with :ok <- ensure_owns_claim(meeting_id, fence) do
      try do
        {fallback_text, blocks} = message_payload(text)

        resp =
          API.post_message(token, channel, fallback_text,
            thread_ts: thread,
            metadata: intent["metadata"],
            blocks: blocks
          )

        message_ts = trim(resp["ts"])

        if message_ts == "" do
          unknown =
            intent
            |> Map.put("status", "unknown")
            |> Map.put("last_error", "chat.postMessage returned no ts")

          with {:ok, _doc, _etag} <-
                 checkpoint(meeting_id, fence, %{"message_post" => unknown}) do
            {:error, {:message_post_unknown, intent["event_type"]}}
          end
        else
          created =
            intent
            |> confirm_message_content(get_in(resp, ["message", "text"]))

          content_confirmation_required? = trim(intent["content_sha256"]) != ""

          created =
            if content_confirmation_required? and not fallback_part_content_confirmed?(created) do
              created
              |> Map.put("status", "unknown")
              |> Map.put("last_error", "chat.postMessage response did not confirm exact content")
            else
              Map.put(created, "status", "created")
            end

          case checkpoint(meeting_id, fence, %{
                 "summary_message_ts" => message_ts,
                 "summary_message_kind" => kind,
                 "message_post" => created
               }) do
            {:ok, _doc, _etag} ->
              if created["status"] == "created" do
                {:ok, message_ts}
              else
                {:error, {:message_post_unknown, intent["event_type"]}}
              end

            {:error, _} = err ->
              _ =
                compensate_message_unreferenced(
                  meeting_id,
                  message_ts,
                  intent["event_type"],
                  "#{kind}_message",
                  fn -> API.delete_message(token, channel, message_ts) end
                )

              err
          end
        end
      rescue
        e in API.Error -> message_post_failed(meeting_id, fence, e, intent)
      end
    end
  end

  defp message_post_failed(meeting_id, fence, error, intent) do
    cond do
      definitely_rejected_create?(error) ->
        retryable =
          intent
          |> Map.put("status", "retryable")
          |> Map.put("last_error", API.error_message(error))

        with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"message_post" => retryable}) do
          {:error, API.error_message(error)}
        end

      ambiguous_write_error?(error) ->
        unknown =
          intent
          |> Map.put("status", "unknown")
          |> Map.put("last_error", API.error_message(error))

        with {:ok, _doc, _etag} <- checkpoint(meeting_id, fence, %{"message_post" => unknown}) do
          {:error, {:message_post_unknown, API.error_message(error)}}
        end

      true ->
        abandon_message_post(
          meeting_id,
          fence,
          intent,
          intent["reconcile_attempts"] || 0,
          "Slack message post failed: " <> API.error_message(error)
        )
    end
  end

  defp reconcile_message_post(meeting_id, fence, token, channel, thread, kind, intent) do
    with :ok <- ensure_owns_claim(meeting_id, fence),
         {:ok, matches} <- matching_messages(token, channel, thread, intent) do
      attempts = (intent["reconcile_attempts"] || 0) + 1

      case matches do
        [%{"ts" => message_ts} = message] when is_binary(message_ts) and message_ts != "" ->
          found =
            intent
            |> Map.put("reconcile_attempts", attempts)
            |> confirm_message_content(message["text"])

          content_confirmation_required? = trim(intent["content_sha256"]) != ""

          found =
            if content_confirmation_required? and not fallback_part_content_confirmed?(found) do
              found
              |> Map.put("status", "unknown")
              |> Map.put("last_error", "Slack read-back content did not match expected content")
            else
              Map.put(found, "status", "created")
            end

          case checkpoint(meeting_id, fence, %{
                 "summary_message_ts" => message_ts,
                 "summary_message_kind" => kind,
                 "message_post" => found
               }) do
            {:ok, _doc, _etag} ->
              if found["status"] == "created" do
                {:ok, message_ts}
              else
                {:error, {:message_post_unknown, intent["event_type"]}}
              end

            {:error, _} = err ->
              err
          end

        [] ->
          now = System.system_time(:second)

          if message_reconciliation_expired?(intent, attempts, now) do
            abandon_message_post(
              meeting_id,
              fence,
              intent,
              attempts,
              "Slack message post could not be confirmed after bounded reconciliation"
            )
          else
            unknown =
              intent
              |> Map.put("status", "unknown")
              |> Map.put("reconcile_attempts", attempts)
              |> Map.put("last_reconciled_at", now)

            with {:ok, _doc, _etag} <-
                   checkpoint(meeting_id, fence, %{"message_post" => unknown}) do
              {:error, {:message_post_unknown, intent["event_type"]}}
            end
          end

        _multiple ->
          conflict =
            intent
            |> Map.put("status", "conflict")
            |> Map.put("reconcile_attempts", attempts)

          with {:ok, _doc, _etag} <-
                 checkpoint(meeting_id, fence, %{"message_post" => conflict}) do
            {:error, {:message_post_conflict, intent["event_type"]}}
          end
      end
    end
  rescue
    e in API.Error -> message_reconciliation_api_error(meeting_id, fence, intent, e)
  end

  defp matching_messages(token, channel, thread, intent) do
    with {:ok, messages} <- list_message_pages(token, channel, thread, intent, "", 0, []) do
      matches =
        messages
        |> Enum.filter(fn message ->
          trim(message["ts"]) != "" and
            get_in(message, ["metadata", "event_type"]) == intent["event_type"]
        end)
        |> Enum.uniq_by(&trim(&1["ts"]))

      {:ok, matches}
    end
  end

  defp list_message_pages(token, channel, thread, intent, cursor, page, acc)
       when page < 100 do
    opts =
      [cursor: cursor, limit: 15, include_all_metadata: true]
      |> put_oldest(intent["started_at"])

    {messages, next_cursor} = API.conversation_replies(token, channel, thread, opts)
    acc = acc ++ List.wrap(messages)

    case trim(next_cursor) do
      "" -> {:ok, acc}
      next -> list_message_pages(token, channel, thread, intent, next, page + 1, acc)
    end
  end

  defp list_message_pages(_token, _channel, _thread, _intent, _cursor, _page, _acc),
    do: {:error, :message_replies_incomplete}

  defp put_oldest(opts, started_at) when is_integer(started_at) and started_at > 0,
    do: Keyword.put(opts, :oldest, Integer.to_string(started_at))

  defp put_oldest(opts, _started_at), do: opts

  defp message_reconciliation_expired?(intent, attempts, now) do
    started_at = intent["started_at"] || 0

    attempts >= @message_reconcile_min_attempts and is_integer(started_at) and
      now - started_at >= @message_reconcile_grace_seconds
  end

  defp message_reconciliation_api_error(meeting_id, fence, intent, error) do
    if retryable_api_error?(error) do
      {:error, API.error_message(error)}
    else
      abandon_message_post(
        meeting_id,
        fence,
        intent,
        (intent["reconcile_attempts"] || 0) + 1,
        "Slack message reconciliation failed: " <> API.error_message(error)
      )
    end
  end

  defp abandon_message_post(meeting_id, fence, intent, attempts, reason) do
    abandoned =
      intent
      |> Map.put("status", "abandoned")
      |> Map.put("reconcile_attempts", attempts)
      |> Map.put("last_error", reason)

    case checkpoint(meeting_id, fence, %{
           "message_post" => abandoned,
           "message_error" => reason
         }) do
      {:ok, _doc, _etag} -> {:error, {:message_post_abandoned, reason}}
      {:error, _} = err -> err
    end
  end

  defp message_event_type(meeting_id, kind) do
    digest =
      ["comma-meeting-message-v1", meeting_id, kind]
      |> Enum.join(<<0>>)
      |> Crypto.hex()
      |> binary_part(0, 32)

    "comma_meeting_message_posted_" <> digest
  end

  defp confirm_message_content(intent, text) when is_binary(text) do
    expected = trim(intent["content_sha256"])

    if expected != "" and Crypto.hex(text) == expected do
      Map.put(intent, "confirmed_content_sha256", expected)
    else
      Map.delete(intent, "confirmed_content_sha256")
    end
  end

  defp confirm_message_content(intent, _text), do: Map.delete(intent, "confirmed_content_sha256")

  defp maybe_put_nonblank(map, _key, ""), do: map
  defp maybe_put_nonblank(map, key, value), do: Map.put(map, key, value)

  # Best-effort undo of a Slack side effect whose durable checkpoint failed, so a
  # retry starts clean instead of duplicating it. A failed undo only leaks the
  # object; it never produces a duplicate in the persisted delivery.
  defp compensate(label, fun) do
    fun.()
    :ok
  rescue
    e -> Logger.warning("meeting delivery compensation #{label} failed: #{inspect(e)}")
  catch
    kind, reason ->
      Logger.warning("meeting delivery compensation #{label} failed: #{inspect({kind, reason})}")
  end

  # A checkpoint may have landed even when its caller observed a lost/ambiguous
  # result. Never delete an external object that the winning delivery now
  # references; only compensate after a live read proves it is unreferenced.
  defp compensate_unreferenced_paths(meeting_id, delivery_paths, value, label, fun) do
    case Store.get(meeting_id) do
      {:ok, doc, _etag} ->
        delivery = get_in(doc, ["state", "delivery"]) || %{}

        if Enum.any?(delivery_paths, &(get_in(delivery, &1) == value)) do
          :ok
        else
          compensate(label, fun)
        end

      {:error, reason} ->
        Logger.warning(
          "meeting delivery compensation #{label} skipped; state unreadable: #{inspect(reason)}"
        )

        :ok
    end
  end

  # A replacement claim inherits the durable message intent before it has had a
  # chance to reconcile and checkpoint the Slack timestamp. Preserve that
  # intent's message just as we preserve an already-adopted timestamp.
  defp compensate_message_unreferenced(meeting_id, message_ts, event_type, label, fun) do
    case Store.get(meeting_id) do
      {:ok, doc, _etag} ->
        delivery = get_in(doc, ["state", "delivery"]) || %{}
        current_event_type = trim(get_in(delivery, ["message_post", "event_type"]))
        event_type = trim(event_type)

        if trim(delivery["summary_message_ts"]) == message_ts or
             (event_type != "" and current_event_type == event_type) do
          :ok
        else
          compensate(label, fun)
        end

      {:error, reason} ->
        Logger.warning(
          "meeting delivery compensation #{label} skipped; state unreadable: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp publish_terminal_notice(
         meeting_id,
         fence,
         token,
         channel,
         thread,
         text,
         status,
         delivery
       ) do
    message_kind = "terminal:" <> status

    with {:ok, message_ts} <-
           ensure_message_posted(
             meeting_id,
             fence,
             token,
             channel,
             thread,
             text,
             message_kind,
             delivery
           ),
         {:ok, _doc, _etag} <-
           checkpoint(meeting_id, fence, %{
             "status" => "published",
             "meeting_status" => status,
             "published_at" => System.system_time(:second)
           }) do
      {:ok, %{"published" => true, "message_ts" => message_ts}}
    end
  rescue
    e in API.Error -> {:error, API.error_message(e)}
  end

  defp canvas_title(state) do
    owner_attribution = SalixMeet.OwnerAttributionSnapshot.current(state)

    summary =
      SalixMeet.OwnerAttributionSnapshot.bound_summary(
        owner_attribution,
        stringify(state["summary"] || %{})
      )

    base =
      summary["title"]
      |> blank_default(blank_default(state["title"], "Meeting"))
      |> safe_runtime_text(:canvas)

    case canvas_date(state["start_at"]) do
      "" -> base
      date -> base <> " (" <> date <> ")"
    end
  end

  # UTC "YYYY-MM-DD HH:MM" stamp appended to the canvas title from the meeting
  # start time.
  defp canvas_date(ts) when is_integer(ts) and ts > 0 do
    dt = DateTime.from_unix!(ts)
    "#{dt.year}-#{pad2(dt.month)}-#{pad2(dt.day)} #{pad2(dt.hour)}:#{pad2(dt.minute)}"
  end

  defp canvas_date(_ts), do: ""

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp fallback_summary_notice_text(state, uploads, bot_user_id),
    do: summary_notice_fallback_text(state, uploads, "", bot_user_id, complete: true)

  defp summary_notice_text(state, uploads, canvas_url, bot_user_id) do
    owner_attribution = SalixMeet.OwnerAttributionSnapshot.current(state)

    summary =
      SalixMeet.OwnerAttributionSnapshot.bound_summary(
        owner_attribution,
        stringify(state["summary"] || %{})
      )

    slack_ids =
      SalixMeet.OwnerAttributionSnapshot.slack_ids_for(owner_attribution, summary)

    action_items =
      summary
      |> indexed_action_items()
      |> Enum.map(&action_item_block(&1, slack_ids))
      |> Enum.reject(&is_nil/1)

    action_item_count = length(action_items)

    markdown = summary_markdown(state, summary, uploads, canvas_url)

    fallback_text =
      summary_notice_fallback_text(state, uploads, canvas_url, bot_user_id, complete: true)

    case SlackMarkdown.render_blocks(markdown) do
      {:ok, markdown_blocks} ->
        blocks =
          markdown_blocks ++
            action_item_blocks(action_items) ++
            linear_follow_up_blocks(action_item_count, bot_user_id)

        if valid_summary_blocks?(blocks) do
          %{
            text: fallback_text,
            blocks: blocks
          }
        else
          fallback_text
        end

      {:error, :markdown_too_long} ->
        fallback_text
    end
  end

  defp summary_markdown(state, summary, uploads, canvas_url) do
    title =
      summary["title"]
      |> blank_default(blank_default(state["title"], "Meeting"))
      |> safe_runtime_text(:canvas)

    [
      "# " <> title,
      SalixMeet.Outcome.text(state["reason_code"]) || "",
      markdown_duration(summary),
      markdown_section("Attendees", summary["attendees"]),
      markdown_timeline(summary["timeline"]),
      markdown_section("Key points", summary["key_points"]),
      markdown_section("Decisions", summary["decisions"]),
      markdown_section("Open questions", summary["open_questions"]),
      markdown_section("Blockers", summary["blockers"]),
      markdown_link("Transcript", get_in(uploads, ["transcript", "permalink"])),
      markdown_link("Recording", get_in(uploads, ["audio", "permalink"])),
      markdown_link("Canvas", canvas_url)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp markdown_duration(summary) do
    case summary["duration_minutes"] do
      n when is_integer(n) and n > 0 -> "**Duration:** #{n} min"
      n when is_float(n) and n > 0 -> "**Duration:** #{round(n)} min"
      _ -> ""
    end
  end

  defp markdown_section(label, values) do
    items =
      values
      |> List.wrap()
      |> Enum.map(&safe_runtime_text(&1, :canvas))
      |> Enum.reject(&(&1 == ""))

    case items do
      [] -> ""
      _ -> "## #{label}\n\n" <> Enum.map_join(items, "\n", &("- " <> &1))
    end
  end

  defp markdown_timeline(values) do
    items =
      values
      |> List.wrap()
      |> Enum.map(&markdown_timeline_item/1)
      |> Enum.reject(&(&1 == ""))

    case items do
      [] -> ""
      _ -> "## Timeline\n\n" <> Enum.map_join(items, "\n", &("- " <> &1))
    end
  end

  defp markdown_timeline_item(item) when is_map(item) do
    item = stringify(item)
    time = safe_runtime_text(item["time"], :canvas)
    summary = safe_runtime_text(item["summary"], :canvas)

    case {time, summary} do
      {"", ""} -> ""
      {"", text} -> text
      {label, ""} -> label
      {label, text} -> label <> " — " <> text
    end
  end

  defp markdown_timeline_item(item), do: safe_runtime_text(item, :canvas)

  defp markdown_link(_label, value) when not is_binary(value) or value == "", do: ""

  defp markdown_link(label, value) do
    "**#{label}:** [Open #{String.downcase(label)}](#{String.trim(value)})"
  end

  defp action_item_blocks([]), do: []

  defp action_item_blocks(action_items) do
    [
      %{
        "type" => "section",
        "block_id" => "meeting_actions_header_v1",
        "text" => %{"type" => "mrkdwn", "text" => "*Action Items*"}
      }
      | action_items
    ]
  end

  defp action_item_block({item, index}, slack_ids) when is_map(item) do
    item = stringify(item)
    description = safe_action_text(item["description"], :thread)
    owner = owner_display(item, index, slack_ids, :thread)
    deadline = safe_action_text(item["deadline"], :thread)

    text =
      cond do
        description == "" -> action_metadata_text(owner, deadline)
        owner == "" and deadline == "" -> description
        owner == "" -> description <> " (due " <> deadline <> ")"
        deadline == "" -> owner <> " — " <> description
        true -> owner <> " — " <> description <> " (due " <> deadline <> ")"
      end

    if text == "" do
      nil
    else
      %{
        "type" => "section",
        "block_id" => "meeting_action_#{index}_v1",
        "text" => %{"type" => "mrkdwn", "text" => text, "verbatim" => true}
      }
    end
  end

  defp action_item_block({item, index}, _slack_ids) do
    case safe_action_text(item, :thread) do
      "" ->
        nil

      text ->
        %{
          "type" => "section",
          "block_id" => "meeting_action_#{index}_v1",
          "text" => %{"type" => "mrkdwn", "text" => text, "verbatim" => true}
        }
    end
  end

  defp valid_summary_blocks?(blocks) do
    length(blocks) <= @fallback_block_max_count and
      Enum.all?(blocks, &valid_summary_block?/1)
  end

  defp valid_summary_block?(%{"type" => "section", "text" => %{"text" => text}})
       when is_binary(text),
       do: String.length(text) <= @fallback_block_text_max_chars

  defp valid_summary_block?(%{"type" => "section"}), do: false
  defp valid_summary_block?(_block), do: true

  defp linear_follow_up_blocks(action_item_count, bot_user_id) do
    case linear_follow_up_hint(action_item_count, bot_user_id) do
      "" ->
        []

      hint ->
        [
          %{
            "type" => "section",
            "block_id" => "meeting_actions_linear_hint_v1",
            "text" => %{"type" => "mrkdwn", "text" => hint}
          }
        ]
    end
  end

  defp summary_notice_fallback_text(state, uploads, canvas_url, bot_user_id, opts) do
    owner_attribution = SalixMeet.OwnerAttributionSnapshot.current(state)

    summary =
      SalixMeet.OwnerAttributionSnapshot.bound_summary(
        owner_attribution,
        stringify(state["summary"] || %{})
      )

    slack_ids =
      SalixMeet.OwnerAttributionSnapshot.slack_ids_for(owner_attribution, summary)

    action_item_count =
      summary
      |> indexed_action_items()
      |> Enum.count(&(action_text(&1, slack_ids, :thread) != ""))

    title =
      summary["title"]
      |> blank_default(blank_default(state["title"], "Meeting"))
      |> safe_runtime_text(:thread)

    lines =
      ["Meeting Summary: " <> title, SalixMeet.Outcome.text(state["reason_code"])]
      |> Enum.reject(&is_nil/1)

    lines =
      if opts[:complete] do
        lines
        |> notice_duration(summary)
        |> notice_section("Attendees", summary["attendees"], &notice_bullet/1)
        |> notice_section("Timeline", summary["timeline"], &notice_timeline_item/1)
      else
        lines
      end

    lines =
      lines
      |> notice_section("Key points", summary["key_points"], &notice_bullet/1)
      |> notice_section(
        "Action items",
        indexed_action_items(summary),
        &action_text(&1, slack_ids, :thread)
      )
      |> notice_section("Decisions", summary["decisions"], &notice_bullet/1)
      |> notice_section("Open questions", summary["open_questions"], &notice_bullet/1)
      |> notice_section("Blockers", summary["blockers"], &notice_bullet/1)

    lines =
      case uploads["transcript"] do
        %{"permalink" => url} when is_binary(url) and url != "" ->
          lines ++ ["", artifact_notice_line("Transcript", url, opts[:complete])]

        _ ->
          lines
      end

    lines =
      case uploads["audio"] do
        %{"permalink" => url} when is_binary(url) and url != "" ->
          lines ++ [artifact_notice_line("Recording", url, opts[:complete])]

        _ ->
          lines
      end

    lines =
      case canvas_url do
        url when is_binary(url) and url != "" ->
          lines ++ ["Canvas: " <> url]

        _ ->
          lines
      end

    lines =
      case linear_follow_up_hint(action_item_count, bot_user_id) do
        "" -> lines
        hint -> lines ++ ["", hint]
      end

    Enum.join(lines, "\n")
  end

  defp message_payload(%{text: text, blocks: blocks}) when is_binary(text) and is_list(blocks),
    do: {text, blocks}

  defp message_payload(text) when is_binary(text), do: {text, nil}

  defp artifact_notice_line(label, url, true),
    do: "*#{label}:* <#{url}|Open #{String.downcase(label)}>"

  defp artifact_notice_line(label, url, _complete), do: "#{label}: #{url}"

  defp linear_follow_up_hint(action_item_count, bot_user_id) when action_item_count > 0 do
    bot_user_id = trim(bot_user_id)

    invocation =
      if valid_slack_path_id?(bot_user_id) do
        "<@#{bot_user_id}> me in this thread"
      else
        "Mention this bot in this thread"
      end

    ":clipboard: This meeting has *#{action_item_count} action item(s)*. " <>
      invocation <>
      " to review them and choose which should become Linear issues. " <>
      "Creation requires your explicit request or selection and an enabled, connected, write-capable Linear integration."
  end

  defp linear_follow_up_hint(_action_item_count, _bot_user_id), do: ""

  # Append a "*Label:*" block of "• item" lines to the Slack notice (mrkdwn, not
  # markdown headings). Drops the whole block when the section has no content.
  defp notice_section(lines, label, list, formatter) do
    items =
      list
      |> List.wrap()
      |> Enum.map(formatter)
      |> Enum.reject(&(&1 == ""))

    case items do
      [] -> lines
      _ -> lines ++ ["", "*#{label}:*"] ++ Enum.map(items, &("• " <> &1))
    end
  end

  defp notice_bullet(value), do: safe_runtime_text(value, :thread)

  defp notice_duration(lines, summary) do
    case summary["duration_minutes"] do
      n when is_integer(n) and n > 0 -> lines ++ ["", "*Duration:* #{n} min"]
      n when is_float(n) and n > 0 -> lines ++ ["", "*Duration:* #{round(n)} min"]
      _ -> lines
    end
  end

  defp notice_timeline_item(item) when is_map(item) do
    item = stringify(item)
    time = safe_runtime_text(item["time"], :thread)

    case safe_runtime_text(item["summary"], :thread) do
      "" -> ""
      text when time == "" -> text
      text -> time <> " — " <> text
    end
  end

  defp notice_timeline_item(item), do: notice_bullet(item)

  defp canvas_markdown(state, uploads), do: render_canvas_markdown(state, uploads, :rich)

  defp canvas_plain_markdown(state, uploads),
    do: render_canvas_markdown(state, uploads, :plain)

  defp render_canvas_markdown(state, uploads, content_variant) do
    owner_attribution = SalixMeet.OwnerAttributionSnapshot.current(state)

    summary =
      SalixMeet.OwnerAttributionSnapshot.bound_summary(
        owner_attribution,
        stringify(state["summary"] || %{})
      )

    slack_ids =
      if content_variant == :rich,
        do: SalixMeet.OwnerAttributionSnapshot.slack_ids_for(owner_attribution, summary),
        else: %{}

    artifacts =
      if content_variant == :rich,
        do: artifacts_block(uploads),
        else: plain_artifacts_block(uploads)

    [
      duration_line(summary),
      md_section("Attendees", summary["attendees"], &canvas_bullet/1),
      md_section("Timeline", summary["timeline"], &format_canvas_timeline_item/1),
      md_section("Key Points", summary["key_points"], &canvas_bullet/1),
      md_section(
        "Action Items",
        indexed_action_items(summary),
        &format_action_item(&1, slack_ids, :canvas)
      ),
      md_section("Decisions", summary["decisions"], &canvas_bullet/1),
      md_section("Open Questions", summary["open_questions"], &canvas_bullet/1),
      md_section("Blockers", summary["blockers"], &canvas_bullet/1),
      artifacts
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Embed each artifact as its own `![](permalink)` block so Slack renders it as
  # a card (audio player / file preview) rather than a plain link. The embed must
  # stand alone — inside a list or other block it degrades to a title unfurl.
  defp artifacts_block(uploads) do
    embeds =
      [uploads["transcript"], uploads["audio"]]
      |> Enum.map(&artifact_embed/1)
      |> Enum.reject(&(&1 == ""))

    case embeds do
      [] -> ""
      _ -> Enum.join(["## Artifacts" | embeds], "\n\n")
    end
  end

  defp artifact_embed(%{"permalink" => url}) when is_binary(url) and url != "",
    do: "![](" <> url <> ")"

  defp artifact_embed(_artifact), do: ""

  defp plain_artifacts_block(uploads) do
    links =
      [uploads["transcript"], uploads["audio"]]
      |> Enum.map(&plain_artifact_link/1)
      |> Enum.reject(&(&1 == ""))

    case links do
      [] -> ""
      _ -> Enum.join(["## Artifacts" | links], "\n")
    end
  end

  defp plain_artifact_link(%{"permalink" => url}) when is_binary(url) and url != "",
    do: "- " <> String.trim(url)

  defp plain_artifact_link(_artifact), do: ""

  # Render a "## Heading" block whose lines come from `list` via `formatter`.
  # Returns "" (dropped by the caller) when the section has no content, so an
  # empty summary field never leaves a dangling heading behind.
  defp md_section(heading, list, formatter) do
    entries =
      list
      |> List.wrap()
      |> Enum.map(formatter)
      |> Enum.reject(&(&1 == "" or &1 == "- "))

    case entries do
      [] -> ""
      _ -> "## " <> heading <> "\n" <> Enum.join(entries, "\n")
    end
  end

  defp canvas_bullet(value) do
    case safe_runtime_text(value, :canvas) do
      "" -> ""
      text -> "- " <> text
    end
  end

  defp format_canvas_timeline_item(item) when is_map(item) do
    item = stringify(item)
    time = safe_runtime_text(item["time"], :canvas)

    case safe_runtime_text(item["summary"], :canvas) do
      "" -> ""
      text when time == "" -> "- " <> text
      text -> "- " <> time <> " — " <> text
    end
  end

  defp format_canvas_timeline_item(item), do: canvas_bullet(item)

  defp duration_line(summary) do
    case summary["duration_minutes"] do
      n when is_integer(n) and n > 0 -> "**Duration:** #{n} min"
      n when is_float(n) and n > 0 -> "**Duration:** #{round(n)} min"
      _ -> ""
    end
  end

  defp indexed_action_items(summary) do
    summary["action_items"]
    |> List.wrap()
    |> Enum.with_index()
  end

  defp format_action_item(indexed_item, slack_ids, mention_fmt) do
    case action_text(indexed_item, slack_ids, mention_fmt) do
      "" -> ""
      text -> "- " <> text
    end
  end

  defp action_text({item, index}, slack_ids, mention_fmt) when is_map(item) do
    item = stringify(item)
    desc = safe_action_text(item["description"], mention_fmt)
    owner = owner_display(item, index, slack_ids, mention_fmt)
    deadline = safe_action_text(item["deadline"], mention_fmt)
    suffix = [owner, deadline] |> Enum.reject(&(&1 == "")) |> Enum.join(" - ")

    cond do
      desc == "" -> action_metadata_text(owner, deadline)
      suffix == "" -> desc
      true -> desc <> " (" <> suffix <> ")"
    end
  end

  defp action_text({item, _index}, _slack_ids, mention_fmt),
    do: safe_action_text(item, mention_fmt)

  defp action_metadata_text("", ""), do: ""
  defp action_metadata_text("", deadline), do: "Due " <> deadline
  defp action_metadata_text(owner, ""), do: owner
  defp action_metadata_text(owner, deadline), do: owner <> " (due " <> deadline <> ")"

  # The prevalidated map comes only from the delivery-owned snapshot, so
  # runtime-owned id fields and a stale mapping are both inert.
  defp owner_display(item, index, slack_ids, mention_fmt) do
    case Map.get(slack_ids, index) do
      id when is_binary(id) and id != "" -> owner_mention(id, mention_fmt)
      _ -> safe_action_text(item["owner"], mention_fmt)
    end
  end

  defp owner_mention(id, :canvas), do: "![](@" <> id <> ")"
  defp owner_mention(id, _thread), do: "<@" <> id <> ">"

  defp safe_action_text(value, mention_fmt), do: safe_runtime_text(value, mention_fmt)

  defp safe_runtime_text(value, :canvas),
    do: value |> runtime_text() |> escape_canvas_markdown()

  defp safe_runtime_text(value, _thread), do: value |> runtime_text() |> escape_slack()

  defp runtime_text(nil), do: ""
  defp runtime_text(value) when is_binary(value), do: String.trim(value)

  defp runtime_text(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  defp runtime_text(_value), do: ""

  # Neutralize Slack control syntax (`<@U…>`, `<!channel>`, `<url|text>`) in all
  # unresolved meeting-derived action-item fields.
  defp escape_slack(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Canvas parses Markdown embeds/mentions such as `![](@U…)`. Escape both the
  # embed punctuation and any existing escape so the fallback stays literal.
  # Product-resolved mentions bypass this function and retain native syntax.
  defp escape_canvas_markdown(text) do
    text
    |> escape_slack()
    |> String.replace("\\", "\\\\")
    |> String.replace("!", "\\!")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  defp failed_text(%{"watchdog" => %{"reason" => "runtime_lost"}}),
    do:
      ":warning: This meeting's record is incomplete — the meeting runtime " <>
        "disconnected before reporting completion, so no summary is available."

  defp failed_text(%{"reason_code" => code} = state)
       when code in ~w(admission_denied meeting_full removed_from_meeting admission_timeout),
       do: ":x: " <> SalixMeet.Outcome.notice(state)

  defp failed_text(%{"error" => ""}), do: ":x: Meeting failed."

  defp failed_text(%{"error" => err}),
    do: ":x: Meeting failed: " <> safe_runtime_text(err, :thread)

  defp failed_text(_state), do: ":x: Meeting failed."

  defp ensure_slack_meeting(%{"provider" => "slack"}), do: :ok
  defp ensure_slack_meeting(_state), do: {:error, "meeting provider is not slack"}

  defp ensure_not_published(%{"delivery" => %{"published_at" => _} = delivery}),
    do: {:ok, Map.put(delivery, "published", true)}

  defp ensure_not_published(_state), do: :ok

  defp published?(%{"delivery" => %{"published_at" => _}}), do: true
  defp published?(_state), do: false

  defp read_connect(group_id, connect_id) do
    case S3.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, %{body: body}} -> {:ok, Jason.decode!(body)}
      {:error, :not_found} -> {:error, "connect not found"}
      {:error, _} = err -> err
    end
  end

  defp connect_publishable?(connect) do
    cond do
      connect["deleted_at"] ->
        # A deleted connect can never publish again: converge terminally
        # instead of retrying forever. A disabled connect stays a plain
        # retryable error — waiting out a disable and catching up on
        # re-enable is existing, intentional behavior.
        {:error, {:connect_terminal, "connect deleted"}}

      connect["disabled_at"] ->
        {:error, {:connect_unavailable, :disabled}}

      connect["provider"] != "slack" ->
        {:error, "connect is not slack"}

      Enum.any?(~w(bot_token workspace_id), &(trim(connect[&1]) == "")) ->
        {:error, "Slack connect is not OAuth-complete"}

      true ->
        :ok
    end
  end

  # ---- parsing helpers ----

  defp normalize_trigger_text(raw, ignored_plain_mentions) do
    raw
    |> trim()
    |> html_unescape()
    |> then(&Regex.replace(@slack_mention_pattern, &1, " "))
    |> then(&Regex.replace(@slack_autolink_pattern, &1, "\\1"))
    |> strip_ignored_plain_mentions(ignored_plain_mentions)
  end

  defp meet_urls(raw, ignored) do
    @google_meet_url_pattern
    |> Regex.scan(normalize_trigger_text(raw, ignored), capture: :first)
    |> Enum.map(fn [url] -> String.trim_trailing(url, ".,;:!?])}>") end)
    |> Enum.uniq()
  end

  defp extract_single_slack_permalink(raw, ignored) do
    case Regex.scan(@slack_permalink_pattern, normalize_trigger_text(raw, ignored)) do
      [[match, channel, sec, micros]] ->
        thread_ts =
          case URI.parse(match).query do
            nil -> ""
            query -> URI.decode_query(query)["thread_ts"] || ""
          end

        %{"channel_id" => channel, "message_ts" => sec <> "." <> micros, "thread_ts" => thread_ts}

      _ ->
        nil
    end
  end

  defp extract_meeting_title_from_message(message, ignored) do
    message
    |> collect_message_texts()
    |> Enum.find_value(fn text ->
      extract_meeting_title_from_text(text, ignored) || normalize_title_candidate(text, ignored)
    end)
  end

  defp extract_meeting_title_from_text(raw, ignored) do
    case extract_slack_title_field(raw) do
      "" ->
        normalized = normalize_title_candidate(raw, ignored)

        cond do
          normalized in [nil, ""] ->
            nil

          match = Regex.run(@started_meeting_title_pattern, normalized) ->
            sanitize_title(Enum.at(match, 1))

          match = Regex.run(@meeting_label_title_pattern, normalized) ->
            sanitize_title(Enum.at(match, 1))

          true ->
            nil
        end

      title ->
        title
    end
  end

  defp extract_slack_title_field(raw) do
    raw = raw |> trim() |> html_unescape()

    case Regex.run(~r/title/i, raw, return: :index) do
      nil ->
        ""

      [{idx, len} | _] ->
        rest =
          raw
          |> binary_part(idx + len, byte_size(raw) - idx - len)
          |> String.trim()
          |> String.trim_leading(" \t:：-*")

        stop =
          ["\n", "\r", " for:", " for ", " will ", " join meet", " button"]
          |> Enum.reduce(byte_size(rest), fn marker, acc ->
            case :binary.match(String.downcase(rest), marker) do
              {pos, _} when pos < acc -> pos
              _ -> acc
            end
          end)

        sanitize_title(binary_part(rest, 0, stop))
    end
  end

  defp normalize_title_candidate(raw, ignored) do
    raw
    |> normalize_trigger_text(ignored)
    |> then(&Regex.replace(@google_meet_url_pattern, &1, " "))
    |> then(&Regex.replace(@slack_permalink_pattern, &1, " "))
    |> sanitize_title()
    |> case do
      "" -> nil
      title -> title
    end
  end

  defp sanitize_title(raw) do
    title =
      raw
      |> trim()
      |> String.split()
      |> Enum.join(" ")
      |> String.trim("\"'`“”‘’[](){}<>|*")
      |> String.trim("-:：")

    cond do
      title == "" -> ""
      Regex.match?(@google_meet_url_pattern, title) -> ""
      Regex.match?(@slack_permalink_pattern, title) -> ""
      Regex.match?(@generic_meeting_title_pattern, title) -> ""
      String.contains?(String.downcase(title), "after the meeting ends") -> ""
      String.starts_with?(String.downcase(title), "caption language") -> ""
      true -> title
    end
  end

  defp collect_message_texts(message) do
    text = message_text(message)
    if text == "", do: [], else: [text]
  end

  defp message_text(message), do: trim(message["text"])

  defp infer_caption_language(context_texts) do
    combined = Enum.join(compact(context_texts), "\n")

    cond do
      Regex.match?(@chinese_hint_pattern, combined) and
          not Regex.match?(@english_hint_pattern, combined) ->
        @chinese_caption_language

      Regex.match?(@english_hint_pattern, combined) and
          not Regex.match?(@chinese_hint_pattern, combined) ->
        @english_caption_language

      predominantly_chinese?(combined) ->
        @chinese_caption_language

      true ->
        default_caption_language()
    end
  end

  defp default_bot_name do
    blank_default(Application.get_env(:salix_meet, :default_bot_name), @default_bot_name)
  end

  defp default_caption_language do
    blank_default(
      Application.get_env(:salix_meet, :default_caption_language),
      @default_caption_language
    )
  end

  defp predominantly_chinese?(text) do
    chars = String.graphemes(text)
    han = Enum.count(chars, &Regex.match?(~r/\p{Han}/u, &1))
    latin = Enum.count(chars, &Regex.match?(~r/[A-Za-z]/, &1))
    han >= 4 and han > latin
  end

  defp ignored_bot_mentions(connect) do
    [connect["bot_user_id"], connect["app_name"], "comma", "salix", "bridge"]
    |> compact()
  end

  defp strip_ignored_plain_mentions(raw, handles) do
    ignored =
      handles
      |> Enum.map(&(&1 |> trim() |> String.trim_leading("@") |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(ignored) == 0 do
      raw
    else
      raw
      |> String.split()
      |> Enum.reject(fn field ->
        trimmed =
          field
          |> String.trim("'\".,;:!?()[]{}<>|*")
          |> String.trim_leading("@")
          |> String.downcase()

        trimmed != "" and MapSet.member?(ignored, trimmed)
      end)
      |> Enum.join(" ")
    end
  end

  defp meeting_id(connect, envelope, event, channel, thread, meet_url) do
    source_id =
      first_nonblank([envelope["event_id"], event["client_msg_id"], event["ts"], meet_url])

    digest =
      [
        "comma30-meeting-v1",
        connect["tenant_id"],
        connect["group_id"],
        connect["connect_id"],
        channel,
        thread,
        source_id,
        meet_url
      ]
      |> Enum.join("\n")
      |> Crypto.hex()
      |> binary_part(0, 24)

    "mtg-" <> digest
  end

  defp channel_id(event), do: first_nonblank([event["channel"], event["channel_id"]])
  defp thread_ts(event), do: first_nonblank([event["thread_ts"], event["ts"], event["event_ts"]])

  defp artifact_upload_title(title, "transcript", fallback),
    do: artifact_base_title(title, fallback) <> " - transcript.txt"

  defp artifact_upload_title(title, "audio", fallback) do
    ext =
      case Path.extname(trim(fallback)) do
        "" -> ".mp3"
        value -> value
      end

    artifact_base_title(title, fallback) <> " - recording" <> ext
  end

  defp artifact_base_title(title, fallback) do
    [title, fallback, "Meeting"]
    |> Enum.map(&sanitize_artifact_title/1)
    |> Enum.find("Meeting", &(&1 != ""))
  end

  defp sanitize_artifact_title(raw) do
    raw
    |> trim()
    |> String.replace(~r/[\/\\:\n\r\t]/, " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp html_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#34;", "\"")
    |> String.replace("&amp;", "&")
  end

  defp compact(values) do
    values
    |> List.wrap()
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp first_nonblank(values), do: Enum.find_value(List.wrap(values), "", &present_string/1)
  defp present_string(value), do: if(trim(value) == "", do: nil, else: trim(value))

  defp blank_default("", fallback), do: fallback
  defp blank_default(nil, fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp require_nonblank("", message), do: {:error, message}
  defp require_nonblank(_value, _message), do: :ok

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
