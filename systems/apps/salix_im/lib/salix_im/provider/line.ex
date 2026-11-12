defmodule SalixIM.Provider.Line do
  @moduledoc """
  Router operations on a LINE Official Account (`line.*`), through the LINE
  Messaging API.

  A chat is `user:<userId>`, `group:<groupId>` or `room:<roomId>`, as
  `SalixIM.LineInbound` names it. `chat_id` defaults to the chat of the
  current LINE source. The bot can address only chats that wrote to it or
  that it joined: LINE issues these IDs per channel.

  ## Replies and push messages

  LINE gives a reply token with each message. A send with that token is a
  reply: it is free, and LINE takes it once. Any other send is a push
  message, which counts against the channel's monthly message quota. A send
  to a chat whose newest message has an unused token younger than
  `@reply_token_max_age_ms` spends the token; every later send pushes.

  LINE publishes no Elixir SDK; the few calls Salix needs are plain JSON over
  `Req` with the channel access token as bearer.
  """

  import SalixIM.Provider.Util

  alias SalixIM.ProviderObservations

  @ops ~w(line.send_message line.list_chats)

  @default_base "https://api.line.me"
  @default_data_base "https://api-data.line.me"
  @receive_timeout_ms 15_000

  # LINE accepts a reply token for about a minute.
  @reply_token_max_age_ms 50_000
  # A text message holds at most 5000 characters, and one request at most 5
  # messages.
  @max_message_chars 5_000
  @max_messages 5

  @doc "The LINE operation names."
  def operations, do: @ops

  @doc "The chat a LINE source names for a webhook event source."
  def chat_id(%{"type" => "user", "userId" => id}) when is_binary(id) and id != "",
    do: "user:" <> id

  def chat_id(%{"type" => "group", "groupId" => id}) when is_binary(id) and id != "",
    do: "group:" <> id

  def chat_id(%{"type" => "room", "roomId" => id}) when is_binary(id) and id != "",
    do: "room:" <> id

  def chat_id(_source), do: ""

  def call(agent_id, connect, api, params) when is_map(connect) do
    params = if is_map(params), do: params, else: %{}

    with true <- api in @ops || {:error, "Unsupported LINE operation"},
         :ok <- ensure_connected(connect) do
      operation(api, agent_id, connect, params)
    end
  end

  # ---- operations ----

  defp operation("line.send_message", _agent_id, connect, params) do
    with {:ok, chat_id} <- target_chat(connect, params),
         {:ok, messages} <- text_messages(params["text"]) do
      send_messages(connect, chat_id, messages)
    end
  end

  defp operation("line.list_chats", _agent_id, connect, params) do
    with {:ok, chats} <-
           ProviderObservations.list_line_chats(
             connect["connect_id"],
             str(params["query"]),
             params["limit"]
           ) do
      {:ok,
       %{
         "chats" =>
           Enum.map(
             chats,
             &Map.take(&1, ~w(chat_id chat_type last_sender_id last_message_at))
           )
       }}
    end
  end

  defp send_messages(connect, chat_id, messages) do
    case ProviderObservations.take_line_reply_token(
           connect["connect_id"],
           chat_id,
           @reply_token_max_age_ms
         ) do
      {:ok, token} ->
        case post(connect, "/v2/bot/message/reply", %{
               "replyToken" => token,
               "messages" => messages
             }) do
          {:ok, _body} ->
            {:ok, %{"chat_id" => chat_id, "delivery" => "reply"}}

          # LINE refused the token (expired, or another node spent it): nothing
          # went out, so the send becomes a push.
          {:error, {:line_api, 400, _message}} ->
            push(connect, chat_id, messages)

          {:error, reason} ->
            {:error, error_text(reason)}
        end

      :none ->
        push(connect, chat_id, messages)
    end
  end

  defp push(connect, chat_id, messages) do
    [_kind, to] = String.split(chat_id, ":", parts: 2)

    # The retry key makes a resent request a no-op on LINE's side.
    case post(connect, "/v2/bot/message/push", %{"to" => to, "messages" => messages},
           headers: [{"x-line-retry-key", retry_key()}]
         ) do
      {:ok, body} ->
        {:ok,
         %{"chat_id" => chat_id, "delivery" => "push"}
         |> maybe_put("message_ids", sent_ids(body))}

      {:error, {:line_api, 429, _message}} ->
        {:error,
         "LINE refused the push message: the channel's monthly message quota is used up or the rate limit was hit. Do not retry now."}

      {:error, reason} ->
        {:error, error_text(reason)}
    end
  end

  defp sent_ids(%{"sentMessages" => sent}) when is_list(sent),
    do: sent |> Enum.map(&str(&1["id"])) |> Enum.reject(&(&1 == ""))

  defp sent_ids(_body), do: nil

  defp target_chat(connect, params) do
    chat_id =
      case str(params["chat_id"]) do
        "" -> str(origin_context(connect)["chat_id"])
        chat_id -> chat_id
      end

    cond do
      chat_id == "" ->
        {:error, "chat_id is required outside a LINE source"}

      not Regex.match?(~r/\A(user|group|room):[A-Za-z0-9]{1,64}\z/, chat_id) ->
        {:error, "chat_id must be user:<userId>, group:<groupId> or room:<roomId>"}

      true ->
        {:ok, chat_id}
    end
  end

  defp origin_context(connect) do
    case SalixIM.Provider.current_tool_context()["trusted_origin"] do
      %{"provider" => "line", "provider_context" => %{} = context} ->
        if context["connect_id"] == connect["connect_id"], do: context, else: %{}

      _other ->
        %{}
    end
  end

  # LINE shows text as written: no Markdown. A long text goes out as up to
  # five messages of one request.
  defp text_messages(text) do
    text = text |> to_string_safe() |> String.trim()

    cond do
      text == "" ->
        {:error, "text is required"}

      String.length(text) > @max_message_chars * @max_messages ->
        {:error, "text is longer than #{@max_message_chars * @max_messages} characters"}

      true ->
        {:ok,
         text
         |> String.graphemes()
         |> Enum.chunk_every(@max_message_chars)
         |> Enum.map(&%{"type" => "text", "text" => Enum.join(&1)})}
    end
  end

  defp retry_key, do: SystemsRuntime.Proc.uuid()

  # ---- Messaging API ----

  @doc "The bot of a channel access token. It proves that the token is valid."
  @spec bot_info(String.t()) :: {:ok, map()} | {:error, term()}
  def bot_info(token), do: request(token, :get, base() <> "/v2/bot/info", [])

  @doc """
  Answers one webhook event with `text` through its reply token: free, and
  LINE takes a token once. Comma uses it for its own account messages
  (connecting, help) to a LINE user that may have no connect.
  """
  @spec reply_text(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reply_text(token, reply_token, text) do
    with {:ok, messages} <- text_messages(text) do
      request(token, :post, base() <> "/v2/bot/message/reply",
        json: %{"replyToken" => str(reply_token), "messages" => messages}
      )
    end
  end

  @doc "The LINE profile (`displayName`) of a user who wrote to the account."
  @spec profile(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def profile(token, user_id),
    do: request(token, :get, base() <> "/v2/bot/profile/" <> URI.encode(str(user_id)), [])

  @doc "The URL of the bytes of a file a person sent (image, video, audio or file)."
  def message_content_url(message_id),
    do: data_base() <> "/v2/bot/message/" <> URI.encode(message_id) <> "/content"

  defp post(connect, path, body, opts \\ []),
    do:
      request(
        str(connect["channel_access_token"]),
        :post,
        base() <> path,
        Keyword.put(opts, :json, body)
      )

  defp request(token, method, url, opts) do
    headers = [{"authorization", "Bearer " <> str(token)} | Keyword.get(opts, :headers, [])]

    req_opts =
      [method: method, url: url, headers: headers, retry: false, receive_timeout: @receive_timeout_ms]
      |> then(fn req -> if opts[:json], do: Keyword.put(req, :json, opts[:json]), else: req end)

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, if(is_map(body), do: body, else: %{})}

      {:ok, %{status: status, body: %{"message" => message}}} ->
        {:error, {:line_api, status, to_string(message)}}

      {:ok, %{status: status}} ->
        {:error, {:line_api, status, "HTTP #{status}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A readable form of a LINE API error."
  def error_text({:line_api, status, message}), do: "LINE API HTTP #{status}: #{message}"
  def error_text(%{__exception__: true} = exception), do: Exception.message(exception)
  def error_text(reason) when is_binary(reason), do: reason
  def error_text(reason), do: inspect(reason)

  defp base,
    do:
      :salix_im
      |> SystemsRuntime.get_env(:line_api_base_url, @default_base)
      |> str()
      |> default_base(@default_base)

  defp data_base,
    do:
      :salix_im
      |> SystemsRuntime.get_env(:line_data_api_base_url, @default_data_base)
      |> str()
      |> default_base(@default_data_base)
end
