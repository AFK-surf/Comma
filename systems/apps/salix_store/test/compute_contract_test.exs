defmodule SalixStore.ComputeContractTest do
  use ExUnit.Case, async: true

  alias SalixStore.ComputeContract

  test "ready requires artifact, current controller, and admission" do
    base = %{
      readable: true,
      desired: "present",
      artifact_verified: true,
      host_healthy: true,
      controller_current: true,
      registration_active: true,
      admission: "accepting"
    }

    assert ComputeContract.ready?(base)
    refute ComputeContract.ready?(Map.put(base, :admission, "closed"))
    refute ComputeContract.ready?(Map.put(base, :controller_current, false))
  end

  test "unreadable local state is actionable and retains last-known observation" do
    assert "action_required" =
             ComputeContract.node_result(%{
               readable: false,
               desired: "present",
               installation: "unreadable",
               last_known: %{result: "ready"}
             })

    projection = ComputeContract.project_node(%{readable: false, last_known: %{result: "ready"}})
    assert projection.readable == false
    assert projection.last_known == %{result: "ready"}
  end

  test "operation contract keeps unknown distinct from failed" do
    attrs = %{
      operation_id: "op-1",
      request_id: "req-1",
      target_ref: "node-1",
      target_revision_or_generation: 2,
      connection_epoch: "9",
      outcome: :unknown_outcome
    }

    assert {:ok, %{outcome: "unknown", connection_epoch: "9"}} = ComputeContract.operation(attrs)

    assert {:error, {:invalid, :connection_epoch}} =
             ComputeContract.operation(%{attrs | connection_epoch: "0"})
  end

  test "workload contract rejects provider-native identity and old runtime kind" do
    assert :ok =
             ComputeContract.validate_workload("external_worker", [
               "runtime_exec",
               "runtime_process"
             ])

    assert {:error, :invalid_workload} = ComputeContract.validate_workload("external_runtime", [])

    assert {:error, :invalid_capability} =
             ComputeContract.validate_workload("service", ["container_id"])
  end
end
