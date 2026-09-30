defmodule SalixEnv.ControlRuntimeAvailabilityTest do
  use ExUnit.Case, async: true

  alias SalixEnv.Control

  test "device names keep hostnames separate and preserve explicit renames" do
    record =
      environment("connected", runtime(%{}))
      |> put_in(["meta", "name"], "Default workspace Connector")
      |> put_in(["meta", "system_info"], %{
        "hostname" => "office-mini",
        "client_source" => "comma_dev"
      })

    assert Control.environment_json(record)["name"] == "Default workspace Connector"

    assert get_in(Control.environment_json(record), ["system_info", "client_source"]) ==
             "comma_dev"

    assert Control.environment_json(Map.put(record, "status", "disconnected"))["name"] ==
             "Default workspace Connector"

    renamed = Map.put(record, "display_name", "Studio")
    assert Control.environment_json(renamed)["name"] == "Studio"
    assert Control.environment_json(renamed)["display_name"] == "Studio"

    assert Control.environment_json(
             put_in(renamed, ["meta", "system_info", "hostname"], "new-host")
           )["name"] == "Studio"

    missing = put_in(record, ["meta", "system_info", "hostname"], " ")
    assert Control.environment_json(missing)["name"] == "Default workspace Connector"
  end

  test "Android profile metadata keeps bounded public fields" do
    projected =
      environment("connected", runtime(%{}))
      |> put_in(["meta", "capabilities"], %{
        "android" => %{
          "protocol_version" => 2,
          "profiles" => Enum.map(1..9, &"api#{&1}"),
          "profile_details" => [
            %{
              "id" => "api35-phone-google-apis",
              "api_level" => 35,
              "abi" => "x86_64",
              "image_flavor" => "google_apis",
              "status" => "installed",
              "avd_name" => "/private/agent-api35"
            }
          ],
          "default_profile" => "api35-phone-google-apis",
          "active_profile" => "api30-phone",
          "target_profile" => "api35-phone-google-apis",
          "state" => "preparing",
          "phase" => "waiting_ready",
          "capacity" => 1,
          "available_slots" => 0,
          "sdk_root" => "/private/android-sdk"
        }
      })
      |> Control.environment_json()
      |> get_in(["capabilities", "android"])

    assert projected["profiles"] == Enum.map(1..8, &"api#{&1}")

    assert projected["profile_details"] == [
             %{
               "id" => "api35-phone-google-apis",
               "api_level" => 35,
               "abi" => "x86_64",
               "image_flavor" => "google_apis",
               "status" => "installed"
             }
           ]

    assert projected["default_profile"] == "api35-phone-google-apis"
    assert projected["active_profile"] == "api30-phone"
    assert projected["target_profile"] == "api35-phone-google-apis"
    assert projected["state"] == "preparing"
    assert projected["phase"] == "waiting_ready"
    refute Map.has_key?(projected, "sdk_root")
    refute Map.has_key?(hd(projected["profile_details"]), "avd_name")
  end

  test "external runtime availability requires complete fresh readiness evidence" do
    now = System.system_time(:millisecond)

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

  test "missing probe facts are unavailable and expired facts are stale" do
    now = System.system_time(:millisecond)

    assert %{"status" => "unavailable", "issue" => "readiness_incomplete"} =
             environment("connected", runtime(%{}))
             |> Control.environment_json()
             |> only_runtime()

    stale =
      environment(
        "connected",
        runtime(%{
          "version_detected" => true,
          "auth_ready" => true,
          "native_server_startable" => true,
          "ready" => true,
          "readiness_checked_at" => now - 1_000,
          "readiness_valid_until" => now - 1
        })
      )
      |> Control.environment_json()
      |> only_runtime()

    assert %{"status" => "stale", "issue" => "readiness_expired"} = stale
    assert stale["updated_at"] == div(now - 1, 1_000)
  end

  test "connector loss invalidates ready without rewriting the probe" do
    now = System.system_time(:millisecond)

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

  test "failed readiness facts map to stable availability issues" do
    now = System.system_time(:millisecond)

    base = %{
      "version_detected" => true,
      "auth_ready" => true,
      "native_server_startable" => true,
      "ready" => true,
      "readiness_checked_at" => now,
      "readiness_valid_until" => now + 600_000
    }

    for {field, issue} <- [
          {"version_detected", "runtime_probe_failed"},
          {"auth_ready", "authentication_required"},
          {"native_server_startable", "native_server_unavailable"},
          {"ready", "runtime_probe_failed"}
        ] do
      assert %{"status" => "unavailable", "issue" => ^issue} =
               environment("connected", runtime(Map.put(base, field, false)))
               |> Control.environment_json()
               |> only_runtime()
    end
  end

  test "provider probe issue wins over overlapping false readiness booleans" do
    now = System.system_time(:millisecond)

    runtime =
      runtime(%{
        "version_detected" => true,
        "auth_ready" => false,
        "native_server_startable" => false,
        "ready" => false,
        "readiness_issue" => "native_server_unavailable",
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      })

    assert %{"status" => "unavailable", "issue" => "native_server_unavailable"} =
             environment("connected", runtime)
             |> Control.environment_json()
             |> only_runtime()
  end

  test "workspace readiness issue is preserved in public availability" do
    now = System.system_time(:millisecond)

    runtime =
      runtime(%{
        "version_detected" => true,
        "auth_ready" => true,
        "native_server_startable" => true,
        "ready" => false,
        "readiness_issue" => "workspace_unavailable",
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      })

    assert %{"status" => "unavailable", "issue" => "workspace_unavailable"} =
             environment("connected", runtime)
             |> Control.environment_json()
             |> only_runtime()
  end

  test "owner readiness message is projected without falling back to last_error" do
    now = System.system_time(:millisecond)

    runtime =
      runtime(%{
        "version_detected" => true,
        "auth_ready" => false,
        "native_server_startable" => false,
        "ready" => false,
        "readiness_issue" => "authentication_required",
        "readiness_message" => "Codex reports no authenticated account.",
        "last_error" => "Authorization: Bearer private-token",
        "readiness_checked_at" => now,
        "readiness_valid_until" => now + 600_000
      })

    assert %{
             "status" => "unavailable",
             "issue" => "authentication_required",
             "message" => "Codex reports no authenticated account."
           } =
             environment("connected", runtime)
             |> Control.environment_json()
             |> only_runtime()

    refute Map.has_key?(
             only_runtime(Control.environment_json(environment("connected", runtime))),
             "last_error"
           )
  end

  test "invalid owner readiness messages are omitted without changing status or issue" do
    now = System.system_time(:millisecond)

    for message <- ["", "unsafe\nmessage", String.duplicate("x", 301), <<0xFF>>] do
      runtime =
        runtime(%{
          "version_detected" => true,
          "auth_ready" => true,
          "native_server_startable" => true,
          "ready" => false,
          "readiness_issue" => "workspace_unavailable",
          "readiness_message" => message,
          "readiness_checked_at" => now,
          "readiness_valid_until" => now + 600_000
        })

      assert %{"status" => "unavailable", "issue" => "workspace_unavailable"} =
               projected =
               environment("connected", runtime) |> Control.environment_json() |> only_runtime()

      refute Map.has_key?(projected, "message")
    end
  end

  test "server-owned availability failures have deterministic messages" do
    now = System.system_time(:millisecond)

    runtime =
      runtime(%{
        "version_detected" => true,
        "auth_ready" => true,
        "native_server_startable" => true,
        "ready" => true,
        "readiness_checked_at" => now - 1_000,
        "readiness_valid_until" => now - 1
      })

    assert %{
             "status" => "stale",
             "issue" => "readiness_expired",
             "message" => "The last runtime readiness observation has expired."
           } =
             environment("connected", runtime)
             |> Control.environment_json()
             |> only_runtime()
  end

  defp environment(status, runtime) do
    now = System.system_time(:millisecond)

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
