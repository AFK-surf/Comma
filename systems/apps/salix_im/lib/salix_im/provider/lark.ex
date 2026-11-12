defmodule SalixIM.Provider.Lark do
  @moduledoc """
  The Lark operations of a Group's Lark bot (`im_api.lark.*`).

  A Lark connect is one custom app of the Lark open platform
  (`open.larksuite.com`) with its own credentials. The bot answers in the
  chats it is in: a send names a chat, and `chat_id` defaults to the chat of
  the current Lark source. A send can name one person (`user_id`) instead of
  a chat. `SalixIM.Provider.Lark.Docs` and `SalixIM.Provider.Lark.Minutes`
  hold the cloud document and Minutes operations, which a Worker can call
  too, as it can every read. `SalixIM.Provider.Lark.Manual` describes each
  operation to the Agent.
  """

  require Logger

  import SalixIM.Provider.Util

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.MessageRenderer.Input

  alias SalixIM.Provider.DocAccess

  alias SalixIM.Provider.Lark.{
    API,
    Directory,
    Docs,
    Manual,
    Meetings,
    Message,
    MessageRenderer,
    MessageSearch,
    Minutes,
    ResourceRef,
    Tables
  }

  alias SalixIM.{Diagnostics, LarkFiles, LarkMessageRecord, LarkThreads, ProviderObservations}

  @max_page_size 50
  @chat_search_types ~w(private external public_joined public_not_joined)
  # The kinds of ID a send to one person can name the person by.
  @direct_id_types ~w(open_id user_id union_id email)
  @max_reaction_pages 10
  @max_image_upload_bytes 10 * 1024 * 1024
  @max_file_upload_bytes 30 * 1024 * 1024
  @document_apis Manual.document_api_names()
  @table_apis Manual.table_api_names()
  @minutes_apis Manual.minutes_api_names()
  @meeting_apis Manual.meeting_api_names()
  @account_apis Manual.account_api_names()
  # Lark takes these only from a person, so `account` names who.
  @person_apis ~w(lark.request_doc_access)

  # ---- cards the runtime sends ----
  #
  # These four are not operations: `SalixIM.Provider.Lark.Manual` does not
  # list them and no Agent can call them. They take a card the runtime
  # rendered and an address the runtime resolved.

  @doc """
  Sends one card to a person's private chat with the bot.
  `SalixIM.IFC.LarkConfirmation` asks its question there, where only that
  person reads and answers it.
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
  Answers one message with a card. `SalixIM.LarkTaskCard` makes `uuid` from
  the card's identity: Lark sends one message per `uuid` in an hour, so a
  repeated request posts no second card. A card in a thread is an answer of
  the bot like any other: it marks the thread in `SalixIM.LarkThreads`, so
  people go on under the card without mentioning the bot.
  """
  @spec reply_card(map(), String.t(), map(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def reply_card(connect, message_id, card, uuid, reply_in_thread?)
      when is_binary(message_id) and is_map(card) and is_binary(uuid) do
    with :ok <- ensure_connected(connect),
         {:ok, sent} <-
           API.post(connect, "/im/v1/messages/#{segment(message_id)}/reply", %{
             "msg_type" => "interactive",
             "content" => Jason.encode!(card),
             "reply_in_thread" => reply_in_thread?,
             "uuid" => uuid
           }) do
      if reply_in_thread?, do: join_thread(connect, str(sent["chat_id"]), sent)
      {:ok, sent}
    end
  end

  @doc "The chat one message is in. A card checks its address with this before the first post."
  @spec message_chat_id(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def message_chat_id(connect, message_id) do
    with :ok <- ensure_connected(connect),
         {:ok, message} <- raw_message(connect, message_id) do
      case str(message["chat_id"]) do
        "" -> {:error, "Lark get-message response did not contain a chat_id"}
        chat_id -> {:ok, chat_id}
      end
    end
  end

  @doc "Replaces the content of one card this app sent."
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
      case call(nil, connect, "lark.get_user", %{"user_id" => open_id}) do
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

  # A send names a chat, or one person. A reply names a message of that
  # chat, so what the bot writes reaches the people of `chat_id` and nobody
  # else.
  defp do_call(agent_id, connect, "lark.send_message", params) do
    result =
      with {:ok, {_id_type, receive_id} = target} <- send_target(connect, params),
           {:ok, upload} <- upload(agent_id, params),
           :ok <- ensure_content(params, upload),
           :ok <- ensure_reply_in_chat(connect, receive_id, params) do
        with {:ok, sent} <- send_text(connect, target, params),
             {:ok, file} <- send_upload(connect, target, params, upload) do
          {:ok,
           target
           |> sent_to(sent || file)
           |> maybe_put("message", without_body(sent))
           |> maybe_put("file_message", without_body(file))}
        end
      else
        {:error, reason} -> {:error, control_error(reason)}
      end

    emit_outbound_diagnostic(connect, "lark.send_message", params, result)
    result
  end

  # Lark copies the message on its side, so a file of any size goes as it is,
  # without a download and an upload here. The forward names its target
  # always: the current chat is not a default.
  defp do_call(_agent_id, connect, "lark.forward_message", params) do
    result =
      with :ok <- require_param(params, "message_id"),
           :ok <- require_forward_target(params),
           {:ok, {id_type, receive_id} = target} <- send_target(connect, params) do
        query =
          URI.encode_query(
            maybe_put(
              %{"receive_id_type" => id_type},
              "uuid",
              message_uuid("lark.forward_message", params)
            )
          )

        with {:ok, sent} <-
               API.post(
                 connect,
                 "/im/v1/messages/#{segment(params["message_id"])}/forward?#{query}",
                 %{"receive_id" => receive_id}
               ) do
          record_sent(connect, %{}, sent)
          {:ok, target |> sent_to(sent) |> Map.put("message", without_body(sent))}
        end
      else
        {:error, reason} -> {:error, control_error(reason)}
      end

    emit_outbound_diagnostic(connect, "lark.forward_message", params, result)
    result
  end

  defp do_call(_agent_id, connect, "lark.update_message", params) do
    with {:ok, chat_id} <- chat_id(connect, params),
         :ok <- require_param(params, "message_id"),
         {:ok, body} <- outbound_content(Map.take(params, ["text", "format"])),
         :ok <- MessageRenderer.validate_request(body),
         :ok <- ensure_bot_authored(connect, params["message_id"], chat_id),
         {:ok, updated} <-
           API.put(connect, "/im/v1/messages/#{segment(params["message_id"])}", body) do
      {:ok, without_body(updated)}
    end
  end

  defp do_call(_agent_id, connect, "lark.get_chat_history", params),
    do: labelled_messages(connect, "chat", params["chat_id"], params)

  defp do_call(_agent_id, connect, "lark.get_thread_replies", params),
    do: labelled_messages(connect, "thread", params["thread_id"], params)

  defp do_call(_agent_id, connect, "lark.search_messages", params) do
    with {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      MessageSearch.search(connect, params, &normalize_message(connect, signing_key, &1))
    end
  end

  # A merged forward (msg_type merge_forward) holds the messages it carries:
  # Lark answers with the forward and then each of them, naming its parent
  # in upper_message_id.
  defp do_call(_agent_id, connect, "lark.get_message", params) do
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

  defp do_call(_agent_id, connect, "lark.list_chat_files", params) do
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

  defp do_call(agent_id, connect, "lark.fetch_message_resource", params) do
    with {:ok, locator} <- resource_locator(connect, params),
         {:ok, message} <- raw_message(connect, locator["message_id"]),
         {:ok, attachment} <-
           find_attachment(message, locator["file_key"], locator["resource_type"]),
         attachment <- maybe_override_file_name(attachment, params["file_name"]),
         {:ok, staged} <-
           LarkFiles.stage(
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

  defp do_call(_agent_id, connect, "lark.delete_message", params) do
    with :ok <- ensure_bot_authored(connect, params["message_id"], nil) do
      API.delete(connect, "/im/v1/messages/#{segment(params["message_id"])}")
    end
  end

  # ---- reactions and pins ----

  defp do_call(_agent_id, connect, "lark.add_reaction", params) do
    with :ok <- require_param(params, "message_id"),
         :ok <- require_param(params, "emoji_type") do
      API.post(connect, "/im/v1/messages/#{segment(params["message_id"])}/reactions", %{
        "reaction_type" => %{"emoji_type" => str(params["emoji_type"])}
      })
    end
  end

  defp do_call(_agent_id, connect, "lark.list_reactions", params) do
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

  defp do_call(_agent_id, connect, "lark.remove_reaction", params) do
    with :ok <- require_param(params, "message_id"),
         :ok <- require_param(params, "reaction_id"),
         :ok <- ensure_bot_reaction(connect, params["message_id"], params["reaction_id"]) do
      API.delete(
        connect,
        "/im/v1/messages/#{segment(params["message_id"])}/reactions/#{segment(params["reaction_id"])}"
      )
    end
  end

  defp do_call(_agent_id, connect, "lark.pin_message", params) do
    with :ok <- require_param(params, "message_id") do
      API.post(connect, "/im/v1/pins", %{"message_id" => str(params["message_id"])})
    end
  end

  defp do_call(_agent_id, connect, "lark.unpin_message", params) do
    with :ok <- require_param(params, "message_id") do
      API.delete(connect, "/im/v1/pins/#{segment(params["message_id"])}")
    end
  end

  defp do_call(_agent_id, connect, "lark.list_pins", params) do
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

  # ---- chat management and discovery ----

  defp do_call(_agent_id, connect, "lark.create_chat", params) do
    with :ok <- require_param(params, "name"),
         {:ok, user_ids} <- chat_user_ids(params) do
      query =
        %{"user_id_type" => "open_id"}
        |> maybe_put("uuid", message_uuid("lark.create_chat", params))
        |> URI.encode_query()

      API.post(connect, "/im/v1/chats?" <> query, %{
        "name" => str(params["name"]),
        "user_id_list" => user_ids,
        "chat_mode" => "group",
        "chat_type" => "private"
      })
    end
  end

  defp do_call(_agent_id, connect, "lark.add_chat_members", params) do
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

  defp do_call(_agent_id, connect, "lark.list_observed_chats", params) do
    with {:ok, chats} <-
           ProviderObservations.list_lark_chats(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, put_ifc(%{"chats" => chats}, ReadLabels.for_messages(connect, chats, "chat_id"))}
    end
  end

  defp do_call(_agent_id, connect, "lark.list_observed_users", params) do
    with {:ok, users} <-
           ProviderObservations.list_lark_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, put_ifc(%{"users" => users}, ReadLabels.for_space(connect))}
    end
  end

  defp do_call(_agent_id, connect, "lark.search_chats", params) do
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

  defp do_call(_agent_id, connect, "lark.join_chat", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, chat_id} <- chat_id(connect, params) do
      API.patch(connect, "/im/v1/chats/#{segment(chat_id)}/members/me_join", %{})
    end
  end

  defp do_call(_agent_id, connect, "lark.list_chats", params) do
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

  defp do_call(_agent_id, connect, "lark.get_chat", params) do
    with :ok <- require_param(params, "chat_id"),
         {:ok, chat} <- API.get(connect, "/im/v1/chats/#{segment(params["chat_id"])}") do
      {:ok, put_ifc(chat, ReadLabels.for_scope(connect, params["chat_id"]))}
    end
  end

  defp do_call(_agent_id, connect, "lark.list_chat_members", params) do
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

  defp do_call(_agent_id, connect, "lark.get_user", params) do
    with :ok <- require_param(params, "user_id"),
         {:ok, user} <-
           API.get(connect, "/contact/v3/users/#{segment(params["user_id"])}", %{
             user_id_type: blank_default(params["user_id_type"], "open_id"),
             department_id_type: "open_department_id"
           }) do
      {:ok, user |> hide_user_mobile() |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  # ---- organization directory ----

  defp do_call(_agent_id, connect, "lark.list_departments", params) do
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

  defp do_call(_agent_id, connect, "lark.list_department_users", params) do
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

  # The departments, people and user groups the app's contact data range
  # names. Lark puts all three lists on one page.
  defp do_call(_agent_id, connect, "lark.list_contact_scopes", params) do
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
             "These are authorization roots, not a complete directory listing. Expand returned departments deliberately with lark.list_departments and lark.list_department_users."
         },
         pagination
       )
       |> put_ifc(ReadLabels.for_space(connect))}
    end
  end

  # A bot cannot search the organization's people by keyword: a query reads
  # the people whose messages reached the bot, then walks the app's contact
  # data range (`Directory`).
  defp do_call(_agent_id, connect, "lark.lookup_users", params) do
    with {:ok, observed} <-
           ProviderObservations.list_lark_users(
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
  defp do_call(_agent_id, connect, "lark.list_directory_users", params) do
    with {:ok, result} <- Directory.list(connect, params["continue_from"]),
         do: {:ok, put_ifc(result, ReadLabels.for_space(connect))}
  end

  defp do_call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Lark provider api"}

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
      {:ok,
       Map.put(
         pagination,
         "messages",
         Enum.map(List.wrap(data["items"]), &normalize_message(connect, signing_key, &1))
       )}
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

  # Lark can refuse the history of an external chat while it still delivers
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
          {:error, "Lark get-message response did not contain a message"}
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
      nil -> {:error, "Lark message does not contain the requested #{resource_type} resource"}
      attachment -> {:ok, attachment}
    end
  end

  # A message as the Agent reads it. Each attachment carries the signed
  # reference `lark.fetch_message_resource` takes.
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

  # A reference is checked before anything is read from Lark, so a reference
  # another connect listed is refused here.
  defp resource_locator(connect, params) do
    case str(params["resource_ref"]) do
      "" ->
        tuple_resource_locator(params)

      resource_ref ->
        with {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
          ResourceRef.decode(resource_ref, resource_ref_scope(connect), signing_key)
        end
    end
  end

  # A reference belongs to one connect of one tenant.
  defp resource_ref_scope(connect) do
    Enum.join(
      ["lark", str(connect["tenant_id"]), str(connect["connect_id"])],
      <<0>>
    )
  end

  # A caller without a reference names the file by the message, its file_key
  # and its kind. Lark itself refuses a file_key that is not of that message.
  defp tuple_resource_locator(params) do
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

  # Where a send goes, as Lark's `receive_id_type` and `receive_id`: a chat,
  # or one person named by `user_id`. A reply needs a message of a chat, so
  # it does not go with `user_id`.
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

  # A send to a person also names the private chat Lark put the message in.
  # Lark answers a send with the stored message: its body holds both a plain
  # text copy and the Markdown source, and reads like the message shown twice.
  # The chat shows it once; the caller needs only the message's ids.
  defp without_body(%{} = message), do: Map.delete(message, "body")
  defp without_body(message), do: message

  defp sent_to({"chat_id", chat_id}, _sent), do: %{"chat_id" => chat_id}

  defp sent_to({id_type, user_id}, sent),
    do:
      maybe_put(
        %{"user_id" => user_id, "user_id_type" => id_type},
        "chat_id",
        str((sent || %{})["chat_id"])
      )

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
          "" -> {:error, "chat_id is required outside a Lark source"}
          chat_id -> {:ok, chat_id}
        end

      chat_id ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, chat_id),
          do: {:ok, chat_id},
          else: {:error, "chat_id must be a Lark chat ID (oc_...)"}
    end
  end

  defp chat_user_ids(%{"user_ids" => ids}) when is_list(ids) and length(ids) in 1..50 do
    if Enum.all?(ids, &(is_binary(&1) and Regex.match?(~r/\Aou_[A-Za-z0-9_-]{1,125}\z/, &1))),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, "user_ids must contain Lark open_ids (ou_...), not names"}
  end

  defp chat_user_ids(_params),
    do: {:error, "user_ids must be a list of 1 to 50 Lark open_ids"}

  # The chat and message of the Lark message this turn answers.
  defp origin_context(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "lark", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context, else: %{}

      _other ->
        %{}
    end
  end

  defp upload(agent_id, params) do
    case str(params["path"]) do
      "" ->
        {:ok, nil}

      path ->
        with {:ok, upload} <- read_agent_upload_stream(agent_id, path, params["blob_ref"]),
             kind = if(image?(upload.filename), do: "image", else: "file"),
             :ok <- validate_upload_size(kind, upload.size) do
          {:ok, Map.put(upload, :kind, kind)}
        end
    end
  end

  defp image?(filename),
    do: String.downcase(Path.extname(filename)) in ~w(.png .jpg .jpeg .gif .webp .bmp)

  defp ensure_content(params, upload) do
    if String.trim(to_string(params["text"] || "")) == "" and is_nil(upload),
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

  defp send_text(connect, target, params) do
    if String.trim(to_string(params["text"] || "")) == "" do
      {:ok, nil}
    else
      with {:ok, rendered} <- outbound_content(params),
           body = maybe_put(rendered, "uuid", message_uuid("lark.send_message", params)),
           :ok <- MessageRenderer.validate_request(body),
           {:ok, sent} <- post_message(connect, target, params, body) do
        record_sent(connect, params, sent)
        {:ok, sent}
      end
    end
  end

  defp send_upload(_connect, _target, _params, nil), do: {:ok, nil}

  defp send_upload(connect, target, params, upload) do
    with {:ok, key} <- upload_media(connect, upload) do
      body =
        %{
          "msg_type" => upload.kind,
          "content" => Jason.encode!(%{(upload.kind <> "_key") => key})
        }
        |> maybe_put("uuid", message_uuid("lark.send_message.file", params))

      with {:ok, sent} <- post_message(connect, target, params, body) do
        # The file's own row: it has no text, so the Markdown is not put on it.
        record_sent(connect, %{}, sent)
        {:ok, sent}
      end
    end
  end

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
                 Map.put(body, "reply_in_thread", reply_in_thread?(connect, receive_id, params))
               ) do
          join_thread(connect, receive_id, sent)
          {:ok, sent}
        end
    end
  end

  # A reply in a group opens a thread under the message, or goes on in its
  # thread, so the people of the group can continue there without mentioning
  # the bot again. A private chat needs no thread: every message of it is for
  # the bot.
  defp reply_in_thread?(connect, chat_id, params) do
    origin = origin_context(connect)

    if Map.has_key?(params, "reply_in_thread"),
      do: truthy?(params["reply_in_thread"]),
      else: not (chat_id == str(origin["chat_id"]) and str(origin["chat_type"]) == "p2p")
  end

  # Best effort: the reply is out, and without the mark the thread only needs
  # a mention again.
  defp join_thread(connect, chat_id, sent) do
    with thread_id when thread_id != "" <- str(sent["thread_id"]),
         {:error, reason} <- LarkThreads.join(connect, chat_id, thread_id) do
      Logger.warning("lark_thread_join_failed", reason: inspect(reason))
    end

    :ok
  end

  # Lark sends the bot no event for its own message, so a sent message is
  # recorded here. Best effort: the send already happened.
  defp record_sent(connect, params, %{"message_id" => _id} = sent),
    do: LarkMessageRecord.observe_sent(connect, sent, to_string(params["text"] || ""))

  defp record_sent(_connect, _params, _sent), do: :ok

  # `chat_id` is the chat an edit names, or `nil` when the operation writes
  # nothing a person reads.
  defp ensure_bot_authored(connect, message_id, chat_id) do
    with {:ok, message} <- raw_message(connect, message_id) do
      sender = message["sender"] || %{}
      sender_id = str(sender["id"])
      sender_type = str(sender["sender_type"])

      cond do
        not (sender_type == "app" and sender_id != "" and sender_id in bot_ids(connect)) ->
          {:error, "Lark message is not authored by this bot"}

        is_binary(chat_id) and str(message["chat_id"]) != chat_id ->
          {:error, "message_id is not a message of this chat"}

        true ->
          :ok
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
        {:error, "Lark reaction is not authored by this bot"}
      end
    end
  end

  defp find_reaction(_connect, _message_id, _reaction_id, _page_token, 0),
    do: {:error, "Lark reaction was not found within the bounded 10-page ownership check"}

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
              {:error, "Lark reaction is not authored by this bot"}
            end
          end
      end
    end
  end

  defp paged_result(data, key, current_page_token) do
    with items when is_list(items) <- data["items"],
         {:ok, pagination} <- page_metadata(data, current_page_token) do
      {:ok, Map.put(pagination, key, items)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Lark pagination incomplete: response items must be a list"}
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
             "Lark pagination invalid_page_token: page_token must be a nonblank string when provided"}

          token ->
            {:ok, token}
        end

      {:ok, _token} ->
        {:error,
         "Lark pagination invalid_page_token: page_token must be a nonblank string when provided"}
    end
  end

  defp page_metadata(data, current_page_token) do
    case Map.fetch(data, "has_more") do
      {:ok, true} ->
        next_page_token = data["page_token"]

        cond do
          not is_binary(next_page_token) ->
            {:error,
             "Lark pagination incomplete: has_more response returned a non-string page_token"}

          String.trim(next_page_token) == "" ->
            {:error, "Lark pagination incomplete: has_more response returned a blank page_token"}

          String.trim(next_page_token) == current_page_token ->
            {:error,
             "Lark pagination incomplete: has_more response repeated page_token and did not advance"}

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
        {:error, "Lark pagination incomplete: response has_more must be a boolean"}
    end
  end

  defp upload_media(connect, %{kind: "image"} = upload),
    do: API.upload_image(connect, upload.filename, upload.stream, upload.size)

  defp upload_media(connect, upload),
    do: API.upload_file(connect, upload.filename, upload.stream, upload.size)

  defp read_agent_upload_stream(agent_id, path, blob_ref) do
    path = str(path)

    cond do
      path == "" ->
        {:error, "path is required"}

      str(agent_id) == "" ->
        {:error, "agent_id is required for Lark file uploads"}

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

  defp validate_upload_size(_kind, 0), do: {:error, "Lark does not allow empty uploads"}

  defp validate_upload_size("image", size) when size > @max_image_upload_bytes,
    do: {:error, "Lark image uploads are limited to 10 MB"}

  defp validate_upload_size("file", size) when size > @max_file_upload_bytes,
    do: {:error, "Lark file uploads are limited to 30 MB"}

  defp validate_upload_size(_kind, _size), do: :ok

  defp message_uuid(api, params) do
    case str(params["__tool_call_id"]) do
      "" ->
        nil

      tool_call_id ->
        target =
          first_present([
            str(params["reply_to"]),
            str(params["chat_id"]),
            str(params["user_id"])
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
         {:ok, card} <-
           SalixIM.QuestionCard.feishu_card(
             SalixIM.QuestionCard.with_mentions(str(params["text"]), mentioned),
             question,
             %{
               "chat_type" => if(str(params["user_id"]) != "", do: "p2p", else: "")
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
    {status, severity, event_type, reason_class} =
      case result do
        {:ok, _sent} -> {"sent", "info", "lark.message.sent", nil}
        {:error, reason} -> {"send_failed", "error", "lark.message.failed", reason_class(reason)}
      end

    request_id = request_id(params)
    source_message_id = str(params["reply_to"])
    reply_message_id = reply_message_id(result)

    %{
      provider: "lark",
      source: "salix.im",
      domain: "conversation",
      event_type: event_type,
      severity: severity,
      status: status,
      reason_class: reason_class,
      summary: if(status == "sent", do: "Lark message sent", else: "Lark message failed"),
      tenant_id: safe(connect, "tenant_id"),
      group_id: safe(connect, "group_id"),
      connect_id: safe(connect, "connect_id"),
      app_id: safe(connect, "app_id"),
      operation_api: api,
      receive_id_type: receive_id_type(params),
      request_id: request_id,
      correlation_id: first_present([request_id, reply_message_id, source_message_id]),
      source_message_id: source_message_id,
      reply_message_id: reply_message_id,
      delivery_state: status
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  # The kind of ID the send named its target by. It says whether the message
  # went to a chat or to one person; the ID itself is not in the diagnostic.
  defp receive_id_type(params) do
    if str(params["user_id"]) == "",
      do: "chat_id",
      else: blank_default(params["user_id_type"], "open_id")
  end

  defp reply_message_id({:ok, %{"message" => %{"message_id" => message_id}}}),
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

      String.contains?(reason, "Lark API error") ->
        "provider_api_error"

      String.contains?(reason, "Lark HTTP") ->
        "provider_http_error"

      String.contains?(reason, "tenant_access_token") ->
        "tenant_access_token_error"

      true ->
        "provider_error"
    end
  end
end
