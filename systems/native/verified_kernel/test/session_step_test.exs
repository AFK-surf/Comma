defmodule SalixVerifiedKernel.SessionStepTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  defp state do
    %{
      __struct__: SalixAgent.InternalSession.State,
      session_id: "s",
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 1,
      name: "Default",
      hidden: false,
      created_at: nil,
      last_activity_at: 1,
      platform: nil,
      billing_context: nil,
      task_origin: nil,
      source_session_id: nil,
      source_schedule_id: nil,
      system_prompt: "",
      events: [],
      last_seq: 0,
      llm_failure_streak: nil,
      compaction_failure: nil,
      last_compaction_recovery: nil,
      wait: nil,
      storage_format: 3,
      next_message_id: 1,
      last_ack_message_id: 0,
      visible_reply_repair: nil,
      runtime_failure_reply: nil,
      runaway_unsettled_streak: nil,
      repeated_tool_result_streak: nil,
      async_results: [],
      async_result_refs: %{},
      next_queue_id: 1,
      queue_ack_id: 0,
      input_queue: [],
      input_dedupe: MapSet.new(),
      compacted_seq: 0,
      messages: [],
      summary: nil,
      async_tool_calls: %{"call" => %{"status" => "running"}}
    }
  end

  defp finish(module, {:observe_time, token}, reads) do
    finish(module, module.step(token, {:observed_time, 123}), reads ++ [:time])
  end

  defp finish(module, {:observe_config, app, key, default, token}, reads) do
    finish(
      module,
      module.step(token, {:observed_config, default}),
      reads ++ [{app, key, default}]
    )
  end

  defp finish(_module, {:done, next}, reads), do: {next, reads}

  test "log deduplication keeps the two signed-zero keys distinct" do
    for keys <- [[0.0, -0.0], [{0.0}, {-0.0}]] do
      initial = Session.new("agent", "session") |> Session.export()

      {logged, _reads} =
        Enum.reduce(Enum.zip(keys, ["positive zero", "negative zero"]), {initial, []}, fn
          {key, content}, {current, reads} ->
            finish(
              Session,
              Session.step(current, %{
                "type" => "session_log_message",
                "dedupe_key" => key,
                "content" => content,
                "created_at" => 123
              }),
              reads
            )
        end)

      assert Enum.map(logged.messages, & &1.content) == ["positive zero", "negative zero"]
      assert MapSet.size(logged.input_dedupe) == 2

      for key <- keys do
        {duplicate, _reads} =
          finish(
            Session,
            Session.step(logged, %{
              "type" => "session_log_message",
              "dedupe_key" => key,
              "content" => "retry must not replace either original",
              "created_at" => 124
            }),
            []
          )

        assert duplicate.messages === logged.messages
      end
    end
  end

  test "public steps execute metadata, queue, async settlement and activity" do
    {created, []} =
      finish(
        Session,
        Session.step(state(), %{"type" => "session_system_prompt", "prompt" => "system"}),
        []
      )

    assert created.system_prompt == "system"

    {queued, []} =
      finish(
        Session,
        Session.step(created, %{
          "type" => "queue_append",
          "kind" => "user_message",
          "source_message_id" => "m",
          "payload" => %{"content" => "hi"}
        }),
        []
      )

    assert length(queued.input_queue) == 1
    assert queued.next_queue_id == 2

    {progressed, [:time]} =
      finish(
        Session,
        Session.step(queued, %{
          "type" => "async_tool_call_progress",
          "tool_call_id" => "call",
          "progress" => [1, 2]
        }),
        []
      )

    assert progressed.async_tool_calls["call"]["updated_at"] == 123

    {completed, []} =
      finish(
        Session,
        Session.step(progressed, %{
          "type" => "async_tool_call_completed",
          "tool_call_id" => "call",
          "result" => %{"content" => "done"}
        }),
        []
      )

    assert completed.async_tool_calls == %{}
    assert completed.async_result_refs == %{"call" => 1}
    assert hd(completed.async_results)["status"] == "completed"
    assert completed.last_seq == 1

    {idle, reads} =
      finish(
        Session,
        Session.step(
          completed,
          %{"type" => "status", "status" => "idle", "created_at" => 12}
        ),
        []
      )

    assert idle.status == :idle
    assert length(reads) <= 9
    assert {:done, ^idle} = Session.step(idle, %{"type" => "status", "session_id" => "other"})
  end

  test "resident handles step by reference and export the state once" do
    handle = Session.open(state())
    assert {:verified_kernel, 1, :session_state, resident} = handle
    assert is_reference(resident)

    {:done, prompted} =
      Session.step(handle, %{"type" => "session_system_prompt", "prompt" => "p"})

    # The clock and the configuration keys are answered ahead of the call, so
    # neither step needs a continuation round trip.
    {:done, progressed} =
      Session.step(prompted, %{
        "type" => "async_tool_call_progress",
        "tool_call_id" => "call"
      })

    {:done, idle} =
      Session.step(progressed, %{"type" => "status", "status" => "idle", "created_at" => 12})

    exported = Session.export(idle)
    assert exported.system_prompt == "p"
    assert exported.status == :idle
    assert is_integer(exported.async_tool_calls["call"]["updated_at"])

    # Older handles stay valid and unchanged.
    assert Session.export(handle) == state()
    assert Session.export(prompted).async_tool_calls["call"] == %{"status" => "running"}

    assert {:done, ^exported} =
             Session.step(exported, %{"type" => "status", "session_id" => "other"})
  end

  test "resident handles reject data of other kernels and missing states" do
    assert_raise ArgumentError, fn ->
      Session.open(state()) |> Session.step(%{"unknown" => %URI{}})
    end

    assert {_, response} =
             SalixVerifiedKernel.Native.session(
               nil,
               :erlang.term_to_binary({1, :session, 1, :step, %{}})
             )

    assert {1, :error, :session, "missing_state"} = :erlang.binary_to_term(response, [:safe])

    assert_raise ArgumentError, fn ->
      SalixVerifiedKernel.Native.session(make_ref(), <<131, 106>>)
    end
  end

  test "invalid status and missing fields retain their exception classes" do
    assert_raise ArgumentError, "invalid internal session status 42", fn ->
      Session.step(state(), %{"type" => "status", "status" => 42})
    end

    assert_raise KeyError, fn ->
      Session.step(Map.delete(state(), :name), %{"type" => "session_update"})
    end
  end

  test "a cold VM can decode atoms produced only by the Lean reducer" do
    encoded =
      state() |> Map.put(:live_context_bytes, 0) |> :erlang.term_to_binary() |> Base.encode64()

    code = """
    fresh = SalixVerifiedKernel.Session.new("cold-agent", "cold-session")
    %{} = SalixVerifiedKernel.Session.export(fresh)
    [encoded] = System.argv()
    state = encoded |> Base.decode64!() |> :erlang.binary_to_term()
    event = %{"type" => "tool_result", "tool_name" => "test", "input" => %{},
      "status" => "completed", "content" => "done", "output" => "done"}
    {:done, next} = SalixVerifiedKernel.Session.step(state, event)
    true = length(Map.fetch!(next, :messages)) == 1
    IO.puts("cold Session transition passed")
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Path.dirname(to_string(:code.which(SalixVerifiedKernel))),
          "-e",
          code,
          encoded
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "cold Session transition passed"
  end
end
