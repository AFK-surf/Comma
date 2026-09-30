defmodule BillingCommerce.ManualGrantCommandsTest do
  use ExUnit.Case, async: true

  alias BillingCommerce.ManualGrantCommands

  @expires_at "2099-08-01T00:00:00Z"

  test "prepares a stable Workspace-bound command and binds server-owned grant fields" do
    attrs = human_attrs()
    actor = %{"id" => "usr_admin"}
    contract = %{idempotency_key: "issue-credit:12345678", reason: "Approved support grant"}
    target = %{workspace_id: "wsp_1", billing_account_id: "example-ba-wsp_1"}

    assert {:ok, prepared} =
             ManualGrantCommands.prepare_human_issue(attrs, actor, contract, target)

    assert prepared.target_type == "workspace"
    assert prepared.target_id == "wsp_1"

    assert prepared.expected_confirmation ==
             "issue-workspace-credits:wsp_1:comma_support:2026-07"

    assert {:ok, repeated} =
             ManualGrantCommands.prepare_human_issue(
               %{attrs | "package_code" => "  comma_support  "},
               actor,
               contract,
               target
             )

    assert repeated.fingerprint == prepared.fingerprint

    bound = ManualGrantCommands.bind_admin_command(prepared.command, "audit-command-id")

    assert bound.billing_account_id == "example-ba-wsp_1"
    assert bound.workspace_id == "wsp_1"
    assert bound.package_code == "comma_support"
    assert bound.package_version == "2026-07"
    assert bound.source_type == "manual_adjustment"
    assert bound.source_id == "comma_admin:wsp_1"
    assert bound.source_event_id == "audit-command-id"
    assert bound.idempotency_key == "comma_admin_grant:audit-command-id"
    assert bound.enforce_product_owner_identity == true

    assert bound.operator == %{
             "id" => "usr_admin",
             "type" => "comma_admin_user",
             "reason" => "Approved support grant"
           }

    assert %DateTime{} = bound.valid_from
    assert bound.expires_at == ~U[2099-08-01 00:00:00Z]
    assert bound.metadata["admin_command_id"] == "audit-command-id"
  end

  test "rejects every browser attempt to provide owner, operator, source, or timing fields" do
    for forbidden <- [
          %{"billing_account_id" => "spoofed"},
          %{"workspace_id" => "spoofed"},
          %{"operator" => %{"id" => "spoofed"}},
          %{"source_type" => "manual_contract"},
          %{"source_id" => "spoofed"},
          %{"source_event_id" => "spoofed"},
          %{"valid_from" => @expires_at},
          %{"metadata" => %{"spoofed" => true}}
        ] do
      assert {:error, :invalid_manual_grant} =
               ManualGrantCommands.prepare_human_issue(
                 Map.merge(human_attrs(), forbidden),
                 %{"id" => "usr_admin"},
                 %{idempotency_key: "issue-credit:12345678", reason: "Approved support grant"},
                 %{workspace_id: "wsp_1", billing_account_id: "example-ba-wsp_1"}
               )
    end
  end

  test "requires an explicit expiry and defers mutable-time validation to issuance" do
    contract = %{idempotency_key: "issue-credit:12345678", reason: "Approved support grant"}
    actor = %{"id" => "usr_admin"}
    target = %{workspace_id: "wsp_1", billing_account_id: "example-ba-wsp_1"}

    for expires_at <- [nil, "not-a-date"] do
      attrs =
        if expires_at,
          do: Map.put(human_attrs(), "expires_at", expires_at),
          else: Map.delete(human_attrs(), "expires_at")

      assert {:error, :invalid_manual_grant} =
               ManualGrantCommands.prepare_human_issue(attrs, actor, contract, target)
    end

    assert {:ok, expired_retry} =
             ManualGrantCommands.prepare_human_issue(
               Map.put(human_attrs(), "expires_at", "2020-01-01T00:00:00Z"),
               actor,
               contract,
               target
             )

    assert expired_retry.command.expires_at == ~U[2020-01-01 00:00:00Z]

    assert {:error, :invalid_manual_grant} =
             ManualGrantCommands.prepare_human_issue(
               human_attrs(),
               actor,
               contract,
               %{workspace_id: "wsp_1"}
             )
  end

  defp human_attrs do
    %{
      "confirmation" => "issue-workspace-credits:wsp_1:comma_support:2026-07",
      "expires_at" => @expires_at,
      "idempotency_key" => "issue-credit:12345678",
      "package_code" => "comma_support",
      "package_version" => "2026-07",
      "reason" => "Approved support grant"
    }
  end
end
