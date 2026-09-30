defmodule SalixIM.Provider.Feishu do
  @moduledoc false

  require Logger

  import SalixIM.Provider.Util

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Provider.Feishu.{API, Message, ResourceRef}
  alias SalixIM.{Diagnostics, FeishuFiles, ProviderConnects, ProviderObservations}

  @max_page_size 50
  @max_reaction_pages 10
  @max_image_upload_bytes 10 * 1024 * 1024
  @max_file_upload_bytes 30 * 1024 * 1024

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

  def call(agent_id, connect, api, params, scope \\ %{}) do
    with :ok <- ensure_connected(connect) do
      params =
        params
        |> Kernel.||(%{})
        |> string_keys()
        |> Map.put("__tool_call_id", scope[:tool_call_id])

      do_call(agent_id, connect, api, params)
    end
  end

  # ---- messages and media ----

  defp do_call(_agent_id, connect, api, params)
       when api in ["feishu.send_text", "feishu.reply_text"] do
    result =
      if api == "feishu.reply_text" do
        with :ok <- require_param(params, "message_id"),
             :ok <- require_param(params, "text"),
             {:ok, text} <- outbound_text(params),
             {:ok, response} <-
               API.post(
                 connect,
                 "/im/v1/messages/#{segment(params["message_id"])}/reply",
                 %{
                   "msg_type" => "text",
                   "content" => Jason.encode!(%{"text" => text}),
                   "reply_in_thread" => reply_in_thread?(params)
                 }
                 |> maybe_put("uuid", message_uuid(api, params))
               ),
             :ok <- maybe_record_thread_participation(connect, params, response) do
          {:ok, response}
        end
      else
        with :ok <- require_param(params, "receive_id"),
             :ok <- require_param(params, "text"),
             {:ok, text} <- outbound_text(params) do
          API.post(
            connect,
            "/im/v1/messages?receive_id_type=#{segment(receive_id_type(params))}",
            %{
              "receive_id" => str(params["receive_id"]),
              "msg_type" => "text",
              "content" => Jason.encode!(%{"text" => text})
            }
            |> maybe_put("uuid", message_uuid(api, params))
          )
        end
      end

    emit_outbound_diagnostic(connect, api, params, result)
    result
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

  defp do_call(_agent_id, connect, "feishu.get_chat_history", params),
    do: labelled_messages(connect, "chat", params["chat_id"], params)

  defp do_call(_agent_id, connect, "feishu.get_thread_replies", params),
    do: labelled_messages(connect, "thread", params["thread_id"], params)

  defp do_call(_agent_id, connect, "feishu.get_message", params) do
    with {:ok, message} <- raw_message(connect, params["message_id"]),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect) do
      normalized = normalize_message(connect, signing_key, message)

      {:ok,
       put_ifc(
         %{"message" => normalized},
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
    with :ok <- ensure_bot_authored(connect, params["message_id"]),
         :ok <- require_param(params, "text"),
         {:ok, text} <- outbound_text(%{"text" => params["text"]}) do
      API.put(connect, "/im/v1/messages/#{segment(params["message_id"])}", %{
        "msg_type" => "text",
        "content" => Jason.encode!(%{"text" => text})
      })
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
      {:ok, %{"chats" => chats}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_observed_users", params) do
    with {:ok, users} <-
           ProviderObservations.list_feishu_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, %{"users" => users}}
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
      {:ok, result}
    end
  end

  defp do_call(_agent_id, connect, "feishu.get_chat", params) do
    with :ok <- require_param(params, "chat_id") do
      API.get(connect, "/im/v1/chats/#{segment(params["chat_id"])}")
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
      {:ok, result}
    end
  end

  defp do_call(_agent_id, connect, "feishu.get_user", params) do
    with :ok <- require_param(params, "user_id") do
      API.get(connect, "/contact/v3/users/#{segment(params["user_id"])}", %{
        user_id_type: blank_default(params["user_id_type"], "open_id"),
        department_id_type: "open_department_id"
      })
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
      {:ok, result}
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
      {:ok, result}
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
       )}
    end
  end

  # Bot tenant tokens cannot use Feishu's keyword user-search API. Keep this
  # compatibility operation explicitly local/observed instead of pretending it
  # is a tenant-wide directory search.
  defp do_call(_agent_id, connect, "feishu.lookup_users", params) do
    with {:ok, users} <-
           ProviderObservations.list_feishu_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, %{"users" => users, "source" => "observed_inbound_users"}}
    end
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
    with {:ok, page} <- list_messages(connect, container_type, container_id, params) do
      {:ok, put_ifc(page, ReadLabels.for_messages(connect, page["messages"], "chat_id"))}
    end
  end

  # The block rides out under a reserved key that `SalixAgent.Tools.IMRouter`
  # pops before the result is encoded, so it never reaches the model as content.
  defp put_ifc(result, nil), do: result
  defp put_ifc(result, ifc), do: Map.put(result, "__ifc__", ifc)

  defp raw_message(connect, message_id) do
    with :ok <- require_value(message_id, "message_id"),
         {:ok, data} <-
           API.get(connect, "/im/v1/messages/#{segment(message_id)}", %{
             card_msg_content_type: "raw_card_content",
             with_sender_name: true
           }) do
      case data do
        %{"items" => [message | _]} when is_map(message) -> {:ok, message}
        %{"message_id" => _} = message -> {:ok, message}
        _ -> {:error, "Feishu get-message response did not contain a message"}
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

  defp outbound_text(params) do
    with {:ok, mentions} <- outbound_mentions(params["mentions"]) do
      mention_all =
        if truthy?(params["mention_all"]),
          do: [~s(<at user_id="all">所有人</at>)],
          else: []

      {:ok,
       (mentions ++ mention_all ++ [xml_escape(params["text"])])
       |> Enum.reject(&(&1 == ""))
       |> Enum.join(" ")}
    end
  end

  defp outbound_mentions(nil), do: {:ok, []}

  defp outbound_mentions(mentions) when is_binary(mentions) do
    mentions
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> outbound_mentions()
  end

  defp outbound_mentions(mentions) when is_list(mentions) do
    mentions
    |> Enum.reduce_while({:ok, []}, fn mention, {:ok, acc} ->
      case outbound_mention(mention) do
        {:ok, tag} -> {:cont, {:ok, acc ++ [tag]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.uniq(tags)}
      error -> error
    end
  end

  defp outbound_mentions(_mentions),
    do: {:error, "mentions must be a list of {user_id, name} entries"}

  defp outbound_mention(mention) when is_binary(mention) do
    outbound_mention(%{"user_id" => mention, "name" => "成员"})
  end

  defp outbound_mention(mention) when is_map(mention) do
    mention = string_keys(mention)
    user_id = str(mention["user_id"] || mention["open_id"] || mention["id"])
    name = blank_default(mention["name"], "成员")

    cond do
      user_id == "" ->
        {:error, "each Feishu mention requires user_id"}

      user_id == "all" ->
        {:error, "use mention_all=true instead of a user_id=all mention"}

      true ->
        {:ok, ~s(<at user_id="#{xml_escape(user_id)}">#{xml_escape(name)}</at>)}
    end
  end

  defp outbound_mention(_mention),
    do: {:error, "each Feishu mention must be a user ID or {user_id, name} object"}

  defp xml_escape(value) do
    value
    |> str()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
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
    source_message_id = if(api == "feishu.reply_text", do: str(params["message_id"]), else: nil)
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

  defp outbound_outcome("feishu.send_text", {:ok, _result}),
    do: {"sent", "info", "feishu.message.sent", nil, "Feishu message sent"}

  defp outbound_outcome("feishu.send_text", {:error, reason}),
    do:
      {"send_failed", "error", "feishu.message.failed", reason_class(reason),
       "Feishu message failed"}

  defp reply_message_id({:ok, %{"message_id" => message_id}}), do: str(message_id)
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
