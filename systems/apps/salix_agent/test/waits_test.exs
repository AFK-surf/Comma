defmodule SalixAgent.WaitsTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Waits
  alias SalixStore.Timers

  @agent_id "agt1_0000000000000000001"
  @session_id "ses1_0000000000000000901"

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    :ok
  end

  test "outbound message receipts preserve the streak in decoded and runtime records" do
    for receipt <- [
          %{
            role: "runtime",
            type: "tool_call_completed",
            source_refs: %{"tool_name" => "im_api.internal.send_message"}
          },
          %{
            "role" => "runtime",
            "type" => "tool_call_failed",
            "source_refs" => %{"tool_name" => "im_api.internal.send_message"}
          }
        ] do
      timeout = %{role: "runtime", type: "wait_expired"}

      messages = [timeout, %{role: "assistant"}, receipt, %{role: "tool"}, timeout]
      assert Waits.consecutive_timeouts(messages) == 2
    end
  end

  test "blank wait ids use a stable payload fingerprint without cross-wait collision" do
    deadline_ms = System.system_time(:millisecond) - 1

    first = %{
      "wait_id" => "",
      "reason" => "first",
      "timeout_seconds" => 1,
      "deadline_ms" => deadline_ms,
      "source" => "wait_for"
    }

    second = %{first | "reason" => "second"}

    first_source = Waits.timeout_source_message_id(@session_id, first)
    assert first_source == Waits.timeout_source_message_id(@session_id, first)
    refute first_source == Waits.timeout_source_message_id(@session_id, second)

    assert :ok = Waits.register_timer_for_wait(@agent_id, @session_id, first)
    assert :ok = Waits.register_timer_for_wait(@agent_id, @session_id, first)
    assert :ok = Waits.register_timer_for_wait(@agent_id, @session_id, second)

    bucket = Timers.minute_bucket(deadline_ms)
    assert {:ok, records} = Timers.sweep(bucket, deadline_ms + 1)
    assert length(records) == 2

    assert Enum.any?(records, fn record ->
             record["source_message_id"] == first_source and
               record["payload"]["runtime_message_id"] == first_source
           end)
  end

  test "non-scalar wait ids fail closed before timer or delivery work" do
    deadline_ms = System.system_time(:millisecond) - 1

    wait = %{
      "wait_id" => %{"invalid" => true},
      "reason" => "invalid",
      "timeout_seconds" => 1,
      "deadline_ms" => deadline_ms,
      "source" => "wait_for"
    }

    assert {:error, :invalid_wait} = Waits.validate(wait)
    assert {:error, :invalid_wait} = Waits.timeout_delivery(@session_id, wait)
    assert :ok = Waits.register_timer_for_wait(@agent_id, @session_id, wait)
    assert {:ok, []} = Timers.sweep(Timers.minute_bucket(deadline_ms), deadline_ms + 1)
  end
end
