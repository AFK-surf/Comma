defmodule BridgeForTeamsWeb.DashboardDailyBrief do
  @moduledoc """
  Daily brief pages for `DashboardAPIController`.

  Each Agent Swarm keeps its own settings; a page names the Swarm it shows
  (`project_id`), else it shows the organization's current one. Owners and
  admins read and change a Swarm's settings (including
  the IM provider and its bot, Slack, Feishu, or Lark, and the calendar:
  weekdays off and make-up workdays, as `YYYY-MM-DD` lists), list the groups
  or channels a bot can post the team brief to, link members to the
  provider, read today's state and the latest runs, and ask for one member's
  brief now. Every read is a fixed number of bounded queries; the group list
  is one bounded read of the bot's chats.
  """

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Repo}
  alias BridgeForTeams.DailyBrief.{Dashboard, Delivery, Members, Sources}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Project, User}

  @settings_keys ~w(project_id provider connect_id slack_connect_id enabled retention_days team_names off_days work_days team_channel_id team_post_at)
  @max_members 500
  @activity_days 14

  @doc """
  One Swarm's daily brief (`project_id`, else the organization's current
  settings), with the Swarms that have settings and, per member, the Swarm
  whose bot sends their brief.
  """
  def overview(org, params \\ %{}) do
    settings = selected_settings(org, params)
    now = SystemsClock.utc_now()

    activity =
      if settings, do: Dashboard.member_activity(settings, now, @activity_days), else: %{}

    {:ok,
     %{
       "settings" =>
         settings && Map.new(@settings_keys, &{&1, Map.get(settings, String.to_atom(&1))}),
       "members" =>
         org.id
         |> members(settings)
         |> Enum.map(&Map.merge(&1, Map.get(activity, &1["id"], %{}))),
       "today" => settings && Dashboard.today(settings, now),
       "runs" => if(settings, do: Dashboard.runs(settings), else: []),
       "configured_projects" =>
         org.id
         |> DailyBrief.list_settings()
         |> Enum.map(
           &%{
             "project_id" => &1.project_id,
             "provider" => Members.provider(&1),
             "enabled" => &1.enabled
           }
         )
     }}
  end

  # The Swarm a page asks for; one without settings shows none.
  defp selected_settings(org, %{"project_id" => project_id}) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, project_id} -> DailyBrief.get_settings(org.id, project_id)
      :error -> nil
    end
  end

  defp selected_settings(org, _params), do: DailyBrief.get_settings(org.id)

  def request_brief(org, member_id) do
    with {:ok, member_id} <- Ecto.UUID.cast(member_id),
         %DailyBriefMember{enabled: true} = member <-
           Repo.get_by(DailyBriefMember, id: member_id, org_id: org.id),
         %{enabled: true} <- sending_settings(org, member),
         {:ok, member} <- Delivery.request(member, SystemsClock.utc_now()) do
      {:ok, %{"id" => member.id, "requested_at" => member.brief_requested_at}}
    else
      %{enabled: false} ->
        {:error, 409, "daily_brief_disabled", "Turn the daily brief on first.", %{}}

      _not_found ->
        {:error, 404, "daily_brief_member_not_found", "This member does not get the brief.", %{}}
    end
  end

  # The Swarm whose bot sends the member's brief.
  defp sending_settings(org, %DailyBriefMember{project_id: project_id})
       when is_binary(project_id),
       do: DailyBrief.get_settings(org.id, project_id)

  defp sending_settings(org, _member), do: DailyBrief.get_settings(org.id)

  @doc "Moves a member's brief to another Swarm's bot (`project_id`)."
  def update_member(org, member_id, params) do
    case DailyBrief.assign_member_project(org.id, member_id, params["project_id"]) do
      {:ok, member} ->
        {:ok, %{"id" => member.id, "project_id" => member.project_id}}

      {:error, :member_not_found} ->
        {:error, 404, "daily_brief_member_not_found", "This member does not get the brief.", %{}}

      {:error, :settings_not_found} ->
        {:error, 422, "daily_brief_not_configured",
         "This Agent Swarm has no daily brief of the member's IM.", %{}}

      {:error, :member_not_in_app} ->
        {:error, 422, "daily_brief_member_not_in_app",
         "This Agent Swarm's bot cannot find the member.", %{}}

      {:error, %Ecto.Changeset{}} ->
        {:error, 409, "daily_brief_member_taken",
         "Another member already has this account in the Agent Swarm's bot.", %{}}

      {:error, _unavailable} ->
        {:error, 503, "daily_brief_member_unavailable",
         "The Agent Swarm's bot could not read people. Try again.", %{}}
    end
  end

  def save(org, params) do
    # A request from before providers names only the Slack bot.
    attrs =
      params
      |> Map.take(@settings_keys)
      |> Map.put_new_lazy("provider", fn ->
        if Map.has_key?(params, "slack_connect_id"), do: "slack", else: current_provider(org)
      end)

    with :ok <- project_in_org(org, attrs["project_id"] || current_project(org)),
         {:ok, settings} <- DailyBrief.put_settings(org.id, attrs) do
      {:ok, Map.new(@settings_keys, &{&1, Map.get(settings, String.to_atom(&1))})}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, 422, "invalid_daily_brief_settings", "Daily brief settings are invalid.",
         %{"fields" => Enum.map(changeset.errors, fn {field, _} -> to_string(field) end)}}

      {:error, :project_not_found} ->
        {:error, 422, "invalid_daily_brief_settings",
         "The Agent Swarm is not in this organization.", %{}}
    end
  end

  def sync_members(org, params \\ %{}) do
    case selected_settings(org, params) do
      nil ->
        {:error, 409, "daily_brief_not_configured", "Save the daily brief settings first.", %{}}

      settings ->
        case Members.sync(settings) do
          {:ok, result} ->
            {:ok, %{"linked" => result.linked, "unresolved" => result.unresolved}}

          {:error, _reason} ->
            {:error, 503, unavailable_code(settings), "The bot could not read people. Try again.",
             %{}}
        end
    end
  end

  @doc """
  The groups or channels the chosen bot can post the team brief to: Slack's
  public channels, or Feishu's and Lark's internal public groups.
  """
  def channels(org, params) do
    provider = if params["provider"] in DailyBriefSetting.providers(), do: params["provider"]
    connect_id = params["connect_id"]
    project_id = params["project_id"] || current_project(org)

    settings = %DailyBriefSetting{
      org_id: org.id,
      project_id: project_id,
      provider: provider,
      connect_id: connect_id,
      slack_connect_id: if(provider == "slack", do: connect_id)
    }

    with true <- is_binary(provider) and is_binary(connect_id) and connect_id != "",
         :ok <- project_in_org(org, project_id),
         {:ok, source} <- Members.source(settings),
         {:ok, %{channels: channels} = listed} <-
           Salix.impl().daily_brief_channels(Sources.channels_request(source)) do
      {:ok,
       %{
         "channels" =>
           channels
           |> Enum.map(&%{"id" => &1.id, "name" => &1.name})
           |> Enum.sort_by(&String.downcase(&1["name"] || "")),
         "complete" => Map.get(listed, :complete?, true) == true
       }}
    else
      false ->
        {:error, 422, "invalid_daily_brief_bot", "Choose a bot first.", %{}}

      {:error, :project_not_found} ->
        {:error, 422, "invalid_daily_brief_bot", "The Agent Swarm is not in this organization.",
         %{}}

      _unavailable ->
        {:error, 503, "channels_unavailable", "The bot's groups could not be read. Try again.",
         %{}}
    end
  end

  defp unavailable_code(settings) do
    case Members.provider(settings) do
      "feishu" -> "feishu_unavailable"
      "lark" -> "lark_unavailable"
      _slack -> "slack_unavailable"
    end
  end

  # The settings' provider's members. Each names its provider id in
  # `provider_user_id`; a Slack member keeps `slack_user_id` too.
  defp members(org_id, settings) do
    provider = if settings, do: Members.provider(settings), else: "slack"

    Repo.all(
      from(m in DailyBriefMember,
        join: u in User,
        on: u.id == m.user_id,
        where: m.org_id == ^org_id and m.provider == ^provider,
        order_by: [asc: u.email],
        limit: @max_members,
        select: %{
          "id" => m.id,
          "email" => u.email,
          "name" => u.name,
          "provider" => m.provider,
          "provider_user_id" => coalesce(m.open_id, m.slack_user_id),
          "slack_user_id" => m.slack_user_id,
          "enabled" => m.enabled,
          "project_id" => m.project_id,
          "timezone" => m.timezone,
          "deliver_at" => m.deliver_at
        }
      )
    )
  end

  defp current_provider(org) do
    case DailyBrief.get_settings(org.id) do
      nil -> "slack"
      settings -> Members.provider(settings)
    end
  end

  defp current_project(org) do
    case DailyBrief.get_settings(org.id) do
      nil -> nil
      settings -> settings.project_id
    end
  end

  defp project_in_org(org, project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{org_id: org_id} when org_id == org.id -> :ok
      _other -> {:error, :project_not_found}
    end
  end

  defp project_in_org(_org, _project_id), do: {:error, :project_not_found}
end
