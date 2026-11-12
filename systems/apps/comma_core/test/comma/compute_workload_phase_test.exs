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
      registrations: %{
        "registration" => %{
          connected: true,
          status: "ready",
          desired_enabled: true,
          current_connection_epoch: "8",
          device_id: nil,
          authorization_expires_at: ~U[2100-01-01 00:00:00Z]
        }
      },
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
               put_in(page, [:registrations, "registration", :device_id], "device")
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

  test "a member may retry a Shell or the Group's own Station when it needs action" do
    parked = %{"kind" => "action_required", "code" => "provider_command_outcome_unknown"}
    station = %{workload("service", "pending") | template_key: "station.default"}

    for {retryable, expected} <- [
          {workload("shell", "pending"), true},
          {%{station | owner_ref: %{"kind" => "group", "id" => "group"}}, true},
          # Another business owner recovers its own Workload.
          {%{station | owner_ref: %{"kind" => "meeting", "id" => "meeting"}}, false},
          {workload("meeting_runtime", "pending"), false}
        ] do
      assert %{"phase" => "action_required", "actions" => %{"retry" => ^expected}} =
               project(retryable, claim_error: parked)
    end
  end
end
