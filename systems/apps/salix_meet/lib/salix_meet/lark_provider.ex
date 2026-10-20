defmodule SalixMeet.LarkProvider do
  @moduledoc """
  Google Meet meetings a person starts from Lark, and what the bot says
  about them in Lark.

  The Router's `meeting.join` tool is the only entry. The meeting is the one
  Meet link of the person's message, or the one link of its thread. The thread
  is read as one page of 50 messages; the history of the chat is never read.
  Status, the summary and the files go to that thread through
  `SalixIM.Ports.LarkDirectDelivery`.
  """

  alias SalixIM.Ports.LarkDirectDelivery
  alias SalixIM.Provider.Lark
  alias SalixIM.Provider.Lark.Message, as: LarkMessage
  alias SalixMeet.{MeetingState, OwnerAttributionSnapshot, Runtime, RuntimeEvents, Store}
  alias SalixStore.{Crypto, S3}

  @meet_url ~r|https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[^\s<>]*)?|iu
  @default_caption_language "Chinese, Mandarin (Simplified)"
  @default_bot_name "Cirno"
  @thread_page_size 50
  @max_file_upload_bytes 30 * 1024 * 1024

  @doc "Execute one Router-authorized manual join after validating its sealed Lark source."
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
         "provider" => "lark"
       }}
    else
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
         true <- state["provider"] == "lark" || {:error, :not_lark_meeting},
         :ok <- maybe_check_claim(meeting_id, claim),
         {:ok, connect} <- publishable_lark_connect(state["group_id"], state["connect_id"]) do
      if payload["kind"] == "summary_generating" do
        publish_generating_status(connect, meeting_id, claim)
      else
        publish_terminal(meeting_agent, connect, meeting_id, state, claim)
      end
    else
      {:error, :not_found} -> {:error, "meeting not found"}
      {:error, _} = error -> error
      false -> {:error, :not_lark_meeting}
    end
  end

  defp publish_generating_status(connect, meeting_id, claim) do
    with :ok <- maybe_check_claim(meeting_id, claim),
         {:ok, %{"state" => state}, _etag} <- Store.get(meeting_id),
         state = stringify(state),
         true <- generating_status_applicable?(state) do
      queue_text(
        connect,
        state,
        "meeting:#{meeting_id}:generating",
        "Preparing the meeting summary…"
      )
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
                 "lark"
               ),
             {:ok, _result} <-
               queue_text(connect, state, "meeting:#{meeting_id}:status:#{status}", text) do
          :ok
        end
    end
  end

  # ---- the meeting the request names ----

  defp resolve_router_request(connect, message, params) do
    text = LarkMessage.text(message)
    ref = lark_ref(message)
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
            :not_unique -> {:error, :meet_url_not_in_current_source}
            {:error, _} = error -> error
          end

        length(current_urls) > 1 ->
          {:error, :ambiguous_meet_urls}

        length(current_urls) == 1 ->
          {:ok, request(hd(current_urls), [text], ref)}

        true ->
          case resolve_thread_request(connect, message, text, ref) do
            :not_unique -> {:error, :meeting_source_not_unique}
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

  # The one Meet link of the thread of the message. `:not_unique` when the
  # message is in no thread, the thread could not be read, or it holds no
  # link or more than one.
  defp resolve_thread_request(connect, message, text, ref) do
    case thread_id(message) do
      "" ->
        :not_unique

      thread_id ->
        case Lark.call(nil, connect, "lark.get_thread_replies", %{
               "thread_id" => thread_id,
               "page_size" => @thread_page_size
             }) do
          {:ok, page} ->
            messages = List.wrap(page["messages"]) |> Enum.take(@thread_page_size)

            case messages |> Enum.flat_map(&message_urls/1) |> Enum.uniq() do
              [url] -> {:ok, request(url, [text | Enum.map(messages, &trim(&1["text"]))], ref)}
              _ -> :not_unique
            end

          {:error, _reason} ->
            :not_unique
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
      "lark_ref" => ref
    }
  end

  # `root_message_id` is the message the bot answers under. A thread ID is
  # not a message, so the first message of a thread is its own root.
  defp lark_ref(message) do
    root_message_id = first_nonblank([message["root_id"], message["message_id"]])

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
    ref = request["lark_ref"]

    case find_active_meeting(connect, ref) do
      %{id: id, state: state} ->
        if trim(state["meet_url"]) == trim(request["meet_url"]) do
          {:ok, id, state, false}
        else
          {:error, :meeting_thread_has_different_meeting}
        end

      nil ->
        create_meeting(connect, meeting_agent, envelope, event, message, request)
    end
  end

  defp create_meeting(connect, meeting_agent, envelope, event, message, request) do
    ref = request["lark_ref"]
    meeting_id = meeting_id(connect, ref, request["meet_url"])
    now = SystemsClock.system_time(:second)

    with {:ok, state} <-
           MeetingState.new_lark(meeting_id, meeting_agent, %{
             "tenant_id" => connect["tenant_id"],
             "group_id" => connect["group_id"],
             "connect_id" => connect["connect_id"],
             "lark_ref" => ref,
             "meet_url" => request["meet_url"],
             "title" => request["title"],
             "bot_name" => default_bot_name(),
             "caption_language" => infer_caption_language(request["context_texts"]),
             "start_at" => now,
             "end_at" => now + 3600,
             "runtime_source" => SalixMeet.MeetingRuntimePolicy.default_source(),
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
    queue_text(
      connect,
      state,
      "meeting:#{meeting_id}:joining",
      "Joining the Google Meet and waiting to be admitted…"
    )
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

  defp deliver_trigger(connect, meeting_id, state, envelope, message) do
    trigger = %{
      "type" => "meeting_trigger",
      "event_id" =>
        first_nonblank([
          get_in(envelope, ["header", "event_id"]),
          envelope["event_id"],
          "lark:" <> meeting_id
        ]),
      "meeting_id" => meeting_id,
      "provider" => "lark",
      "connect_id" => connect["connect_id"],
      "meet_url" => state["meet_url"],
      "title" => state["title"],
      "caption_language" => state["caption_language"],
      "lark_ref" => state["lark_ref"],
      "source" => state["source"],
      "text" => LarkMessage.text(message)
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
      state["provider"] == "lark" and
      get_in(state, ["lark_ref", "chat_id"]) == ref["chat_id"] and
      ref_identity(state["lark_ref"] || %{}) == ref_identity(ref) and
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
      "provider" => "lark",
      "connect_id" => connect["connect_id"],
      "chat_id" => ref["chat_id"],
      "thread_id" => ref["thread_id"],
      "root_message_id" => ref["root_message_id"],
      "meeting_id" => meeting_id,
      "updated_at" => SystemsClock.system_time(:second)
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

    "meet/sources/lark/#{trim(connect["group_id"])}/#{digest}.json"
  end

  # A meeting belongs to the message a thread hangs under. A request at the
  # top of a chat has no thread yet, and the bot's answer opens one: the root
  # message is what both the first request and a later one in the thread
  # name, so it is the identity. A thread ID is not, because the first
  # request has none.
  defp ref_identity(ref),
    do: first_nonblank([ref["root_message_id"], ref["trigger_message_id"]])

  defp meeting_id(connect, ref, meet_url) do
    digest =
      Crypto.hex([
        "comma30-lark-meeting-v1",
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

  defp queue_text(connect, state, idempotency_key, text),
    do: queue_text(connect, state, idempotency_key, text, %{"mode" => "none", "users" => []})

  defp queue_text(connect, state, idempotency_key, text, mentions) do
    with {:ok, target} <- direct_delivery_target(connect, state),
         {:ok, status} <-
           LarkDirectDelivery.post_text(connect, target, text, mentions, idempotency_key) do
      {:ok, %{"delivery_status" => "sent", "provider_status" => status}}
    end
  end

  defp queue_file(connect, state, idempotency_key, artifact, source_agent_id, blob_ref) do
    with {:ok, target} <- direct_delivery_target(connect, state) do
      case LarkDirectDelivery.post_file(
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
          if lark_file_permission_failure?(reason) do
            with {:ok, notice_status} <-
                   LarkDirectDelivery.post_text(
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
    ref = stringify(state["lark_ref"] || %{})

    target = %{
      "chat_id" => trim(ref["chat_id"]),
      "chat_type" => trim(ref["chat_type"]),
      "message_thread_id" => trim(ref["thread_id"]),
      "root_message_id" => trim(ref["root_message_id"]),
      "trigger_message_id" => trim(ref["trigger_message_id"])
    }

    if group_id != "" and trim(connect["connect_id"]) != "" and target["chat_id"] != "",
      do: {:ok, target},
      else: {:error, :invalid_lark_delivery_target}
  end

  defp lark_file_permission_failure?(reason) do
    reason = reason |> inspect() |> String.downcase()
    Enum.any?(["permission", "scope"], &String.contains?(reason, &1))
  end

  # ---- terminal publication ----

  defp publish_terminal(meeting_agent, connect, meeting_id, state, claim) do
    delivery = stringify(state["delivery"] || %{})

    with :ok <-
           ensure_piece(meeting_id, claim, delivery, "lark_summary", fn ->
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
             "provider" => "lark",
             "status" => "published",
             "published_at" => SystemsClock.system_time(:second),
             "activation" => %{
               "status" => "pending",
               "attempt_count" => 0,
               "updated_at" => SystemsClock.system_time(:millisecond)
             }
           }) do
      {:ok, %{"published" => true}}
    end
  end

  defp publish_terminal_artifacts(meeting_agent, connect, meeting_id, state, claim) do
    if state["status"] in ["failed", "cancelled"] and
         not SalixMeet.Outcome.partial_recording?(state) do
      delivery = stringify(state["delivery"] || %{})

      with :ok <- checkpoint_piece_if_missing(meeting_id, claim, delivery, "lark_transcript"),
           :ok <- checkpoint_piece_if_missing(meeting_id, claim, delivery, "lark_audio"),
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
    key = "lark_#{kind}"
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
    case Store.checkpoint_delivery(meeting_id, claim, %{"lark_#{kind}_intent" => intent}) do
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
             "lark_#{kind}",
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
    key = "lark_#{kind}"

    with :ok <-
           ensure_piece(meeting_id, claim, delivery, key <> "_notice", fn ->
             queue_text(connect, state, "meeting:#{meeting_id}:#{kind}:unavailable", text)
           end),
         :ok <- checkpoint_piece(meeting_id, claim, key, status) do
      :ok
    end
  end

  defp artifact_unavailable_text("transcript", :missing),
    do:
      "The summary is posted. The transcript file was deleted or is not available, so it was not uploaded."

  defp artifact_unavailable_text("audio", :missing),
    do:
      "The summary is posted. The recording file was deleted or is not available, so it was not uploaded."

  defp artifact_unavailable_text("transcript", :too_large),
    do:
      "The summary is posted. The transcript is larger than the 30 MB limit of a Lark file, so it was not uploaded."

  defp artifact_unavailable_text("audio", :too_large),
    do:
      "The summary is posted. The recording is larger than the 30 MB limit of a Lark file, so it was not uploaded."

  defp artifact_permission_notice(artifact) do
    value = String.downcase(trim(artifact["filename"] || artifact["path"]))

    if String.contains?(value, "transcript"),
      do:
        "The summary is posted. The Lark bot has no permission to upload or send files, so the transcript was not uploaded.",
      else:
        "The summary is posted. The Lark bot has no permission to upload or send files, so the recording was not uploaded."
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
  # miss — a disabled Lark connect would be wrongly terminalized after the
  # bounded-retry gates and could never catch up on re-enable. Classify from
  # the raw record instead, exactly like the Slack provider: deleted
  # converges terminally, disabled stays a gate-exempt retryable wait, and a
  # truly missing record stays retryable for the gate to converge.
  defp publishable_lark_connect(group_id, connect_id) do
    case SalixIM.ProviderConnects.fetch_im_connect(group_id, connect_id) do
      {:ok, connect} ->
        cond do
          connect["deleted_at"] -> {:error, {:connect_terminal, "connect deleted"}}
          connect["disabled_at"] -> {:error, {:connect_unavailable, :disabled}}
          connect["provider"] != "lark" -> {:error, :not_lark_connect}
          true -> {:ok, connect}
        end

      {:error, _} = error ->
        error
    end
  end

  defp terminal_text(%{"status" => "failed", "watchdog" => %{"reason" => "runtime_lost"}}),
    do:
      "The record of this meeting is incomplete: the meeting runtime was lost before it reported the end, so there is no summary."

  defp terminal_text(%{"status" => "failed", "reason_code" => code} = state)
       when code in ~w(admission_denied meeting_full removed_from_meeting admission_timeout),
       do: outcome_notice(state)

  defp terminal_text(%{"status" => "failed"} = state),
    do:
      "The meeting could not be processed: " <> first_nonblank([state["error"], "unknown error"])

  defp terminal_text(%{"status" => "cancelled"}), do: "The meeting was cancelled."

  defp terminal_text(state) do
    snapshot = OwnerAttributionSnapshot.current(state)

    summary =
      OwnerAttributionSnapshot.bound_summary(
        snapshot,
        stringify(state["summary"] || %{})
      )

    title = first_nonblank([summary["title"], state["title"], "Meeting"])

    ["Meeting summary: " <> title, outcome_text(state["reason_code"])]
    |> Enum.reject(&is_nil/1)
    |> section("Key points", summary["key_points"], &bullet/1)
    |> section("Action items", summary["action_items"], &action_item/1)
    |> section("Decisions", summary["decisions"], &bullet/1)
    |> section("Open questions", summary["open_questions"], &bullet/1)
    |> section("Blockers", summary["blockers"], &bullet/1)
    |> unresolved_owner_confirmation(summary, snapshot)
    |> Enum.join("\n")
  end

  defp unresolved_owner_confirmation(lines, summary, snapshot) do
    resolved =
      snapshot
      |> OwnerAttributionSnapshot.provider_identities_for(summary, "lark")
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
            do: ["- Action item ##{index + 1}: please confirm the owner \"#{owner}\""],
            else: []

        {_item, _index} ->
          []
      end)

    if unresolved == [], do: lines, else: lines ++ ["", "Owners to confirm:" | unresolved]
  end

  defp terminal_mentions(state) do
    snapshot = OwnerAttributionSnapshot.current(state)
    summary = OwnerAttributionSnapshot.bound_summary(snapshot, stringify(state["summary"] || %{}))

    users =
      if trim(state["status"]) == "done" do
        snapshot
        |> OwnerAttributionSnapshot.provider_identities_for(summary, "lark")
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
    lines ++ ["", label <> ":"] ++ Enum.map(values, formatter)
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
      if(owner == "", do: nil, else: "Owner: " <> owner),
      if(due == "", do: nil, else: "Due: " <> due)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
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
      else:
        SystemsRuntime.get_env(:salix_meet, :default_caption_language, @default_caption_language)
  end

  defp status_text(%{"type" => "status", "status" => "error", "reason_code" => code})
       when code in ~w(admission_denied meeting_full removed_from_meeting admission_timeout),
       do: {"error", outcome_text(code)}

  defp status_text(%{"type" => "status", "status" => "guest_fallback"}),
    do: {"guest_fallback", "The Google sign-in expired, so I am joining as a guest."}

  defp status_text(%{"type" => "status", "status" => "waiting_room"}),
    do: {"waiting_room", "I asked to join and am waiting for a host to admit me…"}

  defp status_text(%{"type" => "status", "status" => "in_meeting"}),
    do: {"in_meeting", "Joined the Google Meet."}

  defp status_text(%{"type" => "status", "status" => "left"}),
    do: {"left", "Left the meeting. Preparing the summary and the files…"}

  defp status_text(%{"type" => "status", "status" => "error"} = event),
    do:
      {"error",
       "Could not join the meeting: " <> first_nonblank([event["message"], "unknown error"])}

  defp status_text(_event), do: nil

  # Why the bot is not in the meeting, in the words of the other Lark texts.
  defp outcome_notice(state) do
    if SalixMeet.Outcome.partial_recording?(state),
      do:
        "The bot was removed from the meeting. The meeting could not be processed, and the record below may be incomplete.",
      else: outcome_text(state["reason_code"])
  end

  defp outcome_text("admission_denied"), do: "The request to join was denied."
  defp outcome_text("meeting_full"), do: "The meeting is full, so I could not join."
  defp outcome_text("removed_from_meeting"), do: "The bot was removed from the meeting."
  defp outcome_text("admission_timeout"), do: "Nobody admitted me before the wait ended."
  defp outcome_text(_code), do: nil

  defp default_bot_name,
    do: SystemsRuntime.get_env(:salix_meet, :default_bot_name, @default_bot_name)

  defp maybe_check_claim(_meeting_id, claim) when claim == %{}, do: :ok
  defp maybe_check_claim(meeting_id, claim), do: Store.check_delivery_claim(meeting_id, claim)

  defp ok_result({:ok, _result}), do: :ok
  defp ok_result({:error, _} = error), do: error

  defp require_nonblank(value, reason), do: if(trim(value) == "", do: {:error, reason}, else: :ok)

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
