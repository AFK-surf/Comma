defmodule CommaWeb.RecommendationGoogleMemberSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, RecommendationSourceQuote}

  # Official Google APIs through the account-pinned proxy. Each read uses the
  # provider-asserted self identity of the same consented account.
  @gmail "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar "https://www.googleapis.com/calendar/v3/calendars/primary"
  @drive "https://www.googleapis.com/drive/v3"
  @week 7 * 86_400
  @awaiting "in:inbox to:me -category:promotions newer_than:7d"
  @spam "in:spam to:me newer_than:7d"
  @window 15
  @junk 10

  # Recent inbox mail to the member, read or not. Provider importance and social
  # categories do not decide whether a matter needs the member. As before,
  # the thread's latest message is not one the member sent. One item per thread.
  # Important mail keeps its own read window and precedes ordinary mail within
  # the byte budget. Important threads alone can still exceed that budget.
  # The most recent spam follows it, marked as junk.
  def read("gmail", request, _now) do
    [profile, important, recent, spam] =
      RecommendationMemberRead.map(
        [
          @gmail <> "/profile",
          threads_url("is:important " <> @awaiting),
          threads_url(@awaiting),
          threads_url(@spam, @junk)
        ],
        &request.("GET", &1, []),
        4
      )

    with {:ok, %{"emailAddress" => email}} when is_binary(email) and email != "" <- profile,
         {:ok, important} when is_map(important) <- important,
         {:ok, recent} when is_map(recent) <- recent do
      results =
        (List.wrap(important["threads"]) ++ List.wrap(recent["threads"]))
        |> Enum.filter(&(is_map(&1) and valid_id?(&1["id"])))
        |> Enum.uniq_by(& &1["id"])
        |> RecommendationMemberRead.map(
          &request.("GET", @gmail <> "/threads/" <> &1["id"] <> "?format=full", []),
          8
        )
        |> Enum.map(fn
          {:ok, thread} when is_map(thread) -> awaiting(thread, email)
          _unreadable -> :missing
        end)

      readable = for {:ok, item} <- results, do: item
      missing = Enum.count(results, &(&1 == :missing))

      # Keep readable mail, but never report an unreadable mailbox as caught up.
      if readable != [] or missing == 0 do
        data = %{
          "messages" => readable ++ spam_items(spam, request, readable, email),
          "memberRelation" => "awaiting_your_reply"
        }

        data =
          if missing == 0,
            do: data,
            else: Map.put(data, :source_warnings, [:member_source_context_unavailable])

        {:ok, data, %{"provider_mailbox" => email}}
      else
        {:error, :member_source_context_unavailable}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  def read("googlecalendar", request, now) do
    [calendar, events] =
      RecommendationMemberRead.map(
        [
          @calendar,
          @calendar <>
            "/events?" <>
            URI.encode_query(%{
              "maxResults" => 40,
              "singleEvents" => true,
              "orderBy" => "startTime",
              "showDeleted" => false,
              "timeMin" => DateTime.to_iso8601(now),
              "timeMax" => now |> DateTime.add(@week) |> DateTime.to_iso8601()
            })
        ],
        &request.("GET", &1, []),
        2
      )

    with {:ok, %{"id" => calendar}} when is_binary(calendar) and calendar != "" <- calendar,
         {:ok, %{"items" => items}} when is_list(items) <- events do
      selected =
        items
        |> Enum.filter(fn event ->
          is_map(event) and event["status"] in ~w(confirmed tentative) and
            event["eventType"] in [nil, "default"] and is_binary(event["htmlLink"]) and
            is_list(Map.get(event, "attendees", [])) and
            not Enum.any?(
              Map.get(event, "attendees", []),
              &(is_map(&1) and &1["self"] == true and &1["responseStatus"] == "declined")
            ) and
            (get_in(event, ["organizer", "self"]) == true or
               Enum.any?(Map.get(event, "attendees", []), &(is_map(&1) and &1["self"] == true)))
        end)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.take(40)
        |> Enum.map(fn item ->
          item
          |> CommaWeb.RecommendationSourceContext.attach(~w(status description location))
          |> Map.take(~w(id summary htmlLink start end context))
          |> RecommendationSourceQuote.put(
            title: item["summary"],
            body: {:html, item["description"]}
          )
        end)

      {:ok, %{"items" => selected, "memberRelation" => "your_upcoming_events"},
       %{"provider_calendar_id" => calendar}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  # Owned files and comment mentions are independent: either one keeps the
  # source readable, with a partial-source warning for the other.
  def read("googledrive", request, now) do
    since = now |> DateTime.add(-@week) |> DateTime.to_iso8601()

    [about, owned, recent] =
      RecommendationMemberRead.map(
        [
          @drive <> "/about?fields=user",
          @drive <>
            "/files?" <>
            URI.encode_query(%{
              "q" => "trashed = false and 'me' in owners and modifiedTime > '#{since}'",
              "pageSize" => 40,
              "orderBy" => "modifiedTime desc",
              "fields" =>
                "files(id,name,webViewLink,modifiedTime,owners(permissionId),trashed,description)"
            }),
          @drive <>
            "/files?" <>
            URI.encode_query(%{
              "q" => "trashed = false and modifiedTime > '#{since}'",
              "pageSize" => 5,
              "orderBy" => "modifiedTime desc",
              "fields" => "files(id,name,webViewLink,modifiedTime)"
            })
        ],
        &request.("GET", &1, []),
        3
      )

    {owned, owned_failures} = drive_files(owned)
    {recent, recent_failures} = drive_files(recent)

    with {:ok, %{"user" => %{"permissionId" => user} = me}} when is_binary(user) and user != "" <-
           about,
         false <- owned_failures != [] and recent_failures != [] do
      {mentions, comment_failures} = drive_mentions(request, recent, me["emailAddress"], since)

      selected =
        owned
        |> Enum.filter(fn file ->
          is_map(file) and file["trashed"] != true and is_binary(file["webViewLink"]) and
            is_list(file["owners"]) and
            Enum.any?(file["owners"], &(is_map(&1) and &1["permissionId"] == user))
        end)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.take(40)
        |> Enum.map(fn item ->
          item
          |> CommaWeb.RecommendationSourceContext.attach(~w(description))
          |> Map.take(~w(id name webViewLink modifiedTime context))
          |> Map.put("memberRelation", "your_recently_changed_file")
          |> RecommendationSourceQuote.put(
            title: item["name"],
            body: {:plain, item["description"]}
          )
        end)

      {:ok,
       RecommendationMemberRead.warn(
         %{
           "files" => Enum.uniq_by(mentions ++ selected, & &1["id"]),
           "memberRelation" => "your_files_or_mentions"
         },
         owned_failures ++ recent_failures ++ comment_failures
       ), %{"provider_user_id" => user}}
    else
      true -> {:error, hd(owned_failures)}
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  # A spam read that fails only leaves spam out; the inbox decides readability.
  defp spam_items({:ok, %{"threads" => threads}}, request, inbox, email) when is_list(threads) do
    seen = MapSet.new(inbox, & &1["threadId"])

    threads
    |> Enum.filter(&(is_map(&1) and valid_id?(&1["id"]) and not MapSet.member?(seen, &1["id"])))
    |> Enum.uniq_by(& &1["id"])
    |> RecommendationMemberRead.map(
      &request.("GET", @gmail <> "/threads/" <> &1["id"] <> "?format=full", []),
      8
    )
    |> Enum.flat_map(fn
      {:ok, %{"id" => thread, "messages" => [_ | _] = messages}} when is_binary(thread) ->
        latest = Enum.max_by(messages, &internal_ms/1)
        labels = if is_map(latest), do: latest["labelIds"], else: nil

        with true <- is_list(labels) and valid_id?(latest["id"]),
             true <- "SPAM" in labels and "SENT" not in labels,
             {:ok, item} <- mail_item(latest, thread, email, "spam") do
          [Map.put(item, "memberRelation", "in_your_junk_folder")]
        else
          _ -> []
        end

      _unreadable ->
        []
    end)
  end

  defp spam_items(_spam, _request, _inbox, _email), do: []

  defp threads_url(query, limit \\ @window),
    do: @gmail <> "/threads?" <> URI.encode_query(%{"q" => query, "maxResults" => limit})

  defp drive_files({:ok, %{"files" => files}}) when is_list(files), do: {files, []}
  defp drive_files({:error, reason}), do: {[], [reason]}
  defp drive_files(_response), do: {[], [:invalid_provider_response]}

  # The thread's latest message decides: one the member sent closes the thread.
  defp awaiting(%{"id" => thread, "messages" => [_ | _] = messages}, email)
       when is_binary(thread) do
    latest = Enum.max_by(messages, &internal_ms/1)
    labels = if is_map(latest), do: latest["labelIds"], else: nil

    cond do
      not (is_list(labels) and valid_id?(latest["id"])) ->
        :missing

      "SENT" in labels or
        "INBOX" not in labels or
          Enum.any?(~w(CATEGORY_PROMOTIONS SPAM TRASH), &(&1 in labels)) ->
        :closed

      true ->
        mail_item(latest, thread, email, "inbox")
    end
  end

  defp awaiting(_thread, _email), do: :missing

  defp mail_item(message, thread, email, folder) do
    headers =
      Map.new(
        List.wrap(get_in(message, ["payload", "headers"])),
        &{String.downcase(&1["name"] || ""), &1["value"]}
      )

    text =
      case CommaWeb.ProactiveMailSource.text(message) do
        {:ok, text} -> text
        _ -> nil
      end

    item = %{
      "messageId" => message["id"],
      "threadId" => thread,
      "subject" => headers["subject"],
      "sender" => headers["from"],
      "messageTimestamp" => timestamp(message["internalDate"]),
      "snippet" => message["snippet"],
      "messageText" => text
    }

    if mail_context?(item) do
      {:ok,
       item
       # The snippet repeats the start of the text; it stands in only without one.
       |> CommaWeb.RecommendationSourceContext.attach(
         if(is_binary(text) and text != "", do: ~w(sender messageText), else: ~w(sender snippet))
       )
       |> Map.take(~w(messageId threadId subject sender messageTimestamp context))
       |> Map.put(
         "webUrl",
         "https://mail.google.com/mail/?authuser=" <>
           URI.encode_www_form(email) <> "#" <> folder <> "/" <> message["id"]
       )
       |> RecommendationSourceQuote.put(
         title: item["subject"],
         author: sender_name(item["sender"]),
         body: CommaWeb.ProactiveMailSource.quote_body(message) || {:html, item["snippet"]}
       )}
    else
      :missing
    end
  end

  # "Alex Chen <alex@example.com>" is Alex Chen. An address alone stays.
  defp sender_name(from) when is_binary(from) do
    case Regex.run(~r/^\s*"?([^"<]*?)"?\s*<[^>]+>\s*$/u, from) do
      [_, name] when name != "" -> name
      _ -> from
    end
  end

  defp sender_name(_from), do: nil

  defp internal_ms(%{"internalDate" => value}) do
    case Integer.parse(to_string(value)) do
      {ms, ""} -> ms
      _ -> 0
    end
  end

  defp internal_ms(_message), do: 0

  defp timestamp(value) do
    case Integer.parse(to_string(value)) do
      {ms, ""} -> ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  # Comments do not surface in a file search, so the five most recently changed
  # files are read. A file without comment access contributes none. Other
  # failures are reported, because they leave mentions unread.
  defp drive_mentions(request, files, email, since) when is_binary(email) and email != "" do
    email = String.downcase(email)

    results =
      files
      |> Enum.filter(&(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["webViewLink"])))
      |> RecommendationMemberRead.map(
        fn file ->
          {file,
           request.(
             "GET",
             @drive <>
               "/files/" <>
               URI.encode(file["id"], &URI.char_unreserved?/1) <>
               "/comments?" <>
               URI.encode_query(%{
                 "startModifiedTime" => since,
                 "pageSize" => 20,
                 "fields" =>
                   "comments(id,content,htmlContent,resolved,modifiedTime,author(me)," <>
                     "replies(content,htmlContent,modifiedTime,author(me)))"
               }),
             []
           )}
        end,
        5
      )

    mentions =
      results
      |> Enum.flat_map(fn
        {file, {:ok, %{"comments" => comments}}} when is_list(comments) ->
          Enum.flat_map(comments, &drive_mention(file, &1, email))

        _unreadable ->
          []
      end)
      |> Enum.take(10)

    failures =
      for {_file, {:error, reason}} <- results,
          not match?({:member_provider_http, status} when status in [403, 404], reason),
          do: reason

    {mentions, failures}
  end

  defp drive_mentions(_request, _files, _email, _since), do: {[], []}

  # The latest open comment or reply by someone else that names the member.
  defp drive_mention(file, %{"id" => id} = comment, email) when is_binary(id) do
    latest =
      [comment | List.wrap(comment["replies"])]
      |> Enum.filter(fn entry ->
        is_map(entry) and get_in(entry, ["author", "me"]) != true and
          Enum.any?(~w(content htmlContent), fn key ->
            is_binary(entry[key]) and String.contains?(String.downcase(entry[key]), email)
          end)
      end)
      |> List.last()

    separator = if String.contains?(file["webViewLink"], "?"), do: "&", else: "?"

    if comment["resolved"] != true and is_map(latest) and is_binary(latest["content"]) do
      [
        %{
          "id" => file["id"] <> ":" <> id,
          "name" => file["name"],
          "webViewLink" => file["webViewLink"] <> separator <> "disco=" <> id,
          "modifiedTime" => latest["modifiedTime"] || comment["modifiedTime"],
          "mention" => latest["content"],
          "memberRelation" => "mentioned_you"
        }
        |> CommaWeb.RecommendationSourceContext.attach(~w(mention))
        |> Map.delete("mention")
        |> RecommendationSourceQuote.put(
          title: file["name"],
          author: get_in(latest, ["author", "displayName"]),
          body: {:plain, latest["content"]}
        )
      ]
    else
      []
    end
  end

  defp drive_mention(_file, _comment, _email), do: []

  defp mail_context?(message) do
    Enum.any?(~w(snippet messageText), fn key ->
      is_binary(message[key]) and String.trim(message[key]) != ""
    end)
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)
end
