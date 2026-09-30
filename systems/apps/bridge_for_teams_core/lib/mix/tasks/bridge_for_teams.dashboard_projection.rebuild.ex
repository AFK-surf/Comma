defmodule Mix.Tasks.BridgeForTeams.DashboardProjection.Rebuild do
  @moduledoc """
  Rebuild BridgeForTeams My Space dashboard projections.

      mix bridge_for_teams.dashboard_projection.rebuild --org afk-ai --dry-run
      mix bridge_for_teams.dashboard_projection.rebuild --org afk-ai --project swarm-slug
  """
  use Mix.Task

  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Accounts, Agents, DashboardProjection, Orgs, Projects, Repo}
  alias BridgeForTeams.Schema.{Organization, Project}

  @shortdoc "Rebuild BFT My Space local dashboard projections"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          org: :string,
          project: :string,
          user: :string,
          concurrency: :integer,
          timeout: :integer,
          dry_run: :boolean,
          pretty: :boolean
        ],
        aliases: [o: :org, p: :project, u: :user]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")

    org_ref = opts[:org] || Mix.raise("Missing --org.\n\n#{usage()}")

    with {:ok, org} <- fetch_org(org_ref),
         {:ok, user} <- fetch_user(opts[:user]),
         {:ok, projects} <- scoped_projects(org, opts[:project], user) do
      dry_run? = Keyword.get(opts, :dry_run, false)
      rebuild_opts = rebuild_opts(opts, dry_run?)

      results =
        projects
        |> DashboardProjection.rebuild_projects(rebuild_opts)
        |> Enum.map(&format_result/1)

      Enum.each(results, fn result ->
        Logger.info("dashboard_projection_rebuild_result #{Jason.encode!(result)}")
      end)

      %{
        scope: %{
          org_id: org.id,
          org_slug: org.slug,
          project_count: length(projects),
          user_id: user && user.id
        },
        dry_run: dry_run?,
        concurrency: rebuild_opts[:concurrency],
        timeout_ms: rebuild_opts[:timeout],
        salix_call_counts: salix_call_counts(projects, dry_run?),
        failed_project_ids: failed_project_ids(results),
        results: results
      }
      |> Jason.encode!(pretty: Keyword.get(opts, :pretty, true))
      |> Mix.shell().info()
    else
      {:error, reason} -> Mix.raise("Could not rebuild dashboard projections: #{inspect(reason)}")
    end
  end

  defp scoped_projects(%Organization{} = org, nil, nil) do
    projects =
      from(p in Project,
        where: p.org_id == ^org.id and is_nil(p.archived_at),
        order_by: [asc: p.name]
      )
      |> Repo.all()

    {:ok, projects}
  end

  defp scoped_projects(%Organization{} = org, nil, user) do
    {:ok, Projects.list_projects_for_user(org.id, user.id)}
  end

  defp scoped_projects(%Organization{} = org, project_ref, user) do
    with {:ok, project} <- fetch_project(org, project_ref) do
      if is_nil(user) or
           Enum.any?(Projects.list_projects_for_user(org.id, user.id), &(&1.id == project.id)) do
        {:ok, [project]}
      else
        {:error, :project_not_visible_for_user}
      end
    end
  end

  defp fetch_org(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, id} ->
        case Orgs.get_org(id) do
          {:ok, org} -> {:ok, org}
          {:error, :not_found} -> Orgs.get_org_by_slug(ref)
        end

      :error ->
        Orgs.get_org_by_slug(ref)
    end
  end

  defp fetch_project(%Organization{} = org, ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, id} ->
        case Projects.get_project(id) do
          {:ok, project} when project.org_id == org.id -> {:ok, project}
          _ -> fetch_project_by_slug(org, ref)
        end

      :error ->
        fetch_project_by_slug(org, ref)
    end
  end

  defp fetch_project_by_slug(%Organization{} = org, ref) do
    org.id
    |> Projects.list_projects()
    |> Enum.find(&(&1.slug == ref or &1.name == ref))
    |> case do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  defp fetch_user(nil), do: {:ok, nil}

  defp fetch_user(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, id} ->
        case Accounts.get_user(id) do
          {:ok, user} -> {:ok, user}
          {:error, :not_found} -> Accounts.get_user_by_email(ref)
        end

      :error ->
        Accounts.get_user_by_email(ref)
    end
  end

  defp rebuild_opts(opts, dry_run?) do
    [
      dry_run: dry_run?,
      concurrency: positive_integer(opts[:concurrency], 2),
      timeout: positive_integer(opts[:timeout], 30_000)
    ]
  end

  defp salix_call_counts(_projects, true), do: %{}

  defp salix_call_counts(projects, false) do
    %{
      "list_group_conversations" => length(projects),
      "list_group_meetings" => length(projects),
      "list_group_oauth_bindings" => length(projects),
      "billing_history" =>
        Enum.reduce(projects, 0, fn project, acc ->
          acc + length(Agents.list_agents(project.id))
        end)
    }
  end

  defp failed_project_ids(results) do
    results
    |> Enum.filter(&(&1[:status] == "error"))
    |> Enum.map(& &1[:project_id])
  end

  defp format_result({:dry_run, project_id, stale?}) do
    %{project_id: project_id, action: "dry_run", stale_or_missing: stale?}
  end

  defp format_result({project_id, {:ok, snapshot}}) do
    %{
      project_id: project_id,
      status: "ok",
      conversation_count: snapshot.conversation_count,
      meeting_count: snapshot.meeting_count,
      token_total: snapshot.token_total,
      refreshed_at: snapshot.refreshed_at
    }
  end

  defp format_result({project_id, {:error, reason}}) do
    %{project_id: project_id, status: "error", reason: inspect(reason)}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp usage do
    """
    Usage:
      mix bridge_for_teams.dashboard_projection.rebuild --org ORG_SLUG_OR_ID [--dry-run]
      mix bridge_for_teams.dashboard_projection.rebuild --org ORG_SLUG_OR_ID --project PROJECT_SLUG_OR_ID
      mix bridge_for_teams.dashboard_projection.rebuild --org ORG_SLUG_OR_ID --user USER_EMAIL_OR_ID --concurrency 2 --timeout 30000
    """
  end
end
