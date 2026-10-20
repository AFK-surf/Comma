defmodule SalixAgent.LlmConfigTest do
  @moduledoc """
  Per-agent LLM config is resolved live from the Agent's model
  (`SalixAgent.AgentModel`). The runtime session receives the resolved
  per-call opts, but `SalixAgent.State` does not own a journaled provider
  snapshot.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.{Agent, Keys}
  alias SalixAgent.{ModelChoice, State}

  @session_id "ses1_0000000000000000603"

  defmodule AgentModelResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_llm_for_agent(agent_id)
  end

  # An impl capturing the opts it was called with (registered via :persistent_term).
  defmodule CapturingLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools) do
      record([])
      {:final, "no-opts"}
    end

    @impl true
    def complete(_messages, _tools, llm_opts) do
      record(llm_opts)
      {:final, "with-opts"}
    end

    defp record(opts) do
      pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid})
      SystemsRuntime.Proc.send(pid, {:llm_called, opts})
      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    prev_llm_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, CapturingLLM)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, AgentModelResolver)
    SystemsRuntime.PersistentTerm.put({CapturingLLM, :test_pid}, SystemsRuntime.Proc.self())
    start_supervised!(SalixStore.S3.Fake)

    agent = SalixAgent.TestSupport.new_agent_id()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      SystemsRuntime.put_env(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :llm_resolver, prev_llm_resolver)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    {:ok, agent: agent}
  end

  @tag :session_optimization
  test "warm config reuse resolves changed credentials and fails on an unresolvable model", %{
    agent: agent
  } do
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, snapshot} = SalixAgent.RoundConfig.build_round_snapshot(agent)
    assert {:ok, warm} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, snapshot, %{})
    assert warm.session_config == snapshot.session_config

    # The platform replaces the Profile that serves the worker tier.
    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "https://replacement.example.test/v1",
      "mock"
    )

    assert {:ok, refreshed} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, warm, %{})
    assert opt(refreshed.llm_opts, "base_url") == "https://replacement.example.test/v1"
    assert refreshed.session_config == snapshot.session_config

    # A failed live lookup must not release the cached credentials.
    assert {:ok, _} =
             SalixStore.CasRecord.update(
               Keys.ctl_agent(agent),
               &Map.put(&1, "model", %{"kind" => "catalog", "model" => "no-such-model"})
             )

    assert {:error, _} = SalixAgent.RoundConfig.refresh_round_snapshot(agent, refreshed, %{})
  end

  test "the platform model config reaches the impl as per-call opts", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, _} =
      SalixAgent.deliver(a, %{content: "hi", session_id: @session_id},
        source_message_id: "llm-config-platform:#{a}"
      )

    assert_receive {:llm_called, opts}
    assert opt(opts, "model") == "mock"
    assert opt(opts, "base_url") == SalixAgent.TestSupport.platform_model_base_url()
    assert opt(opts, "credential_scope") == "platform"

    # The runtime state does not own provider config; a fresh replay remains
    # free of a stale llm snapshot.
    {:ok, state} = Agent.read_state(a, State)
    refute Map.has_key?(state, :llm)
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp opt(opts, key) when is_map(opts), do: opts[key] || opts[String.to_atom(key)]

  defp opt(opts, key) when is_list(opts) do
    Keyword.get(opts, String.to_atom(key)) ||
      case List.keyfind(opts, key, 0) do
        {^key, value} -> value
        _ -> nil
      end
  end

  defp opt(_opts, _key), do: nil
end
