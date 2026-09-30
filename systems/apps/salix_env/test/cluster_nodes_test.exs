defmodule SalixEnv.ClusterNodesTest do
  use ExUnit.Case, async: false

  alias SalixEnv.ClusterNodes

  test "resolves only the local node or an already connected peer" do
    assert ClusterNodes.find(node()) == node()
    assert ClusterNodes.find(Atom.to_string(node())) == node()
    assert ClusterNodes.find("unknown@comma.invalid") == nil
    assert ClusterNodes.find(:unknown_node_identity) == nil
  end

  test "unknown node-name churn does not create atoms" do
    assert ClusterNodes.find("warmup@comma.invalid") == nil
    before_count = :erlang.system_info(:atom_count)

    for suffix <- 1..1_000 do
      assert ClusterNodes.find("untrusted-#{suffix}@comma.invalid") == nil
    end

    assert :erlang.system_info(:atom_count) == before_count
  end
end
