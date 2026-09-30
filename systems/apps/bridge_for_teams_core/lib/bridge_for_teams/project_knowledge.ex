defmodule BridgeForTeams.ProjectKnowledge do
  @moduledoc """
  Project-shared, source-backed knowledge grounded in product-owned identities.

  Users, projects, and active project memberships remain authoritative in their
  existing product tables. Memberships are projected directly into Knowledge;
  this context only owns project-scoped aliases and append-only facts/decisions.
  Active Triage context is included through its canonical Salix read interface;
  `triage_context_entries` remains the lifecycle authority and is never copied
  into the append-only assertion table.
  Resolution fails closed: unknown, ambiguous, or incomplete alias scans never
  expose an assertion to an Agent.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo}
  alias BridgeForTeams.Salix.Client

  alias BridgeForTeams.Schema.{
    Agent,
    OrgMembership,
    Project,
    ProjectKnowledgeAlias,
    ProjectKnowledgeAssertion,
    ProjectKnowledgeAssertionSubject,
    User
  }

  @alias_limit 200
  @assertion_limit 50
  @list_limit 50
  @subject_limit 20
  @usage_limit 100
  @usage_session_limit 50
  @member_limit 100
  @retained_context_limit 50
  @retained_context_max_limit 99
  @source_types ~w(slack_receipt meeting manual product_directory)

  @type entity_ref :: {:person, Ecto.UUID.t()} | {:project, Ecto.UUID.t()}
  @type status :: :resolved | :unknown | :ambiguous | :incomplete

  @doc "Register one sourced alias without replacing earlier evidence."
  @spec register_alias(Ecto.UUID.t(), entity_ref(), String.t(), map()) ::
          {:ok, ProjectKnowledgeAlias.t()} | {:error, term()}
  def register_alias(project_id, entity, alias_value, source) do
    alias_value = normalize_display(alias_value)

    with {:ok, project} <- fetch_active_project(project_id),
         :ok <- validate_entity_scope(project, entity),
         {:ok, source_type, source_ref} <- validate_source(source) do
      attrs =
        %{
          project_id: project.id,
          entity_kind: entity_kind(entity),
          alias: alias_value,
          normalized_alias: normalize_alias(alias_value),
          source_type: source_type,
          source_ref: source_ref
        }
        |> put_entity(entity)

      %ProjectKnowledgeAlias{}
      |> ProjectKnowledgeAlias.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Append one sourced assertion and all of its stable product subjects atomically."
  @spec append_assertion(Ecto.UUID.t(), String.t(), String.t(), [entity_ref()], map()) ::
          {:ok, ProjectKnowledgeAssertion.t()} | {:error, term()}
  def append_assertion(project_id, kind, content, subjects, source)
      when is_list(subjects) and subjects != [] and length(subjects) <= @subject_limit do
    with {:ok, project} <- fetch_active_project(project_id),
         :ok <- validate_entity_scopes(project, subjects),
         {:ok, source_type, source_ref} <- validate_source(source) do
      Repo.transaction(fn ->
        attrs = %{
          project_id: project.id,
          kind: to_string(kind),
          content: normalize_display(content),
          source_type: source_type,
          source_ref: source_ref,
          observed_at: source_time(source)
        }

        assertion =
          %ProjectKnowledgeAssertion{}
          |> ProjectKnowledgeAssertion.changeset(attrs)
          |> Repo.insert!()

        subjects
        |> Enum.uniq()
        |> Enum.each(fn entity ->
          %ProjectKnowledgeAssertionSubject{}
          |> ProjectKnowledgeAssertionSubject.changeset(
            put_entity(%{assertion_id: assertion.id}, entity)
          )
          |> Repo.insert!()
        end)

        Repo.preload(assertion, :subjects)
      end)
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  def append_assertion(_project_id, _kind, _content, subjects, _source)
      when is_list(subjects) and length(subjects) > @subject_limit,
      do: {:error, :too_many_subjects}

  def append_assertion(_project_id, _kind, _content, _subjects, _source),
    do: {:error, :subjects_required}

  @doc """
  List one Agent's project-shared knowledge with source and accepted-use evidence.

  PostgreSQL owns the assertion and entity projection. Salix session state owns
  usage: a project-knowledge runtime message exists only when it was committed
  with an accepted assistant response. Runtime read failures remain explicit so
  callers never render "unused" when the evidence source was unavailable.
  """
  @spec list_for_agent(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_for_agent(agent_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @list_limit) |> min_bounded(@list_limit, 100)

    with {:ok, agent} <- fetch_active_agent(agent_id),
         {:ok, project} <- fetch_active_project(agent.project_id) do
      {assertions, assertions_complete?} = list_assertions(project.id, limit)
      {aliases, aliases_complete?} = list_display_aliases(project.id, assertions)
      {members, members_complete?} = list_members(project)
      usage = list_usage(agent, assertions, opts)
      retained_context = list_retained_context(agent, project, opts)
      uses_by_assertion = index_uses(usage)

      {:ok,
       %{
         project: %{id: project.id, name: project.name},
         agent: %{id: agent.id, salix_agent_id: agent.salix_agent_id, name: agent.salix["name"]},
         assertions: Enum.map(assertions, &assertion_list_view(&1, aliases, uses_by_assertion)),
         assertions_complete: assertions_complete?,
         entities_complete: aliases_complete?,
         members: members,
         members_complete: members_complete?,
         usage_status: usage_status(usage),
         usage_complete: usage_complete?(usage),
         retained_context: retained_context_items(retained_context),
         retained_context_status: retained_context_status(retained_context),
         retained_context_complete: retained_context_complete?(retained_context)
       }}
    end
  end

  @doc "Resolve and retrieve project knowledge for an exact active Agent."
  @spec ground_for_agent(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, %{status: status(), entities: [map()], facts: [map()]}} | {:error, term()}
  def ground_for_agent(agent_id, question, opts \\ []) do
    with {:ok, agent} <- fetch_active_agent(agent_id) do
      ground(agent.project_id, question, opts)
    end
  end

  @doc "Retrieve relevant active Triage context through its canonical project interface."
  def ground_retained_for_agent(agent_id, question, opts \\ []) when is_binary(question) do
    limit = min_bounded(opts[:limit], 20, 20)

    with {:ok, agent} <- fetch_active_agent(agent_id),
         {:ok, project} <- fetch_active_project(agent.project_id),
         {:ok, %{} = result} <-
           Client.impl().triage_knowledge_context(project.id, project.salix_group_id, agent.id,
             limit: limit,
             query: String.slice(question, 0, 512)
           ),
         {:ok, %{items: retained}} <- normalize_retained_context({:ok, result}) do
      retained = Enum.take(retained, limit)

      facts =
        Enum.map(retained, fn item ->
          attribution =
            item.source_attribution
            |> Enum.map(&Map.take(&1, ["actor_id", "message_ts"]))
            |> Jason.encode!()

          %{
            id: item.id,
            kind: :fact,
            content:
              "#{item.name}: #{item.content}\nRecorded context (#{item.source_kind}, #{item.confidence}), scope #{item.knowledge_scope || "unknown"}, updated at #{item.updated_at_ms}. " <>
                "Source attribution: #{attribution}. " <>
                "Personal statements are not team rules. Explicit team rules take precedence over conflicting personal preferences. " <>
                "Source time is not a freshness guarantee. This record does not authorize an action.",
            source_refs: [item.source],
            about: [retained_subject(item, project)]
          }
        end)

      if facts == [] do
        {:ok, empty_result(:unknown)}
      else
        {:ok,
         %{
           status: :resolved,
           entities:
             retained
             |> Enum.map(fn item ->
               {kind, id} = retained_subject(item, project)

               %{
                 kind: kind,
                 id: id,
                 matched_alias: if(kind == :project, do: project.name, else: id)
               }
             end)
             |> Enum.uniq_by(&{&1.kind, &1.id}),
           facts: facts
         }}
      end
    else
      _unavailable -> :none
    end
  rescue
    _exception -> :none
  catch
    :exit, _reason -> :none
  end

  defp retained_subject(
         %{knowledge_scope: "person", scope_owner: %{"kind" => "person", "id" => id}},
         _project
       )
       when is_binary(id) and id != "", do: {:person, id}

  defp retained_subject(_item, project), do: {:project, project.id}

  @doc "Resolve and retrieve project knowledge inside one exact active project."
  @spec ground(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, %{status: status(), entities: [map()], facts: [map()]}} | {:error, term()}
  def ground(project_id, question, opts \\ []) do
    alias_limit = bounded_limit(opts[:alias_limit], @alias_limit)
    assertion_limit = bounded_limit(opts[:assertion_limit], @assertion_limit)

    with {:ok, project} <- fetch_active_project(project_id) do
      case load_aliases(project.id, alias_limit) do
        {:ok, aliases} ->
          resolve_grounding(project, aliases, normalize_display(question), assertion_limit)

        {:error, :incomplete_alias_projection} ->
          {:ok, empty_result(:incomplete)}
      end
    end
  end

  defp resolve_grounding(_project, _aliases, "", _assertion_limit),
    do: {:ok, empty_result(:unknown)}

  defp resolve_grounding(project, aliases, question, assertion_limit) do
    matches = Enum.flat_map(aliases, &alias_matches(question, &1))

    case classify_matches(matches) do
      {:ok, []} ->
        {:ok, empty_result(:unknown)}

      {:error, :ambiguous} ->
        {:ok, empty_result(:ambiguous)}

      {:ok, entities} ->
        facts = load_grounded_assertions(project.id, entities, assertion_limit)
        {:ok, %{status: :resolved, entities: entities, facts: facts}}
    end
  end

  defp load_aliases(project_id, limit) do
    aliases =
      from(a in ProjectKnowledgeAlias,
        where: a.project_id == ^project_id,
        order_by: [asc: a.normalized_alias, asc: a.id],
        limit: ^(limit + 1)
      )
      |> Repo.all()

    if length(aliases) > limit, do: {:error, :incomplete_alias_projection}, else: {:ok, aliases}
  end

  defp classify_matches(matches) do
    by_alias =
      Enum.group_by(matches, & &1.alias.normalized_alias, &entity_key(&1.alias))

    if Enum.any?(by_alias, fn {_alias, keys} -> length(Enum.uniq(keys)) > 1 end) or
         overlapping_entities?(matches) do
      {:error, :ambiguous}
    else
      entities =
        matches
        |> Enum.uniq_by(&entity_key(&1.alias))
        |> Enum.map(&entity_view(&1.alias))
        |> Enum.sort_by(&{&1.kind, &1.id})

      {:ok, entities}
    end
  end

  defp load_grounded_assertions(project_id, entities, limit) do
    user_ids = for %{kind: :person, id: id} <- entities, do: id
    project_ids = for %{kind: :project, id: id} <- entities, do: id

    from(a in ProjectKnowledgeAssertion,
      as: :assertion,
      where: a.project_id == ^project_id,
      where:
        exists(
          from(s in ProjectKnowledgeAssertionSubject,
            where:
              s.assertion_id == parent_as(:assertion).id and
                (s.user_id in ^user_ids or s.target_project_id in ^project_ids),
            select: 1
          )
        ),
      where:
        not exists(
          from(s in ProjectKnowledgeAssertionSubject,
            where:
              s.assertion_id == parent_as(:assertion).id and
                not ((not is_nil(s.user_id) and s.user_id in ^user_ids) or
                       (not is_nil(s.target_project_id) and
                          s.target_project_id in ^project_ids)),
            select: 1
          )
        ),
      order_by: [desc: a.observed_at, desc: a.id],
      limit: ^limit,
      preload: [:subjects]
    )
    |> Repo.all()
    |> Enum.map(&assertion_view/1)
  end

  defp assertion_view(assertion) do
    %{
      id: assertion.id,
      kind: String.to_existing_atom(assertion.kind),
      content: assertion.content,
      source_refs: [%{type: assertion.source_type, ref: assertion.source_ref}],
      about: assertion.subjects |> Enum.map(&subject_key/1) |> Enum.sort()
    }
  end

  defp entity_view(%ProjectKnowledgeAlias{} = alias_record) do
    {kind, id} = entity_key(alias_record)
    %{kind: kind, id: id, matched_alias: alias_record.alias}
  end

  defp entity_key(%{entity_kind: "person", user_id: id}), do: {:person, id}
  defp entity_key(%{entity_kind: "project", target_project_id: id}), do: {:project, id}
  defp subject_key(%{user_id: id}) when not is_nil(id), do: {:person, id}
  defp subject_key(%{target_project_id: id}), do: {:project, id}

  defp list_assertions(project_id, limit) do
    rows =
      from(a in ProjectKnowledgeAssertion,
        where: a.project_id == ^project_id,
        order_by: [desc: a.observed_at, desc: a.id],
        limit: ^(limit + 1),
        preload: [subjects: [:user, :target_project]]
      )
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) <= limit}
  end

  defp list_display_aliases(project_id, assertions) do
    keys =
      assertions
      |> Enum.flat_map(&Enum.map(&1.subjects, fn subject -> subject_key(subject) end))
      |> Enum.uniq()

    user_ids = for {:person, id} <- keys, do: id
    project_ids = for {:project, id} <- keys, do: id

    rows =
      from(a in ProjectKnowledgeAlias,
        where:
          a.project_id == ^project_id and
            (a.user_id in ^user_ids or a.target_project_id in ^project_ids),
        order_by: [asc: a.normalized_alias, asc: a.id],
        limit: ^(@alias_limit + 1)
      )
      |> Repo.all()

    aliases =
      rows
      |> Enum.take(@alias_limit)
      |> Enum.group_by(&entity_key/1, & &1.alias)
      |> Map.new(fn {key, values} -> {key, Enum.uniq(values)} end)

    {aliases, length(rows) <= @alias_limit}
  end

  defp list_members(project) do
    {:ok, %{members: memberships, truncated: truncated?}} =
      Memberships.list_project_members_bounded(project.id, @member_limit)

    {Enum.map(memberships, &member_list_view(project, &1)), not truncated?}
  end

  defp member_list_view(project, %{user: %User{} = user} = membership) do
    %{
      id: user.id,
      kind: :person,
      name: first_display_value([user.name, user.email, user.id]),
      role: membership.role,
      source: %{
        type: "product_directory",
        ref: "bft://projects/#{project.id}/members/#{user.id}"
      }
    }
  end

  defp first_display_value(values) do
    Enum.find_value(values, "", fn value ->
      case normalize_display(value) do
        "" -> nil
        normalized -> normalized
      end
    end)
  end

  defp list_usage(agent, assertions, opts) do
    impl = Client.impl()
    assertion_ids = Enum.map(assertions, & &1.id)

    if assertion_ids == [] do
      {:ok,
       %{
         "uses" => [],
         "complete" => true,
         "history_truncated" => false,
         "sessions_scanned" => 0
       }}
    else
      list_usage_from_runtime(impl, agent, assertion_ids, opts)
    end
  end

  defp list_usage_from_runtime(impl, agent, assertion_ids, opts) do
    if Code.ensure_loaded?(impl) and function_exported?(impl, :list_project_knowledge_uses, 2) do
      impl.list_project_knowledge_uses(
        agent.salix_agent_id,
        assertion_ids: assertion_ids,
        limit: min_bounded(opts[:usage_limit], @usage_limit, @usage_limit),
        session_limit:
          min_bounded(opts[:usage_session_limit], @usage_session_limit, @usage_session_limit)
      )
    else
      {:error, :unavailable}
    end
  end

  defp list_retained_context(agent, project, opts) do
    impl = Client.impl()

    if Code.ensure_loaded?(impl) and
         function_exported?(impl, :triage_knowledge_context, 4) and
         is_binary(project.salix_group_id) and project.salix_group_id != "" do
      impl.triage_knowledge_context(
        project.id,
        project.salix_group_id,
        agent.id,
        limit:
          min_bounded(
            opts[:retained_context_limit],
            @retained_context_limit,
            @retained_context_max_limit
          )
      )
      |> normalize_retained_context()
    else
      {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp normalize_retained_context({:ok, %{items: items, complete: complete}})
       when is_list(items) and is_boolean(complete) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, normalized} ->
      case retained_context_view(item) do
        {:ok, view} -> {:cont, {:ok, [view | normalized]}}
        :error -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, %{items: Enum.reverse(normalized), complete: complete}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_retained_context({:error, reason}), do: {:error, reason}
  defp normalize_retained_context(_invalid), do: {:error, :invalid_response}

  defp retained_context_view(
         %{
           context_ref: context_ref,
           kind: source_kind,
           state: :active,
           subject: subject,
           value: content,
           confidence: confidence,
           source_count: source_count,
           updated_at_ms: updated_at_ms
         } = item
       )
       when is_binary(context_ref) and context_ref != "" and
              source_kind in ["project_fact", "decision", "follow_up"] and
              is_binary(subject) and subject != "" and is_binary(content) and content != "" and
              confidence in [nil, "explicit", "inferred"] and is_integer(source_count) and
              source_count >= 0 and is_integer(updated_at_ms) and updated_at_ms >= 0 do
    next_check_at_ms = item[:next_check_at_ms]

    if is_nil(next_check_at_ms) or
         (is_integer(next_check_at_ms) and next_check_at_ms >= 0) do
      kind = if source_kind == "decision", do: :decision, else: :context

      {:ok,
       %{
         id: context_ref,
         kind: kind,
         source_kind: retained_context_source_kind(source_kind),
         name: subject,
         content: content,
         confidence: confidence,
         knowledge_scope: item[:knowledge_scope],
         scope_owner: item[:scope_owner],
         source_attribution: item[:source_attribution] || [],
         source_count: source_count,
         source: %{type: "triage_context", ref: item[:source_ref] || context_ref},
         next_check_at_ms: next_check_at_ms,
         updated_at_ms: updated_at_ms
       }}
    else
      :error
    end
  end

  defp retained_context_view(_item), do: :error

  defp retained_context_source_kind("project_fact"), do: :project_fact
  defp retained_context_source_kind("decision"), do: :decision
  defp retained_context_source_kind("follow_up"), do: :follow_up

  defp retained_context_items({:ok, %{items: items}}), do: items
  defp retained_context_items(_retained_context), do: []

  defp retained_context_status({:ok, _result}), do: :available
  defp retained_context_status({:error, reason}), do: {:unavailable, reason}

  defp retained_context_complete?({:ok, %{complete: complete}}), do: complete
  defp retained_context_complete?(_retained_context), do: false

  defp index_uses({:ok, %{"uses" => uses}}) when is_list(uses) do
    Enum.reduce(uses, %{}, fn use, acc ->
      use
      |> Map.get("assertions", [])
      |> Enum.reduce(acc, fn assertion, indexed ->
        case assertion["id"] do
          id when is_binary(id) ->
            Map.update(indexed, id, [usage_view(use)], &[usage_view(use) | &1])

          _invalid ->
            indexed
        end
      end)
    end)
  end

  defp index_uses(_usage), do: %{}

  defp usage_view(use) do
    Map.take(use, [
      "session_id",
      "retrieval_id",
      "used_at",
      "assistant_message_id",
      "assistant_excerpt"
    ])
  end

  defp assertion_list_view(assertion, aliases, uses_by_assertion) do
    %{
      id: assertion.id,
      kind: String.to_existing_atom(assertion.kind),
      content: assertion.content,
      observed_at: assertion.observed_at,
      created_at: assertion.created_at,
      source: %{type: assertion.source_type, ref: assertion.source_ref},
      subjects: Enum.map(assertion.subjects, &subject_list_view(&1, aliases)),
      uses: Map.get(uses_by_assertion, assertion.id, []) |> Enum.sort_by(& &1["used_at"], :desc)
    }
  end

  defp subject_list_view(%{user_id: id, user: %User{} = user}, aliases) when not is_nil(id) do
    %{
      kind: :person,
      id: id,
      name: user.name || user.email || id,
      aliases: Map.get(aliases, {:person, id}, [])
    }
  end

  defp subject_list_view(%{target_project_id: id, target_project: %Project{} = project}, aliases) do
    %{
      kind: :project,
      id: id,
      name: project.name,
      aliases: Map.get(aliases, {:project, id}, [])
    }
  end

  defp usage_status({:ok, %{"uses" => uses}}) when is_list(uses), do: :available
  defp usage_status({:error, reason}), do: {:unavailable, reason}
  defp usage_status(_invalid), do: {:unavailable, :invalid_response}

  defp usage_complete?({:ok, %{"complete" => complete}}), do: complete == true
  defp usage_complete?(_usage), do: false

  defp fetch_active_agent(agent_id) do
    case BridgeForTeams.Agents.get_agent(agent_id) do
      {:ok, %Agent{} = agent} ->
        if Agent.active?(agent), do: {:ok, agent}, else: {:error, :agent_inactive}

      {:error, :not_found} ->
        {:error, :agent_not_found}

      error ->
        error
    end
  end

  defp fetch_active_project(project_id) do
    case Repo.get(Project, project_id) do
      %Project{status: "active", archived_at: nil} = project -> {:ok, project}
      %Project{} -> {:error, :project_inactive}
      nil -> {:error, :project_not_found}
    end
  end

  defp validate_entity_scopes(project, entities) do
    entities
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn entity, :ok ->
      case validate_entity_scope(project, entity) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_entity_scope(%Project{org_id: org_id}, {:person, user_id}) do
    if Repo.exists?(
         from(m in OrgMembership, where: m.org_id == ^org_id and m.user_id == ^user_id)
       ) do
      :ok
    else
      {:error, :person_outside_project_org}
    end
  end

  defp validate_entity_scope(%Project{org_id: org_id}, {:project, target_project_id}) do
    if Repo.exists?(
         from(p in Project,
           where: p.id == ^target_project_id and p.org_id == ^org_id and is_nil(p.archived_at)
         )
       ) do
      :ok
    else
      {:error, :project_outside_org}
    end
  end

  defp validate_entity_scope(_project, _entity), do: {:error, :invalid_entity}

  defp validate_source(source) when is_map(source) do
    type = source[:type] || source["type"]
    ref = normalize_display(source[:ref] || source["ref"])

    if to_string(type) in @source_types and ref != "" do
      {:ok, to_string(type), ref}
    else
      {:error, :invalid_source}
    end
  end

  defp validate_source(_source), do: {:error, :invalid_source}

  defp source_time(source) do
    case source[:observed_at] || source["observed_at"] do
      %DateTime{} = value -> value
      _ -> DateTime.utc_now()
    end
  end

  defp entity_kind({:person, _id}), do: "person"
  defp entity_kind({:project, _id}), do: "project"

  defp put_entity(attrs, {:person, user_id}), do: Map.put(attrs, :user_id, user_id)

  defp put_entity(attrs, {:project, project_id}),
    do: Map.put(attrs, :target_project_id, project_id)

  defp normalize_display(value) when is_binary(value), do: String.trim(value)
  defp normalize_display(_value), do: ""
  defp normalize_alias(value), do: value |> normalize_display() |> String.downcase()

  defp alias_matches(question, alias_record) do
    alias_value = alias_record.normalized_alias
    question = String.downcase(question)

    pattern =
      if Regex.match?(~r/\p{Han}/u, alias_value) do
        Regex.escape(alias_value)
      else
        "(?<![\\p{L}\\p{N}_])" <> Regex.escape(alias_value) <> "(?![\\p{L}\\p{N}_])"
      end

    pattern
    |> Regex.compile!("u")
    |> Regex.scan(question, return: :index)
    |> Enum.map(fn [{start, length}] ->
      %{alias: alias_record, start: start, length: length}
    end)
  end

  defp overlapping_entities?(matches) do
    matches
    |> Enum.with_index()
    |> Enum.any?(fn {left, index} ->
      matches
      |> Enum.drop(index + 1)
      |> Enum.any?(fn right ->
        entity_key(left.alias) != entity_key(right.alias) and overlap?(left, right)
      end)
    end)
  end

  defp overlap?(left, right) do
    left.start < right.start + right.length and right.start < left.start + left.length
  end

  defp bounded_limit(value, _default) when is_integer(value) and value in 1..500, do: value
  defp bounded_limit(_value, default), do: default

  defp min_bounded(value, _default, max) when is_integer(value) and value > 0,
    do: min(value, max)

  defp min_bounded(_value, default, _max), do: default

  defp empty_result(status), do: %{status: status, entities: [], facts: []}
end
