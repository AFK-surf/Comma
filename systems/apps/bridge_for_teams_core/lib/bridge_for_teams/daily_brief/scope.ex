defmodule BridgeForTeams.DailyBrief.Scope do
  @moduledoc """
  Which Swarms' public groups or channels a brief reads, as a list of
  settings: the Swarm that sends the brief first, then the others of the
  same organization and provider with the brief on, the first saved first.

    * A Swarm's team brief also reads the Swarms its `SearchGrant`s let it
      search (`Departments.effective_search_group_ids_by_project/1`).
    * A member's personal brief reads the Swarm that sends it, the Swarms
      the member belongs to (`project_memberships`), and the Swarms the
      sending Swarm may search.

  A Swarm alone, without grants or other Swarms, reads only its own.
  """

  import Ecto.Query

  alias BridgeForTeams.{Departments, Repo}
  alias BridgeForTeams.DailyBrief.Members
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Project, ProjectMembership}

  @doc "The settings a Swarm's team brief reads."
  @spec team(DailyBriefSetting.t()) :: [DailyBriefSetting.t()]
  def team(%DailyBriefSetting{} = settings) do
    case siblings(settings) do
      [] ->
        [settings]

      siblings ->
        granted = granted_groups(settings)
        [settings | for({s, group} <- siblings, MapSet.member?(granted, group), do: s)]
    end
  end

  @doc "The settings a member's personal brief reads; `settings` sends it."
  @spec personal(DailyBriefSetting.t(), DailyBriefMember.t()) :: [DailyBriefSetting.t()]
  def personal(%DailyBriefSetting{} = settings, %DailyBriefMember{} = member) do
    case siblings(settings) do
      [] ->
        [settings]

      siblings ->
        granted = granted_groups(settings)

        mine =
          Repo.all(
            from(pm in ProjectMembership,
              where:
                pm.user_id == ^member.user_id and
                  pm.project_id in ^Enum.map(siblings, &elem(&1, 0).project_id),
              select: pm.project_id
            )
          )
          |> MapSet.new()

        [
          settings
          | for(
              {s, group} <- siblings,
              MapSet.member?(mine, s.project_id) or MapSet.member?(granted, group),
              do: s
            )
        ]
    end
  end

  @doc "A short key of a scope: its settings ids in order."
  @spec key([DailyBriefSetting.t()]) :: [Ecto.UUID.t()]
  def key(scope), do: Enum.map(scope, & &1.id)

  @doc "Enabled settings of the organization's other Swarms of the same provider."
  @spec sibling_settings(DailyBriefSetting.t()) :: [DailyBriefSetting.t()]
  def sibling_settings(%DailyBriefSetting{} = settings),
    do: settings |> siblings() |> Enum.map(&elem(&1, 0))

  # Enabled settings of the organization's other Swarms of the same
  # provider, each with its Swarm's Salix group id.
  defp siblings(%DailyBriefSetting{org_id: org_id, id: id} = settings) do
    provider = Members.provider(settings)

    Repo.all(
      from(s in DailyBriefSetting,
        join: p in Project,
        on: p.id == s.project_id and p.org_id == s.org_id,
        where:
          s.org_id == ^org_id and s.enabled and s.project_id != ^settings.project_id and
            is_nil(p.archived_at),
        order_by: [asc: s.created_at, asc: s.id],
        select: {s, p.salix_group_id}
      )
    )
    |> Enum.filter(fn {s, _group} -> s.id != id and Members.provider(s) == provider end)
  end

  defp granted_groups(%DailyBriefSetting{org_id: org_id, project_id: project_id}) do
    org_id
    |> Departments.effective_search_group_ids_by_project()
    |> Map.get(project_id, [])
    |> MapSet.new()
  end
end
