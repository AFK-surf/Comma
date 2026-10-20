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

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      llm: SystemsRuntime.get_env(:salix_agent, :llm),
      im: SystemsRuntime.get_env(:salix_agent, :im_provider_mod),
      visible_reply: SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, RecordingLLM)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, RecordingIMProvider)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    SystemsRuntime.PersistentTerm.put(@owner_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@owner_key)
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :llm, previous.llm)
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
  end

  defp deliver_task_message(agent) do
    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent, @session_id, [
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
