defmodule Salix.Bindings.DailyBriefPersonalSource do
  @moduledoc """
  Reads one BFT member's direct and group direct messages with the member's
  own grant, for that member's daily brief, and the member's own messages in
  the shared channels the bot does not read (Slack Connect channels with
  another company), so the brief sees where the member took part.

  Every call loads the grant and checks its tenant, owner, status, and Slack
  user before it reads. The token never leaves this module, and nothing read
  here is stored. A revoked or invalid grant answers `{:error,
  :grant_revoked}`, so BFT can turn direct messages off.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixStore.OAuth, as: Connections
  alias SalixStore.OAuth.Adapters.Slack

  @list_page 200
  @max_list_pages 10
  @history_page 200
  @max_history_pages 5
  @max_retry_after_s 30
  @search_page 100
  @max_search_pages 10
  @max_concurrency 5
  @task_timeout_ms 60_000
  @revoked_errors ~w(invalid_auth token_revoked account_inactive not_authed token_expired missing_scope)

  @doc """
  The member's direct and group direct messages from `after_us` to
  `before_us`, oldest first: every such conversation of theirs is listed,
  then each one's history in the window is read. `complete?` is false when a
  bound ran out or a conversation could not be read.
  """
  @spec direct_messages(map()) :: {:ok, map()} | {:error, term()}
  def direct_messages(%{after_us: after_us, before_us: before_us} = request)
      when is_integer(after_us) and is_integer(before_us) and before_us > after_us do
    with_token(request, fn token ->
      {conversations, listed?} = conversations(token, nil, 1, [])
      oldest = ts(after_us)
      latest = ts(before_us)

      {messages, read?} =
        conversations
        |> SystemsClock.async_stream(
          fn channel ->
            {channel, history(token, channel["id"], oldest, latest, nil, 1, [])}
          end,
          ordered: true,
          max_concurrency: @max_concurrency,
          timeout: @task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.reduce({[], true}, fn
          {:ok, {channel, {:ok, found, complete?}}}, {acc, read?} ->
            kind = kind(channel)
            {acc ++ Enum.map(found, &message_view(&1, channel, kind)), read? and complete?}

          {:ok, {_channel, {:revoked, error}}}, _acc ->
            raise error

          _failed, {acc, _read?} ->
            {acc, false}
        end)

      {shared, searched?} = shared_own(token, request.slack_user_id, after_us, before_us)

      {:ok,
       %{
         messages:
           (messages ++ shared)
           |> Enum.uniq_by(&{&1.channel_id, &1.ts})
           |> Enum.sort_by(&ts_us(&1.ts)),
         complete?: listed? and read? and searched?
       }}
    end)
  end

  def direct_messages(_request), do: {:error, :invalid_request}

  defp conversations(token, cursor, page, acc) do
    result =
      SlackAPI.list_user_conversation_page(token,
        limit: @list_page,
        cursor: cursor,
        types: ["im", "mpim"],
        exclude_archived: true
      )

    # Slack refuses to read the Slackbot direct message with a user token.
    acc =
      acc ++
        Enum.filter(result["channels"], &(kind(&1) != nil and &1["user"] != "USLACKBOT"))

    cond do
      blank?(result["next_cursor"]) -> {acc, true}
      page >= @max_list_pages -> {acc, false}
      true -> conversations(token, result["next_cursor"], page + 1, acc)
    end
  end

  # The member's own messages in public channels shared with another
  # company: the bot is never in those, so only the member's search sees
  # them. Search takes whole days, so the window is cut after.
  defp shared_own(token, slack_user_id, after_us, before_us) do
    first = search_day(after_us, -86_400)
    last = search_day(before_us, 86_400)
    query = "from:<@#{slack_user_id}> after:#{first} before:#{last}"
    {matches, complete?} = search(token, query, 1, [])

    messages =
      for %{"channel" => channel} = match <- matches,
          shared_public?(channel),
          at = ts_us(match["ts"]),
          is_integer(at) and at > after_us and at <= before_us,
          do: shared_view(match, channel)

    {messages, complete?}
  rescue
    error in SlackAPI.Error ->
      if error.message in @revoked_errors, do: reraise(error, __STACKTRACE__), else: {[], false}
  end

  # Search days are exclusive at both ends.
  defp search_day(us, shift),
    do:
      us
      |> div(1_000_000)
      |> Kernel.+(shift)
      |> DateTime.from_unix!()
      |> DateTime.to_date()
      |> Date.to_iso8601()

  defp search(token, query, page, acc) do
    %{matches: matches, more?: more?} =
      with_retry(fn ->
        SlackAPI.search_messages(token, query, count: @search_page, page: page)
      end)

    acc = acc ++ matches

    cond do
      not more? -> {acc, true}
      page >= @max_search_pages -> {acc, false}
      true -> search(token, query, page + 1, acc)
    end
  end

  defp shared_public?(channel) when is_map(channel) do
    channel["is_channel"] == true and channel["is_private"] != true and
      channel["is_mpim"] != true and channel["is_im"] != true and
      (channel["is_ext_shared"] == true or channel["is_shared"] == true)
  end

  defp shared_public?(_channel), do: false

  # A search match has no thread field; its permalink carries the thread.
  defp shared_view(match, channel) do
    permalink = match["permalink"]

    %{
      channel_id: channel["id"],
      channel_name: channel["name"],
      kind: "shared",
      ts: match["ts"],
      thread_ts: thread_of(permalink),
      author: match["user"],
      bot?: false,
      text: match["text"] || "",
      permalink: permalink
    }
  end

  defp thread_of(permalink) when is_binary(permalink) do
    case URI.parse(permalink).query do
      nil -> nil
      query -> URI.decode_query(query)["thread_ts"]
    end
  end

  defp thread_of(_permalink), do: nil

  # One conversation's messages in the window, a page at a time. A rate
  # limit waits as Slack asks once; any other failure leaves it out.
  defp history(token, channel_id, oldest, latest, cursor, page, acc) do
    {messages, next} =
      with_retry(fn ->
        SlackAPI.conversation_history(token, channel_id,
          oldest: oldest,
          latest: latest,
          cursor: cursor,
          limit: @history_page
        )
      end)

    acc = acc ++ messages

    cond do
      blank?(next) -> {:ok, acc, true}
      page >= @max_history_pages -> {:ok, acc, false}
      true -> history(token, channel_id, oldest, latest, next, page + 1, acc)
    end
  rescue
    error in SlackAPI.Error ->
      if error.message in @revoked_errors, do: {:revoked, error}, else: :error
  end

  defp with_retry(read) do
    read.()
  rescue
    error in SlackAPI.Error ->
      if is_integer(error.retry_after) and error.retry_after <= @max_retry_after_s do
        SystemsClock.sleep(error.retry_after * 1_000)
        read.()
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp ts(us), do: "#{div(us, 1_000_000)}.#{String.pad_leading("#{rem(us, 1_000_000)}", 6, "0")}"

  defp kind(%{"is_im" => true}), do: "im"
  defp kind(%{"is_mpim" => true}), do: "mpim"
  defp kind(%{"id" => "D" <> _}), do: "im"
  defp kind(%{"name" => "mpdm-" <> _}), do: "mpim"
  defp kind(_channel), do: nil

  defp message_view(message, channel, kind) do
    %{
      channel_id: channel["id"],
      kind: kind,
      ts: message["ts"],
      thread_ts: message["thread_ts"],
      author: message["user"] || message["bot_id"],
      # An app posts with its bot user as "user", so its bot_id tells it apart.
      bot?: is_binary(message["bot_id"]),
      text: message["text"] || "",
      permalink: nil,
      reactions: reactions(message["reactions"])
    }
  end

  # Who reacted with what: a reaction is often the whole answer.
  defp reactions(list) when is_list(list) do
    for %{"name" => name} = reaction <- list,
        is_binary(name),
        users = Enum.filter(List.wrap(reaction["users"]), &is_binary/1),
        users != [],
        do: %{name: name, users: Enum.take(users, 10)}
  end

  defp reactions(_none), do: []

  defp with_token(request, read) do
    with {:ok, token} <- token(request) do
      try do
        read.(token)
      rescue
        error in SlackAPI.Error ->
          # Slack refused the member's grant itself: the grant records it, so
          # later reads stop at the grant without asking Slack again.
          if Slack.token_refused?("slack.com", 200, %{"ok" => false, "error" => error.message}),
            do: _ = Connections.mark_token_refused(request.connection_id, token)

          reraise(error, __STACKTRACE__)
      end
    end
  rescue
    error in SlackAPI.Error ->
      cond do
        error.message in @revoked_errors -> {:error, :grant_revoked}
        is_integer(error.retry_after) -> {:error, {:rate_limited, error.retry_after}}
        true -> {:error, {:slack, error.message}}
      end
  end

  defp token(%{
         tenant_id: tenant_id,
         connection_id: connection_id,
         bft_member: %{org_id: org_id, member_id: member_id, user_id: user_id},
         slack_user_id: slack_user_id
       })
       when is_binary(tenant_id) and is_binary(connection_id) and is_binary(slack_user_id) do
    owner = %{"org_id" => org_id, "member_id" => member_id, "user_id" => user_id}

    case Connections.get(connection_id) do
      {:ok, %{"tenant" => ^tenant_id, "bft_member" => ^owner, "provider" => "slack"} = conn} ->
        # The Slack adapter's account fields sit under the connection's metadata.
        authed =
          get_in(conn, ["metadata", "metadata", "authed_user_id"]) ||
            conn["provider_account_id"]

        token = conn["slack_user_token"] || conn["access_token"]

        cond do
          conn["status"] != "active" -> {:error, :grant_revoked}
          authed != slack_user_id -> {:error, :grant_revoked}
          blank?(token) -> {:error, :grant_revoked}
          true -> {:ok, token}
        end

      {:ok, _other} ->
        {:error, :grant_revoked}

      {:error, :not_found} ->
        {:error, :grant_revoked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp token(_request), do: {:error, :invalid_request}

  defp ts_us(ts) when is_binary(ts) do
    case Regex.run(~r/^(\d{1,12})\.(\d{1,6})$/, ts) do
      [_, seconds, micros] ->
        String.to_integer(seconds) * 1_000_000 +
          String.to_integer(String.pad_trailing(micros, 6, "0"))

      nil ->
        nil
    end
  end

  defp ts_us(_ts), do: nil

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
