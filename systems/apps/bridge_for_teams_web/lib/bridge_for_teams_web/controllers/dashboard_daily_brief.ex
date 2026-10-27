defmodule BridgeForTeamsWeb.DashboardDailyBrief do
  @moduledoc """
  Daily brief pages for `DashboardAPIController`.

  Owners and admins read and change the organization's settings (including
  the calendar: weekdays off and make-up workdays, as `YYYY-MM-DD` lists),
  link members to Slack, read today's state and the latest runs, and ask for
  one member's brief now. Every read is a fixed number of bounded queries.
  """

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Repo}
  alias BridgeForTeams.DailyBrief.{Dashboard, Delivery, Members}
  alias BridgeForTeams.Schema.{DailyBriefMember, Project, User}

  @settings_keys ~w(project_id slack_connect_id enabled retention_days team_names off_days work_days team_channel_id team_post_at)
  @max_members 500
  @activity_days 14

  def overview(org) do
    settings = DailyBrief.get_settings(org.id)
    now = SystemsClock.utc_now()

    activity =
      if settings, do: Dashboard.member_activity(settings, now, @activity_days), else: %{}

    {:ok,
     %{
       "settings" =>
         settings && Map.new(@settings_keys, &{&1, Map.get(settings, String.to_atom(&1))}),
       "members" => Enum.map(members(org.id), &Map.merge(&1, Map.get(activity, &1["id"], %{}))),
       "today" => settings && Dashboard.today(settings, now),
       "runs" => if(settings, do: Dashboard.runs(settings), else: [])
     }}
  end

  def request_brief(org, member_id) do
    with {:ok, member_id} <- Ecto.UUID.cast(member_id),
         %DailyBriefMember{enabled: true} = member <-
           Repo.get_by(DailyBriefMember, id: member_id, org_id: org.id),
         %{enabled: true} <- DailyBrief.get_settings(org.id),
         {:ok, member} <- Delivery.request(member, SystemsClock.utc_now()) do
      {:ok, %{"id" => member.id, "requested_at" => member.brief_requested_at}}
    else
      %{enabled: false} ->
        {:error, 409, "daily_brief_disabled", "Turn the daily brief on first.", %{}}

      _not_found ->
        {:error, 404, "daily_brief_member_not_found", "This member does not get the brief.", %{}}
    end
  end

  def save(org, params) do
    attrs = Map.take(params, @settings_keys)

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

  def sync_members(org) do
    case DailyBrief.get_settings(org.id) do
      nil ->
        {:error, 409, "daily_brief_not_configured", "Save the daily brief settings first.", %{}}

      settings ->
        case Members.sync(settings) do
          {:ok, result} ->
            {:ok, %{"linked" => result.linked, "unresolved" => result.unresolved}}

          {:error, _reason} ->
            {:error, 503, "slack_unavailable", "Slack could not be read. Try again.", %{}}
        end
    end
  end

  defp members(org_id) do
    Repo.all(
      from(m in DailyBriefMember,
        join: u in User,
        on: u.id == m.user_id,
        where: m.org_id == ^org_id,
        order_by: [asc: u.email],
        limit: @max_members,
        select: %{
          "id" => m.id,
          "email" => u.email,
          "name" => u.name,
          "slack_user_id" => m.slack_user_id,
          "enabled" => m.enabled,
          "timezone" => m.timezone,
          "deliver_at" => m.deliver_at
        }
      )
    )
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
