defmodule SalixIM.LarkSuiteDailyBrief do
  @moduledoc """
  The read and post paths of the BFT daily brief for Feishu and Lark, shared
  by `SalixIM.FeishuDailyBriefSource`, `SalixIM.LarkDailyBriefSource`,
  `SalixIM.FeishuDailyBriefSurface` and `SalixIM.LarkDailyBriefSurface`.
  Each public module passes its own provider: its connect kind, API module,
  message mirror and backfill ledger. Nothing here is shared with Slack.

  Only internal public group chats that the connect's bot belongs to are
  readable: `chat_mode` group or topic, `chat_type` public, not external,
  and not dissolved. A private group, an external group, and a one-to-one
  chat are never read and never posted to as a team brief. Message text
  comes from the provider's message mirror; every read checks the active
  connect and the chat's current audience first.

  Feishu and Lark do not let the bot read a person's own chats, so the
  coverage gap of `channels/1` is always empty and nothing reads direct
  messages.
  """

  alias SalixIM.ProviderConnects

  @chat_page_size 100
  # Each listed chat costs one detail read; past 300 chats the list says it
  # is incomplete and the admin pastes a group ID.
  @max_chat_pages 3
  @max_window_limit 200
  @max_member_threads 500
  @max_emails 50
  @max_users 200
  @max_concurrency 8
  @chat_info_concurrency 16
  @task_timeout_ms 15_000
  @id ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @type provider :: %{
          required(:provider) => String.t(),
          required(:api) => module(),
          required(:reader) => (-> module() | nil),
          required(:ledger) => module(),
          required(:applink) => String.t(),
          required(:default_timezone) => String.t()
        }

  ## Source

  @doc "The bot's readable chats. Feishu and Lark show no member's own chats: gaps are empty."
  @spec channels(provider(), map()) :: {:ok, map()} | {:error, term()}
  def channels(provider, request) do
    with {:ok, connect} <- fetch_connect(provider, request),
         {:ok, chats, complete?} <- list_chats(provider, connect) do
      readable =
        chats
        |> Enum.filter(&listed_candidate?/1)
        |> SystemsClock.async_stream(
          fn chat ->
            case chat_info(provider, connect, chat["chat_id"]) do
              {:ok, info} -> if readable_info?(info), do: chat_view(chat, info)
              _unreadable -> nil
            end
          end,
          max_concurrency: @chat_info_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, %{} = view} -> [view]
          _other -> []
        end)

      member_ids = List.wrap(request[:member_open_ids])

      {:ok,
       %{
         app_id: connect["app_id"],
         channels: readable,
         complete?: complete?,
         gaps: Map.new(member_ids, &{&1, %{channels: [], complete?: true}})
       }}
    end
  end

  @doc """
  One page of a chat's current messages in `[after_us, before_us)`, oldest
  first, thread replies included. Recalled messages are absent.
  """
  @spec read_window(provider(), map()) :: {:ok, map()} | {:error, term()}
  def read_window(
        provider,
        %{channel_id: chat_id, after_us: after_us, before_us: before_us, limit: limit} = request
      )
      when is_binary(chat_id) and is_integer(after_us) and is_integer(before_us) and
             after_us >= 0 and before_us > after_us and is_integer(limit) and
             limit in 1..@max_window_limit do
    with {:ok, connect} <- fetch_connect(provider, request),
         :ok <- chat_readable(provider, connect, chat_id),
         {:ok, reader} <- reader(provider),
         scope = scope(connect),
         :ok <- archive_covers(provider, scope, chat_id, after_us),
         {:ok, page} <-
           reader_result(
             reader.search(
               scope,
               [
                 chat_id: chat_id,
                 after_us: max(after_us, 1),
                 before_us: before_us,
                 sort_dir: :asc,
                 limit: limit
               ] ++ cursor_opts(request[:cursor])
             )
           ) do
      {:ok,
       %{
         messages: page.messages |> Enum.filter(&(&1["create_time_us"] > 0)) |> Enum.map(&view/1),
         next_cursor: cursor_view(page.next_cursor),
         has_more?: page.has_more? == true
       }}
    end
  end

  def read_window(_provider, _request), do: {:error, :invalid_request}

  @doc "The current state of named messages (`ts` are message ids) in one readable chat."
  @spec messages(provider(), map()) :: {:ok, map()} | {:error, term()}
  def messages(provider, %{channel_id: chat_id, ts: ids} = request)
      when is_binary(chat_id) and is_list(ids) and length(ids) in 1..@max_window_limit do
    with true <- Enum.all?(ids, &id?/1) || {:error, :invalid_request},
         {:ok, connect} <- fetch_connect(provider, request),
         :ok <- chat_readable(provider, connect, chat_id),
         {:ok, reader} <- reader(provider),
         {:ok, rows} <- reader_result(reader.messages(scope(connect), chat_id, Enum.uniq(ids))) do
      {:ok, %{messages: Enum.map(rows, &view/1)}}
    end
  end

  def messages(_provider, _request), do: {:error, :invalid_request}

  @doc """
  Of the `threads` (chat id and root message id, at most 500), the ones the
  member wrote in. No text returns.
  """
  @spec member_threads(provider(), map()) :: {:ok, map()} | {:error, term()}
  def member_threads(provider, %{open_id: open_id, threads: threads} = request)
      when is_binary(open_id) and is_list(threads) and length(threads) <= @max_member_threads do
    pairs =
      for %{channel_id: chat, thread_ts: root} <- threads,
          id?(chat) and id?(root),
          uniq: true,
          do: {chat, root}

    with true <- id?(open_id) || {:error, :invalid_request},
         {:ok, connect} <- fetch_connect(provider, request),
         {:ok, wrote} <- participation(provider, scope(connect), open_id, pairs) do
      {:ok,
       %{
         threads: for({chat, root} <- wrote, do: %{channel_id: chat, thread_ts: root}),
         complete?: true
       }}
    end
  end

  def member_threads(_provider, _request), do: {:error, :invalid_request}

  @doc "How many messages each member wrote in each readable chat since `after_us`. Counts only."
  @spec active_channels(provider(), map()) :: {:ok, map()} | {:error, term()}
  def active_channels(
        provider,
        %{open_ids: open_ids, channel_ids: chat_ids, after_us: after_us} = request
      )
      when is_list(open_ids) and length(open_ids) <= 500 and is_list(chat_ids) and
             length(chat_ids) <= 2_000 and is_integer(after_us) and after_us >= 0 do
    with {:ok, connect} <- fetch_connect(provider, request),
         {:ok, rows} <- counts(provider, scope(connect), open_ids, chat_ids, after_us) do
      {:ok,
       rows
       |> Enum.group_by(&elem(&1, 1), fn {chat, _user, n} -> %{channel_id: chat, count: n} end)
       |> Map.new(fn {user, counts} -> {user, Enum.sort_by(counts, &(-&1.count))} end)}
    end
  end

  def active_channels(_provider, _request), do: {:error, :invalid_request}

  @doc """
  Resolves BFT emails to people of the connect's tenant: open id, names, and
  time zone. Frozen, resigned, and inactive people are not returned.
  """
  @spec lookup_members(provider(), map()) :: {:ok, map()} | {:error, term()}
  def lookup_members(provider, %{emails: emails} = request)
      when is_list(emails) and length(emails) <= @max_emails do
    with {:ok, connect} <- fetch_connect(provider, request) do
      emails = emails |> Enum.map(&normalize_email/1) |> Enum.uniq() |> Enum.reject(&(&1 == ""))

      case emails do
        [] ->
          {:ok, %{}}

        emails ->
          with {:ok, data} <-
                 api_result(
                   provider.api.post(
                     connect,
                     "/contact/v3/users/batch_get_id?user_id_type=open_id",
                     %{"emails" => emails}
                   )
                 ) do
            {:ok,
             data
             |> Map.get("user_list", [])
             |> List.wrap()
             |> Enum.flat_map(fn
               %{"user_id" => "ou_" <> _ = open_id, "email" => email} when is_binary(email) ->
                 [{normalize_email(email), open_id}]

               _other ->
                 []
             end)
             |> Enum.filter(fn {email, _open_id} -> email in emails end)
             |> Enum.uniq_by(&elem(&1, 0))
             |> SystemsClock.async_stream(
               fn {email, open_id} ->
                 case member(provider, connect, open_id) do
                   {:ok, member} -> {email, member}
                   :error -> nil
                 end
               end,
               max_concurrency: @max_concurrency,
               timeout: @task_timeout_ms,
               on_timeout: :kill_task
             )
             |> Enum.reduce(%{}, fn
               {:ok, {email, member}}, acc -> Map.put(acc, email, member)
               _other, acc -> acc
             end)}
          end
      end
    end
  end

  def lookup_members(_provider, _request), do: {:error, :invalid_request}

  @doc "The names the directory shows for open ids of the connect's tenant. At most 200."
  @spec user_names(provider(), map()) :: {:ok, map()} | {:error, term()}
  def user_names(provider, %{user_ids: ids} = request)
      when is_list(ids) and length(ids) <= @max_users do
    with {:ok, connect} <- fetch_connect(provider, request) do
      {:ok,
       ids
       |> Enum.uniq()
       |> Enum.filter(&match?("ou_" <> _, &1))
       |> Enum.filter(&id?/1)
       |> SystemsClock.async_stream(
         fn open_id ->
           case user(provider, connect, open_id) do
             {:ok, user} -> if name = present(user["name"]), do: {open_id, name}
             :error -> nil
           end
         end,
         max_concurrency: @max_concurrency,
         timeout: @task_timeout_ms,
         on_timeout: :kill_task
       )
       |> Enum.reduce(%{}, fn
         {:ok, {id, name}}, acc -> Map.put(acc, id, name)
         _other, acc -> acc
       end)}
    end
  end

  def user_names(_provider, _request), do: {:error, :invalid_request}

  @doc """
  Links that open each named message's chat in the app, for readable chats.
  Feishu and Lark give the bot no link to one message, so the link opens
  its chat. At most 50.
  """
  @spec permalinks(provider(), map()) :: {:ok, map()} | {:error, term()}
  def permalinks(provider, %{messages: messages} = request)
      when is_list(messages) and length(messages) <= 50 do
    with {:ok, connect} <- fetch_connect(provider, request) do
      readable =
        messages
        |> Enum.map(& &1.channel_id)
        |> Enum.uniq()
        |> SystemsClock.async_stream(
          fn chat_id -> if chat_readable(provider, connect, chat_id) == :ok, do: chat_id end,
          max_concurrency: @max_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.reduce(MapSet.new(), fn
          {:ok, chat_id}, acc when is_binary(chat_id) -> MapSet.put(acc, chat_id)
          _other, acc -> acc
        end)

      {:ok,
       for(
         %{channel_id: chat_id, ts: id} <- messages,
         MapSet.member?(readable, chat_id),
         into: %{},
         do: {{chat_id, id}, chat_link(provider, chat_id)}
       )}
    end
  end

  def permalinks(_provider, _request), do: {:error, :invalid_request}

  @doc "The link that opens a chat in the provider's app."
  @spec chat_link(provider(), String.t()) :: String.t()
  def chat_link(provider, chat_id),
    do: provider.applink <> "/client/chat/open?" <> URI.encode_query(openChatId: chat_id)

  ## Surface

  @doc """
  Posts one brief card: to a member by `open_id`, or the team brief to a
  readable public group by `channel_id`.
  """
  @spec post(provider(), map()) :: {:ok, map()} | {:error, term()}
  def post(provider, %{open_id: open_id, card: card} = request)
      when is_binary(open_id) and is_map(card) do
    with true <- match?("ou_" <> _, open_id) || {:error, :invalid_request},
         {:ok, connect} <- fetch_connect(provider, request) do
      send_card(provider, connect, "open_id", open_id, card)
    end
  end

  def post(provider, %{channel_id: chat_id, card: card} = request)
      when is_binary(chat_id) and is_map(card) do
    with {:ok, connect} <- fetch_connect(provider, request),
         :ok <- chat_readable(provider, connect, chat_id) do
      send_card(provider, connect, "chat_id", chat_id, card)
    end
  end

  def post(_provider, _request), do: {:error, :invalid_request}

  defp send_card(provider, connect, id_type, receive_id, card) do
    case provider.api.post(connect, "/im/v1/messages?receive_id_type=" <> id_type, %{
           "receive_id" => receive_id,
           "msg_type" => "interactive",
           "content" => Jason.encode!(card)
         }) do
      {:ok, %{"message_id" => message_id} = data} when is_binary(message_id) ->
        {:ok, %{channel_id: present(data["chat_id"]) || receive_id, ts: message_id}}

      {:ok, _unexpected} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Chats

  @doc """
  `:ok` when the chat is an internal public group the bot is in: the only
  kind a brief reads or posts the team brief to.
  """
  @spec chat_readable(provider(), map(), String.t()) :: :ok | {:error, :channel_ineligible}
  def chat_readable(provider, connect, chat_id) when is_binary(chat_id) do
    with true <- id?(chat_id) and String.starts_with?(chat_id, "oc_"),
         {:ok, info} <- chat_info(provider, connect, chat_id),
         true <- readable_info?(info),
         {:ok, %{"is_in_chat" => true}} <-
           provider.api.get(connect, "/im/v1/chats/#{chat_id}/members/is_in_chat") do
      :ok
    else
      _ineligible -> {:error, :channel_ineligible}
    end
  end

  def chat_readable(_provider, _connect, _chat_id), do: {:error, :channel_ineligible}

  defp list_chats(provider, connect) do
    Enum.reduce_while(1..@max_chat_pages, {[], nil}, fn page, {acc, token} ->
      case provider.api.get(connect, "/im/v1/chats", %{
             page_size: @chat_page_size,
             page_token: token
           }) do
        {:ok, data} when is_map(data) ->
          acc = acc ++ Enum.filter(List.wrap(data["items"]), &is_map/1)
          next = present(data["page_token"])

          cond do
            data["has_more"] != true or is_nil(next) -> {:halt, {:ok, acc, true}}
            page == @max_chat_pages -> {:halt, {:ok, acc, false}}
            true -> {:cont, {acc, next}}
          end

        {:ok, _unexpected} ->
          {:halt, {:error, :source_unavailable}}

        {:error, reason} ->
          {:halt, provider_error(reason)}
      end
    end)
  end

  defp chat_info(provider, connect, chat_id) do
    case provider.api.get(connect, "/im/v1/chats/#{chat_id}") do
      {:ok, info} when is_map(info) -> {:ok, info}
      _unreadable -> :error
    end
  end

  # The list says enough to drop external and dissolved groups before any
  # per-chat read.
  defp listed_candidate?(chat) do
    id?(chat["chat_id"]) and String.starts_with?(chat["chat_id"], "oc_") and
      chat["external"] != true and chat["chat_status"] in [nil, "normal"]
  end

  @doc false
  # An internal public group, never a private, external, or one-to-one chat.
  def readable_info?(info) when is_map(info) do
    info["chat_mode"] in ["group", "topic"] and info["chat_type"] == "public" and
      info["external"] != true and info["chat_status"] in [nil, "normal"]
  end

  def readable_info?(_info), do: false

  defp chat_view(chat, info),
    do: %{
      id: chat["chat_id"],
      name: present(info["name"]) || present(chat["name"]) || chat["chat_id"]
    }

  ## People

  defp member(provider, connect, open_id) do
    with {:ok, user} <- user(provider, connect, open_id),
         true <- active?(user) do
      {:ok,
       %{
         open_id: open_id,
         app_id: connect["app_id"],
         timezone: present(user["time_zone"]) || provider.default_timezone,
         names:
           [user["name"], user["nickname"], user["en_name"]]
           |> Enum.map(&present/1)
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
       }}
    else
      _inactive -> :error
    end
  end

  defp user(provider, connect, open_id) do
    case provider.api.get(connect, "/contact/v3/users/#{open_id}", %{user_id_type: "open_id"}) do
      {:ok, %{"user" => user}} when is_map(user) -> {:ok, user}
      _unreadable -> :error
    end
  end

  defp active?(user) do
    status = if is_map(user["status"]), do: user["status"], else: %{}

    status["is_frozen"] != true and status["is_resigned"] != true and
      status["is_activated"] != false and status["is_exited"] != true
  end

  ## Mirror

  defp reader(provider) do
    case provider.reader.() do
      reader when is_atom(reader) and not is_nil(reader) -> {:ok, reader}
      _none -> {:error, :source_unavailable}
    end
  end

  defp reader_result({:ok, result}), do: {:ok, result}
  defp reader_result({:error, _reason}), do: {:error, :source_unavailable}

  defp archive_covers(provider, scope, chat_id, after_us) do
    case provider.ledger.coverage(scope, chat_id, after_us) do
      {:ok, :complete} -> :ok
      _not_covered -> {:error, :source_unavailable}
    end
  end

  defp participation(_provider, _scope, _open_id, []), do: {:ok, []}

  defp participation(provider, scope, open_id, pairs) do
    with {:ok, reader} <- reader(provider) do
      reader_result(reader.thread_participation(scope, open_id, pairs))
    end
  end

  defp counts(_provider, _scope, [], _chat_ids, _after_us), do: {:ok, []}
  defp counts(_provider, _scope, _open_ids, [], _after_us), do: {:ok, []}

  defp counts(provider, scope, open_ids, chat_ids, after_us) do
    with {:ok, reader} <- reader(provider) do
      reader_result(
        reader.actor_chat_counts(
          scope,
          Enum.filter(open_ids, &id?/1),
          Enum.filter(chat_ids, &id?/1),
          after_us
        )
      )
    end
  end

  # A mirror row, in the shape of the Slack source's messages: `ts` is the
  # message id and `thread_ts` the thread's root message id; `at_us` is when
  # it was sent.
  defp view(row) do
    root = present(row["root_id"])

    %{
      channel_id: row["chat_id"],
      ts: row["message_id"],
      thread_ts: if(root && root != row["message_id"], do: root),
      at_us: row["create_time_us"],
      actor_kind: if(row["actor_kind"] in ["app", "bot"], do: "bot", else: "user"),
      actor_id: present(row["actor_id"]),
      actor_label: present(row["actor_label"]),
      subtype: nil,
      text: row["text"] || "",
      mentions: mentions(row["content"], row["text"]),
      reactions: []
    }
  end

  # Rich-text messages keep each mention's open id in their content, as an
  # `at` node or, in card Markdown, an inline `<at id=ou_…>`; a plain text
  # message keeps only the name, which aliases match.
  @inline_at ~r/<at\s+(?:user_)?id=\\?["']?(ou_[A-Za-z0-9_-]+)/

  defp mentions(content, text) do
    (at_nodes(content) ++ inline_at(content) ++ inline_at(text)) |> Enum.uniq()
  end

  defp at_nodes(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, decoded} -> collect_at(decoded, [])
      _invalid -> []
    end
  end

  defp at_nodes(_content), do: []

  defp inline_at(value) when is_binary(value),
    do: @inline_at |> Regex.scan(value, capture: :all_but_first) |> List.flatten()

  defp inline_at(_value), do: []

  defp collect_at(%{"tag" => "at", "user_id" => "ou_" <> _ = id} = node, acc),
    do: collect_at(Map.delete(node, "user_id"), [id | acc])

  defp collect_at(map, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &collect_at/2)

  defp collect_at(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_at/2)
  defp collect_at(_value, acc), do: acc

  defp cursor_opts(%{ts_us: ts_us, message_id: id}) when is_integer(ts_us) and is_binary(id),
    do: [cursor_ts_us: ts_us, cursor_message_id: id]

  defp cursor_opts(_cursor), do: []

  defp cursor_view({ts_us, id}), do: %{ts_us: ts_us, message_id: id}
  defp cursor_view(_cursor), do: nil

  defp scope(connect),
    do: %{"tenant_id" => connect["tenant_id"], "app_id" => connect["app_id"]}

  ## Connect

  defp fetch_connect(provider, %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id})
       when is_binary(tenant_id) and is_binary(group_id) and is_binary(connect_id) do
    case ProviderConnects.get_active_connect_by_id(group_id, connect_id, provider.provider) do
      {:ok, %{"tenant_id" => ^tenant_id, "app_id" => app_id} = connect}
      when is_binary(app_id) and app_id != "" ->
        {:ok, connect}

      {:ok, _other} ->
        {:error, :source_unavailable}

      {:error, :not_found} ->
        {:error, :source_unavailable}

      {:error, _reason} ->
        {:error, :source_authority_unavailable}
    end
  end

  defp fetch_connect(_provider, _request), do: {:error, :invalid_request}

  defp api_result({:ok, data}) when is_map(data), do: {:ok, data}
  defp api_result({:ok, _unexpected}), do: {:error, :source_unavailable}
  defp api_result({:error, reason}), do: provider_error(reason)

  # Feishu and Lark answer a rate limit with code 99991400.
  defp provider_error(reason) when is_binary(reason) do
    if String.contains?(reason, "99991400"),
      do: {:error, {:rate_limited, 5}},
      else: {:error, :source_unavailable}
  end

  defp provider_error(_reason), do: {:error, :source_unavailable}

  defp id?(value), do: is_binary(value) and Regex.match?(@id, value)

  defp normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil
end
