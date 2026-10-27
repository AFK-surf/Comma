defmodule BridgeForTeams.DailyBrief do
  @moduledoc """
  Storage for the daily brief: an organization's settings, its members and
  their aliases, and the retention of its runs. A run keeps the brief it wrote
  (`Delivery`), so the next day's brief can tell what changed since.
  """

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{DailyBriefAlias, DailyBriefMember, DailyBriefSetting}

  @default_retention_days 90
  @default_prune_limit 500

  ## Settings and members

  @spec put_settings(Ecto.UUID.t(), map()) :: {:ok, DailyBriefSetting.t()} | {:error, term()}
  def put_settings(org_id, attrs) do
    (Repo.get_by(DailyBriefSetting, org_id: org_id) || %DailyBriefSetting{org_id: org_id})
    |> DailyBriefSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec get_settings(Ecto.UUID.t()) :: DailyBriefSetting.t() | nil
  def get_settings(org_id), do: Repo.get_by(DailyBriefSetting, org_id: org_id)

  @spec put_member(map()) :: {:ok, DailyBriefMember.t()} | {:error, term()}
  def put_member(%{org_id: org_id, user_id: user_id} = attrs) do
    (Repo.get_by(DailyBriefMember, org_id: org_id, user_id: user_id) || %DailyBriefMember{})
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
          LEFT JOIN daily_brief_settings s ON s.org_id = row.org_id
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
