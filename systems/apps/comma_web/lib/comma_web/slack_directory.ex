defmodule CommaWeb.SlackDirectory do
  @moduledoc """
  The Slack channels and people a Workspace owner's managed grant can see, for
  the composer's "@" menu, one page per request: the client core follows
  `next_cursor` at Slack's pace. People include bots (they are asked for work
  like people), without deactivated accounts and Slackbot.
  """

  alias Comma.Workspaces
  alias CommaWeb.{RecommendationMemberIdentity, RecommendationOAuthSource, SlackWebAPI}
  alias Salix.Control.OAuthBindings

  @channel_page_size 200
  # A user carries its whole profile: this page stays within the response bound.
  @people_page_size 100
  @member_page_size 200

  def channels(user, session, workspace_id, cursor) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         do: channels_page(workspace, user["id"], cursor)
  end

  def people(user, session, workspace_id, cursor) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         do: people_page(workspace, user["id"], cursor)
  end

  def channel_members(user, session, workspace_id, channel, cursor) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         do: channel_members_page(workspace, user["id"], channel, cursor)
  end

  @doc "One page of a channel's members, as Slack user ids. No usable grant is an empty, last page."
  def channel_members_page(workspace, user_id, channel, cursor) do
    query = %{"channel" => channel, "limit" => @member_page_size}
    page(workspace, user_id, "conversations.members", "members", query, cursor, &member/2)
  end

  @doc "One page of channels. No usable grant is an empty, last page."
  def channels_page(workspace, user_id, cursor) do
    query = %{
      "limit" => @channel_page_size,
      "types" => "public_channel,private_channel",
      "exclude_archived" => true
    }

    page(workspace, user_id, "conversations.list", "channels", query, cursor, &channel/2)
  end

  @doc "One page of people. No usable grant is an empty, last page."
  def people_page(workspace, user_id, cursor) do
    query = %{"limit" => @people_page_size}
    page(workspace, user_id, "users.list", "members", query, cursor, &person/2)
  end

  defp page(workspace, user_id, method, key, query, cursor, row) do
    case source(workspace, user_id) do
      {:ok, source, team_id} ->
        query = if cursor in [nil, ""], do: query, else: Map.put(query, "cursor", cursor)
        url = SlackWebAPI.url(method, query)

        case RecommendationOAuthSource.member_get(workspace, user_id, source, url) do
          {:ok, %{^key => rows} = body} when is_list(rows) ->
            {:ok,
             %{
               "data" => Enum.flat_map(rows, &row.(&1, team_id)),
               "next_cursor" => next_cursor(body)
             }}

          {:error, reason} ->
            {:error, {:unavailable, reason}}

          _ ->
            {:error, {:unavailable, :invalid_provider_response}}
        end

      :none ->
        {:ok, %{"data" => [], "next_cursor" => nil}}
    end
  end

  defp next_cursor(body) do
    case get_in(body, ["response_metadata", "next_cursor"]) do
      next when is_binary(next) and next != "" -> next
      _ -> nil
    end
  end

  defp source(workspace, user_id) do
    with {:ok, %{"binding_id" => binding_id}} <-
           OAuthBindings.select_provider_record(workspace["default_group_id"], "slack", "slack"),
         source = %{"kind" => "managed_oauth", "appId" => "slack", "connectionId" => binding_id},
         {:ok, %{"provider_workspace_id" => team_id}} <-
           RecommendationMemberIdentity.resolve(workspace, user_id, source) do
      {:ok, source, team_id}
    else
      _ -> :none
    end
  end

  defp channel(%{"id" => id, "name" => name} = channel, team_id)
       when is_binary(id) and is_binary(name) do
    [
      %{
        "id" => id,
        "name" => name,
        "member" => channel["is_member"] == true,
        "team_id" => team_id
      }
    ]
  end

  defp channel(_channel, _team_id), do: []

  defp member(id, _team_id) when is_binary(id), do: [id]
  defp member(_id, _team_id), do: []

  defp person(%{"deleted" => true}, _team_id), do: []
  defp person(%{"id" => "USLACKBOT"}, _team_id), do: []

  defp person(%{"id" => id, "name" => handle} = person, team_id)
       when is_binary(id) and is_binary(handle) do
    profile = person["profile"] || %{}

    [
      %{
        "id" => id,
        "handle" => handle,
        "name" =>
          present(profile["display_name"]) || present(profile["real_name"]) ||
            present(person["real_name"]) || handle,
        "avatar_ref" => CommaWeb.LinkPreviewAvatar.ref(profile["image_48"]),
        "team_id" => team_id
      }
    ]
  end

  defp person(_person, _team_id), do: []

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
