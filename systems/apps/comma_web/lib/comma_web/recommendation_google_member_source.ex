defmodule CommaWeb.RecommendationGoogleMemberSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, RecommendationSourceQuote}

  # Official Google APIs through the account-pinned proxy. Each read uses the
  # provider-asserted self identity of the same consented account.
  @gmail "https://gmail.googleapis.com/gmail/v1/users/me"
  @calendar "https://www.googleapis.com/calendar/v3/calendars/primary"
  @drive "https://www.googleapis.com/drive/v3"
  @week 7 * 86_400
  @awaiting "in:inbox -category:promotions newer_than:7d"
  @promotions "in:inbox category:promotions newer_than:7d"
  @spam "in:spam newer_than:7d"
  @window 15
  @promo_window 5
  @junk 10

  # Recent inbox mail delivered to the member's mailbox (including shared
  # aliases and groups), read or not. Provider importance and social
  # categories do not decide whether a matter needs the member. As before,
  # the thread's latest message is not one the member sent. One item per thread.
  # Important mail keeps its own read window and precedes ordinary mail within
  # the byte budget. Important threads alone can still exceed that budget.
  # When portrait entity terms are provided (`opts[:targets]["terms"]`), one
  # bounded query rescues matching promotions-tab newsletters/digests that
  # specifically name the member's own products or projects.
  # The most recent spam follows it, marked as junk.
  def read(toolkit, request, now, opts \\ [])

  def read("gmail", request, _now, opts) do
    terms = target_terms(opts)

    base_urls = [
      @gmail <> "/profile",
      threads_url("is:important " <> @awaiting),
      threads_url(@awaiting),
      threads_url(@spam, @junk)
    ]

    urls =
      if terms == [],
        do: base_urls,
        else: base_urls ++ [threads_url(promotions_query(terms), @promo_window)]

    [profile, important, recent, spam | promo_rest] =
      RecommendationMemberRead.map(
        urls,
        &request.("GET", &1, []),
        length(urls)
      )

    promo = List.first(promo_rest)

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
      promoted = promotion_items(promo, request, readable, email, terms)

      # Keep readable mail, but never report an unreadable mailbox as caught up.
      if readable != [] or promoted != [] or missing == 0 do
        data = %{
          "messages" =>
            readable ++ promoted ++ spam_items(spam, request, readable ++ promoted, email),
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

  def read("googlecalendar", request, now, _opts) do
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
          others = calendar_other_attendees(item)
          summary = others |> Enum.join(", ") |> String.slice(0, 240)

          item
          |> Map.put("attendeeCount", length(others))
          |> then(&if(summary != "", do: Map.put(&1, "attendeesSummary", summary), else: &1))
          |> CommaWeb.RecommendationSourceContext.attach(~w(status description location))
          |> Map.take(~w(id summary htmlLink start end attendeeCount attendeesSummary context))
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
  def read("googledrive", request, now, _opts) do
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

  # A promotions rescue query that fails leaves promotions out; inbox decides readability.
  defp promotion_items({:ok, %{"threads" => threads}}, request, inbox, email, terms)
       when is_list(threads) and terms != [] do
    seen = MapSet.new(inbox, & &1["threadId"])

    threads
    |> Enum.filter(&(is_map(&1) and valid_id?(&1["id"]) and not MapSet.member?(seen, &1["id"])))
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(@promo_window)
    |> RecommendationMemberRead.map(
      &request.("GET", @gmail <> "/threads/" <> &1["id"] <> "?format=full", []),
      5
    )
    |> Enum.flat_map(fn
      {:ok, %{"id" => thread, "messages" => [_ | _] = messages}} when is_binary(thread) ->
        latest = Enum.max_by(messages, &internal_ms/1)
        labels = if is_map(latest), do: latest["labelIds"], else: nil

        with true <- is_list(labels) and valid_id?(latest["id"]),
             true <-
               "INBOX" in labels and "CATEGORY_PROMOTIONS" in labels and
                 Enum.all?(~w(SENT SPAM TRASH), &(&1 not in labels)),
             {:ok, item} <- mail_item(latest, thread, email, "inbox"),
             true <- matches_any_term?(item, terms) do
          [Map.put(item, "memberRelation", "mentions_your_work")]
        else
          _ -> []
        end

      _unreadable ->
        []
    end)
  end

  defp promotion_items(_promo, _request, _inbox, _email, _terms), do: []

  defp target_terms(opts) do
    opts
    |> Keyword.get(:targets, %{})
    |> Map.get("terms", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.replace(~r/["():\r\n]/u, " ") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(5)
  end

  defp promotions_query(terms) do
    clause = Enum.map_join(terms, " OR ", &~s("#{&1}"))
    @promotions <> " (" <> clause <> ")"
  end

  defp matches_any_term?(item, terms) do
    haystack =
      [item["subject"], get_in(item, ["context", "text"]), get_in(item, ["quote", "body"])]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")
      |> String.downcase()

    Enum.any?(terms, &String.contains?(haystack, String.downcase(&1)))
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

    has_attachments? = CommaWeb.ProactiveMailSource.attachments?(message)
    to_header = non_direct_recipient(headers["to"], email)

    item = %{
      "messageId" => message["id"],
      "threadId" => thread,
      "subject" => headers["subject"],
      "sender" => headers["from"],
      "to" => to_header,
      "messageTimestamp" => timestamp(message["internalDate"]),
      "snippet" => message["snippet"],
      "messageText" => text
    }

    if mail_context?(item, has_attachments?) do
      context_fields =
        cond do
          is_binary(text) and text != "" ->
            ~w(sender to messageText)

          is_binary(item["snippet"]) and String.trim(item["snippet"]) != "" ->
            ~w(sender to snippet)

          true ->
            ~w(sender to subject)
        end

      {:ok,
       item
       # The snippet repeats the start of the text; it stands in only without one.
       |> CommaWeb.RecommendationSourceContext.attach(context_fields)
       |> Map.take(~w(messageId threadId subject sender to messageTimestamp context))
       |> Map.reject(fn {key, value} -> key == "to" and is_nil(value) end)
       # The pool keeps no attachment. The proactive check reads a mail's
       # attachments before it judges one marked unread.
       |> then(
         &if(has_attachments?,
           do: put_in(&1, ["context", "attachments"], "unread"),
           else: &1
         )
       )
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

  defp mail_context?(message, has_attachments?) do
    Enum.any?(~w(snippet messageText), fn key ->
      is_binary(message[key]) and String.trim(message[key]) != ""
    end) or
      (has_attachments? and is_binary(message["subject"]) and
         String.trim(message["subject"]) != "")
  end

  # Preserve the bounded To header only when the mail was not addressed directly
  # to the member's own mailbox (e.g., a shared alias or Google Group such as
  # support@...), keeping direct-mail context and fingerprints unchanged.
  defp non_direct_recipient(to, email) when is_binary(to) and is_binary(email) do
    normalized = to |> String.replace(~r/\s+/u, " ") |> String.trim()
    down_email = String.downcase(String.trim(email))

    cond do
      normalized == "" -> nil
      down_email != "" and String.contains?(String.downcase(normalized), down_email) -> nil
      true -> String.slice(normalized, 0, 160)
    end
  end

  defp non_direct_recipient(_to, _email), do: nil

  defp calendar_other_attendees(event) do
    event
    |> Map.get("attendees", [])
    |> List.wrap()
    |> Enum.filter(fn attendee ->
      is_map(attendee) and attendee["self"] != true and attendee["resource"] != true and
        attendee["responseStatus"] != "declined"
    end)
    |> Enum.take(12)
    |> Enum.flat_map(fn attendee ->
      name = attendee["displayName"]
      email = attendee["email"]

      cond do
        is_binary(name) and String.trim(name) != "" and is_binary(email) and email != "" ->
          ["#{String.trim(name)} <#{email}>"]

        is_binary(email) and email != "" ->
          [email]

        is_binary(name) and String.trim(name) != "" ->
          [String.trim(name)]

        true ->
          []
      end
    end)
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)
end
