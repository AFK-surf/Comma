System.put_env("BRIDGE_TOB_ACCEPTANCE_REPORT_SKIP_RUN", "true")
Code.require_file("../../../scripts/bridge_tob_acceptance_report.exs", __DIR__)

defmodule BridgeToB.AcceptanceReportTest do
  use SystemsClock.Case, async: true

  test "sanitizes secret-like evidence fields but keeps redacted prefixes" do
    sanitized =
      BridgeToB.AcceptanceReport.sanitize(%{
        "verification_token" => "real-token",
        "raw_body" => "full payload",
        "user_email" => "person@example.com",
        "chat_id" => "oc_real",
        "chat_id_prefix" => "oc_reda",
        "limits" => %{"raw_chat_id_redacted" => true, "app_id_redacted" => true}
      })

    assert sanitized["verification_token"] == "[redacted]"
    assert sanitized["raw_body"] == "[redacted]"
    assert sanitized["user_email"] == "[redacted]"
    assert sanitized["chat_id"] == "[redacted]"
    assert sanitized["chat_id_prefix"] == "oc_reda"
    assert sanitized["limits"]["raw_chat_id_redacted"] == true
    assert sanitized["limits"]["app_id_redacted"] == true
  end
end
