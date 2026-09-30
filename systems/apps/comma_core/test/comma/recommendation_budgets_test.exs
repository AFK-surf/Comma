defmodule Comma.RecommendationBudgetsTest do
  use ExUnit.Case, async: true

  alias Comma.RecommendationBudgets

  test "source collection fits inside the complete eight-minute generation budget" do
    source_waves =
      div(
        RecommendationBudgets.max_sources() +
          RecommendationBudgets.max_source_concurrency() - 1,
        RecommendationBudgets.max_source_concurrency()
      )

    assert source_waves * RecommendationBudgets.source_read_timeout_ms() <=
             RecommendationBudgets.source_collection_timeout_ms()

    assert RecommendationBudgets.source_collection_timeout_ms() == 30_000
    assert RecommendationBudgets.run_hard_cap_seconds() == 480

    assert RecommendationBudgets.source_collection_timeout_ms() <
             RecommendationBudgets.run_hard_cap_seconds() * 1_000

    assert RecommendationBudgets.valid?()
  end
end
