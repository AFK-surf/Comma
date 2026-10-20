defmodule SalixIM.Triage.SourceModeTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.SourceMode

  # A ClickHouse generation keeps its authority beside another ClickHouse event
  # or a scheduled recheck; any callback beside it is a mixed source.
  for {name, second, expected} <- [
        {"keeps ClickHouse as the authority for ambient-only generations",
         %{"source_mode" => "clickhouse_etl"}, {:ok, "clickhouse_etl"}},
        {"rejects a directed agent callback beside ClickHouse",
         %{"source_mode" => "callback", "addressing_kind" => "directed", "actor_kind" => "agent"},
         {:error, :mixed_identity_source_mode}},
        {"allows a scheduled recheck without changing ClickHouse authority",
         %{"source_mode" => "scheduled_recheck"}, {:ok, "clickhouse_etl"}},
        {"rejects ambient callback ownership beside ClickHouse",
         %{"source_mode" => "callback", "addressing_kind" => "ambient", "actor_kind" => "human"},
         {:error, :mixed_identity_source_mode}},
        {"rejects directed human callbacks from the ambient generation",
         %{"source_mode" => "callback", "addressing_kind" => "directed", "actor_kind" => "human"},
         {:error, :mixed_identity_source_mode}}
      ] do
    @second second
    @expected expected
    test name do
      assert SourceMode.resolve([%{"source_mode" => "clickhouse_etl"}, @second]) == @expected
    end
  end
end
