defmodule SalixEnv.RuntimeAuthTest do
  use ExUnit.Case, async: true

  alias SalixEnv.RuntimeAuth

  @snapshot %{
    "schema_version" => 1,
    "status" => "unauthenticated",
    "mode" => "chatgpt",
    "requires_openai_auth" => true,
    "observed_at" => 1_787_020_000_000
  }

  test "accepts only the bounded provider-neutral V1 auth snapshot" do
    assert {:ok, @snapshot} = RuntimeAuth.validate_snapshot(@snapshot)

    assert {:ok, snapshot} =
             RuntimeAuth.validate_snapshot(%{
               "schema_version" => 1,
               "status" => "error",
               "requires_openai_auth" => true,
               "observed_at" => 1_787_020_000_001,
               "issue" => "login_failed"
             })

    refute Map.has_key?(snapshot, "mode")

    for invalid <- [
          Map.put(@snapshot, "schema_version", 2),
          Map.put(@snapshot, "status", "logged_in"),
          Map.put(@snapshot, "mode", "oauth_secret"),
          Map.put(@snapshot, "requires_openai_auth", 1),
          Map.put(@snapshot, "observed_at", 0),
          Map.put(@snapshot, "issue", "raw_error"),
          Map.put(@snapshot, "email", "private@example.test"),
          Map.put(@snapshot, "verification_url", "https://example.test"),
          Map.put(@snapshot, "user_code", "SECRET"),
          Map.put(@snapshot, "token", "SECRET"),
          Map.delete(@snapshot, "status")
        ] do
      assert {:error, :invalid_runtime_auth_snapshot} = RuntimeAuth.validate_snapshot(invalid)
    end
  end

  test "validates read, start, and cancel results without widening ceremony data" do
    now = System.system_time(:millisecond)

    assert {:ok, %{"auth" => @snapshot}} =
             RuntimeAuth.validate_result(:read, %{"auth" => @snapshot})

    active_read = %{
      "auth" => Map.put(@snapshot, "status", "pending"),
      "attempt_id" => "rta_123",
      "flow" => "device_code",
      "expires_at" => now + 900_000
    }

    assert {:ok, ^active_read} = RuntimeAuth.validate_result(:read, active_read)

    ceremony =
      Map.merge(active_read, %{
        "verification_url" => "https://auth.openai.com/codex/device",
        "user_code" => "ABCD-EFGH",
        "reused" => false
      })

    assert {:ok, ^ceremony} = RuntimeAuth.validate_result(:login_start, ceremony)

    canceled = %{
      "auth" => @snapshot,
      "attempt_id" => "rta_123",
      "canceled" => true
    }

    assert {:ok, ^canceled} = RuntimeAuth.validate_result(:login_cancel, canceled)

    for {operation, invalid} <- [
          {:read, Map.put(active_read, "user_code", "SECRET")},
          {:read, Map.delete(active_read, "expires_at")},
          {:login_start, Map.put(ceremony, "verification_url", "file:///tmp/secret")},
          {:login_start,
           Map.put(ceremony, "verification_url", "https://attacker.example/codex/device")},
          {:login_start, Map.put(ceremony, "verification_url", "https://auth.openai.com/device")},
          {:login_start,
           Map.put(ceremony, "verification_url", "https://auth.openai.com/codex/device/extra")},
          {:login_start, Map.put(ceremony, "verification_url", <<"https://", 0xFF>>)},
          {:login_start, Map.put(ceremony, "expires_at", now + 1_200_000)},
          {:login_start, Map.put(ceremony, "user_code", "unsafe\ncode")},
          {:login_start, Map.put(ceremony, "user_code", <<0xFF>>)},
          {:login_start, Map.put(ceremony, "token", "SECRET")},
          {:login_cancel, Map.put(canceled, "verification_url", "https://example.test")},
          {:login_cancel, Map.put(canceled, "canceled", false)},
          {:login_cancel, Map.put(canceled, "attempt_id", "unsafe/value")}
        ] do
      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(operation, invalid)
    end

    expired = Map.put(ceremony, "expires_at", now - 1)
    assert {:ok, ^expired} = RuntimeAuth.validate_result(:login_start, expired)
  end

  test "validates caller-controlled flow and opaque attempt ids" do
    assert :ok = RuntimeAuth.validate_flow("device_code")
    assert {:error, :invalid_runtime_auth_flow} = RuntimeAuth.validate_flow("browser")
    assert {:error, :invalid_runtime_auth_flow} = RuntimeAuth.validate_flow("/bin/sh")

    assert :ok = RuntimeAuth.validate_attempt_id("rta_abc-123")

    for invalid <- [
          nil,
          "",
          "unsafe/value",
          "unsafe\nvalue",
          <<0xFF>>,
          String.duplicate("a", 129)
        ] do
      assert {:error, :invalid_runtime_auth_attempt_id} =
               RuntimeAuth.validate_attempt_id(invalid)
    end
  end

  test "private input offers and receipts contain bounded context, never credential fields" do
    strings =
      ~w(actor_id tenant_id project_id target_kind workload_id device_id runtime_id provider backend method form attempt_id runtime_instance_id generation connection_epoch allocation_id allocation_generation native_generation auth_epoch)

    context =
      Map.new(strings, &{&1, ""})
      |> Map.merge(%{
        "actor_id" => "admin",
        "tenant_id" => "tenant",
        "project_id" => "project",
        "target_kind" => "compute_workload",
        "workload_id" => "workload",
        "runtime_instance_id" => "runtime",
        "generation" => "1",
        "connection_epoch" => "epoch",
        "allocation_id" => "allocation",
        "allocation_generation" => "1",
        "provider" => "codex",
        "backend" => "chatgpt",
        "method" => "credential_import",
        "form" => "codex_auth_file",
        "attempt_id" => "attempt",
        "native_generation" => "native",
        "auth_epoch" => "1",
        "schema_version" => 1,
        "sequence" => 1,
        "expires_at" => System.system_time(:millisecond) + 900_000
      })

    offer = %{
      "context" => context,
      "public_key" => Base.encode64(<<4, 0::512>>),
      "phase" => "awaiting_user",
      "save_result" => "not_committed"
    }

    assert {:ok, ^offer} = RuntimeAuth.validate_result(:input_begin, offer)

    claude_url =
      "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state"

    claude_offer =
      offer
      |> put_in(["context", "provider"], "claude")
      |> put_in(["context", "backend"], "anthropic")
      |> put_in(["context", "method"], "native_login")
      |> put_in(["context", "form"], "authorization_code")

    claude_start = Map.put(claude_offer, "verification_url", claude_url)
    assert {:ok, ^claude_start} = RuntimeAuth.validate_result(:login_start, claude_start)

    assert {:error, :invalid_runtime_auth_response} =
             RuntimeAuth.validate_result(
               :login_start,
               Map.put(
                 claude_start,
                 "verification_url",
                 String.replace(claude_url, "claude.com", "evil.example")
               )
             )

    assert {:error, :invalid_runtime_auth_response} =
             RuntimeAuth.validate_result(
               :login_start,
               Map.put(claude_start, "verification_url", claude_url <> "&state=other")
             )

    for invalid <- [
          Map.put(offer, "token", "secret"),
          Map.put(offer, "public_key", "bad"),
          put_in(offer, ["context", "actor_id"], ""),
          put_in(offer, ["context", "sequence"], 2),
          put_in(offer, ["context", "form"], "arbitrary_settings"),
          put_in(offer, ["context", "backend"], "arbitrary_endpoint"),
          put_in(offer, ["context", "private_key"], "secret"),
          put_in(offer, ["context", "allocation_generation"], String.duplicate("x", 257))
        ] do
      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(:input_begin, invalid)
    end

    for operation <- [:input_submit, :input_cancel] do
      receipt = %{"save_result" => "committed", "issue" => "storage_sync_failed"}
      assert {:ok, ^receipt} = RuntimeAuth.validate_result(operation, receipt)

      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(operation, Map.put(receipt, "file", "secret"))

      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(
                 operation,
                 Map.put(receipt, "issue", "raw provider output")
               )
    end
  end

  test "status rejects secret attempt fields and readiness without authentication evidence" do
    status = %{
      "provider" => "codex",
      "auth" => %{
        "schema_version" => 1,
        "status" => "unknown",
        "requires_openai_auth" => true,
        "observed_at" => System.system_time(:millisecond)
      },
      "native_ready" => true,
      "dispatch_ready" => false,
      "methods" => [
        %{
          "backend" => "openai",
          "method" => "credential_import",
          "form" => "api_key",
          "schema_version" => 1
        }
      ],
      "attempt" => %{
        "attempt_id" => "attempt",
        "expires_at" => System.system_time(:millisecond) + 900_000,
        "owned" => false,
        "phase" => "awaiting_user",
        "save_result" => "not_committed",
        "issue" => ""
      }
    }

    assert {:ok, ^status} = RuntimeAuth.validate_result(:status, status)

    claude_status = %{
      status
      | "provider" => "claude",
        "methods" => [
          %{
            "backend" => "anthropic",
            "method" => "verify",
            "form" => "api_key",
            "schema_version" => 1
          },
          %{
            "backend" => "openrouter",
            "method" => "verify",
            "form" => "api_key",
            "schema_version" => 1
          }
        ]
    }

    assert {:ok, ^claude_status} = RuntimeAuth.validate_result(:status, claude_status)

    assert {:error, :invalid_runtime_auth_response} =
             RuntimeAuth.validate_result(
               :status,
               put_in(claude_status, ["methods", Access.at(0), "backend"], "arbitrary")
             )

    for invalid <- [
          put_in(status, ["attempt", "public_key"], "private-ceremony"),
          put_in(status, ["attempt", "context"], %{}),
          Map.put(status, "dispatch_ready", true),
          Map.put(status, "methods", List.duplicate(hd(status["methods"]), 9)),
          put_in(status, ["attempt", "issue"], "raw native error")
        ] do
      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(:status, invalid)
    end
  end

  test "verification exposes only finite status and issue receipts" do
    for result <- [
          %{"status" => "authenticated", "issue" => ""},
          %{"status" => "error", "issue" => "permission_denied"},
          %{"status" => "unauthenticated", "issue" => "credentials_rejected"}
        ] do
      assert {:ok, ^result} = RuntimeAuth.validate_result(:verify, result)

      assert {:error, :invalid_runtime_auth_response} =
               RuntimeAuth.validate_result(:verify, Map.put(result, "provider_body", "secret"))
    end

    assert {:error, :invalid_runtime_auth_response} =
             RuntimeAuth.validate_result(:verify, %{
               "status" => "error",
               "issue" => "raw provider error"
             })
  end
end
