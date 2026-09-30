defmodule Comma.Recommendations do
  @moduledoc """
  Member-scoped Comma Center recommendation settings and current projection.

  Publication uses generation and source-revision fences. Implementation tests
  cover this feature. Its former TLA+ model is historical (see `tla/README.md`).
  """

  import Ecto.Query

  require Logger

  alias Comma.Data.{RecommendationProfile, RecommendationRun}
  alias Comma.Workers.RecommendationGenerate
  alias Comma.Workers.RecommendationRunTimeout
  alias Comma.Workers.RecommendationSourceSync
  alias Comma.Workers.RecommendationSourceRefresh
  alias Comma.{MemberSourceItems, RecommendationBudgets, RecommendationContract, Repo, Workspaces}
  alias CommaProduct.Telemetry

  @manual_runs_per_hour 6
  @source_kinds ~w(native_mcp_oauth managed_oauth composio im_connect)

  # The client's UI language tags, mirrored from `@comma/i18n` `supportedLocales`.
  # This is an allowlist rather than a length check on purpose: the stored value
  # reaches the briefing renderer's system prompt, so an attacker-controlled
  # query parameter must never become free prompt text.
  @locales ~w(en zh-CN)

  def sync_sources(user, session, workspace_id, discovered) when is_list(discovered) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- validate_discovered_sources(discovered) do
      Repo.transaction(fn ->
        profile = locked_profile(workspace_id, user["id"])
        sources = reconcile_sources(profile, discovered)

        selected_changed? =
          selected_source_signature(sources) != selected_source_signature(profile.sources)

        if sources == profile.sources do
          public_envelope(profile)
        else
          if selected_changed?, do: supersede_active_runs(profile.id)

          {:ok, updated} =
            profile
            |> RecommendationProfile.settings_changeset(%{
              schedule_enabled: profile.schedule_enabled,
              schedule_hour: profile.schedule_hour,
              schedule_minute: profile.schedule_minute,
              timezone: profile.timezone,
              auto_enable_new_sources: profile.auto_enable_new_sources,
              sources: sources,
              source_revision: profile.source_revision + if(selected_changed?, do: 1, else: 0)
            })
            |> maybe_hide_snapshot_changeset(selected_changed?)
            |> Repo.update()

          public_envelope(updated)
        end
      end)
    end
  end

  def sync_sources(_user, _session, _workspace_id, _discovered),
    do: {:error, :invalid_recommendation_sources}

  def reconcile_discovered_sources(profile_id, discovered)
      when is_binary(profile_id) and is_list(discovered) do
    with :ok <- validate_discovered_sources(discovered) do
      Repo.transaction(fn ->
        profile =
          Repo.one!(
            from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
          )

        sources = reconcile_sources(profile, discovered)

        selected_changed? =
          selected_source_signature(sources) != selected_source_signature(profile.sources)

        attrs = %{
          schedule_enabled: profile.schedule_enabled,
          schedule_hour: profile.schedule_hour,
          schedule_minute: profile.schedule_minute,
          timezone: profile.timezone,
          auto_enable_new_sources: profile.auto_enable_new_sources,
          sources: sources,
          source_revision: profile.source_revision + if(selected_changed?, do: 1, else: 0),
          sources_checked_at: DateTime.utc_now()
        }

        attrs =
          if selected_changed?,
            do: Map.merge(attrs, discovered_snapshot(profile, sources, attrs.source_revision)),
            else: attrs

        if selected_changed?, do: supersede_active_runs(profile.id)

        with {:ok, updated} <-
               profile |> RecommendationProfile.settings_changeset(attrs) |> Repo.update(),
             :ok <- maybe_enqueue_source_refresh(updated, selected_changed?),
             :ok <- retain_member_pool(updated) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp maybe_enqueue_source_refresh(profile, true) do
    if enabled_sources(profile) == [] do
      :ok
    else
      %{profile_id: profile.id, source_revision: profile.source_revision}
      |> RecommendationSourceRefresh.new(unique: [period: 300, fields: [:args]])
      |> then(&Oban.insert(Comma.Oban, &1))
      |> case do
        {:ok, _job} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp maybe_enqueue_source_refresh(_profile, false), do: :ok

  def begin_source_refresh(profile_id, source_revision) do
    case Repo.get(RecommendationProfile, profile_id) do
      nil ->
        {:error, :not_found}

      profile ->
        create_internal_run(
          profile,
          "agent_tool",
          "source_revision:#{source_revision}",
          source_revision
        )
    end
  end

  # A newly confirmed receipt can restore a source already present in the
  # profile. Its unchanged source revision would otherwise skip refresh.
  def begin_confirmation_refresh(profile_id, token) when is_binary(token) do
    case Repo.get(RecommendationProfile, profile_id) do
      nil ->
        :ok

      profile ->
        if enabled_sources(profile) == [] do
          :ok
        else
          case create_internal_run(profile, "agent_tool", "confirmed:#{token}") do
            {:ok, _} -> :ok
            {:error, _} = error -> error
          end
        end
    end
  end

  def enqueue_source_sync(profile_id) when is_binary(profile_id) do
    # Source sync and schedule reconciliation share profile arguments but own
    # different work. Include the worker in their uniqueness boundary.
    %{profile_id: profile_id}
    |> RecommendationSourceSync.new(unique: [period: 300, fields: [:worker, :args]])
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  @doc false
  def reset_sources_for_mode_change(user, session, workspace_id) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        profile = locked_profile(workspace_id, user["id"])
        supersede_active_runs(profile.id)

        selected_changed? = selected_source_signature(profile.sources) != []

        attrs = %{
          sources: [],
          sources_checked_at: nil,
          source_revision: profile.source_revision + if(selected_changed?, do: 1, else: 0),
          snapshot: nil,
          snapshot_source_revision: nil,
          last_error: nil
        }

        case profile |> Ecto.Changeset.change(attrs) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # Internal rollout control. Changing mode invalidates both active work and
  # the published projection without changing the user's refresh schedule.
  def set_relevance_mode(user, session, workspace_id, mode) when mode in ~w(generic member) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        profile = locked_profile(workspace_id, user["id"])

        if relevance_mode(profile) == mode do
          profile
        else
          :ok = supersede_active_runs(profile.id)

          updated =
            profile
            |> Ecto.Changeset.change(
              relevance_mode: mode,
              source_revision: profile.source_revision + 1,
              snapshot: nil,
              snapshot_source_revision: nil,
              published_member_subjects: %{}
            )
            |> Repo.update!()

          :ok = retain_member_pool(updated)
          updated
        end
      end)
    end
  end

  # The member source item pool holds only sources that the member collects
  # now. Turning a source off, losing it or leaving member mode deletes its
  # items in the transaction that changes the setting.
  defp retain_member_pool(profile) do
    sources =
      if relevance_mode(profile) == "member",
        do: MemberSourceItems.enabled_source_ids(profile),
        else: []

    MemberSourceItems.retain_sources(profile.id, sources)
  end

  def relevance_mode(profile),
    do: if(profile.relevance_mode == "generic", do: "generic", else: "member")

  def get_runtime_profile(workspace_id, user_id) do
    case Repo.get_by(RecommendationProfile, workspace_id: workspace_id, user_id: user_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  def get_runtime_profile_by_agent(agent_id, session_id)
      when is_binary(agent_id) and agent_id != "" do
    case Repo.get_by(RecommendationProfile, agent_id: agent_id) do
      nil -> {:error, :not_found}
      profile when is_nil(session_id) or profile.session_id == session_id -> {:ok, profile}
      _profile -> {:error, :not_found}
    end
  end

  def get_runtime_profile_by_agent(_agent_id, _session_id), do: {:error, :not_found}

  def reserve_runtime(profile_id, attrs) when is_binary(profile_id) and is_map(attrs) do
    # TLA anchor: RecommendationRuntimeConvergence.Reserve.
    Repo.transaction(fn ->
      profile =
        Repo.one!(
          from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE")
        )

      if present?(profile.agent_id) and present?(profile.session_id) and
           present?(profile.schedule_id) do
        profile
      else
        case profile |> RecommendationProfile.runtime_changeset(attrs) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  def bind_runtime(profile_id, attrs) when is_binary(profile_id) and is_map(attrs) do
    RecommendationProfile
    |> Repo.get(profile_id)
    |> case do
      nil -> {:error, :not_found}
      profile -> profile |> RecommendationProfile.runtime_changeset(attrs) |> Repo.update()
    end
  end

  def begin_scheduled(agent_id, session_id, source_message_id) do
    with %RecommendationProfile{} = profile <-
           Repo.get_by(RecommendationProfile, agent_id: agent_id, session_id: session_id),
         true <- present?(source_message_id),
         :ok <- require_enabled_sources(profile) do
      create_internal_run(profile, "schedule", source_message_id)
    else
      nil -> {:error, :forbidden}
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def run_context(run_id) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         %RecommendationRun{} = run <- Repo.get(RecommendationRun, run_id),
         %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, run.profile_id) do
      {:ok, %{run: run, profile: profile}}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc "The URLs each admitted fact may reference, by source ID."
  def source_evidence(facts) when is_list(facts),
    do:
      Map.new(facts, fn fact ->
        {fact["sourceId"], fact |> RecommendationContract.http_urls() |> Enum.sort()}
      end)

  def record_source_evidence(run_id, facts, failures \\ [])
      when is_binary(run_id) and is_list(facts) and is_list(failures) do
    record_evidence(
      run_id,
      source_evidence(facts),
      facts
      |> Enum.filter(&is_map(&1["memberSubject"]))
      |> Map.new(&{&1["sourceId"], &1["memberSubject"]}),
      Enum.map(failures, & &1["sourceId"])
    )
  end

  @doc """
  Records a run's source evidence, member subjects and failed source IDs. A
  member run reads them from the member source item pool; a generic run from
  its own collection.
  """
  def record_evidence(run_id, evidence, subjects, failure_ids)
      when is_binary(run_id) and is_map(evidence) and is_map(subjects) and is_list(failure_ids) do
    # TLA anchor: RecommendationPublication.RecordEvidence. Publication cannot
    # settle until the bounded source-id/URL evidence for this run is durable.
    failure_ids =
      failure_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    active_run =
      from(run in RecommendationRun,
        where: run.id == ^run_id and run.status in ["pending", "running"],
        select: run
      )

    case Repo.update_all(
           active_run,
           set: [
             source_evidence: evidence,
             member_subjects: subjects,
             source_evidence_recorded: true,
             source_failure_ids: failure_ids
           ]
         ) do
      {1, [run]} ->
        {:ok, run}

      {0, []} ->
        if Repo.exists?(from(run in RecommendationRun, where: run.id == ^run_id)),
          do: {:error, :run_already_finished},
          else: {:error, :not_found}
    end
  end

  @doc """
  Read the member's envelope. The rail's own read passes `exposure: true`;
  settings and refresh preparation also read here and are not exposures.
  """
  def get(user, session, workspace_id, timezone \\ nil, locale \\ nil, opts \\ []) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, profile} <- ensure_profile(workspace_id, user["id"], timezone, locale) do
      envelope = public_envelope(profile)
      if opts[:exposure], do: record_exposure(profile, envelope)
      {:ok, envelope}
    end
  end

  def read_existing(user, session, workspace_id) do
    with {:ok, _} <- Workspaces.authorize(user, session, workspace_id) do
      case get_runtime_profile(workspace_id, user["id"]) do
        {:ok, profile} ->
          envelope = public_envelope(profile)
          # Request clears last_error before allocating a new generation. Active
          # runs expose no lastError; an expired/failed generation owns this code.
          observation =
            if envelope["lastError"],
              do:
                "#{profile.requested_generation}:#{profile.source_revision}:#{envelope["lastError"]}"

          {:ok, Map.put(envelope, "errorObservation", observation)}

        {:error, :not_found} ->
          {:ok, %{"state" => "empty", "snapshot" => nil, "lastError" => nil}}
      end
    end
  end

  # The client reads only while its rail is active, so a fresh read is the
  # server-side exposure fact. Reads are not deduplicated: a write on this
  # path would be telemetry-owned coordination. Count exposed generations from
  # the log line; the counter measures fresh reads.
  defp record_exposure(profile, %{"state" => "fresh", "snapshot" => snapshot}) do
    variant = profile.published_metrics["variant"]
    Telemetry.emit_recommendation_exposure(variant)

    Logger.info(
      "routine_exposure " <>
        Jason.encode!(%{
          "userId" => profile.user_id,
          "workspaceId" => profile.workspace_id,
          "generation" => snapshot["generation"],
          "variant" => variant
        })
    )
  end

  defp record_exposure(_profile, _envelope), do: :ok

  def update_settings(user, session, workspace_id, attrs) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      Repo.transaction(fn ->
        profile = locked_profile(workspace_id, user["id"])

        with {:ok, settings} <- normalize_settings(attrs, profile.sources),
             {:ok, personal} <- normalize_personal_settings(attrs, profile) do
          sources_changed? =
            selected_source_signature(profile.sources) !=
              selected_source_signature(settings.sources) or
              personal.relevance_mode != relevance_mode(profile)

          updates =
            %{
              schedule_enabled: settings.schedule_enabled,
              schedule_hour: settings.schedule_hour,
              schedule_minute: settings.schedule_minute,
              timezone: settings.timezone,
              auto_enable_new_sources: settings.auto_enable_new_sources,
              sources: settings.sources
            }
            |> Map.merge(personal)
            |> Map.put(
              :source_revision,
              profile.source_revision + if(sources_changed?, do: 1, else: 0)
            )
            |> maybe_hide_snapshot(sources_changed?)

          if sources_changed?, do: supersede_active_runs(profile.id)

          case profile |> RecommendationProfile.settings_changeset(updates) |> Repo.update() do
            {:ok, updated} ->
              :ok = retain_member_pool(updated)
              public_envelope(updated)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def request_refresh(user, session, workspace_id, trigger \\ "manual") do
    result =
      with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id),
           true <- trigger in ~w(manual schedule agent_tool) do
        Repo.transaction(fn ->
          profile = locked_profile(workspace_id, user["id"])

          # TLA anchor: RecommendationPublication.Request. The profile lock
          # serializes refresh allocation; replacing the active run, including
          # evidence cleanup, happens in this transaction before N+1 is inserted.
          with :ok <- require_enabled_sources(profile),
               :ok <- enforce_rate_limit(profile, trigger),
               :ok <- supersede_active_runs(profile.id),
               generation = profile.requested_generation + 1,
               {:ok, updated} <-
                 profile
                 |> Ecto.Changeset.change(%{
                   requested_generation: generation,
                   last_error: nil,
                   last_requested_at: DateTime.utc_now()
                 })
                 |> Repo.update(),
               {:ok, run} <-
                 %RecommendationRun{}
                 |> RecommendationRun.changeset(%{
                   profile_id: profile.id,
                   generation: generation,
                   source_revision: profile.source_revision,
                   relevance_mode: relevance_mode(profile),
                   trigger: trigger,
                   status: "pending"
                 })
                 |> Repo.insert(),
               {:ok, _job} <- enqueue_generation(run) do
            %{envelope: public_envelope(updated), run: public_run(run)}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        false -> {:error, :invalid_trigger}
        {:error, _} = error -> error
      end

    Telemetry.emit_recommendation_run(
      trigger,
      case result do
        {:ok, _} -> :requested
        {:error, :rate_limited} -> :rate_limited
        _ -> :failed
      end
    )

    result
  end

  @doc """
  Settle a run with its projection. `metrics` holds the run's bounded generation
  counts. It stays on the run after settlement, unlike the source evidence, and
  the published generation's copy stays on the profile.
  """
  def publish(run_id, snapshot, metrics \\ %{})
      when is_binary(run_id) and is_map(snapshot) and is_map(metrics) do
    evidence_result =
      case Repo.get(RecommendationRun, run_id) do
        %RecommendationRun{source_evidence_recorded: true} = run ->
          {:ok, {run.source_evidence || %{}, run.source_failure_ids || []}}

        %RecommendationRun{} ->
          {:error, :recommendation_source_evidence_not_recorded}

        nil ->
          {:error, :not_found}
      end

    snapshot =
      case evidence_result do
        {:ok, {_evidence, failure_ids}} ->
          snapshot
          |> drop_unfounded_partial_source_warnings(failure_ids)
          |> bound_projection(run_id)

        {:error, _} ->
          snapshot
      end

    validation =
      with {:ok, {evidence, failure_ids}} <- evidence_result do
        # Failed sources contribute no facts; the third argument authorizes
        # their ids only inside partial-source warnings.
        RecommendationContract.validate(snapshot, evidence, failure_ids)
      end

    case validation do
      :ok ->
        # Count the bounded projection: it is what the member receives.
        metrics = Map.put(metrics, "projection", projection_metrics(snapshot))

        Repo.transaction(fn ->
          {profile, run} = locked_profile_and_run(run_id)

          cond do
            run.status not in ~w(pending running) ->
              {:already_finished, public_envelope(profile)}

            DateTime.diff(DateTime.utc_now(), run.inserted_at, :millisecond) >=
                RecommendationBudgets.run_hard_cap_seconds() * 1_000 ->
              {:ok, envelope} = fail_if_active(run.id, :recommendation_run_timed_out)
              {:expired, envelope}

            current_run?(profile, run, snapshot) ->
              now = DateTime.utc_now()

              {:ok, updated_profile} =
                profile
                |> Ecto.Changeset.change(%{
                  snapshot: snapshot,
                  snapshot_source_revision: run.source_revision,
                  published_generation: run.generation,
                  published_metrics: Map.put(metrics, "variant", run.relevance_mode),
                  published_member_subjects: run.member_subjects,
                  last_error: nil,
                  last_published_at: now
                })
                |> Repo.update()

              {:ok, _run} = finish_run(run, "published", nil, now, metrics)
              Telemetry.emit_recommendation_run(run.trigger, :published)
              {:published, public_envelope(updated_profile)}

            true ->
              {:ok, _run} = finish_run(run, "superseded", nil, DateTime.utc_now(), metrics)
              Telemetry.emit_recommendation_run(run.trigger, :superseded)
              {:superseded, public_envelope(profile)}
          end
        end)

      {:error, :not_found} = error ->
        error

      {:error, reason} = error ->
        # An invalid model projection is a terminal run outcome, not a reason to
        # leave the generation looking active until the timeout worker arrives.
        # `fail/2` fences stale generations before updating the profile error.
        _ = fail_if_active(run_id, {:invalid_snapshot, reason})
        error
    end
  end

  def fail(run_id, reason) when is_binary(run_id) do
    Repo.transaction(fn ->
      {profile, run} = locked_profile_and_run(run_id)

      if run.status in ~w(pending running) do
        message = reason |> inspect(limit: 3) |> String.slice(0, 240)
        now = DateTime.utc_now()
        {:ok, _run} = finish_run(run, "failed", message, now)
        Telemetry.emit_recommendation_run(run.trigger, :failed)

        updated =
          if profile.requested_generation == run.generation do
            {:ok, value} = profile |> Ecto.Changeset.change(last_error: message) |> Repo.update()
            value
          else
            profile
          end

        public_envelope(updated)
      else
        :already_finished
      end
    end)
  end

  def fail_if_active(run_id, reason) when is_binary(run_id), do: fail(run_id, reason)

  @doc "True while a run of this profile is pending or running."
  def active_run?(profile_id) when is_binary(profile_id) do
    Repo.exists?(
      from(run in RecommendationRun,
        where: run.profile_id == ^profile_id and run.status in ["pending", "running"]
      )
    )
  end

  defp bound_projection(snapshot, run_id) do
    bounded = RecommendationContract.bound(snapshot)

    if bounded != snapshot do
      Logger.info(
        "recommendation projection bounded run=#{run_id} " <>
          "cards=#{projection_card_count(snapshot)}->#{projection_card_count(bounded)} " <>
          "rows=#{projection_row_count(snapshot)}->#{projection_row_count(bounded)}"
      )
    end

    bounded
  end

  defp projection_card_count(%{"cards" => cards}) when is_list(cards), do: length(cards)
  defp projection_card_count(_snapshot), do: 0

  defp projection_row_count(%{"cards" => cards}) when is_list(cards) do
    Enum.sum(
      Enum.map(cards, fn
        %{"items" => items} when is_list(items) -> length(items)
        _card -> 0
      end)
    )
  end

  defp projection_row_count(_snapshot), do: 0

  defp projection_metrics(snapshot) do
    %{
      "cards" => projection_card_count(snapshot),
      "rows" => projection_row_count(snapshot),
      "links" => inline_link_count(snapshot),
      "warnings" => length(List.wrap(snapshot["warnings"]))
    }
  end

  defp inline_link_count(%{"kind" => "inline-link"}), do: 1

  defp inline_link_count(value) when is_map(value),
    do: value |> Map.values() |> Enum.map(&inline_link_count/1) |> Enum.sum()

  defp inline_link_count(value) when is_list(value),
    do: value |> Enum.map(&inline_link_count/1) |> Enum.sum()

  defp inline_link_count(_value), do: 0

  # A partial_sources warning is real only when this run recorded a failed
  # source read; a source that merely returned no usable items is normal and
  # must not surface user-visible warning text.
  defp drop_unfounded_partial_source_warnings(%{"warnings" => warnings} = snapshot, failure_ids)
       when is_list(warnings) do
    Map.put(
      snapshot,
      "warnings",
      Enum.filter(warnings, fn warning ->
        not partial_sources_warning?(warning) or
          founded_partial_sources?(warning, failure_ids)
      end)
    )
  end

  defp drop_unfounded_partial_source_warnings(snapshot, _failure_ids), do: snapshot

  defp partial_sources_warning?(%{"code" => "partial_sources"}), do: true
  defp partial_sources_warning?(_warning), do: false

  defp founded_partial_sources?(warning, failure_ids) do
    case warning do
      %{"sourceIds" => ids} when is_list(ids) and ids != [] ->
        Enum.any?(ids, &(&1 in failure_ids))

      _ ->
        failure_ids != []
    end
  end

  defp ensure_profile(workspace_id, user_id, timezone, locale \\ nil) do
    case Repo.get_by(RecommendationProfile, workspace_id: workspace_id, user_id: user_id) do
      nil ->
        %RecommendationProfile{}
        |> RecommendationProfile.create_changeset(%{
          workspace_id: workspace_id,
          user_id: user_id,
          timezone: normalize_timezone(timezone),
          relevance_mode: "member",
          locale: normalize_locale(locale)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:workspace_id, :user_id])
        |> case do
          {:ok, %RecommendationProfile{id: nil}} ->
            {:ok,
             Repo.get_by!(RecommendationProfile, workspace_id: workspace_id, user_id: user_id)}

          result ->
            result
        end

      profile ->
        sync_locale(profile, normalize_locale(locale))
    end
  end

  # Only a client fetch carries a language preference, so an unreported locale
  # leaves the stored one alone: the scheduled run has no client in the loop and
  # must keep using the last preference the user actually expressed. The
  # schedule timezone is a setting, not a client fact: the settings form saves
  # the timezone of the device the member sets the delivery time on, and a read
  # never moves the daily run between devices.
  defp sync_locale(profile, nil), do: {:ok, profile}
  defp sync_locale(%RecommendationProfile{locale: locale} = profile, locale), do: {:ok, profile}

  defp sync_locale(profile, locale) do
    profile
    |> RecommendationProfile.locale_changeset(locale)
    |> Repo.update()
  end

  defp locked_profile(workspace_id, user_id) do
    case Repo.one(
           from(profile in RecommendationProfile,
             where: profile.workspace_id == ^workspace_id and profile.user_id == ^user_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        {:ok, _profile} = ensure_profile(workspace_id, user_id, "Etc/UTC")

        Repo.one!(
          from(profile in RecommendationProfile,
            where: profile.workspace_id == ^workspace_id and profile.user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        )

      profile ->
        profile
    end
  end

  # Sources are keyed by connection id. The request carries the flags the
  # member set; each applies to the canonical source with that id, a source the
  # request does not name keeps its current flag, and an id that discovery has
  # since removed is gone. Discovery runs between the settings load and the
  # save, so an exact echo of the source list cannot be required without
  # rejecting every schedule change made in that window.
  defp normalize_settings(attrs, canonical_sources) when is_map(attrs) do
    schedule = attrs["schedule"] || %{}
    requested_sources = attrs["sources"] || []

    with true <- is_list(requested_sources) and Enum.all?(requested_sources, &requested_source?/1),
         {:ok, timezone} <- strict_timezone(schedule["timezone"]) do
      requested_flags = Map.new(requested_sources, &{&1["connectionId"], &1["enabled"]})

      sources =
        Enum.map(canonical_sources, fn canonical ->
          Map.put(
            canonical,
            "enabled",
            Map.get(requested_flags, canonical["connectionId"], canonical["enabled"] == true)
          )
        end)

      settings = %RecommendationProfile{
        schedule_enabled: schedule["enabled"],
        schedule_hour: schedule["hour"],
        schedule_minute: schedule["minute"],
        timezone: timezone,
        auto_enable_new_sources: attrs["autoEnableNewSources"],
        sources: sources
      }

      if is_boolean(settings.schedule_enabled) and
           is_boolean(settings.auto_enable_new_sources) and
           is_integer(settings.schedule_hour) and settings.schedule_hour in 0..23 and
           is_integer(settings.schedule_minute) and settings.schedule_minute in 0..59 and
           valid_sources?(sources) do
        {:ok, settings}
      else
        {:error, :invalid_recommendation_settings}
      end
    else
      false -> {:error, :invalid_recommendation_settings}
      :error -> {:error, :invalid_recommendation_settings}
    end
  end

  defp normalize_settings(_attrs, _canonical_sources),
    do: {:error, :invalid_recommendation_settings}

  # Only member-owned preferences cross this boundary. Provider identity and
  # consent remain private authorities and cannot be supplied in settings.
  defp normalize_personal_settings(attrs, profile) do
    mode = Map.get(attrs, "relevanceMode", relevance_mode(profile))

    if mode in ~w(generic member),
      do: {:ok, %{relevance_mode: mode}},
      else: {:error, :invalid_recommendation_settings}
  end

  defp requested_source?(source),
    do:
      is_map(source) and is_binary(source["connectionId"]) and
        String.trim(source["connectionId"]) != "" and is_boolean(source["enabled"])

  defp validate_discovered_sources(sources) when length(sources) <= 12 do
    if Enum.all?(sources, fn source ->
         is_map(source) and source["kind"] in @source_kinds and
           present?(source["appId"]) and present?(source["appName"]) and
           present?(source["connectionId"]) and present?(source["label"])
       end),
       do: :ok,
       else: {:error, :invalid_recommendation_sources}
  end

  defp validate_discovered_sources(_sources), do: {:error, :invalid_recommendation_sources}

  # Connection replacements inherit the member's app choice. The native
  # apps also retain it across empty discovery results during reauthorization.
  # Other sources without a current predecessor use the auto-enable default.
  defp reconcile_sources(profile, discovered) do
    existing = Map.new(profile.sources, &{&1["connectionId"], &1})
    native_preferences = RecommendationProfile.native_source_preferences(profile)
    discovered_ids = MapSet.new(discovered, & &1["connectionId"])

    replaced =
      profile.sources
      |> Enum.reject(&MapSet.member?(discovered_ids, &1["connectionId"]))
      |> Map.new(&{source_app_key(&1), &1["enabled"]})

    Enum.map(discovered, fn source ->
      enabled =
        case existing[source["connectionId"]] do
          %{"enabled" => value} when is_boolean(value) ->
            value

          _ ->
            case replaced[source_app_key(source)] do
              value when is_boolean(value) ->
                value

              _ ->
                case source_app_key(source) do
                  {:oauth_app, app} ->
                    Map.get(native_preferences, app, profile.auto_enable_new_sources)

                  _ ->
                    profile.auto_enable_new_sources
                end
            end
        end

      source
      |> Map.take(~w(appId appName connectionId iconUrl kind label bindingAlias provider toolkit))
      |> Map.put("enabled", enabled)
    end)
  end

  defp source_app_key(%{"appId" => app, "kind" => kind})
       when app in ~w(github linear notion slack) and kind in ~w(composio managed_oauth),
       do: {:oauth_app, app}

  defp source_app_key(source),
    do: {source["kind"], source["toolkit"] || source["bindingAlias"] || source["appId"]}

  defp create_internal_run(profile, trigger, source_message_id, expected_source_revision \\ nil) do
    Repo.transaction(fn ->
      profile =
        Repo.one!(
          from(p in RecommendationProfile, where: p.id == ^profile.id, lock: "FOR UPDATE")
        )

      # TLA anchor: RecommendationPublication.CrashOrDuplicate. A stable schedule
      # delivery id maps retries to the original run instead of allocating a new
      # generation after a crash or duplicate delivery.
      existing =
        Repo.get_by(RecommendationRun,
          profile_id: profile.id,
          source_message_id: source_message_id
        )

      replacement_obsolete? =
        source_refresh_obsolete?(profile, expected_source_revision, source_message_id)

      cond do
        replacement_obsolete? ->
          :skipped

        existing ->
          %{
            envelope: public_envelope(profile),
            run: public_run(existing),
            sources: enabled_sources(profile)
          }

        true ->
          # A new scheduled delivery is another Request transition. Keep the
          # stable-message duplicate branch above idempotent, but replace any
          # different active generation before allocating this one.
          with :ok <- supersede_active_runs(profile.id),
               generation = profile.requested_generation + 1,
               {:ok, updated} <-
                 profile
                 |> Ecto.Changeset.change(%{
                   requested_generation: generation,
                   last_error: nil,
                   last_requested_at: DateTime.utc_now()
                 })
                 |> Repo.update(),
               {:ok, run} <-
                 %RecommendationRun{}
                 |> RecommendationRun.changeset(%{
                   profile_id: profile.id,
                   generation: generation,
                   source_revision: profile.source_revision,
                   relevance_mode: relevance_mode(profile),
                   source_message_id: source_message_id,
                   trigger: trigger,
                   status: "running"
                 })
                 |> Repo.insert(),
               {:ok, _job} <- enqueue_generation(run) do
            %{
              envelope: public_envelope(updated),
              run: public_run(run),
              sources: enabled_sources(updated)
            }
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp source_refresh_obsolete?(_profile, nil, _message_id), do: false

  defp source_refresh_obsolete?(profile, revision, message_id) do
    latest =
      Repo.get_by(RecommendationRun,
        profile_id: profile.id,
        generation: profile.requested_generation
      )

    profile.source_revision != revision or enabled_sources(profile) == [] or
      (not is_nil(latest) and latest.source_revision == revision and
         latest.source_message_id != message_id)
  end

  defp enabled_sources(profile), do: Enum.filter(profile.sources, &(&1["enabled"] == true))

  defp enqueue_generation(run) do
    with {:ok, _job} <-
           %{run_id: run.id}
           |> RecommendationGenerate.new(unique: [period: :infinity, fields: [:worker, :args]])
           |> then(&Oban.insert(Comma.Oban, &1)) do
      %{run_id: run.id}
      |> RecommendationRunTimeout.new(schedule_in: RecommendationBudgets.run_hard_cap_seconds())
      |> then(&Oban.insert(Comma.Oban, &1))
    end
  end

  def begin_schedule_occurrence(profile_id, schedule_id, scheduled_for) do
    Repo.transaction(fn ->
      profile =
        Repo.one(from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE"))

      case profile do
        %{schedule_id: ^schedule_id, schedule_enabled: true} ->
          with :ok <- require_enabled_sources(profile),
               {:ok, result} <-
                 create_internal_run(
                   profile,
                   "schedule",
                   "schedule:#{schedule_id}:#{scheduled_for}"
                 ) do
            result
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _ ->
          :skipped
      end
    end)
  end

  @doc false
  def recover_schedule_receipt(profile, %{"last_run" => timestamp}) when is_integer(timestamp) do
    # The old receiver ACKed Agent input before recommendation.begin allocated
    # a run. Preserve that accepted occurrence when no newer request replaced it.
    newer_request? =
      profile.last_requested_at &&
        DateTime.to_unix(profile.last_requested_at, :millisecond) >= timestamp

    if newer_request? do
      :ok
    else
      case begin_schedule_occurrence(profile.id, profile.schedule_id, timestamp) do
        {:ok, %{run: %{"id" => run_id}}} ->
          if System.system_time(:millisecond) - timestamp >=
               RecommendationBudgets.run_hard_cap_seconds() * 1_000 do
            case fail_if_active(run_id, :recommendation_run_timed_out) do
              {:ok, _} -> :ok
              error -> error
            end
          else
            :ok
          end

        {:ok, :skipped} ->
          :ok

        {:error, :no_recommendation_sources} ->
          :ok

        error ->
          error
      end
    end
  end

  def recover_schedule_receipt(_profile, _schedule), do: :ok

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_sources?(sources) when is_list(sources) and length(sources) <= 12 do
    Enum.all?(sources, fn source ->
      is_map(source) and source["kind"] in @source_kinds and is_binary(source["connectionId"]) and
        String.trim(source["connectionId"]) != "" and is_boolean(source["enabled"])
    end)
  end

  defp valid_sources?(_sources), do: false

  defp normalize_timezone(value) when is_binary(value) do
    case strict_timezone(value) do
      {:ok, timezone} -> timezone
      :error -> "Etc/UTC"
    end
  end

  defp normalize_timezone(_value), do: "Etc/UTC"

  defp normalize_locale(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed in @locales, do: trimmed, else: nil
  end

  defp normalize_locale(_value), do: nil

  defp strict_timezone(value) when is_binary(value) do
    timezone = String.trim(value)

    if timezone != "" and String.length(timezone) <= 64 and
         match?({:ok, _datetime}, DateTime.shift_zone(DateTime.utc_now(), timezone)) do
      {:ok, timezone}
    else
      :error
    end
  end

  defp strict_timezone(_value), do: :error

  defp maybe_hide_snapshot(updates, true),
    do: Map.merge(updates, %{snapshot: nil, snapshot_source_revision: nil})

  defp maybe_hide_snapshot(updates, false), do: updates

  defp maybe_hide_snapshot_changeset(changeset, true),
    do: Ecto.Changeset.change(changeset, %{snapshot: nil, snapshot_source_revision: nil})

  defp maybe_hide_snapshot_changeset(changeset, false), do: changeset

  # Discovery schedules a replacement run for every selected-source change. An
  # addition leaves every source the current snapshot read selected, so the
  # snapshot stays valid for the new revision: it shows as refreshing, then as
  # stale if the replacement fails. Removing, disabling or rebinding a selected
  # source invalidates it.
  defp discovered_snapshot(profile, sources, revision) do
    if profile.snapshot_source_revision == profile.source_revision and
         selection_added_only?(profile.sources, sources),
       do: %{snapshot_source_revision: revision},
       else: %{snapshot: nil, snapshot_source_revision: nil}
  end

  defp selection_added_only?(previous, current) do
    current = MapSet.new(selected_source_signature(current))
    Enum.all?(selected_source_signature(previous), &MapSet.member?(current, &1))
  end

  defp selected_source_signature(sources) do
    sources
    |> Enum.filter(&(&1["enabled"] == true))
    |> Enum.map(&Map.take(&1, ~w(connectionId kind bindingAlias provider toolkit)))
    |> Enum.sort_by(& &1["connectionId"])
  end

  # TLA anchor: RecommendationPublication.SourceChange and Request. Once the
  # source revision or requested generation changes, older in-flight runs can
  # no longer make progress and must stop presenting as active immediately.
  defp supersede_active_runs(profile_id) do
    now = DateTime.utc_now()

    {_count, run_ids} =
      from(run in RecommendationRun,
        where: run.profile_id == ^profile_id and run.status in ["pending", "running"],
        select: run.id
      )
      |> Repo.update_all(
        set: [
          status: "superseded",
          source_evidence: %{},
          source_evidence_recorded: false,
          source_failure_ids: [],
          finished_at: now
        ]
      )

    # At most one active generation exists under the profile lock. Oban's args
    # GIN index selects its jobs. PostgreSQL delivers cancellation notifications
    # only after this transaction commits, then owner death cancels its LLM job.
    for run_id <- run_ids do
      query =
        from(job in Oban.Job,
          where:
            job.worker in [
              "Comma.Workers.RecommendationGenerate",
              "Comma.Workers.RecommendationRunTimeout"
            ] and
              fragment("? @> ?", job.args, ^%{"run_id" => run_id})
        )

      {:ok, _} = Oban.cancel_all_jobs(Comma.Oban, query)
    end

    :ok
  end

  defp enforce_rate_limit(_profile, trigger) when trigger != "manual", do: :ok

  defp enforce_rate_limit(profile, "manual") do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)

    count =
      Repo.aggregate(
        from(run in RecommendationRun,
          where:
            run.profile_id == ^profile.id and run.trigger == "manual" and
              run.inserted_at >= ^cutoff
        ),
        :count
      )

    if count < @manual_runs_per_hour, do: :ok, else: {:error, :rate_limited}
  end

  defp current_run?(profile, run, snapshot) do
    run.status in ~w(pending running) and profile.requested_generation == run.generation and
      relevance_mode(profile) == run.relevance_mode and
      member_subjects_valid?(profile, run.relevance_mode, run.member_subjects) and
      profile.source_revision == run.source_revision and snapshot["generation"] == run.generation and
      snapshot["sourceRevision"] == run.source_revision and
      snapshot_sources_allowed?(profile, snapshot)
  end

  defp require_enabled_sources(profile) do
    if Enum.any?(profile.sources, &(&1["enabled"] == true)),
      do: :ok,
      else: {:error, :no_recommendation_sources}
  end

  defp snapshot_sources_allowed?(profile, snapshot) do
    enabled =
      profile.sources
      |> Enum.filter(&(&1["enabled"] == true))
      |> MapSet.new(& &1["connectionId"])

    Enum.all?(snapshot["cards"], fn card ->
      Enum.all?(card["sourceIds"], &MapSet.member?(enabled, &1))
    end)
  end

  defp locked_profile_and_run(run_id) do
    # Settings/source reconciliation already locks the profile before touching
    # active runs. Settlement must use the same order or the two transactions
    # can deadlock while each holds the row the other needs.
    run_profile_id = Repo.get!(RecommendationRun, run_id).profile_id

    profile =
      Repo.one!(
        from(profile in RecommendationProfile,
          where: profile.id == ^run_profile_id,
          lock: "FOR UPDATE"
        )
      )

    run =
      Repo.one!(
        from(run in RecommendationRun,
          where: run.id == ^run_id and run.profile_id == ^profile.id,
          lock: "FOR UPDATE"
        )
      )

    {profile, run}
  end

  # Settlement clears the source evidence. It keeps the run metrics: they hold
  # counts only and the relevance baseline reads them after the run ends.
  defp finish_run(run, status, error, now, metrics \\ nil) do
    attrs = %{
      status: status,
      error: error,
      source_evidence: %{},
      source_evidence_recorded: false,
      source_failure_ids: [],
      finished_at: now
    }

    attrs = if metrics, do: Map.put(attrs, :metrics, metrics), else: attrs

    run
    |> RecommendationRun.changeset(attrs)
    |> Repo.update()
  end

  defp member_subjects_valid?(_profile, "generic", _subjects), do: true

  defp member_subjects_valid?(profile, "member", subjects) do
    runtime = Application.get_env(:comma_core, :recommendation_runtime_mod)

    is_atom(runtime) and function_exported?(runtime, :member_subjects_valid?, 2) and
      runtime.member_subjects_valid?(profile, subjects)
  end

  defp public_envelope(profile) do
    identity_valid? =
      is_nil(profile.snapshot) or
        member_subjects_valid?(
          profile,
          relevance_mode(profile),
          profile.published_member_subjects
        )

    snapshot =
      if profile.snapshot_source_revision == profile.source_revision and
           (profile.published_metrics["variant"] || "generic") == relevance_mode(profile) and
           identity_valid?,
         do: profile.snapshot,
         else: nil

    enabled_sources? = Enum.any?(profile.sources, &(&1["enabled"] == true))
    run_state = current_run_state(profile)

    last_error =
      cond do
        run_state == :expired -> ":recommendation_run_timed_out"
        not identity_valid? -> ":member_identity_required"
        true -> profile.last_error
      end

    state =
      cond do
        not enabled_sources? ->
          "empty"

        run_state == :active ->
          "refreshing"

        last_error != nil and snapshot != nil ->
          "stale"

        last_error != nil ->
          "error"

        snapshot == nil ->
          "empty"

        true ->
          "fresh"
      end

    %{
      "settings" => %{
        "autoEnableNewSources" => profile.auto_enable_new_sources,
        "relevanceMode" => relevance_mode(profile),
        "schedule" => %{
          "enabled" => profile.schedule_enabled,
          "hour" => profile.schedule_hour,
          "minute" => profile.schedule_minute,
          "timezone" => profile.timezone
        },
        "sourcesCheckedAt" =>
          if(profile.sources_checked_at,
            do: DateTime.to_iso8601(profile.sources_checked_at),
            else: nil
          ),
        "sourceRevision" => profile.source_revision,
        "sources" =>
          Enum.map(
            profile.sources,
            &Map.take(&1, ~w(appId appName connectionId enabled iconUrl kind label))
          )
      },
      "snapshot" => snapshot,
      "state" => state,
      "lastError" => if(state in ["error", "stale"], do: last_error_code(last_error))
    }
  end

  # `fail/2` stores our own `inspect/1` of the settlement reason, so the prefix
  # identifies the failure class. Only this bounded code crosses the API; the
  # stored text never does.
  defp last_error_code(nil), do: nil

  defp last_error_code(error) when is_binary(error) do
    cond do
      String.starts_with?(error, "{:invalid_snapshot") ->
        "invalid_projection"

      String.starts_with?(error, "{:agent_failed") ->
        "renderer_declined"

      error == ":member_identity_required" ->
        "member_identity_required"

      String.starts_with?(error, ":source_collection_failed") ->
        "source_collection_failed"

      String.starts_with?(error, "{:delivery_failed") ->
        "delivery_failed"

      error in [":recommendation_run_timed_out", ":model_timed_out"] ->
        "timed_out"

      error in [":invalid_briefing_content", ":unknown_briefing_reference"] ->
        "invalid_projection"

      true ->
        "failed"
    end
  end

  # One indexed lookup derives expiry even when the queue cannot settle the run.
  # Reads do not mutate durable run state or emit worker settlement telemetry.
  defp current_run_state(profile) do
    inserted_at =
      if profile.requested_generation > profile.published_generation do
        Repo.one(
          from(run in RecommendationRun,
            where:
              run.profile_id == ^profile.id and run.generation == ^profile.requested_generation and
                run.source_revision == ^profile.source_revision and
                run.status in ["pending", "running"],
            select: run.inserted_at
          )
        )
      end

    cond do
      is_nil(inserted_at) ->
        :none

      DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond) >=
          RecommendationBudgets.run_hard_cap_seconds() * 1_000 ->
        :expired

      true ->
        :active
    end
  end

  defp public_run(run),
    do: %{
      "id" => run.id,
      "generation" => run.generation,
      "sourceRevision" => run.source_revision,
      "status" => run.status,
      "trigger" => run.trigger
    }
end
