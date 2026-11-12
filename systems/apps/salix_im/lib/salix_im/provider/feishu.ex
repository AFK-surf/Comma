defmodule SalixIM.Provider.Feishu do
  @moduledoc false

  require Logger

  import SalixIM.Provider.Util

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.MessageRenderer.Input

  alias SalixIM.Provider.Feishu.{
    API,
    Directory,
    Docs,
    Meetings,
    Message,
    MessageRenderer,
    MessageSearch,
    Minutes,
    ResourceRef,
    Tables
  }

  alias SalixIM.Provider.{DocAccess, OperationRegistry}
  alias SalixIM.{Diagnostics, FeishuFiles, ProviderConnects, ProviderObservations}

  @max_page_size 50
  @chat_search_types ~w(private external public_joined public_not_joined)
  @direct_id_types ~w(open_id user_id union_id email)
  @max_reaction_pages 10
  @max_image_upload_bytes 10 * 1024 * 1024
  @max_file_upload_bytes 30 * 1024 * 1024
  @minutes_apis OperationRegistry.feishu_minutes_api_names()
  @meeting_apis OperationRegistry.feishu_meeting_api_names()
  @account_apis OperationRegistry.feishu_account_api_names()
  # Feishu takes these only from a person, so `account` names who.
  @person_apis ~w(feishu.request_doc_access)
  @table_apis OperationRegistry.feishu_table_api_names()
  @document_apis OperationRegistry.worker_api_names("feishu") --
                   (@minutes_apis ++ @meeting_apis ++ @table_apis)

  @doc """
  Post one runtime-owned interactive card into a person's own direct
  conversation with the bot.

  Not reachable from any model: it is not in the provider operation table, it
  takes a rendered card rather than model text, and the destination is an open
  id the runtime resolved. `SalixIM.IFC.FeishuConfirmation` is its only caller
  — a declassification is a question the runtime asks a person, so it has to
  arrive somewhere only that person can see and act on.
  """
  @spec post_direct_card(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post_direct_card(connect, open_id, card) when is_binary(open_id) and is_map(card) do
    with :ok <- ensure_connected(connect) do
      API.post(connect, "/im/v1/messages?receive_id_type=open_id", %{
        "receive_id" => open_id,
        "msg_type" => "interactive",
        "content" => Jason.encode!(card)
      })
    end
  end

  @doc """
  Reply with one runtime-rendered interactive card under an exact message.

  Like `post_direct_card/3`, this is not in the provider operation table. Its
  only caller is `SalixIM.FeishuTaskCard`, which derives `uuid` from the card
  identity so a replay inside Feishu's one-hour deduplication window cannot
  post a second card. A card reply does not record thread participation.
  """
  @spec reply_card(map(), String.t(), map(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def reply_card(connect, message_id, card, uuid, reply_in_thread?)
      when is_binary(message_id) and is_map(card) and is_binary(uuid) do
    with :ok <- ensure_connected(connect) do
      API.post(connect, "/im/v1/messages/#{segment(message_id)}/reply", %{
        "msg_type" => "interactive",
        "content" => Jason.encode!(card),
        "reply_in_thread" => reply_in_thread?,
        "uuid" => uuid
      })
    end
  end

  @doc """
  The chat that holds one exact message. A runtime-owned card verifies its
  reply address with this read before the first post.
  """
  @spec message_chat_id(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def message_chat_id(connect, message_id) do
    with :ok <- ensure_connected(connect),
         {:ok, message} <- raw_message(connect, message_id) do
      case str(message["chat_id"]) do
        "" -> {:error, "Feishu get-message response did not contain a chat_id"}
        chat_id -> {:ok, chat_id}
      end
    end
  end

  @doc "Replace the content of one interactive card that this app sent."
  @spec update_card(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_card(connect, message_id, card) when is_binary(message_id) and is_map(card) do
    with :ok <- ensure_connected(connect) do
      API.patch(connect, "/im/v1/messages/#{segment(message_id)}", %{
        "content" => Jason.encode!(card)
      })
    end
  end

  @doc """
  Who one person of this app's tenant is, for a person to recognise the
  account: `"name"`, `"email"` and `"workspace"` (the tenant's name). A read
  the app has no scope for leaves its field out, so this never fails. The
  app's `open_id` means nothing to another app.
  """
  @spec account(map(), String.t()) :: map()
  def account(connect, open_id) when is_binary(open_id) do
    user =
      case call(nil, connect, "feishu.get_user", %{"user_id" => open_id}) do
        {:ok, %{"user" => %{} = user}} -> user
        _other -> %{}
      end

    workspace =
      case API.get(connect, "/tenant/v2/tenant/query") do
        {:ok, %{"tenant" => %{"name" => name}}} -> name
        _other -> nil
      end

    %{
      "name" => user["name"],
      "email" => Enum.find([user["email"], user["enterprise_email"]], &(&1 not in [nil, ""])),
      "workspace" => workspace
    }
  end

  def call(agent_id, connect, api, params, scope \\ %{}) do
    params =
      params
      |> Kernel.||(%{})
      |> string_keys()
      |> Map.put("__tool_call_id", scope[:tool_call_id])

    with :ok <- ensure_connected(connect),
         {:ok, acting} <- acting_connect(agent_id, connect, api, params) do
      agent_id
      |> do_call(acting, api, params)
      |> DocAccess.next_step(api, acting)
    end
  end

  # A document, table or Minutes read, a document content write, or an
  # access request that names a signed-in account runs as that person. A
  # meeting operation reads `account` itself. Every other operation runs as
  # the bot and refuses an account rather than ignore it.
  defp acting_connect(agent_id, connect, api, %{"account" => account})
       when is_binary(account) do
    case String.trim(account) do
      "" ->
        {:ok, connect}

      account when api in @account_apis or api in @person_apis ->
        Meetings.as_account(agent_id, connect, account)

      _account when api in @meeting_apis ->
        {:ok, connect}

      "app" ->
        {:ok, connect}

      _account ->
        {:error, "#{api} runs as the app only; it takes no account"}
    end
  end

  defp acting_connect(_agent_id, connect, _api, _params), do: {:ok, connect}

  # ---- cloud documents, tables and Minutes ----

  defp do_call(agent_id, connect, api, params) when api in @document_apis,
    do: Docs.call(agent_id, connect, api, params)

  defp do_call(agent_id, connect, api, params) when api in @table_apis,
    do: Tables.call(agent_id, connect, api, params)

  defp do_call(agent_id, connect, api, params) when api in @minutes_apis,
    do: Minutes.call(agent_id, connect, api, params)

  defp do_call(agent_id, connect, api, params) when api in @meeting_apis,
    do: Meetings.call(agent_id, connect, api, params)

  # ---- messages and media ----

  defp do_call(_agent_id, connect, api, params)
       when api in ["feishu.send_text", "feishu.reply_text"] do
    result =
      if api == "feishu.reply_text" do
        with :ok <- require_param(params, "message_id"),
             {:ok, rendered} <- outbound_content(params),
             body <-
               rendered
               |> Map.put("reply_in_thread", reply_in_thread?(params))
               |> maybe_put("uuid", message_uuid(api, params)),
             :ok <- MessageRenderer.validate_request(body),
             {:ok, response} <-
               API.post(connect, "/im/v1/messages/#{segment(params["message_id"])}/reply", body),
             :ok <- maybe_record_thread_participation(connect, params, response) do
          {:ok, response}
        end
      else
        with :ok <- require_param(params, "receive_id"),
             {:ok, rendered} <- outbound_content(params),
             body <-
               rendered
               |> Map.put("receive_id", str(params["receive_id"]))
               |> maybe_put("uuid", message_uuid(api, params)),
             :ok <- MessageRenderer.validate_request(body) do
          API.post(
            connect,
            "/im/v1/messages?receive_id_type=#{segment(receive_id_type(params))}",
            body
          )
        end
      end

    emit_outbound_diagnostic(connect, api, params, result)
    without_body(result)
  end

  defp do_call(agent_id, connect, api, params)
       when api in ["feishu.send_image", "feishu.send_file", "feishu.reply_file"] do
    media_api = if api == "feishu.reply_file", do: "feishu.send_file", else: api

    with :ok <- require_media_target(api, params),
         :ok <- require_param(params, "path"),
         {:ok, upload} <-
           read_agent_upload_stream(agent_id, params["path"], params["blob_ref"]),
         :ok <- validate_upload_size(media_api, upload.size),
         {:ok, media_key} <-
           upload_media(connect, media_api, upload.filename, upload.stream, upload.size) do
      msg_type = if media_api == "feishu.send_image", do: "image", else: "file"
      content_key = if media_api == "feishu.send_image", do: "image_key", else: "file_key"

      body =
        %{
          "msg_type" => msg_type,
          "content" => Jason.encode!(%{content_key => media_key})
        }
        |> maybe_put("uuid", message_uuid(api, params))

      if api == "feishu.reply_file" do
        API.post(
          connect,
          "/im/v1/messages/#{segment(params["message_id"])}/reply",
          Map.put(body, "reply_in_thread", reply_in_thread?(params))
        )
      else
        API.post(
          connect,
          "/im/v1/messages?receive_id_type=#{segment(receive_id_type(params))}",
          Map.put(body, "receive_id", str(params["receive_id"]))
        )
      end
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  # The send of `lark.send_message`: Markdown, and optionally one file, to a
  # chat (the source chat by default) or to one person. A reply names a
  # message of that chat, so what the bot writes reaches the people of
  # `chat_id` and nobody else.
  defp do_call(agent_id, connect, "feishu.send_message", params) do
    result =
      with {:ok, {_id_type, receive_id} = target} <- send_target(connect, params),
           {:ok, upload} <- send_upload_stream(agent_id, params),
           :ok <- ensure_content(params, upload),
           :ok <- ensure_reply_in_chat(connect, receive_id, params) do
        with {:ok, sent} <- send_message_text(connect, target, params),
             {:ok, file} <- send_message_upload(connect, target, params, upload) do
          {:ok,
           target
           |> sent_to(sent || file)
           |> maybe_put("message", strip_body(sent))
           |> maybe_put("file_message", strip_body(file))}
        end
      else
        {:error, reason} -> {:error, control_error(reason)}
      end

    emit_outbound_diagnostic(connect, "feishu.send_message", params, result)
    result
  end

  # Feishu copies the message on its side, so a file of any size goes as it
  # is, without a download and an upload here. The forward names its target
  # always: the current chat is not a default.
  defp do_call(_agent_id, connect, "feishu.forward_message", params) do
    result =
      with :ok <- require_param(params, "message_id"),
           :ok <- require_forward_target(params),
           {:ok, {id_type, receive_id} = target} <- send_target(connect, params) do
        query =
          URI.encode_query(
            maybe_put(
              %{"receive_id_type" => id_type},
              "uuid",
              message_uuid("feishu.forward_message", Map.put(params, "receive_id", receive_id))
            )
          )

        with {:ok, sent} <-
               API.post(
                 connect,
                 "/im/v1/messages/#{segment(params["message_id"])}/forward?#{query}",
                 %{"receive_id" => receive_id}
               ) do
          {:ok, target |> sent_to(sent) |> Map.put("message", strip_body(sent))}
        end
      else
        {:error, reason} -> {:error, control_error(reason)}
      end

    emit_outbound_diagnostic(connect, "feishu.forward_message", params, result)
    result
  end

  defp do_call(_agent_id, connect, "feishu.get_chat_history", params),
    do: labelled_messages(connect, "chat", params["chat_id"], params)

  defp do_call(_agent_id, connect, "feishu.get_thread_replies", params),
    do: labelled_messages(connect, "thread", params["thread_id"], params)

  defp do_call(_agent_id, connect, "feishu.search_messages", params) do
    with {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      MessageSearch.search(connect, params, &normalize_message(connect, signing_key, &1))
    end
  end

  # A merged forward (msg_type merge_forward) holds the messages it carries:
  # Feishu answers with the forward and then each of them, naming its parent
  # in upper_message_id.
  defp do_call(_agent_id, connect, "feishu.get_message", params) do
    with {:ok, [message | carried]} <- raw_message_items(connect, params["message_id"]),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      normalized = normalize_message(connect, signing_key, message)

      forwarded =
        for %{"upper_message_id" => upper} = item <- carried,
            str(upper) != "",
            do:
              connect
              |> normalize_message(signing_key, item)
              |> Map.put("upper_message_id", str(upper))

      {:ok,
       put_ifc(
         maybe_put(
           %{"message" => normalized},
           "forwarded_messages",
           if(forwarded != [], do: forwarded)
         ),
         ReadLabels.for_scope(connect, normalized["chat_id"])
       )}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_chat_files", params) do
    with {:ok, page} <- list_messages(connect, "chat", params["chat_id"], params) do
      messages = page["messages"]

      files =
        messages
        |> Enum.flat_map(fn message ->
          Enum.map(message["attachments"], fn attachment ->
            attachment
            |> Map.put("message_id", message["message_id"])
            |> Map.put("thread_id", message["thread_id"])
            |> Map.put("sender", message["sender"])
            |> Map.put("create_time", message["create_time"])
          end)
        end)

      {:ok,
       put_ifc(
         %{
           "files" => files,
           "messages_scanned" => length(messages),
           "has_more" => page["has_more"],
           "next_page_token" => page["next_page_token"]
         },
         # Every file here was attached to a message of the one chat that was
         # scanned, and the list is of files rather than messages, so it carries
         # that chat's audience whole rather than a per-item index.
         ReadLabels.for_scope(connect, params["chat_id"])
       )}
    end
  end

  defp do_call(agent_id, connect, "feishu.fetch_message_resource", params) do
    with {:ok, locator} <- resource_locator(connect, params),
         {:ok, message} <- raw_message(connect, locator["message_id"]),
         {:ok, attachment} <-
           find_attachment(message, locator["file_key"], locator["resource_type"]),
         attachment <- maybe_override_file_name(attachment, params["file_name"]),
         {:ok, staged} <-
           FeishuFiles.stage(
             agent_id,
             connect,
             locator["message_id"],
             locator["file_key"],
             locator["resource_type"],
             attachment
           ),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      {:ok,
       staged
       |> Map.merge(locator)
       |> put_resource_ref(connect, signing_key, locator)
       # The bytes belong to the chat the message was posted in, not to
       # whoever asked for them.
       |> put_ifc(ReadLabels.for_scope(connect, message["chat_id"]))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.update_message", params) do
    with {:ok, body} <- outbound_content(Map.take(params, ["text", "format"])),
         :ok <- MessageRenderer.validate_request(body),
         :ok <- ensure_bot_authored(connect, params["message_id"]) do
      connect
      |> API.put("/im/v1/messages/#{segment(params["message_id"])}", body)
      |> without_body()
    end
  end

  defp do_call(_agent_id, connect, "feishu.delete_message", params) do
    with :ok <- ensure_bot_authored(connect, params["message_id"]) do
      API.delete(connect, "/im/v1/messages/#{segment(params["message_id"])}")
    end
  end

  # ---- reactions and pins ----

  defp do_call(_agent_id, connect, "feishu.add_reaction", params) do
    with :ok <- require_param(params, "message_id"),
         :ok <- require_param(params, "emoji_type") do
      API.post(connect, "/im/v1/messages/#{segment(params["message_id"])}/reactions", %{
        "reaction_type" => %{"emoji_type" => str(params["emoji_type"])}
      })
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_reactions", params) do
    with :ok <- require_param(params, "message_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(
             connect,
             "/im/v1/messages/#{segment(params["message_id"])}/reactions",
             %{
               page_size: page_size(params),
               page_token: page_token,
               reaction_type: params["emoji_type"]
             }
           ),
         {:ok, result} <- paged_result(data, "reactions", page_token) do
      {:ok, result}
    end
  end

  defp do_call(_agent_id, connect, "feishu.remove_reaction", params) do
    with :ok <- require_param(params, "message_id"),
         :ok <- require_param(params, "reaction_id"),
         :ok <- ensure_bot_reaction(connect, params["message_id"], params["reaction_id"]) do
      API.delete(
        connect,
        "/im/v1/messages/#{segment(params["message_id"])}/reactions/#{segment(params["reaction_id"])}"
      )
    end
  end

  defp do_call(_agent_id, connect, "feishu.pin_message", params) do
    with :ok <- require_param(params, "message_id") do
      API.post(connect, "/im/v1/pins", %{"message_id" => str(params["message_id"])})
    end
  end

  defp do_call(_agent_id, connect, "feishu.unpin_message", params) do
    with :ok <- require_param(params, "message_id") do
      API.delete(connect, "/im/v1/pins/#{segment(params["message_id"])}")
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_pins", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/im/v1/pins", %{
             chat_id: params["chat_id"],
             start_time: params["start_time"],
             end_time: params["end_time"],
             page_size: page_size(params),
             page_token: page_token
           }),
         {:ok, result} <- paged_result(data, "pins", page_token) do
      {:ok, result}
    end
  end

  # ---- chat and user discovery ----

  defp do_call(_agent_id, connect, "feishu.list_observed_chats", params) do
    with {:ok, chats} <-
           ProviderObservations.list_feishu_chats(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, put_ifc(%{"chats" => chats}, ReadLabels.for_messages(connect, chats, "chat_id"))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_observed_users", params) do
    with {:ok, users} <-
           ProviderObservations.list_feishu_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, put_ifc(%{"users" => users}, ReadLabels.for_space(connect))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.search_chats", params) do
    with {:ok, page_token} <- page_token(params),
         {:ok, search_types} <- chat_search_types(params),
         query =
           %{"page_size" => page_size(params)}
           |> maybe_put("page_token", page_token)
           |> URI.encode_query(),
         {:ok, data} <-
           API.post_read(
             connect,
             "/im/v2/chats/search?" <> query,
             chat_search_body(params, search_types)
           ),
         {:ok, page} <- paged_result(data, "chats", page_token) do
      chats = Enum.flat_map(page["chats"], &chat_search_item/1)

      {:ok,
       page
       |> Map.put("chats", chats)
       |> maybe_put("total", data["total"])
       |> maybe_put("notice", data["notice"])
       |> put_ifc(ReadLabels.for_messages(connect, chats, "chat_id"))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.join_chat", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, chat_id} <- chat_id(connect, params) do
      API.patch(connect, "/im/v1/chats/#{segment(chat_id)}/members/me_join", %{})
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_chats", params) do
    with {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/im/v1/chats", %{
             page_size: page_size(params),
             page_token: page_token
           }),
         {:ok, result} <- paged_result(data, "chats", page_token) do
      {:ok, put_ifc(result, ReadLabels.for_messages(connect, result["chats"], "chat_id"))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.get_chat", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, chat} <- API.get(connect, "/im/v1/chats/#{segment(params["chat_id"])}") do
      {:ok, put_ifc(chat, ReadLabels.for_scope(connect, params["chat_id"]))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.create_chat", params) do
    with :ok <- require_param(params, "name"),
         {:ok, user_ids} <- chat_user_ids(params) do
      query =
        %{"user_id_type" => "open_id"}
        |> maybe_put("uuid", message_uuid("feishu.create_chat", params))
        |> URI.encode_query()

      API.post(connect, "/im/v1/chats?" <> query, %{
        "name" => str(params["name"]),
        "user_id_list" => user_ids,
        "chat_mode" => "group",
        "chat_type" => "private"
      })
    end
  end

  defp do_call(_agent_id, connect, "feishu.add_chat_members", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, chat_id} <- chat_id(connect, params),
         {:ok, user_ids} <- chat_user_ids(params) do
      # Reject the whole request if any member is unavailable.
      API.post(
        connect,
        "/im/v1/chats/#{segment(chat_id)}/members?member_id_type=open_id&succeed_type=2",
        %{"id_list" => user_ids}
      )
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_chat_members", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/im/v1/chats/#{segment(params["chat_id"])}/members", %{
             member_id_type: "open_id",
             page_size: page_size(params),
             page_token: page_token
           }),
         {:ok, result} <- paged_result(data, "members", page_token) do
      # Who is in a chat is what its members see.
      {:ok, put_ifc(result, ReadLabels.for_scope(connect, params["chat_id"]))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.get_user", params) do
    with :ok <- require_param(params, "user_id"),
         {:ok, user} <-
           API.get(connect, "/contact/v3/users/#{segment(params["user_id"])}", %{
             user_id_type: blank_default(params["user_id_type"], "open_id"),
             department_id_type: "open_department_id"
           }) do
      {:ok, user |> hide_user_mobile() |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_departments", params) do
    department_id = blank_default(params["department_id"], "0")

    with {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(
             connect,
             "/contact/v3/departments/#{segment(department_id)}/children",
             %{
               department_id_type:
                 blank_default(params["department_id_type"], "open_department_id"),
               user_id_type: "open_id",
               fetch_child: false,
               page_size: page_size(params),
               page_token: page_token
             }
           ),
         {:ok, result} <- paged_result(data, "departments", page_token) do
      {:ok, put_ifc(result, ReadLabels.for_space(connect))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_department_users", params) do
    with :ok <- require_param(params, "department_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/contact/v3/users/find_by_department", %{
             department_id: params["department_id"],
             department_id_type:
               blank_default(params["department_id_type"], "open_department_id"),
             user_id_type: blank_default(params["user_id_type"], "open_id"),
             page_size: page_size(params),
             page_token: page_token
           }),
         {:ok, result} <- paged_result(data, "users", page_token) do
      {:ok,
       result
       |> Map.update("users", [], fn users -> Enum.map(users, &hide_mobile/1) end)
       |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_contact_scopes", params) do
    with {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/contact/v3/scopes", %{
             user_id_type: blank_default(params["user_id_type"], "open_id"),
             department_id_type:
               blank_default(params["department_id_type"], "open_department_id"),
             page_size: page_size(params, 100),
             page_token: page_token
           }),
         {:ok, pagination} <- page_metadata(data, page_token) do
      {:ok,
       Map.merge(
         %{
           "department_ids" => List.wrap(data["department_ids"]),
           "user_ids" => List.wrap(data["user_ids"]),
           "group_ids" => List.wrap(data["group_ids"]),
           "guidance" =>
             "These are authorization roots, not a complete directory listing. Expand returned departments deliberately with feishu.list_departments and feishu.list_department_users."
         },
         pagination
       )
       |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  # Bot tenant tokens cannot use Feishu's keyword user-search API: a query
  # reads the people the bot has seen, then walks the app's directory data
  # range (`Directory`).
  defp do_call(_agent_id, connect, "feishu.lookup_users", params) do
    with {:ok, observed} <-
           ProviderObservations.list_feishu_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok,
       connect
       |> Directory.lookup(observed, params["query"], params["limit"])
       |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  # Everyone in the data range, whole departments within one call's request
  # budget, resumed from `continue_from` (`Directory`).
  defp do_call(_agent_id, connect, "feishu.list_directory_users", params) do
    with {:ok, result} <- Directory.list(connect, params["continue_from"]),
         do: {:ok, put_ifc(result, ReadLabels.for_space(connect))}
  end

  defp do_call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Feishu provider api"}

  defp list_messages(connect, container_type, container_id, params) do
    with :ok <- require_value(container_id, "#{container_type}_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/im/v1/messages", %{
             container_id_type: container_type,
             container_id: container_id,
             start_time: if(container_type == "chat", do: params["start_time"]),
             end_time: if(container_type == "chat", do: params["end_time"]),
             sort_type: blank_default(params["sort_type"], "ByCreateTimeDesc"),
             page_size: page_size(params),
             page_token: page_token,
             card_msg_content_type: "raw_card_content",
             with_sender_name: true,
             only_thread_root_messages: if(container_type == "chat", do: true)
           }),
         {:ok, pagination} <- page_metadata(data, page_token),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      page =
        Map.put(
          pagination,
          "messages",
          Enum.map(
            List.wrap(data["items"]),
            &normalize_message(connect, signing_key, &1)
          )
        )

      {:ok, page}
    end
  end

  # A history page and a thread page both come back as messages that name their
  # own chat, so the audience is read off the page rather than off the argument:
  # a thread is addressed by thread id and never says which chat it is in.
  defp labelled_messages(connect, container_type, container_id, params) do
    with {:ok, page} <- read_messages(connect, container_type, container_id, params) do
      {:ok, put_ifc(page, ReadLabels.for_messages(connect, page["messages"], "chat_id"))}
    end
  end

  # Feishu can refuse the history of an external chat while it still delivers
  # the chat's messages to the bot. Those are in the local index.
  defp read_messages(connect, container_type, container_id, params) do
    case list_messages(connect, container_type, container_id, params) do
      {:error, reason} = refused ->
        # A read as a person who is not let in stays that person's refusal.
        if API.external_chat_rejected?(reason) and not is_binary(connect["user_access_token"]),
          do: indexed_messages(connect, container_type, container_id, params, refused),
          else: refused

      page ->
        page
    end
  end

  defp indexed_messages(connect, container_type, container_id, params, refused) do
    with {:ok, signing_key} <- API.resource_ref_signing_key(connect),
         {:ok, page} <-
           MessageSearch.container_page(
             connect,
             container_type,
             container_id,
             params,
             &normalize_message(connect, signing_key, &1)
           ) do
      {:ok, page}
    else
      _unavailable -> refused
    end
  end

  # The block rides out under a reserved key that `SalixAgent.Tools.IMRouter`
  # pops before the result is encoded, so it never reaches the model as content.
  # A person can hide their mobile number in the directory
  # (`mobile_visible: false`); a read does not return a hidden number.
  defp hide_user_mobile(%{"user" => user} = data), do: Map.put(data, "user", hide_mobile(user))
  defp hide_user_mobile(data), do: data

  defp hide_mobile(%{"mobile_visible" => false} = user), do: Map.delete(user, "mobile")
  defp hide_mobile(user), do: user

  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)

  defp raw_message(connect, message_id) do
    with {:ok, [message | _carried]} <- raw_message_items(connect, message_id),
         do: {:ok, message}
  end

  defp raw_message_items(connect, message_id) do
    with :ok <- require_value(message_id, "message_id"),
         {:ok, data} <-
           API.get(connect, "/im/v1/messages/#{segment(message_id)}", %{
             card_msg_content_type: "raw_card_content",
             with_sender_name: true
           }) do
      case data do
        %{"items" => [message | _] = items} when is_map(message) ->
          {:ok, Enum.filter(items, &is_map/1)}

        %{"message_id" => _} = message ->
          {:ok, [message]}

        _ ->
          {:error, "Feishu get-message response did not contain a message"}
      end
    end
  end

  defp find_attachment(message, file_key, resource_type) do
    Message.attachments(message)
    |> Enum.find(fn attachment ->
      attachment["file_key"] == str(file_key) and
        attachment["resource_type"] == resource_type
    end)
    |> case do
      nil -> {:error, "Feishu message does not contain the requested #{resource_type} resource"}
      attachment -> {:ok, attachment}
    end
  end

  defp normalize_message(connect, signing_key, message) do
    message
    |> Message.normalize()
    |> Map.update("attachments", [], fn attachments ->
      Enum.map(attachments, &put_resource_ref(&1, connect, signing_key, message))
    end)
  end

  defp put_resource_ref(attachment, connect, signing_key, source) do
    message_id = str(source["message_id"])
    file_key = str(attachment["file_key"] || source["file_key"])
    resource_type = str(attachment["resource_type"] || source["resource_type"])

    case ResourceRef.encode(
           resource_ref_scope(connect),
           signing_key,
           message_id,
           file_key,
           resource_type
         ) do
      {:ok, resource_ref} -> Map.put(attachment, "resource_ref", resource_ref)
      {:error, _reason} -> attachment
    end
  end

  defp resource_locator(connect, params) do
    case str(params["resource_ref"]) do
      "" ->
        legacy_resource_locator(params)

      resource_ref ->
        with {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
          ResourceRef.decode(resource_ref, resource_ref_scope(connect), signing_key)
        end
    end
  end

  defp resource_ref_scope(connect) do
    Enum.join(
      ["feishu", str(connect["tenant_id"]), str(connect["connect_id"])],
      <<0>>
    )
  end

  # Keep direct provider callers compatible while the Agent-facing operation
  # contract moves to one authenticated reference. The manual and disclosed
  # schema intentionally do not expose this tuple-shaped fallback.
  defp legacy_resource_locator(params) do
    resource_type = str(params["resource_type"])

    with :ok <- require_param(params, "message_id"),
         :ok <- require_param(params, "file_key"),
         :ok <- require_resource_type(resource_type) do
      {:ok,
       %{
         "message_id" => str(params["message_id"]),
         "file_key" => str(params["file_key"]),
         "resource_type" => resource_type
       }}
    end
  end

  defp ensure_bot_authored(connect, message_id) do
    with {:ok, message} <- raw_message(connect, message_id) do
      sender = message["sender"] || %{}
      sender_id = str(sender["id"])
      sender_type = str(sender["sender_type"])

      if sender_type == "app" and sender_id != "" and sender_id in bot_ids(connect) do
        :ok
      else
        {:error, "Feishu message is not authored by this bot"}
      end
    end
  end

  defp ensure_bot_reaction(connect, message_id, reaction_id) do
    with {:ok, reaction} <-
           find_reaction(connect, message_id, str(reaction_id), "", @max_reaction_pages) do
      operator = (reaction || %{})["operator"] || %{}

      operator_id = str(operator["operator_id"])

      if (reaction && str(operator["operator_type"]) == "app") and operator_id != "" and
           operator_id in bot_ids(connect) do
        :ok
      else
        {:error, "Feishu reaction is not authored by this bot"}
      end
    end
  end

  defp find_reaction(_connect, _message_id, _reaction_id, _page_token, 0),
    do: {:error, "Feishu reaction was not found within the bounded 10-page ownership check"}

  defp find_reaction(connect, message_id, reaction_id, page_token, pages_left) do
    with {:ok, data} <-
           API.get(connect, "/im/v1/messages/#{segment(message_id)}/reactions", %{
             page_size: @max_page_size,
             page_token: page_token
           }) do
      case Enum.find(List.wrap(data["items"]), &(&1["reaction_id"] == reaction_id)) do
        %{} = reaction ->
          {:ok, reaction}

        nil ->
          with {:ok, pagination} <- page_metadata(data, page_token) do
            if pagination["has_more"] do
              find_reaction(
                connect,
                message_id,
                reaction_id,
                pagination["next_page_token"],
                pages_left - 1
              )
            else
              {:error, "Feishu reaction is not authored by this bot"}
            end
          end
      end
    end
  end

  defp maybe_record_thread_participation(connect, params, response) do
    thread_id = str(response["thread_id"] || params["thread_id"])
    chat_id = str(response["chat_id"] || params["chat_id"])

    if thread_id == "" or chat_id == "" do
      :ok
    else
      case ProviderConnects.record_feishu_thread_participation(connect, chat_id, thread_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "feishu thread participation marker write failed connect_id=#{connect["connect_id"]} reason=#{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp reply_in_thread?(params) do
    if Map.has_key?(params, "reply_in_thread") do
      truthy?(params["reply_in_thread"])
    else
      str(params["chat_type"]) == "group" and str(params["thread_id"]) == ""
    end
  end

  defp paged_result(data, key, current_page_token) do
    with items when is_list(items) <- data["items"],
         {:ok, pagination} <- page_metadata(data, current_page_token) do
      {:ok, Map.put(pagination, key, items)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Feishu pagination incomplete: response items must be a list"}
    end
  end

  defp page_token(params) do
    case Map.fetch(params, "page_token") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, token} when is_binary(token) ->
        case String.trim(token) do
          "" ->
            {:error,
             "Feishu pagination invalid_page_token: page_token must be a nonblank string when provided"}

          token ->
            {:ok, token}
        end

      {:ok, _token} ->
        {:error,
         "Feishu pagination invalid_page_token: page_token must be a nonblank string when provided"}
    end
  end

  defp page_metadata(data, current_page_token) do
    case Map.fetch(data, "has_more") do
      {:ok, true} ->
        next_page_token = data["page_token"]

        cond do
          not is_binary(next_page_token) ->
            {:error,
             "Feishu pagination incomplete: has_more response returned a non-string page_token"}

          String.trim(next_page_token) == "" ->
            {:error,
             "Feishu pagination incomplete: has_more response returned a blank page_token"}

          String.trim(next_page_token) == current_page_token ->
            {:error,
             "Feishu pagination incomplete: has_more response repeated page_token and did not advance"}

          true ->
            {:ok,
             %{
               "has_more" => true,
               "next_page_token" => String.trim(next_page_token)
             }}
        end

      {:ok, false} ->
        {:ok, %{"has_more" => false, "next_page_token" => ""}}

      _ ->
        {:error, "Feishu pagination incomplete: response has_more must be a boolean"}
    end
  end

  # ---- feishu.send_message and feishu.forward_message ----

  defp send_target(connect, params) do
    case str(params["user_id"]) do
      "" ->
        with {:ok, chat_id} <- chat_id(connect, params), do: {:ok, {"chat_id", chat_id}}

      user_id ->
        id_type = blank_default(params["user_id_type"], "open_id")

        cond do
          str(params["chat_id"]) != "" ->
            {:error, "pass chat_id or user_id, not both"}

          str(params["reply_to"]) != "" ->
            {:error, "reply_to is not allowed with user_id"}

          id_type not in @direct_id_types ->
            {:error, "user_id_type must be open_id, user_id, union_id or email"}

          true ->
            {:ok, {id_type, user_id}}
        end
    end
  end

  defp require_forward_target(params) do
    if str(params["chat_id"]) == "" and str(params["user_id"]) == "",
      do: {:error, "chat_id or user_id is required"},
      else: :ok
  end

  defp chat_search_types(params) do
    case params["search_types"] do
      nil ->
        {:ok, []}

      types when is_list(types) ->
        if Enum.all?(types, &(&1 in @chat_search_types)),
          do: {:ok, Enum.uniq(types)},
          else: {:error, "search_types must be among #{Enum.join(@chat_search_types, ", ")}"}

      _other ->
        {:error, "search_types must be a list"}
    end
  end

  defp chat_search_body(params, search_types) do
    body = maybe_put(%{}, "query", str(params["query"]))

    if search_types == [],
      do: body,
      else: Map.put(body, "filter", %{"search_types" => search_types})
  end

  # The chat itself is in `meta_data`; the rest of an item is the search's
  # highlighted snippet.
  defp chat_search_item(%{"meta_data" => %{} = chat}), do: [chat]
  defp chat_search_item(_item), do: []

  defp chat_id(connect, params) do
    case str(params["chat_id"]) do
      "" ->
        case str(origin_context(connect)["chat_id"]) do
          "" -> {:error, "chat_id is required outside a Feishu source"}
          chat_id -> {:ok, chat_id}
        end

      chat_id ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, chat_id),
          do: {:ok, chat_id},
          else: {:error, "chat_id must be a Feishu chat ID (oc_...)"}
    end
  end

  defp chat_user_ids(%{"user_ids" => ids}) when is_list(ids) and length(ids) in 1..50 do
    if Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/\Aou_[A-Za-z0-9_-]{1,125}\z/, &1))),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, "user_ids must contain Feishu open_ids (ou_...), not names"}
  end

  defp chat_user_ids(_params),
    do: {:error, "user_ids must be a list of 1 to 50 Feishu open_ids"}

  # The chat and message of the Feishu message this turn answers.
  defp origin_context(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "feishu", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context, else: %{}

      _other ->
        %{}
    end
  end

  defp send_upload_stream(agent_id, params) do
    case str(params["path"]) do
      "" ->
        {:ok, nil}

      path ->
        with {:ok, upload} <- read_agent_upload_stream(agent_id, path, params["blob_ref"]),
             api = if(image?(upload.filename), do: "feishu.send_image", else: "feishu.send_file"),
             :ok <- validate_upload_size(api, upload.size) do
          {:ok, Map.put(upload, :api, api)}
        end
    end
  end

  defp image?(filename),
    do: String.downcase(Path.extname(filename)) in ~w(.png .jpg .jpeg .gif .webp .bmp)

  defp ensure_content(params, upload) do
    if str(params["text"]) == "" and is_nil(upload),
      do: {:error, "text or path is required"},
      else: :ok
  end

  # A reply goes wherever the replied message is. The message must be of the
  # chat the send names; the source message of this turn is known to be.
  defp ensure_reply_in_chat(connect, chat_id, params) do
    origin = origin_context(connect)

    case str(params["reply_to"]) do
      "" ->
        :ok

      message_id ->
        if message_id == str(origin["message_id"]) and chat_id == str(origin["chat_id"]) do
          :ok
        else
          with {:ok, message} <- raw_message(connect, message_id) do
            if str(message["chat_id"]) == chat_id,
              do: :ok,
              else: {:error, "reply_to is not a message of this chat"}
          end
        end
    end
  end

  defp send_message_text(connect, {id_type, receive_id} = target, params) do
    if str(params["text"]) == "" do
      {:ok, nil}
    else
      origin = origin_context(connect)
      source_chat? = id_type == "chat_id" and receive_id == str(origin["chat_id"])

      # A question card says where it is: the chat type, and the thread of the
      # source when it answers there.
      card_params =
        params
        |> Map.put(
          "chat_type",
          if(id_type == "chat_id", do: chat_type(connect, receive_id), else: "p2p")
        )
        |> Map.put("thread_id", if(source_chat?, do: str(origin["message_thread_id"]), else: ""))

      with {:ok, rendered} <- outbound_content(card_params),
           body =
             maybe_put(
               rendered,
               "uuid",
               message_uuid("feishu.send_message", uuid_params(target, params))
             ),
           :ok <- MessageRenderer.validate_request(body) do
        post_message(connect, target, params, body)
      end
    end
  end

  defp send_message_upload(_connect, _target, _params, nil), do: {:ok, nil}

  defp send_message_upload(connect, target, params, upload) do
    with {:ok, key} <-
           upload_media(connect, upload.api, upload.filename, upload.stream, upload.size) do
      {msg_type, content_key} =
        if upload.api == "feishu.send_image",
          do: {"image", "image_key"},
          else: {"file", "file_key"}

      body =
        %{"msg_type" => msg_type, "content" => Jason.encode!(%{content_key => key})}
        |> maybe_put(
          "uuid",
          message_uuid("feishu.send_message.file", uuid_params(target, params))
        )

      post_message(connect, target, params, body)
    end
  end

  defp uuid_params({_id_type, receive_id}, params),
    do:
      params
      |> Map.put("receive_id", receive_id)
      |> Map.put("message_id", str(params["reply_to"]))

  defp post_message(connect, {id_type, receive_id}, params, body) do
    case str(params["reply_to"]) do
      "" ->
        API.post(
          connect,
          "/im/v1/messages?receive_id_type=#{id_type}",
          Map.put(body, "receive_id", receive_id)
        )

      # A reply is always of a chat: `send_target/2` refuses it for a person.
      message_id ->
        with {:ok, sent} <-
               API.post(
                 connect,
                 "/im/v1/messages/#{segment(message_id)}/reply",
                 Map.put(
                   body,
                   "reply_in_thread",
                   send_reply_in_thread?(connect, receive_id, params)
                 )
               ),
             :ok <- maybe_record_thread_participation(connect, %{"chat_id" => receive_id}, sent) do
          {:ok, sent}
        end
    end
  end

  # A reply in a group opens a thread under the message, or goes on in its
  # thread, so the people of the group can continue there without mentioning
  # the bot again. A private chat needs no thread: every message of it is for
  # the bot.
  defp send_reply_in_thread?(connect, chat_id, params) do
    if Map.has_key?(params, "reply_in_thread"),
      do: truthy?(params["reply_in_thread"]),
      else: chat_type(connect, chat_id) != "p2p"
  end

  defp chat_type(connect, chat_id) do
    origin = origin_context(connect)
    if chat_id == str(origin["chat_id"]), do: str(origin["chat_type"]), else: "group"
  end

  defp sent_to({"chat_id", chat_id}, _sent), do: %{"chat_id" => chat_id}

  defp sent_to({id_type, user_id}, sent),
    do:
      maybe_put(
        %{"user_id" => user_id, "user_id_type" => id_type},
        "chat_id",
        str((sent || %{})["chat_id"])
      )

  defp strip_body(%{} = message), do: Map.delete(message, "body")
  defp strip_body(message), do: message

  defp upload_media(connect, "feishu.send_image", filename, stream, size),
    do: API.upload_image(connect, filename, stream, size)

  defp upload_media(connect, "feishu.send_file", filename, stream, size),
    do: API.upload_file(connect, filename, stream, size)

  defp read_agent_upload_stream(agent_id, path, blob_ref) do
    path = str(path)

    cond do
      path == "" ->
        {:error, "path is required"}

      str(agent_id) == "" ->
        {:error, "agent_id is required for Feishu file uploads"}

      is_map(blob_ref) ->
        case SalixIM.Ports.AgentWorkspace.read_ref_stream(
               agent_id,
               blob_ref,
               Path.basename(path)
             ) do
          {:ok, stream, size, filename}
          when is_integer(size) and size >= 0 and is_binary(filename) ->
            {:ok, %{stream: stream, size: size, filename: filename}}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, "invalid immutable file ref"}
        end

      true ->
        case SalixIM.Ports.AgentWorkspace.read_stream(agent_id, path) do
          {:ok, stream, size, filename}
          when is_integer(size) and size >= 0 and is_binary(filename) ->
            {:ok,
             %{
               stream: stream,
               size: size,
               filename: blank_default(filename, Path.basename(path))
             }}

          {:error, :not_found} ->
            {:error, "file not found in agent VFS: #{path}"}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, "file not found in agent VFS: #{path}"}
        end
    end
  end

  defp validate_upload_size(_api, 0), do: {:error, "Feishu does not allow empty uploads"}

  defp validate_upload_size("feishu.send_image", size) when size > @max_image_upload_bytes,
    do: {:error, "Feishu image uploads are limited to 10 MB"}

  defp validate_upload_size("feishu.send_file", size) when size > @max_file_upload_bytes,
    do: {:error, "Feishu file uploads are limited to 30 MB"}

  defp validate_upload_size(_api, _size), do: :ok

  defp receive_id_type(params), do: blank_default(params["receive_id_type"], "chat_id")

  defp message_uuid(api, params) do
    case str(params["__tool_call_id"]) do
      "" ->
        nil

      tool_call_id ->
        target =
          first_present([
            str(params["message_id"]),
            str(params["receive_id"]),
            str(params["chat_id"])
          ])

        digest =
          :crypto.hash(:sha256, Enum.join([api, target || "", tool_call_id], "\0"))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 40)

        "bft_" <> digest
    end
  end

  # A source message lists who it mentions as structured_mentions; a send
  # takes mentions. Without this, the misnamed list is ignored and nobody is
  # mentioned.
  defp outbound_content(%{"structured_mentions" => _}),
    do: {:error, "structured_mentions is not a send parameter: pass mentions=[{user_id, name}]"}

  defp outbound_content(%{"question" => question} = params) when not is_nil(question) do
    with {:ok, question} <- SalixIM.QuestionCard.normalize(question),
         {:ok, mentioned} <-
           MessageRenderer.mention_ids(params["mentions"], params["mention_all"]),
         :ok <- require_param(params, "text"),
         {:ok, card} <-
           SalixIM.QuestionCard.feishu_card(
             SalixIM.QuestionCard.with_mentions(str(params["text"]), mentioned),
             question,
             %{
               "chat_type" => card_chat_type(params),
               "thread_id" => str(params["thread_id"])
             }
           ) do
      {:ok, %{"msg_type" => "interactive", "content" => Jason.encode!(card)}}
    end
  end

  defp outbound_content(params) do
    SalixIM.MessageRenderer.render(MessageRenderer, %Input{markdown: params["text"]},
      format: params["format"],
      mentions: params["mentions"],
      mention_all: truthy?(params["mention_all"])
    )
  end

  # Feishu answers a send with the stored message: its body holds both a
  # plain text copy and the Markdown source, and reads like the message shown
  # twice. The chat shows it once; the caller needs only the message's ids.
  defp without_body({:ok, %{} = message}), do: {:ok, Map.delete(message, "body")}
  defp without_body(result), do: result

  # A send to a person is a private chat; a reply says its chat type.
  defp card_chat_type(%{"receive_id" => _} = params) do
    if receive_id_type(params) == "chat_id", do: "", else: "p2p"
  end

  defp card_chat_type(params), do: str(params["chat_type"])

  defp page_size(params, maximum \\ @max_page_size) do
    (params["page_size"] || maximum)
    |> int_or(maximum)
    |> min(maximum)
    |> max(1)
  end

  defp bot_ids(connect) do
    [str(connect["app_id"]), str(connect["bot_open_id"])]
    |> Enum.reject(&(&1 == ""))
  end

  defp require_param(params, key), do: require_value(params[key], key)

  defp require_media_target("feishu.reply_file", params), do: require_param(params, "message_id")
  defp require_media_target(_api, params), do: require_param(params, "receive_id")

  defp require_value(value, key) do
    if str(value) == "", do: {:error, "#{key} is required"}, else: :ok
  end

  defp require_resource_type(type) when type in ["image", "file"], do: :ok
  defp require_resource_type(_type), do: {:error, "resource_type must be image or file"}

  defp maybe_override_file_name(attachment, value) do
    case str(value) do
      "" -> attachment
      file_name -> Map.put(attachment, "file_name", file_name)
    end
  end

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "on"]

  defp blank_default(value, default) do
    case str(value) do
      "" -> default
      value -> value
    end
  end

  defp segment(value), do: value |> str() |> URI.encode_www_form()

  defp string_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp string_keys(_value), do: %{}

  # ---- safe outbound diagnostics ----

  defp emit_outbound_diagnostic(connect, api, params, result) do
    connect
    |> outbound_diagnostic(api, params, result)
    |> Diagnostics.emit()
  end

  defp outbound_diagnostic(connect, api, params, result) do
    {status, severity, event_type, reason_class, summary} = outbound_outcome(api, result)
    request_id = request_id(params)

    source_message_id =
      case api do
        "feishu.reply_text" -> str(params["message_id"])
        "feishu.send_message" -> presence(str(params["reply_to"]))
        _other -> nil
      end

    reply_message_id = reply_message_id(result)

    %{
      provider: "feishu",
      source: "salix.im",
      domain: "conversation",
      event_type: event_type,
      severity: severity,
      status: status,
      reason_class: reason_class,
      summary: summary,
      tenant_id: safe(connect, "tenant_id"),
      group_id: safe(connect, "group_id"),
      connect_id: safe(connect, "connect_id"),
      app_id: safe(connect, "app_id"),
      operation_api: api,
      request_id: request_id,
      correlation_id: first_present([request_id, reply_message_id, source_message_id]),
      source_message_id: source_message_id,
      reply_message_id: reply_message_id,
      receive_id_type: if(api == "feishu.send_text", do: receive_id_type(params), else: nil),
      delivery_state: status
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp outbound_outcome("feishu.reply_text", {:ok, _result}),
    do: {"reply_sent", "info", "feishu.reply.sent", nil, "Feishu reply sent"}

  defp outbound_outcome("feishu.reply_text", {:error, reason}),
    do:
      {"reply_failed", "error", "feishu.reply.failed", reason_class(reason),
       "Feishu reply failed"}

  defp outbound_outcome(api, {:ok, _result})
       when api in ["feishu.send_message", "feishu.forward_message"],
       do: {"sent", "info", "feishu.message.sent", nil, "Feishu message sent"}

  defp outbound_outcome(api, {:error, reason})
       when api in ["feishu.send_message", "feishu.forward_message"],
       do:
         {"send_failed", "error", "feishu.message.failed", reason_class(reason),
          "Feishu message failed"}

  defp outbound_outcome("feishu.send_text", {:ok, _result}),
    do: {"sent", "info", "feishu.message.sent", nil, "Feishu message sent"}

  defp outbound_outcome("feishu.send_text", {:error, reason}),
    do:
      {"send_failed", "error", "feishu.message.failed", reason_class(reason),
       "Feishu message failed"}

  defp reply_message_id({:ok, %{"message_id" => message_id}}), do: str(message_id)

  defp reply_message_id({:ok, %{"message" => %{"message_id" => message_id}}}),
    do: str(message_id)

  defp reply_message_id({:ok, %{"file_message" => %{"message_id" => message_id}}}),
    do: str(message_id)

  defp reply_message_id(_result), do: nil

  defp request_id(params),
    do: first_present([str(params["request_id"]), str(params["client_request_id"])])

  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))
  defp safe(connect, key) when is_map(connect), do: str(connect[key])

  defp reason_class(reason) do
    reason = to_string(reason)

    cond do
      String.contains?(reason, "rate") ->
        "rate_limited"

      String.contains?(reason, "permission") or String.contains?(reason, "scope") ->
        "missing_scope"

      String.contains?(reason, "Feishu API error") ->
        "provider_api_error"

      String.contains?(reason, "Feishu HTTP") ->
        "provider_http_error"

      String.contains?(reason, "tenant_access_token") ->
        "tenant_access_token_error"

      true ->
        "provider_error"
    end
  end
end
