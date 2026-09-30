defmodule BridgeForTeams.RunChecksTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.RunChecks
  alias BridgeForTeams.RunChecks.GateContract

  test "bot check order includes the Google Calendar notification gate" do
    assert RunChecks.bot_gate_ids() == [
             "bot.credentials",
             "bot.callback",
             "bot.chat_access",
             "bot.calendar",
             "bot.first_message",
             "bot.manual"
           ]
  end

  test "serializes the shared dashboard result shape for CLI JSON output" do
    ran_at = ~U[2026-06-22 10:00:00Z]

    result = %{
      surface: "bot",
      org_ref: "org-1",
      project_ref: "project-1",
      connect_ref: "connect-1",
      ran_at: ran_at,
      gates: [
        %{
          gate_id: "bot.credentials",
          label: "App ID + Secret valid",
          status: :ok,
          reason_class: :validated,
          next_action: "No action required.",
          evidence: %{
            app_id: "cli_app",
            app_secret: "secret must not serialize",
            nested: %{verification_token: "token must not serialize"},
            scope_count: 3
          }
        },
        %{
          gate_id: "bot.calendar",
          label: "Google Calendar meeting notifications",
          required: false,
          status: :skipped,
          reason_class: :calendar_policy_not_configured,
          next_action: "Configure notifications only when wanted.",
          evidence: %{}
        }
      ]
    }

    assert %{
             "surface" => "bot",
             "org_ref" => "org-1",
             "project_ref" => "project-1",
             "connect_ref" => "connect-1",
             "ran_at" => "2026-06-22T10:00:00Z",
             "gates" => [gate, calendar_gate]
           } =
             result
             |> RunChecks.encode_json!(pretty: false)
             |> Jason.decode!()

    assert gate["gate_id"] == "bot.credentials"
    assert gate["label"] == "App ID + Secret valid"
    assert gate["status"] == "ok"
    assert gate["reason_class"] == "validated"
    assert gate["next_action"] == "No action required."
    assert gate["required"] == true
    assert gate["redacted"] == true
    assert gate["evidence"]["app_id"] == "cli_app"
    assert gate["evidence"]["app_secret"] == "[REDACTED]"
    assert gate["evidence"]["nested"]["verification_token"] == "[REDACTED]"
    assert gate["evidence"]["scope_count"] == 3
    assert calendar_gate["gate_id"] == "bot.calendar"
    assert calendar_gate["status"] == "skipped"
    assert calendar_gate["required"] == false
  end

  test "normalizes declared gate booleans with missing values meaning true" do
    assert [optional, legacy_optional, required] =
             GateContract.normalize_gates([
               %{gate_id: "optional", status: :skipped, required: false, redacted: true},
               %{
                 "gate_id" => "legacy",
                 "status" => "skipped",
                 "required" => "false",
                 "redacted" => "true"
               },
               %{gate_id: "required", status: :ok}
             ])

    assert optional["required"] == false
    assert optional["redacted"] == true
    assert legacy_optional["required"] == false
    assert legacy_optional["redacted"] == true
    assert required["required"] == true
    assert required["redacted"] == true
    assert GateContract.aggregate_status([optional, legacy_optional, required]) == "ok"
    assert GateContract.first_actionable([optional, legacy_optional, required]) == nil
  end
end
