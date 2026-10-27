defmodule BridgeForTeams.DailyBrief.Members do
  @moduledoc """
  Links an organization's BFT users to their Slack members for the daily brief.

  The Swarm's Slack bot resolves each user's email in its workspace. A newly
  linked member starts with its Slack names as aliases; later runs keep the
  member's own alias edits.
  """

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Memberships, Repo}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Organization, Project}

  @batch 50

  @spec sync(DailyBriefSetting.t()) ::
          {:ok, %{linked: non_neg_integer(), unresolved: [String.t()]}} | {:error, term()}
  def sync(%DailyBriefSetting{} = settings) do
    with {:ok, source} <- source(settings) do
      users =
        settings.org_id
        |> Memberships.list_org_members()
        |> Enum.map(& &1.user)
        |> Enum.filter(&(is_binary(&1.email) and &1.status == "active"))

      by_email = Map.new(users, &{normalize(&1.email), &1})

      by_email
      |> Map.keys()
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while({:ok, %{linked: 0, unresolved: []}}, fn emails, {:ok, acc} ->
        case Salix.impl().daily_brief_lookup_members(Map.put(source, :emails, emails)) do
          {:ok, found} ->
            linked =
              Enum.count(found, fn {email, slack} ->
                match?({:ok, _}, link(settings, by_email[email], slack))
              end)

            {:cont,
             {:ok,
              %{
                linked: acc.linked + linked,
                unresolved: acc.unresolved ++ Enum.reject(emails, &Map.has_key?(found, &1))
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "The Salix identity of the settings' Swarm and Slack connection."
  @spec source(DailyBriefSetting.t()) :: {:ok, map()} | {:error, :source_unavailable}
  def source(%DailyBriefSetting{} = settings) do
    with %Organization{salix_tenant_id: tenant_id} when is_binary(tenant_id) <-
           Repo.get(Organization, settings.org_id),
         %Project{salix_group_id: group_id, org_id: org_id} when is_binary(group_id) <-
           Repo.get(Project, settings.project_id),
         true <- org_id == settings.org_id do
      {:ok, %{tenant_id: tenant_id, group_id: group_id, connect_id: settings.slack_connect_id}}
    else
      _missing -> {:error, :source_unavailable}
    end
  end

  @doc "Enabled members of the organization, with aliases."
  @spec enabled(Ecto.UUID.t()) :: [DailyBriefMember.t()]
  def enabled(org_id) do
    Repo.all(
      from(m in DailyBriefMember,
        where: m.org_id == ^org_id and m.enabled,
        order_by: [asc: m.created_at, asc: m.id],
        preload: [:aliases]
      )
    )
  end

  defp link(settings, user, slack) do
    existing = Repo.get_by(DailyBriefMember, org_id: settings.org_id, user_id: user.id)

    with {:ok, member} <-
           DailyBrief.put_member(%{
             org_id: settings.org_id,
             user_id: user.id,
             slack_workspace_id: slack.workspace_id,
             slack_user_id: slack.slack_user_id,
             timezone: slack.timezone
           }) do
      if is_nil(existing) do
        DailyBrief.put_aliases(member, Enum.map(slack.names, &%{term: &1, kind: "name"}))
      end

      {:ok, member}
    end
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
