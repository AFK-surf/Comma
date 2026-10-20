defmodule CommaWeb.RecommendationOutlookPreview do
  @moduledoc """
  Exact-link lookup in the member's current collected Outlook source. This does
  not derive a Graph id from a URL or scan a mailbox for an arbitrary link.
  """

  alias Comma.{MemberSourceConsents, MemberSourceItems, Recommendations}
  alias CommaWeb.RecommendationComposioMemberSource

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
    with true <- supported_href?(href) and workspace["owner_user_id"] == viewer,
         {:ok, profile} <- Recommendations.get_runtime_profile(workspace["id"], viewer),
         true <- profile.relevance_mode == "member",
         %{"connection_id" => id} = consent <-
           MemberSourceConsents.binding(workspace["id"], viewer, "outlook"),
         true <- is_nil(source_id) or source_id == id,
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
         ^consent <- MemberSourceConsents.binding(workspace["id"], viewer, "outlook"),
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
    %{
      "kind" => if(kind == "message", do: "outlook_message", else: "outlook_event"),
      "href" => href,
      "title" => String.slice(data["subject"] || "Untitled", 0, 200),
      "excerpt" => String.slice(data["bodyPreview"] || "", 0, 280),
      "sender" =>
        if(kind == "message",
          do: nested(data, ["from", "emailAddress", "address"]),
          else: nil
        ),
      "startsAt" => if(kind == "event", do: starts_at(data["start"]), else: nil)
    }
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
end
