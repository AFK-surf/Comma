defmodule SalixAgent.WorkerTaskFailureTest do
  require SystemsRuntime.Proc

  @moduledoc """
  A Task Worker whose model answers with nothing, or fails for good, drives
  whole rounds through `SalixAgent.Server` with a scripted model and a
  recording IM provider. Staging 2026-10-08: such a Worker sent requests that
  ended with its own empty response, which the provider refused as assistant
  prefill, and it stopped without telling its Task.
  """

  use SystemsClock.Case, async: false

  alias SalixAgent.{Fleet, Server}
  alias SalixAgent.LLM.Mock

  @session_id "ses1_0000000000000000977"
  @task "cnv1_0000000000000000977"
  @source_message_id "msg1_0000000000000000977"
  @group_id "grp1_0000000000000000977"
  @encoded_source "groupconv:#{@task}:#{@source_message_id}:par1_0000000000000000977"
  @owner_key {__MODULE__, :owner}

  # The scripted model, recording each request's messages.
  defmodule RecordingLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools) do
      record(messages)
      Mock.complete(messages, tools)
    end

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, tools, on_delta, opts) do
      record(messages)
      Mock.complete_stream(messages, tools, on_delta, opts)
    end

    defp record(messages),
      do:
        SystemsRuntime.Proc.send(
          SystemsRuntime.PersistentTerm.get({SalixAgent.WorkerTaskFailureTest, :owner}),
          {:llm, messages}
        )
  end

  defmodule RecordingIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "description" => "Send an internal conversation message.",
             "parameters" => %{
               "conversation_id" => "Conversation id.",
               "content" => "Message content."
             },
             "required_params" => ["conversation_id", "content"]
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, provider, api, args) do
      owner = SystemsRuntime.PersistentTerm.get({SalixAgent.WorkerTaskFailureTest, :owner})
      SystemsRuntime.Proc.send(owner, {:im_provider_call, agent_id, provider, api, args})
      {:ok, %{"ok" => true, "inserted" => true}}
    end
  end

  defmodule TestVisibleReply do
    @moduledoc false
    @behaviour SalixAgent.VisibleReply

    @impl true
    def authorize(_agent_id, _scope), do: :ok
  end

  defmodule AuditFacts do
    def mode(_, _), do: "audit"

    def resolve(request) do
      send(
        SystemsRuntime.PersistentTerm.get({SalixAgent.WorkerTaskFailureTest, :owner}),
        {:ifc_resolved, request}
      )

      {:ok, %{"destination" => %{"label" => ["public"], "writers" => "any"}, "policy" => %{}}}
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      llm: SystemsRuntime.get_env(:salix_agent, :llm),
      facts: SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod),
      im: SystemsRuntime.get_env(:salix_agent, :im_provider_mod),
      visible_reply: SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, RecordingLLM)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, AuditFacts)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, RecordingIMProvider)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    SystemsRuntime.PersistentTerm.put(@owner_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@owner_key)
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :llm, previous.llm)
      restore(:salix_agent, :ifc_facts_mod, previous.facts)
      restore(:salix_agent, :im_provider_mod, previous.im)
      restore(:salix_agent, :visible_reply_mod, previous.visible_reply)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  test "a Worker that keeps answering with nothing never ends a request on its own response, then reports to its Task",
       %{agent: agent} do
    empty = {:assistant, "", [], %{"chat_message_extra" => %{"reasoning" => "thinking only"}}}
    Mock.script(List.duplicate(empty, 6))

    deliver_task_message(agent)
    run(agent)

    requests = llm_requests()
    assert length(requests) >= 2

    # The provider sees the runtime's message last, never the model's own response.
    for messages <- requests do
      last = messages |> SalixLlm.ConvertOpenAI.to_chat() |> List.last()
      refute last["role"] == "assistant", inspect(last)
    end

    assert [{"internal", "internal.send_message", %{"params" => params}}] = im_calls(agent)
    assert params["conversation_id"] == @task
    assert [%{"type" => "text", "text" => text}] = params["content"]
    assert text =~ "I stopped without a result"
    assert_received {:ifc_resolved, request}
    assert is_list(request["atoms"])
  end

  # Prod 2026-11-18 (HyperShell): the report said only "LLM provider returned
  # HTTP 503", so the Router told people the provider was down and retried a
  # model no Profile served for hours, also with no model, which ran the
  # swarm's default Task model: the same unserved model.
  test "a Worker whose model no Profile serves tells its Task to pick a model agent.models lists",
       %{agent: agent} do
    {:error, meta} =
      SalixAgent.LLM.Error.http("catalog", 503, "no enabled profile serves claude-sonnet-5-5")

    text = report_for(agent, Map.merge(meta, billing_stop("model_unavailable")))

    assert text =~ "model_unavailable: no enabled profile serves claude-sonnet-5-5"
    assert text =~ "im_api.internal.read_conversation"
    assert text =~ "never infer its goal from unrelated messages or notices"
    assert text =~ "agent.models"
    assert text =~ ~s({"kind":"platform","tier":"worker"})
    assert text =~ "default Task model"
    refute text =~ "HTTP 503"
  end

  test "a Worker whose own subscription is at its limit names when it resets", %{agent: agent} do
    {:error, meta} = SalixAgent.LLM.Error.http("catalog", 503, "usage limit reached")

    text =
      report_for(
        agent,
        meta
        |> Map.merge(billing_stop("quota_exhausted"))
        |> Map.put("funding", %{"reset_at" => 1_795_000_000})
      )

    assert text =~ "(quota_exhausted"
    assert text =~ "resets at 2026-11-18T11:06:40Z"
    assert text =~ "im_api.internal.read_conversation"
  end

  test "a Worker stopped by Comma credits says neither another model nor a wait helps",
       %{agent: agent} do
    text =
      report_for(agent, %{
        "error_class" => "billing_unavailable",
        "reason" => "insufficient_credits",
        "retryable" => false,
        "message" => "Not enough credits. Add credits and try again."
      })

    assert text =~ "(insufficient_credits)"
    assert text =~ "add credits"
    assert text =~ "Mark this Task failed"
    refute text =~ "resets"
    refute text =~ "refill"
  end

  test "an active Loop Task Worker stopped by Comma credits tells the Router to keep the Loop scheduled",
       %{agent: agent} do
    {:ok, loop} =
      SalixAgent.Loops.request_task_loop(%{
        "tenant_id" => "ten1_0000000000000000977",
        "group_id" => @group_id,
        "agent_id" => agent,
        "task_conversation_id" => @task,
        "trigger" => %{"every_minutes" => 60}
      })

    {:ok, _active} =
      SalixStore.Loops.update(loop["loop_id"], fn row ->
        {:ok, Map.put(row, "status", "active")}
      end)

    on_exit(fn ->
      SalixAgent.Loops.delete_task_loops(@group_id, @task)
    end)

    text =
      report_for(agent, %{
        "error_class" => "billing_unavailable",
        "reason" => "insufficient_credits",
        "retryable" => false,
        "message" => "Not enough credits. Add credits and try again."
      })

    assert text =~ "(insufficient_credits)"
    assert text =~ "add credits"
    assert text =~ "stays scheduled"
    refute text =~ "Mark this Task failed"
    refute text =~ "Nothing more will happen"
  end

  test "a pending Loop Task Worker stopped by Comma credits warns that the Loop was never created",
       %{agent: agent} do
    {:ok, _loop} =
      SalixAgent.Loops.request_task_loop(%{
        "tenant_id" => "ten1_0000000000000000977",
        "group_id" => @group_id,
        "agent_id" => agent,
        "task_conversation_id" => @task,
        "trigger" => %{"every_minutes" => 60}
      })

    on_exit(fn ->
      SalixAgent.Loops.delete_task_loops(@group_id, @task)
    end)

    text =
      report_for(agent, %{
        "error_class" => "billing_unavailable",
        "reason" => "insufficient_credits",
        "retryable" => false,
        "message" => "Not enough credits. Add credits and try again."
      })

    assert text =~ "(insufficient_credits)"
    assert text =~ "still pending (never created)"
    assert text =~ "im_api.internal.send_message"
    refute text =~ "stays scheduled"
  end

  defp billing_stop(reason),
    do: %{"error_class" => "billing_unavailable", "reason" => reason, "retryable" => false}

  # The one report a Worker sends its Task after the model fails with `error`.
  defp report_for(agent, error) do
    Mock.script(List.duplicate({:error, error}, 6))

    deliver_task_message(agent)
    run(agent)

    assert [{"internal", "internal.send_message", %{"params" => params}}] = im_calls(agent)
    assert [%{"type" => "text", "text" => text}] = params["content"]
    text
  end

  defp deliver_task_message(agent) do
    {:ok, _session} =
      SalixAgent.TestSupport.SessionFixture.commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id}
      ])

    {:ok, _pid} = Fleet.ensure_started(agent, create: true)

    {:ok, :created} =
      SalixAgent.deliver(
        agent,
        %{
          content: "find the camera's model",
          session_id: @session_id,
          trusted_origin: %{
            "provider" => "internal",
            "conversation_id" => @task,
            "conversation_kind" => "agent_task",
            "message_id" => @source_message_id,
            "participant_id" => "par1_0000000000000000977",
            "source_actor_type" => "agent",
            "agent_group_id" => @group_id
          }
        },
        source_message_id: @encoded_source
      )

    :ok
  end

  # Drive the session until it stops asking for another round.
  defp run(agent, rounds \\ 10) do
    Server.wake(agent)
    Server.info(agent)
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, @session_id)
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

    if rounds > 0 and SalixAgent.InternalSession.derived_state(session) in [:queued, :active],
      do: run(agent, rounds - 1),
      else: :ok
  end

  defp llm_requests do
    SystemsRuntime.Proc.receive do
      {:llm, messages} -> [messages | llm_requests()]
    after
      0 -> []
    end
  end

  defp im_calls(agent) do
    SystemsRuntime.Proc.receive do
      {:im_provider_call, ^agent, provider, api, args} ->
        [{provider, api, args} | im_calls(agent)]
    after
      0 -> []
    end
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
