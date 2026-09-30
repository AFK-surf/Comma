defmodule SalixAgent.SessionKernelReplyRepairTest do
  use ExUnit.Case, async: false
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver

  defp event(extra \\ %{}) do
    Map.merge(
      %{"type" => "visible_reply_repair", "status" => "pending", "created_at" => "now"},
      extra
    )
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, event) do
    outcome(fn ->
      {:done, next} = Driver.step(state, event)
      next
    end)
  end

  test "repair selects raw fields appends one fact and preserves every unrelated field" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      events: [%{"seq" => 2}],
      last_seq: 5,
      llm_failure_streak: %{count: 3},
      last_activity_at: "before",
      visible_reply_repair: %{old: true},
      messages: [:unvisited]
    }

    ev =
      event(%{
        "attempts" => false,
        "revision" => nil,
        "diagnostic_hwm" => 0,
        "completed_at_hwm" => [],
        "public_summary" => %{nested: [1.5]},
        "kind" => "injected",
        "seq" => 999,
        "unknown" => true
      })

    assert {:returned, next} = check(state, ev)

    repair =
      Map.take(ev, [
        "status",
        "attempts",
        "diagnostic_hwm",
        "completed_at_hwm",
        "public_summary",
        "created_at"
      ])

    assert next.visible_reply_repair === repair

    assert next.events ===
             state.events ++
               [
                 Map.merge(
                   repair,
                   %{"kind" => "visible_reply_repair", "seq" => 6}
                 )
               ]

    assert next.last_seq === 6
    assert next.llm_failure_streak === nil
    assert next.last_activity_at === "now"
    writes = [:visible_reply_repair, :events, :last_seq, :llm_failure_streak, :last_activity_at]
    assert Map.drop(next, writes) === Map.drop(state, writes)
  end

  test "only literal completed status clears repair and repeated events still append" do
    for status <- ["completed", :completed, nil, false, [], <<1::1>>] do
      ev = event(%{"status" => status})

      assert {:returned, first} =
               check(
                 %State{
                   status: :active,
                   activity_status: :thinking,
                   activity_status_updated_at: 10
                 },
                 ev
               )

      assert {:returned, second} = check(first, ev)
      assert length(second.events) === 2
      assert second.last_seq === 2
      assert second.visible_reply_repair === nil === (status === "completed")
    end
  end

  test "native sequence and history defaults preserve float and negative arithmetic" do
    for previous <- [nil, false, -2, 0, 2.5], history <- [nil, false, []] do
      assert {:returned, next} =
               check(
                 %State{
                   status: :active,
                   activity_status: :thinking,
                   activity_status_updated_at: 10,
                   last_seq: previous,
                   events: history
                 },
                 event()
               )

      assert next.last_seq === (previous || 0) + 1
      assert hd(next.events)["seq"] === next.last_seq
    end

    for timestamp <- [nil, false, 0, "", []] do
      assert {:returned, next} =
               check(
                 %State{
                   status: :active,
                   activity_status: :thinking,
                   activity_status_updated_at: 10,
                   last_activity_at: "before"
                 },
                 event(%{"created_at" => timestamp})
               )

      assert next.last_activity_at === (timestamp || "before")
    end
  end

  test "native sequence and malformed history fail without a partial returned State" do
    assert {:raised, :error, %ArithmeticError{}} = check(%State{last_seq: :invalid}, event())

    for history <- [:invalid, [1 | :improper]] do
      assert {:raised, :error, %ArgumentError{}} = check(%State{events: history}, event())
    end
  end
end
