defmodule SalixEnv.ControlRuntimeAvailabilityTest do
  use SystemsClock.Case, async: true

  alias SalixEnv.Control

  test "external runtime availability requires complete fresh readiness evidence" do
    now = SystemsClock.system_time(:millisecond)

    runtime =
      runtime(%{
        "version_detected" => true,
        "auth_ready" => true,
        "native_server_startable" => true,
        "ready" => true,
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      })

    projected = environment("connected", runtime) |> Control.environment_json()

    assert %{"status" => "ready"} = only_runtime(projected)

    assert [
             %{"provider" => "connector"},
             %{
               "provider" => "codex",
               "status" => "ready",
               "device_id" => "device",
               "device_runtime_id" => "device-runtime",
               "runtime_id" => "runtime"
             }
           ] = projected["device_runtimes"]

    refute Map.has_key?(only_runtime(projected), "connector_id")
  end

  test "connector loss invalidates ready without rewriting the probe" do
    now = SystemsClock.system_time(:millisecond)

    assert %{"status" => "disconnected", "issue" => "connector_disconnected"} =
             environment(
               "disconnected",
               runtime(%{
                 "version_detected" => true,
                 "auth_ready" => true,
                 "native_server_startable" => true,
                 "ready" => true,
                 "readiness_checked_at" => now,
                 "readiness_valid_until" => now + 600_000
               })
             )
             |> Control.environment_json()
             |> only_runtime()
  end

  defp environment(status, runtime) do
    now = SystemsClock.system_time(:millisecond)

    %{
      "connector_run_id" => "connector-run",
      "tenant_id" => "tenant",
      "group_id" => "group",
      "device_id" => "device",
      "connector_id" => "connector",
      "status" => status,
      "registered_at" => now,
      "updated_at" => now,
      "meta" => %{
        "tenant_id" => "tenant",
        "group_id" => "group",
        "device_id" => "device",
        "connector_id" => "connector",
        "agent_runtimes" => [runtime]
      }
    }
  end

  defp runtime(attrs) do
    Map.merge(
      %{
        "kind" => "external",
        "provider" => "codex",
        "runtime_id" => "runtime",
        "device_runtime_id" => "device-runtime"
      },
      attrs
    )
  end

  defp only_runtime(%{"device_runtimes" => runtimes}),
    do: Enum.find(runtimes, &(&1["provider"] == "codex"))
end
