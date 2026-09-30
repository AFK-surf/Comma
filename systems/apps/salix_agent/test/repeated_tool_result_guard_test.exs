defmodule SalixAgent.RepeatedToolResultGuardTest do
  use ExUnit.Case, async: true

  alias SalixAgent.AsyncToolResults
  alias SalixAgent.InternalSession
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.Codec

  defp base do
    "agent-repeat"
    |> InternalSession.new("ses1_0000000000000000910", %{})
    |> InternalSession.export()
  end

  defp input(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => id,
        "role" => "user",
        "source_message_id" => "src-#{id}",
        "content" => "input"
      },
      attrs
    )
  end

  defp result(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "tool_result",
        "message_id" => id,
        "tool_call_id" => "call-#{id}",
        "tool_name" => "recommendation.begin",
        "input" => %{},
        "status" => "failed",
        "error" => true,
        "error_class" => "tool_error",
        "error_message" => "recommendation run rejected: :no_recommendation_sources",
        "content" => "error: recommendation run rejected"
      },
      attrs
    )
  end

  defp started(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_started",
        "tool_call_id" => "bg-#{id}",
        "tool_name" => "recommendation.begin",
        "input" => %{"generation" => 3},
        "status" => "running"
      },
      attrs
    )
  end

  defp failed(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "async_tool_call_failed",
        "tool_call_id" => "bg-#{id}",
        "error" => true,
        "error_class" => "tool_error",
        "error_message" => "recommendation run rejected: :no_recommendation_sources",
        "completed_at" => 1_000 + id
      },
      attrs
    )
  end

  # The runtime feeds a background result back to the model as a queued
  # runtime message carrying the call id (`AsyncToolResults`); it is the loop's
  # own feedback, not fresh input.
  defp completion_notice(id, tool_call_id) do
    %{
      "type" => "runtime_message",
      "from_queue" => true,
      "message_id" => id,
      "runtime_message_id" => "tool-call-result:#{tool_call_id}",
      "runtime_message_type" => "tool_call_failed",
      "source_tool_call_id" => tool_call_id,
      "source_message_id" => "tool-call-result:#{tool_call_id}",
      "summary" => "background call failed",
      "content" => "background call failed"
    }
  end

  @bg_input Jason.encode!(%{"generation" => 3})
  @bg_error "recommendation run rejected: :no_recommendation_sources"

  # What the round really commits for one background call: the synchronous
  # `async_running` placeholder result, the started record, the terminal
  # events from the real generator (carrying this call's id, timings and call
  # index) and the queued completion notice the actor materializes on the next
  # activation.
  defp background_lifecycle(state, i, overrides \\ %{}) do
    call_id = "bg-#{i}"
    content = "error: " <> @bg_error

    placeholder =
      Jason.encode!(%{
        "status" => "running",
        "tool_call_id" => call_id,
        "tool_name" => "recommendation.begin",
        "auto_wait_seconds" => 20,
        "message" =>
          "tool is still running asynchronously; completion will arrive as a session notification"
      })

    result =
      Map.merge(
        %{
          id: call_id,
          name: "recommendation.begin",
          content: content,
          error: true,
          input: @bg_input,
          output: content,
          status: "failed",
          duration_ms: 300 + i,
          started_at: 1_000_000 + i * 60_000,
          call_index: 0,
          error_class: "tool_error",
          error_message: @bg_error,
          events: []
        },
        overrides
      )

    pending = %{
      "tool_call_id" => call_id,
      "tool_name" => "recommendation.begin",
      "session_id" => state.session_id,
      "input" => @bg_input
    }

    session =
      state
      |> InternalSession.open()
      |> InternalSession.apply_events([
        %{
          "type" => "tool_result",
          "message_id" => 100 + i,
          "tool_call_id" => call_id,
          "tool_name" => "recommendation.begin",
          "input" => @bg_input,
          "content" => placeholder,
          "status" => "async_running",
          "error" => false,
          "duration_ms" => 12
        },
        %{
          "type" => "async_tool_call_started",
          "session_id" => state.session_id,
          "tool_call_id" => call_id,
          "tool_name" => "recommendation.begin",
          "input" => @bg_input,
          "status" => "running"
        }
        | AsyncToolResults.internal_events(pending, result)
      ])

    {events, _wake?, hwm} = InternalSession.materialize_pending_input_events(session)

    session
    |> InternalSession.apply_events(events)
    |> InternalSession.bump_hwm(hwm)
    |> InternalSession.export()
  end

  defp reload(state), do: state |> InternalSession.open() |> InternalSession.persist() |> load()

  defp load(bytes) do
    {:ok, session} = InternalSession.load(bytes)
    InternalSession.export(session)
  end

  test "five identical results in a row park the session; four do not" do
    four = SessionData.apply_events(base(), [input(1) | Enum.map(2..5, &result/1)])
    assert SessionData.query(four, :consecutive_repeated_tool_results) == 4
    refute SessionData.query(four, :repeated_tool_results_exhausted?)
    assert "stable_input_pending" in SessionData.query(four, :work_reasons)

    five = SessionData.apply_event(four, result(6))
    assert SessionData.query(five, :consecutive_repeated_tool_results) == 5
    assert SessionData.query(five, :repeated_tool_results_exhausted?)
    assert SessionData.query(five, :repeated_tool_result_tool) == "recommendation.begin"
    assert SessionData.query(five, :activity_status) == :failed
    assert SessionData.query(five, :activity_issue) == "repeated_tool_result_parked"
    refute "stable_input_pending" in SessionData.query(five, :work_reasons)
  end

  test "a different outcome, input or tool starts the count over" do
    state = SessionData.apply_events(base(), [input(1), result(2), result(3), result(4)])

    assert SessionData.query(state, :consecutive_repeated_tool_results) == 3

    other_input = SessionData.apply_event(state, result(5, %{"input" => %{"force" => true}}))

    assert SessionData.query(other_input, :consecutive_repeated_tool_results) == 1

    other_outcome =
      SessionData.apply_event(
        state,
        result(5, %{"status" => "completed", "error" => false})
      )

    assert SessionData.query(other_outcome, :consecutive_repeated_tool_results) == 1

    other_tool = SessionData.apply_event(state, result(5, %{"tool_name" => "env.exec"}))

    assert SessionData.query(other_tool, :consecutive_repeated_tool_results) == 1
  end

  test "polling tools neither count nor break a streak" do
    state = SessionData.apply_events(base(), [input(1), result(2), result(3)])

    polled =
      SessionData.apply_events(state, [
        result(4, %{"tool_name" => "wait_for", "status" => "completed", "content" => "timed out"}),
        result(5, %{"tool_name" => "tool_call.get_result", "status" => "completed"}),
        result(6)
      ])

    assert SessionData.query(polled, :consecutive_repeated_tool_results) == 3
  end

  test "identical background results count the same way, and their completion notices do not reset" do
    events =
      [input(1)] ++
        Enum.flat_map(1..5, fn i ->
          [started(i), failed(i), completion_notice(10 + i, "bg-#{i}")]
        end)

    state = SessionData.apply_events(base(), events)
    assert SessionData.query(state, :consecutive_repeated_tool_results) == 5
    assert SessionData.query(state, :repeated_tool_results_exhausted?)
    refute SessionData.query(state, :work_reasons) |> Enum.member?("stable_input_pending")
  end

  test "fresh user input clears the count" do
    parked = SessionData.apply_events(base(), [input(1) | Enum.map(2..6, &result/1)])

    assert SessionData.query(parked, :repeated_tool_results_exhausted?)

    fresh = SessionData.apply_event(parked, input(7))
    assert SessionData.query(fresh, :consecutive_repeated_tool_results) == 0
    refute SessionData.query(fresh, :repeated_tool_results_exhausted?)
    assert "stable_input_pending" in SessionData.query(fresh, :work_reasons)
  end

  test "the count survives reload, and a snapshot written before the field loads clean" do
    state = SessionData.apply_events(base(), [input(1), result(2), result(3), result(4)])

    assert SessionData.query(reload(state), :consecutive_repeated_tool_results) == 3

    legacy =
      state
      |> Map.delete(:repeated_tool_result_streak)
      |> Codec.encode_snapshot()
      |> Codec.snapshot_etf()
      |> load()

    assert legacy.repeated_tool_result_streak == nil
    assert SessionData.query(legacy, :consecutive_repeated_tool_results) == 0

    assert SessionData.query(
             SessionData.apply_event(legacy, result(5)),
             :consecutive_repeated_tool_results
           ) == 1
  end

  test "a real background call lifecycle counts once per terminal result and parks at the cap" do
    state = SessionData.apply_event(base(), input(1))
    four = Enum.reduce(1..4, state, &background_lifecycle(&2, &1))
    assert SessionData.query(four, :consecutive_repeated_tool_results) == 4
    refute SessionData.query(four, :repeated_tool_results_exhausted?)
    assert four.input_queue == []

    five = background_lifecycle(four, 5)
    assert SessionData.query(five, :consecutive_repeated_tool_results) == 5
    assert SessionData.query(five, :repeated_tool_results_exhausted?)
    assert SessionData.query(five, :repeated_tool_result_tool) == "recommendation.begin"
    assert SessionData.query(five, :activity_issue) == "repeated_tool_result_parked"
    refute "stable_input_pending" in SessionData.query(five, :work_reasons)
  end

  test "a background result whose outcome changes starts the count over despite equal metadata" do
    three =
      Enum.reduce(
        1..3,
        SessionData.apply_event(base(), input(1)),
        &background_lifecycle(&2, &1)
      )

    assert SessionData.query(three, :consecutive_repeated_tool_results) == 3

    changed =
      background_lifecycle(three, 4, %{
        content: "ok: recommendation run started",
        output: "ok: recommendation run started",
        error: false,
        status: "completed",
        error_class: nil,
        error_message: nil
      })

    assert SessionData.query(changed, :consecutive_repeated_tool_results) == 1
  end

  test "the running placeholder a background call returns neither counts nor breaks a streak" do
    state = SessionData.apply_events(base(), [input(1), result(2), result(3)])

    placeholder =
      result(4, %{
        "status" => "async_running",
        "error" => false,
        "error_class" => nil,
        "error_message" => nil,
        "content" => Jason.encode!(%{"status" => "running", "tool_call_id" => "call-4"})
      })

    assert SessionData.query(
             SessionData.apply_event(state, placeholder),
             :consecutive_repeated_tool_results
           ) == 2

    assert SessionData.query(
             SessionData.apply_events(state, [placeholder, result(5)]),
             :consecutive_repeated_tool_results
           ) == 3
  end

  test "a sync error and a background failure with the same outcome are one streak" do
    sync =
      SessionData.apply_events(base(), [
        input(1),
        result(2, %{
          "input" => @bg_input,
          "status" => "error",
          "content" => "error: " <> @bg_error
        }),
        result(3, %{
          "input" => @bg_input,
          "status" => "error",
          "content" => "error: " <> @bg_error
        })
      ])

    assert SessionData.query(sync, :consecutive_repeated_tool_results) == 2

    assert SessionData.query(
             background_lifecycle(sync, 4),
             :consecutive_repeated_tool_results
           ) == 3
  end
end
