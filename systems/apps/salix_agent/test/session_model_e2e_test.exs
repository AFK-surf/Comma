defmodule SalixAgent.ModelChoiceE2ETest do
  @moduledoc """
  A Session's own model (`SalixAgent.ModelChoice`) through the Session actor:
  the delivery that creates the Session carries the choice, the Session stores
  it, and its rounds send that model instead of the Agent's.
  """
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AccountPool, InternalSession, InternalSessionStore}
  alias SalixStore.S3

  @chosen "ses1_0000000000000000981"
  @plain "ses1_0000000000000000982"

  defmodule CapturingLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools), do: record([])

    @impl true
    def complete(_messages, _tools, llm_opts), do: record(llm_opts)

    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: record([])

    @impl true
    def complete_stream(_messages, _tools, _on_delta, llm_opts), do: record(llm_opts)

    defp record(opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:llm_called, Map.new(opts)}
      )

      {:error, {:http, 400, "refused"}}
    end
  end

  defmodule Resolver do
    @moduledoc false
    def resolve(_agent_id), do: {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, :route})}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    settings = [
      {:salix_store, :s3_backend},
      {:salix_agent, :llm},
      {:salix_agent, :llm_resolver}
    ]

    previous = for {app, key} <- settings, do: {app, key, SystemsRuntime.fetch_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, CapturingLLM)
    SystemsRuntime.put_env(:salix_agent, :llm_resolver, Resolver)
    SystemsRuntime.PersistentTerm.put({CapturingLLM, :owner}, SystemsRuntime.Proc.self())

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant,
      group_id: group_id,
      role: "worker"
    })

    {:ok, _} =
      AccountPool.create(tenant, %{
        "credential_kind" => "provider_api_key",
        "source" => "openrouter",
        "api_key" => "sk-or-v1-e2e-0123456789abcdef"
      })

    # The Agent's own model, which a Session without a choice uses.
    {:ok, route} =
      AccountPool.resolve_config(
        %{
          "catalog_model" => "claude-haiku-4-5",
          "allow_paid" => true,
          "credential_scope" => "tenant"
        },
        tenant
      )

    SystemsRuntime.PersistentTerm.put({Resolver, :route}, route)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase({Resolver, :route})
      SystemsRuntime.PersistentTerm.erase({CapturingLLM, :owner})

      for {app, key, value} <- previous do
        case value do
          {:ok, value} -> SystemsRuntime.put_env(app, key, value)
          :error -> SystemsRuntime.delete_env(app, key)
        end
      end
    end)

    {:ok, agent: agent}
  end

  test "the delivery that creates a Session sets its model; another Session keeps the Agent's",
       %{agent: agent} do
    choice = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => true}

    assert {:ok, _} =
             SalixAgent.deliver(
               agent,
               %{content: "say hello", role: "user", session_id: @chosen, model: choice},
               source_message_id: "session-model-chosen"
             )

    settle_receive({:llm_called, chosen})
    assert chosen["model"] == "openai/gpt-5.5"

    assert {:ok, state} = InternalSessionStore.read(agent, @chosen)
    assert InternalSession.get(state, :model) == choice

    assert {:ok, _} =
             SalixAgent.deliver(
               agent,
               %{content: "say hello", role: "user", session_id: @plain},
               source_message_id: "session-model-plain"
             )

    settle_receive({:llm_called, plain})
    assert plain["model"] == "anthropic/claude-haiku-4.5"
  end
end
