defmodule SalixIM.Provider.Telegram do
  @moduledoc false

  import SalixIM.Provider.Util

  alias SalixIM.ProviderObservations
  alias SalixIM.TelegramText

  # Runtime-only topic transport. Model calls use open_task_topic, which owns
  # Task authorization and the durable creation reservation.
  def topic_request(connect, method, params) when method in ["getMe", "createForumTopic"] do
    with :ok <- ensure_connected(connect) do
      request(fn ->
        Req.post("#{telegram_api_base(connect)}/bot#{connect["bot_token"]}/#{method}",
          json: params,
          retry: false,
          receive_timeout: 10_000
        )
      end)
    end
  end

  # ---- Telegram dispatch ----

  def call(agent_id, connect, api, params) do
    with :ok <- ensure_connected(connect),
         :ok <- authorize_managed_call(connect, api, params) do
      do_call_telegram(agent_id, connect, api, params)
    end
  end

  defp do_call_telegram(agent_id, connect, api, params)
       when api in ["telegram.send_message", "telegram.remove_reply_keyboard"] do
    with {:ok, rendered} <-
           TelegramText.message(str(params["text"]), params["text_format"] || "markdown") do
      placement = placement(params)

      placement =
        if api == "telegram.remove_reply_keyboard",
          do: Map.put(placement, "reply_markup", %{"remove_keyboard" => true}),
          else: placement

      send_message(connect, placement, rendered, System.monotonic_time())
    end
    |> reply_sent(agent_id, connect, params)
  end

  defp do_call_telegram(agent_id, connect, api, params)
       when api in ["telegram.send_photo", "telegram.send_document"] do
    field = if api == "telegram.send_photo", do: :photo, else: :document

    with {:ok, caption} <-
           TelegramText.caption(str(params["caption"]), params["text_format"] || "markdown"),
         {:ok, upload} <- read_agent_upload(agent_id, params["path"]) do
      fields =
        %{chat_id: str(params["chat_id"])}
        |> Map.put(field, {upload.data, filename: upload.filename})
        |> Map.merge(caption.fields)
        |> maybe_put(:message_thread_id, presence(str(params["message_thread_id"])))
        |> maybe_put(:reply_to_message_id, presence(str(params["reply_to_message_id"])))

      post = fn fields ->
        Req.post(
          "#{telegram_api_base(connect)}/bot#{connect["bot_token"]}/#{telegram_send_file_method(api)}",
          form_multipart: fields,
          retry: false
        )
      end

      response = post.(fields)

      response =
        if fields[:parse_mode] && format_rejected?(response) do
          case TelegramText.caption_fallback(caption.plain) do
            {:ok, fallback} -> post.(fields |> Map.delete(:parse_mode) |> Map.merge(fallback))
            {:error, _} -> response
          end
        else
          response
        end

      request(fn -> response end)
    end
    |> reply_sent(agent_id, connect, params)
  end

  defp do_call_telegram(_agent_id, connect, "telegram.list_chats", params) do
    with {:ok, chats} <-
           ProviderObservations.list_telegram_chats(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, %{"chats" => chats}}
    end
  end

  defp do_call_telegram(_agent_id, connect, "telegram.list_users", params) do
    with {:ok, users} <-
           ProviderObservations.list_telegram_users(
             connect["connect_id"],
             params["query"],
             params["limit"]
           ) do
      {:ok, %{"users" => users}}
    end
  end

  defp do_call_telegram(_agent_id, connect, "telegram.get_chat", params) do
    chat_id = str(params["chat_id"])

    case ProviderObservations.get_telegram_chat(connect["connect_id"], chat_id) do
      {:ok, chat} ->
        {:ok, %{"chat" => chat}}

      {:error, :not_found} ->
        post_json(telegram_api_base(connect), "/bot#{connect["bot_token"]}/getChat", %{
          "chat_id" => chat_id
        })

      other ->
        other
    end
  end

  defp do_call_telegram(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Telegram provider api"}

  defp reply_sent({:ok, _} = result, agent_id, connect, params) do
    SalixIM.PrivateChatStatus.provider_reply_sent(agent_id, connect, params)
    result
  end

  defp reply_sent(result, _agent_id, _connect, _params), do: result

  # Observe the actual transport result before the shared provider adapter
  # turns it into the existing public result. Authorization failures never
  # reach this boundary; no peer, credential, or provider text enters telemetry.
  defp placement(params) do
    %{"chat_id" => str(params["chat_id"])}
    |> maybe_put_present("message_thread_id", params["message_thread_id"])
    |> maybe_put_present("reply_parameters", reply_parameters(params))
  end

  defp reply_parameters(%{"reply_to_message_id" => id} = params) when id not in [nil, ""] do
    %{"message_id" => id}
    |> maybe_put_present("allow_sending_without_reply", params["allow_sending_without_reply"])
  end

  defp reply_parameters(_), do: nil

  defp send_message(connect, placement, rendered, started) do
    response =
      post_text(connect, rendered.method, Map.merge(placement, rendered.fields))

    response =
      if rendered.fields["parse_mode"] == "HTML" and format_rejected?(response) do
        case TelegramText.plain_fallback(rendered.plain) do
          {:ok, fields} -> post_text(connect, "sendMessage", Map.merge(placement, fields))
          {:error, _} -> response
        end
      else
        response
      end

    result = request(fn -> response end)
    emit_send(connect, send_outcome(response), started)
    result
  rescue
    exception ->
      emit_send(connect, :error, started)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      emit_send(connect, :error, started)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp post_text(connect, method, body) do
    Req.post("#{telegram_api_base(connect)}/bot#{connect["bot_token"]}/#{method}",
      json: body,
      retry: false
    )
  end

  # Only a definitive parser rejection proves nothing was delivered. Never
  # retry timeouts, 5xx, rate limits or generic 400s as another message format.
  defp format_rejected?(
         {:ok, %{status: 400, body: %{"ok" => false, "description" => description}}}
       )
       when is_binary(description) do
    Enum.any?(
      ["Bad Request: can't parse entities", "Bad Request: can't parse rich message"],
      &String.starts_with?(description, &1)
    )
  end

  defp format_rejected?(_), do: false

  defp send_outcome({:ok, %{status: 403}}), do: :rejected

  defp send_outcome({:ok, %{status: status, body: %{"ok" => false, "error_code" => 403}}})
       when status in 200..299,
       do: :rejected

  defp send_outcome({:ok, %{status: status, body: %{"ok" => true, "result" => _result}}})
       when status in 200..299,
       do: :ok

  defp send_outcome({:error, %Req.TransportError{reason: :timeout}}), do: :timeout
  defp send_outcome({:error, _reason}), do: :unavailable
  defp send_outcome(_response), do: :error

  defp emit_send(connect, outcome, started) do
    surface = if connect["managed_by"] == "comma_product", do: "comma", else: "salix"

    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        component: "salix_im",
        operation: "telegram_send_message",
        surface: surface,
        outcome: outcome
      }
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp authorize_managed_call(%{"managed_by" => "comma_product"} = connect, api, params) do
    peer_id = str(connect["managed_peer_id"])

    cond do
      api not in [
        "telegram.send_message",
        "telegram.remove_reply_keyboard",
        "telegram.send_photo",
        "telegram.send_document",
        "telegram.get_chat"
      ] ->
        {:error, "unsupported Telegram API for a Comma-managed direct message"}

      peer_id == "" or str(params["chat_id"]) != peer_id ->
        {:error, "Telegram chat_id is outside this Comma-managed direct message"}

      true ->
        :ok
    end
  end

  defp authorize_managed_call(_connect, _api, _params), do: :ok

  defp telegram_api_base(_connect),
    do:
      :salix_im
      |> Application.get_env(:telegram_api_base_url, "https://api.telegram.org")
      |> str()
      |> default_base("https://api.telegram.org")

  defp telegram_send_file_method("telegram.send_photo"), do: "sendPhoto"
  defp telegram_send_file_method("telegram.send_document"), do: "sendDocument"
end
