defmodule Comma.ComputeWorkloadPhaseTest do
  use ExUnit.Case, async: true

  alias SalixStore.Compute.{
    Allocation,
    ProviderBinding,
    ReconcilerClaim,
    RuntimeInstance,
    Workload
  }

  defp page(workload, opts) do
    facts =
      Keyword.get(opts, :facts, %{
        "container_status" => "running",
        "runtime_verified_host_epoch" => "8"
      })

    %{
      allocations: [
        %Allocation{
          id: "allocation",
          provider_binding_id: "binding",
          status: "ready",
          provider_observation: facts
        }
      ],
      bindings: [
        %ProviderBinding{
          id: "binding",
          provider: "agent_vmm",
          provider_ref: "registration",
          status: "available",
          observation: %{"connection_epoch" => "8"}
        }
      ],
      runtimes: Keyword.get(opts, :runtimes, []),
      claims:
        for error <- List.wrap(Keyword.get(opts, :claim_error)) do
          %ReconcilerClaim{workload_id: workload.id, generation: 1, last_error: error}
        end
    }
  end

  defp workload(kind, observed_state \\ "ready") do
    %Workload{
      id: "workload",
      kind: kind,
      allocation_id: "allocation",
      environment_id: "environment",
      desired_state: "ready",
      observed_state: observed_state,
      generation: 1,
      revision: 1
    }
  end

  defp project(workload, opts \\ []),
    do: Comma.Compute.public_workload_phase(workload, page(workload, opts))

  test "an Agent VMM location names the registration's Comma Device" do
    workload = workload("service")
    page = page(workload, [])

    assert %{"location" => %{"registration_id" => "registration", "device_id" => "device"}} =
             Comma.Compute.public_workload_phase(
               workload,
               Map.put(page, :registration_devices, %{"registration" => "device"})
             )

    # A missing registration has no Device.
    assert %{"location" => %{"registration_id" => "registration", "device_id" => nil}} =
             Comma.Compute.public_workload_phase(workload, page)
  end

  test "a service on an Agent VMM Host is ready from its verified container facts" do
    assert %{"phase" => "ready", "problem" => nil} = project(workload("service"))

    # Facts verified before the Host reconnected do not prove the container.
    stale = %{"container_status" => "running", "runtime_verified_host_epoch" => "7"}
    assert %{"phase" => "starting"} = project(workload("service"), facts: stale)

    stopped = %{"container_status" => "stopped", "runtime_verified_host_epoch" => "8"}
    assert %{"phase" => "starting"} = project(workload("service"), facts: stopped)
    assert %{"phase" => "starting"} = project(workload("service", "pending"))
  end

  test "a meeting runtime stays gated on its runtime readiness" do
    assert %{"phase" => "unknown"} = project(workload("meeting_runtime"))

    runtime = %RuntimeInstance{workload_id: "workload", generation: 1, readiness: "ready"}
    assert %{"phase" => "ready"} = project(workload("meeting_runtime"), runtimes: [runtime])

    catching_up = %{runtime | readiness: "catching_up"}

    assert %{"phase" => "starting"} =
             project(workload("meeting_runtime"), runtimes: [catching_up])
  end

  test "the current claim's last error is a bounded problem code" do
    pending = workload("service", "pending")

    for {error, problem} <- [
          {%{"kind" => "error", "reason" => ":runtime_instance_changed"},
           %{"code" => "runtime_instance_changed", "retryable" => true}},
          {%{"kind" => "error", "reason" => "{:gateway_status, 502}"},
           %{"code" => "host_unreachable", "retryable" => true}},
          {%{"kind" => "provider_error", "code" => "unavailable", "message" => "raw host text"},
           %{"code" => "host_unreachable", "retryable" => true}},
          {%{"kind" => "error", "reason" => ":imported_image_not_observed"},
           %{"code" => "image_unavailable", "retryable" => true}},
          {%{
             "kind" => "action_required",
             "code" => "resource_capacity_exhausted",
             "resource" => "storage_headroom"
           }, %{"code" => "capacity_unavailable", "retryable" => false}},
          {%{"kind" => "action_required", "code" => "container_start_evidence_unavailable"},
           %{"code" => "other", "retryable" => false}},
          {%{"kind" => "unknown", "result" => "{:ok, %{weird: true}}"},
           %{"code" => "other", "retryable" => true}}
        ] do
      assert project(pending, claim_error: error)["problem"] == problem
    end

    # A claim without an error, or with only retry bookkeeping, has no problem.
    assert project(pending, claim_error: %{})["problem"] == nil

    assert project(pending, claim_error: %{"runtime_recovery_deadline" => "2026-01-01T00:00:00Z"})[
             "problem"
           ] == nil

    # The problem is additive: the phase stays computed from the facts.
    assert %{"phase" => "starting"} =
             project(pending, claim_error: %{"kind" => "error", "reason" => ":timeout"})
  end
end

defmodule Comma.ComputeRegistrationDevicesTest do
  use ExUnit.Case, async: false

  alias SalixStore.AgentVMM.Registration
  alias SalixStore.Compute.ProviderBinding

  setup do
    SalixStore.RepoTestSetup.ensure!()
    :ok
  end

  test "a page reads the Devices of all its registrations in one query" do
    suffix = SystemsRuntime.Proc.uuid()
    now = SystemsClock.utc_now()

    ids =
      for n <- 1..5 do
        id = "reg-#{n}-#{suffix}"

        SalixStore.Repo.insert!(%Registration{
          id: id,
          credential_hash: "credential",
          tenant_id: "tenant-#{suffix}",
          group_id: "group",
          device_id: "device-#{n}",
          status: "ready",
          desired_enabled: true,
          revision: 1,
          policy_revision: 1,
          next_controller_sequence: 1,
          created_at: now,
          updated_at: now
        })

        id
      end

    bindings =
      Enum.map(ids, &%ProviderBinding{provider: "agent_vmm", provider_ref: &1}) ++
        [
          %ProviderBinding{provider: "agent_vmm", provider_ref: "missing-#{suffix}"},
          %ProviderBinding{provider: "cloudflare", provider_ref: hd(ids)}
        ]

    handler = "registration-devices-#{suffix}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _event, _measurements, %{source: source}, _ ->
        if self() == test_pid, do: send(test_pid, {:query, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Comma.Compute.registration_devices(bindings) ==
             Map.new(Enum.with_index(ids, 1), fn {id, n} -> {id, "device-#{n}"} end)

    assert_received {:query, "agent_vmm_registrations"}
    refute_received {:query, _}

    assert Comma.Compute.registration_devices([%ProviderBinding{provider: "cloudflare"}]) == %{}
    refute_received {:query, _}
  end
end
