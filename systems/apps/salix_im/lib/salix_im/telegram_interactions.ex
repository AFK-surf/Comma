defmodule SalixIM.TelegramInteractions do
  @moduledoc """
  Durable, private-chat questions with one immutable response and idempotent
  Router delivery. Modeled in tla/salix/TelegramInteractions.tla.

  The send claim is persisted before HTTP: an ambiguous send is never retried
  blindly. Decisions are saved before enqueueing; repeats resume the same input.
  Neither prompts nor pending human decisions keep a runtime tool running.
  """

  alias SalixIM.{
    GroupDirectory,
    ProviderConnects,
    ProviderRecipientIdentity,
    TelegramStatusTransport
  }

  alias SalixStore.TelegramInteractions, as: Store
  alias SalixStore.OAuth.AuthState

  @labels %{
    "en" => %{
      selected: "✅ Selected: ",
      cancelled: "Cancelled",
      denied: "Declined",
      approved: "✅ Allowed this time",
      oauth_completed: "✅ Authorization completed",
      oauth_failed: "Authorization incomplete",
      permission: "Allow this operation once?",
      location:
        "Share a location using Telegram, or reply to this message with your city. Sharing precise location is optional.",
      location_placeholder: "Reply with a city, or share location",
      share: "Share location",
      no_share: "Don't share / Cancel",
      reply: "Reply to this question",
      allow: "Allow this time",
      authorize: "Authorize",
      verify: "Check authorization",
      deny: "Decline / Cancel",
      received: "Received",
      oauth_pending: "Authorization is not complete. Finish the browser flow and try again.",
      invalid: "This request is invalid, already handled, or expired."
    },
    "zh-CN" => %{
      selected: "✅ 已选择：",
      cancelled: "已取消",
      denied: "已拒绝",
      approved: "✅ 已允许这一次",
      oauth_completed: "✅ 授权已完成",
      oauth_failed: "授权未完成",
      permission: "是否允许这一次操作？",
      location: "请通过 Telegram 分享位置，或回复这条消息告诉我城市。不必提供精确定位。",
      location_placeholder: "回复城市，或分享位置",
      share: "分享位置",
      no_share: "不分享 / 取消",
      reply: "回复这个问题",
      allow: "允许这一次",
      authorize: "前往授权",
      verify: "检查授权结果",
      deny: "拒绝 / 取消",
      received: "已收到",
      oauth_pending: "授权尚未完成，请完成浏览器流程后重试",
      invalid: "此请求无效、已处理或已过期"
    }
  }

  def id(scope, call_id) do
    [scope["agent_id"], scope["session_id"], call_id]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def request(scope, type, args, call_id) do
    observe("telegram_interaction_prompt", fn -> do_request(scope, type, args, call_id) end)
  end

  defp do_request(scope, type, args, call_id) do
    with true <- is_binary(call_id) and call_id != "",
         {:ok, connect} <- active_connect(scope),
         {:ok, locale} <- locale(args["locale"]),
         {:ok, prompt, choices} <- prompt(type, Map.put(args, "locale", locale)),
         {:ok, timeout} <- timeout(args["timeout_seconds"]) do
      request_id = id(scope, call_id)

      record = %{
        "id" => request_id,
        "scope" => scope,
        "type" => type,
        "locale" => locale,
        "prompt" => prompt,
        "choices" => choices,
        "status" => "sending",
        "connect_epoch" => epoch(connect),
        "expires_at" => now() + timeout,
        "oauth_state" => args["oauth_state"],
        "authorization_url" => args["authorization_url"]
      }

      case Store.create(record) do
        {:ok, record} ->
          send_prompt(connect, record)

        {:error, :exists} ->
          with {:ok, saved} <- Store.get(scope["group_id"], request_id),
               true <- saved["status"] in ["pending", "decided", "delivered"],
               true <- saved["scope"] == scope and saved["connect_epoch"] == epoch(connect),
               true <-
                 saved["type"] == type and saved["prompt"] == prompt and
                   saved["choices"] == choices and (saved["locale"] || "zh-CN") == locale do
            delivered_receipt(saved)
          else
            _ -> {:error, :send_outcome_unknown}
          end

        error ->
          error
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def handle_update(connect, %{"callback_query" => callback}) do
    case String.split(text(callback["data"]), ":") do
      ["ci", request_id, choice] when byte_size(request_id) == 43 ->
        message = callback["message"] || %{}
        result = respond(connect, request_id, message, callback["from"], choice)
        answer_callback(connect, callback["id"], request_id, result)
        handled(result)

      _ ->
        :unhandled
    end
  end

  def handle_update(connect, %{"message" => message}) do
    reply_id = get_in(message, ["reply_to_message", "message_id"])

    case response_request(connect, message, reply_id) do
      {:ok, record} ->
        with true <- record["type"] in ["question", "location"],
             {:ok, response} <- typed_response(record, message) do
          handled(
            decide(connect, record, message, message["from"], response, record["message_id"])
          )
        else
          false -> :unhandled
          error -> handled(error)
        end

      {:error, :not_found} ->
        :unhandled

      :unhandled ->
        :unhandled

      error ->
        handled(error)
    end
  end

  def handle_update(_, _), do: :unhandled

  defp response_request(connect, _message, reply_id) when is_integer(reply_id),
    do: Store.get_by_reply(connect["group_id"], connect["connect_id"], reply_id)

  defp response_request(connect, message, nil) do
    native_response? =
      is_map(message["location"]) or
        message["text"] in [
          label(%{"locale" => "en"}, :no_share),
          label(%{"locale" => "zh-CN"}, :no_share)
        ]

    if native_response? and is_integer(message["message_id"]) and
         get_in(message, ["chat", "type"]) == "private" and
         text(get_in(message, ["from", "id"])) == text(get_in(message, ["chat", "id"])) do
      Store.get_location_response(
        connect["group_id"],
        connect["connect_id"],
        text(get_in(message, ["chat", "id"])),
        text(message["message_thread_id"]),
        epoch(connect),
        message["message_id"],
        now()
      )
    else
      :unhandled
    end
  end

  defp response_request(_, _, _), do: :unhandled

  # Invoked only after the real OAuth callback persisted its terminal outcome.
  # A check-result button provides safe retry if the callback's enqueue failed.
  def oauth_completed(state) do
    with {:ok, auth} <- AuthState.get(state),
         %{"group_id" => group_id, "id" => request_id} <- auth["telegram_interaction"],
         {:ok, record} <- Store.get(group_id, request_id),
         {:ok, connect} <- active_connect(record["scope"]),
         {:ok, response} <- oauth_response(record) do
      decide_verified(connect, record, response)
    else
      nil -> :ok
      error -> error
    end
  rescue
    _ -> {:error, :completion_delivery_unavailable}
  end

  defp send_prompt(connect, record) do
    scope = record["scope"]

    fields =
      target(scope)
      |> with_reply_target(scope)
      |> Map.merge(%{
        "text" => record["prompt"],
        "reply_markup" => markup(record)
      })

    with {:ok, %{"message_id" => message_id}} when is_integer(message_id) <-
           api(connect, "sendMessage", fields),
         {:ok, saved} <-
           Store.update(
             scope["group_id"],
             record["id"],
             fn current ->
               if current == record,
                 do: current |> Map.put("message_id", message_id) |> Map.put("status", "pending"),
                 else: {:error, :conflict}
             end
           ) do
      delivered_receipt(saved)
    else
      {:ok, _} -> {:error, :invalid_provider_response}
      error -> error
    end
  end

  defp delivered_receipt(record) do
    {:ok,
     %{
       "status" => "question_delivered",
       "request_id" => record["id"],
       "message_id" => record["message_id"],
       "instructions" =>
         "The question is already visible. This activation ends now. Do not send it again or poll; the user's response is a new input."
     }}
  end

  defp respond(connect, request_id, message, from, choice) do
    with {:ok, record} <- Store.get(connect["group_id"], request_id),
         :ok <- validate(connect, record, message, from, message["message_id"]),
         {:ok, response} <- choice_response(record, choice) do
      decide_verified(connect, record, response)
    end
  end

  defp decide(connect, record, message, from, response, prompt_message_id) do
    with :ok <- validate(connect, record, message, from, prompt_message_id),
         do: decide_verified(connect, record, response, message["message_id"])
  end

  defp decide_verified(connect, record, response, response_message_id \\ nil) do
    observe("telegram_interaction_response", fn ->
      persist_response(connect, record, response, response_message_id)
    end)
  end

  defp persist_response(connect, record, response, response_message_id) do
    with {:ok, saved} <-
           Store.update(
             connect["group_id"],
             record["id"],
             fn current ->
               cond do
                 current["connect_epoch"] != epoch(connect) ->
                   {:error, :stale_connection}

                 current["response"] == response ->
                   {:unchanged, current}

                 current["status"] != "pending" ->
                   {:error, :already_decided}

                 current["expires_at"] <= now() ->
                   {:error, :expired}

                 true ->
                   current
                   |> Map.put("response", response)
                   |> Map.put("status", "decided")
                   |> Map.put("response_message_id", response_message_id)
               end
             end
           ) do
      result = deliver(connect, saved)

      # Keep the retry control until Router delivery succeeds. An edit failure
      # cannot undo that delivery; repeating the same choice repairs this exact
      # projection without enqueueing another input or changing the decision.
      if match?({:ok, _}, result), do: complete_card(connect, saved)
      result
    end
  end

  defp complete_card(connect, %{"type" => "location"} = record) do
    # Removing a reply keyboard requires a new message. Claim this send first:
    # an ambiguous HTTP outcome must not produce another acknowledgement.
    with {:ok, false} <- Store.newer_location_prompt?(record),
         {:ok, _} <-
           Store.update(connect["group_id"], record["id"], fn current ->
             if current["keyboard_completion"] == nil,
               do: Map.put(current, "keyboard_completion", "sending"),
               else: {:error, :already_claimed}
           end) do
      result =
        observe("telegram_interaction_card", fn ->
          api(
            connect,
            "sendMessage",
            target(record["scope"])
            |> Map.merge(%{
              "text" =>
                if(record["response"]["status"] == "denied",
                  do: label(record, :cancelled),
                  else: label(record, :received)
                ),
              "reply_markup" => %{"remove_keyboard" => true}
            })
          )
        end)

      Store.update(connect["group_id"], record["id"], fn current ->
        Map.put(
          current,
          "keyboard_completion",
          if(match?({:ok, _}, result), do: "sent", else: "unknown")
        )
      end)
    end
  end

  defp complete_card(_connect, %{"type" => "question", "choices" => []}), do: :ok

  defp complete_card(connect, record) do
    observe("telegram_interaction_card", fn ->
      api(connect, "editMessageText", %{
        "chat_id" => record["scope"]["chat_id"],
        "message_id" => record["message_id"],
        "text" => record["prompt"] <> "\n\n" <> completion_text(record),
        "reply_markup" => %{"inline_keyboard" => []}
      })
    end)
  end

  defp completion_text(%{"type" => "question", "response" => %{"status" => "denied"}} = record),
    do: label(record, :cancelled)

  defp completion_text(%{"response" => %{"status" => "denied"}} = record),
    do: label(record, :denied)

  defp completion_text(%{"response" => %{"status" => "approved"}} = record),
    do: label(record, :approved)

  defp completion_text(%{"response" => %{"status" => "oauth_completed"}} = record),
    do: label(record, :oauth_completed)

  defp completion_text(%{"response" => %{"status" => "oauth_failed"}} = record),
    do: label(record, :oauth_failed)

  defp completion_text(%{"response" => %{"answer" => answer}} = record) do
    # A typed reply can also answer an inline question. Leave room for the
    # original prompt under Telegram's text limit, including astral characters.
    preview = answer |> String.codepoints() |> Enum.take(500) |> Enum.join()
    label(record, :selected) <> preview <> if(preview == answer, do: "", else: "…")
  end

  defp deliver(_connect, %{"status" => "delivered"}), do: {:ok, :duplicate}

  defp deliver(connect, record) do
    scope = record["scope"]

    content =
      Jason.encode!(%{
        "interaction" => record["type"],
        "request_id" => record["id"],
        "original_source_message_id" => scope["source_message_id"],
        "question" => record["prompt"],
        "response" => record["response"],
        "permission_scope" =>
          "This response applies only to this request; it does not grant OS permissions or prove OAuth success."
      })

    metadata =
      ProviderRecipientIdentity.put(
        %{
          "provider" => "telegram",
          "connect_id" => scope["connect_id"],
          "chat_id" => scope["chat_id"],
          "chat_type" => "private",
          "message_thread_id" => scope["message_thread_id"],
          "message_id" => text(record["response_message_id"] || record["message_id"]),
          "from_user_id" => scope["chat_id"],
          "event_id" => "interaction:" <> record["id"]
        },
        connect
      )

    with {:ok, fresh} <- active_connect(scope),
         true <- epoch(fresh) == record["connect_epoch"],
         {:ok, :queued} <-
           ProviderConnects.enqueue_group_router_im_provider_message(
             scope["group_id"],
             content,
             metadata,
             "im_provider:telegram:#{scope["connect_id"]}:interaction:#{record["id"]}",
             trusted_source_text: content
           ),
         {:ok, _} <-
           Store.update(
             scope["group_id"],
             record["id"],
             fn current ->
               if current["response"] == record["response"],
                 do: Map.put(current, "status", "delivered"),
                 else: {:error, :conflict}
             end
           ) do
      {:ok, :queued}
    else
      false -> {:error, :stale_connection}
      error -> error
    end
  end

  defp validate(connect, record, message, from, prompt_message_id) do
    scope = record["scope"]

    with {:ok, fresh} <- active_connect(scope),
         true <- fresh["connect_id"] == connect["connect_id"],
         true <- epoch(fresh) == record["connect_epoch"],
         true <- get_in(message, ["chat", "type"]) == "private",
         true <- text(get_in(message, ["chat", "id"])) == scope["chat_id"],
         true <- text((from || %{})["id"]) == scope["chat_id"],
         true <- text(message["message_thread_id"]) == text(scope["message_thread_id"]),
         true <- prompt_message_id == record["message_id"],
         true <- record["expires_at"] > now() or record["status"] in ["decided", "delivered"] do
      :ok
    else
      _ -> {:error, :invalid_or_expired_interaction}
    end
  end

  def active_connect(scope) do
    with {:ok, group} <- GroupDirectory.get_group(scope["group_id"]),
         true <- group["router_agent_id"] == scope["agent_id"],
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             scope["group_id"],
             scope["connect_id"],
             "telegram"
           ),
         true <-
           TelegramStatusTransport.authorized?(connect, Map.put(scope, "chat_type", "private")) do
      {:ok, connect}
    else
      _ -> {:error, :unauthorized_source}
    end
  end

  defp epoch(connect),
    do: Map.take(connect, ~w(connect_id connected_at managed_peer_id bot_user_id tenant_id))

  defp choice_response(%{"type" => "oauth"} = record, "verify"), do: oauth_response(record)

  defp choice_response(%{"type" => "oauth"} = record, "deny") do
    with {:ok, _} <- AuthState.cancel_pending(record["oauth_state"]),
         do: {:ok, %{"status" => "denied"}}
  end

  defp choice_response(_record, "deny"), do: {:ok, %{"status" => "denied"}}
  defp choice_response(%{"type" => "permission"}, "allow"), do: {:ok, %{"status" => "approved"}}

  defp choice_response(%{"type" => "question", "choices" => choices}, choice) do
    case Integer.parse(choice) do
      {index, ""} when index >= 0 and index < length(choices) ->
        {:ok, %{"status" => "answered", "answer" => Enum.at(choices, index)}}

      _ ->
        {:error, :invalid_choice}
    end
  end

  defp choice_response(_, _), do: {:error, :invalid_choice}

  defp oauth_response(record) do
    with {:ok, auth} <- AuthState.get(record["oauth_state"]),
         true <-
           auth["telegram_interaction"] == %{
             "group_id" => record["scope"]["group_id"],
             "id" => record["id"]
           } do
      case auth["status"] do
        "completed" ->
          {:ok,
           %{
             "status" => "oauth_completed",
             "provider" => auth["provider"],
             "alias" => auth["alias"]
           }}

        status when status in ["failed", "expired"] ->
          {:ok, %{"status" => "oauth_failed"}}

        _ ->
          {:error, :oauth_not_completed}
      end
    else
      _ -> {:error, :oauth_not_completed}
    end
  end

  defp typed_response(%{"type" => "location"}, %{
         "location" => %{"latitude" => lat, "longitude" => lng}
       })
       when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lng) and lng >= -180 and
              lng <= 180,
       do:
         {:ok, %{"status" => "answered", "location" => %{"latitude" => lat, "longitude" => lng}}}

  defp typed_response(%{"type" => "location"}, %{"text" => answer})
       when is_binary(answer) and byte_size(answer) in 1..4096 do
    if answer in [label(%{"locale" => "en"}, :no_share), label(%{"locale" => "zh-CN"}, :no_share)],
      do: {:ok, %{"status" => "denied"}},
      else: {:ok, %{"status" => "answered", "answer" => answer}}
  end

  defp typed_response(_record, %{"text" => answer})
       when is_binary(answer) and byte_size(answer) in 1..4096,
       do: {:ok, %{"status" => "answered", "answer" => answer}}

  defp typed_response(_, _), do: {:error, :invalid_response}

  defp prompt("question", %{"question" => question} = args)
       when is_binary(question) and byte_size(question) in 1..2000 do
    choices = args["choices"] || []

    if is_list(choices) and length(choices) <= 8 and
         Enum.all?(choices, &(is_binary(&1) and byte_size(&1) in 1..100)),
       do: {:ok, question, choices},
       else: {:error, :invalid_choices}
  end

  defp prompt("permission", %{"capability" => capability} = args)
       when is_binary(capability) and byte_size(capability) in 1..200 do
    description = args["description"] || capability

    if is_binary(description) and byte_size(description) <= 2000,
      do: {:ok, label(args, :permission) <> "\n" <> capability <> "\n" <> description, []},
      else: {:error, :invalid_description}
  end

  defp prompt("location", %{"reason" => reason} = args)
       when is_binary(reason) and byte_size(reason) in 1..2000,
       do: {:ok, reason <> "\n" <> label(args, :location), []}

  defp prompt("oauth", %{"reason" => reason, "authorization_url" => url, "oauth_state" => state})
       when is_binary(reason) and byte_size(reason) in 1..2000 and is_binary(url) and
              is_binary(state) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> {:ok, reason, []}
      _ -> {:error, :invalid_authorization_url}
    end
  end

  defp prompt(_, _), do: {:error, :invalid_prompt}

  # Keep explicit replies when supported. Some clients send the keyboard
  # response without reply_to_message; only a unique live location request owns it.
  defp markup(%{"type" => "location"} = record),
    do: %{
      "keyboard" => [
        [%{"text" => label(record, :share), "request_location" => true, "style" => "primary"}],
        [%{"text" => label(record, :no_share)}]
      ],
      "force_reply" => true,
      "input_field_placeholder" => label(record, :location_placeholder),
      "resize_keyboard" => true,
      "one_time_keyboard" => true
    }

  defp markup(%{"type" => "question", "choices" => []} = record),
    do: %{"force_reply" => true, "input_field_placeholder" => label(record, :reply)}

  defp markup(record) do
    buttons =
      case record["type"] do
        "permission" ->
          [Map.put(button(record, label(record, :allow), "allow"), "style", "success")]

        "oauth" ->
          [
            %{
              "text" => label(record, :authorize),
              "url" => record["authorization_url"],
              "style" => "primary"
            },
            button(record, label(record, :verify), "verify")
          ]

        "question" ->
          record["choices"]
          |> Enum.with_index()
          |> Enum.map(fn {label, index} -> button(record, label, to_string(index)) end)
      end

    %{
      "inline_keyboard" =>
        Enum.map(buttons ++ [button(record, label(record, :deny), "deny")], &[&1])
    }
  end

  defp button(record, label, choice),
    do: %{"text" => label, "callback_data" => "ci:" <> record["id"] <> ":" <> choice}

  defp target(scope) do
    base = %{"chat_id" => scope["chat_id"]}

    if scope["message_thread_id"] in [nil, ""],
      do: base,
      else: Map.put(base, "message_thread_id", scope["message_thread_id"])
  end

  defp with_reply_target(fields, scope) do
    case scope["reply_to_message_id"] do
      id when is_binary(id) and id != "" ->
        Map.put(fields, "reply_parameters", %{
          "message_id" => id,
          "allow_sending_without_reply" => true
        })

      _ ->
        fields
    end
  end

  defp timeout(nil), do: {:ok, 600}
  defp timeout(n) when is_integer(n) and n in 1..1800, do: {:ok, n}
  defp timeout(_), do: {:error, :invalid_timeout}
  defp now, do: System.system_time(:second)

  defp observe(operation, fun) do
    started = System.monotonic_time()
    result = fun.()
    emit_observation(operation, result, started)
    result
  end

  defp emit_observation(operation, result, started) do
    outcome =
      case result do
        {:ok, :duplicate} ->
          "already"

        {:ok, _} ->
          "ok"

        {:error, reason}
        when reason in [:expired, :already_decided, :stale_connection, :unauthorized_source] ->
          "rejected"

        _ ->
          "unavailable"
      end

    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{component: "salix_im", operation: operation, surface: "comma", outcome: outcome}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp text(nil), do: ""
  defp text(value), do: to_string(value)
  defp handled({:ok, status}), do: {:handled, {:ok, status}}

  defp handled({:error, reason})
       when reason in [
              :invalid_or_expired_interaction,
              :invalid_choice,
              :invalid_response,
              :expired,
              :already_decided,
              :already_consumed,
              :stale_connection,
              :oauth_not_completed,
              :not_found,
              :ambiguous_location_request
            ],
       do: {:handled, {:ok, :ignored}}

  defp handled({:error, reason}), do: {:handled, {:error, reason}}
  defp handled(_), do: {:handled, {:error, :invalid_interaction}}

  defp answer_callback(connect, callback_id, request_id, result) do
    record =
      case Store.get(connect["group_id"], request_id) do
        {:ok, record} -> record
        _ -> %{"locale" => "en"}
      end

    text =
      case result do
        {:ok, _} -> label(record, :received)
        {:error, :oauth_not_completed} -> label(record, :oauth_pending)
        _ -> label(record, :invalid)
      end

    api(connect, "answerCallbackQuery", %{"callback_query_id" => callback_id, "text" => text})
    :ok
  end

  # The agent selects this from the current dialogue, never the Telegram UI
  # language or character heuristics. Persist it so later callbacks stay in the
  # prompt's language. Old cards were authored in Chinese and retain that copy.
  defp locale(nil), do: {:ok, "en"}
  defp locale(locale) when locale in ["en", "zh-CN"], do: {:ok, locale}
  defp locale(_), do: {:error, :invalid_locale}
  defp label(record, key), do: get_in(@labels, [record["locale"] || "zh-CN", key])

  # Same per-connect Req adapter choice as TelegramStatusTransport. No retries
  # after an ambiguous write, and never expose provider error bodies or tokens.
  defp api(connect, method, body) do
    base = Application.get_env(:salix_im, :telegram_api_base_url, "https://api.telegram.org")

    case Req.post("#{String.trim_trailing(base, "/")}/bot#{connect["bot_token"]}/#{method}",
           json: body,
           retry: false,
           redirect: false,
           receive_timeout: 2_000,
           connect_options: [timeout: 2_000]
         ) do
      {:ok, %{status: status, body: %{"ok" => true, "result" => result}}}
      when status in 200..299 ->
        {:ok, result}

      _ ->
        {:error, :provider_delivery_unconfirmed}
    end
  rescue
    _ -> {:error, :provider_delivery_unconfirmed}
  end
end
