defmodule SalixEnv.ControlLanGatewayTest do
  use SystemsClock.Case, async: true

  alias SalixEnv.Control

  @probes %{
    "max_probes" => 4,
    "max_payload_bytes" => 256,
    "max_answer_bytes" => 1024,
    "max_total_answer_bytes" => 4096
  }
  @chunks %{"max_total_bytes" => 4_194_304, "chunk_bytes" => 8192}

  test "a gateway's probe and chunk limits reach the device and its environment" do
    projected =
      device(%{
        "methods" => ["lan_http_request", "lan_discover", "unknown"],
        "max_bytes" => 65_536,
        "max_timeout_seconds" => 30,
        "discover_probes" => Map.put(@probes, "other", 1),
        "response_chunks" => @chunks,
        "other" => true
      })
      |> Control.environment_json()

    expected = %{
      "methods" => ["lan_http_request", "lan_discover"],
      "max_bytes" => 65_536,
      "max_timeout_seconds" => 30,
      "discover_probes" => @probes,
      "response_chunks" => @chunks
    }

    assert projected["capabilities"]["lan_gateway"] == expected
    assert [%{"capabilities" => %{"lan_gateway" => ^expected}}] = projected["environments"]
  end

  test "limits that are not positive integers are left out" do
    projected =
      device(%{
        "methods" => ["lan_discover"],
        "discover_probes" => %{"max_probes" => 0, "max_payload_bytes" => "256"},
        "response_chunks" => true
      })
      |> Control.environment_json()

    assert projected["capabilities"]["lan_gateway"] == %{"methods" => ["lan_discover"]}
  end

  defp device(lan_gateway) do
    now = SystemsClock.system_time(:millisecond)

    %{
      "connector_run_id" => "connector-run",
      "tenant_id" => "tenant",
      "group_id" => "group",
      "device_id" => "device",
      "connector_id" => "connector",
      "status" => "connected",
      "registered_at" => now,
      "updated_at" => now,
      "meta" => %{
        "tenant_id" => "tenant",
        "group_id" => "group",
        "device_id" => "device",
        "capabilities" => %{"exec" => true, "lan_gateway" => lan_gateway}
      }
    }
  end
end
