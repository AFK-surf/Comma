defmodule Mix.Tasks.BridgeForTeams.RunChecks do
  @moduledoc """
  Emit the shared BridgeForTeams Feishu Run checks contract as JSON.

      mix bridge_for_teams.run_checks --surface sso --org acme --redirect-uri https://teams.example/auth/callback
      mix bridge_for_teams.run_checks --surface bot --org acme --project agent-swarm-slug
  """
  use Mix.Task

  alias BridgeForTeams.{Orgs, Projects, RunChecks}
  alias BridgeForTeams.Schema.Organization

  @shortdoc "Run BFT Feishu checks and print the redacted JSON contract"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          surface: :string,
          org: :string,
          project: :string,
          redirect_uri: :string,
          pretty: :boolean
        ],
        aliases: [s: :surface, o: :org, p: :project]
      )

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}\n\n#{usage()}")

    surface = opts[:surface] || Mix.raise("Missing --surface.\n\n#{usage()}")
    org_ref = opts[:org] || Mix.raise("Missing --org.\n\n#{usage()}")

    with {:ok, org} <- fetch_org(org_ref),
         {:ok, result} <- run_surface(surface, org, opts) do
      pretty? = Keyword.get(opts, :pretty, true)
      Mix.shell().info(RunChecks.encode_json!(result, pretty: pretty?))
    else
      {:error, reason} -> Mix.raise("Could not run checks: #{inspect(reason)}")
    end
  end

  defp run_surface("sso", %Organization{} = org, opts) do
    RunChecks.run_sso(org, redirect_uri: opts[:redirect_uri])
  end

  defp run_surface("bot", %Organization{} = org, opts) do
    project_ref =
      opts[:project] || Mix.raise("Missing --project for --surface bot.\n\n#{usage()}")

    with {:ok, project} <- fetch_project(org, project_ref) do
      RunChecks.run_bot(org, project)
    end
  end

  defp run_surface(surface, _org, _opts),
    do: {:error, {:unsupported_surface, surface}}

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

  defp usage do
    """
    Usage:
      mix bridge_for_teams.run_checks --surface sso --org ORG_SLUG_OR_ID [--redirect-uri URL]
      mix bridge_for_teams.run_checks --surface bot --org ORG_SLUG_OR_ID --project PROJECT_SLUG_OR_ID
    """
  end
end
