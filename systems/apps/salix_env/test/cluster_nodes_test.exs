defmodule SalixEnv.ClusterNodesTest do
  use SystemsClock.Case, async: false

  alias SalixEnv.ClusterNodes

  test "unknown node-name churn does not create atoms" do
    assert ClusterNodes.find("warmup@comma.invalid") == nil
    before_count = :erlang.system_info(:atom_count)

    for suffix <- 1..1_000 do
      assert ClusterNodes.find("untrusted-#{suffix}@comma.invalid") == nil
    end

    assert :erlang.system_info(:atom_count) == before_count
  end
end
