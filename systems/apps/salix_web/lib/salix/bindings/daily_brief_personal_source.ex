defmodule Salix.Bindings.DailyBriefPersonalSource do
  @moduledoc """
  Reads one BFT member's direct and group direct messages with the member's
  own grant, for that member's daily brief.

  Every call loads the grant and checks its tenant, owner, status, and Slack
  user before it reads. The token never leaves this module, and nothing read
  here is stored. A revoked or invalid grant answers `{:error,
  :grant_revoked}`, so BFT can turn direct messages off.
  """

  alias SalixIM.Provider.Slack.API, as: SlackAPI
  alias SalixStore.OAuth, as: Connections

  @list_page 200
  @max_list_pages 10
  @history_page 200
  @max_history_pages 5
  @max_retry_after_s 30
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

      {messages, read?} =
        Enum.reduce(conversations, {[], true}, fn channel, {acc, read?} ->
          case history(token, channel["id"], ts(after_us), ts(before_us), nil, 1, []) do
            {:ok, found, complete?} ->
              kind = kind(channel)
              {acc ++ Enum.map(found, &message_view(&1, channel, kind)), read? and complete?}

            :error ->
              {acc, false}
          end
        end)

      {:ok,
       %{
         messages:
           messages |> Enum.uniq_by(&{&1.channel_id, &1.ts}) |> Enum.sort_by(&ts_us(&1.ts)),
         complete?: listed? and read?
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
      if error.message in @revoked_errors, do: reraise(error, __STACKTRACE__), else: :error
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
      bot?: is_binary(message["bot_id"]) and is_nil(message["user"]),
      text: message["text"] || "",
      permalink: nil
    }
  end

  defp with_token(request, read) do
    with {:ok, token} <- token(request) do
      read.(token)
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
