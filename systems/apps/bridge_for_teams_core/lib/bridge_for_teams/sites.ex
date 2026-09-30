defmodule BridgeForTeams.Sites do
  @moduledoc """
  Deployed agent-hosted websites for a project.

  Salix is the source of truth: each project agent may host static websites in
  its VFS under `/.salix/websites/<name>`, which Salix serves at
  `{site}-{base32-agent-id}.{sites-domain}`. This context fans out over the
  project's provisioned agents and reads each one's published sites from Salix
  over `:erpc` (`SalixAgent.Workspace.list_sites/1`), tagging every site with the
  owning agent so the project dashboard can list them all in one place.
  """
  alias BridgeForTeams.Agents
  alias BridgeForTeams.Observability
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Salix.ReadCache
  alias BridgeForTeams.Schema.{Agent, Project}

  require Logger

  # Salix briefly unreachable — surface so the UI can say so rather than show a
  # misleadingly empty list. Other per-agent errors (e.g. an agent not yet
  # provisioned in Salix) just contribute no sites.
  @transient [:unavailable, :timeout]

  # Bounded fan-out over the project's agents. The per-task timeout is a
  # backstop above the erpc impl's own short dashboard-read timeout (~3s call
  # + 5s erpc budget); a killed task counts as a transient :timeout.
  @list_sites_max_concurrency 8
  @list_sites_task_timeout_ms 10_000

  # Cached project-sites reads (`cache: true`) live this long. Errors are never
  # cached (see `BridgeForTeams.Salix.ReadCache`).
  @sites_cache_ttl_ms 45_000

  @doc """
  Publish (or update) a static site under one of the project's agents by
  writing `index.html` into the agent's VFS at `/.salix/websites/<name>/`.
  Salix serves it immediately at `{name}-{base32-agent-id}.{sites-domain}`.

  Uses the project's first provisioned agent. Returns `{:ok, site}` with the
  same string-keyed shape as `list_project_sites/1`, or `{:error, :no_agent}`
  when the project has no Salix-provisioned agent, or the Salix write error.
  """
  @spec publish_project_site(Project.t(), String.t(), binary()) ::
          {:ok, map()} | {:error, term()}
  def publish_project_site(%Project{} = project, site_name, index_html)
      when is_binary(site_name) and is_binary(index_html) do
    with {:ok, agents} <- Agents.fetch_agents(project.id),
         %Agent{} = agent <- List.first(agents) || {:error, :no_agent},
         path = "/.salix/websites/#{site_name}/index.html",
         {:ok, _result} <-
           Client.impl().write_agent_file(agent.salix_agent_id, path, index_html),
         {:ok, sites} <- Client.impl().list_agent_sites(agent.salix_agent_id) do
      case Enum.find(sites, &(&1["name"] == site_name)) do
        nil -> {:error, :site_not_listed}
        site -> {:ok, decorate(site, agent)}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  List every deployed website across the project's (non-archived) agents.

  Returns `{:ok, [site]}` where each `site` is a string-keyed map:

      %{"name" => "marketing", "url" => "https://marketing-<b32>.example.com",
        "agent_id" => <bft agent uuid>, "salix_agent_id" => "agt1_...",
        "agent_name" => "router"}

  Sites are grouped by agent (agents ordered by name, sites by name). When Salix
  is unreachable the whole call returns `{:error, :unavailable | :timeout}`.

  Agents are queried concurrently (bounded fan-out). Options:

    * `cache: true` — serve from `BridgeForTeams.Salix.ReadCache` under
      `{:project_sites, project_id}` (TTL #{@sites_cache_ttl_ms}ms) for
      dashboard render paths; errors are never cached. Defaults to `false`.
  """
  @spec list_project_sites(Project.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_project_sites(%Project{} = project, opts \\ []) do
    if Keyword.get(opts, :cache, false) do
      ReadCache.fetch({:project_sites, project.id}, @sites_cache_ttl_ms, fn ->
        do_list_project_sites(project)
      end)
    else
      do_list_project_sites(project)
    end
  end

  @doc "Drop the cached `list_project_sites/2` entry for a project."
  @spec invalidate_project_sites_cache(String.t()) :: :ok
  def invalidate_project_sites_cache(project_id) when is_binary(project_id) do
    ReadCache.invalidate({:project_sites, project_id})
  end

  defp do_list_project_sites(%Project{} = project) do
    case Agents.fetch_agents(project.id) do
      {:ok, agents} ->
        do_list_project_sites(project, agents)

      {:error, _} = error ->
        maybe_record_sites_diagnostic(project, [], error)
        error
    end
  end

  defp do_list_project_sites(project, agents) do
    result =
      agents
      |> Task.async_stream(
        fn agent -> {agent, Client.impl().list_agent_sites(agent.salix_agent_id)} end,
        max_concurrency: @list_sites_max_concurrency,
        timeout: @list_sites_task_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.reduce({:ok, []}, fn
        # First transient error (in agent order) wins; later results are ignored.
        _outcome, {:error, _reason} = error ->
          error

        {:ok, {agent, {:ok, sites}}}, {:ok, acc} when is_list(sites) ->
          {:ok, acc ++ Enum.map(sites, &decorate(&1, agent))}

        {:ok, {_agent, {:error, reason}}}, {:ok, _acc} when reason in @transient ->
          {:error, reason}

        # Agent not provisioned / no readable state yet — contributes no sites.
        {:ok, {_agent, {:error, _other}}}, {:ok, acc} ->
          {:ok, acc}

        # Task killed by the async_stream backstop timeout — transient.
        {:exit, _reason}, {:ok, _acc} ->
          {:error, :timeout}
      end)

    maybe_record_sites_diagnostic(project, agents, result)

    result
  end

  defp maybe_record_sites_diagnostic(%Project{} = project, agents, {:error, reason})
       when reason in @transient do
    reason_class = Atom.to_string(reason)

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "project",
      resource_type: "project_website_index",
      resource_id: project.id,
      source: "salix.control",
      event_type: "project.websites.unavailable",
      severity: "warning",
      status: "unavailable",
      reason_class: reason_class,
      summary: "Project websites could not be loaded from Salix",
      evidence: %{
        "project_id" => project.id,
        "salix_group_id" => project.salix_group_id,
        "salix_agent_count" => length(agents),
        "surface" => "project_websites",
        "reason_class" => reason_class,
        "status" => "unavailable"
      },
      correlation_id: "project:#{project.id}:websites:index",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, observability_reason} ->
        Logger.warning(
          "project_websites_observability_failed reason=#{inspect(observability_reason)} project_id=#{project.id}"
        )
    end
  end

  defp maybe_record_sites_diagnostic(_project, _agents, _result), do: :ok

  defp decorate(site, %Agent{} = agent) when is_map(site) do
    %{
      "name" => site["name"],
      "url" => site["url"],
      "agent_id" => agent.id,
      "salix_agent_id" => agent.salix_agent_id,
      "agent_name" => agent.salix["name"] || agent.salix_agent_id
    }
  end
end
