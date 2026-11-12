defmodule SalixIM.Provider.Lark.MeetingBot do
  @moduledoc """
  The OpenAPI of an app's bot in a Lark or Feishu video meeting, called as the
  app. The two platforms answer the same paths on their own hosts, so the
  connect's provider picks the client.

  The bot answers an invitation with `bots/join`, naming the nine-digit meeting
  number and the invitation's `call_id`; it joins a calendar meeting by its
  number alone. It reads what is said and written in the meeting from
  `bots/events` with the long meeting ID that `bots/join` returned. Both need the scope `vc:meeting.bot.join:write`. It writes into the
  meeting with `bots/message`, which needs `vc:meeting.message:write`.
  """

  alias SalixIM.Provider.Feishu.API, as: FeishuAPI
  alias SalixIM.Provider.Lark.API, as: LarkAPI

  @events_page_size 100
  # 120004: the bot is not in this meeting. 10005 is the same for a bot that
  # never got in. 121105: the meeting does not exist any more.
  @absent ~r/^(Lark|Feishu) API error (120004|10005|121105) /

  @spec join(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def join(connect, meeting_no, call_id) do
    body = %{"join_type" => 1, "join_identify" => %{"meeting_no" => meeting_no}}
    body = if call_id == "", do: body, else: Map.put(body, "call_id", call_id)
    api(connect).post(connect, "/vc/v1/bots/join", body)
  end

  @doc "One page of a meeting's events after `page_token`."
  @spec events(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def events(connect, meeting_id, page_token) do
    params = %{
      "meeting_id" => meeting_id,
      "user_id_type" => "open_id",
      "page_size" => @events_page_size
    }

    params = if page_token == "", do: params, else: Map.put(params, "page_token", page_token)
    api(connect).get(connect, "/vc/v1/bots/events", params)
  end

  @doc """
  Sends text into the meeting, where its participants read it. Lark sends one
  message per `uuid`, so a repeated request posts no second message.
  """
  @spec post_meeting_text(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def post_meeting_text(connect, meeting_id, text, uuid) do
    api(connect).post(connect, "/vc/v1/bots/message", %{
      "meeting_id" => meeting_id,
      "msg_type" => "text",
      "content" => text,
      "uuid" => uuid
    })
  end

  @doc "The platform's error code in an error of this client, or nil."
  @spec error_code(term()) :: integer() | nil
  def error_code(reason) when is_binary(reason) do
    case Regex.run(~r/^(?:Lark|Feishu) API error (\d+) /, reason) do
      [_, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  def error_code(_reason), do: nil

  @doc """
  The web link of a document (an AI note's `docx`), read with `connect`'s
  identity (`drive/v1/metas/batch_query`).
  """
  @spec doc_url(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def doc_url(connect, token) do
    body = %{
      "request_docs" => [%{"doc_token" => token, "doc_type" => "docx"}],
      "with_url" => true
    }

    with {:ok, data} <- api(connect).post(connect, "/drive/v1/metas/batch_query", body),
         [%{"url" => url} | _] when is_binary(url) <- List.wrap(data["metas"]) do
      {:ok, url}
    else
      {:error, _} = error -> error
      _ -> {:error, :doc_url_missing}
    end
  end

  @doc "Whether an error of `events/3` says the bot is out of the meeting."
  @spec absent?(term()) :: boolean()
  def absent?(reason) when is_binary(reason), do: Regex.match?(@absent, reason)
  def absent?(_reason), do: false

  @doc """
  Sends text to a person's private chat with the bot. The answer names the chat
  (`chat_id`) and the message (`message_id`). Lark sends one message per `uuid`
  in an hour, and Feishu the same, so a repeated request posts no second
  message.
  """
  @spec post_direct_text(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def post_direct_text(connect, open_id, text, uuid) do
    api(connect).post(connect, "/im/v1/messages?receive_id_type=open_id", %{
      "receive_id" => open_id,
      "msg_type" => "text",
      "content" => Jason.encode!(%{"text" => text}),
      "uuid" => uuid
    })
  end

  @doc "Sends `text` to a chat the bot is in. One `uuid` posts one message."
  @spec post_chat_text(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def post_chat_text(connect, chat_id, text, uuid) do
    api(connect).post(connect, "/im/v1/messages?receive_id_type=chat_id", %{
      "receive_id" => chat_id,
      "msg_type" => "text",
      "content" => Jason.encode!(%{"text" => text}),
      "uuid" => uuid
    })
  end

  @doc """
  A meeting actor's open_id. An event pushed to the app names every ID of the
  person under `id`; `bots/events` asked for `open_id` gives it as a string.
  """
  @spec open_id(term()) :: String.t()
  def open_id(%{"id" => id}) when is_binary(id), do: String.trim(id)
  def open_id(%{"id" => %{"open_id" => id}}) when is_binary(id), do: String.trim(id)
  def open_id(%{"open_id" => id}) when is_binary(id), do: String.trim(id)
  def open_id(_actor), do: ""

  @doc "A meeting's long ID. An event pushes it as a number, an API answers a string."
  @spec meeting_id(term()) :: String.t()
  def meeting_id(id) when is_integer(id), do: Integer.to_string(id)
  def meeting_id(id) when is_binary(id), do: String.trim(id)
  def meeting_id(_id), do: ""

  defp api(%{"provider" => "feishu"}), do: FeishuAPI
  defp api(_connect), do: LarkAPI
end
