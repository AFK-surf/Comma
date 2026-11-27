defmodule CommaWeb.RecommendationGmailPreview do
  @moduledoc """
  Exact-link lookup in the member's current collected Gmail source or owned
  Home `MailInteraction` entries. This never scans a mailbox or reads an
  arbitrary Gmail URL outside collected/recorded items.
  """

  alias Comma.{MemberSourceConsents, MemberSourceItems, Recommendations}
  alias CommaWeb.{ProactiveMailSource, RecommendationComposioMemberSource}
  alias SalixIM.{ConversationIds, Conversations, GroupDirectory, MailInteraction}

  @max_body_chars 8_000

  def supported_href?(href) when is_binary(href) do
    case URI.parse(href) do
      %URI{scheme: "https", host: "mail.google.com", userinfo: nil} ->
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
         {:ok, {source, item, message_id}} <- current(profile, workspace, viewer, id, href),
         provider_user = get_in(source.state.subject || %{}, ["provider_user_id"]),
         {:ok, data} <-
           RecommendationComposioMemberSource.preview_gmail(
             workspace,
             id,
             provider_user,
             message_id
           ),
         ^consent <- MemberSourceConsents.binding(workspace["id"], viewer, "gmail", id),
         {:ok, new_profile} <- Recommendations.get_runtime_profile(workspace["id"], viewer),
         true <-
           new_profile.id == profile.id and new_profile.source_revision == profile.source_revision,
         {:ok, {^source, ^item, ^message_id}} <-
           current(new_profile, workspace, viewer, id, href) do
      {:ok, card(data, href)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preview_from_home_mail(workspace, viewer, href, source_id) do
    with true <- supported_href?(href) and workspace["owner_user_id"] == viewer,
         {:ok, account_id, message_id} <- home_mail_entry(workspace, viewer, href, source_id),
         %{"connection_id" => ^account_id} = consent <-
           MemberSourceConsents.binding(workspace["id"], viewer, "gmail", account_id),
         {:ok, data} <-
           RecommendationComposioMemberSource.preview_gmail(
             workspace,
             account_id,
             nil,
             message_id
           ),
         ^consent <- MemberSourceConsents.binding(workspace["id"], viewer, "gmail", account_id) do
      {:ok, card(data, href)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp current(profile, workspace, viewer, id, href) do
    source = %{"toolkit" => "gmail", "connectionId" => id}

    if Enum.any?(profile.sources || [], fn row ->
         row["toolkit"] == "gmail" and row["kind"] == "composio" and
           row["connectionId"] == id and row["enabled"] == true
       end) do
      matching =
        MemberSourceItems.current(profile.id)
        |> Enum.filter(fn entry ->
          entry.collected and entry.state.source_id == id and entry.state.toolkit == "gmail" and
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

          case ids["messageId"] do
            message when is_binary(message) and byte_size(message) in 1..256 ->
              {:ok, {entry, item, message}}

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

  defp card(data, href) do
    headers =
      Map.new(get_in(data, ["payload", "headers"]) || [], fn
        %{"name" => name, "value" => value} when is_binary(name) and is_binary(value) ->
          {String.downcase(name), String.trim(value)}

        _ ->
          {"", ""}
      end)

    body =
      case ProactiveMailSource.text(data) do
        {:ok, text} when is_binary(text) and text != "" -> truncate_text(text, @max_body_chars)
        _ -> nil
      end

    snippet =
      case data["snippet"] do
        text when is_binary(text) and text != "" -> String.trim(text)
        _ -> body || ""
      end

    received_at =
      case Integer.parse(to_string(data["internalDate"] || "")) do
        {ms, ""} when ms > 0 -> ms
        _ -> nil
      end

    %{
      "kind" => "gmail_message",
      "href" => href,
      "title" => String.slice(non_blank(headers["subject"]) || "Untitled", 0, 200),
      "excerpt" => String.slice(snippet, 0, 280),
      "sender" => non_blank(headers["from"]),
      "recipients" => non_blank(headers["to"]),
      "receivedAt" => received_at,
      "body" => body
    }
  end

  defp consent(workspace, viewer, source_id) when source_id in [nil, ""] do
    case MemberSourceConsents.toolkit_bindings(workspace["id"], viewer, "gmail") do
      [only] -> only
      _ -> nil
    end
  end

  defp consent(workspace, viewer, source_id),
    do: MemberSourceConsents.binding(workspace["id"], viewer, "gmail", source_id)

  defp non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(_), do: nil

  defp truncate_text(text, max_chars) do
    if String.length(text) > max_chars,
      do: String.slice(text, 0, max_chars - 1) <> "…",
      else: text
  end
end
