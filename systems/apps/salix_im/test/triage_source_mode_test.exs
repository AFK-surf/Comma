defmodule SalixIM.Triage.SourceModeTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.SourceMode

  test "keeps ClickHouse as the authority for ambient-only generations" do
    assert {:ok, "clickhouse_etl"} =
             SourceMode.resolve([
               %{"source_mode" => "clickhouse_etl"},
               %{"source_mode" => "clickhouse_etl"}
             ])
  end

  test "rejects a directed agent callback beside ClickHouse" do
    assert {:error, :mixed_identity_source_mode} =
             SourceMode.resolve([
               %{"source_mode" => "clickhouse_etl"},
               %{
                 "source_mode" => "callback",
                 "addressing_kind" => "directed",
                 "actor_kind" => "agent"
               }
             ])
  end

  test "allows a scheduled recheck without changing ClickHouse authority" do
    assert {:ok, "clickhouse_etl"} =
             SourceMode.resolve([
               %{"source_mode" => "clickhouse_etl"},
               %{"source_mode" => "scheduled_recheck"}
             ])
  end

  test "rejects ambient callback ownership beside ClickHouse" do
    assert {:error, :mixed_identity_source_mode} =
             SourceMode.resolve([
               %{"source_mode" => "clickhouse_etl"},
               %{
                 "source_mode" => "callback",
                 "addressing_kind" => "ambient",
                 "actor_kind" => "human"
               }
             ])
  end

  test "rejects directed human callbacks from the ambient generation" do
    assert {:error, :mixed_identity_source_mode} =
             SourceMode.resolve([
               %{"source_mode" => "clickhouse_etl"},
               %{
                 "source_mode" => "callback",
                 "addressing_kind" => "directed",
                 "actor_kind" => "human"
               }
             ])
  end

  test "fails closed for empty, missing, or unknown source modes" do
    assert {:error, :invalid_identity_source_mode} = SourceMode.resolve([])

    assert {:error, :identity_source_mode_missing} =
             SourceMode.resolve([%{"source_mode" => "clickhouse_etl"}, %{}])

    assert {:error, :invalid_identity_source_mode} =
             SourceMode.resolve([%{"source_mode" => "unknown"}])
  end
end
