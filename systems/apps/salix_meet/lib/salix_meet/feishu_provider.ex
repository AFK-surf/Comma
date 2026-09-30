defmodule SalixMeet.FeishuProvider do
  @moduledoc """
  Feishu entry and publication boundary for Google Meet meetings.

  Group triggers require an actual Feishu mention entity. Thread lookup is one
  bounded page (50 messages) and never falls back to group history.
  """

  alias SalixIM.Ports.FeishuDirectDelivery
  alias SalixIM.Provider.Feishu
  alias SalixIM.Provider.Feishu.Message, as: FeishuMessage
  alias SalixMeet.{MeetingState, OwnerAttributionSnapshot, Runtime, RuntimeEvents, Store}
  alias SalixStore.{Crypto, S3}

  @meet_url ~r|https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[^\s<>]*)?|iu
  @join_intent ~r/(?:入会|加入会议|参加会议|进会|join(?:\s+(?:the\s+)?meeting)?)/iu
  @negated_join_intent ~r/(?:不要|别|请勿|不用)\s*(?:入会|加入会议|参加会议|进会)|(?:do\s+not|don['’]?t|never)\s+join(?:\s+(?:the\s+)?meeting)?/iu
  @default_caption_language "Chinese, Mandarin (Simplified)"
  @default_bot_name "Cirno"
  @thread_page_size 50
  @max_file_upload_bytes 30 * 1024 * 1024

  @spec handle_event(map(), map()) :: {:ok, :handled} | :ignored | {:error, term()}
  def handle_event(connect, envelope) when is_map(connect) and is_map(envelope) do
    if SalixMeet.RuntimeDriver.configured?() do
      event = stringify(envelope["event"] || %{})
      message = stringify(event["message"] || %{})

      with true <- List.wrap(message["files"]) == [] || :ignored,
           :ok <- ensure_addressed(connect, message),
           {:ok, request} <- resolve_request(connect, message),
           {:ok, meeting_agent} <-
             Runtime.start_for_group(connect["tenant_id"], connect["group_id"]),
           {:ok, meeting_id, state, _created?} <-
             ensure_meeting(connect, meeting_agent, envelope, event, message, request),
           :ok <- notify_start(connect, meeting_id, state),
           :ok <- request_meeting_join(meeting_id),
           :ok <- deliver_trigger(connect, meeting_id, state, envelope, message) do
        {:ok, :handled}
      else
        :ignored -> :ignored
        {:error, :ignored} -> :ignored
        {:prompt, text, ref} -> prompt(connect, ref, text)
        {:error, _} = error -> error
        false -> :ignored
        other -> {:error, other}
      end
    else
      :ignored
    end
  end

  @doc "Execute one Router-authorized manual join after validating its sealed Feishu source."
  @spec join_from_router(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def join_from_router(connect, source, params)
      when is_map(connect) and is_map(source) and is_map(params) do
    metadata = stringify(source["metadata"] || %{})
    text = trim(source["text"])

    message = %{
      "message_id" =>
        first_nonblank([
          metadata["trigger_message_id"],
          metadata["message_id"],
          source["source_message_id"],
          source["message_id"]
        ]),
      "root_id" => metadata["root_message_id"],
      "thread_id" => metadata["message_thread_id"],
      "chat_id" => metadata["chat_id"],
      "chat_type" => metadata["chat_type"],
      "content" => %{"text" => text},
      "files" => []
    }

    event = %{
      "message" => message,
      "sender" => %{"sender_id" => %{"open_id" => metadata["sender_open_id"]}}
    }

    envelope = %{
      "event_id" => source["source_message_id"],
      "event" => event,
      "header" => %{
        "event_id" => source["source_message_id"],
        "tenant_key" => metadata["tenant_key"]
      }
    }

    with true <-
           SalixMeet.RuntimeDriver.configured?() || {:error, :meeting_runtime_not_configured},
         true <-
           trim(source["connect_id"]) == trim(connect["connect_id"]) ||
             {:error, :meeting_source_connect_mismatch},
         true <-
           (trim(message["chat_id"]) != "" and trim(message["message_id"]) != "") ||
             {:error, :invalid_meeting_source},
         {:ok, request} <- resolve_router_request(connect, message, params),
         {:ok, meeting_agent} <-
           Runtime.start_for_group(connect["tenant_id"], connect["group_id"]),
         {:ok, meeting_id, state, created?} <-
           ensure_meeting(connect, meeting_agent, envelope, event, message, request),
         :ok <- if(created?, do: notify_start(connect, meeting_id, state), else: :ok),
         :ok <- if(created?, do: request_meeting_join(meeting_id), else: :ok),
         :ok <-
           if(created?,
             do: deliver_trigger(connect, meeting_id, state, envelope, message),
             else: :ok
           ) do
      {:ok,
       %{
         "meeting_id" => meeting_id,
         "status" => if(created?, do: "joining", else: "already_active"),
         "provider" => "feishu"
       }}
    else
      {:prompt, _text, _ref} -> {:error, :meeting_thread_has_different_meeting}
      {:error, _} = error -> error
      false -> {:error, :invalid_meeting_source}
      other -> {:error, other}
    end
  end

  @doc "Terminal meeting publication used by `SalixMeet.ProviderDispatcher`."
  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(meeting_agent, payload) when is_map(meeting_agent) and is_map(payload) do
    payload = stringify(payload)
    meeting_id = trim(payload["meeting_id"])
    claim = stringify(payload["delivery_claim"] || %{})

    with :ok <- require_nonblank(meeting_id, :meeting_id_required),
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         state = stringify(state),
         true <- state["provider"] == "feishu" || {:error, :not_feishu_meeting},
         :ok <- maybe_check_claim(meeting_id, claim),
         {:ok, connect} <- publishable_feishu_connect(state["group_id"], state["connect_id"]) do
      if payload["kind"] == "summary_generating" do
        publish_generating_status(connect, meeting_id, claim)
      else
        publish_terminal(meeting_agent, connect, meeting_id, state, claim)
      end
    else
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = error -> error
      false -> {:error, :not_feishu_meeting}
    end
  end

  defp publish_generating_status(connect, meeting_id, claim) do
    with :ok <- maybe_check_claim(meeting_id, claim),
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         state = stringify(state),
         true <- generating_status_applicable?(state) do
      queue_text(connect, state, "meeting:#{meeting_id}:generating", "正在整理会议摘要…")
    else
      false -> {:ok, %{"status_set" => false}}
      {:error, _} = error -> error
    end
  end

  defp generating_status_applicable?(state) do
    trim(state["status"]) == "done" and
      OwnerAttributionSnapshot.complete?(OwnerAttributionSnapshot.current(state))
  end

  @doc false
  def notify_status(meeting_id, state, event)
      when is_binary(meeting_id) and is_map(state) and is_map(event) do
    event = stringify(event)

    case status_text(event) do
      nil ->
        :ok

      {status, text} ->
        with {:ok, connect} <-
               SalixIM.ProviderConnects.get_active_connect_by_id(
                 state["group_id"],
                 state["connect_id"],
                 "feishu"
               ),
             {:ok, _result} <-
               queue_text(connect, state, "meeting:#{meeting_id}:status:#{status}", text) do
          :ok
        end
    end
  end

  # ---- trigger discovery ----

  defp ensure_addressed(connect, message) do
    case trim(message["chat_type"]) do
      "p2p" -> :ok
      "group" -> if(actual_bot_mention?(connect, message), do: :ok, else: {:error, :ignored})
      _ -> {:error, :ignored}
    end
  end

  defp actual_bot_mention?(connect, message) do
    bot_open_id = trim(connect["bot_open_id"])

    bot_open_id != "" and
      Enum.any?(List.wrap(message["mentions"]), fn mention ->
        trim(get_in(mention || %{}, ["id", "open_id"])) == bot_open_id
      end)
  end

  defp resolve_request(connect, message) do
    text = FeishuMessage.text(message)
    ref = feishu_ref(message)

    cond do
      Regex.match?(@negated_join_intent, text) ->
        {:error, :ignored}

      Regex.match?(@join_intent, text) ->
        case meet_urls(text) do
          [url] -> {:ok, request(url, [text], ref)}
          [_ | _] -> {:prompt, "检测到多个 Google Meet 链接，请只保留一个后再让我入会。", ref}
          [] -> resolve_thread_request(connect, message, text, ref)
        end

      true ->
        {:error, :ignored}
    end
  end

  defp resolve_router_request(connect, message, params) do
    text = FeishuMessage.text(message)
    ref = feishu_ref(message)
    current_urls = meet_urls(text)

    with {:ok, requested_url} <- requested_meet_url(params) do
      cond do
        requested_url != "" and requested_url in current_urls ->
          {:ok, request(requested_url, [text], ref)}

        requested_url != "" ->
          with {:ok, resolved} <- resolve_thread_request(connect, message, text, ref),
               true <-
                 trim(resolved["meet_url"]) == requested_url ||
                   {:error, :meet_url_not_in_current_source} do
            {:ok, resolved}
          else
            {:prompt, _text, _ref} -> {:error, :meet_url_not_in_current_source}
            {:error, _} = error -> error
          end

        length(current_urls) > 1 ->
          {:error, :ambiguous_meet_urls}

        length(current_urls) == 1 ->
          {:ok, request(hd(current_urls), [text], ref)}

        true ->
          case resolve_thread_request(connect, message, text, ref) do
            {:prompt, _text, _ref} -> {:error, :meeting_source_not_unique}
            other -> other
          end
      end
    end
  end

  defp requested_meet_url(params) do
    case trim(params["meet_url"]) do
      "" ->
        {:ok, ""}

      raw ->
        case meet_urls(raw) do
          [url] when url == raw -> {:ok, url}
          _ -> {:error, :invalid_google_meet_url}
        end
    end
  end

  defp resolve_thread_request(connect, message, text, ref) do
    case thread_id(message) do
      "" ->
        {:prompt, "请在包含 Google Meet 链接的会议话题中 @我说“入会”，或明确说“入会”并粘贴一个 Meet 链接。", ref}

      thread_id ->
        with {:ok, page} <-
               Feishu.call(nil, connect, "feishu.get_thread_replies", %{
                 "thread_id" => thread_id,
                 "page_size" => @thread_page_size
               }) do
          messages = List.wrap(page["messages"]) |> Enum.take(@thread_page_size)
          urls = messages |> Enum.flat_map(&message_urls/1) |> Enum.uniq()

          case urls do
            [url] -> {:ok, request(url, [text | Enum.map(messages, &trim(&1["text"]))], ref)}
            [] -> {:prompt, "这个话题最近 50 条消息里没有唯一的 Google Meet 链接，请明确说“入会”并粘贴链接。", ref}
            _ -> {:prompt, "这个话题里有多个 Google Meet 链接，请明确说“入会”并粘贴要加入的那个。", ref}
          end
        else
          {:error, reason} ->
            {:prompt, "读取会议话题失败（#{reason_text(reason)}），请明确说“入会”并粘贴 Google Meet 链接。", ref}
        end
    end
  end

  defp message_urls(message) do
    text_urls = meet_urls(trim(message["text"]))

    link_urls =
      message
      |> Map.get("links", [])
      |> List.wrap()
      |> Enum.flat_map(&meet_urls(trim((&1 || %{})["url"])))

    Enum.uniq(text_urls ++ link_urls)
  end

  defp meet_urls(text), do: Regex.scan(@meet_url, text) |> List.flatten() |> Enum.uniq()

  defp request(url, texts, ref) do
    %{
      "meet_url" => url,
      "title" => "Google Meet",
      "context_texts" => Enum.reject(texts, &(trim(&1) == "")),
      "feishu_ref" => ref
    }
  end

  defp feishu_ref(message) do
    root_message_id =
      first_nonblank([message["root_id"], message["thread_id"], message["message_id"]])

    %{
      "chat_id" => trim(message["chat_id"]),
      "chat_type" => trim(message["chat_type"]),
      "thread_id" => thread_id(message),
      "root_message_id" => root_message_id,
      "trigger_message_id" => trim(message["message_id"])
    }
  end

  defp thread_id(message),
    do: first_nonblank([message["thread_id"], message["root_id"]])

  # ---- state and runtime ----

  defp ensure_meeting(connect, meeting_agent, envelope, event, message, request) do
    ref = request["feishu_ref"]

    case find_active_meeting(connect, ref) do
      %{id: id, state: state} ->
        if trim(state["meet_url"]) == trim(request["meet_url"]) do
          {:ok, id, state, false}
        else
          {:prompt, "这个话题已经有另一场进行中的会议，请在新话题中发起。", ref}
        end

      nil ->
        create_meeting(connect, meeting_agent, envelope, event, message, request)
    end
  end

  defp create_meeting(connect, meeting_agent, envelope, event, message, request) do
    ref = request["feishu_ref"]
    meeting_id = meeting_id(connect, ref, request["meet_url"])
    now = System.system_time(:second)

    with {:ok, state} <-
           MeetingState.new_feishu(meeting_id, meeting_agent, %{
             "tenant_id" => connect["tenant_id"],
             "group_id" => connect["group_id"],
             "connect_id" => connect["connect_id"],
             "feishu_ref" => ref,
             "meet_url" => request["meet_url"],
             "title" => request["title"],
             "bot_name" => default_bot_name(),
             "caption_language" => infer_caption_language(request["context_texts"]),
             "start_at" => now,
             "end_at" => now + 3600,
             "runtime_source" => "connected_runtime",
             "source" => %{
               "event_id" =>
                 first_nonblank([get_in(envelope, ["header", "event_id"]), envelope["event_id"]]),
               "message_id" => trim(message["message_id"]),
               "sender_open_id" => trim(get_in(event, ["sender", "sender_id", "open_id"])),
               "tenant_key" =>
                 first_nonblank([
                   get_in(envelope, ["header", "tenant_key"]),
                   connect["tenant_key"]
                 ])
             }
           }) do
      case Store.create_once(meeting_id, state: state) do
        {:ok, _doc, _etag} ->
          with :ok <- put_source_index(connect, ref, meeting_id),
               do: {:ok, meeting_id, state, true}

        {:error, :exists} ->
          with {:ok, %{"state" => existing}, _etag} <- Store.get(meeting_id),
               :ok <- put_source_index(connect, ref, meeting_id) do
            {:ok, meeting_id, stringify(existing), false}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp notify_start(connect, meeting_id, state) do
    queue_text(connect, state, "meeting:#{meeting_id}:joining", "正在加入 Google Meet，等待会议准入…")
    |> ok_result()
  end

  defp request_meeting_join(meeting_id) do
    with :ok <- ensure_meeting_process(meeting_id) do
      request_join(meeting_id, 5)
    end
  end

  defp request_join(_meeting_id, 0), do: {:error, :meeting_join_not_leader}

  defp request_join(meeting_id, attempts) do
    case SalixMeet.Meeting.join(meeting_id) do
      {:ok, _joined_at} ->
        :ok

      {:error, reason} when reason in [:not_leader, :not_running] ->
        Process.sleep(10)
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

  defp deliver_trigger(connect, meeting_id, state, envelope, message) do
    trigger = %{
      "type" => "meeting_trigger",
      "event_id" =>
        first_nonblank([
          get_in(envelope, ["header", "event_id"]),
          envelope["event_id"],
          "feishu:" <> meeting_id
        ]),
      "meeting_id" => meeting_id,
      "provider" => "feishu",
      "connect_id" => connect["connect_id"],
      "meet_url" => state["meet_url"],
      "title" => state["title"],
      "caption_language" => state["caption_language"],
      "feishu_ref" => state["feishu_ref"],
      "source" => state["source"],
      "text" => FeishuMessage.text(message)
    }

    case Runtime.deliver_event(connect["tenant_id"], connect["group_id"], trigger) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  defp find_active_meeting(connect, ref) do
    with {:ok, %{"meeting_id" => meeting_id}} <- read_source_index(connect, ref),
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         state = stringify(state),
         true <- active_same_thread?(state, connect, ref) do
      %{id: meeting_id, state: state}
    else
      _ -> nil
    end
  end

  defp active_same_thread?(state, connect, ref) do
    state["tenant_id"] == connect["tenant_id"] and state["group_id"] == connect["group_id"] and
      state["provider"] == "feishu" and
      get_in(state, ["feishu_ref", "chat_id"]) == ref["chat_id"] and
      ref_identity(state["feishu_ref"] || %{}) == ref_identity(ref) and
      state["status"] not in RuntimeEvents.terminal_statuses()
  end

  defp read_source_index(connect, ref) do
    case S3.get(source_index_key(connect, ref)) do
      {:ok, %{body: body}} -> {:ok, Jason.decode!(body)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp put_source_index(connect, ref, meeting_id) do
    record = %{
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "provider" => "feishu",
      "connect_id" => connect["connect_id"],
      "chat_id" => ref["chat_id"],
      "thread_id" => ref["thread_id"],
      "root_message_id" => ref["root_message_id"],
      "meeting_id" => meeting_id,
      "updated_at" => System.system_time(:second)
    }

    case S3.put(source_index_key(connect, ref), Jason.encode!(record)) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  defp source_index_key(connect, ref) do
    digest =
      Crypto.hex([
        trim(connect["tenant_id"]),
        <<0>>,
        trim(connect["group_id"]),
        <<0>>,
        trim(connect["connect_id"]),
        <<0>>,
        trim(ref["chat_id"]),
        <<0>>,
        ref_identity(ref)
      ])

    "meet/sources/feishu/#{trim(connect["group_id"])}/#{digest}.json"
  end

  defp ref_identity(ref),
    do: first_nonblank([ref["thread_id"], ref["root_message_id"], ref["trigger_message_id"]])

  defp meeting_id(connect, ref, meet_url) do
    digest =
      Crypto.hex([
        "comma30-feishu-meeting-v1",
        <<0>>,
        trim(connect["tenant_id"]),
        <<0>>,
        trim(connect["group_id"]),
        <<0>>,
        trim(connect["connect_id"]),
        <<0>>,
        trim(ref["chat_id"]),
        <<0>>,
        ref_identity(ref),
        <<0>>,
        meet_url
      ])
      |> binary_part(0, 24)

    "mtg-" <> digest
  end

  # ---- direct provider delivery ----

  defp prompt(connect, ref, text) do
    case queue_text(
           connect,
           %{"group_id" => connect["group_id"], "feishu_ref" => ref},
           prompt_key(ref, text),
           text
         ) do
      {:ok, _result} -> {:ok, :handled}
      {:error, _} = error -> error
    end
  end

  defp queue_text(connect, state, idempotency_key, text),
    do: queue_text(connect, state, idempotency_key, text, %{"mode" => "none", "users" => []})

  defp queue_text(connect, state, idempotency_key, text, mentions) do
    with {:ok, target} <- direct_delivery_target(connect, state),
         {:ok, status} <-
           FeishuDirectDelivery.post_text(connect, target, text, mentions, idempotency_key) do
      {:ok, %{"delivery_status" => "sent", "provider_status" => status}}
    end
  end

  defp queue_file(connect, state, idempotency_key, artifact, source_agent_id, blob_ref) do
    with {:ok, target} <- direct_delivery_target(connect, state) do
      case FeishuDirectDelivery.post_file(
             source_agent_id,
             connect,
             target,
             trim(artifact["path"]),
             blob_ref,
             idempotency_key
           ) do
        {:ok, status} ->
          {:ok, %{"delivery_status" => "sent", "provider_status" => status}}

        {:error, reason} ->
          if feishu_file_permission_failure?(reason) do
            with {:ok, notice_status} <-
                   FeishuDirectDelivery.post_text(
                     connect,
                     target,
                     artifact_permission_notice(artifact),
                     %{"mode" => "none", "users" => []},
                     idempotency_key <> ":permission-notice"
                   ) do
              {:ok,
               %{
                 "delivery_status" => "permission_notice_sent",
                 "provider_status" => notice_status
               }}
            end
          else
            {:error, reason}
          end
      end
    end
  end

  defp direct_delivery_target(connect, state) do
    group_id = trim(state["group_id"] || connect["group_id"])
    ref = stringify(state["feishu_ref"] || %{})

    target = %{
      "chat_id" => trim(ref["chat_id"]),
      "chat_type" => trim(ref["chat_type"]),
      "message_thread_id" => trim(ref["thread_id"]),
      "root_message_id" => trim(ref["root_message_id"]),
      "trigger_message_id" => trim(ref["trigger_message_id"])
    }

    if group_id != "" and trim(connect["connect_id"]) != "" and target["chat_id"] != "",
      do: {:ok, target},
      else: {:error, :invalid_feishu_delivery_target}
  end

  defp feishu_file_permission_failure?(reason) do
    reason = reason |> inspect() |> String.downcase()
    Enum.any?(["permission", "scope"], &String.contains?(reason, &1))
  end

  # ---- terminal publication ----

  defp publish_terminal(meeting_agent, connect, meeting_id, state, claim) do
    delivery = stringify(state["delivery"] || %{})

    with :ok <-
           ensure_piece(meeting_id, claim, delivery, "feishu_summary", fn ->
             queue_text(
               connect,
               state,
               "meeting:#{meeting_id}:summary",
               terminal_text(state),
               terminal_mentions(state)
             )
           end),
         :ok <- publish_terminal_artifacts(meeting_agent, connect, meeting_id, state, claim),
         {:ok, _doc, _etag} <-
           Store.checkpoint_delivery(meeting_id, claim, %{
             "provider" => "feishu",
             "status" => "published",
             "published_at" => System.system_time(:second),
             "activation" => %{
               "status" => "pending",
               "attempt_count" => 0,
               "updated_at" => System.system_time(:millisecond)
             }
           }) do
      {:ok, %{"published" => true}}
    end
  end

  defp publish_terminal_artifacts(meeting_agent, connect, meeting_id, state, claim) do
    if state["status"] in ["failed", "cancelled"] and
         not SalixMeet.Outcome.partial_recording?(state) do
      delivery = stringify(state["delivery"] || %{})

      with :ok <- checkpoint_piece_if_missing(meeting_id, claim, delivery, "feishu_transcript"),
           :ok <- checkpoint_piece_if_missing(meeting_id, claim, delivery, "feishu_audio"),
           do: :ok
    else
      with :ok <- publish_artifact(meeting_agent, connect, meeting_id, state, claim, "transcript"),
           :ok <- publish_artifact(meeting_agent, connect, meeting_id, state, claim, "audio"),
           do: :ok
    end
  end

  defp publish_artifact(meeting_agent, connect, meeting_id, state, claim, kind) do
    artifact = stringify(get_in(state, ["artifacts", kind]) || %{})
    path = trim(artifact["path"])
    delivery = stringify(state["delivery"] || %{})
    key = "feishu_#{kind}"
    intent = stringify(delivery[key <> "_intent"] || %{})

    cond do
      Map.has_key?(delivery, key) ->
        :ok

      map_size(intent) > 0 ->
        publish_staged_artifact(connect, meeting_id, state, claim, kind, intent)

      path == "" ->
        publish_unavailable_artifact(
          connect,
          meeting_id,
          state,
          claim,
          kind,
          "missing",
          artifact_unavailable_text(kind, :missing)
        )

      true ->
        case SalixMeet.Ports.AgentRuntime.stat_workspace(
               meeting_agent["meeting_agent_id"],
               path
             ) do
          {:ok, metadata} ->
            publish_available_artifact(
              metadata,
              meeting_agent,
              connect,
              meeting_id,
              state,
              claim,
              kind,
              artifact
            )

          {:error, :not_found} ->
            publish_unavailable_artifact(
              connect,
              meeting_id,
              state,
              claim,
              kind,
              "missing",
              artifact_unavailable_text(kind, :missing)
            )

          {:error, _} = error ->
            error
        end
    end
  end

  defp publish_available_artifact(
         metadata,
         meeting_agent,
         connect,
         meeting_id,
         state,
         claim,
         kind,
         artifact
       ) do
    case artifact_ref(metadata) do
      {:ok, size, blob_ref} when size <= @max_file_upload_bytes ->
        intent = artifact_delivery_intent(artifact, meeting_agent["meeting_agent_id"], blob_ref)

        with :ok <- checkpoint_artifact_intent(meeting_id, claim, kind, intent),
             :ok <- publish_staged_artifact(connect, meeting_id, state, claim, kind, intent) do
          :ok
        end

      {:ok, _size, _blob_ref} ->
        publish_unavailable_artifact(
          connect,
          meeting_id,
          state,
          claim,
          kind,
          "too_large",
          artifact_unavailable_text(kind, :too_large)
        )

      {:error, _} = error ->
        error
    end
  end

  defp artifact_ref(metadata) when is_map(metadata) do
    size = metadata[:size] || metadata["size"]
    ref = stringify(metadata[:ref] || metadata["ref"] || %{})

    if is_integer(size) and size >= 0 and valid_blob_ref?(ref, size) do
      {:ok, size, ref}
    else
      {:error, :invalid_artifact_metadata}
    end
  end

  defp artifact_ref(_metadata), do: {:error, :invalid_artifact_metadata}

  defp valid_blob_ref?(ref, size) do
    ref["kind"] == "blob" and trim(ref["uuid"]) != "" and ref["size"] == size and
      trim(ref["hash"]) != ""
  end

  defp artifact_delivery_intent(artifact, source_agent_id, blob_ref) do
    path = trim(artifact["path"])

    %{
      "status" => "ready",
      "artifact" => %{
        "path" => path,
        "filename" => first_nonblank([artifact["filename"], Path.basename(path)])
      },
      "source_agent_id" => trim(source_agent_id),
      "blob_ref" => stringify(blob_ref)
    }
  end

  defp checkpoint_artifact_intent(meeting_id, claim, kind, intent) do
    case Store.checkpoint_delivery(meeting_id, claim, %{"feishu_#{kind}_intent" => intent}) do
      {:ok, _doc, _etag} -> :ok
      {:error, _} = error -> error
    end
  end

  defp publish_staged_artifact(connect, meeting_id, state, claim, kind, intent) do
    with {:ok, artifact, source_agent_id, blob_ref} <-
           validate_artifact_delivery_intent(state, intent),
         {:ok, result} <-
           queue_file(
             connect,
             state,
             "meeting:#{meeting_id}:#{kind}",
             artifact,
             source_agent_id,
             blob_ref
           ),
         :ok <-
           checkpoint_piece(
             meeting_id,
             claim,
             "feishu_#{kind}",
             delivery_checkpoint_status(result)
           ) do
      :ok
    end
  end

  defp validate_artifact_delivery_intent(state, intent) do
    intent = stringify(intent)
    artifact = stringify(intent["artifact"] || %{})
    blob_ref = stringify(intent["blob_ref"] || %{})
    source_agent_id = trim(intent["source_agent_id"])
    expected_agent_id = trim(state["meeting_agent_id"])
    size = blob_ref["size"]

    cond do
      intent["status"] != "ready" ->
        {:error, :invalid_artifact_delivery_intent}

      trim(artifact["path"]) == "" ->
        {:error, :invalid_artifact_delivery_intent}

      trim(artifact["filename"]) == "" ->
        {:error, :invalid_artifact_delivery_intent}

      source_agent_id == "" or source_agent_id != expected_agent_id ->
        {:error, :invalid_artifact_delivery_intent}

      not is_integer(size) or size < 0 or size > @max_file_upload_bytes ->
        {:error, :invalid_artifact_delivery_intent}

      not valid_blob_ref?(blob_ref, size) ->
        {:error, :invalid_artifact_delivery_intent}

      true ->
        {:ok, artifact, source_agent_id, blob_ref}
    end
  end

  defp publish_unavailable_artifact(
         connect,
         meeting_id,
         state,
         claim,
         kind,
         status,
         text
       ) do
    delivery = stringify(state["delivery"] || %{})
    key = "feishu_#{kind}"

    with :ok <-
           ensure_piece(meeting_id, claim, delivery, key <> "_notice", fn ->
             queue_text(connect, state, "meeting:#{meeting_id}:#{kind}:unavailable", text)
           end),
         :ok <- checkpoint_piece(meeting_id, claim, key, status) do
      :ok
    end
  end

  defp artifact_unavailable_text("transcript", :missing),
    do: "会议摘要已发布，但逐字稿文件已删除或不可用，未能上传。"

  defp artifact_unavailable_text("audio", :missing),
    do: "会议摘要已发布，但录音文件已删除或不可用，未能上传。"

  defp artifact_unavailable_text("transcript", :too_large),
    do: "会议摘要已发布，但逐字稿超过飞书单文件 30 MB 上限，未能上传。"

  defp artifact_unavailable_text("audio", :too_large),
    do: "会议摘要已发布，但录音超过飞书单文件 30 MB 上限，未能上传。"

  defp artifact_permission_notice(artifact) do
    value = String.downcase(trim(artifact["filename"] || artifact["path"]))

    if String.contains?(value, ["transcript", "逐字"]),
      do: "会议摘要已发布，但飞书机器人缺少文件上传或发送权限，逐字稿未能上传。",
      else: "会议摘要已发布，但飞书机器人缺少文件上传或发送权限，录音未能上传。"
  end

  defp ensure_piece(_meeting_id, _claim, delivery, key, _fun)
       when is_map_key(delivery, key),
       do: :ok

  defp ensure_piece(meeting_id, claim, _delivery, key, fun) do
    with {:ok, result} <- fun.(),
         do: checkpoint_piece(meeting_id, claim, key, delivery_checkpoint_status(result))
  end

  defp delivery_checkpoint_status(%{"delivery_status" => status})
       when status in ["sent", "permission_notice_sent"],
       do: status

  defp delivery_checkpoint_status(_result), do: "sent"

  defp checkpoint_piece(meeting_id, claim, key, status) do
    case Store.checkpoint_delivery(meeting_id, claim, %{key => status}) do
      {:ok, _doc, _etag} -> :ok
      {:error, _} = error -> error
    end
  end

  defp checkpoint_piece_if_missing(_meeting_id, _claim, delivery, key)
       when is_map_key(delivery, key),
       do: :ok

  defp checkpoint_piece_if_missing(meeting_id, claim, _delivery, key),
    do: checkpoint_piece(meeting_id, claim, key, "not_applicable")

  # The active-connect lookup folds deleted/disabled/mismatched into
  # :not_found, which the delivery gate cannot tell apart from a transient
  # miss — a disabled Feishu connect would be wrongly terminalized after the
  # bounded-retry gates and could never catch up on re-enable. Classify from
  # the raw record instead, exactly like the Slack provider: deleted
  # converges terminally, disabled stays a gate-exempt retryable wait, and a
  # truly missing record stays retryable for the gate to converge.
  defp publishable_feishu_connect(group_id, connect_id) do
    case SalixIM.ProviderConnects.fetch_im_connect(group_id, connect_id) do
      {:ok, connect} ->
        cond do
          connect["deleted_at"] -> {:error, {:connect_terminal, "connect deleted"}}
          connect["disabled_at"] -> {:error, {:connect_unavailable, :disabled}}
          connect["provider"] != "feishu" -> {:error, :not_feishu_connect}
          true -> {:ok, connect}
        end

      {:error, _} = error ->
        error
    end
  end

  defp terminal_text(%{"status" => "failed", "watchdog" => %{"reason" => "runtime_lost"}}),
    do: "本场会议的记录不完整：会议运行时在报告结束前失联，无法生成总结。"

  defp terminal_text(%{"status" => "failed", "reason_code" => code} = state)
       when code in ~w(admission_denied meeting_full removed_from_meeting admission_timeout),
       do: SalixMeet.Outcome.notice(state)

  defp terminal_text(%{"status" => "failed"} = state),
    do: "会议处理失败：" <> first_nonblank([state["error"], "未知错误"])

  defp terminal_text(%{"status" => "cancelled"}), do: "会议已取消。"

  defp terminal_text(state) do
    snapshot = OwnerAttributionSnapshot.current(state)

    summary =
      OwnerAttributionSnapshot.bound_summary(
        snapshot,
        stringify(state["summary"] || %{})
      )

    title = first_nonblank([summary["title"], state["title"], "会议摘要"])

    ["会议摘要：" <> title, SalixMeet.Outcome.text(state["reason_code"])]
    |> Enum.reject(&is_nil/1)
    |> section("要点", summary["key_points"], &bullet/1)
    |> section("行动项", summary["action_items"], &action_item/1)
    |> section("决策", summary["decisions"], &bullet/1)
    |> section("待确认", summary["open_questions"], &bullet/1)
    |> section("阻塞项", summary["blockers"], &bullet/1)
    |> unresolved_owner_confirmation(summary, snapshot)
    |> Enum.join("\n")
  end

  defp unresolved_owner_confirmation(lines, summary, snapshot) do
    resolved =
      snapshot
      |> OwnerAttributionSnapshot.provider_identities_for(summary, "feishu")
      |> Map.keys()
      |> MapSet.new()

    unresolved =
      summary
      |> Map.get("action_items", [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{} = item, index} ->
          owner = first_nonblank([item["owner"], item["assignee"], item["owner_name"]])

          if owner != "" and not MapSet.member?(resolved, index),
            do: ["- 行动项 ##{index + 1}：请确认负责人「#{owner}」"],
            else: []

        {_item, _index} ->
          []
      end)

    if unresolved == [], do: lines, else: lines ++ ["", "负责人待确认：" | unresolved]
  end

  defp terminal_mentions(state) do
    snapshot = OwnerAttributionSnapshot.current(state)
    summary = OwnerAttributionSnapshot.bound_summary(snapshot, stringify(state["summary"] || %{}))

    users =
      if trim(state["status"]) == "done" do
        snapshot
        |> OwnerAttributionSnapshot.provider_identities_for(summary, "feishu")
        |> Enum.sort_by(fn {index, _identity} -> index end)
        |> Enum.map(fn {_index, identity} ->
          %{"user_id" => identity["user_id"], "name" => identity["display_name"]}
        end)
        |> Enum.uniq_by(& &1["user_id"])
        |> Enum.take(100)
      else
        []
      end

    if users == [],
      do: %{"mode" => "none", "users" => []},
      else: %{"mode" => "users", "users" => users}
  end

  defp section(lines, _label, values, _formatter) when not is_list(values), do: lines
  defp section(lines, _label, [], _formatter), do: lines

  defp section(lines, label, values, formatter) do
    lines ++ ["", label <> "："] ++ Enum.map(values, formatter)
  end

  defp bullet(value) when is_map(value),
    do:
      "- " <>
        first_nonblank([value["text"], value["title"], value["description"], inspect(value)])

  defp bullet(value), do: "- " <> trim(value)

  defp action_item(item) when is_map(item) do
    owner = first_nonblank([item["owner"], item["assignee"], item["owner_name"]])
    text = first_nonblank([item["text"], item["task"], item["description"], inspect(item)])
    due = trim(item["due_date"] || item["due"])

    [
      text,
      if(owner == "", do: nil, else: "负责人：" <> owner),
      if(due == "", do: nil, else: "截止：" <> due)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("；")
    |> then(&("- " <> &1))
  end

  defp action_item(value), do: bullet(value)

  # ---- small helpers ----

  defp infer_caption_language(texts) do
    combined = Enum.join(List.wrap(texts), " ")
    han = Regex.scan(~r/\p{Han}/u, combined) |> length()
    latin = Regex.scan(~r/[A-Za-z]/u, combined) |> length()

    if han >= 4 and han > latin,
      do: @default_caption_language,
      else: Application.get_env(:salix_meet, :default_caption_language, @default_caption_language)
  end

  defp status_text(%{"type" => "status", "status" => "error", "reason_code" => code})
       when code in ~w(admission_denied meeting_full removed_from_meeting admission_timeout),
       do: {"error", SalixMeet.Outcome.text(code)}

  defp status_text(%{"type" => "status", "status" => "waiting_room"}),
    do: {"waiting_room", "已请求入会，正在等待主持人准入…"}

  defp status_text(%{"type" => "status", "status" => "in_meeting"}),
    do: {"in_meeting", "已加入 Google Meet。"}

  defp status_text(%{"type" => "status", "status" => "left"}),
    do: {"left", "已离开会议，正在整理摘要和会议产物…"}

  defp status_text(%{"type" => "status", "status" => "error"} = event),
    do: {"error", "加入会议失败：" <> first_nonblank([event["message"], "未知错误"])}

  defp status_text(_event), do: nil

  defp default_bot_name,
    do: Application.get_env(:salix_meet, :default_bot_name, @default_bot_name)

  defp prompt_key(ref, text) do
    digest = Crypto.hex([ref_identity(ref), <<0>>, text]) |> binary_part(0, 24)
    "meeting-prompt:" <> digest
  end

  defp maybe_check_claim(_meeting_id, claim) when claim == %{}, do: :ok
  defp maybe_check_claim(meeting_id, claim), do: Store.check_delivery_claim(meeting_id, claim)

  defp ok_result({:ok, _result}), do: :ok
  defp ok_result({:error, _} = error), do: error

  defp require_nonblank(value, reason), do: if(trim(value) == "", do: {:error, reason}, else: :ok)

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

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
