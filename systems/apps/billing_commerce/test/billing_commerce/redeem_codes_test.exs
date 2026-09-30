defmodule BillingCommerce.RedeemCodesTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.{PackageCatalog, RedeemCodes, Subscriptions}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)

    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    Application.put_env(:billing_commerce, :billing_source_typed_sink, __MODULE__.ProjectionSink)

    on_exit(fn ->
      Application.delete_env(:billing_commerce, :billing_source_typed_sink)
    end)

    seed_package("comma_redeem_once", "comma", "one_time")
    seed_package("bridge_redeem_sub", "bridge", "subscription")
    :ok
  end

  test "admin creates, lists, disables, and audits hash-only redeem codes" do
    assert {:ok, %{code: code, id: code_id} = redeem_code} =
             RedeemCodes.create_code(%{
               code: "comma-free-month",
               package_code: "comma_redeem_once",
               package_version: "2026-06",
               code_type: "one_time_package",
               surface: "comma",
               max_redemptions: 10,
               valid_from: ~U[2026-06-01 00:00:00Z],
               metadata: %{"campaign" => "support"}
             })

    assert code == "COMMA-FREE-MONTH"
    assert redeem_code.display_prefix == "COMMA-FR"
    assert redeem_code.package_code == "comma_redeem_once"
    assert redeem_code.code_hash != code
    refute stored_code_hash(code_id) == code
    assert {:ok, %{data: [listed | _]}} = RedeemCodes.list_codes()
    assert listed.id == code_id
    refute Map.has_key?(listed, :code)

    assert {:ok, disabled} = RedeemCodes.disable_code(%{id: code_id})
    assert disabled.status == "disabled"
    assert {:ok, %{data: []}} = RedeemCodes.list_redemptions(%{redeem_code_id: code_id})
  end

  test "admin command id deduplicates code creation without replaying plaintext" do
    attrs = %{
      admin_command_id: Ecto.UUID.generate(),
      code: "comma-admin-command-once",
      package_code: "comma_redeem_once",
      package_version: "2026-06",
      code_type: "one_time_package",
      surface: "comma",
      valid_from: ~U[2026-06-01 00:00:00Z]
    }

    assert {:ok, %{id: code_id, code: "COMMA-ADMIN-COMMAND-ONCE"}} =
             RedeemCodes.create_code(attrs)

    assert {:already_applied, replay} = RedeemCodes.create_code(attrs)
    assert replay.id == code_id
    refute Map.has_key?(replay, :code)
  end

  test "custom codes shorter than the persisted display prefix are rejected" do
    assert {:error, :invalid_redeem_code} =
             RedeemCodes.create_code(%{
               code: "free",
               package_code: "comma_redeem_once",
               package_version: "2026-06",
               code_type: "one_time_package",
               surface: "comma",
               valid_from: ~U[2026-06-01 00:00:00Z]
             })

    assert {:ok, %{data: codes}} = RedeemCodes.list_codes()
    refute Enum.any?(codes, &(&1.display_prefix == "FREE"))
  end

  test "custom code length and display prefix preserve complete Unicode characters" do
    assert {:error, :invalid_redeem_code} =
             RedeemCodes.create_code(%{
               code: "密码密码密码密码",
               package_code: "comma_redeem_once",
               package_version: "2026-06",
               code_type: "one_time_package",
               surface: "comma",
               valid_from: ~U[2026-06-01 00:00:00Z]
             })

    assert {:ok, %{data: []}} = RedeemCodes.list_codes()

    assert {:ok, created} =
             RedeemCodes.create_code(%{
               code: "密码密码密码密码锁",
               package_code: "comma_redeem_once",
               package_version: "2026-06",
               code_type: "one_time_package",
               surface: "comma",
               valid_from: ~U[2026-06-01 00:00:00Z]
             })

    assert created.display_prefix == "密码密码密码密码"
    assert String.valid?(created.display_prefix)
    refute created.display_prefix == created.code
  end

  test "provided non-string custom codes are rejected instead of generating a code" do
    for code <- [123_456_789, false] do
      assert {:error, :invalid_redeem_code} =
               RedeemCodes.create_code(%{
                 code: code,
                 package_code: "comma_redeem_once",
                 package_version: "2026-06",
                 code_type: "one_time_package",
                 surface: "comma",
                 valid_from: ~U[2026-06-01 00:00:00Z]
               })
    end

    assert {:ok, %{data: []}} = RedeemCodes.list_codes()
  end

  test "invalid create fields return validation errors without persisting a code" do
    for attrs <- [
          %{expires_at: "not-a-date"},
          %{package_code: nil},
          %{package_version: 202_607},
          %{surface: false},
          %{max_redemptions: 0},
          %{max_redemptions: 2.5},
          %{max_redemptions: 2_147_483_648},
          %{max_redemptions: 1, per_account_limit: 2},
          %{metadata: ["not", "a", "map"]}
        ] do
      assert {:error, :invalid_redeem_code} =
               RedeemCodes.create_code(
                 Map.merge(
                   %{
                     code: "comma-valid-create-code",
                     package_code: "comma_redeem_once",
                     package_version: "2026-06",
                     code_type: "one_time_package",
                     surface: "comma",
                     valid_from: ~U[2026-06-01 00:00:00Z]
                   },
                   attrs
                 )
               )
    end

    assert {:ok, %{data: []}} = RedeemCodes.list_codes()
  end

  test "an applied redemption remains recoverable after its code is disabled or expires" do
    {:ok, %{code: code, id: code_id}} =
      RedeemCodes.create_code(%{
        code: "comma-recovery-apply",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z],
        expires_at: ~U[2026-07-01 00:00:00Z]
      })

    attrs =
      apply_attrs(%{
        code: code,
        billing_account_id: "example-ba-wsp_recovery_apply",
        product_owner_id: "wsp_recovery_apply",
        idempotency_key: "redeem:recovery:1",
        source_event_id: "admin-command-recovery",
        at: ~U[2026-06-15 00:00:00Z]
      })

    assert {:ok, %{redemption: redemption, idempotent: false}} =
             RedeemCodes.apply_code(attrs)

    assert {:ok, %{status: "disabled"}} = RedeemCodes.disable_code(%{id: code_id})

    assert {:ok, %{redemption: recovered, idempotent: true}} =
             attrs
             |> Map.put(:at, ~U[2026-08-01 00:00:00Z])
             |> RedeemCodes.apply_code()

    assert recovered.id == redemption.id
    assert grant_count("example-ba-wsp_recovery_apply") == 1

    assert {:error, :redeem_idempotency_key_conflict} =
             attrs
             |> Map.put(:product_owner_id, "wsp_other")
             |> RedeemCodes.apply_code()
  end

  test "one-time package redeem creates one redemption and redeem_one_time grant" do
    {:ok, %{code: code, id: code_id}} =
      RedeemCodes.create_code(%{
        code: "comma-once-1",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:ok, %{redemption: redemption, grant: grant, idempotent: false}} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: code,
                 billing_account_id: "example-ba-wsp_redeem_once",
                 surface: "comma",
                 product_owner_type: "workspace",
                 product_owner_id: "wsp_redeem_once",
                 idempotency_key: "redeem:once:1"
               })
             )

    assert redemption.redeem_code_id == code_id
    assert redemption.status == "applied"
    assert grant.remaining_credits == 700

    assert %{
             source_type: "redeem_one_time",
             source_id: source_id,
             valid_from: valid_from,
             expires_at: expires_at
           } = grant_source(grant.id)

    assert source_id == redemption.source_id
    assert DateTime.compare(valid_from, ~U[2026-06-01 00:00:00Z]) == :eq
    assert DateTime.compare(expires_at, ~U[2026-07-01 00:00:00Z]) == :eq

    assert {:ok, %{redemption: retry_redemption, grant: nil, idempotent: true}} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: code,
                 billing_account_id: "example-ba-wsp_redeem_once",
                 surface: "comma",
                 product_owner_type: "workspace",
                 product_owner_id: "wsp_redeem_once",
                 idempotency_key: "redeem:once:1"
               })
             )

    assert retry_redemption.id == redemption.id
    assert grant_count("example-ba-wsp_redeem_once") == 1

    assert Enum.any?(
             Agent.get(__MODULE__.ProjectionLog, & &1),
             &(&1["event_kind"] == "redeem_applied" and &1["source_type"] == "redeem_one_time")
           )

    assert {:error, :redeem_code_account_limit_reached} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: code,
                 billing_account_id: "example-ba-wsp_redeem_once",
                 surface: "comma",
                 product_owner_type: "workspace",
                 product_owner_id: "wsp_redeem_once",
                 idempotency_key: "redeem:once:2"
               })
             )

    assert grant_count("example-ba-wsp_redeem_once") == 1

    {:ok, %{code: other_code, id: other_code_id}} =
      RedeemCodes.create_code(%{
        code: "comma-once-2",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:ok, %{redemption: %{redeem_code_id: ^other_code_id}}} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: other_code,
                 billing_account_id: "example-ba-wsp_redeem_other",
                 surface: "comma",
                 product_owner_type: "workspace",
                 product_owner_id: "wsp_redeem_other",
                 idempotency_key: "redeem:other:1"
               })
             )

    assert {:ok, %{data: [%{status: "applied", redeem_code_id: ^code_id}]}} =
             RedeemCodes.list_redemptions(%{redeem_code_id: code_id})

    assert {:error, :invalid_redeem_code_id} = RedeemCodes.list_redemptions()

    assert {:error, :invalid_redeem_code_id} =
             RedeemCodes.list_redemptions(%{redeem_code_id: " "})
  end

  test "internal subscription redeem creates schedule and scheduler issues redeem_subscription_cycle grant" do
    {:ok, %{code: code}} =
      RedeemCodes.create_code(%{
        code: "bridge-sub-1",
        package_code: "bridge_redeem_sub",
        package_version: "2026-06",
        code_type: "internal_subscription",
        surface: "bridge",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:ok, %{redemption: redemption, subscription: subscription, cycles: [cycle]}} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: code,
                 billing_account_id: "bridge-ba-org_redeem_sub",
                 surface: "bridge",
                 product_owner_type: "organization",
                 product_owner_id: "org_redeem_sub",
                 idempotency_key: "redeem:sub:1"
               })
             )

    assert redemption.source_id == subscription.id
    assert cycle.grant_source_type == "redeem_subscription_cycle"

    assert {:ok, %{cycles: [%{grant: grant}]}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-06-02 00:00:00Z], limit: 10})

    assert %{source_type: "redeem_subscription_cycle"} = grant_source(grant.id)
    assert grant_count("bridge-ba-org_redeem_sub") == 1
  end

  test "redeem codes reject package surface mismatches" do
    assert {:error, :package_surface_mismatch} =
             RedeemCodes.create_code(%{
               code: "comma-bridge-mismatch",
               package_code: "bridge_redeem_sub",
               package_version: "2026-06",
               code_type: "internal_subscription",
               surface: "comma",
               valid_from: ~U[2026-06-01 00:00:00Z]
             })
  end

  test "redeem apply cannot mutate an existing account to another surface" do
    {:ok, %{code: code}} =
      RedeemCodes.create_code(%{
        code: "bridge-existing-comma",
        package_code: "bridge_redeem_sub",
        package_version: "2026-06",
        code_type: "internal_subscription",
        surface: "bridge",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    insert_billing_account!("example-ba-wsp_existing_redeem", "comma", "workspace", "wsp_existing")

    assert {:error, :billing_account_surface_mismatch} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: code,
                 billing_account_id: "example-ba-wsp_existing_redeem",
                 surface: "bridge",
                 product_owner_type: "organization",
                 product_owner_id: "org_existing",
                 idempotency_key: "redeem:existing-surface"
               })
             )

    assert account_surface("example-ba-wsp_existing_redeem") == "comma"
    assert grant_count("example-ba-wsp_existing_redeem") == 0
  end

  test "apply rejects expired, disabled, scope mismatch, maxed, and duplicate account redemptions" do
    {:ok, %{code: expired}} =
      RedeemCodes.create_code(%{
        code: "comma-expired-1",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-05-01 00:00:00Z],
        expires_at: ~U[2026-06-01 00:00:00Z]
      })

    assert {:error, :redeem_code_expired} =
             RedeemCodes.apply_code(apply_attrs(%{code: expired, idempotency_key: "expired"}))

    {:ok, %{code: disabled, id: disabled_id}} =
      RedeemCodes.create_code(%{
        code: "comma-disabled-1",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    {:ok, _} = RedeemCodes.disable_code(%{id: disabled_id})

    assert {:error, :redeem_code_disabled} =
             RedeemCodes.apply_code(apply_attrs(%{code: disabled, idempotency_key: "disabled"}))

    {:ok, %{code: scoped}} =
      RedeemCodes.create_code(%{
        code: "comma-scoped-1",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        scope_product_owner_type: "workspace",
        scope_product_owner_id: "wsp_allowed",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:error, :redeem_scope_mismatch} =
             RedeemCodes.apply_code(apply_attrs(%{code: scoped, idempotency_key: "scope"}))

    {:ok, %{code: maxed}} =
      RedeemCodes.create_code(%{
        code: "comma-maxed-1",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        max_redemptions: 1,
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:ok, _} =
             RedeemCodes.apply_code(apply_attrs(%{code: maxed, idempotency_key: "maxed-1"}))

    assert {:error, :redeem_code_max_redemptions_reached} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: maxed,
                 billing_account_id: "example-ba-wsp_other",
                 product_owner_id: "wsp_other",
                 idempotency_key: "maxed-2"
               })
             )

    {:ok, %{code: first_code}} =
      RedeemCodes.create_code(%{
        code: "comma-idem-first",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    {:ok, %{code: second_code}} =
      RedeemCodes.create_code(%{
        code: "comma-idem-second",
        package_code: "comma_redeem_once",
        package_version: "2026-06",
        code_type: "one_time_package",
        surface: "comma",
        valid_from: ~U[2026-06-01 00:00:00Z]
      })

    assert {:ok, _} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: first_code,
                 billing_account_id: "example-ba-wsp_idem_conflict",
                 product_owner_id: "wsp_idem_conflict",
                 idempotency_key: "idem-conflict"
               })
             )

    assert {:error, :redeem_idempotency_key_conflict} =
             RedeemCodes.apply_code(
               apply_attrs(%{
                 code: second_code,
                 billing_account_id: "example-ba-wsp_idem_conflict",
                 product_owner_id: "wsp_idem_conflict",
                 idempotency_key: "idem-conflict"
               })
             )
  end

  defmodule ProjectionSink do
    def insert(rows) do
      Agent.update(BillingCommerce.RedeemCodesTest.ProjectionLog, &(rows ++ &1))
      {:ok, length(rows)}
    end
  end

  defp seed_package(code, surface, kind) do
    {:ok, _} = PackageCatalog.create_package(%{code: code, surface: surface, name: code})

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: surface,
        kind: kind,
        billing_period: "month",
        grant_credits: 700,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })
  end

  defp apply_attrs(attrs) do
    Map.merge(
      %{
        billing_account_id: "example-ba-wsp_redeem_guard",
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: "wsp_redeem_guard",
        at: ~U[2026-06-15 00:00:00Z],
        operator: %{id: "ops_1", reason: "redeem test"}
      },
      attrs
    )
  end

  defp stored_code_hash(code_id) do
    %{rows: [[hash]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT code_hash FROM billing_redeem_codes WHERE id = $1",
        [code_id]
      )

    hash
  end

  defp grant_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM credit_grants WHERE billing_account_id = $1",
        [account_id]
      )

    count
  end

  defp insert_billing_account!(account_id, surface, product_owner_type, product_owner_id) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_accounts (
        id, surface, product_owner_type, product_owner_id, status, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'active', now(), now())
      """,
      [account_id, surface, product_owner_type, product_owner_id]
    )
  end

  defp account_surface(account_id) do
    %{rows: [[surface]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT surface FROM billing_accounts WHERE id = $1",
        [account_id]
      )

    surface
  end

  defp grant_source(grant_id) do
    %{rows: [[source_type, source_id, valid_from, expires_at]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT source_type, source_id, valid_from, expires_at FROM credit_grants WHERE id = $1",
        [grant_id]
      )

    %{
      source_type: source_type,
      source_id: source_id,
      valid_from: valid_from,
      expires_at: expires_at
    }
  end
end
