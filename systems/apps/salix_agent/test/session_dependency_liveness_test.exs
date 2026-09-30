defmodule SalixAgent.SessionDependencyLivenessTest do
  @moduledoc """
  Actor-level regressions for user-owned dependency liveness.

  These tests deliberately use dependencies which do not return before the
  actor-owned deadline. Storage remains healthy: the boundary under test is
  only user-selected LLM and external-runtime work.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.{
    ExternalSessionActor,
    ExternalSessionStore,
    InternalSessionActor,
    InternalSessionFleet,
    InternalSessionStore
  }

  alias SalixStore.{RuntimeIds, S3}

  @deadline_ms 100
  @external_session_id "ses1_0000000000000001801"
  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")

  defmodule ControlTemplateResolver do
    @moduledoc false
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.Templates.resolve_llm_for_agent(agent_id)
  end

  defmodule RuntimeEnv do
    @moduledoc false
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"],
         "command" => "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "status" => "ready",
         "connector_run_id" => "test-connector-run",
         "device_id" => config["device_id"] || "test-device",
         "device_runtime_id" => config["device_runtime_id"]
       }}
    end
  end

  defmodule DeadlineLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      cond do
        "fresh after timeout" in contents ->
          send(owner, {:fresh_llm_started, self()})

          receive do
            {:release_fresh_llm, response} -> response
          after
            2_000 -> {:final, "fresh provider escaped the actor deadline"}
          end

        "raise llm" in contents ->
          raise "provider adapter failed"

        "hang normal llm" in contents ->
          send(owner, {:normal_llm_started, self()})

          receive do
            {:release_normal_llm, response} -> response
          after
            2_000 -> {:final, "provider escaped the actor deadline"}
          end

        true ->
          {:final, "unexpected input"}
      end
    end

    # The hanging call streams one delta first: the deadline then kills an
    # attempt that had produced content, which the actor must still report.
    @impl true
    def complete_stream(messages, tools, on_delta) do
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      if "hang normal llm" in contents or "raise llm" in contents,
        do: on_delta.("partial answer ")

      complete(messages, tools)
    end
  end

  defmodule ObservabilityCollector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(fact), do: forward({:run_observation, fact})

    @impl true
    def llm_attempt(fact), do: forward({:attempt_observation, fact})

    defp forward(message) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule DeadlineCompactionLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(_messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:compaction_llm_started, self()})

      receive do
        {:release_compaction_llm, response} -> response
      after
        2_000 ->
          {:final, "<compaction-summary>provider escaped the actor deadline</compaction-summary>"}
      end
    end

    @impl true
    def complete(messages, tools, _opts), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts), do: complete(messages, tools)
  end

  defmodule DeadlineExternalRuntime do
    @moduledoc false
    @behaviour SalixAgent.ExternalRuntime

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)

    @impl true
    def run(request) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:external_runtime_started, self(), request})

      receive do
        {:release_external_runtime, response} -> response
      after
        2_000 -> {:error, :test_dependency_did_not_get_actor_deadline}
      end
    end
  end

  defmodule SaturatingLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)

    @impl true
    def complete(messages, _tools) do
      owner = :persistent_term.get({__MODULE__, :owner})
      contents = Enum.map(messages, &to_string(&1[:content] || &1["content"] || ""))

      cond do
        "other tenant fast" in contents ->
          send(owner, {:other_tenant_llm_started, self()})
          {:final, "other tenant completed"}

        "same tenant lane one" in contents ->
          block(owner, :lane_one)

        "same tenant lane two" in contents ->
          block(owner, :lane_two)

        true ->
          {:final, "unexpected input"}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    defp block(owner, lane) do
      send(owner, {:saturating_llm_started, lane, self()})

      receive do
        :release_saturating_llm -> {:final, "released #{lane}"}
      after
        10_000 -> {:final, "unbounded #{lane}"}
      end
    end
  end

  defmodule HangingMCPProvider do
    @moduledoc false

    def set_owner(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
    def provider_state(_agent_id), do: {:ok, %{}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => "mcp.liveness.hang",
           "summary" => "Blocking user-owned MCP dependency used by liveness tests.",
           "manual" => "Blocking user-owned MCP dependency used by liveness tests.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def call_tool(_agent_id, "liveness", "hang", _args, _ctx) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:hanging_mcp_started, self()})

      receive do
        :release_hanging_mcp -> {:ok, %{"content" => "released"}}
        {:release_hanging_mcp, response} -> response
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for key <- [
            :llm,
            :llm_resolver,
            :summarizer,
            :external_runtime_driver,
            :runtime_environment_mod,
            :session_actor_idle_ms,
            :dependency_job_timeout_ms,
            :dependency_max_children,
            :dependency_max_children_per_tenant,
            :mcp_provider_mod,
            :capability_request_store_mod,
            :agent_observability_mod,
            :llm_request_timeout_ms
          ],
          into: %{},
          do: {key, Application.get_env(:salix_agent, key)}

    previous_store = Application.get_env(:salix_store, :s3_backend)

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    Application.put_env(:salix_agent, :llm_resolver, ControlTemplateResolver)
    Application.delete_env(:salix_agent, :summarizer)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    Application.put_env(:salix_agent, :external_runtime_driver, DeadlineExternalRuntime)
    Application.put_env(:salix_agent, :session_actor_idle_ms, 2_000)

    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: @deadline_ms,
      compaction: @deadline_ms,
      external_runtime: @deadline_ms
    })

    Application.put_env(:salix_agent, :dependency_max_children, 2)
    Application.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)

    Application.put_env(:salix_agent, :agent_observability_mod, ObservabilityCollector)
    ObservabilityCollector.set_owner(self())
    DeadlineLLM.set_owner(self())
    DeadlineCompactionLLM.set_owner(self())
    DeadlineExternalRuntime.set_owner(self())
    SaturatingLLM.set_owner(self())
    HangingMCPProvider.set_owner(self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, previous_store)

      Enum.each(previous, fn {key, value} ->
        restore_env(:salix_agent, key, value)
      end)

      for module <- [
            ObservabilityCollector,
            DeadlineLLM,
            DeadlineCompactionLLM,
            DeadlineExternalRuntime,
            SaturatingLLM,
            HangingMCPProvider
          ] do
        :persistent_term.erase({module, :owner})
      end
    end)

    :ok
  end

  test "never-returning normal LLM times out durably, resumes queued input, and ignores a late result" do
    Application.put_env(:salix_agent, :llm, DeadlineLLM)

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001811"

    assert {:ok, :committed} =
             stage_internal(agent_id, session_id, "normal-hang", "hang normal llm")

    assert_receive {:normal_llm_started, dependency_pid}, 1_000

    actor_pid = internal_actor_pid!(agent_id, session_id)

    %{pending_llm: %{dependency_job: %{token: stale_token}}} =
      :sys.get_state(actor_pid)

    assert {:ok, :committed} =
             stage_internal(agent_id, session_id, "normal-fresh", "fresh after timeout")

    # The actor consumed the mailbox edge while the first LLM owned the
    # activation. The durable dirty bit must survive until that blocker clears;
    # a completion path is not allowed to reconstruct this wake by accident.
    assert eventually(fn -> :sys.get_state(actor_pid).wake_pending end)

    assert eventually(fn ->
             dependency_failure?(agent_id, session_id, "dependency_timeout")
           end)

    # The killed attempt is reported by the actor, with what the round had
    # received from it: one streamed delta, no transport body (a fake provider
    # never goes through SalixLlm.Http), and the lost run beside it.
    assert_receive {:attempt_observation, killed}, 1_000
    assert killed.outcome == "killed"
    assert killed.attempt == 1
    assert killed.max_attempts == SalixAgent.Round.llm_request_max_attempts()
    assert killed.reason == "dependency_timeout"
    assert killed.session_id == session_id
    assert killed.salix_agent_id == agent_id
    assert killed.content_deltas == 1
    assert is_integer(killed.first_content_ms)
    assert killed.received_bytes == nil
    assert killed.received_chunks == nil
    assert killed.duration_ms >= div(@deadline_ms, 2)
    assert_receive {:run_observation, %{status: "actor_failed", session_id: ^session_id}}, 1_000

    assert_receive {:fresh_llm_started, replacement_dependency_pid}, 1_000

    %{pending_llm: %{dependency_job: %{token: current_token}}} =
      :sys.get_state(actor_pid)

    refute current_token == stale_token

    # A malformed identity must not crash the actor or consume the live owner.
    send(
      actor_pid,
      {:dependency_job_result, "not-a-reference", {{:final, "invalid answer"}, 1, %{}}}
    )

    %{pending_llm: %{dependency_job: %{token: ^current_token}}} =
      :sys.get_state(actor_pid)

    # Inject the exact DependencyJob result protocol from the timed-out token
    # while its replacement is current. It cannot clear or commit the new job.
    send(
      actor_pid,
      {:dependency_job_result, stale_token, {{:final, "stale late answer"}, 1, %{}}}
    )

    %{pending_llm: %{dependency_job: %{token: ^current_token}}} =
      :sys.get_state(actor_pid)

    send(dependency_pid, {:release_normal_llm, {:final, "stale late answer"}})

    send(
      replacement_dependency_pid,
      {:release_fresh_llm, done_response("fresh answer after timeout")}
    )

    assert eventually(fn ->
             assistant_content?(agent_id, session_id, "fresh answer after timeout")
           end)

    session = read_internal!(agent_id, session_id)

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "assistant" and &1.content == "stale late answer")
           )

    assert :sys.get_state(actor_pid).pending_llm == nil
  end

  test "a job that crashes after its attempt returned keeps the loop's fact for that attempt" do
    Application.put_env(:salix_agent, :llm, DeadlineLLM)
    # Shorter than the first retry backoff: the raising attempt is abandoned
    # and the exception re-raised, so the job dies after the loop recorded it.
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 200)

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001812"

    assert {:ok, :committed} = stage_internal(agent_id, session_id, "raise", "raise llm")

    assert_receive {:attempt_observation, %{outcome: "abandoned", attempt: 1} = abandoned},
                   1_000

    assert abandoned.session_id == session_id

    assert eventually(fn ->
             dependency_failure?(agent_id, session_id, "dependency_crashed")
           end)

    assert_receive {:run_observation, %{status: "actor_failed", session_id: ^session_id}}, 1_000

    # The actor saw the crash, but the attempt had already returned: a second
    # row for it would share the abandoned row's key and replace it.
    refute_received {:attempt_observation, %{outcome: "killed"}}
  end

  test "never-returning compaction LLM times out durably and cannot block later control" do
    Application.put_env(:salix_agent, :llm, DeadlineCompactionLLM)

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001812"
    source_id = "dependency-liveness:compact"

    seed_compactable_session!(agent_id, session_id)

    assert {:ok, pid} =
             InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    assert {:ok, :committed} =
             InternalSessionActor.stage_control(pid, %{
               source_message_id: source_id,
               payload: %{kind: "session_compact", session_id: session_id}
             })

    assert_receive {:compaction_llm_started, dependency_pid}, 1_000

    context = %{agent_id: agent_id, session_id: session_id}

    assert {:error, :session_compacting} =
             InternalSessionActor.run_round(pid, context, [], 750)

    assert {:error, :session_compacting} =
             InternalSessionActor.compact_session(pid, :compact, context, [], 750)

    parent = self()

    spawn(fn ->
      result =
        try do
          InternalSessionActor.stage_control(
            pid,
            %{
              payload: %{
                kind: "session_update",
                session_id: session_id,
                name: "control survived compaction timeout"
              }
            },
            750
          )
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:control_after_compaction, result})
    end)

    control_result =
      receive do
        {:control_after_compaction, result} -> result
      after
        1_000 -> :no_control_result
      end

    assert control_result == {:ok, :committed}

    assert eventually(fn ->
             session = read_internal!(agent_id, session_id)

             Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
               event["kind"] == "session_compact_result" and
                 event["source_message_id"] == source_id and
                 event["status"] == "failed_soft" and
                 String.contains?(to_string(event["reason"]), "dependency_timeout")
             end)
           end)

    # This is the late-completion attempt. A correctly timed-out job has
    # already been killed or fenced before this reply can reach the actor.
    send(
      dependency_pid,
      {:release_compaction_llm,
       {:final, "<compaction-summary>stale late compaction</compaction-summary>"}}
    )

    session = read_internal!(agent_id, session_id)
    assert SalixAgent.InternalSession.get(session, :name) == "control survived compaction timeout"
    assert SalixAgent.InternalSession.get(session, :summary) == nil
    assert SalixAgent.InternalSession.get(session, :summary_sequence) == 0
  end

  test "microcompact during a blocked summary fences the stale unredacted view" do
    Application.put_env(:salix_agent, :llm, DeadlineCompactionLLM)

    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: @deadline_ms,
      compaction: 1_000,
      external_runtime: @deadline_ms
    })

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001813"
    source_id = "dependency-liveness:redaction-fence"

    seed_redactable_compaction_session!(agent_id, session_id)

    assert {:ok, pid} =
             InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    assert {:ok, :committed} =
             InternalSessionActor.stage_control(pid, %{
               source_message_id: source_id,
               payload: %{kind: "session_compact", session_id: session_id}
             })

    assert_receive {:compaction_llm_started, dependency_pid}, 1_000

    assert {:ok, :committed} =
             InternalSessionActor.stage_control(pid, %{
               source_message_id: "dependency-liveness:microcompact",
               payload: %{kind: "session_microcompact", session_id: session_id}
             })

    assert eventually(fn ->
             SalixAgent.InternalSession.get(read_internal!(agent_id, session_id), :redactions) !=
               []
           end)

    send(
      dependency_pid,
      {:release_compaction_llm,
       {:final,
        "<compaction-summary>stale summary containing secret tool output</compaction-summary>"}}
    )

    assert eventually(fn ->
             session = read_internal!(agent_id, session_id)

             Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
               event["kind"] == "session_compact_result" and
                 event["source_message_id"] == source_id and
                 event["status"] == "failed_hard" and
                 String.contains?(to_string(event["reason"]), "stale_compaction_view")
             end)
           end)

    session = read_internal!(agent_id, session_id)
    assert SalixAgent.InternalSession.get(session, :summary) == nil
    assert SalixAgent.InternalSession.get(session, :summary_sequence) == 0
  end

  test "never-returning external runtime times out durably, resumes dispatch, and ignores its old ref" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "worker",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "test-device",
          "runtime_id" => "test-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

    {:ok, actor_pid} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: @external_session_id,
        process_on_init: false
      )

    assert {:ok, :committed} = stage_external(actor_pid, "external-hang", "hang external")

    assert_receive {:external_runtime_started, first_dependency_pid, first_request}, 1_000

    %{pending_external: %{dependency_job: %{token: stale_token}}} =
      :sys.get_state(actor_pid)

    Process.sleep(@deadline_ms + 300)

    timed_out? =
      match?(
        {:ok, %{"status" => "failed", "issue" => "runtime_failed"}},
        ExternalSessionStore.get_session_status(agent, @external_session_id)
      )

    unless timed_out? do
      send(first_dependency_pid, {
        :release_external_runtime,
        {:accepted, %{"dispatch_id" => first_request.dispatch_id}}
      })
    end

    assert timed_out?

    assert {:ok, :committed} = stage_external(actor_pid, "external-next", "next dispatch")

    assert_receive {:external_runtime_started, second_dependency_pid, second_request}, 1_000
    refute second_request.dispatch_id == first_request.dispatch_id

    %{pending_external: %{dependency_job: %{token: current_token}}} =
      :sys.get_state(actor_pid)

    refute current_token == stale_token

    # Inject the exact DependencyJob result protocol from the old token after a
    # replacement is active. It must not clear or accept the replacement.
    send(
      actor_pid,
      {:dependency_job_result, stale_token,
       {:external_runtime, {:accepted, %{"dispatch_id" => first_request.dispatch_id}}, 999}}
    )

    %{pending_external: %{dependency_job: %{token: ^current_token}}} =
      :sys.get_state(actor_pid)

    send(first_dependency_pid, {
      :release_external_runtime,
      {:accepted, %{"dispatch_id" => first_request.dispatch_id}}
    })

    send(second_dependency_pid, {
      :release_external_runtime,
      {:accepted, %{"dispatch_id" => second_request.dispatch_id}}
    })

    assert eventually(fn -> external_queue(agent_id) == [] end)
  end

  test "one tenant's dependency saturation preserves another tenant and core control" do
    Application.put_env(:salix_agent, :llm, SaturatingLLM)

    # This case exercises admission isolation, not the 100 ms deadline used by
    # the timeout cases above. Keep the first tenant slot alive long enough for
    # both queued actors to reach admission even on a loaded CI scheduler.
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{
      llm: 5_000,
      compaction: @deadline_ms,
      external_runtime: @deadline_ms
    })

    saturated_agent = create_internal_agent!()
    other_agent = create_internal_agent!()

    lane_one_session = "ses1_0000000000000001821"
    lane_two_session = "ses1_0000000000000001822"
    other_session = "ses1_0000000000000001823"

    assert {:ok, :committed} =
             stage_internal(
               saturated_agent,
               lane_one_session,
               "saturation-one",
               "same tenant lane one"
             )

    assert_receive {:saturating_llm_started, :lane_one, first_dependency_pid}, 1_000

    assert {:ok, :committed} =
             stage_internal(
               saturated_agent,
               lane_two_session,
               "saturation-two",
               "same tenant lane two"
             )

    assert {:ok, :committed} =
             stage_internal(other_agent, other_session, "other-tenant", "other tenant fast")

    assert eventually(fn ->
             assistant_content?(other_agent, other_session, "other tenant completed")
           end)

    # The second dependency for one tenant is rejected at admission instead
    # of consuming the global slot reserved for unrelated work.
    refute_received {:saturating_llm_started, :lane_two, _pid}

    assert eventually(fn ->
             dependency_failure?(saturated_agent, lane_two_session, "dependency_saturated")
           end)

    assert {:ok, :committed} =
             InternalSessionFleet.stage_control(
               saturated_agent,
               lane_two_session,
               %{
                 payload: %{
                   kind: "session_update",
                   session_id: lane_two_session,
                   name: "core control remained live"
                 }
               },
               timeout: 500
             )

    assert SalixAgent.InternalSession.get(
             read_internal!(saturated_agent, lane_two_session),
             :name
           ) ==
             "core control remained live"

    send(first_dependency_pid, :release_saturating_llm)
  end

  test "direct user tool failure stays poll-owned without waking the model or opening repair" do
    Application.put_env(:salix_agent, :mcp_provider_mod, HangingMCPProvider)

    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001824"

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    assert {:ok, pid} =
             InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    parent = self()

    spawn(fn ->
      result = InternalSessionActor.execute_tool(pid, "mcp.liveness.hang", %{}, 1_000)
      send(parent, {:hanging_tool_call_result, result})
    end)

    assert_receive {:hanging_mcp_started, dependency_pid}, 1_000

    assert {:ok, :committed} =
             InternalSessionActor.stage_control(
               pid,
               %{
                 source_message_id: "dependency-liveness:tool-control",
                 payload: %{
                   kind: "session_update",
                   session_id: session_id,
                   name: "mailbox stayed live during tool dependency"
                 }
               },
               250
             )

    assert SalixAgent.InternalSession.get(read_internal!(agent_id, session_id), :name) ==
             "mailbox stayed live during tool dependency"

    assert_receive {:hanging_tool_call_result,
                    {:ok, %{id: tool_call_id, status: "async_running"}}},
                   500

    running_session = read_internal!(agent_id, session_id)

    assert SalixAgent.InternalSession.get(running_session, :async_tool_calls)[tool_call_id][
             "completion_owner"
           ] == "direct_poll"

    # Drain the start/control messages, then trace sends by the actor. The
    # exact direct-poll terminal below must not synthesize a model `:process`
    # wake to itself.
    _ = :sys.get_state(pid)
    :erlang.trace(pid, true, [:send])
    on_exit(fn -> :erlang.trace(pid, false, [:send]) end)

    send(dependency_pid, {:release_hanging_mcp, {:error, :user_owned_dependency_failed}})

    assert eventually(fn ->
             :sys.get_state(pid).pending_async_tools == %{}
           end)

    session = read_internal!(agent_id, session_id)

    assert {:ok, %{"status" => "failed", "tool_call_id" => ^tool_call_id}} =
             SalixAgent.InternalSession.lookup_async_call(session, tool_call_id)

    assert SalixAgent.InternalSession.wait(session) == nil
    assert SalixAgent.InternalSession.get(session, :visible_reply_repair) == nil
    assert SalixAgent.InternalSession.work_reasons(session) == []

    refute_receive {:trace, ^pid, :send, :process, ^pid}, 100

    refute Enum.any?(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
             get_in(item, ["payload", "source_tool_call_id"]) == tool_call_id
           end)

    refute Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             Map.get(message, :source_tool_call_id) == tool_call_id
           end)
  end

  defmodule InterruptedCapabilityStore do
    def create_capability_request(attrs) do
      agent_id = attrs["source_agent_id"] || attrs[:source_agent_id]
      session_id = attrs["source_session_id"] || attrs[:source_session_id]
      id = attrs["tool_call_id"] || attrs[:tool_call_id]
      {:ok, session} = InternalSessionStore.read(agent_id, session_id)
      admission = SalixAgent.InternalSession.lookup_async_call(session, id)
      {:ok, request} = SalixAgent.CapabilityRequests.create_capability_request(attrs)

      canonical = %{
        "status" => "completed",
        "content" => "location persisted before handoff",
        "error" => false
      }

      {:ok, _} =
        SalixAgent.CapabilityRequests.reconcile_capability_request(
          agent_id,
          session_id,
          id,
          canonical
        )

      send(
        :persistent_term.get({__MODULE__, :owner}),
        {:capability_created_before_handoff, self(), admission, request}
      )

      receive do
        :return_handoff -> {:ok, request}
      end
    end

    def reconcile_capability_request(agent_id, session_id, id, result),
      do:
        SalixAgent.CapabilityRequests.reconcile_capability_request(
          agent_id,
          session_id,
          id,
          result
        )
  end

  defmodule UnexpectedDirectLLM do
    def complete(_messages, _tools) do
      send(
        :persistent_term.get({InterruptedCapabilityStore, :owner}),
        :unexpected_direct_model_wake
      )

      {:final, "unexpected direct model wake"}
    end

    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)
  end

  test "direct capability admission survives a request completion before its callback handoff" do
    Application.put_env(:salix_agent, :capability_request_store_mod, InterruptedCapabilityStore)
    Application.put_env(:salix_agent, :llm, UnexpectedDirectLLM)
    :persistent_term.put({InterruptedCapabilityStore, :owner}, self())
    on_exit(fn -> :persistent_term.erase({InterruptedCapabilityStore, :owner}) end)
    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001825"

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    {:ok, original_actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        InternalSessionActor.execute_tool(original_actor, "location.request", %{
          "reason" => "weather"
        })
      end)

    assert_receive {:capability_created_before_handoff, creator, {:ok, admission}, request},
                   2_000

    id = request["tool_call_id"]
    assert admission["tool_call_id"] == id
    assert admission["status"] == "running"
    assert admission["completion_owner"] == "direct_poll"
    # Before request creation, admission is still locally owned work.
    refute admission["completion_mode"] == "external_callback"

    # Neither the tool handoff nor its result reaches the execution caller.
    creator_monitor = Process.monitor(creator)
    Process.exit(caller, :kill)
    Process.exit(original_actor, :kill)
    Process.exit(creator, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _}, 1_000
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, _}, 1_000
    {:ok, before_recovery} = InternalSessionStore.read(agent_id, session_id)

    assert {:ok, %{"status" => "running"}} =
             SalixAgent.InternalSession.lookup_async_call(before_recovery, id)

    {:ok, actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    :ok = InternalSessionActor.wake(agent_id, session_id)

    assert eventually(fn ->
             case SalixAgent.InternalSession.lookup_async_call(
                    read_internal!(agent_id, session_id),
                    id
                  ) do
               {:ok, %{"status" => "completed"}} -> true
               _ -> false
             end
           end)

    _ = :sys.get_state(actor)
    recovered = read_internal!(agent_id, session_id)

    assert {:ok,
            %{
              "completion_owner" => "direct_poll",
              "result" => %{"content" => "location persisted before handoff"}
            }} =
             SalixAgent.InternalSession.lookup_async_call(recovered, id)

    assert SalixAgent.InternalSession.work_reasons(recovered) == []
    assert SalixAgent.InternalSession.get(recovered, :input_queue) == []
    assert SalixAgent.InternalSession.get(recovered, :messages) == []
    refute_receive :unexpected_direct_model_wake, 100
  end

  @tag :inline_direct_receipt
  test "inline direct capability result survives a lost final session commit" do
    Application.put_env(:salix_agent, :llm, UnexpectedDirectLLM)
    :persistent_term.put({InterruptedCapabilityStore, :owner}, self())
    on_exit(fn -> :persistent_term.erase({InterruptedCapabilityStore, :owner}) end)
    agent_id = create_internal_agent!()
    session_id = "ses1_0000000000000001826"

    tenant_id =
      agent_id |> SalixStore.Ids.group_id_from_agent!() |> SalixStore.Ids.tenant_id_from_group!()

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    {:ok, actor} =
      InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    # A real occupied tenant slot makes the capability return inline, without
    # relying on scheduler timing to win the zero-wait completion fast path.
    {:ok, occupied} =
      SalixAgent.DependencyJob.start(
        :tool,
        tenant_id,
        fn ->
          receive do
            :release -> :ok
          end
        end,
        timeout_ms: 10_000
      )

    on_exit(fn -> SalixAgent.DependencyJob.cancel(occupied) end)
    owner = self()

    :sys.replace_state(actor, fn data ->
      result =
        SalixAgent.SessionToolExecution.execute(
          agent_id,
          session_id,
          :internal,
          [],
          "location.request",
          %{"reason" => "weather"}
        )

      send(owner, {:inline_before_session_commit, result})
      # Stop at the actual execute/actor-commit seam: discard only the returned
      # session events, retaining everything execute durably wrote itself.
      data
    end)

    assert_receive {:inline_before_session_commit, {:ok, result, [], _events, _observed}}, 1_000
    id = result.id
    assert result.error_class == "dependency_saturated"

    assert {:ok, %{"status" => "running", "completion_owner" => "direct_poll"}} =
             SalixAgent.InternalSession.lookup_async_call(
               read_internal!(agent_id, session_id),
               id
             )

    :ok = SalixAgent.DependencyJob.cancel(occupied)

    :ok = InternalSessionActor.wake(agent_id, session_id)

    assert eventually(fn ->
             case SalixAgent.InternalSession.lookup_async_call(
                    read_internal!(agent_id, session_id),
                    id
                  ) do
               {:ok, %{"status" => "failed"}} -> true
               _ -> false
             end
           end)

    recovered = read_internal!(agent_id, session_id)

    assert {:ok, %{"error_class" => "dependency_saturated", "completion_owner" => "direct_poll"}} =
             SalixAgent.InternalSession.lookup_async_call(recovered, id)

    assert SalixAgent.InternalSession.get(recovered, :messages) == []
    assert SalixAgent.InternalSession.get(recovered, :input_queue) == []
    refute_receive :unexpected_direct_model_wake, 100
  end

  defp create_internal_agent! do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)
    agent_id
  end

  defp stage_internal(agent_id, session_id, source_message_id, content) do
    result =
      InternalSessionFleet.stage_delivery(agent_id, session_id, %{
        source_message_id: source_message_id,
        payload: %{
          session_id: session_id,
          role: "user",
          content: content,
          created_at: System.system_time(:second)
        }
      })

    :ok = InternalSessionActor.wake(agent_id, session_id)
    result
  end

  defp stage_external(pid, source_message_id, content) do
    ExternalSessionActor.stage_delivery(pid, %{
      "source_message_id" => source_message_id,
      "payload" => %{
        "session_id" => @external_session_id,
        "role" => "user",
        "content" => content
      }
    })
  end

  defp internal_actor_pid!(agent_id, session_id) do
    [{pid, _}] =
      Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id))

    pid
  end

  defp seed_compactable_session!(agent_id, session_id) do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 1,
          "source_message_id" => "compact-user",
          "role" => "user",
          "content" => "summarize the user-owned dependency"
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 2,
          "content" => "material that should not be compacted by a late result"
        },
        %{
          "type" => "ack",
          "session_id" => session_id,
          "last_ack_message_id" => 2
        }
      ])

    :ok
  end

  defp seed_redactable_compaction_session!(agent_id, session_id) do
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id, "storage_format" => 2},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => session_id,
          "message_id" => 1,
          "source_message_id" => "redaction-user",
          "role" => "user",
          "content" => "inspect the tool output"
        },
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 2,
          "content" => "",
          "tool_calls" => [
            %{"id" => "redaction-call", "name" => "fs.read_file", "args" => %{}}
          ]
        },
        %{
          "type" => "tool_result",
          "session_id" => session_id,
          "message_id" => 3,
          "tool_call_id" => "redaction-call",
          "content" => "secret tool output"
        },
        # Settle the tool exchange so the secret-bearing pair belongs to the
        # summarized prefix. Runnable suffix preservation is covered by the
        # compaction continuation regressions and intentionally excludes that
        # suffix from this stale-view fence.
        %{
          "type" => "assistant",
          "session_id" => session_id,
          "message_id" => 4,
          "content" => "inspection complete",
          "tool_calls" => []
        },
        %{
          "type" => "ack",
          "session_id" => session_id,
          "last_ack_message_id" => 4
        }
      ])

    :ok
  end

  defp dependency_failure?(agent_id, session_id, reason_fragment) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
          event["kind"] == "llm_call_failed" and
            String.contains?(inspect(event), reason_fragment)
        end)

      {:error, _reason} ->
        false
    end
  end

  defp assistant_content?(agent_id, session_id, content) do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        Enum.any?(
          SalixAgent.InternalSession.get(session, :messages),
          &(&1.role == "assistant" and &1.content == content)
        )

      {:error, _reason} ->
        false
    end
  end

  defp external_queue(agent_id) do
    case ExternalSessionStore.get_session_record(agent_id, @external_session_id) do
      {:ok, state} -> state["input_message_queue"]
      {:error, _reason} -> :unavailable
    end
  end

  defp read_internal!(agent_id, session_id) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defp done_response(content) do
    {:assistant, content,
     [
       %{
         id: "dependency_liveness_end_turn_#{System.unique_integer([:positive, :monotonic])}",
         name: "end_turn",
         args: %{"outcome" => "done"}
       }
     ]}
  end

  defp eventually(fun, retries \\ 150)

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
