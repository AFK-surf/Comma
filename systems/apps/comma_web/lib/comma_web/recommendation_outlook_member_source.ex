defmodule CommaWeb.RecommendationOutlookMemberSource do
  @moduledoc """
  Bounded, read-only Microsoft Graph mail and calendar collection using the
  same consented, account-pinned proxy and Routine collection budget as Gmail.
  No mailbox writes, subscriptions or independent monitor are created.
  """

  alias CommaWeb.{ProactiveOutlookMailSource, RecommendationMemberRead, RecommendationSourceQuote}
  alias CommaWeb.RecommendationSourceContext

  @graph "https://graph.microsoft.com/v1.0/me"
  @week 7 * 86_400
  # A message's own text replaces the 255-character preview, which often ends
  # before the deadline or the consequence. Text bodies of 40 messages fit.
  @mail_bytes 4_000_000

  def read(request, now) do
    since = now |> DateTime.add(-@week) |> DateTime.to_iso8601()
    until = now |> DateTime.add(@week) |> DateTime.to_iso8601()

    [profile, mail, calendar] =
      RecommendationMemberRead.map(
        [
          {@graph <> "?$select=id,mail,userPrincipalName", []},
          {@graph <>
             "/mailFolders/inbox/messages?" <>
             URI.encode_query(%{
               "$top" => 40,
               "$filter" => "receivedDateTime ge #{since}",
               "$orderby" => "receivedDateTime desc",
               "$select" =>
                 "id,conversationId,subject,from,receivedDateTime,bodyPreview,uniqueBody,webLink,importance"
             }), [parameters: [ProactiveOutlookMailSource.text_body()], max_bytes: @mail_bytes]},
          {@graph <>
             "/calendarView?" <>
             URI.encode_query(%{
               "startDateTime" => DateTime.to_iso8601(now),
               "endDateTime" => until,
               "$top" => 40,
               "$select" =>
                 "id,subject,start,end,webLink,organizer,attendees,isCancelled,bodyPreview,location"
             }), []}
        ],
        fn {url, opts} -> request.("GET", url, opts) end,
        3
      )

    with {:ok, %{"id" => id} = me} when is_binary(id) and id != "" <- profile,
         true <- is_binary(me["mail"]) or is_binary(me["userPrincipalName"]) do
      mailbox = Enum.find([me["mail"], me["userPrincipalName"]], &(is_binary(&1) and &1 != ""))
      {messages, mail_error} = messages(mail)
      {events, calendar_error} = events(calendar, mailbox)
      failures = Enum.reject([mail_error, calendar_error], &is_nil/1)

      if length(failures) == 2 do
        {:error, :member_source_context_unavailable}
      else
        data = %{
          "messages" => messages,
          "items" => events,
          "memberRelation" => "your_recent_inbox_and_upcoming_events"
        }

        {:ok, RecommendationMemberRead.warn(data, failures), %{"provider_user_id" => id}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp messages({:ok, %{"value" => value}}) when is_list(value) do
    items =
      value
      |> Enum.filter(fn m ->
        is_map(m) and is_binary(m["id"]) and is_binary(m["conversationId"]) and
          is_binary(m["webLink"]) and outlook_url?(m["webLink"]) and
          is_binary(m["receivedDateTime"])
      end)
      |> Enum.sort_by(& &1["receivedDateTime"], :desc)
      |> Enum.uniq_by(& &1["conversationId"])
      |> Enum.take(40)
      |> Enum.map(fn m ->
        %{
          "messageId" => m["id"],
          "threadId" => m["conversationId"],
          "subject" => m["subject"],
          "sender" => get_in(m, ["from", "emailAddress", "address"]),
          "messageTimestamp" => m["receivedDateTime"],
          "webUrl" => m["webLink"]
        }
        |> Map.put(
          "context",
          RecommendationSourceContext.attach(mail_text(m), ~w(body bodyPreview))["context"]
        )
        |> RecommendationSourceQuote.put(
          title: m["subject"],
          author:
            get_in(m, ["from", "emailAddress", "name"]) ||
              get_in(m, ["from", "emailAddress", "address"]),
          body: mail_quote(m)
        )
      end)

    {items, nil}
  end

  defp messages({:error, reason}), do: {[], reason}
  defp messages(_), do: {[], :member_source_context_unavailable}

  defp mail_text(message) do
    case ProactiveOutlookMailSource.message_text(message) do
      {:ok, text} when text != "" -> %{"body" => String.replace(text, ~r/\s+/u, " ")}
      _ -> %{"bodyPreview" => message["bodyPreview"]}
    end
  end

  # The unique body keeps its lines. The model context collapses them.
  defp mail_quote(message),
    do: ProactiveOutlookMailSource.quote_body(message) || {:plain, message["bodyPreview"]}

  defp events({:ok, %{"value" => value}}, mailbox) when is_list(value) do
    items =
      value
      |> Enum.filter(fn event ->
        is_map(event) and event["isCancelled"] != true and is_binary(event["id"]) and
          is_binary(event["webLink"]) and
          outlook_url?(event["webLink"]) and
          member_event?(event, mailbox)
      end)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.take(40)
      |> Enum.map(fn event ->
        event
        |> Map.put("webUrl", event["webLink"])
        |> RecommendationSourceContext.attach(~w(bodyPreview location))
        |> Map.take(~w(id subject start end webUrl context))
        |> RecommendationSourceQuote.put(
          title: event["subject"],
          body: {:plain, event["bodyPreview"]}
        )
      end)

    {items, nil}
  end

  defp events({:error, reason}, _), do: {[], reason}
  defp events(_, _), do: {[], :member_source_context_unavailable}

  defp outlook_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} ->
        host in ~w(outlook.office.com outlook.office365.com outlook.live.com)

      _ ->
        false
    end
  end

  defp member_event?(_event, mailbox) when not is_binary(mailbox), do: false

  defp member_event?(event, mailbox) do
    self = String.downcase(mailbox)
    organizer = get_in(event, ["organizer", "emailAddress", "address"])
    attendees = event["attendees"] || []

    (is_binary(organizer) and String.downcase(organizer) == self) or
      (is_list(attendees) and
         Enum.any?(attendees, fn attendee ->
           address = get_in(attendee, ["emailAddress", "address"])

           is_binary(address) and String.downcase(address) == self and
             get_in(attendee, ["status", "response"]) != "declined"
         end))
  end
end
