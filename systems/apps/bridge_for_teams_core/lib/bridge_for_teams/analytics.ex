defmodule BridgeForTeams.Analytics do
  @moduledoc """
  Read-only dashboard analytics from Bridge-owned local snapshots.
  """
  import Ecto.Query

  alias BridgeForTeams.{DashboardProjection, Projects, Repo}
  alias BridgeForTeams.Schema.{Organization, Project}

  @type token_usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec org_home_summary(Ecto.UUID.t()) :: map()
  def org_home_summary(org_id) do
    org = Repo.get(Organization, org_id)
    projects = list_active_projects(org_id)
    summarize_projects(org, projects)
  end

  @spec org_home_summary(Ecto.UUID.t(), Ecto.UUID.t()) :: map()
  def org_home_summary(org_id, user_id) do
    org_home_summary(org_id, user_id, [])
  end

  @spec org_home_summary(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: map()
  def org_home_summary(org_id, user_id, _opts) do
    org = Repo.get(Organization, org_id)
    projects = Projects.list_projects_for_user(org_id, user_id)
    summarize_projects(org, projects)
  end

  defp summarize_projects(_org, projects) do
    snapshots = DashboardProjection.snapshots_for_projects(Enum.map(projects, & &1.id))

    rows =
      Enum.map(projects, fn project ->
        project_usage(project, Map.get(snapshots, project.id))
      end)

    used_project_count = Enum.count(rows, &(&1.conversation_count > 0))
    token_totals = Enum.reduce(rows, empty_usage(), &merge_usage(&2, &1.token_usage))
    conversation_count = Enum.reduce(rows, 0, &(&2 + &1.conversation_count))

    %{
      project_count: length(projects),
      used_project_count: used_project_count,
      unused_project_count: max(length(projects) - used_project_count, 0),
      conversation_count: conversation_count,
      token_totals: token_totals,
      project_usage_rows:
        rows
        |> Enum.sort_by(&{&1.token_usage.total, &1.conversation_count, &1.name}, :desc)
        |> Enum.take(5)
    }
  end

  defp list_active_projects(org_id) do
    from(p in Project,
      where: p.org_id == ^org_id and is_nil(p.archived_at),
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  defp project_usage(%Project{} = project, nil) do
    %{
      project_id: project.id,
      name: project.name,
      conversation_count: 0,
      token_usage: empty_usage(),
      snapshot_status: :missing
    }
  end

  defp project_usage(%Project{} = project, snapshot) do
    %{
      project_id: project.id,
      name: project.name,
      conversation_count: snapshot.conversation_count || 0,
      token_usage: %{
        input: snapshot.token_input || 0,
        output: snapshot.token_output || 0,
        cache_read: snapshot.token_cache_read || 0,
        cache_write: snapshot.token_cache_write || 0,
        total: snapshot.token_total || 0
      },
      snapshot_status: snapshot_status(snapshot),
      refreshed_at: snapshot.refreshed_at,
      refresh_error: snapshot.refresh_error
    }
  end

  defp snapshot_status(%{refresh_error: error}) when is_binary(error) and error != "", do: :error
  defp snapshot_status(%{refreshing_at: %DateTime{}}), do: :refreshing
  defp snapshot_status(%{stale_at: %DateTime{}}), do: :stale
  defp snapshot_status(_snapshot), do: :ready

  defp merge_usage(left, right) do
    %{
      input: left.input + right.input,
      output: left.output + right.output,
      cache_read: left.cache_read + right.cache_read,
      cache_write: left.cache_write + right.cache_write,
      total: left.total + right.total
    }
  end

  defp empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0}
end
