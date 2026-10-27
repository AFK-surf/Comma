defmodule SalixStore.CodingSandboxesTest do
  use SystemsClock.Case, async: false

  alias SalixStore.CodingSandboxes
  alias SalixStore.Compute.WorkloadCredential

  setup do
    Process.put(:coding_tenant, "tnt_" <> SystemsRuntime.Proc.uuid())
    # The clock moves only when a test advances it.
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
    previous = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("k", 32)
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    :ok
  end

  # Compute's tables are shared by the suites: each test has a tenant of its own.
  defp create(conversation \\ "cnv_a", group \\ "grp_1") do
    CodingSandboxes.create(%{
      tenant_id: tenant(),
      group_id: group,
      conversation_id: conversation,
      workspace: "comma:" <> group,
      repo: %{"owner" => "acme", "name" => "api", "base_ref" => "main", "branch" => "comma/a"},
      agent_id: "agt_worker",
      start: %{"requester" => "agt_worker@agents.salix", "repo" => %{"owner" => "acme"}}
    })
  end

  defp tenant, do: Process.get(:coding_tenant)

  test "a coding Task gets one Workload, found by its conversation and its device" do
    assert {:ok, workload} = create()
    assert {:ok, ^workload} = create()

    assert workload.kind == "coding_sandbox"
    assert workload.generation == 1
    assert workload.observed_state == "pending"
    assert workload.spec["state"] == "starting"
    assert workload.spec["device_id"] == "dev-sbx-cnv_a"
    assert workload.spec["agent_id"] == "agt_worker"

    assert {:ok, %{id: id}} = CodingSandboxes.get_by_conversation(tenant(), "cnv_a")
    assert id == workload.id
    assert {:ok, %{id: ^id}} = CodingSandboxes.get_by_device(tenant(), "dev-sbx-cnv_a")
    assert {:error, :not_found} = CodingSandboxes.get_by_device("tnt_2", "dev-sbx-cnv_a")
    assert CodingSandboxes.device?("dev-sbx-cnv_a")
    refute CodingSandboxes.device?("dev-cloudvm-abc")
  end

  test "a new sandbox advances the generation, which retires the old station's connect credential" do
    {:ok, workload} = create()
    {:ok, old} = WorkloadCredential.issue_connect(workload.id, workload.generation)
    assert {:ok, _} = WorkloadCredential.verify_connect(old)

    {:ok, _} =
      CodingSandboxes.update(workload.id, fn w ->
        {:ok, Map.merge(w.spec, %{"state" => "stopped", "sandbox" => "t-a-g1"})}
      end)

    assert {:ok, next} = CodingSandboxes.advance(workload.id, %{"end" => nil})
    assert next.generation == 2
    assert next.allocation_id != workload.allocation_id
    assert next.spec["state"] == "starting"
    assert next.spec["sandbox"] == nil
    assert next.spec["device_id"] == workload.spec["device_id"]

    assert {:error, _} = WorkloadCredential.verify_connect(old)
    {:ok, current} = WorkloadCredential.issue_connect(next.id, next.generation)
    assert {:ok, %{id: id}} = WorkloadCredential.verify_connect(current)
    assert id == workload.id
  end

  test "due Workloads are claimed once until their lease ends" do
    {:ok, a} = create("cnv_a")
    {:ok, _b} = create("cnv_b")

    {:ok, _} =
      CodingSandboxes.update(a.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", nil)} end)

    # Other suites' Workloads may be due too: only this test's are looked at.
    mine = fn {:ok, claimed} -> Enum.filter(claimed, &(&1.spec["tenant_id"] == tenant())) end
    assert [claimed] = mine.(CodingSandboxes.claim_due(100, 60_000))
    assert claimed.spec["conversation_id"] == "cnv_b"
    assert [] = mine.(CodingSandboxes.claim_due(100, 60_000))

    SystemsClock.advance(61_000)
    assert [again] = mine.(CodingSandboxes.claim_due(100, 60_000))
    assert again.id == claimed.id
  end

  test "a Group's live sandboxes are those starting or ready" do
    {:ok, a} = create("cnv_a")
    {:ok, _} = create("cnv_b")
    {:ok, _} = create("cnv_c", "grp_2")
    assert CodingSandboxes.live_count(tenant(), "grp_1") == 2

    {:ok, stopped} =
      CodingSandboxes.update(a.id, fn w -> {:ok, Map.put(w.spec, "state", "stopped")} end)

    assert stopped.observed_state == "stopped"
    assert stopped.desired_state == "stopped"
    assert CodingSandboxes.live_count(tenant(), "grp_1") == 1
  end
end
