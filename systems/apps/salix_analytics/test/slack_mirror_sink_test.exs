defmodule SalixAnalytics.SlackMirrorSinkTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.SlackMirror.Sink

  setup do
    start_supervised!(SalixAnalytics.MockClickHouse)

    bandit =
      start_supervised!(
        {Bandit,
         plug: SalixAnalytics.MockClickHouse, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    previous = Application.get_env(:salix_analytics, :clickhouse)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      database: "salix_staging",
      table: "salix_staging.events"
    )

    on_exit(fn -> restore_clickhouse(previous) end)
    :ok
  end

  test "accepts ClickHouse Cloud's versioned SharedReplacingMergeTree layout" do
    SalixAnalytics.MockClickHouse.report_engine_as("SharedReplacingMergeTree")

    SalixAnalytics.MockClickHouse.report_engine_full_as(
      "SharedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', " <>
        "'{replica}', version) PARTITION BY toYYYYMM(event_date) " <>
        "ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)"
    )

    assert Sink.readiness() == :ok
  end

  test "refuses a SharedReplacingMergeTree without the version argument" do
    SalixAnalytics.MockClickHouse.report_engine_as("SharedReplacingMergeTree")

    SalixAnalytics.MockClickHouse.report_engine_full_as(
      "SharedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}') " <>
        "PARTITION BY toYYYYMM(event_date) " <>
        "ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)"
    )

    assert {:error, {:slack_mirror_table_layout_mismatch, _table, what}} = Sink.readiness()
    assert what =~ "version argument"
  end

  defp restore_clickhouse(nil), do: Application.delete_env(:salix_analytics, :clickhouse)

  defp restore_clickhouse(previous),
    do: Application.put_env(:salix_analytics, :clickhouse, previous)
end
