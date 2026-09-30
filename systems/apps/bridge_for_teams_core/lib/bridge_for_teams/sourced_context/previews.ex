defmodule BridgeForTeams.SourcedContext.Previews do
  @moduledoc """
  Authorized preview, comparison, and immutable human review revisions.

  A preview always carries the exact frozen snapshot plus model/prompt/policy/
  schema evidence that produced it. Human selection or editing creates a new
  review revision; it never mutates model output or source objects in place.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo, SlackHistoryImports}
  alias BridgeForTeams.ContextLifecycle.ReadBarrier
  alias BridgeForTeams.SlackHistoryImport.StateMachine

  alias BridgeForTeams.Schema.{
    ContextBundle,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextDerivation,
    SourcedContextObject,
    SourcedContextReviewItem,
    SourcedContextReviewRevision,
    SourcedContextSnapshot
  }

  alias BridgeForTeams.SourcedContext.{
    Acquisition,
    CanonicalJSON,
    Crypto,
    Instrumentation,
    Payloads,
    ProcessorOutput
  }

  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get(run_id, user_id) do
    Instrumentation.measure(:sourced_context_preview, fn ->
      with :ok <- feature_enabled(),
           :ok <- encryption_available(),
           %SlackHistoryImportRun{} = run <- Repo.get(SlackHistoryImportRun, run_id),
           :ok <- authorize_admin(user_id, run.project_id) do
        ReadBarrier.run([run.context_bundle_id], fn ->
          with :ok <- preview_state(run),
               {:ok, view} <- preview_view(run) do
            {:ok, view}
          end
        end)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec compare(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, term()}
  def compare(left_derivation_id, right_derivation_id, user_id) do
    Instrumentation.measure(:sourced_context_preview, fn ->
      with :ok <- feature_enabled(),
           :ok <- encryption_available(),
           %SourcedContextDerivation{} = left <-
             Repo.get(SourcedContextDerivation, left_derivation_id),
           %SourcedContextDerivation{} = right <-
             Repo.get(SourcedContextDerivation, right_derivation_id),
           %SlackHistoryImportRun{} = left_run <- Repo.get(SlackHistoryImportRun, left.run_id),
           %SlackHistoryImportRun{} = right_run <- Repo.get(SlackHistoryImportRun, right.run_id),
           true <- left_run.project_id == right_run.project_id,
           :ok <- authorize_admin(user_id, left_run.project_id) do
        ReadBarrier.run(
          [left_run.context_bundle_id, right_run.context_bundle_id],
          fn ->
            with {:ok, left_artifacts} <- derivation_artifacts(left.id),
                 {:ok, right_artifacts} <- derivation_artifacts(right.id) do
              {:ok,
               %{
                 same_snapshot: left.snapshot_id == right.snapshot_id,
                 source_changed: left.snapshot_id != right.snapshot_id,
                 left: derivation_evidence(left),
                 right: derivation_evidence(right),
                 changes: compare_artifacts(left_artifacts, right_artifacts)
               }}
            end
          end
        )
      else
        nil -> {:error, :not_found}
        false -> {:error, :cross_project_comparison_forbidden}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec revise(Ecto.UUID.t(), map()) ::
          {:ok,
           %{
             run: SlackHistoryImportRun.t(),
             review_revision: SourcedContextReviewRevision.t(),
             replayed?: boolean()
           }}
          | {:error, term()}
  def revise(run_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:sourced_context_preview, fn ->
      with :ok <- feature_enabled(),
           :ok <- encryption_available(),
           {:ok, request} <- normalize_revision_request(attrs) do
        transaction(fn -> persist_revision(run_id, request) end)
      end
    end)
    |> audit_preview_revision()
  end

  def revise(_run_id, _attrs), do: {:error, :invalid_preview_revision}

  defp preview_view(run) do
    with %SourcedContextReviewRevision{} = review <-
           Repo.get(SourcedContextReviewRevision, run.review_revision_id),
         true <-
           review.run_id == run.id and review.snapshot_id == run.snapshot_id and
             review.derivation_id == run.derivation_id,
         %SourcedContextDerivation{} = derivation <-
           Repo.get(SourcedContextDerivation, review.derivation_id),
         %SourcedContextSnapshot{} = snapshot <-
           Repo.get(SourcedContextSnapshot, review.snapshot_id),
         {:ok, snapshot_data} <- Acquisition.read_snapshot(snapshot.id),
         {:ok, items} <- review_items(review.id, snapshot_data.objects) do
      {:ok,
       %{
         import_run: run_evidence(run),
         source_snapshot: snapshot_evidence(snapshot),
         derivation: derivation_evidence(derivation),
         review_revision: %{
           id: review.id,
           revision: review.revision,
           parent_revision_id: review.parent_revision_id,
           selection_sha256: review.selection_sha256,
           selected_count: review.selected_count,
           created_by_user_id: review.created_by_user_id,
           created_at: review.created_at
         },
         items: items,
         warnings: derivation.warnings
       }}
    else
      nil -> {:error, :preview_not_found}
      false -> {:error, :preview_evidence_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_items(review_id, snapshot_objects) do
    objects = Map.new(snapshot_objects, &{&1.id, &1})

    items =
      Repo.all(
        from(item in SourcedContextReviewItem,
          where: item.review_revision_id == ^review_id,
          preload: [artifact: :sources]
        )
      )
      |> Enum.sort_by(&{&1.artifact.kind, &1.artifact.stable_key})

    if length(items) > bound(:derivation_artifacts, 100) do
      {:error, :preview_bound_exceeded}
    else
      items
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        with {:ok, payload} <-
               Payloads.unseal(
                 :review_item,
                 item.id,
                 item.payload_ciphertext,
                 item.payload_sha256
               ),
             {:ok, sources} <- preview_sources(item.artifact.sources, objects) do
          view = %{
            id: item.id,
            artifact_id: item.artifact_id,
            stable_key: item.artifact.stable_key,
            kind: item.kind,
            payload: payload,
            payload_sha256: item.payload_sha256,
            confidence_millis: item.artifact.confidence_millis,
            edited: item.payload_sha256 != item.artifact.payload_sha256,
            sources: sources
          }

          {:cont, {:ok, [view | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, views} -> {:ok, Enum.reverse(views)}
        error -> error
      end
    end
  end

  defp preview_sources(sources, objects) do
    sources
    |> Enum.sort_by(& &1.source_object_id)
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, acc} ->
      case Map.fetch(objects, source.source_object_id) do
        {:ok, object} ->
          view = %{
            object_id: object.id,
            workspace_id: object.source.workspace_id,
            channel_id: object.source.channel_id,
            message_ts: object.source.message_ts,
            thread_ts: object.source.thread_ts,
            observable_version: object.source.observable_version,
            payload: object.payload
          }

          {:cont, {:ok, [view | acc]}}

        :error ->
          {:halt, {:error, :artifact_source_outside_snapshot}}
      end
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      error -> error
    end
  end

  defp derivation_artifacts(derivation_id) do
    artifacts =
      Repo.all(
        from(artifact in SourcedContextArtifact,
          where: artifact.derivation_id == ^derivation_id,
          order_by: [asc: artifact.kind, asc: artifact.stable_key],
          limit: ^(bound(:derivation_artifacts, 100) + 1)
        )
      )

    if length(artifacts) > bound(:derivation_artifacts, 100) do
      {:error, :preview_bound_exceeded}
    else
      artifacts
      |> Enum.reduce_while({:ok, %{}}, fn artifact, {:ok, acc} ->
        case Payloads.unseal(
               :artifact,
               artifact.id,
               artifact.payload_ciphertext,
               artifact.payload_sha256
             ) do
          {:ok, payload} ->
            view = %{
              artifact_id: artifact.id,
              stable_key: artifact.stable_key,
              kind: artifact.kind,
              payload: payload,
              payload_sha256: artifact.payload_sha256,
              confidence_millis: artifact.confidence_millis
            }

            {:cont, {:ok, Map.put(acc, {artifact.kind, artifact.stable_key}, view)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp compare_artifacts(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {kind, stable_key} = identity ->
      left_item = Map.get(left, identity)
      right_item = Map.get(right, identity)

      status =
        cond do
          is_nil(left_item) ->
            :added

          is_nil(right_item) ->
            :removed

          left_item.payload_sha256 == right_item.payload_sha256 and
              left_item.kind == right_item.kind ->
            :unchanged

          true ->
            :changed
        end

      %{
        kind: kind,
        stable_key: stable_key,
        status: status,
        left: left_item,
        right: right_item
      }
    end)
  end

  defp persist_revision(run_id, request) do
    {_bundle, run} = lock_lifecycle_ready_run(run_id)
    :ok = require_ok(authorize_admin(request.user_id, run.project_id))
    :ok = require_ok(preview_state(run))

    parent =
      Repo.get(SourcedContextReviewRevision, request.parent_review_revision_id) ||
        Repo.rollback(:parent_review_not_found)

    if parent.run_id != run.id or parent.snapshot_id != run.snapshot_id do
      Repo.rollback(:preview_evidence_mismatch)
    end

    {selection, normalized_artifacts, artifacts_by_identity} =
      normalize_revision_selection(run, parent, request.items)

    selection_sha256 = CanonicalJSON.sha256(CanonicalJSON.encode!(selection))

    cond do
      run.review_revision_id == parent.id ->
        if run.generation != request.expected_generation do
          Repo.rollback(:stale_run_generation)
        end

        create_revision(
          run,
          parent,
          request.user_id,
          selection_sha256,
          normalized_artifacts,
          artifacts_by_identity
        )

      true ->
        replay_revision(run, parent, selection_sha256)
    end
  end

  defp normalize_revision_selection(run, parent, requested_items) do
    artifacts =
      Repo.all(
        from(artifact in SourcedContextArtifact,
          where: artifact.derivation_id == ^parent.derivation_id,
          preload: [:sources]
        )
      )

    artifacts_by_id = Map.new(artifacts, &{&1.id, &1})

    raw_artifacts =
      Enum.map(requested_items, fn requested ->
        artifact =
          Map.get(artifacts_by_id, requested.artifact_id) ||
            Repo.rollback(:artifact_outside_current_derivation)

        payload =
          case requested.payload do
            :use_artifact ->
              case Payloads.unseal(
                     :artifact,
                     artifact.id,
                     artifact.payload_ciphertext,
                     artifact.payload_sha256
                   ) do
                {:ok, payload} -> payload
                {:error, reason} -> Repo.rollback(reason)
              end

            payload ->
              payload
          end

        %{
          kind: artifact.kind,
          stable_key: artifact.stable_key,
          payload: payload,
          confidence_millis: artifact.confidence_millis,
          source_object_ids: Enum.map(artifact.sources, & &1.source_object_id)
        }
      end)

    source_ids =
      Repo.all(
        from(object in SourcedContextObject,
          where: object.run_id == ^run.id,
          select: object.id
        )
      )
      |> MapSet.new()

    normalized =
      case ProcessorOutput.normalize(
             %{artifacts: raw_artifacts, warnings: %{}},
             source_ids,
             output_bounds()
           ) do
        {:ok, result} -> result.artifacts
        {:error, reason} -> Repo.rollback(reason)
      end

    artifacts_by_identity = Map.new(artifacts, &{{&1.kind, &1.stable_key}, &1})

    selection =
      Enum.map(normalized, fn artifact ->
        identity = {artifact["kind"], artifact["stable_key"]}
        source = Map.fetch!(artifacts_by_identity, identity)
        payload_sha256 = CanonicalJSON.sha256(CanonicalJSON.encode!(artifact["payload"]))

        %{
          "artifact_id" => source.id,
          "kind" => artifact["kind"],
          "payload_sha256" => payload_sha256
        }
      end)

    {selection, normalized, artifacts_by_identity}
  end

  defp create_revision(
         run,
         parent,
         user_id,
         selection_sha256,
         normalized_artifacts,
         artifacts_by_identity
       ) do
    now = DateTime.utc_now()
    revision_number = next_revision(run.id)

    if revision_number > bound(:run_review_revisions, 50) do
      Repo.rollback(:run_review_revision_bound_exceeded)
    end

    review =
      %SourcedContextReviewRevision{}
      |> SourcedContextReviewRevision.changeset(%{
        run_id: run.id,
        snapshot_id: parent.snapshot_id,
        derivation_id: parent.derivation_id,
        parent_revision_id: parent.id,
        revision: revision_number,
        created_by_user_id: user_id,
        selection_sha256: selection_sha256,
        selected_count: length(normalized_artifacts),
        created_at: now
      })
      |> Repo.insert!()

    Enum.each(normalized_artifacts, fn normalized ->
      identity = {normalized["kind"], normalized["stable_key"]}
      artifact = Map.fetch!(artifacts_by_identity, identity)
      id = Ecto.UUID.generate()
      {:ok, sealed} = Payloads.seal(:review_item, id, normalized["payload"])

      %SourcedContextReviewItem{id: id}
      |> SourcedContextReviewItem.changeset(%{
        review_revision_id: review.id,
        artifact_id: artifact.id,
        kind: artifact.kind,
        payload_ciphertext: sealed.ciphertext,
        payload_sha256: sealed.sha256,
        created_at: now
      })
      |> Repo.insert!()
    end)

    {updated_run, _event} =
      SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
        StateMachine.revise_preview(protocol_run, protocol_run.generation, review.id)
      end)

    %{
      run: updated_run,
      review_revision: Repo.preload(review, :items),
      replayed?: false
    }
  end

  defp replay_revision(run, parent, selection_sha256) do
    case Repo.one(
           from(review in SourcedContextReviewRevision,
             where:
               review.parent_revision_id == ^parent.id and
                 review.selection_sha256 == ^selection_sha256,
             order_by: [desc: review.revision],
             limit: 1
           )
         ) do
      %SourcedContextReviewRevision{id: id} = review when id == run.review_revision_id ->
        %{
          run: run,
          review_revision: Repo.preload(review, :items),
          replayed?: true
        }

      _ ->
        Repo.rollback(:stale_preview_revision)
    end
  end

  defp audit_preview_revision({:ok, %{replayed?: false} = result} = response) do
    run = result.run
    review = result.review_revision

    Instrumentation.record_audit(
      "sourced_context.preview.revised",
      %{
        org_id: run.org_id,
        project_id: run.project_id,
        resource_type: "slack_history_import_run",
        resource_id: run.id,
        resource_label: "Slack history onboarding"
      },
      review.created_by_user_id,
      review.id,
      %{
        snapshot_id: review.snapshot_id,
        derivation_id: review.derivation_id,
        review_revision_id: review.id,
        parent_review_revision_id: review.parent_revision_id,
        review_revision: review.revision,
        selected_count: review.selected_count,
        selection_sha256: review.selection_sha256
      }
    )

    response
  end

  defp audit_preview_revision(response), do: response

  defp normalize_revision_request(attrs) do
    items = value(attrs, :items)

    with expected_generation when is_integer(expected_generation) and expected_generation >= 0 <-
           value(attrs, :expected_generation),
         {:ok, user_id} <- uuid(value(attrs, :user_id), :invalid_user_id),
         {:ok, parent_id} <-
           uuid(value(attrs, :parent_review_revision_id), :invalid_parent_review_revision_id),
         true <- is_list(items) and length(items) <= bound(:derivation_artifacts, 100),
         {:ok, items} <- normalize_requested_items(items) do
      {:ok,
       %{
         expected_generation: expected_generation,
         user_id: user_id,
         parent_review_revision_id: parent_id,
         items: items
       }}
    else
      false -> {:error, :preview_selection_bound_exceeded}
      nil -> {:error, :invalid_expected_generation}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_preview_revision}
    end
  end

  defp normalize_requested_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      with true <- is_map(item),
           {:ok, artifact_id} <- uuid(value(item, :artifact_id), :invalid_artifact_id),
           {:ok, payload} <- requested_payload(item) do
        {:cont, {:ok, [%{artifact_id: artifact_id, payload: payload} | acc]}}
      else
        false -> {:halt, {:error, :invalid_preview_item}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)

        if length(normalized) == length(Enum.uniq_by(normalized, & &1.artifact_id)),
          do: {:ok, normalized},
          else: {:error, :duplicate_preview_artifact}

      error ->
        error
    end
  end

  defp requested_payload(item) do
    case fetch_value(item, :payload) do
      :error -> {:ok, :use_artifact}
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _invalid} -> {:error, :invalid_preview_payload}
    end
  end

  defp run_evidence(run) do
    %{
      id: run.id,
      generation: run.generation,
      state: run.state,
      project_id: run.project_id,
      source_workspace_id: run.source_workspace_id,
      selected_channels: Enum.map(Repo.preload(run, :channels).channels, & &1.channel_id),
      range_start: run.range_start,
      range_end: run.range_end,
      coverage_profile: run.coverage_profile,
      audience_scope: run.audience_scope,
      context_bundle_id: run.context_bundle_id
    }
  end

  defp snapshot_evidence(snapshot) do
    %{
      id: snapshot.id,
      run_id: snapshot.run_id,
      normalization_revision: snapshot.normalization_revision,
      manifest_sha256: snapshot.manifest_sha256,
      object_count: snapshot.object_count,
      byte_count: snapshot.byte_count,
      coverage: snapshot.coverage,
      finalized_at: snapshot.finalized_at
    }
  end

  defp derivation_evidence(derivation) do
    %{
      id: derivation.id,
      run_id: derivation.run_id,
      snapshot_id: derivation.snapshot_id,
      parent_derivation_id: derivation.parent_derivation_id,
      model_provider: derivation.model_provider,
      model_id: derivation.model_id,
      model_revision: derivation.model_revision,
      prompt_template_id: derivation.prompt_template_id,
      prompt_revision: derivation.prompt_revision,
      policy_revision: derivation.policy_revision,
      schema_revision: derivation.schema_revision,
      processor_config: derivation.processor_config,
      output_sha256: derivation.output_sha256,
      artifact_count: derivation.artifact_count,
      completed_at: derivation.completed_at
    }
  end

  defp preview_state(%{state: state, review_revision_id: id})
       when state in ["preview_ready", "committed", "rolled_back"] and not is_nil(id),
       do: :ok

  defp preview_state(_run), do: {:error, :preview_not_ready}

  defp lifecycle_ready(bundle_id) do
    case Repo.get(ContextBundle, bundle_id) do
      %ContextBundle{lifecycle_state: "registered", subject_index_state: "complete"} -> :ok
      _ -> {:error, :context_lifecycle_not_ready}
    end
  end

  defp authorize_admin(user_id, project_id) do
    case Memberships.authorize(user_id, :write, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp require_ok(:ok), do: :ok
  defp require_ok({:error, reason}), do: Repo.rollback(reason)

  defp lock_run(id) do
    Repo.one(
      from(run in SlackHistoryImportRun,
        where: run.id == ^id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  # Lifecycle owns the bundle row. Lock it before the import run so an erasure
  # or deletion request cannot race a review revision that writes new content.
  defp lock_lifecycle_ready_run(run_id) do
    bundle_id =
      Repo.one(
        from(run in SlackHistoryImportRun,
          where: run.id == ^run_id,
          select: run.context_bundle_id
        )
      ) || Repo.rollback(:not_found)

    bundle =
      Repo.one(
        from(bundle in ContextBundle,
          where: bundle.id == ^bundle_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:context_lifecycle_not_ready)

    :ok = require_ok(lifecycle_ready(bundle.id))
    run = lock_run(run_id)

    if run.context_bundle_id == bundle.id,
      do: {bundle, run},
      else: Repo.rollback(:context_lifecycle_not_ready)
  end

  defp next_revision(run_id) do
    (Repo.one(
       from(review in SourcedContextReviewRevision,
         where: review.run_id == ^run_id,
         select: max(review.revision)
       )
     ) || 0) + 1
  end

  defp output_bounds do
    [
      max_artifacts: bound(:derivation_artifacts, 100),
      max_sources_per_artifact: bound(:artifact_sources, 20),
      max_payload_bytes: bound(:artifact_payload_bytes, 8_000),
      max_warnings_bytes: bound(:derivation_warnings_bytes, 16_384)
    ]
  end

  defp bound(key, default) do
    Application.get_env(:bridge_for_teams_core, :sourced_context_bounds, [])
    |> Keyword.get(key, default)
  end

  defp feature_enabled do
    if Keyword.get(
         Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
         :derivation,
         false
       ),
       do: :ok,
       else: {:error, {:feature_disabled, :derivation}}
  end

  defp encryption_available do
    if Crypto.available?(),
      do: :ok,
      else: {:error, :sourced_context_encryption_unavailable}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp value(map, key, default \\ nil) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
end
