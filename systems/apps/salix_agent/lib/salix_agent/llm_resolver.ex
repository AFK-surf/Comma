defmodule SalixAgent.LlmResolver do
  require SalixAgent.InternalSession

  @moduledoc """
  Live per-agent provider resolution seam (willow's
  `ResolveAgentProviderConfig`): an agent's model (its model choice, else the
  platform model of its role, `SalixAgent.AgentModel`) is resolved at
  activation time, never snapshotted into the agent journal, so a changed
  choice or platform model applies on the agent's next round. The control
  plane wires itself at startup via
  `Application.put_env(:salix_agent, :llm_resolver, Salix.Bindings.AgentLlmResolver)`
  (same seam pattern as `:notifier` / `:placement`).

  `{:ok, nil}` means no config is available through the configured resolver
  (no control record). An error return means the agent's model can't be
  resolved right now; the round must fail rather than silently call the wrong
  provider.
  """

  @callback resolve(agent_id :: String.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback resolve_record(agent_record :: map()) :: {:ok, map() | nil} | {:error, term()}
  @optional_callbacks resolve_record: 1

  @triage_effort_floor_order ~w(high medium)
  @effort_rank %{
    nil => 0,
    "" => 0,
    "none" => 0,
    "minimal" => 1,
    "low" => 2,
    "medium" => 3,
    "high" => 4,
    "xhigh" => 5,
    "max" => 6,
    "ultra" => 7
  }

  @spec resolve(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def resolve(agent_id) do
    case SystemsRuntime.get_env(:salix_agent, :llm_resolver) do
      nil -> {:ok, nil}
      mod -> mod.resolve(agent_id)
    end
  end

  @doc """
  The LLM options for one internal Session: its own model choice
  (`SalixAgent.ModelChoice`) when it has one, otherwise the Agent's.
  """
  @spec resolve_session(String.t(), term()) :: {:ok, term()} | {:error, term()}
  def resolve_session(agent_id, session) do
    result =
      case session_model(session) do
        nil ->
          resolve_runtime(agent_id)

        model ->
          with {:ok, record} <- SalixAgent.Control.get_record(agent_id) do
            session_llm(model, record["tenant_id"])
          end
      end

    case result do
      {:ok, llm} -> {:ok, apply_triage_reasoning_floor(llm, session)}
      other -> other
    end
  end

  @doc """
  Raises `reasoning_effort` to the triage investigation floor when the session
  or round context is a triage investigation and the resolved catalog model
  supports a higher effort level.
  """
  @spec apply_triage_reasoning_floor(term(), term()) :: term()
  def apply_triage_reasoning_floor(llm_opts, session_or_context) when is_map(llm_opts) do
    with true <- triage_investigation?(session_or_context),
         model_id when is_binary(model_id) <-
           llm_opts["catalog_model"] || llm_opts[:catalog_model] || llm_opts["model"] ||
             llm_opts[:model],
         {:ok, %{"efforts" => [_ | _] = efforts}} <- SalixAgent.Models.get(model_id),
         floor when is_binary(floor) <- Enum.find(@triage_effort_floor_order, &(&1 in efforts)),
         current = llm_opts["reasoning_effort"] || llm_opts[:reasoning_effort],
         true <- Map.get(@effort_rank, current, 0) < Map.fetch!(@effort_rank, floor) do
      put_reasoning_effort(llm_opts, floor)
    else
      _ -> llm_opts
    end
  end

  def apply_triage_reasoning_floor(llm_opts, _session_or_context), do: llm_opts

  defp triage_investigation?(session) when SalixAgent.InternalSession.is_session(session) do
    source_ids = SalixAgent.InternalSession.current_source_ids(session)
    origins = SalixAgent.InternalSession.current_turn_trusted_origins(session, source_ids)
    Enum.any?(origins, &triage_origin?/1)
  end

  defp triage_investigation?(ctx) when is_map(ctx) do
    triage_origin?(ctx[:trusted_origin] || ctx["trusted_origin"]) or
      Enum.any?(List.wrap(ctx[:trusted_origins] || ctx["trusted_origins"]), &triage_origin?/1) or
      ctx[:triage_investigation] == true or
      ctx["triage_investigation"] == true
  end

  defp triage_investigation?(_other), do: false

  defp triage_origin?(origin),
    do: is_map(origin) and is_map(origin["triage_investigation"])

  defp put_reasoning_effort(llm_opts, floor) do
    if Map.has_key?(llm_opts, :reasoning_effort) or
         (map_size(llm_opts) > 0 and Enum.all?(Map.keys(llm_opts), &is_atom/1)) do
      Map.put(llm_opts, :reasoning_effort, floor)
    else
      Map.put(llm_opts, "reasoning_effort", floor)
    end
  end

  @doc "The LLM options of a Session model choice for `tenant_id`."
  @spec session_llm(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def session_llm(model, tenant_id) do
    case SalixAgent.ModelChoice.resolve_llm(model, tenant_id) do
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm_resolver, reason}}
    end
  end

  @doc "A Session's own model choice, or nil when it follows its Agent."
  @spec session_model(term()) :: map() | nil
  def session_model(session) when SalixAgent.InternalSession.is_session(session) do
    case SalixAgent.InternalSession.get(session, :model) do
      model when is_map(model) and map_size(model) > 0 -> model
      _none -> nil
    end
  end

  def session_model(_session), do: nil

  @spec resolve_runtime(String.t()) :: {:ok, term()} | {:error, term()}
  def resolve_runtime(agent_id) do
    case resolve(agent_id) do
      {:ok, nil} -> {:ok, []}
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm_resolver, reason}}
    end
  end

  @doc false
  @spec resolve_runtime(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def resolve_runtime(agent_id, agent_record) when is_binary(agent_id) and is_map(agent_record) do
    SalixStore.ReadScope.fetch({:agent_llm, agent_id, agent_record}, fn ->
      do_resolve_runtime(agent_id, agent_record)
    end)
  end

  defp do_resolve_runtime(agent_id, agent_record) do
    result =
      case SystemsRuntime.get_env(:salix_agent, :llm_resolver) do
        nil ->
          {:ok, nil}

        mod ->
          if SystemsRuntime.Proc.ensure_loaded?(mod) and
               function_exported?(mod, :resolve_record, 1) do
            mod.resolve_record(agent_record)
          else
            mod.resolve(agent_id)
          end
      end

    case result do
      {:ok, nil} -> {:ok, []}
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm_resolver, reason}}
    end
  end
end
