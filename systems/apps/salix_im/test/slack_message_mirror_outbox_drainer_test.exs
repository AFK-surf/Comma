defmodule SalixIM.SlackMessageMirrorOutboxDrainerTest do
  @moduledoc """
  The outbox drainer against the real outbox table and a scripted writer.

  The property from `tla/salix/SlackMirrorOutbox.tla` that code has to keep:
  a row is deleted only after the write was acknowledged, and a failed write
  leaves every row of the batch in place.
  """
  use ExUnit.Case, async: false

  alias SalixIM.SlackMessageMirror.OutboxDrainer
  alias SalixStore.{Repo, SlackMirrorOutbox}

  defmodule ScriptedWriter do
    @moduledoc false
    def write_batch(rows) do
      pid = Application.fetch_env!(:salix_im, :outbox_drainer_test_pid)
      send(pid, {:write, self(), rows})

      receive do
        {:answer, answer} -> answer
      after
        1_000 -> :ok
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
    Repo.query!("TRUNCATE slack_mirror_outbox")
    Application.put_env(:salix_im, :outbox_drainer_test_pid, self())
    on_exit(fn -> Application.delete_env(:salix_im, :outbox_drainer_test_pid) end)
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

    handler = "outbox-batch-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:salix, :slack_mirror, :outbox, :batch],
      fn _event, measurements, metadata, _config ->
        send(parent, {:batch, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
      end)

    assert_receive {:write, from, _rows}
    send(from, {:answer, {:error, :clickhouse_down}})

    assert {:error, :clickhouse_down} = Task.await(task)
    assert_receive {:batch, %{count: 2}, %{outcome: :failed}}
    assert pending() == 2

    # Held back: attempts 0 -> backoff of one drain interval.
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
    refute_receive {:write, _from, _rows}, 50

    Process.sleep(250)
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 10, drain_ms: 100)
    assert_receive {:write, _from, rows}
    assert length(rows) == 2
    assert pending() == 0
  end

  test "a full batch asks for an immediate next tick" do
    for n <- 1..3, do: :ok = SlackMirrorOutbox.append(row(n))

    assert :more = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 2)
    assert_receive {:write, _from, [_one, _two]}
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter, batch_size: 2)
    assert_receive {:write, _from, [_three]}
    assert pending() == 0
  end

  test "a writer that raises leaves the rows in place and does not kill the drainer" do
    defmodule RaisingWriter do
      def write_batch(_rows), do: raise("clickhouse url malformed")
    end

    :ok = SlackMirrorOutbox.append(row(1))

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    drainer =
      start_supervised!(
        {OutboxDrainer,
         name: nil,
         writer: RaisingWriter,
         task_supervisor: supervisor,
         start_delay_ms: 0,
         drain_ms: 50}
      )

    Process.sleep(200)
    assert Process.alive?(drainer)
    assert pending() == 1
  end

  test "the lag gauge is published from the oldest waiting row" do
    handler = "outbox-lag-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:salix, :slack_mirror, :outbox, :lag],
      fn _event, measurements, _metadata, _config -> send(parent, {:lag, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter)
    assert_receive {:lag, %{oldest_age_seconds: 0.0}}

    :ok = SlackMirrorOutbox.append(row(1))
    Process.sleep(30)
    assert :idle = OutboxDrainer.drain_once(writer: ScriptedWriter)
    assert_receive {:lag, %{oldest_age_seconds: age}}
    assert age >= 0.03
  end

  test "a disabled writer does not claim the outbox" do
    :ok = SlackMirrorOutbox.append(row(1))
    assert :idle = OutboxDrainer.drain_once(writer: DisabledWriter)
    assert pending() == 1
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
