defmodule CommaWeb.RecommendationOutlookPreview do
  @moduledoc """
  Exact-link lookup in the member's current collected Outlook source or owned
  Home `MailInteraction` entries. This does not derive a Graph id from a URL or
  scan a mailbox for an arbitrary link.
  """

  alias Comma.{MemberSourceConsents, MemberSourceItems, Recommendations}
  alias CommaWeb.{ProactiveOutlookMailSource, RecommendationComposioMemberSource}
  alias SalixIM.{ConversationIds, Conversations, GroupDirectory, MailInteraction}

  @max_body_chars 8_000

  def supported_href?(href) when is_binary(href) do
    case URI.parse(href) do
      %URI{scheme: "https", host: host, userinfo: nil} ->
        host in ~w(outlook.office.com outlook.office365.com outlook.live.com) and
          byte_size(href) <= 2_048

      _ ->
        false
    end
  end

  def supported_href?(_), do: false

  def preview(workspace, viewer, href, source_id) do
    case preview_from_routine(workspace, viewer, href, source_id) do
      {:ok, result} ->
        {:ok, result}

      _ ->
        preview_from_home_mail(workspace, viewer, href, source_id)
    end
  end

  defp preview_from_routine(workspace, viewer, href, source_id) do
    with true <- supported_href?(href) and workspace["owner_user_id"] == viewer,
         {:ok, profile} <- Recommendations.get_runtime_profile(workspace["id"], viewer),
         true <- profile.relevance_mode == "member",
         %{"connection_id" => id} = consent <- consent(workspace, viewer, source_id),
         {:ok, {source, item, kind, resource_id}} <- current(profile, workspace, viewer, id, href),
         %{"provider_user_id" => provider_user} <- source.state.subject,
         {:ok, data} <-
           RecommendationComposioMemberSource.preview_outlook(
             workspace,
             id,
             provider_user,
             kind,
             resource_id,
             href
           ),
         true <- valid_card_data?(data),
         ^consent <- MemberSourceConsents.binding(workspace["id"], viewer, "outlook", id),
         {:ok, new_profile} <- Recommendations.get_runtime_profile(workspace["id"], viewer),
         true <-
           new_profile.id == profile.id and new_profile.source_revision == profile.source_revision,
         {:ok, {^source, ^item, ^kind, ^resource_id}} <-
           current(new_profile, workspace, viewer, id, href) do
      {:ok, card(data, kind, href)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preview_from_home_mail(workspace, viewer, href, source_id) do
    with true <- supported_href?(href) and workspace["owner_user_id"] == viewer,
         {:ok, account_id, message_id} <- home_mail_entry(workspace, viewer, href, source_id),
         %{"connection_id" => ^account_id} = consent <-
           MemberSourceConsents.binding(workspace["id"], viewer, "outlook", account_id),
         {:ok, data} <-
           RecommendationComposioMemberSource.preview_outlook(
             workspace,
             account_id,
             nil,
             "message",
             message_id,
             href
           ),
         true <- valid_card_data?(data),
         ^consent <- MemberSourceConsents.binding(workspace["id"], viewer, "outlook", account_id) do
      {:ok, card(data, "message", href)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp home_mail_entry(workspace, viewer, href, source_id) do
    group_id = workspace["default_group_id"]

    with true <- is_binary(group_id) and group_id != "",
         {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, home_id} <- ConversationIds.group_router(group),
         {:ok, conversation} <- Conversations.get_group_conversation_record(group_id, home_id) do
      matching =
        conversation
        |> MailInteraction.entries()
        |> Map.values()
        |> Enum.filter(fn value ->
          is_map(value) and value["owner_id"] == viewer and
            is_binary(value["source_url"]) and String.trim(value["source_url"]) == href and
            is_binary(value["account_id"]) and value["account_id"] != "" and
            is_binary(value["message_id"]) and value["message_id"] != "" and
            (is_nil(source_id) or source_id == "" or value["account_id"] == source_id)
        end)
        |> Enum.sort_by(&(&1["changed_at"] || 0), :desc)

      case matching do
        [%{"account_id" => account_id, "message_id" => message_id} | _] ->
          {:ok, account_id, message_id}

        _ ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp current(profile, workspace, viewer, id, href) do
    source = %{"toolkit" => "outlook", "connectionId" => id}

    if Enum.any?(profile.sources || [], fn row ->
         row["toolkit"] == "outlook" and row["kind"] == "composio" and
           row["connectionId"] == id and row["enabled"] == true
       end) do
      matching =
        MemberSourceItems.current(profile.id)
        |> Enum.filter(fn entry ->
          entry.collected and entry.state.source_id == id and entry.state.toolkit == "outlook" and
            RecommendationComposioMemberSource.current_subject?(
              workspace,
              viewer,
              source,
              entry.state.subject
            )
        end)
        |> Enum.flat_map(fn entry ->
          for item <- entry.items, item.url == href, do: {entry, item}
        end)

      case matching do
        [{entry, item}] ->
          ids = item.provider_ids || %{}

          case {ids["messageId"], ids["eventId"]} do
            {message, nil} when is_binary(message) and byte_size(message) in 1..512 ->
              {:ok, {entry, item, "message", message}}

            {nil, event} when is_binary(event) and byte_size(event) in 1..512 ->
              {:ok, {entry, item, "event", event}}

            _ ->
              {:error, :not_found}
          end

        _ ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp valid_card_data?(data) do
    is_map(data) and
      Enum.all?(~w(subject bodyPreview), fn field ->
        is_nil(data[field]) or is_binary(data[field])
      end) and
      (is_nil(nested(data, ["start", "dateTime"])) or
         is_binary(nested(data, ["start", "dateTime"]))) and
      (is_nil(nested(data, ["from", "emailAddress", "address"])) or
         is_binary(nested(data, ["from", "emailAddress", "address"])))
  end

  defp nested(data, []), do: data
  defp nested(data, [key | rest]) when is_map(data), do: nested(data[key], rest)
  defp nested(_, _), do: nil

  defp card(data, kind, href) do
    body =
      if kind == "message" do
        case ProactiveOutlookMailSource.message_text(data) do
          {:ok, text} when is_binary(text) and text != "" ->
            truncate_text(text, @max_body_chars)

          _ ->
            nil
        end
      end

    excerpt_source =
      case data["bodyPreview"] do
        text when is_binary(text) and text != "" -> text
        _ -> body || ""
      end

    %{
      "kind" => if(kind == "message", do: "outlook_message", else: "outlook_event"),
      "href" => href,
      "title" => String.slice(data["subject"] || "Untitled", 0, 200),
      "excerpt" => String.slice(String.trim(excerpt_source), 0, 280),
      "sender" =>
        if(kind == "message",
          do: outlook_sender(data["from"]),
          else: nil
        ),
      "recipients" =>
        if(kind == "message",
          do: outlook_recipients(data["toRecipients"]),
          else: nil
        ),
      "receivedAt" =>
        if(kind == "message",
          do: iso_unix_ms(data["receivedDateTime"]),
          else: nil
        ),
      "body" => body,
      "startsAt" => if(kind == "event", do: starts_at(data["start"]), else: nil)
    }
  end

  defp outlook_sender(%{"emailAddress" => %{} = addr}) do
    name = clean_string(addr["name"])
    email = clean_string(addr["address"])

    cond do
      is_binary(name) and is_binary(email) and String.downcase(name) != String.downcase(email) ->
        "#{name} <#{email}>"

      is_binary(email) ->
        email

      true ->
        name
    end
  end

  defp outlook_sender(_), do: nil

  defp outlook_recipients(rows) when is_list(rows) do
    rows
    |> Enum.take(10)
    |> Enum.map(&clean_string(nested(&1, ["emailAddress", "address"])))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp outlook_recipients(_), do: nil

  defp iso_unix_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp iso_unix_ms(_), do: nil

  defp clean_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_string(_), do: nil

  defp truncate_text(text, max_chars) do
    if String.length(text) > max_chars,
      do: String.slice(text, 0, max_chars - 1) <> "…",
      else: text
  end

  # Graph returns event times in UTC unless a Prefer header asks otherwise;
  # any other zone is withheld rather than shown as a zoneless string.
  defp starts_at(%{"dateTime" => value, "timeZone" => "UTC"}) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
      _ -> nil
    end
  end

  defp starts_at(_), do: nil

  # The viewer's Outlook account the link names, or the only one they consented.
  defp consent(workspace, viewer, source_id) when source_id in [nil, ""] do
    case MemberSourceConsents.toolkit_bindings(workspace["id"], viewer, "outlook") do
      [only] -> only
      _ -> nil
    end
  end

  defp consent(workspace, viewer, source_id),
    do: MemberSourceConsents.binding(workspace["id"], viewer, "outlook", source_id)
end
