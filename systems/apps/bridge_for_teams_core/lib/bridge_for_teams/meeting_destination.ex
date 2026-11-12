defmodule BridgeForTeams.MeetingDestination do
  @moduledoc """
  Where a Group's meeting reminders, join notices and minutes go, read and
  changed from chat. Salix's Router tools `meeting.settings.get_destination`
  and `meeting.settings.set_destination` call this with the signed origin of
  the current message, so the requester is the person who wrote it, never a
  name in its text.

  Anyone who writes to the bot may read it. Only an organization owner or
  admin may change it, as on the dashboard (`BridgeForTeams.MeetingPreparation`).
  The requester is found through the bindings that already exist: a Feishu or
  Lark sender through the Organization's single sign-on
  (`BridgeForTeams.StationMembers.requester/4`), a Slack user through the
  daily brief's member list. Anyone else gets `:admin_required`.

  Salix owns the setting (`Salix.Bindings.MeetingPreparationDashboard`,
  actions `destination` and `set_destination`).
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{DailyBriefMember, Organization, Project}

  @platforms ~w(slack feishu lark)

  @spec get_destination(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def get_destination(group_id, origin) do
    with {:ok, _requester} <- requester(group_id, origin),
         {:ok, project, org} <- project(group_id) do
      salix(org, project, "destination", %{})
    end
  end

  @spec set_destination(String.t(), map(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def set_destination(group_id, origin, platform, connect_id, chat_id)
      when platform in @platforms do
    with {:ok, requester} <- requester(group_id, origin),
         {:ok, project, org} <- project(group_id),
         :ok <- authorize(org, project, requester),
         {:ok, current} <- salix(org, project, "destination", %{}),
         {:ok, connect_id} <- pick(current, platform, connect_id) do
      attrs =
        %{"connect_id" => connect_id}
        |> put_present("channel_id", chat_id)

      salix(org, project, "set_destination", attrs)
    else
      {:choice_needed, options} ->
        {:ok, %{"status" => "choice_needed", "options" => options}}

      {:error, _} = error ->
        error
    end
  end

  def set_destination(_group_id, _origin, _platform, _connect_id, _chat_id),
    do: {:error, :invalid_platform}

  # One bot of the platform: the named one, or the only one there is.
  defp pick(current, platform, connect_id) do
    options = Enum.filter(List.wrap(current["options"]), &(&1["platform"] == platform))

    case {present(connect_id), options} do
      {nil, [%{"connect_id" => id}]} ->
        {:ok, id}

      {nil, []} ->
        {:error, :platform_not_connected}

      {nil, several} ->
        {:choice_needed, several}

      {id, options} ->
        if Enum.any?(options, &(&1["connect_id"] == id)),
          do: {:ok, id},
          else: {:error, :platform_not_connected}
    end
  end

  defp authorize(org, project, requester) do
    with {:ok, user_id} <- user(org, project, requester),
         {:ok, role} when role in ["owner", "admin"] <- Memberships.org_role(org.id, user_id) do
      :ok
    else
      _ -> {:error, :admin_required}
    end
  end

  # A Feishu/Lark sender maps through the Organization's single sign-on.
  defp user(org, project, %{provider: provider, connect_id: connect_id, subject: subject})
       when provider in ["feishu", "lark"] do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(project.salix_group_id, connect_id),
         true <- connect["provider"] == provider,
         {:ok, user_id} <-
           BridgeForTeams.StationMembers.requester(
             org.salix_tenant_id,
             project.salix_group_id,
             connect,
             subject
           ) do
      {:ok, user_id}
    else
      _ -> :none
    end
  end

  # A Slack user maps through the daily brief's enabled members, as
  # `BridgeForTeams.DailyBrief.ChatSettings` does.
  defp user(org, _project, %{provider: "slack", subject: user_id, workspace_id: workspace_id})
       when is_binary(workspace_id) do
    case Repo.one(
           from(m in DailyBriefMember,
             where:
               m.org_id == ^org.id and m.enabled and m.slack_user_id == ^user_id and
                 m.slack_workspace_id == ^workspace_id,
             select: m.user_id
           )
         ) do
      user_id when is_binary(user_id) -> {:ok, user_id}
      nil -> :none
    end
  end

  defp user(_org, _project, _requester), do: :none

  defp requester(group_id, %{} = origin) do
    context = origin["provider_context"] || %{}
    provider = origin["provider"]

    subject =
      case provider do
        "slack" -> context["user_id"]
        _ -> context["sender_open_id"]
      end

    if provider in @platforms and origin["source_actor_type"] == "provider_user" and
         origin["agent_group_id"] == group_id and is_binary(subject) and subject != "" and
         is_binary(context["connect_id"]) do
      {:ok,
       %{
         provider: provider,
         subject: subject,
         connect_id: context["connect_id"],
         workspace_id: context["workspace_id"]
       }}
    else
      {:error, :meeting_settings_requires_provider_request}
    end
  end

  defp requester(_group_id, _origin), do: {:error, :meeting_settings_requires_provider_request}

  defp project(group_id) do
    case Repo.one(
           from(p in Project,
             join: o in Organization,
             on: o.id == p.org_id,
             where: p.salix_group_id == ^group_id and is_nil(p.archived_at),
             select: {p, o}
           )
         ) do
      {project, org} -> {:ok, project, org}
      nil -> {:error, :project_not_found}
    end
  end

  defp salix(org, project, action, attrs) do
    if Code.ensure_loaded?(Client.impl()) and
         function_exported?(Client.impl(), :meeting_preparation, 1) do
      Client.impl().meeting_preparation(%{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => project.salix_group_id,
        "action" => action,
        "attrs" => attrs
      })
    else
      {:error, :meeting_settings_unavailable}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil

  defp put_present(map, key, value) do
    case present(value) do
      nil -> map
      text -> Map.put(map, key, text)
    end
  end
end
