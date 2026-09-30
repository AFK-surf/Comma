defmodule SalixAgent.RoundConfig do
  require SalixAgent.InternalSession

  @moduledoc """
  Round and runtime session configuration for one agent.

  These are pure reads over the agent control record, provider resolution,
  plugin and skill projections and tool disclosure. They hold no process
  state, so every caller builds them in its own process.
  """

  @doc false
  def build_runtime_session_config(agent_id, role, attrs)
      when is_binary(agent_id) and is_map(attrs) do
    with {:ok, control_record} <- SalixAgent.AgentRuntimeConfig.resolve(agent_id) do
      build_runtime_session_config_from_runtime(agent_id, role, attrs, control_record)
    end
  end

  @doc false
  def build_round_config(agent_id, role, session_context)
      when is_binary(agent_id) and is_binary(role) and is_map(session_context) do
    SystemsObservability.Trace.with_span(
      :salix_round_config_build,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> traced_build_round_config(agent_id, role, session_context) end
    )
  end

  defp traced_build_round_config(agent_id, role, session_context) do
    with {:ok, agent_record} <- SalixAgent.Control.get_record(agent_id),
         :ok <-
           if(SalixAgent.Control.archived?(agent_record),
             do: {:error, {:bad_request, "agent is archived"}},
             else: :ok
           ),
         runtime_config = SalixAgent.AgentRuntimeConfig.from_control(agent_record),
         [llm_result, session_config_result] <-
           run_parallel([
             fn -> SalixAgent.LlmResolver.resolve_runtime(agent_id, agent_record) end,
             fn ->
               build_runtime_session_config_from_runtime(
                 agent_id,
                 role,
                 %{
                   platform: Map.get(session_context, :platform),
                   session_context: session_context
                 },
                 runtime_config
               )
             end
           ]),
         {:ok, llm_opts} <- llm_result,
         {:ok, session_config} <- session_config_result do
      {:ok, %{llm_opts: llm_opts, session_config: session_config}}
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  def build_round_snapshot(agent_id, session_context \\ %{}) do
    SystemsObservability.Trace.with_span(
      :salix_round_config_build,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn ->
        with {:ok, record} <- SalixAgent.Control.get_record(agent_id),
             false <- SalixAgent.Control.archived?(record),
             runtime = SalixAgent.AgentRuntimeConfig.from_control(record),
             [llm, plugin, skills] <-
               run_parallel([
                 fn -> SalixAgent.LlmResolver.resolve_runtime(agent_id, record) end,
                 fn -> runtime_plugin_projection(runtime) end,
                 fn ->
                   SalixAgent.SkillProjection.prepare_materialization(%{
                     agent_id: agent_id,
                     tenant_id: runtime[:tenant_id],
                     group_id: runtime[:group_id]
                   })
                 end
               ]),
             {:ok, llm_opts} <- llm,
             {:ok, plugin_projection} <- plugin,
             {:ok, skill_materialization} <- skills do
          snapshot = %{
            provider_record: record,
            role: record["role"],
            runtime_config: runtime,
            llm_opts: llm_opts,
            plugin_projection: plugin_projection,
            skill_materialization: skill_materialization
          }

          # A reusable catalog never carries a previous activation's grants.
          context = Map.take(session_context, [:platform])

          with {:ok, config} <-
                 build_runtime_session_config_from_runtime(
                   agent_id,
                   snapshot.role,
                   %{
                     platform: context[:platform],
                     session_context: context,
                     round_snapshot: snapshot,
                     retain_round_inputs: true
                   },
                   runtime
                 ) do
            {inputs, config} = Map.pop(config, :round_inputs)
            {:ok, Map.merge(snapshot, %{session_config: config, config_inputs: inputs})}
          end
        else
          true -> {:error, {:bad_request, "agent is archived"}}
          {:error, _} = error -> error
        end
      end
    )
  end

  @doc false
  def prefetch_round_refresh(agent_id, snapshot, context) do
    key = {:round_refresh, agent_id, snapshot, Map.take(context, [:platform])}
    seed = SalixStore.ReadScope.capture() || %{}

    SalixStore.ReadScope.prefetch(key, fn ->
      SalixStore.ReadScope.run(seed, fn ->
        result = refresh_round_snapshot(agent_id, snapshot, context)
        {:ok, {result, SalixStore.ReadScope.capture()}}
      end)
    end)
  end

  @doc false
  def join_round_refresh(agent_id, snapshot, context) do
    key = {:round_refresh, agent_id, snapshot, Map.take(context, [:platform])}

    {:ok, {result, reads}} =
      SalixStore.ReadScope.fetch(key, fn ->
        {:ok, {refresh_round_snapshot(agent_id, snapshot, context), nil}}
      end)

    SalixStore.ReadScope.merge(reads)
    result
  end

  @doc false
  def refresh_round_snapshot(agent_id, snapshot, session_context) do
    # Resolve the current provider in parallel with its Agent binding. If the
    # binding changed, discard that preparation and resolve the current record.
    previous_record = snapshot[:provider_record]

    [control, llm, catalog] =
      run_parallel([
        fn -> SalixAgent.Control.get_record(agent_id) end,
        fn ->
          if is_map(previous_record),
            do: SalixAgent.LlmResolver.resolve_runtime(agent_id, previous_record),
            else: {:error, :missing_provider_record}
        end,
        fn -> round_catalog_versions(agent_id, snapshot) end
      ])

    with {:ok, record} <- control,
         false <- SalixAgent.Control.archived?(record),
         runtime = SalixAgent.AgentRuntimeConfig.from_control(record),
         {:ok, llm_opts} <-
           if(record == previous_record,
             do: llm,
             else: SalixAgent.LlmResolver.resolve_runtime(agent_id, record)
           ),
         {:ok, plugins, skills} <- catalog do
      if runtime == snapshot.runtime_config and plugins == snapshot.plugin_projection and
           skills == snapshot.session_config.skill_projection_revision do
        {:ok, %{snapshot | llm_opts: llm_opts} |> Map.put(:provider_record, record)}
      else
        build_round_snapshot(agent_id, session_context)
      end
    else
      true -> {:error, {:bad_request, "agent is archived"}}
      {:error, _} = error -> error
    end
  end

  defp round_catalog_versions(agent_id, snapshot) do
    runtime = snapshot.runtime_config

    with {:ok, plugins} <- runtime_plugin_projection(runtime),
         {:ok, skills} <-
           SalixAgent.SkillProjection.revision(%{
             agent_id: agent_id,
             tenant_id: runtime[:tenant_id],
             group_id: runtime[:group_id],
             skill_projection_revision: snapshot.session_config.skill_projection_revision,
             plugin_projection: plugins,
             plugin_projection_revision: plugins && plugins["revision"]
           }) do
      {:ok, plugins, skills}
    end
  end

  @doc false
  def materialize_round_snapshot(agent_id, snapshot, session_context) do
    SystemsObservability.Trace.with_span(
      :salix_round_materialize,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> do_materialize_round_snapshot(agent_id, snapshot, session_context) end
    )
  end

  defp do_materialize_round_snapshot(agent_id, snapshot, session_context) do
    # Task-scoped IM grants must be derived from this activation, not the
    # catalog's refresh activation. Dispatch still validates current authority.
    if snapshot.role == "worker" and
         List.wrap(session_context[:trusted_origins]) != [] do
      with {:ok, config} <-
             build_runtime_session_config_from_runtime(
               agent_id,
               snapshot.role,
               %{
                 platform: session_context[:platform],
                 session_context: session_context,
                 round_snapshot: snapshot
               },
               snapshot.runtime_config
             ) do
        {:ok, %{llm_opts: snapshot.llm_opts, session_config: config}}
      end
    else
      {:ok,
       %{
         llm_opts: snapshot.llm_opts,
         session_config: Map.put(snapshot.session_config, :platform, session_context[:platform])
       }}
    end
  end

  # The disclosure context seeded from a session is plain data: its identity
  # and platform. The session itself never crosses into the disclosure pipeline.
  @doc """
  The data a round configuration reads from the session: its identity and
  platform, the activation's admitted source ids, and the current turn's
  trusted origins. Tool disclosure resolves Task-delegated grants from the
  last two, so every caller that seeds a configuration from a session handle
  projects it through here.
  """
  @spec round_session_context(SalixAgent.InternalSession.t() | map() | term()) :: map()
  def round_session_context(session) when SalixAgent.InternalSession.is_session(session) do
    source_message_ids = SalixAgent.InternalSession.current_source_ids(session)

    %{
      session_id: SalixAgent.InternalSession.session_id(session),
      platform: SalixAgent.InternalSession.get(session, :platform),
      source_message_ids: source_message_ids,
      trusted_origins:
        SalixAgent.InternalSession.current_turn_trusted_origins(session, source_message_ids)
    }
  end

  def round_session_context(context) when is_map(context), do: context
  def round_session_context(_context), do: %{}

  defp build_runtime_session_config_from_runtime(agent_id, role, attrs, runtime_config)
       when is_binary(agent_id) and is_map(attrs) and is_map(runtime_config) do
    platform = attrs["platform"] || attrs[:platform]
    session_context = round_session_context(attrs["session_context"] || attrs[:session_context])

    runtime_kind =
      normalize_runtime_kind(attrs["runtime_kind"] || attrs[:runtime_kind] || :internal)

    recommendation_policy =
      if runtime_config[:purpose] == "comma_recommendation", do: :restricted, else: :ordinary

    base_disclosure_context =
      session_context
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:tenant_id, runtime_config[:tenant_id])
      |> Map.put(:group_id, runtime_config[:group_id])
      |> Map.put(:disabled_tools, runtime_config[:disabled_tools] || [])
      |> Map.put(:inspector_policy, runtime_config[:inspector_policy])
      |> Map.put(:recommendation_policy, recommendation_policy)

    im_disclosure_context =
      base_disclosure_context
      |> Map.put(:role, role)
      |> Map.put(:runtime_kind, runtime_kind)

    cached = get_in(attrs, [:round_snapshot, :config_inputs])

    with [
           plugin_result,
           skill_materialization_result,
           memory_enabled_result,
           im_entries_result,
           mcp_entries_result,
           mcp_state_result
         ] <-
           run_parallel([
             fn ->
               case attrs[:round_snapshot] do
                 nil -> runtime_plugin_projection(runtime_config)
                 snapshot -> {:ok, snapshot.plugin_projection}
               end
             end,
             fn ->
               case attrs[:round_snapshot] do
                 nil ->
                   SalixAgent.SkillProjection.prepare_materialization(base_disclosure_context)

                 snapshot ->
                   {:ok, snapshot.skill_materialization}
               end
             end,
             fn ->
               {:ok,
                if(cached,
                  do: cached.memory_enabled,
                  else: SalixAgent.MemoryConsultation.enabled?(base_disclosure_context)
                )}
             end,
             fn ->
               {:ok, SalixAgent.Tools.ImRouter.dynamic_disclosure_entries(im_disclosure_context)}
             end,
             fn ->
               {:ok,
                if(cached,
                  do: cached.mcp_entries,
                  else: SalixAgent.Tools.MCP.dynamic_disclosure_entries(base_disclosure_context)
                )}
             end,
             fn ->
               {:ok,
                if(cached,
                  do: cached.mcp_state,
                  else: SalixAgent.Tools.MCP.provider_state(base_disclosure_context)
                )}
             end
           ]),
         {:ok, plugin_projection} <- plugin_result,
         {:ok, skill_materialization} <- skill_materialization_result,
         {:ok, memory_ask_worker_enabled} <- memory_enabled_result,
         {:ok, im_entries} <- im_entries_result,
         {:ok, mcp_entries} <- mcp_entries_result,
         {:ok, mcp_provider_state} <- mcp_state_result do
      disclosure_context =
        base_disclosure_context
        |> Map.put(:plugin_projection, plugin_projection)
        |> Map.put(
          :plugin_projection_revision,
          plugin_projection && plugin_projection["revision"]
        )

      with {:ok, skill_projection} <-
             SalixAgent.SkillProjection.finish_materialization(
               skill_materialization,
               disclosure_context
             ) do
        disclosure_context =
          disclosure_context
          |> Map.put(:skill_projection_revision, skill_projection.revision)
          |> Map.put(:memory_ask_worker_enabled, memory_ask_worker_enabled)

        disclosure =
          SalixAgent.ToolDisclosure.materialize_prepared(
            role,
            runtime_kind,
            disclosure_context,
            im_entries,
            mcp_entries
          )
          |> Map.put("recommendation_policy", Atom.to_string(recommendation_policy))
          |> Map.put("inspector_policy", runtime_config[:inspector_policy])

        config = %{
          platform: platform,
          role: role,
          tenant_id: runtime_config[:tenant_id],
          group_id: runtime_config[:group_id],
          system_prompt:
            SalixAgent.ToolPolicy.session_prompt(
              role,
              runtime_config.prompts,
              agent_id,
              runtime_kind,
              disclosure,
              disclosure_context
            ),
          tool_disclosure: disclosure,
          tool_disclosure_revision: disclosure["revision"],
          plugin_projection: plugin_projection,
          plugin_projection_revision: plugin_projection && plugin_projection["revision"],
          skill_projection_revision: skill_projection.revision,
          miniskill_projection: skill_projection,
          mcp_provider_state: mcp_provider_state,
          tool_specs: SalixAgent.ToolPolicy.specs_for(role, disclosure),
          external_tool_specs: SalixAgent.ToolPolicy.external_specs_for(disclosure)
        }

        inputs = %{
          memory_enabled: memory_ask_worker_enabled,
          mcp_entries: mcp_entries,
          mcp_state: mcp_provider_state
        }

        {:ok,
         if(attrs[:retain_round_inputs], do: Map.put(config, :round_inputs, inputs), else: config)}
      end
    end
  end

  # Branches start from the control records the caller already holds, and
  # the caller learns what the branches read, so a later step in the same
  # unit of work (a Group policy gate after the catalog branches) is served
  # without another round trip.
  defp run_parallel(funs) do
    observability_context = SystemsObservability.Context.capture()
    read_scope = SalixStore.ReadScope.capture()

    funs
    |> Task.async_stream(
      fn fun ->
        SystemsObservability.Context.run(observability_context, fn ->
          SalixStore.ReadScope.run(read_scope, fn ->
            result = fun.()
            {result, SalixStore.ReadScope.capture()}
          end)
        end)
      end,
      ordered: true,
      max_concurrency: length(funs),
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {result, branch_scope}} ->
        SalixStore.ReadScope.merge(branch_scope)
        result

      {:exit, reason} ->
        {:error, {:parallel_runtime_read_failed, reason}}
    end)
  end

  defp normalize_runtime_kind(kind) when kind in [:external, "external"],
    do: :external

  defp normalize_runtime_kind(kind) when kind in [:script, "script"],
    do: :script

  defp normalize_runtime_kind(_kind), do: :internal

  defp runtime_plugin_projection(runtime_config) do
    tenant_id = runtime_config[:tenant_id]
    group_id = runtime_config[:group_id]

    case SalixAgent.PluginStore.runtime_projection(%{
           "tenant_id" => tenant_id,
           "group_id" => group_id
         }) do
      {:ok, projection} ->
        {:ok, projection}

      {:error, reason} ->
        {:error, {:plugin_projection, reason}}
    end
  end
end
