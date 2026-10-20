defmodule SalixStore.QueueCaseTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_mirror_outbox]

  alias SalixStore.SlackMirrorOutbox

  # What a suite that ran earlier leaves: a row older than any row a test
  # here appends. Each test below leaves its own row to the next one as well.
  setup_all do
    :ok = SlackMirrorOutbox.append(row("left by an earlier suite"))
  end

  test "the oldest row of the queue is the test's own" do
    :ok = SlackMirrorOutbox.append(row("first"))
    assert {:ok, [%{row: %{"text" => "first"}}]} = SlackMirrorOutbox.claim(1, 60_000)
  end

  test "the queue holds only what the test appended" do
    :ok = SlackMirrorOutbox.append(row("second"))
    assert {:ok, [%{row: %{"text" => "second"}}]} = SlackMirrorOutbox.claim(10, 60_000)
  end

  test "an asynchronous module cannot empty the queues every test shares" do
    assert_raise ArgumentError, ~r/make it `async: false`/, fn ->
      SalixStore.QueueCase.start_empty(%{async: true, module: __MODULE__})
    end
  end

  defp row(text) do
    %{
      "event_date" => "2026-08-18",
      "tenant_id" => "ten1_queue_case",
      "workspace_id" => "T_QUEUE_CASE",
      "channel_id" => "C_QUEUE_CASE",
      "message_ts_us" => 1_787_019_000_000_001,
      "message_ts" => "1787019000.000001",
      "version" => 1,
      "deleted" => false,
      "text" => text,
      "body_text" => "",
      "blocks" => "",
      "files" => "[]",
      "ingest_source" => "webhook"
    }
  end
end
