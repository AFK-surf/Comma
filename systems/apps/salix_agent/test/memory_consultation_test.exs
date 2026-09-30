defmodule SalixAgent.MemoryConsultationTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSessionFleet, InternalSessionStore, MemoryConsultation}
  alias SalixAgent.InternalSession
  alias SalixAgent.Tools.Memory

  defmodule Source do
    @behaviour SalixAgent.MemoryConsultationSource

    @impl true
    def search_worker_sessions(group_id, keywords, conversation_refs, limit) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:consultation_discovery, group_id, keywords, conversation_refs, limit}
      )

      {:ok, Application.fetch_env!(:salix_agent, :memory_consultation_test_discovery)}
    end

    @impl true
    def consult_worker_session(group_id, target, question, request_id, opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:consultation_route, group_id, target, question, request_id}
      )

      SalixAgent.AgentActor.consult_worker_session(
        target.agent_id,
        target.session_id,
        question,
        request_id,
        opts
      )
    end
  end

  defmodule Resolver do
    def resolve(_agent_id), do: {:ok, %{"model" => "memory-test"}}
  end

  defmodule LLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete(messages, tools, %{})

    @impl true
    def complete(messages, tools, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:consultation_llm, messages, tools})
      {:final, "The worker remembers the deployment decision."}
    end
  end

  @session_id "ses1_0000000000000000971"

  setup do
    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      source: Application.get_env(:salix_agent, :memory_consultation_source_mod),
      llm: Application.get_env(:salix_agent, :llm),
      resolver: Application.get_env(:salix_agent, :llm_resolver)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :memory_consultation_source_mod, Source)
    Application.put_env(:salix_agent, :llm, LLM)
    Application.put_env(:salix_agent, :llm_resolver, Resolver)
    :persistent_term.put({Source, :test_pid}, self())
    :persistent_term.put({LLM, :test_pid}, self())

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_agent, :memory_consultation_source_mod, previous.source)
      restore_env(:salix_agent, :llm, previous.llm)
      restore_env(:salix_agent, :llm_resolver, previous.resolver)
      :persistent_term.erase({Source, :test_pid})
      :persistent_term.erase({LLM, :test_pid})
      SalixAgent.TestSupport.stop_all_agents()
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    worker_id = SalixStore.Ids.new_agent_id(group_id)
    router_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "router",
      "runtime_config" => %{"kind" => "internal"}
    })

    SalixAgent.TestSupport.create_control_agent!(worker_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    })

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "tenant_id" => tenant_id,
      "memory_ask_worker_enabled" => true
    })

    state =
      worker_id
      |> InternalSession.new(@session_id, %{"created_at" => 1})
      |> InternalSession.apply_events([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "role" => "user",
          "content" => "We chose the blue deployment.",
          "source_message_id" => "source-1",
          "created_at" => 2
        },
        %{
          "type" => "assistant",
          "message_id" => 2,
          "content" => "I will retain that decision.",
          "created_at" => 3
        }
      ])

    {:ok, pid} =
      InternalSessionFleet.ensure_started(worker_id, @session_id, process_on_init: false)

    :sys.replace_state(pid, fn actor_state ->
      :ok = InternalSessionStore.seed(worker_id, state)
      actor_state
    end)

    target = %{
      agent_id: worker_id,
      session_id: @session_id,
      participant_id: "ptp1_0000000000000000001",
      worker_role: "implementer",
      runtime_kind: "internal",
      rank_at: 10,
      conversation_ref: %{
        "conversation_id" => "conv1_0000000000000000001",
        "message_id" => "msg1_0000000000000000001",
        "title" => "Deployment",
        "snippet" => "blue deployment"
      }
    }

    Application.put_env(:salix_agent, :memory_consultation_test_discovery, %{
      targets: [target],
      truncated: false
    })

    {:ok, tenant_id: tenant_id, group_id: group_id, worker_id: worker_id, router_id: router_id}
  end

  test "consults one committed Internal Worker snapshot without tools or source writes", ctx do
    {:ok, before_state} = InternalSessionStore.read(ctx.worker_id, @session_id)

    result =
      MemoryConsultation.ask(
        "blue deployment",
        "Which deployment did we choose?",
        [%{"conversation_id" => "conv1_0000000000000000001"}],
        %{
          role: "router",
          agent_id: ctx.router_id,
          tenant_id: ctx.tenant_id,
          group_id: ctx.group_id
        }
      )

    assert %{
             "keywords" => "blue deployment",
             "question" => "Which deployment did we choose?",
             "results" => [
               %{
                 "status" => "answered",
                 "runtime_kind" => "internal",
                 "worker_role" => "implementer",
                 "answer" => "The worker remembers the deployment decision."
               }
             ],
             "truncated" => false
           } = result

    assert_receive {:consultation_discovery, group_id, "blue deployment",
                    [%{"conversation_id" => "conv1_0000000000000000001"}], 11}

    assert group_id == ctx.group_id

    assert_receive {:consultation_route, ^group_id, target, "Which deployment did we choose?",
                    "memory-consultation-" <> _request_suffix}

    assert target.agent_id == ctx.worker_id
    assert_receive {:consultation_llm, messages, []}
    assert Enum.any?(messages, &(&1[:content] == "We chose the blue deployment."))
    assert List.last(messages) == %{role: "user", content: "Which deployment did we choose?"}

    {:ok, after_state} = InternalSessionStore.read(ctx.worker_id, @session_id)

    assert InternalSession.storage_revision(after_state) ==
             InternalSession.storage_revision(before_state)

    assert InternalSession.get(after_state, :messages) ==
             InternalSession.get(before_state, :messages)
  end

  test "direct Conversation refs do not require keywords", ctx do
    conversation_refs = [%{"conversation_id" => "conv1_0000000000000000001"}]

    result =
      %{
        "question" => "Which deployment did we choose?",
        "conversation_refs" => conversation_refs
      }
      |> Memory.memory_ask_worker(%{
        role: "router",
        agent_id: ctx.router_id,
        tenant_id: ctx.tenant_id,
        group_id: ctx.group_id
      })
      |> Jason.decode!()

    assert result["keywords"] == ""
    assert [%{"status" => "answered"}] = result["results"]

    assert_receive {:consultation_discovery, group_id, "", ^conversation_refs, 11}
    assert group_id == ctx.group_id
  end

  test "rejects non-Router callers before discovery", ctx do
    assert %{"error" => ":router_only", "results" => []} =
             MemoryConsultation.ask(
               "keywords",
               "question",
               [],
               %{
                 role: "worker",
                 agent_id: ctx.worker_id,
                 tenant_id: ctx.tenant_id,
                 group_id: ctx.group_id
               }
             )

    refute_receive {:consultation_discovery, _, _, _, _}
  end

  test "rejects a disabled Group before discovery", ctx do
    SalixAgent.TestSupport.create_control_group!(ctx.group_id, %{
      "tenant_id" => ctx.tenant_id,
      "memory_ask_worker_enabled" => false
    })

    assert %{"error" => ":memory_ask_worker_disabled", "results" => []} =
             MemoryConsultation.ask(
               "keywords",
               "question",
               [],
               %{
                 role: "router",
                 agent_id: ctx.router_id,
                 tenant_id: ctx.tenant_id,
                 group_id: ctx.group_id
               }
             )

    refute_receive {:consultation_discovery, _, _, _, _}
  end

  test "deduplicates by exact Session and consults only the newest ten", ctx do
    targets =
      1..11
      |> Enum.map(fn rank ->
        %{
          agent_id: ctx.worker_id,
          session_id: SalixStore.Ids.new_session_id(),
          participant_id: "participant-#{rank}",
          worker_role: "worker-#{rank}",
          runtime_kind: "internal",
          rank_at: rank,
          conversation_ref: %{"conversation_id" => "conversation-#{rank}"}
        }
      end)

    newest = List.last(targets)

    duplicate_newest = %{
      newest
      | rank_at: 100,
        conversation_ref: %{"conversation_id" => "conversation-newest-duplicate"}
    }

    Application.put_env(:salix_agent, :memory_consultation_test_discovery, %{
      targets: [duplicate_newest | targets],
      truncated: false
    })

    result =
      MemoryConsultation.ask(
        "bounded recall",
        "What do you remember?",
        [],
        %{
          role: "router",
          agent_id: ctx.router_id,
          tenant_id: ctx.tenant_id,
          group_id: ctx.group_id
        }
      )

    assert result["truncated"] == true
    assert length(result["results"]) == 10

    refs = Enum.map(result["results"], &get_in(&1, ["conversation_ref", "conversation_id"]))
    assert "conversation-newest-duplicate" in refs
    refute "conversation-11" in refs
    refute "conversation-1" in refs
    assert Enum.all?(result["results"], &(&1["status"] == "unavailable"))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
