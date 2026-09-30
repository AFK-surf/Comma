defmodule BridgeForTeams.RuntimeAuthTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.RuntimeAuth

  test "accepts only the official bounded Codex device-code ceremony" do
    now = System.system_time(:millisecond)

    ceremony = %{
      "attempt_id" => "rta_project",
      "flow" => "device_code",
      "verification_url" => "https://auth.openai.com/codex/device",
      "user_code" => "ABCD-EFGH",
      "expires_at" => now + 900_000,
      "reused" => false,
      "auth" => %{
        "schema_version" => 1,
        "status" => "pending",
        "mode" => "chatgpt",
        "requires_openai_auth" => true,
        "observed_at" => now
      }
    }

    assert {:ok, ^ceremony} = RuntimeAuth.project_start(ceremony)

    for verification_url <- [
          "https://attacker.example/codex/device",
          "https://auth.openai.com/device",
          "https://auth.openai.com/codex/device/extra",
          "https://auth.openai.com/codex/device?continue=attacker"
        ] do
      assert {:error, :invalid_runtime_auth_response} =
               ceremony
               |> Map.put("verification_url", verification_url)
               |> RuntimeAuth.project_start()
    end

    assert {:error, :invalid_runtime_auth_response} =
             ceremony
             |> Map.put("expires_at", now + 1_200_000)
             |> RuntimeAuth.project_start()

    expired = Map.put(ceremony, "expires_at", now - 1)
    assert {:ok, ^expired} = RuntimeAuth.project_start(expired)
  end
end
