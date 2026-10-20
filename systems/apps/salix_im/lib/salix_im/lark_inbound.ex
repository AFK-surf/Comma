defmodule SalixIM.LarkInbound do
  @moduledoc """
  Lark bot webhook ingress.

  Lark posts one JSON envelope per callback to the request URL of the app's
  event subscription. With an Encrypt Key the envelope is `{"encrypt": ...}`
  and names no app, so the request URL of a connect carries `?app_id=`.

    * `url_verification`: Lark checks the request URL; the answer echoes the
      challenge.
    * `im.message.receive_v1`: a message the bot can see. Every message of a
      private chat is for the bot. A group message is for the bot when it
      mentions the bot, or when it is in a thread the bot answered in
      (`SalixIM.LarkThreads`).
    * `im.message.recalled_v1`: a message was recalled. It is recorded and
      asks nothing of the Router.
    * `card.action.trigger`: a person pressed a button of a card. Only the
      declassification card (`SalixIM.IFC.LarkConfirmation`) has buttons.
      The press settles its request and never reaches the Router; the answer
      to the callback is the card that replaces the question.

  A message for the bot enters the Group's Router Conversation through
  `ProviderConnects.enqueue_group_router_im_provider_message/5`.
  `SalixIM.LarkMessageRecord` records every delivered message for
  `lark.search_messages`, whether or not it is for the bot. Every other event
  is acknowledged and dropped. The chat and the sender of a message for the
  bot are kept for `lark.list_observed_chats` and `lark.list_observed_users`.

  A verified envelope must have the shape Lark documents: an object where
  this module reads an object, and a string where it reads a string. Any
  other shape is `:invalid_envelope`.

  ## Verification

  A callback is accepted after at least one positive check against the
  connect's own material: the `X-Lark-Signature` header verified with the
  Encrypt Key, the envelope decrypted with the Encrypt Key, or the envelope
  token equal to the Verification Token. A connect with neither value refuses
  every callback.

  Lark can deliver one message more than once. A message for the bot has a
  receipt per connect and message ID, and a delivery that finds the receipt
  is answered with the status `duplicate`.

  A message for the Router gets its receipt after the Router took it. Until
  then every delivery is delivered in full, so a delivery that stopped half
  way loses nothing. The source ID
  `im_provider:lark:<connect_id>:<message_id>` is stable across deliveries,
  and the Session takes one source ID once.

  A control command never enters the Session and runs at most once, so its
  receipt is claimed before it starts. A command that reported an error did
  not start and gives the receipt back; a delivery that stopped after its
  claim is not run again.

  ## Diagnostics

  Each callback of a known connect emits one `lark.callback.*` diagnostic
  through `SalixIM.Diagnostics`, and a message for the bot also emits
  `lark.message.*` for each step of its delivery. A diagnostic holds IDs and
  states only, never the text of a message or a secret.
  """

  require Logger

  alias SalixIM.{
    Diagnostics,
    LarkFiles,
    LarkMessageRecord,
    LarkThreads,
    ProviderConnects,
    ProviderObservations,
    ProviderReceipts,
    ProviderRecipientIdentity
  }

  alias SalixIM.IFC.LarkConfirmation
  alias SalixIM.Provider.Lark.Message

  @ack %{"ok" => true}

  @doc """
  Handles one callback for `connect`. Returns the JSON answer Lark expects, or
  an error: `:verification_material_missing`, `:invalid_signature`,
  `:invalid_token`, `:invalid_envelope`, `:ignored`, or a delivery error that
  Lark should retry.
  """
  @spec handle_event(map(), term(), [{String.t(), String.t()}], binary()) ::
          {:ok, map()} | {:error, term()}
  def handle_event(connect, envelope, headers, raw_body) when is_map(connect) do
    request_id = request_id(headers)

    # The diagnostic reads the verified envelope when there is one.
    {outcome, seen} =
      case verify(connect, envelope, headers, raw_body) do
        {:ok, decoded} -> {verified(connect, decoded, request_id), decoded}
        {:error, _reason} = error -> {error, envelope}
      end

    emit_diagnostic(connect, seen, request_id, outcome)
    answer(outcome)
  end

  defp verified(connect, decoded, request_id) do
    with :ok <- validate_shape(decoded) do
      case challenge(decoded) do
        {:ok, challenge} ->
          {:ok, %{"challenge" => challenge}}

        :none ->
          with :ok <- LarkMessageRecord.observe(connect, decoded) do
            dispatch(connect, decoded, request_id)
          end
      end
    end
  end

  # What Lark gets back. An event that asks nothing of the Router is
  # acknowledged like one that was handled, so Lark does not send it again.
  defp answer({:ok, %{} = body}), do: {:ok, body}
  defp answer({:card, %{} = body}), do: {:ok, body}
  defp answer({:ok, status}), do: {:ok, Map.put(@ack, "status", Atom.to_string(status))}
  defp answer({:ignored, _reason}), do: {:ok, @ack}
  defp answer({:error, _reason} = error), do: error

  # ---- verification ----

  defp verify(connect, envelope, headers, raw_body) do
    encrypt_key = text(connect["encrypt_key"])
    token = text(connect["verification_token"])

    if encrypt_key == "" and token == "" do
      {:error, :verification_material_missing}
    else
      signature = signature_status(headers, raw_body, encrypt_key)

      with :ok <- if(signature == :invalid, do: {:error, :invalid_signature}, else: :ok),
           {:ok, decoded, decrypted?} <- decode(envelope, encrypt_key) do
        token_ok? = token != "" and envelope_token(decoded) == token

        if token_ok? or decrypted? or signature == :verified,
          do: {:ok, decoded},
          else: {:error, :invalid_token}
      end
    end
  end

  defp signature_status(headers, raw_body, encrypt_key) do
    signature = header(headers, "x-lark-signature")
    timestamp = header(headers, "x-lark-request-timestamp")
    nonce = header(headers, "x-lark-request-nonce")

    cond do
      # Without the Encrypt Key the header cannot be checked, so it never
      # counts as a positive check.
      signature == "" or encrypt_key == "" ->
        :absent

      timestamp == "" or nonce == "" ->
        :invalid

      true ->
        expected =
          :crypto.hash(:sha256, timestamp <> nonce <> encrypt_key <> to_string(raw_body || ""))
          |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
          do: :verified,
          else: :invalid
    end
  end

  # sha256("") is public: a blank key must never count as decryption.
  defp decode(%{"encrypt" => _encrypted}, ""), do: {:error, :invalid_token}

  defp decode(%{"encrypt" => encrypted}, encrypt_key) when is_binary(encrypted) do
    key = :crypto.hash(:sha256, encrypt_key)

    # base64(iv ++ AES-256-CBC(key, iv, pkcs7(json))), with a random 16-byte iv.
    with {:ok, <<iv::binary-16, cipher::binary>>} <- Base.decode64(encrypted),
         plain = :crypto.crypto_one_time(:aes_256_cbc, key, iv, cipher, false),
         {:ok, json} <- unpad(plain),
         {:ok, %{} = decoded} <- Jason.decode(json) do
      {:ok, decoded, true}
    else
      _invalid -> {:error, :invalid_signature}
    end
  rescue
    _invalid -> {:error, :invalid_signature}
  end

  defp decode(%{"encrypt" => _other}, _encrypt_key), do: {:error, :invalid_signature}
  defp decode(%{} = envelope, _encrypt_key), do: {:ok, envelope, false}
  defp decode(_envelope, _encrypt_key), do: {:error, :invalid_envelope}

  defp unpad(data) when byte_size(data) > 0 do
    pad = :binary.last(data)
    size = byte_size(data)
    if pad in 1..16 and pad <= size, do: {:ok, binary_part(data, 0, size - pad)}, else: :error
  end

  defp unpad(_data), do: :error

  defp envelope_token(decoded), do: text(decoded["token"] || map(decoded["header"])["token"])

  defp header(headers, name) do
    Enum.find_value(List.wrap(headers), "", fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: String.trim(value)

      _other ->
        nil
    end)
  end

  defp challenge(%{"type" => "url_verification"} = envelope), do: present(envelope["challenge"])

  defp challenge(%{"header" => %{"event_type" => "url_verification"}} = envelope),
    do: present(map(envelope["event"])["challenge"])

  defp challenge(_envelope), do: :none

  defp present(value) do
    case text(value) do
      "" -> :none
      value -> {:ok, value}
    end
  end

  # ---- events ----

  defp dispatch(
         connect,
         %{"header" => %{"event_type" => "im.message.receive_v1"}} = envelope,
         request_id
       ) do
    event = map(envelope["event"])
    message = map(event["message"])
    sender = map(event["sender"])
    message_id = text(message["message_id"])

    cond do
      message_id == "" or text(message["chat_id"]) == "" ->
        {:error, :invalid_envelope}

      # The bot's own message never reaches the Router.
      own_message?(connect, sender) ->
        {:ignored, :own_message}

      not for_bot?(connect, message) ->
        {:ignored, :not_for_bot}

      true ->
        deliver = fn ->
          with :ok <- observe_chat_and_sender(connect, message, sender) do
            route(connect, envelope, message, sender, message_id, request_id)
          end
        end

        if command?(connect, message, sender),
          do: at_most_once(connect, message_id, deliver),
          else: until_received(connect, message_id, deliver)
    end
  end

  # A press on a card. It is verified like every callback, and it decides
  # only what the stored request allows: the person who pressed must be the
  # one the request names. A press that decides nothing is acknowledged and
  # leaves the card as it is; there is nothing for Lark to send again.
  defp dispatch(
         connect,
         %{"header" => %{"event_type" => "card.action.trigger"}} = envelope,
         _request_id
       ) do
    cond do
      not card_action_shape?(envelope) ->
        {:error, :invalid_envelope}

      not LarkConfirmation.action?(envelope) ->
        {:ignored, :event_not_routed}

      true ->
        case LarkConfirmation.apply_action(connect, envelope) do
          {:ok, response} -> {:card, response}
          {:error, {:ignored, _reason}} -> {:ignored, :card_action_ignored}
          {:error, _reason} = error -> error
        end
    end
  end

  defp dispatch(_connect, _envelope, _request_id), do: {:ignored, :event_not_routed}

  # The values of a card press this module and `LarkConfirmation` read. Lark
  # sends the `value` of a button as an object, or as its JSON string.
  defp card_action_shape?(envelope) do
    shape?(envelope, ["event", "operator"], :object) and
      shape?(envelope, ["event", "operator", "open_id"], :string) and
      shape?(envelope, ["event", "action"], :object) and
      case fetch(envelope, ["event", "action", "value"]) do
        {:ok, value} -> is_map(value) or is_binary(value)
        :missing -> true
        :invalid -> false
      end
  end

  # Only a message for the bot reaches the Router: one addressed to it, and a
  # group message of a thread the bot answered in.
  defp for_bot?(connect, message) do
    addressed?(connect, message) or
      LarkThreads.joined?(connect, message["chat_id"], message["thread_id"])
  end

  # A control command runs at most once, and nothing but its receipt says
  # that it ran: it never enters the Session. So the receipt is claimed before
  # the command starts, and only one of two deliveries at the same time gets
  # it. A command that reported an error did not start, and gives the receipt
  # back for Lark's retry. A delivery that stopped after its claim is not run
  # again: the command may have started.
  defp at_most_once(connect, message_id, deliver) do
    connect_id = connect["connect_id"]

    case ProviderReceipts.record_lark(connect_id, message_id) do
      {:ok, true} ->
        with {:error, _reason} = error <- deliver.() do
          _ = ProviderReceipts.delete_lark(connect_id, message_id)
          error
        end

      {:ok, false} ->
        {:ok, :duplicate}

      {:error, _reason} = error ->
        error
    end
  end

  # Any other message must reach the Router, so its receipt is written only
  # after the Router took it. A delivery that stopped before that leaves no
  # receipt, and Lark's retry is delivered in full; the Session takes one
  # source ID once, so a message the Router already has is not a second
  # input. The receipt only spares that work for a later delivery.
  defp until_received(connect, message_id, deliver) do
    connect_id = connect["connect_id"]

    if ProviderReceipts.lark_recorded?(connect_id, message_id) do
      {:ok, :duplicate}
    else
      with {:ok, _status} = delivered <- deliver.() do
        _ = ProviderReceipts.record_lark(connect_id, message_id)
        delivered
      end
    end
  end

  # What `route/6` hands on as a command: text of a person who addressed the
  # bot, that `SalixIM.ControlCommand` reads as a command.
  defp command?(connect, message, sender),
    do: SalixIM.ControlCommand.parse(command_text(connect, message, sender)) != :none

  # Only a person who addressed the bot runs a control command. A bot's
  # message holds text that whoever it relays wrote, and a message of a
  # thread the bot answered in is only talk that goes on.
  defp command_text(connect, message, sender) do
    if text(sender["sender_type"]) == "user" and addressed?(connect, message),
      do: message_text(connect, message)
  end

  # Lark names a chat and a person by ID only. The lists show what an event
  # carried; `lark.get_chat` and `lark.get_user` read the names from Lark.
  defp observe_chat_and_sender(connect, message, sender) do
    sender_id = map(sender["sender_id"])

    with :ok <-
           ProviderObservations.upsert_lark_chat(connect, %{
             "chat_id" => text(message["chat_id"]),
             "chat_type" => text(message["chat_type"]),
             "name" => text(message["chat_id"])
           }) do
      ProviderObservations.upsert_lark_user(connect, %{
        "open_id" => text(sender_id["open_id"]),
        "union_id" => text(sender_id["union_id"]),
        "user_id" => text(sender_id["user_id"]),
        "name" => text(sender["sender_type"])
      })
    end
  end

  # Any message of a private chat, and a group message that mentions the bot.
  defp addressed?(connect, message),
    do: text(message["chat_type"]) == "p2p" or mentions_bot?(connect, message)

  defp own_message?(connect, sender) do
    ids = map(sender["sender_id"])
    id = [text(ids["open_id"]), text(ids["app_id"])] |> Enum.find("", &(&1 != ""))

    text(sender["sender_type"]) == "app" and id != "" and
      id in [text(connect["bot_open_id"]), text(connect["app_id"])]
  end

  defp mentions_bot?(connect, message) do
    bot = text(connect["bot_open_id"])
    bot != "" and Enum.any?(mentions(message), &(text(map(&1["id"])["open_id"]) == bot))
  end

  defp mentions(message), do: message["mentions"] |> List.wrap() |> Enum.filter(&is_map/1)

  defp route(connect, envelope, message, sender, message_id, request_id) do
    body = message_text(connect, message)
    sender_id = map(sender["sender_id"])
    source_id = source_id(connect, message_id)
    lifecycle = &emit_diagnostic(connect, envelope, request_id, {:lifecycle, &1, source_id})

    lifecycle.(:received)

    metadata =
      %{
        "provider" => "lark",
        "connect_id" => connect["connect_id"],
        "app_name" => text(connect["app_name"]),
        "tenant_key" => text(map(envelope["header"])["tenant_key"]),
        "chat_id" => text(message["chat_id"]),
        "chat_type" => text(message["chat_type"]),
        "message_id" => message_id,
        "message_thread_id" => text(message["thread_id"]),
        "message_root_id" => text(message["root_id"]),
        # The name a Task card and a runtime delivery read the root by.
        "root_message_id" => text(message["root_id"]),
        "message_parent_id" => text(message["parent_id"]),
        "message_type" => text(message["message_type"]),
        "source_sent_at_ms" => sent_at_ms(message["create_time"]),
        "sender_open_id" => text(sender_id["open_id"]),
        "sender_union_id" => text(sender_id["union_id"]),
        "sender_user_id" => text(sender_id["user_id"]),
        "sender_type" => text(sender["sender_type"]),
        "bot_mentioned" => mentions_bot?(connect, message),
        "structured_mentions" => structured_mentions(connect, message),
        "event_type" => "lark.message",
        "source_actor_type" => "provider_user"
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()
      |> ProviderRecipientIdentity.put(connect)

    name =
      [sender_id["open_id"], sender_id["user_id"], sender["sender_type"]]
      |> Enum.map(&text/1)
      |> Enum.find("", &(&1 != ""))

    connect["group_id"]
    |> ProviderConnects.enqueue_group_router_im_provider_message(
      "Lark message from #{name} in #{text(message["chat_id"])}:\n" <> body,
      metadata,
      source_id,
      trusted_source_text: body,
      command_text: command_text(connect, message, sender),
      attachments: attachments(connect, message, message_id)
    )
    |> case do
      {:error, reason} = error ->
        lifecycle.({:delivery_failed, reason})

        if permanent?(reason) do
          Logger.warning("lark_inbound_refused", reason: inspect(reason))
          {:error, :ignored}
        else
          error
        end

      # The control command ran. Nothing was staged for the Router, so this is
      # not `delivered`.
      {:ok, :command} ->
        lifecycle.(:command)
        {:ok, :command}

      _admitted ->
        lifecycle.(:delivered)
        {:ok, :queued}
    end
  end

  defp source_id(connect, message_id),
    do: "im_provider:lark:#{connect["connect_id"]}:#{message_id}"

  defp permanent?(reason) when reason in [:not_found, :duplicate, :already_delivered], do: true
  defp permanent?({:bad_request, _message}), do: true
  defp permanent?(_reason), do: false

  defp message_text(connect, message) do
    bot = text(connect["bot_open_id"])

    # Lark writes a mention as a key (`@_user_1`). The bot's own mention is
    # not part of the request; any other reads as `@name`.
    body =
      message
      |> mentions()
      |> Enum.reject(&(text(&1["key"]) == ""))
      |> Enum.reduce(Message.text(message), fn mention, acc ->
        if bot != "" and text(map(mention["id"])["open_id"]) == bot,
          do: String.replace(acc, text(mention["key"]), ""),
          else: String.replace(acc, text(mention["key"]), "@" <> text(mention["name"]))
      end)
      |> String.trim()

    cond do
      body != "" -> body
      Message.attachments(message) != [] -> "[Lark message with attachment]"
      true -> "[non-text Lark message]"
    end
  end

  defp structured_mentions(connect, message) do
    bot = text(connect["bot_open_id"])

    message
    |> mentions()
    |> Enum.map(fn mention ->
      ids = map(mention["id"])

      %{
        "open_id" => text(ids["open_id"]),
        "user_id" => text(ids["user_id"]),
        "union_id" => text(ids["union_id"]),
        "name" => text(mention["name"]),
        "key" => text(mention["key"])
      }
    end)
    |> Enum.reject(&(&1["open_id"] in ["", bot]))
    |> Enum.uniq_by(& &1["open_id"])
  end

  defp attachments(connect, message, message_id) do
    chat_id = text(message["chat_id"])

    message
    |> Message.attachments()
    |> Enum.map(fn attachment ->
      %{
        "provider" => "lark",
        "path" => LarkFiles.inbound_path(chat_id, message_id, attachment),
        "file_name" => attachment["file_name"],
        "mime" => attachment["mime_type"],
        "size" => nil,
        "to_blob" => fn agent_id ->
          with {:ok, resource} <-
                 LarkFiles.stream_to_blob(
                   agent_id,
                   connect,
                   message_id,
                   attachment["file_key"],
                   attachment["resource_type"]
                 ) do
            # Lark names the file and its type only when it serves the bytes.
            resolved =
              attachment
              |> Map.put("mime_type", resource.mime_type)
              |> Map.put(
                "file_name",
                Enum.find([resource.file_name, attachment["file_name"]], &(text(&1) != ""))
              )

            {:ok,
             resource
             |> Map.put(:path, LarkFiles.inbound_path(chat_id, message_id, resolved))
             |> Map.put(:file_name, resolved["file_name"])}
          end
        end
      }
    end)
  end

  # ---- envelope shape ----

  # A caller chose the type of every value of the envelope. These are the
  # objects and the strings this module reads; an envelope with another type
  # at one of them is refused before anything reads it. The content of a
  # message is not checked here: it is a JSON document with a shape per
  # message type, and `SalixIM.Provider.Lark.Message` accepts any shape.
  @shape_objects [
    ["header"],
    ["event"],
    ["event", "sender"],
    ["event", "sender", "sender_id"],
    ["event", "message"]
  ]

  @shape_strings [
    ["type"],
    ["token"],
    ["challenge"],
    ["header", "app_id"],
    ["header", "token"],
    ["header", "event_type"],
    ["header", "event_id"],
    ["header", "tenant_key"],
    ["event", "challenge"],
    ["event", "message_id"],
    ["event", "chat_id"],
    ["event", "sender", "sender_type"],
    ["event", "sender", "sender_id", "open_id"],
    ["event", "sender", "sender_id", "app_id"],
    ["event", "sender", "sender_id", "union_id"],
    ["event", "sender", "sender_id", "user_id"],
    ["event", "message", "message_id"],
    ["event", "message", "chat_id"],
    ["event", "message", "chat_type"],
    ["event", "message", "thread_id"],
    ["event", "message", "root_id"],
    ["event", "message", "parent_id"],
    ["event", "message", "message_type"]
  ]

  @mention_strings [
    ["key"],
    ["name"],
    ["tenant_key"],
    ["id", "open_id"],
    ["id", "user_id"],
    ["id", "union_id"]
  ]

  defp validate_shape(envelope) do
    with true <- Enum.all?(@shape_objects, &shape?(envelope, &1, :object)),
         true <- Enum.all?(@shape_strings, &shape?(envelope, &1, :string)),
         true <- mentions_shape?(envelope) do
      :ok
    else
      false -> {:error, :invalid_envelope}
    end
  end

  defp mentions_shape?(envelope) do
    case fetch(envelope, ["event", "message", "mentions"]) do
      :missing ->
        true

      {:ok, mentions} when is_list(mentions) ->
        Enum.all?(mentions, fn mention ->
          is_map(mention) and shape?(mention, ["id"], :object) and
            Enum.all?(@mention_strings, &shape?(mention, &1, :string))
        end)

      _invalid ->
        false
    end
  end

  # A value that is absent or null has a valid shape: it reads as blank.
  defp shape?(envelope, path, kind) do
    case fetch(envelope, path) do
      :missing -> true
      {:ok, value} when kind == :object -> is_map(value)
      {:ok, value} when kind == :string -> is_binary(value)
      :invalid -> false
    end
  end

  defp fetch(value, []), do: {:ok, value}

  defp fetch(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      :error -> :missing
      {:ok, nil} -> :missing
      {:ok, value} -> fetch(value, rest)
    end
  end

  defp fetch(_value, _path), do: :invalid

  # ---- diagnostics ----

  # A diagnostic is an observation. It is built from a caller's JSON, also
  # for a callback that failed verification, and it must never change the
  # answer to Lark.
  defp emit_diagnostic(connect, envelope, request_id, outcome) do
    connect
    |> diagnostic(envelope, request_id, outcome)
    |> Diagnostics.emit()
  rescue
    exception ->
      Logger.warning("lark_inbound_diagnostic_failed", reason: inspect(exception.__struct__))
      :ok
  end

  defp diagnostic(connect, envelope, request_id, outcome) do
    {status, severity, reason_class, event_type, summary} = diagnostic_outcome(outcome)
    message_id = safe(envelope, ["event", "message", "message_id"])

    %{
      provider: "lark",
      source: "salix.im",
      domain:
        if(String.starts_with?(event_type, "lark.message."),
          do: "conversation",
          else: "integration"
        ),
      event_type: event_type,
      severity: severity,
      status: status,
      reason_class: reason_class,
      summary: summary,
      tenant_id: text(connect["tenant_id"]),
      group_id: text(connect["group_id"]),
      connect_id: text(connect["connect_id"]),
      app_id: text(connect["app_id"]),
      provider_event_type:
        first_present([safe(envelope, ["header", "event_type"]), safe(envelope, ["type"])]),
      provider_event_id: safe(envelope, ["header", "event_id"]),
      request_id: request_id,
      message_id: message_id,
      source_message_id: if(message_id != "", do: source_id(connect, message_id)),
      chat_id: safe(envelope, ["event", "message", "chat_id"]),
      chat_type: safe(envelope, ["event", "message", "chat_type"]),
      thread_id: safe(envelope, ["event", "message", "thread_id"]),
      callback_mode: callback_mode(envelope),
      delivery_state: status
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp diagnostic_outcome({:ok, %{"challenge" => _challenge}}),
    do:
      {"ok", "info", "url_verification", "lark.callback.challenge_verified",
       "Lark callback challenge verified"}

  defp diagnostic_outcome({:ok, :queued}),
    do: {"queued", "info", nil, "lark.callback.queued", "Lark callback queued"}

  defp diagnostic_outcome({:ok, :command}),
    do: {"command", "info", nil, "lark.callback.command", "Lark control command handled"}

  defp diagnostic_outcome({:card, _response}),
    do: {"decided", "info", nil, "lark.callback.card_action", "Lark card action decided"}

  defp diagnostic_outcome({:ok, :duplicate}),
    do:
      {"duplicate", "info", "duplicate_event", "lark.callback.duplicate",
       "Lark callback duplicate ignored"}

  # An event that is not for the bot is expected, so it is no warning.
  defp diagnostic_outcome({:ignored, reason}),
    do:
      {"ignored", "info", Atom.to_string(reason), "lark.callback.ignored",
       "Lark callback ignored"}

  defp diagnostic_outcome({:error, :ignored}),
    do: {"ignored", "warning", "ignored", "lark.callback.ignored", "Lark callback ignored"}

  defp diagnostic_outcome({:error, reason})
       when reason in [:invalid_signature, :invalid_token, :invalid_envelope],
       do:
         {"rejected", "warning", Atom.to_string(reason), "lark.callback.rejected",
          "Lark callback rejected"}

  defp diagnostic_outcome({:lifecycle, :received, _source_id}),
    do: {"received", "info", nil, "lark.message.received", "Lark message received"}

  defp diagnostic_outcome({:lifecycle, :delivered, _source_id}),
    do: {"delivered", "info", nil, "lark.message.delivered", "Lark message delivered"}

  defp diagnostic_outcome({:lifecycle, :command, _source_id}),
    do: {"command", "info", nil, "lark.message.command", "Lark control command handled"}

  defp diagnostic_outcome({:lifecycle, {:delivery_failed, reason}, _source_id}),
    do:
      {"delivery_failed", "error", reason_class(reason), "lark.message.delivery_failed",
       "Lark message delivery failed"}

  defp diagnostic_outcome({:error, reason}),
    do: {"failed", "error", reason_class(reason), "lark.callback.failed", "Lark callback failed"}

  # The name of a failure, never its detail: a reason can hold text that a
  # person or a provider wrote.
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "error"

  defp callback_mode(%{"encrypt" => encrypted}) when is_binary(encrypted), do: "encrypted"

  defp callback_mode(envelope) do
    if safe(envelope, ["type"]) == "url_verification" or
         safe(envelope, ["header", "event_type"]) == "url_verification",
       do: "challenge",
       else: "message"
  end

  defp request_id(headers),
    do: first_present([header(headers, "x-request-id"), header(headers, "x-correlation-id")])

  # A string of the envelope, or "" for any other value at `path`.
  defp safe(envelope, path) do
    case fetch(envelope, path) do
      {:ok, value} -> text(value)
      _missing_or_invalid -> ""
    end
  end

  defp first_present(values), do: Enum.find(values, "", &(&1 != ""))

  defp sent_at_ms(value) when is_integer(value), do: value

  defp sent_at_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ms, ""} -> ms
      _invalid -> nil
    end
  end

  defp sent_at_ms(_value), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
