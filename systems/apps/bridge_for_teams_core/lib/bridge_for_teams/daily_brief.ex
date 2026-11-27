defmodule BridgeForTeams.DailyBrief do
  @moduledoc """
  Storage for the daily brief: each Agent Swarm's settings, the members and
  their aliases, and the retention of its runs. A run keeps the brief it wrote
  (`Delivery`), so the next day's brief can tell what changed since.
  """

  import Ecto.Query

  alias BridgeForTeams.DailyBrief.Members
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefAlias, DailyBriefMember, DailyBriefSetting, User}

  @default_retention_days 90
  @default_prune_limit 500

  ## Settings and members

  @doc """
  Saves one Swarm's settings (`attrs` project id). Without a project id, the
  organization's current settings (`get_settings/1`) are changed. Each Swarm
  keeps its own row: saving one Swarm never changes another's.
  """
  @spec put_settings(Ecto.UUID.t(), map()) :: {:ok, DailyBriefSetting.t()} | {:error, term()}
  def put_settings(org_id, attrs) do
    existing =
      case Map.get(attrs, :project_id) || Map.get(attrs, "project_id") do
        nil ->
          get_settings(org_id)

        project_id ->
          case Ecto.UUID.cast(project_id) do
            {:ok, project_id} -> get_settings(org_id, project_id)
            :error -> nil
          end
      end

    (existing || %DailyBriefSetting{org_id: org_id})
    |> DailyBriefSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  The organization's current settings: an enabled Swarm's before a disabled
  one's, the first saved first. A page or request that names no Swarm reads
  these.
  """
  @spec get_settings(Ecto.UUID.t()) :: DailyBriefSetting.t() | nil
  def get_settings(org_id) do
    Repo.one(
      from(s in DailyBriefSetting,
        where: s.org_id == ^org_id,
        order_by: [desc: s.enabled, asc: s.created_at, asc: s.id],
        limit: 1
      )
    )
  end

  @doc "One Swarm's settings."
  @spec get_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: DailyBriefSetting.t() | nil
  def get_settings(org_id, project_id),
    do: Repo.get_by(DailyBriefSetting, org_id: org_id, project_id: project_id)

  @doc "Every Swarm's settings of the organization, the first saved first."
  @spec list_settings(Ecto.UUID.t()) :: [DailyBriefSetting.t()]
  def list_settings(org_id) do
    Repo.all(
      from(s in DailyBriefSetting,
        where: s.org_id == ^org_id,
        order_by: [asc: s.created_at, asc: s.id]
      )
    )
  end

  @doc """
  Makes `project_id`'s Swarm the one whose bot sends the member's personal
  brief. The Swarm must have settings of the member's provider. A Feishu or
  Lark member is named by their open id in that Swarm's app, looked up by
  email through its bot; the open id is kept with the member's other apps'.
  """
  @spec assign_member_project(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, DailyBriefMember.t()} | {:error, term()}
  def assign_member_project(org_id, member_id, project_id) do
    with {:ok, member_id} <- cast_id(member_id, :member_not_found),
         {:ok, project_id} <- cast_id(project_id, :settings_not_found),
         %DailyBriefMember{} = member <-
           Repo.get_by(DailyBriefMember, id: member_id, org_id: org_id) ||
             {:error, :member_not_found},
         %DailyBriefSetting{} = settings <-
           get_settings(org_id, project_id) || {:error, :settings_not_found},
         true <-
           Members.provider(settings) == member.provider || {:error, :settings_not_found},
         {:ok, attrs} <- sending_identity(member, settings) do
      member
      |> DailyBriefMember.changeset(Map.put(attrs, :project_id, project_id))
      |> Repo.update()
    end
  end

  defp cast_id(id, missing) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, missing}
    end
  end

  # A Slack id is the workspace's, the same for every bot in it.
  defp sending_identity(%DailyBriefMember{provider: "slack"}, _settings), do: {:ok, %{}}

  defp sending_identity(%DailyBriefMember{} = member, settings) do
    with {:ok, source} <- Members.source(settings),
         %User{email: email} when is_binary(email) <-
           Repo.get(User, member.user_id) || {:error, :member_not_found},
         email = email |> String.trim() |> String.downcase(),
         {:ok, found} <-
           Salix.impl().daily_brief_lookup_members(Map.put(source, :emails, [email])),
         %{app_id: app_id, open_id: open_id} when is_binary(app_id) and is_binary(open_id) <-
           Map.get(found, email) || {:error, :member_not_in_app} do
      {:ok,
       %{
         app_id: app_id,
         open_id: open_id,
         app_open_ids: Map.put(member.app_open_ids || %{}, app_id, open_id)
       }}
    end
  end

  @doc "Links a user once per provider (`attrs.provider`, Slack when absent)."
  @spec put_member(map()) :: {:ok, DailyBriefMember.t()} | {:error, term()}
  def put_member(%{org_id: org_id, user_id: user_id} = attrs) do
    provider = Map.get(attrs, :provider, "slack")

    (Repo.get_by(DailyBriefMember, org_id: org_id, user_id: user_id, provider: provider) ||
       %DailyBriefMember{})
    |> DailyBriefMember.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Replaces the member's alias set."
  @spec put_aliases(DailyBriefMember.t(), [map()]) ::
          {:ok, [DailyBriefAlias.t()]} | {:error, term()}
  def put_aliases(%DailyBriefMember{id: member_id}, aliases) when is_list(aliases) do
    Repo.transaction(fn ->
      Repo.delete_all(from(a in DailyBriefAlias, where: a.member_id == ^member_id))

      Enum.map(aliases, fn attrs ->
        case %DailyBriefAlias{}
             |> DailyBriefAlias.changeset(Map.put(attrs, :member_id, member_id))
             |> Repo.insert() do
          {:ok, row} -> row
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  ## Retention

  @doc """
  Deletes one bounded batch of runs older than their organization's
  retention period, with the briefs they kept.
  """
  @spec prune_expired(keyword()) :: {:ok, %{runs: non_neg_integer()}}
  def prune_expired(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    limit = Keyword.get(opts, :limit, @default_prune_limit)

    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH targets AS (
          SELECT row.id FROM daily_brief_runs row
          LEFT JOIN daily_brief_settings s
            ON s.org_id = row.org_id AND s.project_id = row.project_id
          WHERE row.created_at < $1::timestamp -
              make_interval(days => coalesce(s.retention_days, #{@default_retention_days}))
          ORDER BY row.created_at, row.id
          LIMIT $2
          FOR UPDATE OF row SKIP LOCKED
        ), deleted AS (
          DELETE FROM daily_brief_runs row USING targets t WHERE row.id = t.id RETURNING row.id
        )
        SELECT count(*)::bigint FROM deleted
        """,
        [DateTime.to_naive(now), limit]
      )

    {:ok, %{runs: count}}
  end
end
