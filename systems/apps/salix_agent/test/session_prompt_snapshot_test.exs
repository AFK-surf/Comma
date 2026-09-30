defmodule SalixAgent.SessionPromptSnapshotTest do
  @moduledoc """
  Activation records the current configuration prompt without replacing history.
  Compaction uses the old prompt before recording its refreshed prompt.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{Compaction, Fleet, InternalSessionStore}

  @session_id "ses1_0000000000000000102"

  defmodule CaptureLLM do
    @behaviour SalixAgent.LLM

    use Elixir.Agent

    def start_link(_opts \\ []), do: Elixir.Agent.start_link(fn -> [] end)

    def script(responses) when is_list(responses) do
      Elixir.Agent.update(agent_pid!(), fn _ -> responses end)
    end

    @impl true
    def complete(messages, tools) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:llm_request, messages, tools})
      end

      Elixir.Agent.get_and_update(agent_pid!(), fn
        [next | rest] -> {next, rest}
        [] -> {{:final, "done"}, []}
      end)
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    defp agent_pid! do
      case :persistent_term.get({__MODULE__, :agent_pid}, nil) do
        pid when is_pid(pid) -> pid
        nil -> raise "CaptureLLM is not started for this test"
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_summarizer = Application.get_env(:salix_agent, :summarizer)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    capture_llm = start_supervised!(CaptureLLM)
    :persistent_term.put({CaptureLLM, :agent_pid}, capture_llm)
    Application.put_env(:salix_agent, :llm, CaptureLLM)
    Application.delete_env(:salix_agent, :summarizer)
    :persistent_term.put({CaptureLLM, :test_pid}, self())
    CaptureLLM.script([])

    agent = SalixAgent.TestSupport.new_agent_id()

    on_exit(fn ->
      # A prompt snapshot test may have already observed the LLM request while
      # the per-session actor is still committing the response. Let that work
      # finish before restoring global LLM config; otherwise the actor can
      # retry against the next test's `SalixAgent.LLM.Mock` script.
      wait_for_agent_sessions_to_settle(agent, 200)
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase({CaptureLLM, :agent_pid})
      :persistent_term.erase({CaptureLLM, :test_pid})
      restore(:salix_store, :s3_backend, prev_backend)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :summarizer, prev_summarizer)
      restore(:salix_agent, :group_context_mod, prev_group_context)
    end)

    {:ok, agent: agent}
  end

  test "normal activations apply configured instructions and retain earlier messages", %{
    agent: agent
  } do
    SalixAgent.TestSupport.create_control_agent!(agent, %{
      "role" => "worker",
      "system_prompt" => "first prompt"
    })

    {:ok, _pid} = Fleet.ensure_started(agent, create: false)

    CaptureLLM.script([done_response("first reply")])

    {:ok, _} =
      SalixAgent.deliver(agent, %{content: "hello", session_id: @session_id},
        source_message_id: "u1"
      )

    assert_receive {:llm_request, first_messages, _tools}, 1_000
    assert_agent_sessions_settled!(agent)

    first_prompt = prompt_from(first_messages)
    assert first_prompt =~ "first prompt"

    first_session = read_session!(agent, @session_id)
    assert first_session.system_prompt == first_prompt
    assert List.last(first_session.messages).content == "first reply"

    {:ok, _agent} = SalixAgent.Control.configure(agent, %{"system_prompt" => "second prompt"})

    CaptureLLM.script([done_response("second reply")])

    {:ok, _} =
      SalixAgent.deliver(agent, %{content: "again", session_id: @session_id},
        source_message_id: "u2"
      )

    assert_receive {:llm_request, second_messages, _tools}, 1_000
    assert_agent_sessions_settled!(agent)

    second_prompt = prompt_from(second_messages)
    refute second_prompt == first_prompt
    assert second_prompt =~ "second prompt"
    refute second_prompt =~ "first prompt"
    assert Enum.any?(second_messages, &(&1[:content] == "first reply"))
    second_session = read_session!(agent, @session_id)
    assert second_session.system_prompt == second_prompt
    assert List.last(second_session.messages).content == "second reply"
  end

  test "old sessions use current configuration and preserve history through replay", %{
    agent: agent
  } do
    SalixAgent.TestSupport.create_control_agent!(agent, %{
      "role" => "worker",
      "system_prompt" => "Current configured instructions."
    })

    old_prompt = "current_date: 2026-09-05"
    catalog = SalixAgent.InternalSession.request_projection({:turn_reminder_catalog})

    custom =
      "\n\nAvailable skills are exposed as session runtime files.\nSkill index: /.runtime/skills/index.md" <>
        "\n\n## Agent Instructions\n\nKeep the stored custom instructions."

    old_catalog =
      String.replace(catalog, "- final_reply=on:", "- final_reply=on: obsolete runtime rule")

    old_snapshot =
      old_prompt <> "\n\nSend first, then finish separately.\n\n" <> old_catalog <> custom

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "session_system_prompt",
          "session_id" => @session_id,
          "system_prompt" => old_snapshot
        },
        %{
          "type" => "runtime_message",
          "session_id" => @session_id,
          "from_context_provider" => true,
          "no_wake" => true,
          "message_id" => 1,
          "runtime_message_id" => "legacy-notice",
          "runtime_message_type" => "runtime_guidance",
          "summary" => "old summary",
          "content" => "legacy hidden body"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "previous response",
          "do_not_send_to_llm" => %{
            "context_provider_states" => %{
              "migration_notice" => %{"version" => SalixAgent.MigrationNotice.version()}
            }
          }
        },
        %{
          "type" => "ack",
          "session_id" => @session_id,
          "last_ack_message_id" => 2
        }
      ])

    {:ok, _} = Fleet.ensure_started(agent, create: false)
    CaptureLLM.script([done_response("first"), done_response("second")])

    {:ok, _} =
      SalixAgent.deliver(
        agent,
        %{content: "Yesterday's updates, using UTC.", session_id: @session_id},
        source_message_id: "date-request-1"
      )

    assert_receive {:llm_request, first, _}, 2_000
    assert_agent_sessions_settled!(agent)
    migrated = prompt_from(first)
    assert migrated =~ "Current configured instructions."
    refute migrated =~ "Keep the stored custom instructions."
    refute migrated =~ "Send first, then finish separately."
    refute migrated =~ "obsolete runtime rule"
    assert Enum.any?(first, &(&1[:content] == "previous response"))
    time = Enum.find(first, &(&1[:type] == "time_context"))
    assert time.content =~ Date.to_iso8601(Date.utc_today())
    input = Enum.find(first, &(&1[:source_message_id] == "date-request-1"))
    assert input.input_time["received_at"] =~ Date.to_iso8601(Date.utc_today())

    for {module, function} <- [
          {SalixLlm.Convert, :to_anthropic},
          {SalixLlm.ConvertOpenAI, :to_chat},
          {SalixLlm.ConvertOpenAI, :to_responses_parts}
        ] do
      rendered = apply(module, function, [first]) |> inspect(limit: :infinity)
      assert rendered =~ "/.runtime/skills/index.md"
      refute rendered =~ "legacy hidden body"
    end

    stored = read_session!(agent, @session_id)
    assert stored.system_prompt == migrated

    assert Enum.find(stored.messages, &(&1[:type] == "time_context"))[:content_kind] ==
             "model_context"

    {:ok, _} =
      SalixAgent.deliver(
        agent,
        %{content: "Continue with today's updates, UTC.", session_id: @session_id},
        source_message_id: "date-request-2"
      )

    assert_receive {:llm_request, second, _}, 2_000
    assert_agent_sessions_settled!(agent)
    # The migration happened once: the second request replays the same prompt.
    assert prompt_from(second) == migrated
    assert read_session!(agent, @session_id).system_prompt == migrated
    assert Enum.count(second, &(&1[:type] == "runtime_guidance")) == 2
    assert Enum.count(second, &(&1[:type] == "time_context")) == 2
    # The exact previously prepared notification survives the commit/rebuild.
    assert Enum.find(second, &(&1[:runtime_message_id] == time.runtime_message_id)).content ==
             time.content

    assert Enum.find(second, &(&1[:runtime_message_id] == time.runtime_message_id)).content_kind ==
             "model_context"
  end

  test "compaction uses the old prompt and stores a refreshed prompt", %{agent: agent} do
    SalixAgent.TestSupport.create_control_agent!(agent, %{
      "role" => "worker",
      "system_prompt" => "new prompt"
    })

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "session_system_prompt",
          "session_id" => @session_id,
          "system_prompt" => "OLD SNAPSHOT"
        },
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "content" => "build"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "done"
        },
        %{
          "type" => "ack",
          "session_id" => @session_id,
          "last_ack_message_id" => 2
        }
      ])

    CaptureLLM.script([{:final, "<compaction-summary>old history</compaction-summary>"}])

    {:ok, _owned, %{"status" => "compacted"}} =
      Compaction.compact(%{agent_id: agent, session_id: @session_id}, @session_id)

    assert_receive {:llm_request, messages, _tools}, 1_000
    assert prompt_from(messages) == "OLD SNAPSHOT"

    session = read_session!(agent, @session_id)
    assert session.summary == "<compacted-context>\nold history\n</compacted-context>"
    assert session.system_prompt =~ "new prompt"
    refute session.system_prompt == "OLD SNAPSHOT"
  end

  test "the Lean model reaches a provider request only after IFC help", %{agent: agent} do
    SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "worker"})
    {:ok, _pid} = Fleet.ensure_started(agent, create: false)

    CaptureLLM.script([
      {:assistant, "",
       [
         %{
           id: "read-ifc",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "ifc"}}
         }
       ]},
      done_response("done")
    ])

    {:ok, _} =
      SalixAgent.deliver(agent, %{content: "Read the IFC manual.", session_id: @session_id},
        source_message_id: "ifc-help-request"
      )

    assert_receive {:llm_request, before_help, _tools}, 1_000

    refute inspect(before_help, limit: :infinity, printable_limit: :infinity) =~
             "namespace VerifiedKernel.IFC"

    after_help = request_with_ifc(10)
    assert_agent_sessions_settled!(agent)
    refute prompt_from(after_help) =~ "namespace VerifiedKernel.IFC"

    assert inspect(after_help, limit: :infinity, printable_limit: :infinity) =~
             "end VerifiedKernel.IFC.Behavior"
  end

  defp request_with_ifc(0), do: flunk("IFC help did not reach the provider")

  defp request_with_ifc(remaining) do
    assert_receive {:llm_request, messages, _tools}, 5_000

    if inspect(messages, limit: :infinity, printable_limit: :infinity) =~
         "namespace VerifiedKernel.IFC" do
      messages
    else
      request_with_ifc(remaining - 1)
    end
  end

  defp prompt_from([%{role: "summary", content: prompt} | _]), do: prompt
  defp prompt_from([%{"role" => "summary", "content" => prompt} | _]), do: prompt

  defp done_response(content) do
    {:assistant, content,
     [
       %{
         id: "prompt_snapshot_end_turn_#{System.unique_integer([:positive, :monotonic])}",
         name: "end_turn",
         args: %{"outcome" => "done"}
       }
     ]}
  end

  defp read_session!(agent_id, session_id) do
    {:ok, session} = read_state(agent_id, session_id)
    session
  end

  defp assert_agent_sessions_settled!(agent) do
    assert wait_for_agent_sessions_to_settle(agent, 200)
  end

  defp wait_for_agent_sessions_to_settle(agent, retries) do
    eventually(fn -> agent_sessions_settled?(agent) end, retries)
  end

  defp agent_sessions_settled?(agent) do
    case InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, :not_found} ->
        true

      {:error, _} ->
        false
    end
  end

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp read_state(agent_id, session_id) do
    with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, SalixAgent.InternalSession.export(session)}
    end
  end
end
