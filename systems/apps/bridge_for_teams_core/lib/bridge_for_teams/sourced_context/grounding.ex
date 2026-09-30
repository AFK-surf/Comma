defmodule BridgeForTeams.SourcedContext.Grounding do
  @moduledoc """
  Feature-off runtime overlay over active sourced-context publications.

  Result cardinality, decrypted artifacts, and resolver inputs are bounded.
  The current representative-selection query still scans active supports and
  therefore is not production-enable safe without the canonical projection
  described in the onboarding RFC. Normal configuration keeps runtime
  grounding and product Knowledge inspection independently off.

  The read path rechecks the active Agent, project, publication, fixed product
  publication scope, and source-neutral lifecycle state on every request.
  `ground_for_triage/4` additionally requires the current request capability
  produced only after BFT Triage has revalidated its Salix source authority.
  The capability binds the active organization, project, Agent caller, Slack
  destination, connect generation, and fixed audience scope.
  `ground_for_project_agent/4` is the separate source-neutral path for the
  exact active project Agent used by Salix runtime retrieval. The generic
  `ground_for_agent/3` remains an internal/test seam and must not be wired into
  a live request path that lacks one of those capabilities.

  Slack connection liveness is intentionally absent from publication
  visibility. Rollback removes visibility by deactivating the publication edge;
  it does not delete the underlying bundle.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo}
  alias BridgeForTeams.ContextLifecycle.ReadBarrier

  alias BridgeForTeams.Schema.{
    Agent,
    ContextBundle,
    Organization,
    Project,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextArtifactSource,
    SourcedContextPublication,
    SourcedContextReviewItem
  }

  alias BridgeForTeams.SourcedContext.{Crypto, Instrumentation, Payloads}

  @entity_kinds ~w(person project)
  @fact_kinds ~w(decision context)
  @candidate_selection_attempts 3
  @triage_capability_keys ~w(schema org_id project_id caller audience)
  @triage_caller_keys ~w(kind agent_id salix_agent_id)
  @project_agent_capability_keys ~w(schema project_id caller audience)
  @project_agent_caller_keys ~w(kind agent_id salix_agent_id)
  @project_agent_audience_keys ~w(scope surface)
  @project_agent_schema "comma.bft-sourced-context-project-agent.v1"
  @project_audience_scope "project-public-channels:v1"

  @triage_audience_keys ~w(
    scope
    provider
    tenant_id
    group_id
    connect_id
    connect_generation
    triage_authority_generation
    workspace_id
    app_id
    channel_id
    visibility
    shared
    authority_revision
    source_mode
  )

  @spec ground_for_agent(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | :none | {:error, term()}
  def ground_for_agent(agent_id, question, opts \\ []) do
    run_grounding(agent_id, question, opts, fn _agent, _project -> :ok end)
  end

  @doc "Ground one current, authority-bound BFT Triage request."
  @spec ground_for_triage(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | :none | {:error, term()}
  def ground_for_triage(agent_id, question, capability, opts \\ []) do
    run_grounding(agent_id, question, opts, fn agent, project ->
      with {:ok, org} <- active_organization(project.org_id) do
        validate_triage_capability(capability, org, project, agent)
      end
    end)
  end

  @doc "Ground one exact active project Agent request against shared sourced context."
  @spec ground_for_project_agent(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | :none | {:error, term()}
  def ground_for_project_agent(agent_id, question, capability, opts \\ []) do
    run_grounding(agent_id, question, opts, fn agent, project ->
      with {:ok, _org} <- active_organization(project.org_id) do
        validate_project_agent_capability(capability, project, agent)
      end
    end)
  end

  @doc false
  @spec project_agent_capability(Agent.t()) :: map()
  def project_agent_capability(%Agent{} = agent) do
    %{
      "schema" => @project_agent_schema,
      "project_id" => agent.project_id,
      "caller" => %{
        "kind" => "salix_agent",
        "agent_id" => agent.id,
        "salix_agent_id" => agent.salix_agent_id
      },
      "audience" => %{
        "scope" => @project_audience_scope,
        "surface" => "project_agent"
      }
    }
  end

  @doc "Cheap local preflight for whether a project may contribute sourced context."
  @spec project_context_available?(Ecto.UUID.t()) :: boolean()
  def project_context_available?(project_id) when is_binary(project_id) do
    with true <- enabled?(),
         {:ok, ^project_id} <- Ecto.UUID.cast(project_id) do
      Repo.exists?(active_candidate_scope(project_id))
    else
      _other -> false
    end
  end

  def project_context_available?(_project_id), do: false

  @doc """
  List the active sourced-context knowledge visible to one exact project Agent.

  This is the authorized product inspection projection used by Knowledge. It
  deliberately does not check the runtime grounding feature: committed,
  lifecycle-ready knowledge may remain inspectable even when Agent use is off.
  It does require the independent, default-off Knowledge-inspection launch gate
  because the shared representative-selection query is not yet storage-bounded.
  Candidate selection, lifecycle fencing, payload decryption, provenance, and
  bounds are shared with runtime grounding so the two surfaces cannot disagree
  about which active publication supports a canonical item.
  """
  @spec list_active_context_for_agent(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{items: [map()]}} | :none | {:error, term()}
  def list_active_context_for_agent(agent_id, user_id, opts \\ []) do
    Instrumentation.measure(:sourced_context_knowledge, fn ->
      if knowledge_inspection_enabled?() do
        with :ok <- encryption_available(),
             {:ok, agent} <- active_agent(agent_id),
             {:ok, project} <- active_project(agent.project_id),
             :ok <- authorize_admin(user_id, project.id) do
          case project_current_context(
                 project,
                 opts,
                 @candidate_selection_attempts,
                 fn candidates ->
                   {:ok, %{items: knowledge_items(project.id, candidates)}}
                 end
               ) do
            :none -> {:ok, %{items: []}}
            result -> result
          end
        end
      else
        :none
      end
    end)
  end

  defp run_grounding(agent_id, question, opts, authorize_request) do
    Instrumentation.measure(:sourced_context_grounding, fn ->
      if enabled?() do
        with :ok <- encryption_available(),
             {:ok, agent} <- active_agent(agent_id),
             {:ok, project} <- active_project(agent.project_id),
             :ok <- authorize_request.(agent, project) do
          ground_current_context(
            project,
            question,
            opts,
            @candidate_selection_attempts
          )
        else
          {:error, reason} -> {:error, reason}
        end
      else
        :none
      end
    end)
  end

  defp ground_current_context(project, question, opts, attempts_left) do
    project_current_context(project, opts, attempts_left, fn candidates ->
      resolve(
        question,
        project.id,
        candidates,
        Keyword.drop(opts, [:candidate_selection_observer, :candidate_projection_observer])
      )
    end)
  end

  defp project_current_context(project, opts, attempts_left, projector)
       when is_function(projector, 1) do
    with {:ok, rows} <- active_candidate_rows(project.id),
         false <- rows == [] do
      observe_candidate_selection(rows, opts)
      bundle_ids = rows |> Enum.map(& &1.bundle_id) |> Enum.uniq()

      result =
        ReadBarrier.run(bundle_ids, fn ->
          with {:ok, current} <- active_candidate_rows(project.id),
               :ok <- require_locked_candidate_bundles(current, bundle_ids),
               false <- current == [],
               {:ok, candidates} <- load_candidates(current) do
            observe_candidate_projection(candidates, opts)
            projector.(candidates)
          else
            true -> :none
            {:error, reason} -> {:error, reason}
          end
        end)

      case result do
        {:error, :candidate_support_changed} when attempts_left > 1 ->
          project_current_context(project, opts, attempts_left - 1, projector)

        {:error, :candidate_support_changed} ->
          {:error, :grounding_selection_unstable}

        other ->
          other
      end
    else
      true -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # The first query chooses at most one support per canonical key. A rollback
  # can win before the lifecycle share-lock is acquired, in which case the
  # unrestricted re-read selects an older support from a different bundle.
  # Never decrypt that unlocked fallback: restart the bounded selection so it
  # receives the same lifecycle fence. New commits can cause the same retry.
  defp require_locked_candidate_bundles(rows, locked_bundle_ids) do
    locked = MapSet.new(locked_bundle_ids)

    if Enum.all?(rows, &MapSet.member?(locked, &1.bundle_id)),
      do: :ok,
      else: {:error, :candidate_support_changed}
  end

  # In-process test observer only; no runtime or browser input is forwarded to
  # Grounding options. It makes the select-before-lock rollback window
  # deterministic without changing candidate rows or production behavior.
  defp observe_candidate_selection(rows, opts) do
    case Keyword.get(opts, :candidate_selection_observer) do
      observer when is_function(observer, 1) -> observer.(rows)
      _other -> :ok
    end
  end

  # In-process test observer only. Keeping it immediately before the projector
  # lets concurrency tests prove that decrypted payload materialization remains
  # inside the lifecycle read barrier. No runtime or browser input is forwarded
  # to Grounding options.
  defp observe_candidate_projection(candidates, opts) do
    case Keyword.get(opts, :candidate_projection_observer) do
      observer when is_function(observer, 1) -> observer.(candidates)
      _other -> :ok
    end
  end

  @doc "Merge the existing ProjectKnowledge result with the sourced-context overlay."
  @spec merge_results({:ok, map()} | {:error, term()}, {:ok, map()} | :none | {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def merge_results(base, :none), do: base
  def merge_results(base, {:error, _overlay_reason}), do: base
  def merge_results({:error, reason}, _overlay), do: {:error, reason}

  def merge_results({:ok, base}, {:ok, overlay}) do
    merge_resolved_results(base, overlay)
  end

  # Import runs are provenance/rollback units, not separately stacked context
  # layers. PostgreSQL therefore selects one deterministic active reviewed value
  # for each processor-owned canonical {kind, stable_key} before the runtime
  # item bound is applied. A later rollback simply makes the next active support
  # eligible; the number of committed runs never disables the whole overlay.
  defp active_candidate_rows(project_id) do
    limit = bound(:grounding_items, 200)

    query =
      from([item, artifact, publication, run, bundle] in active_candidate_scope(project_id),
        distinct: [asc: artifact.kind, asc: artifact.stable_key],
        order_by: [
          asc: artifact.kind,
          asc: artifact.stable_key,
          desc: publication.activated_at,
          desc: publication.id
        ],
        limit: ^(limit + 1),
        select: %{
          publication: publication,
          run: run,
          bundle_id: bundle.id,
          item: item,
          artifact: artifact
        }
      )

    rows = Repo.all(query)

    if length(rows) > limit,
      do: {:error, :grounding_item_bound_exceeded},
      else: {:ok, rows}
  end

  defp active_candidate_scope(project_id) do
    from(item in SourcedContextReviewItem,
      join: artifact in SourcedContextArtifact,
      on: artifact.id == item.artifact_id and artifact.kind == item.kind,
      join: publication in SourcedContextPublication,
      on: publication.review_revision_id == item.review_revision_id,
      join: run in SlackHistoryImportRun,
      on: run.id == publication.run_id,
      join: bundle in ContextBundle,
      as: :bundle,
      on: bundle.id == publication.bundle_id,
      where:
        publication.status == "active" and run.state == "committed" and
          run.publication_id == publication.id and run.project_id == ^project_id and
          bundle.project_id == ^project_id and bundle.lifecycle_state == "registered" and
          bundle.subject_index_state == "complete" and
          publication.audience_scope == run.audience_scope and
          run.audience_scope == "project-public-channels:v1"
    )
  end

  defp load_candidates(rows) do
    artifact_ids = Enum.map(rows, & &1.artifact.id)
    source_limit = length(artifact_ids) * bound(:artifact_sources, 20)

    sources =
      if artifact_ids == [] do
        []
      else
        Repo.all(
          from(source in SourcedContextArtifactSource,
            where: source.artifact_id in ^artifact_ids,
            order_by: [asc: source.artifact_id, asc: source.source_object_id],
            limit: ^(source_limit + 1)
          )
        )
      end

    if length(sources) > source_limit do
      {:error, :grounding_source_bound_exceeded}
    else
      sources_by_artifact = Enum.group_by(sources, & &1.artifact_id)

      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        item = row.item
        artifact = row.artifact
        artifact_sources = Map.get(sources_by_artifact, artifact.id, [])

        with true <- artifact_sources != [],
             {:ok, payload} <-
               Payloads.unseal(
                 :review_item,
                 item.id,
                 item.payload_ciphertext,
                 item.payload_sha256
               ),
             {:ok, candidate} <- candidate(row, item, artifact, artifact_sources, payload) do
          {:cont, {:ok, [candidate | acc]}}
        else
          false -> {:halt, {:error, :grounding_provenance_missing}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
        error -> error
      end
    end
  end

  defp candidate(publication, item, artifact, sources, payload)
       when artifact.kind in @entity_kinds do
    with name when is_binary(name) and name != "" <- payload["name"],
         aliases when is_list(aliases) <- payload["aliases"],
         true <- Enum.all?(aliases, &(is_binary(&1) and &1 != "")),
         semantic_key = semantic_entity_key(artifact.kind, artifact.stable_key, name),
         true <- byte_size(artifact.stable_key) <= 256 do
      {:ok,
       %{
         type: :entity,
         publication_id: publication.publication.id,
         run_id: publication.run.id,
         item_id: item.id,
         kind: artifact.kind,
         stable_key: artifact.stable_key,
         semantic_key: semantic_key,
         name: name,
         aliases: [name | aliases] |> Enum.uniq_by(&normalize_alias/1),
         source_refs: source_refs(publication.publication.id, sources)
       }}
    else
      _ -> {:error, :invalid_grounding_entity}
    end
  end

  defp candidate(publication, item, artifact, sources, payload)
       when artifact.kind in @fact_kinds do
    with content when is_binary(content) and content != "" <- payload["content"],
         about when is_list(about) and about != [] <- payload["about"],
         {:ok, about} <- normalize_about(about) do
      {:ok,
       %{
         type: :fact,
         publication_id: publication.publication.id,
         run_id: publication.run.id,
         item_id: item.id,
         kind: artifact.kind,
         stable_key: artifact.stable_key,
         content: content,
         about: about,
         source_refs: source_refs(publication.publication.id, sources)
       }}
    else
      _ -> {:error, :invalid_grounding_fact}
    end
  end

  defp candidate(_publication, _item, _artifact, _sources, _payload),
    do: {:error, :invalid_grounding_kind}

  defp knowledge_items(project_id, candidates) do
    entities =
      candidates
      |> Enum.filter(&(&1.type == :entity))
      |> merge_entities(project_id)
      |> Enum.map(fn entity ->
        %{
          id: entity.id,
          kind: entity_kind_atom(entity.kind),
          name: entity.name,
          aliases: entity.aliases,
          source_refs: entity.source_refs
        }
      end)

    facts =
      candidates
      |> Enum.filter(&(&1.type == :fact))
      |> Enum.map(fn fact ->
        %{
          id: fact_id(fact.kind, fact.stable_key, fact.about),
          kind: fact_kind_atom(fact.kind),
          content: fact.content,
          about: fact.about,
          source_refs: fact.source_refs
        }
      end)

    Enum.sort_by(entities ++ facts, &{knowledge_kind_rank(&1.kind), &1.id})
  end

  defp resolve(question, project_id, candidates, opts) when is_binary(question) do
    question = String.trim(question)

    if question == "" do
      {:ok, empty_result(:unknown)}
    else
      entities = candidates |> Enum.filter(&(&1.type == :entity)) |> merge_entities(project_id)
      facts = Enum.filter(candidates, &(&1.type == :fact))
      resolve_matches(question, entities, facts, opts)
    end
  end

  defp resolve(_question, _project_id, _candidates, _opts),
    do: {:ok, empty_result(:unknown)}

  defp merge_entities(entities, project_id) do
    entities
    |> Enum.group_by(& &1.semantic_key)
    |> Enum.map(fn {semantic_key, versions} ->
      first = hd(versions)

      %{
        semantic_key: semantic_key,
        kind: first.kind,
        id: entity_id(project_id, semantic_key),
        stable_key: first.stable_key,
        name: first.name,
        aliases:
          versions
          |> Enum.flat_map(& &1.aliases)
          |> Enum.uniq_by(&normalize_alias/1)
          |> Enum.sort_by(&normalize_alias/1),
        source_refs:
          versions
          |> Enum.flat_map(& &1.source_refs)
          |> Enum.uniq()
          |> Enum.sort_by(&{&1.type, &1.ref}),
        source_keys: versions |> Enum.map(&{&1.kind, &1.stable_key}) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp resolve_matches(question, entities, facts, opts) do
    matches = Enum.flat_map(entities, &entity_matches(question, &1))

    case classify_matches(matches) do
      {:ok, []} ->
        {:ok, empty_result(:unknown)}

      {:error, :ambiguous} ->
        {:ok, empty_result(:ambiguous)}

      {:ok, resolved} ->
        entity_limit = bounded_opt(opts, :entity_limit, 20)
        fact_limit = bounded_opt(opts, :fact_limit, 20)

        if length(resolved) > entity_limit do
          {:ok, empty_result(:incomplete)}
        else
          resolved_keys = MapSet.new(resolved, & &1.semantic_key)
          grounded_facts = ground_facts(facts, entities, resolved_keys)

          if length(grounded_facts) > fact_limit do
            {:ok, empty_result(:incomplete)}
          else
            result = %{
              status: :resolved,
              entities: Enum.map(resolved, &entity_view/1),
              facts: grounded_facts
            }

            if source_ref_count(result) <= bound(:grounding_source_refs, 500),
              do: {:ok, result},
              else: {:ok, empty_result(:incomplete)}
          end
        end
    end
  end

  defp entity_matches(question, entity) do
    Enum.flat_map(entity.aliases, fn alias_value ->
      normalized = normalize_alias(alias_value)
      question = String.downcase(question)

      pattern =
        if Regex.match?(~r/\p{Han}/u, normalized) do
          Regex.escape(normalized)
        else
          "(?<![\\p{L}\\p{N}_])" <> Regex.escape(normalized) <> "(?![\\p{L}\\p{N}_])"
        end

      pattern
      |> Regex.compile!("u")
      |> Regex.scan(question, return: :index)
      |> Enum.map(fn [{start, length}] ->
        %{
          entity: entity,
          alias: alias_value,
          normalized_alias: normalized,
          start: start,
          length: length
        }
      end)
    end)
  end

  defp classify_matches(matches) do
    alias_targets = Enum.group_by(matches, & &1.normalized_alias, & &1.entity.semantic_key)

    if Enum.any?(alias_targets, fn {_alias, keys} -> length(Enum.uniq(keys)) > 1 end) or
         overlapping_entities?(matches) do
      {:error, :ambiguous}
    else
      resolved =
        matches
        |> Enum.uniq_by(& &1.entity.semantic_key)
        |> Enum.map(fn match -> Map.put(match.entity, :matched_alias, match.alias) end)
        |> Enum.sort_by(&{&1.kind, &1.id})

      {:ok, resolved}
    end
  end

  defp overlapping_entities?(matches) do
    matches
    |> Enum.with_index()
    |> Enum.any?(fn {left, index} ->
      matches
      |> Enum.drop(index + 1)
      |> Enum.any?(fn right ->
        left.entity.semantic_key != right.entity.semantic_key and
          left.start < right.start + right.length and right.start < left.start + left.length
      end)
    end)
  end

  defp ground_facts(facts, entities, resolved_keys) do
    entity_by_canonical_key =
      entities
      |> Enum.flat_map(fn entity ->
        Enum.map(entity.source_keys, &{&1, entity.semantic_key})
      end)
      |> Map.new()

    facts
    |> Enum.reduce([], fn fact, acc ->
      about_keys =
        Enum.map(fact.about, fn reference ->
          Map.get(entity_by_canonical_key, {reference.kind, reference.stable_key})
        end)

      if Enum.all?(about_keys, &(not is_nil(&1) and MapSet.member?(resolved_keys, &1))) do
        about_entities =
          about_keys
          |> Enum.uniq()
          |> Enum.map(fn semantic_key ->
            entity = Enum.find(entities, &(&1.semantic_key == semantic_key))
            {entity_kind_atom(entity.kind), entity.id}
          end)
          |> Enum.sort()

        fact_view = %{
          id: fact_id(fact.kind, fact.stable_key, about_entities),
          kind: if(fact.kind == "decision", do: :decision, else: :fact),
          semantic_key: {fact.kind, fact.stable_key},
          content: fact.content,
          about: about_entities,
          source_refs: fact.source_refs
        }

        [fact_view | acc]
      else
        acc
      end
    end)
    |> merge_facts()
    |> Enum.map(&Map.delete(&1, :semantic_key))
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp merge_facts(facts) do
    facts
    |> Enum.group_by(&{&1.semantic_key, &1.about})
    |> Enum.map(fn {_key, versions} ->
      first = hd(versions)

      %{
        first
        | source_refs:
            versions
            |> Enum.flat_map(& &1.source_refs)
            |> Enum.uniq()
            |> Enum.sort_by(&{&1.type, &1.ref})
      }
    end)
  end

  defp normalize_about(about) do
    about
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, acc} ->
      kind = reference["kind"]
      stable_key = reference["stable_key"]

      if kind in @entity_kinds and is_binary(stable_key) and stable_key != "" do
        {:cont, {:ok, [%{kind: kind, stable_key: stable_key} | acc]}}
      else
        {:halt, {:error, :invalid_grounding_about}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp source_refs(publication_id, sources) do
    publication_ref = %{type: "sourced_context_publication", ref: publication_id}

    object_refs =
      Enum.map(sources, fn source ->
        %{type: "sourced_context_object", ref: source.source_object_id}
      end)

    [publication_ref | object_refs] |> Enum.uniq() |> Enum.sort_by(&{&1.type, &1.ref})
  end

  defp semantic_entity_key(kind, stable_key, _name), do: {kind, stable_key}

  defp entity_id(project_id, semantic_key),
    do: opaque_id("ctx", {project_id, semantic_key})

  defp fact_id(kind, stable_key, about), do: opaque_id("ctxfact", {kind, stable_key, about})

  defp opaque_id(prefix, value) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "#{prefix}_#{digest}"
  end

  defp entity_view(entity) do
    %{
      kind: entity_kind_atom(entity.kind),
      id: entity.id,
      matched_alias: entity.matched_alias,
      source_refs: entity.source_refs
    }
  end

  defp entity_kind_atom("person"), do: :person
  defp entity_kind_atom("project"), do: :project

  defp fact_kind_atom("decision"), do: :decision
  defp fact_kind_atom("context"), do: :context

  defp knowledge_kind_rank(:person), do: 0
  defp knowledge_kind_rank(:project), do: 1
  defp knowledge_kind_rank(:decision), do: 2
  defp knowledge_kind_rank(:context), do: 3

  defp merge_resolved_results(base, overlay) do
    statuses = {value(base, :status), value(overlay, :status)}

    cond do
      :incomplete in Tuple.to_list(statuses) ->
        {:ok, empty_result(:incomplete)}

      :ambiguous in Tuple.to_list(statuses) ->
        {:ok, empty_result(:ambiguous)}

      value(base, :status) == :unknown ->
        {:ok, overlay}

      value(overlay, :status) == :unknown ->
        {:ok, base}

      value(base, :status) == :resolved and value(overlay, :status) == :resolved ->
        merge_two_resolved(base, overlay)

      true ->
        {:ok, empty_result(:unknown)}
    end
  end

  defp merge_two_resolved(base, overlay) do
    entities = value(base, :entities, []) ++ value(overlay, :entities, [])
    facts = value(base, :facts, []) ++ value(overlay, :facts, [])

    alias_targets =
      Enum.group_by(entities, &normalize_alias(value(&1, :matched_alias)), fn entity ->
        {value(entity, :kind), value(entity, :id)}
      end)

    cond do
      Enum.any?(alias_targets, fn {_alias, keys} -> length(Enum.uniq(keys)) > 1 end) ->
        {:ok, empty_result(:ambiguous)}

      length(entities) > 20 or length(facts) > 20 ->
        {:ok, empty_result(:incomplete)}

      true ->
        result = %{
          status: :resolved,
          entities: Enum.uniq_by(entities, &{value(&1, :kind), value(&1, :id)}),
          facts: Enum.uniq_by(facts, &value(&1, :id))
        }

        if source_ref_count(result) <= bound(:grounding_source_refs, 500),
          do: {:ok, result},
          else: {:ok, empty_result(:incomplete)}
    end
  end

  defp active_agent(id) do
    case BridgeForTeams.Agents.get_agent(id) do
      {:ok, %Agent{} = agent} ->
        if Agent.active?(agent), do: {:ok, agent}, else: {:error, :agent_inactive}

      {:error, :not_found} ->
        {:error, :agent_not_found}

      error ->
        error
    end
  end

  defp active_project(id) do
    case Repo.get(Project, id) do
      %Project{status: "active", archived_at: nil} = project -> {:ok, project}
      %Project{} -> {:error, :project_inactive}
      nil -> {:error, :project_not_found}
    end
  end

  defp authorize_admin(user_id, project_id) do
    case Memberships.authorize(user_id, :read, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp active_organization(id) do
    case Repo.get(Organization, id) do
      %Organization{status: "active"} = org -> {:ok, org}
      %Organization{} -> {:error, :organization_inactive}
      nil -> {:error, :organization_not_found}
    end
  end

  defp validate_triage_capability(capability, org, project, agent) when is_map(capability) do
    caller = value(capability, :caller)
    audience = value(capability, :audience)

    valid? =
      exact_keys?(capability, @triage_capability_keys) and
        exact_keys?(caller, @triage_caller_keys) and
        exact_keys?(audience, @triage_audience_keys) and
        value(capability, :schema) == "comma.bft-sourced-context-request.v1" and
        same_ref?(value(capability, :org_id), org.id) and
        same_ref?(value(capability, :project_id), project.id) and
        value(caller, :kind) == "salix_agent" and
        same_ref?(value(caller, :agent_id), agent.id) and
        same_ref?(value(caller, :salix_agent_id), agent.salix_agent_id) and
        value(audience, :scope) == "project-public-channels:v1" and
        value(audience, :provider) == "slack" and
        same_ref?(value(audience, :tenant_id), org.salix_tenant_id) and
        same_ref?(value(audience, :group_id), project.salix_group_id) and
        value(audience, :visibility) == "public" and
        value(audience, :shared) == false and
        sha256?(value(audience, :authority_revision)) and
        value(audience, :source_mode) in [
          "callback",
          "clickhouse_etl",
          "historical_thread_reenactment",
          "periodic_patrol",
          "scheduled_recheck"
        ] and
        Enum.all?(
          [
            :connect_id,
            :connect_generation,
            :triage_authority_generation,
            :workspace_id,
            :app_id,
            :channel_id
          ],
          &present?(value(audience, &1))
        )

    if valid?, do: :ok, else: {:error, :invalid_grounding_request_capability}
  end

  defp validate_triage_capability(_capability, _org, _project, _agent),
    do: {:error, :invalid_grounding_request_capability}

  defp validate_project_agent_capability(capability, project, agent)
       when is_map(capability) do
    caller = value(capability, :caller)
    audience = value(capability, :audience)

    valid? =
      exact_keys?(capability, @project_agent_capability_keys) and
        exact_keys?(caller, @project_agent_caller_keys) and
        exact_keys?(audience, @project_agent_audience_keys) and
        value(capability, :schema) == @project_agent_schema and
        same_ref?(value(capability, :project_id), project.id) and
        value(caller, :kind) == "salix_agent" and
        same_ref?(value(caller, :agent_id), agent.id) and
        same_ref?(value(caller, :salix_agent_id), agent.salix_agent_id) and
        value(audience, :scope) == @project_audience_scope and
        value(audience, :surface) == "project_agent"

    if valid?, do: :ok, else: {:error, :invalid_grounding_request_capability}
  end

  defp validate_project_agent_capability(_capability, _project, _agent),
    do: {:error, :invalid_grounding_request_capability}

  defp sha256?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp exact_keys?(map, expected) when is_map(map) do
    keys =
      map
      |> Map.keys()
      |> Enum.map(fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _other -> :invalid
      end)

    :invalid not in keys and Enum.sort(keys) == Enum.sort(expected)
  end

  defp exact_keys?(_map, _expected), do: false

  defp same_ref?(left, right) when not is_nil(left) and not is_nil(right),
    do: to_string(left) == to_string(right)

  defp same_ref?(_left, _right), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_alias(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_alias(_value), do: ""

  defp bounded_opt(opts, key, max) do
    case Keyword.get(opts, key, max) do
      value when is_integer(value) and value > 0 -> min(value, max)
      _ -> max
    end
  end

  defp bound(key, default) do
    Application.get_env(:bridge_for_teams_core, :sourced_context_bounds, [])
    |> Keyword.get(key, default)
  end

  @doc "Whether request-time sourced-context grounding is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: feature_enabled?(:grounding)

  @doc "Whether product Knowledge may inspect the current sourced-context projection."
  @spec knowledge_inspection_enabled?() :: boolean()
  def knowledge_inspection_enabled?, do: feature_enabled?(:knowledge_inspection)

  defp feature_enabled?(feature) do
    Keyword.get(
      Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
      feature,
      false
    )
  end

  defp encryption_available do
    if Crypto.available?(),
      do: :ok,
      else: {:error, :sourced_context_encryption_unavailable}
  end

  defp empty_result(status), do: %{status: status, entities: [], facts: []}

  defp source_ref_count(result) do
    (value(result, :entities, []) ++ value(result, :facts, []))
    |> Enum.flat_map(&value(&1, :source_refs, []))
    |> Enum.uniq()
    |> length()
  end

  defp value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
