defmodule CommaWeb.RecommendationGoogleMemberSource do
  @moduledoc false

  alias CommaWeb.RecommendationMemberRead

  # Official Google APIs through the account-pinned proxy. Each read uses the
  # provider-asserted self identity of the same consented account.
  @gmail "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar "https://www.googleapis.com/calendar/v3/calendars/primary"
  @drive "https://www.googleapis.com/drive/v3"
  @week 7 * 86_400
  @awaiting "in:inbox is:important to:me -category:promotions -category:social newer_than:7d"

  # Important mail to the member that still waits for a reply, read or not:
  # the thread's latest message is not one the member sent. One item per thread.
  def read("gmail", request, _now) do
    [profile, list] =
      RecommendationMemberRead.map(
        [
          @gmail <> "/profile",
          @gmail <> "/threads?" <> URI.encode_query(%{"q" => @awaiting, "maxResults" => 15})
        ],
        &request.("GET", &1, []),
        2
      )

    with {:ok, %{"emailAddress" => email}} when is_binary(email) and email != "" <- profile,
         {:ok, list} when is_map(list) <- list do
      results =
        List.wrap(list["threads"])
        |> Enum.filter(&(is_map(&1) and valid_id?(&1["id"])))
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

      # Keep readable work, but never report an unreadable mailbox as caught up.
      if readable != [] or missing == 0 do
        data = %{"messages" => readable, "memberRelation" => "awaiting_your_reply"}

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
        not Enum.all?(~w(INBOX IMPORTANT), &(&1 in labels)) or
          Enum.any?(~w(CATEGORY_PROMOTIONS CATEGORY_SOCIAL SPAM TRASH), &(&1 in labels)) ->
        :closed

      true ->
        mail_item(latest, thread, email)
    end
  end

  defp awaiting(_thread, _email), do: :missing

  defp mail_item(message, thread, email) do
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
       |> CommaWeb.RecommendationSourceContext.attach(~w(sender snippet messageText))
       |> Map.take(~w(messageId threadId subject sender messageTimestamp context))
       |> Map.put(
         "webUrl",
         "https://mail.google.com/mail/?authuser=" <>
           URI.encode_www_form(email) <> "#inbox/" <> message["id"]
       )}
    else
      :missing
    end
  end

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
