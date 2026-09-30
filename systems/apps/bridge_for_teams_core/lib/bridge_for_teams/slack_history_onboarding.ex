defmodule BridgeForTeams.SlackHistoryOnboarding do
  @moduledoc """
  Product coordinator for starting bounded Slack-history dry runs.

  Browser input names only the BFT project, Slack connect, channel ids, and
  requested time window. Salix reissues the exact workspace, app, connect
  generation, and per-channel authority revision before any run is persisted;
  caller-supplied authority fields are deliberately ignored.

  Acquisition is independent from live Triage enablement. A connected source
  may be imported while live listening is off, and disconnecting the source
  never rolls back or deletes a completed publication.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo, SlackHistoryImports}
  alias BridgeForTeams.Salix.Client

  alias BridgeForTeams.Schema.{
    ContextBundle,
    Organization,
    Project,
    SlackHistoryImportChannel,
    SlackHistoryImportRun,
    SourcedContextPublication,
    User
  }

  @default_range_days 7
  @max_range_days 30
  @max_interactive_channels 10
  @authority_concurrency 5
  @authority_timeout_ms 10_000
  @run_limit 20

  @installation_authority_fields [
    :tenant_id,
    :group_id,
    :connect_id,
    :connect_generation,
    :workspace_id,
    :app_id
  ]

  @type start_result :: {:ok, SlackHistoryImportRun.t()} | {:error, term()}

  @type readiness :: %{
          onboarding_preview?: boolean(),
          discovery?: boolean(),
          acquisition?: boolean(),
          derivation?: boolean(),
          worker?: boolean(),
          processor?: boolean(),
          dry_run?: boolean(),
          commit?: boolean(),
          grounding?: boolean(),
          knowledge_inspection?: boolean()
        }

  @doc "Returns the independently gated launch slices used by context onboarding."
  @spec readiness() :: readiness()
  def readiness do
    features = Application.get_env(:bridge_for_teams_core, :sourced_context_features, [])
    discovery? = features[:discovery] == true
    acquisition? = features[:acquisition] == true
    derivation? = features[:derivation] == true
    worker? = BridgeForTeams.SlackHistoryOnboarding.Reconciler.configured?()
    processor? = BridgeForTeams.SlackHistoryOnboarding.Reconciler.processor_configured?()

    %{
      onboarding_preview?: features[:onboarding_preview] == true,
      discovery?: discovery?,
      acquisition?: acquisition?,
      derivation?: derivation?,
      worker?: worker?,
      processor?: processor?,
      dry_run?: discovery? and acquisition? and derivation? and worker? and processor?,
      commit?: features[:commit] == true,
      grounding?: features[:grounding] == true,
      knowledge_inspection?: features[:knowledge_inspection] == true
    }
  end

  @doc "Whether the internal product preview may start a new dry run."
  @spec available?() :: boolean()
  def available? do
    readiness = readiness()
    readiness.onboarding_preview? and readiness.dry_run?
  end

  @doc "Start one immutable dry run from server-verified Slack source authority."
  @spec start_dry_run(Organization.t() | Ecto.UUID.t(), User.t() | Ecto.UUID.t(), map()) ::
          start_result()
  def start_dry_run(org_ref, user_ref, attrs) when is_map(attrs) do
    with :ok <- require_available(),
         {:ok, org} <- fetch_org(org_ref),
         {:ok, user_id} <- user_id(user_ref),
         {:ok, project} <- fetch_project(org, value(attrs, :project_id)),
         :ok <- authorize(user_id, project.id),
         {:ok, connect_id} <- nonblank(value(attrs, :connect_id), :invalid_connect),
         {:ok, _expected_installation} <-
           expected_installation(value(attrs, :expected_source_installation), connect_id),
         {:ok, channel_ids} <- normalize_channel_ids(value(attrs, :channel_ids)),
         {:ok, client_request_id} <- uuid(value(attrs, :client_request_id)),
         {:ok, run} <-
           create_or_replay(
             org,
             project,
             user_id,
             connect_id,
             channel_ids,
             client_request_id,
             attrs
           ) do
      BridgeForTeams.SlackHistoryOnboarding.Reconciler.notify(run.id)
      {:ok, run}
    end
  end

  def start_dry_run(_org, _user, _attrs), do: {:error, :invalid_dry_run}

  @doc "List the newest bounded set of runs visible to a project admin."
  @spec list_runs(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [SlackHistoryImportRun.t()]} | {:error, term()}
  def list_runs(project_id, user_id) do
    with {:ok, page} <- list_runs_page(project_id, user_id) do
      {:ok, page.runs}
    end
  end

  @doc "List one bounded import-ledger page; the cursor is the last run id from the prior page."
  @spec list_runs_page(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{runs: [SlackHistoryImportRun.t()], next_cursor: Ecto.UUID.t() | nil}}
          | {:error, term()}
  def list_runs_page(project_id, user_id, opts \\ []) when is_list(opts) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, user_id} <- uuid(user_id),
         %Project{} <- Repo.get(Project, project_id),
         :ok <- authorize(user_id, project_id),
         {:ok, cursor} <- run_cursor(project_id, Keyword.get(opts, :before)) do
      channel_query = from(channel in SlackHistoryImportChannel, order_by: channel.channel_id)

      query =
        from(run in SlackHistoryImportRun,
          where: run.project_id == ^project_id,
          order_by: [desc: run.created_at, desc: run.id]
        )

      query =
        case cursor do
          nil ->
            query

          cursor ->
            from(run in query,
              where:
                run.created_at < ^cursor.created_at or
                  (run.created_at == ^cursor.created_at and run.id < ^cursor.id)
            )
        end

      rows =
        Repo.all(
          from(run in query,
            limit: ^(@run_limit + 1),
            preload: [:context_bundle, channels: ^channel_query]
          )
        )

      runs = Enum.take(rows, @run_limit)
      next_cursor = if length(rows) > @run_limit, do: List.last(runs).id, else: nil

      {:ok, %{runs: runs, next_cursor: next_cursor}}
    else
      nil -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load the newest publication that still makes Slack context available to the project."
  @spec active_context_run(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SlackHistoryImportRun.t() | nil} | {:error, term()}
  def active_context_run(project_id, user_id) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, user_id} <- uuid(user_id),
         %Project{} <- Repo.get(Project, project_id),
         :ok <- authorize(user_id, project_id) do
      channel_query = from(channel in SlackHistoryImportChannel, order_by: channel.channel_id)

      run =
        Repo.one(
          from(run in SlackHistoryImportRun,
            join: publication in SourcedContextPublication,
            on:
              publication.run_id == run.id and publication.id == run.publication_id and
                publication.status == "active",
            join: bundle in ContextBundle,
            on: bundle.id == publication.bundle_id and bundle.id == run.context_bundle_id,
            where:
              run.project_id == ^project_id and run.state == "committed" and
                bundle.project_id == ^project_id and bundle.lifecycle_state == "registered" and
                bundle.subject_index_state == "complete",
            order_by: [desc: publication.activated_at, desc: publication.id],
            limit: 1,
            preload: [:context_bundle, channels: ^channel_query]
          )
        )

      {:ok, run}
    else
      nil -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load one exact run under current project-admin authority."
  @spec get_run(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SlackHistoryImportRun.t()} | {:error, term()}
  def get_run(project_id, user_id, run_id) do
    with {:ok, project_id} <- uuid(project_id),
         {:ok, user_id} <- uuid(user_id),
         {:ok, run_id} <- uuid(run_id),
         %Project{} <- Repo.get(Project, project_id),
         :ok <- authorize(user_id, project_id),
         %{id: _, created_at: _} = run <-
           Repo.one(
             from(run in SlackHistoryImportRun,
               where: run.id == ^run_id and run.project_id == ^project_id,
               preload: [:context_bundle, :channels]
             )
           ) do
      {:ok, run}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_cursor(_project_id, nil), do: {:ok, nil}
  defp run_cursor(_project_id, ""), do: {:ok, nil}

  defp run_cursor(project_id, run_id) do
    with {:ok, run_id} <- uuid(run_id),
         %{id: _, created_at: _} = run <-
           Repo.one(
             from(run in SlackHistoryImportRun,
               where: run.id == ^run_id and run.project_id == ^project_id,
               select: %{id: run.id, created_at: run.created_at}
             )
           ) do
      {:ok, run}
    else
      _error -> {:error, :invalid_run_cursor}
    end
  end

  defp create_or_replay(org, project, user_id, connect_id, channel_ids, client_request_id, attrs) do
    case SlackHistoryImports.get_run_by_request(org.id, user_id, client_request_id) do
      {:ok, run} ->
        replay_existing(run, project, connect_id, channel_ids, attrs)

      {:error, :not_found} ->
        create_authorized_run(
          org,
          project,
          user_id,
          connect_id,
          channel_ids,
          client_request_id,
          attrs
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_authorized_run(
         org,
         project,
         user_id,
         connect_id,
         channel_ids,
         client_request_id,
         attrs
       ) do
    with {:ok, range_start, range_end} <- normalize_range(attrs),
         {:ok, authority} <- source_authority(org, project, connect_id, channel_ids),
         {:ok, expected} <-
           expected_installation(value(attrs, :expected_source_installation), connect_id),
         :ok <- installation_unchanged(authority, expected) do
      run_attrs = %{
        org_id: org.id,
        project_id: project.id,
        requested_by_user_id: user_id,
        client_request_id: client_request_id,
        salix_tenant_id: org.salix_tenant_id,
        salix_group_id: project.salix_group_id,
        source_workspace_id: authority.workspace_id,
        source_app_id: authority.app_id,
        connect_id: authority.connect_id,
        connect_generation: authority.connect_generation,
        selected_channels: authority.channels,
        range_start: range_start,
        range_end: range_end,
        policy_revision: "context-lifecycle:v1",
        coverage_profile: "slack-root-bounded:v1",
        audience_scope: "project-public-channels:v1"
      }

      persist_authorized_run(run_attrs, value(attrs, :replaces_run_id))
    end
  end

  defp persist_authorized_run(run_attrs, replaces_run_id) do
    case replacement_candidate(replaces_run_id, run_attrs) do
      {:ok, old_run} ->
        case SlackHistoryImports.restart_after_reconnect(old_run.id, %{
               expected_generation: old_run.generation,
               requested_by_user_id: run_attrs.requested_by_user_id,
               client_request_id: run_attrs.client_request_id,
               source_workspace_id: run_attrs.source_workspace_id,
               source_app_id: run_attrs.source_app_id,
               connect_id: run_attrs.connect_id,
               connect_generation: run_attrs.connect_generation,
               selected_channels: run_attrs.selected_channels,
               range_start: run_attrs.range_start,
               range_end: run_attrs.range_end,
               policy_revision: run_attrs.policy_revision,
               coverage_profile: run_attrs.coverage_profile,
               audience_scope: run_attrs.audience_scope
             }) do
          {:ok, run, _event} -> {:ok, run}
          {:error, reason} -> {:error, reason}
        end

      :unrelated ->
        SlackHistoryImports.create_run(run_attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replacement_candidate(nil, _run_attrs), do: :unrelated
  defp replacement_candidate("", _run_attrs), do: :unrelated

  defp replacement_candidate(old_run_id, run_attrs) do
    with {:ok, old_run} <- SlackHistoryImports.get_run(old_run_id),
         true <- old_run.org_id == run_attrs.org_id and old_run.project_id == run_attrs.project_id do
      cond do
        old_run.state not in [
          "stale_source",
          "acquired",
          "deriving",
          "preview_ready",
          "committed",
          "rolled_back"
        ] ->
          {:error, :invalid_replacement_state}

        old_run.source_workspace_id != run_attrs.source_workspace_id ->
          {:error, :replacement_workspace_changed}

        old_run.connect_generation == run_attrs.connect_generation ->
          {:error, :connect_generation_not_advanced}

        true ->
          {:ok, old_run}
      end
    else
      _error -> {:error, :replacement_run_not_found}
    end
  end

  defp expected_installation(installation, connect_id) when is_map(installation) do
    normalized = %{
      connect_id: trim(value(installation, :connect_id)),
      connect_generation: trim(value(installation, :connect_generation)),
      workspace_id: trim(value(installation, :workspace_id)),
      app_id: trim(value(installation, :app_id))
    }

    if normalized.connect_id == connect_id and normalized.connect_generation != "" and
         normalized.workspace_id != "" and normalized.app_id != "" do
      {:ok, normalized}
    else
      {:error, :invalid_expected_source_installation}
    end
  end

  defp expected_installation(_installation, _connect_id),
    do: {:error, :invalid_expected_source_installation}

  defp installation_unchanged(authority, expected) do
    if authority.connect_id == expected.connect_id and
         authority.connect_generation == expected.connect_generation and
         authority.workspace_id == expected.workspace_id and authority.app_id == expected.app_id do
      :ok
    else
      {:error, :source_installation_changed}
    end
  end

  defp replay_existing(run, project, connect_id, channel_ids, attrs) do
    existing_channel_ids = Enum.map(run.channels, & &1.channel_id)

    if run.project_id == project.id and run.connect_id == connect_id and
         existing_channel_ids == channel_ids and replay_range_matches?(run, attrs) and
         replay_replacement_matches?(run, value(attrs, :replaces_run_id)) do
      {:ok, run}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp replay_range_matches?(run, attrs) do
    case {value(attrs, :range_start), value(attrs, :range_end)} do
      {%DateTime{} = start_at, %DateTime{} = end_at} ->
        DateTime.compare(run.range_start, start_at) == :eq and
          DateTime.compare(run.range_end, end_at) == :eq

      _relative ->
        case normalize_range_days(value(attrs, :range_days)) do
          {:ok, days} -> DateTime.diff(run.range_end, run.range_start, :second) == days * 86_400
          {:error, _reason} -> false
        end
    end
  end

  defp replay_replacement_matches?(%{replaces_run_id: nil}, requested),
    do: requested in [nil, ""]

  defp replay_replacement_matches?(run, replaces_run_id),
    do: run.replaces_run_id == replaces_run_id

  defp source_authority(org, project, connect_id, channel_ids) do
    channel_ids
    |> Task.async_stream(
      fn channel_id ->
        Client.impl().slack_history_source_authority(%{
          tenant_id: org.salix_tenant_id,
          group_id: project.salix_group_id,
          connect_id: connect_id,
          channel_id: channel_id
        })
      end,
      ordered: true,
      max_concurrency: @authority_concurrency,
      timeout: @authority_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(channel_ids)
    |> Enum.reduce_while({:ok, []}, fn
      {{:ok, {:ok, authority}}, channel_id}, {:ok, acc} ->
        case normalize_authority(authority, org, project, connect_id, channel_id) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {{:ok, {:error, reason}}, _channel_id}, _acc ->
        {:halt, {:error, normalize_source_error(reason)}}

      {{:exit, :timeout}, _channel_id}, _acc ->
        {:halt, {:error, :source_authority_timeout}}

      {{:exit, _reason}, _channel_id}, _acc ->
        {:halt, {:error, :source_authority_unavailable}}
    end)
    |> combine_authorities()
  end

  defp normalize_authority(authority, org, project, connect_id, channel_id)
       when is_map(authority) do
    channel = value(authority, :channel)

    normalized = %{
      tenant_id: trim(value(authority, :tenant_id)),
      group_id: trim(value(authority, :group_id)),
      connect_id: trim(value(authority, :connect_id)),
      connect_generation: trim(value(authority, :connect_generation)),
      workspace_id: trim(value(authority, :workspace_id)),
      app_id: trim(value(authority, :app_id)),
      channel: %{
        id: trim(value(channel, :id)),
        name: optional_trim(value(channel, :name)),
        visibility: trim(value(channel, :visibility)),
        authority_revision: trim(value(channel, :authority_revision)),
        is_member: value(channel, :is_member)
      }
    }

    if normalized.tenant_id == org.salix_tenant_id and
         normalized.group_id == project.salix_group_id and
         normalized.connect_id == connect_id and
         normalized.channel.id == channel_id and
         normalized.channel.visibility == "public" and
         normalized.channel.is_member == true and
         normalized.connect_generation != "" and normalized.workspace_id != "" and
         normalized.app_id != "" and sha256?(normalized.channel.authority_revision) do
      {:ok, normalized}
    else
      {:error, :invalid_source_authority}
    end
  end

  defp normalize_authority(_authority, _org, _project, _connect_id, _channel_id),
    do: {:error, :invalid_source_authority}

  defp combine_authorities({:error, reason}), do: {:error, reason}

  defp combine_authorities({:ok, authorities}) do
    authorities = Enum.reverse(authorities)

    case authorities do
      [first | _] ->
        if Enum.all?(authorities, &same_installation?(&1, first)) do
          {:ok,
           %{
             connect_id: first.connect_id,
             connect_generation: first.connect_generation,
             workspace_id: first.workspace_id,
             app_id: first.app_id,
             channels:
               Enum.map(authorities, fn item ->
                 %{
                   id: item.channel.id,
                   name: item.channel.name,
                   visibility: item.channel.visibility,
                   authority_revision: item.channel.authority_revision
                 }
               end)
           }}
        else
          {:error, :source_authority_changed}
        end

      [] ->
        {:error, :invalid_channels}
    end
  end

  defp same_installation?(left, right) do
    Map.take(left, @installation_authority_fields) ==
      Map.take(right, @installation_authority_fields)
  end

  defp fetch_org(%Organization{} = org), do: {:ok, org}

  defp fetch_org(id) do
    with {:ok, id} <- uuid(id),
         %Organization{} = org <- Repo.get(Organization, id) do
      {:ok, org}
    else
      nil -> {:error, :org_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_project(org, project_id) do
    with {:ok, project_id} <- uuid(project_id),
         %Project{} = project <- Repo.get(Project, project_id),
         true <-
           project.org_id == org.id and project.status == "active" and is_nil(project.archived_at),
         true <- is_binary(project.salix_group_id) and project.salix_group_id != "" do
      {:ok, project}
    else
      nil -> {:error, :project_not_found}
      false -> {:error, :project_outside_org}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(user_id, project_id) do
    case Memberships.authorize(user_id, :write, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp user_id(%User{id: id}), do: {:ok, id}
  defp user_id(id), do: uuid(id)

  defp normalize_channel_ids(channel_ids) when is_list(channel_ids) do
    normalized = channel_ids |> Enum.map(&trim/1) |> Enum.reject(&(&1 == ""))

    if normalized != [] and length(normalized) <= @max_interactive_channels and
         length(normalized) == length(Enum.uniq(normalized)) do
      {:ok, Enum.sort(normalized)}
    else
      {:error, :invalid_channels}
    end
  end

  defp normalize_channel_ids(_channel_ids), do: {:error, :invalid_channels}

  defp normalize_range(attrs) do
    case {value(attrs, :range_start), value(attrs, :range_end)} do
      {%DateTime{} = start_at, %DateTime{} = end_at} -> validate_range(start_at, end_at)
      _other -> default_range(value(attrs, :range_days))
    end
  end

  defp default_range(nil), do: default_range(@default_range_days)
  defp default_range(""), do: default_range(@default_range_days)

  defp default_range(days) when is_binary(days) do
    with {:ok, days} <- normalize_range_days(days), do: default_range(days)
  end

  defp default_range(days) when is_integer(days) and days in 1..@max_range_days do
    range_end = DateTime.utc_now()
    validate_range(DateTime.add(range_end, -days, :day), range_end)
  end

  defp default_range(_days), do: {:error, :invalid_range}

  defp normalize_range_days(nil), do: {:ok, @default_range_days}
  defp normalize_range_days(""), do: {:ok, @default_range_days}

  defp normalize_range_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} -> normalize_range_days(days)
      _invalid -> {:error, :invalid_range}
    end
  end

  defp normalize_range_days(days) when is_integer(days) and days in 1..@max_range_days,
    do: {:ok, days}

  defp normalize_range_days(_days), do: {:error, :invalid_range}

  defp validate_range(start_at, end_at) do
    seconds = DateTime.diff(end_at, start_at, :second)

    if seconds > 0 and seconds <= @max_range_days * 86_400,
      do: {:ok, start_at, end_at},
      else: {:error, :invalid_range}
  end

  defp require_available do
    if available?(), do: :ok, else: {:error, {:feature_disabled, :slack_history_onboarding}}
  end

  defp normalize_source_error(:disabled), do: {:feature_disabled, :salix_slack_history_read}
  defp normalize_source_error(reason), do: reason

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp nonblank(value, error) do
    case trim(value) do
      "" -> {:error, error}
      normalized -> {:ok, normalized}
    end
  end

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_other, _key), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
  defp optional_trim(nil), do: nil
  defp optional_trim(value), do: trim(value)
end
