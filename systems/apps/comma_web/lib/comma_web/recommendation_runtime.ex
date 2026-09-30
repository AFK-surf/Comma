defmodule CommaWeb.RecommendationRuntime do
  @moduledoc "Coordinates durable Routine work without running a conversational Agent."

  require Logger
  alias Comma.{Recommendations, RecommendationDraft, Repo}
  alias Comma.Data.RecommendationProfile
  alias Comma.Workers.{RecommendationGenerate, RecommendationReconcile}
  alias CommaWeb.{MemberSourceIngest, RecommendationRenderer, RecommendationSourceCollector}
  alias SalixAgent.AgentControl

  def read(ctx), do: read(%{}, ctx)
  def read(args, ctx), do: CommaWeb.ProactiveRoutine.read(args, ctx)

  def ensure(user, session, workspace, timezone \\ nil, locale \\ nil, opts \\ []) do
    with {:ok, envelope} <-
           Recommendations.get(user, session, workspace["id"], timezone, locale, opts),
         {:ok, profile} <- Recommendations.get_runtime_profile(workspace["id"], user["id"]),
         {:ok, _} <- Recommendations.enqueue_source_sync(profile.id),
         {:ok, _} <- enqueue_reconcile(profile.id) do
      {:ok, CommaWeb.ProactiveRoutine.project(envelope, workspace)}
    end
  end

  def reconcile(user, _session, workspace) do
    with {:ok, profile} <- Recommendations.get_runtime_profile(workspace["id"], user["id"]),
         :ok <- CommaWeb.RecommendationSchedule.reconcile(profile.id) do
      {:ok, profile}
    end
  end

  defp enqueue_reconcile(profile_id) do
    %{profile_id: profile_id}
    |> RecommendationReconcile.new(unique: [period: 300, fields: [:worker, :args]])
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  def reconcile_profile(profile_id, opts \\ []) do
    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         :ok <- CommaWeb.RecommendationSchedule.reconcile(profile.id) do
      if opts[:retire_renderer],
        do: CommaWeb.RecommendationSchedule.retire_renderer(profile.id),
        else: :ok
    else
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  def sync_sources(profile_id, opts \\ []) do
    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, workspace} <- authorized_workspace(profile),
         {:ok, sources} <-
           CommaWeb.RecommendationSources.discover(
             workspace,
             profile.user_id,
             Recommendations.relevance_mode(profile),
             profile.sources
           ),
         {:ok, updated} <- Recommendations.reconcile_discovered_sources(profile.id, sources) do
      case {opts[:refresh_token], updated.source_revision == profile.source_revision} do
        {token, true} when is_binary(token) ->
          Recommendations.begin_confirmation_refresh(profile.id, token)

        _ ->
          :ok
      end
    else
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  defdelegate begin_schedule_occurrence(profile_id, schedule_id, scheduled_for),
    to: Recommendations

  def refresh_sources(profile_id, revision) do
    case Recommendations.begin_source_refresh(profile_id, revision) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  def prepare_refresh(user, session, workspace, timezone \\ nil, locale \\ nil) do
    case ensure(user, session, workspace, timezone, locale) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def reset_for_mode_change(user, session, workspace) do
    with {:ok, _} <- ensure(user, session, workspace),
         {:ok, profile} <-
           Recommendations.reset_sources_for_mode_change(user, session, workspace["id"]) do
      case sync_sources(profile.id) do
        {:error, {:composio_source_discovery_failed, :not_configured}} -> :ok
        other -> other
      end
    end
  end

  def generate(run_id) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, %{run: run, profile: profile}} <- Recommendations.run_context(run_id),
           true <- run.status in ~w(pending running),
           {:ok, workspace} <-
             stage(authorized_workspace(profile), :workspace_unavailable),
           remaining = RecommendationGenerate.remaining_ms(run),
           true <- remaining > 0,
           {:ok, collection} <-
             stage(
               collect(
                 workspace,
                 profile,
                 run,
                 min(remaining, Comma.RecommendationBudgets.source_collection_timeout_ms())
               ),
               :source_collection_failed
             ),
           collection =
             collection
             |> CommaWeb.RecommendationMailTasks.prepare(workspace)
             |> then(&if(member?(run), do: MemberSourceIngest.keep_mail(&1), else: &1)),
           :ok <- usable_sources(collection),
           {:ok, run} <-
             Recommendations.record_source_evidence(run_id, collection.facts, collection.failures),
           context =
             if(member?(run),
               do: MemberSourceIngest.context(collection, run.source_evidence),
               else: RecommendationDraft.prepare(collection.facts, run.source_evidence)
             ),
           remaining = RecommendationGenerate.remaining_ms(run),
           true <- remaining > 0,
           {:ok, draft, metadata} <-
             render(
               workspace,
               profile,
               run,
               collection,
               context,
               remaining
             ),
           {:ok, snapshot} <-
             RecommendationDraft.compile(draft, context, run, collection.failures,
               locale: profile.locale
             ),
           snapshot = CommaWeb.ProactiveRoutine.attach(snapshot, collection.facts),
           snapshot = CommaWeb.RecommendationMailTasks.project(snapshot, collection.facts),
           :ok <- Comma.RecommendationContract.validate(snapshot),
           {:ok, _workspace} <- stage(authorized_workspace(profile), :workspace_unavailable),
           {:ok, {outcome, _}} <-
             Recommendations.publish(
               run_id,
               snapshot,
               generation_metrics(run, collection, context, metadata)
             ) do
        Logger.info(
          "routine_generation " <>
            Jason.encode!(
              Map.merge(metadata, %{
                "runId" => run_id,
                "outcome" => to_string(outcome),
                "durationMs" => System.monotonic_time(:millisecond) - started,
                "sourceCount" => length(collection.facts),
                "sourceCollectionMs" => collection.duration_ms,
                "sourceFailureCount" => length(collection.failures)
              })
            )
        )

        :ok
      else
        false -> {:error, :recommendation_run_timed_out}
        {:error, :run_already_finished} -> :ok
        {:error, _} = error -> error
      end

    # The same bounded reason `Recommendations.fail/2` stores; never source content.
    case result do
      {:error, reason} ->
        Logger.warning(
          "routine_generation " <>
            Jason.encode!(%{
              "runId" => run_id,
              "outcome" => "failed",
              "reason" => reason |> inspect(limit: 3) |> String.slice(0, 240),
              "durationMs" => System.monotonic_time(:millisecond) - started
            })
        )

      :ok ->
        :ok
    end

    result
  end

  # Member runs read the member source item pool, the only member read path. A
  # scheduled run accepts items the collection chain read within its interval;
  # a run the member asked for, or one after a source change, reads again when
  # the pool is older than a minute.
  defp collect(workspace, profile, %{relevance_mode: "member"} = run, timeout_ms),
    do:
      MemberSourceIngest.collection(workspace, profile,
        max_age_s: if(run.trigger == "schedule", do: MemberSourceIngest.interval_s(), else: 60),
        collection_timeout_ms: timeout_ms
      )

  defp collect(workspace, profile, _run, timeout_ms),
    do:
      RecommendationSourceCollector.collect(workspace, profile.sources,
        collection_timeout_ms: timeout_ms
      )

  defp member?(run), do: run.relevance_mode == "member"

  # All public envelope paths call this through the existing runtime boundary.
  # No provider request runs here: the live consent/binding records fence reads.
  def member_subjects_valid?(profile, subjects) when is_map(subjects) do
    with {:ok, workspace} <- authorized_workspace(profile) do
      Enum.all?(subjects, fn {source_id, subject} ->
        source =
          Enum.find(profile.sources, &(&1["connectionId"] == source_id and &1["enabled"] == true))

        is_map(subject) and is_map(source) and
          current_subject?(workspace, profile.user_id, source, subject)
      end)
    else
      _ -> false
    end
  end

  def member_subjects_valid?(_profile, _subjects), do: false

  defp current_subject?(workspace, user_id, %{"kind" => "composio"} = source, subject),
    do:
      CommaWeb.RecommendationComposioMemberSource.current_subject?(
        workspace,
        user_id,
        source,
        subject
      )

  defp current_subject?(workspace, user_id, source, subject),
    do:
      CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source) == {:ok, subject}

  defp render(workspace, profile, run, collection, context, remaining) do
    if run.relevance_mode == "member" and
         Comma.RecommendationMemberSelection.candidates(context) == [] do
      {:ok, %{"selected" => []}, %{"inputBytes" => 0, "modelDurationMs" => 0}}
    else
      with {:ok, template_id} <-
             stage(
               template_id(RecommendationRenderer.agent_id(workspace, run)),
               :model_configuration_unavailable
             ),
           remaining = min(remaining, RecommendationGenerate.remaining_ms(run)),
           true <- remaining > 0 do
        RecommendationRenderer.render(
          workspace,
          template_id,
          profile,
          run,
          collection,
          context,
          remaining
        )
      else
        false -> {:error, :recommendation_run_timed_out}
        error -> error
      end
    end
  end

  # The relevance baseline: counts and sizes of what one run read, offered the
  # model, and paid for. It holds no source content. The run freezes its mode.
  defp generation_metrics(run, collection, context, metadata) do
    %{
      "variant" => run.relevance_mode,
      "collectionDurationMs" => collection.duration_ms,
      "sources" => %{
        "collected" => length(collection.facts),
        "failed" => length(collection.failures)
      },
      "bound" => Map.new(collection.facts, &{&1["sourceId"], &1["bound"]}),
      "references" => map_size(context.references),
      "model" =>
        Map.take(
          metadata,
          ~w(inputBytes modelDurationMs usage)
        )
    }
  end

  # A durable request may outlive its account or workspace access. Existing
  # account/membership records remain the authority at execution and publication.
  defp authorized_workspace(profile) do
    with {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id) do
      Comma.Workspaces.authorize(user, %{}, profile.workspace_id)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp usable_sources(%{facts: [], failures: [_ | _] = failures}) do
    if Enum.any?(failures, &(&1["class"] == "identity")),
      do: {:error, :member_identity_required},
      else: {:error, :source_collection_failed}
  end

  defp usable_sources(_), do: :ok
  defp stage({:ok, _} = ok, _reason), do: ok
  defp stage({:error, _}, reason), do: {:error, reason}

  # Legacy Agent capability calls cannot mutate generations after the cutover.
  # Journals remain readable; background jobs are the only publication owner.
  def begin_run(_ctx), do: {:error, :recommendation_renderer_retired}
  def publish(_ctx, _run_id, _snapshot), do: {:error, :recommendation_renderer_retired}
  def fail(_ctx, _run_id, _reason), do: {:error, :recommendation_renderer_retired}
  def authorize_tool(_ctx, _name, _args), do: {:error, :forbidden}
  def authorize_disclosure(_ctx, _name), do: {:error, :forbidden}

  @doc """
  The model template of a Routine or proactive judgment. A configured template
  is chosen for this task alone. Otherwise the request uses the template of the
  Agent it runs as.
  """
  def template_id(agent_id) do
    case Application.get_env(:comma_web, :recommendation_template_id) do
      template_id when is_binary(template_id) and template_id != "" -> {:ok, template_id}
      _ -> agent_template_id(agent_id)
    end
  end

  defp agent_template_id(agent_id) do
    if local_recommendation_mock_enabled?() do
      CommaWeb.SalixClient.ensure_default_agent_template()
    else
      with {:ok, record} <- AgentControl.get_record(agent_id),
           {:ok, template_id, _source} <-
             SalixAgent.Templates.resolve_template_id_for_record(record) do
        {:ok, template_id}
      else
        _ -> {:error, :recommendation_template_unavailable}
      end
    end
  end

  defp local_recommendation_mock_enabled? do
    function_exported?(SalixWeb.LocalOAuthMock, :enabled?, 0) and
      SalixWeb.LocalOAuthMock.enabled?()
  end
end
