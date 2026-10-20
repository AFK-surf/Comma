defmodule SalixIM.SlackMessageMirrorOutboxDrainerTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The outbox drainer against the real outbox table and a scripted writer.

  The property from `tla/salix/SlackMirrorOutbox.tla` that code has to keep:
  a row is deleted only after the write was acknowledged, and a failed write
  leaves every row of the batch in place.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_mirror_outbox]

  alias SalixIM.SlackMessageMirror.OutboxDrainer
  alias SalixStore.{Repo, SlackMirrorOutbox}

  defmodule ScriptedWriter do
    @moduledoc false
    def write_batch(rows) do
      pid = SystemsRuntime.fetch_env!(:salix_im, :outbox_drainer_test_pid)
      SystemsRuntime.Proc.send(pid, {:write, SystemsRuntime.Proc.self(), rows})

      # Only a test that scripts an answer waits for one; every other write
      # acknowledges immediately.
      if SystemsRuntime.get_env(:salix_im, :outbox_drainer_test_scripted, false) do
        SystemsRuntime.Proc.receive do
          {:answer, answer} -> answer
        after
          1_000 -> :ok
        end
      else
        :ok
      end
    end

    def write_reaction_batch(_rows), do: :ok
    def write_pin_batch(_rows), do: :ok
    def write_metadata_batch(_rows), do: :ok
    def write_event_triggers(_rows), do: :ok
  end

  defmodule DisabledWriter do
    @moduledoc false
    def enabled?, do: false
  end

  setup do
    SystemsRuntime.put_env(:salix_im, :outbox_drainer_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_im, :outbox_drainer_test_pid)
      SystemsRuntime.delete_env(:salix_im, :outbox_drainer_test_scripted)
    end)

    :ok
  end

  test "an acknowledged batch is deleted, oldest first" do
    for n <- 1..3, do: :ok = SlackMirrorOutbox.append(row(n))

    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10)

    assert_receive {:write, _from, rows}
    assert Enum.map(rows, & &1["text"]) == ["row 1", "row 2", "row 3"]
    assert pending() == 0
  end

  test "a failed batch stays, is counted, and comes back after its backoff" do
    for n <- 1..2, do: :ok = SlackMirrorOutbox.append(row(n))

    handler = "outbox-batch-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      handler,
      [:salix, :slack_mirror, :outbox, :batch],
      fn _event, measurements, metadata, _config ->
        SystemsRuntime.Proc.send(parent, {:batch, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    SystemsRuntime.put_env(:salix_im, :outbox_drainer_test_scripted, true)

    task =
      SystemsRuntime.Task.async(fn ->
        OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
      end)

    assert_receive {:write, from, _rows}
    SystemsRuntime.Proc.send(from, {:answer, {:error, :clickhouse_down}})

    assert {:error, :clickhouse_down} = SystemsRuntime.Task.await(task, :infinity)
    SystemsRuntime.put_env(:salix_im, :outbox_drainer_test_scripted, false)
    assert_receive {:batch, %{count: 2}, %{outcome: :failed}}
    assert pending() == 2

    # Held back: attempts 0 -> backoff of one drain interval.
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
    refute_receive {:write, _from, _rows}, 50

    SystemsRuntime.Proc.sleep(250)
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
    assert_receive {:write, _from, rows}
    assert length(rows) == 2
    assert pending() == 0
  end

  defp pending do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM slack_mirror_outbox")
    count
  end

  defp row(n) do
    ts_us = 1_787_019_000_000_000 + n

    %{
      "event_date" => "2026-08-18",
      "tenant_id" => "ten1_drain",
      "workspace_id" => "T_DRAIN",
      "channel_id" => "C_DRAIN",
      "message_ts_us" => ts_us,
      "message_ts" => "1787019000.#{String.pad_leading(Integer.to_string(n), 6, "0")}",
      "version" => ts_us * 2,
      "deleted" => false,
      "text" => "row #{n}",
      "ingest_source" => "webhook"
    }
  end
end
