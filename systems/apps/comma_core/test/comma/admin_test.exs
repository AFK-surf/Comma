defmodule Comma.AdminTest do
  use Comma.DataCase, async: false

  import Ecto.Query

  alias Comma.Accounts.{AuthSession, Repository}
  alias Comma.Admin.{AccessOverride, AuditEvent}
  alias Comma.Data.Workspace
  alias Comma.Repo

  setup do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)
    :ok
  end

  test "selfhost requires explicit Admin access and never trusts the hosted domain" do
    previous = Application.get_env(:comma_core, :selfhost)
    Application.put_env(:comma_core, :selfhost, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:comma_core, :selfhost),
        else: Application.put_env(:comma_core, :selfhost, previous)
    end)

    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => unique_email("selfhost") <> "@comma.surf"})

    refute Comma.Admin.admin_user?(user)
    {:ok, owner} = Comma.Admin.set_admin_access(user["id"], "allow", :ops, "Instance owner")
    assert Comma.Admin.admin_user?(owner)
    {:ok, denied} = Comma.Admin.set_admin_access(user["id"], "deny", :ops, "Revoke access")
    refute Comma.Admin.admin_user?(denied)
  end

  test "the admin email domain is configuration" do
    Application.put_env(:comma_core, :admin_email_domain, "ops.example.com")
    on_exit(fn -> Application.delete_env(:comma_core, :admin_email_domain) end)

    assert Comma.Admin.admin_email?("Admin@Ops.Example.com")
    refute Comma.Admin.admin_email?("admin@comma.surf")
  end

  test "recognizes only the exact normalized comma.surf email domain" do
    for email <- [
          "admin@comma.surf",
          " Admin@Comma.Surf "
        ] do
      assert Comma.Admin.admin_email?(email)
      assert Comma.Admin.admin_user?(%{"email" => email})
    end

    for email <- [
          "admin@sub.comma.surf",
          "admin@comma.surf.example.com",
          "admin@example.com",
          "@comma.surf",
          "comma.surf",
          "",
          nil
        ] do
      refute Comma.Admin.admin_email?(email)
      refute Comma.Admin.admin_user?(%{"email" => email})
    end

    refute Comma.Admin.admin_user?(%{})
    refute Comma.Admin.admin_user?(nil)
  end

  test "resolves exact-domain defaults, explicit overrides, and disabled users live" do
    {:ok, domain_user} =
      Comma.Accounts.create_user(%{"email" => unique_email("domain") <> "@comma.surf"})

    {:ok, outside_user} =
      Comma.Accounts.create_user(%{"email" => unique_email("outside") <> "@example.com"})

    assert Comma.Admin.admin_user?(domain_user)
    refute Comma.Admin.admin_user?(outside_user)

    assert {:ok, denied} =
             Comma.Admin.set_admin_access(
               domain_user["id"],
               "deny",
               :ops,
               "Remove domain-default Admin access"
             )

    refute denied["admin_access"]["allowed"]
    assert denied["admin_access"]["source"] == "explicit_deny"
    refute Comma.Admin.admin_user?(denied)

    assert {:ok, allowed} =
             Comma.Admin.set_admin_access(
               outside_user["id"],
               "allow",
               :ops,
               "Grant explicit Admin access"
             )

    assert allowed["admin_access"]["allowed"]
    assert allowed["admin_access"]["source"] == "explicit_allow"
    assert Comma.Admin.admin_user?(allowed)

    assert {:ok, disabled} =
             Comma.Admin.update_user(outside_user["id"], %{"status" => "disabled"})

    refute disabled["admin_access"]["allowed"]
    assert disabled["admin_access"]["source"] == "disabled"
    refute Comma.Admin.admin_user?(disabled)
  end

  test "decorates bounded user pages with access and login methods" do
    {:ok, domain_user} =
      Comma.Accounts.create_user(%{"email" => unique_email("summary-domain") <> "@comma.surf"})

    {:ok, outside_user} =
      Comma.Accounts.create_user(%{"email" => unique_email("summary-outside") <> "@example.com"})

    last_authenticated_at = ~U[2026-07-25 08:30:00.000000Z]

    assert {:ok, _identity} =
             Repository.ensure_identity(outside_user["id"], %{
               provider: "google",
               issuer: "https://accounts.google.com",
               subject: "summary-google-subject",
               email_snapshot: outside_user["email"],
               email_verified: true,
               last_authenticated_at: last_authenticated_at
             })

    {:ok, _outside_user} =
      Comma.Admin.set_admin_access(
        outside_user["id"],
        "allow",
        :ops,
        "Count the explicit Admin"
      )

    {:ok, page} = Comma.Admin.list_users(limit: 100)

    assert Enum.find(page["data"], &(&1["id"] == domain_user["id"]))["admin_access"] == %{
             "allowed" => true,
             "decision" => nil,
             "source" => "domain_default"
           }

    listed_outside = Enum.find(page["data"], &(&1["id"] == outside_user["id"]))

    assert listed_outside["admin_access"]["allowed"]

    assert [
             %{"method" => "email_otp", "email" => outside_email},
             %{
               "method" => "google",
               "email_snapshot" => google_email,
               "email_verified" => true,
               "linked_at" => linked_at,
               "last_authenticated_at" => last_authenticated_at_unix
             }
           ] = listed_outside["login_methods"]

    assert outside_email == outside_user["email"]
    assert google_email == outside_user["email"]
    assert is_integer(linked_at)
    assert last_authenticated_at_unix == DateTime.to_unix(last_authenticated_at)

    {:ok, fetched_domain} = Comma.Admin.get_user(domain_user["id"])

    assert fetched_domain["login_methods"] == [
             %{"method" => "email_otp", "email" => domain_user["email"]}
           ]
  end

  test "Workspace and Billing projection is owner-verified, bounded, and redacted" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    valid_from = DateTime.add(now, -1, :day)
    expires_at = DateTime.add(now, 30, :day)

    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => unique_email("workspace-billing") <> "@comma.surf"})

    assert {:ok, %{"workspace" => nil, "billing" => nil}} =
             Comma.Admin.get_user_workspace_billing(user["id"])

    assert {:ok, workspace} = Comma.Workspaces.create_for_user(user["id"])

    workspace["id"]
    |> then(&Repo.get!(Workspace, &1))
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace["billing_account_id"],
               surface: "comma",
               required_surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: workspace["id"],
               enforce_product_owner_identity: true
             })

    for number <- 1..51 do
      assert {:ok, _grant} =
               BillingCore.Credits.issue_grant(%{
                 repo: BillingCore.Repo,
                 billing_account_id: workspace["billing_account_id"],
                 credits: 1,
                 valid_from: valid_from,
                 expires_at: expires_at,
                 source_type: "redeem_code",
                 source_id: "redemption-#{number}",
                 source_event_id: "event-#{number}",
                 idempotency_key: "workspace-billing-#{number}",
                 package_code: "comma_pro",
                 package_version: "1"
               })
    end

    assert {:ok,
            %{
              "workspace" => projected_workspace,
              "billing" => projected_billing
            }} = Comma.Admin.get_user_workspace_billing(user["id"])

    assert projected_workspace == %{
             "id" => workspace["id"],
             "name" => workspace["name"],
             "status" => "ready",
             "tenant_id" => workspace["salix_tenant_id"],
             "group_id" => workspace["default_group_id"],
             "billing_account_id" => workspace["billing_account_id"],
             "cloud_vm" => %{
               "workspace_id" => workspace["id"],
               "enabled" => true,
               "convergence_status" => "pending"
             },
             "created_at" => projected_workspace["created_at"],
             "updated_at" => projected_workspace["updated_at"]
           }

    assert is_integer(projected_workspace["created_at"])
    assert is_integer(projected_workspace["updated_at"])
    assert projected_billing["account_id"] == workspace["billing_account_id"]
    assert projected_billing["account_status"] == "active"
    assert projected_billing["current_credits"] == 51
    assert projected_billing["has_more"] == true
    assert length(projected_billing["active_grants"]) == 50

    assert Enum.all?(projected_billing["active_grants"], fn grant ->
             Map.keys(grant) |> Enum.sort() ==
               ~w(
                 expires_at
                 id
                 package_code
                 package_version
                 remaining_credits
                 source_id
                 source_type
                 valid_from
               )
           end)

    refute inspect(projected_billing) =~ "policy_snapshot"
    refute inspect(projected_billing) =~ "metadata"
    refute inspect(projected_billing) =~ "source_event_id"
    refute inspect(projected_billing) =~ "idempotency_key"
  end

  test "Workspace and Billing projection fails closed on owner mismatch and cardinality drift" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    valid_from = DateTime.add(now, -1, :day)
    expires_at = DateTime.add(now, 30, :day)

    {:ok, mismatched_user} =
      Comma.Accounts.create_user(%{
        "email" => unique_email("workspace-mismatch") <> "@comma.surf"
      })

    assert {:ok, workspace} = Comma.Workspaces.create_for_user(mismatched_user["id"])

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace["billing_account_id"],
               surface: "comma",
               required_surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "another-workspace",
               enforce_product_owner_identity: true
             })

    assert {:ok, _grant} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace["billing_account_id"],
               credits: 73,
               valid_from: valid_from,
               expires_at: expires_at,
               source_type: "redeem_code",
               source_id: "mismatched-redemption",
               source_event_id: "mismatched-event",
               idempotency_key: "workspace-billing-mismatch",
               package_code: "must_not_cross",
               package_version: "1"
             })

    assert {:ok,
            projection = %{
              "workspace" => %{"id" => workspace_id},
              "billing" => %{
                "account_status" => "identity_mismatch",
                "current_credits" => 0,
                "active_grants" => [],
                "has_more" => false
              }
            }} = Comma.Admin.get_user_workspace_billing(mismatched_user["id"])

    assert workspace_id == workspace["id"]
    refute inspect(projection) =~ "must_not_cross"

    {:ok, duplicate_user} =
      Comma.Accounts.create_user(%{
        "email" => unique_email("workspace-duplicate") <> "@comma.surf"
      })

    assert {:ok, _first} = Comma.Workspaces.create_for_user(duplicate_user["id"])
    assert {:ok, _second} = Comma.Workspaces.create_for_user(duplicate_user["id"])

    assert {:error, :workspace_invariant} =
             Comma.Admin.get_user_workspace_billing(duplicate_user["id"])

    assert {:error, :not_found} =
             Comma.Admin.get_user_workspace_billing("missing-workspace-billing-user")
  end

  test "human support command is audited, capped, secret-redacted, and duplicate-safe" do
    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("actor") <> "@comma.surf"})

    {:ok, target} =
      Comma.Accounts.create_user(%{"email" => unique_email("target") <> "@example.com"})

    attrs = %{
      "reason" => "Investigate a reported support issue",
      "idempotency_key" => "support-test-key-0001",
      "confirmation" => "support-session:#{target["id"]}",
      "expires_in_seconds" => 900,
      "budget" => 5,
      "tool_allowlist" => ["echo"]
    }

    assert {:ok, session} =
             Comma.Admin.run_human_command(
               actor,
               "create_support_session",
               "user",
               target["id"],
               attrs,
               "support-session:#{target["id"]}",
               fn _command_id -> Comma.Admin.create_support_session(target["id"], attrs) end
             )

    assert "comma_sess_" <> _ = session["token"]
    assert session["restricted"] == true
    assert session["interaction_budget_remaining"] == 5
    assert session["tool_allowlist"] == ["echo"]

    assert {:error, :admin_command_already_succeeded} =
             Comma.Admin.run_human_command(
               actor,
               "create_support_session",
               "user",
               target["id"],
               attrs,
               "support-session:#{target["id"]}",
               fn _command_id -> Comma.Admin.create_support_session(target["id"], attrs) end
             )

    assert Repo.aggregate(
             from(session in AuthSession, where: session.user_id == ^target["id"]),
             :count,
             :id
           ) == 1

    event =
      Repo.get_by!(AuditEvent,
        actor_key: actor["id"],
        action: "create_support_session",
        idempotency_key: attrs["idempotency_key"]
      )

    assert event.outcome == "succeeded"
    assert event.evidence == %{"recorded" => true}
    refute inspect(event) =~ session["token"]

    assert {:error, :invalid_ttl_seconds} =
             Comma.Admin.create_support_session(target["id"], %{"expires_in_seconds" => 901})
  end

  test "a concurrent retry cannot execute a second effect while the first owns the fence" do
    previous_lease_seconds = Application.get_env(:comma_core, :admin_audit_lease_seconds)
    Application.put_env(:comma_core, :admin_audit_lease_seconds, 0)

    on_exit(fn ->
      case previous_lease_seconds do
        nil -> Application.delete_env(:comma_core, :admin_audit_lease_seconds)
        seconds -> Application.put_env(:comma_core, :admin_audit_lease_seconds, seconds)
      end
    end)

    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("fenced-actor") <> "@comma.surf"})

    {:ok, target} =
      Comma.Accounts.create_user(%{"email" => unique_email("fenced-target") <> "@example.com"})

    attrs = %{
      "reason" => "Verify one owner executes the support command",
      "idempotency_key" => "support-fence-test-0001",
      "confirmation" => "support-session:#{target["id"]}",
      "expires_in_seconds" => 900
    }

    parent = self()

    first =
      Task.async(fn ->
        Comma.Admin.run_human_command(
          actor,
          "create_support_session",
          "user",
          target["id"],
          attrs,
          "support-session:#{target["id"]}",
          fn _command_id ->
            send(parent, :first_effect_started)

            receive do
              :release_first_effect -> :ok
            after
              5_000 -> raise "timed out waiting to release the first Admin effect"
            end

            Comma.Admin.create_support_session(target["id"], attrs)
          end
        )
      end)

    assert_receive :first_effect_started, 1_000

    second =
      Task.async(fn ->
        Comma.Admin.run_human_command(
          actor,
          "create_support_session",
          "user",
          target["id"],
          attrs,
          "support-session:#{target["id"]}",
          fn _command_id ->
            send(parent, :second_effect_started)
            Comma.Admin.create_support_session(target["id"], attrs)
          end
        )
      end)

    assert Task.yield(second, 100) == nil
    refute_received :second_effect_started

    send(first.pid, :release_first_effect)
    assert {:ok, _session} = Task.await(first, 2_000)

    assert Task.await(second, 2_000) in [
             {:error, :admin_command_in_progress},
             {:error, :admin_command_already_succeeded}
           ]

    refute_received :second_effect_started

    assert Repo.aggregate(
             from(session in AuthSession, where: session.user_id == ^target["id"]),
             :count,
             :id
           ) == 1
  end

  test "external command recovers owner truth after commit and a lost response" do
    previous_lease_seconds = Application.get_env(:comma_core, :admin_audit_lease_seconds)
    Application.put_env(:comma_core, :admin_audit_lease_seconds, 0)

    on_exit(fn ->
      case previous_lease_seconds do
        nil -> Application.delete_env(:comma_core, :admin_audit_lease_seconds)
        seconds -> Application.put_env(:comma_core, :admin_audit_lease_seconds, seconds)
      end
    end)

    package_code = "comma_admin_lost_ack_#{System.unique_integer([:positive])}"
    package_version = "2026-07"

    assert {:ok, _package} =
             BillingCommerce.create_package(%{
               code: package_code,
               surface: "comma",
               name: "Admin lost ACK package"
             })

    assert {:ok, _version} =
             BillingCommerce.create_package_version(%{
               package_code: package_code,
               version: package_version,
               surface: "comma",
               kind: "one_time",
               billing_period: "month",
               grant_credits: 100,
               grant_period: "current_period",
               currency: "usd",
               amount_minor: 0,
               usage_policy: %{},
               effective_at: ~U[2026-07-01 00:00:00Z],
               status: "active"
             })

    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("lost-ack") <> "@comma.surf"})

    attrs = %{
      "code" => "comma-lost-ack-#{System.unique_integer([:positive])}",
      "package_code" => package_code,
      "package_version" => package_version,
      "reason" => "Recover Billing owner truth after a lost response",
      "idempotency_key" => "lost-ack-#{Ecto.UUID.generate()}",
      "confirmation" => "create-redeem-code:#{package_code}:#{package_version}"
    }

    parent = self()

    assert_raise RuntimeError, "simulated response loss", fn ->
      Comma.Admin.run_human_external_command(
        actor,
        "create_redeem_code",
        attrs,
        "redeem_code",
        "#{package_code}:#{package_version}",
        &BillingCommerce.RedeemCodeCommands.prepare_human_create/3,
        fn command_id, command ->
          assert {:ok, created} =
                   command
                   |> BillingCommerce.RedeemCodeCommands.bind_admin_command(command_id)
                   |> BillingCommerce.create_redeem_code()

          send(parent, {:billing_committed, created})
          raise "simulated response loss"
        end
      )
    end

    assert_receive {:billing_committed, created}

    event =
      Repo.get_by!(AuditEvent,
        actor_key: actor["id"],
        action: "create_redeem_code",
        idempotency_key: attrs["idempotency_key"]
      )

    assert event.outcome == "started"
    assert %DateTime{} = event.lease_expires_at

    assert {:ok, recovered} =
             Comma.Admin.run_human_external_command(
               actor,
               "create_redeem_code",
               attrs,
               "redeem_code",
               "#{package_code}:#{package_version}",
               &BillingCommerce.RedeemCodeCommands.prepare_human_create/3,
               fn command_id, command ->
                 command
                 |> BillingCommerce.RedeemCodeCommands.bind_admin_command(command_id)
                 |> BillingCommerce.create_redeem_code()
               end
             )

    assert recovered.id == created.id
    refute Map.has_key?(recovered, :code)
    assert Repo.get!(AuditEvent, event.id).outcome == "succeeded"

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM billing_redeem_codes WHERE admin_command_id = $1",
               [event.id]
             ).rows
  end

  test "receipted external command replays a succeeded audit through the receipt only" do
    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("receipted") <> "@comma.surf"})

    {:ok, receipt} = Agent.start_link(fn -> nil end)
    parent = self()

    attrs = %{
      "expected_revision" => 7,
      "reason" => "Recover the exact committed Agent VMM intent",
      "idempotency_key" => "receipted-#{Ecto.UUID.generate()}",
      "confirmation" => "disable_agent_vmm_registration:registration-a:7"
    }

    prepare = fn command_attrs, _actor, _contract ->
      command = %{
        action: "disable_agent_vmm_registration",
        tenant_id: "tenant-a",
        target_id: "registration-a",
        expected_revision: command_attrs["expected_revision"]
      }

      {:ok,
       %{
         command: command,
         target_type: "agent_vmm_registration",
         target_id: "registration-a",
         expected_confirmation: "disable_agent_vmm_registration:registration-a:7",
         fingerprint: command
       }}
    end

    execute = fn command_id, _command ->
      send(parent, :executed)
      Agent.update(receipt, fn nil -> command_id end)
      {:ok, %{accepted: true, result_revision: 8}}
    end

    replay = fn command_id, _command ->
      send(parent, :replayed)

      if Agent.get(receipt, & &1) == command_id,
        do: {:already_applied, %{accepted: true, result_revision: 8}},
        else: {:error, :unavailable}
    end

    args = [
      actor,
      "disable_agent_vmm_registration",
      attrs,
      "agent_vmm_registration",
      "registration-a",
      prepare,
      execute,
      replay
    ]

    assert {:ok, %{result_revision: 8}} =
             apply(Comma.Admin, :run_human_receipted_external_command, args)

    assert_receive :executed
    refute_received :replayed

    assert {:ok, %{result_revision: 8}} =
             apply(Comma.Admin, :run_human_receipted_external_command, args)

    assert_receive :replayed
    refute_received :executed
  end

  test "Admin Session projection is bounded and human revocation commands are audited" do
    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("session-actor") <> "@comma.surf"})

    {:ok, target} =
      Comma.Accounts.create_user(%{"email" => unique_email("session-target") <> "@example.com"})

    assert {:ok, ordinary} =
             Comma.Accounts.create_session(target["id"],
               client_kind: "web",
               device_label: "Web on macOS"
             )

    assert {:ok, support} =
             Comma.Admin.create_support_session(target["id"], %{"expires_in_seconds" => 900})

    assert {:ok, expired} =
             Comma.Accounts.create_session(target["id"],
               client_kind: "electron",
               device_label: "Comma Desktop on Linux"
             )

    expired_at = DateTime.add(DateTime.utc_now(), -60, :second)

    expired["id"]
    |> then(&Repo.get!(AuthSession, &1))
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    assert {:ok, page} = Comma.Admin.list_user_sessions(target["id"], limit: 50)
    assert page["has_more"] == false
    assert length(page["data"]) == 3

    assert Enum.all?(page["data"], fn session ->
             Map.keys(session) |> Enum.sort() ==
               ~w(
                 auth_method
                 authenticated_at
                 client_kind
                 device_label
                 expires_at
                 id
                 last_seen_at
                 restricted
                 revoked_at
                 session_source
               )
           end)

    listed_support = Enum.find(page["data"], &(&1["id"] == support["id"]))
    assert listed_support["client_kind"] == "api"
    assert listed_support["device_label"] == "Admin support session"
    refute Map.has_key?(listed_support, "token")
    refute Map.has_key?(listed_support, "user_id")
    refute Map.has_key?(listed_support, "workspace_id")

    revoke_attrs = %{
      "reason" => "Remove the reported browser Session",
      "idempotency_key" => "revoke-session-test-0001",
      "confirmation" => "revoke-session:#{ordinary["id"]}"
    }

    assert {:ok, %{"revoked" => true, "session_id" => ordinary_id}} =
             Comma.Admin.run_human_command(
               actor,
               "revoke_user_session",
               "session",
               ordinary["id"],
               revoke_attrs,
               "revoke-session:#{ordinary["id"]}",
               fn _command_id ->
                 Comma.Admin.revoke_user_session(target["id"], ordinary["id"])
               end
             )

    assert ordinary_id == ordinary["id"]
    assert {:error, :revoked} = Comma.Accounts.validate_session(ordinary["token"])

    revoke_all_attrs = %{
      "reason" => "End the remaining support access",
      "idempotency_key" => "revoke-all-session-test-0001",
      "confirmation" => "revoke-all-sessions:#{target["id"]}"
    }

    assert {:ok, %{"revoked_count" => 1}} =
             Comma.Admin.run_human_command(
               actor,
               "revoke_all_user_sessions",
               "user",
               target["id"],
               revoke_all_attrs,
               "revoke-all-sessions:#{target["id"]}",
               fn _command_id -> Comma.Admin.revoke_all_user_sessions(target["id"]) end
             )

    assert {:error, :revoked} = Comma.Accounts.validate_session(support["token"])
    assert {:error, :expired} = Comma.Accounts.validate_session(expired["token"])
    assert Repo.get!(AuthSession, expired["id"]).revoked_at == nil

    for {action, idempotency_key} <- [
          {"revoke_user_session", revoke_attrs["idempotency_key"]},
          {"revoke_all_user_sessions", revoke_all_attrs["idempotency_key"]}
        ] do
      assert %AuditEvent{outcome: "succeeded", evidence: %{"recorded" => true}} =
               Repo.get_by!(AuditEvent,
                 actor_key: actor["id"],
                 action: action,
                 idempotency_key: idempotency_key
               )
    end

    assert {:error, :not_found} = Comma.Admin.list_user_sessions("missing-user")
  end

  test "invalid human confirmation is rejected before the effect and remains auditable" do
    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("rejected") <> "@comma.surf"})

    parent = self()

    assert {:error, :invalid_admin_confirmation} =
             Comma.Admin.run_human_command(
               actor,
               "update_user",
               "user",
               actor["id"],
               %{
                 "reason" => "Try an invalid confirmation",
                 "idempotency_key" => "rejected-test-key-0001",
                 "confirmation" => "wrong"
               },
               "update-user:#{actor["id"]}",
               fn _command_id ->
                 send(parent, :effect_ran)
                 {:ok, %{}}
               end
             )

    refute_received :effect_ran

    assert Repo.exists?(
             from(event in AuditEvent,
               where:
                 event.actor_key == ^actor["id"] and
                   event.action == "update_user" and
                   event.outcome == "rejected" and
                   event.error_code == "invalid_admin_confirmation"
             )
           )
  end

  test "Audit log is latest-first, cursor-bounded, and secret-redacted" do
    {:ok, actor} =
      Comma.Accounts.create_user(%{"email" => unique_email("audit-reader") <> "@comma.surf"})

    for {suffix, reason} <- [
          {"first", "Record the first approved account update"},
          {"second", "Record the second approved account update"}
        ] do
      assert {:ok, %{}} =
               Comma.Admin.run_human_command(
                 actor,
                 "update_user",
                 "user",
                 actor["id"],
                 %{
                   "reason" => reason,
                   "idempotency_key" => "audit-page-#{suffix}-0001",
                   "confirmation" => "update-user:#{actor["id"]}"
                 },
                 "update-user:#{actor["id"]}",
                 fn _command_id -> {:ok, %{}} end
               )
    end

    secret = "audit-page-cursor-secret"

    assert {:ok,
            %{
              "data" => [latest],
              "has_more" => true,
              "next_cursor" => cursor
            }} = Comma.Admin.list_audit_events(limit: 1, cursor_secret: secret)

    assert latest["reason"] == "Record the second approved account update"

    assert latest["actor"] == %{
             "type" => "comma_user",
             "user_id" => actor["id"],
             "email" => actor["email"]
           }

    assert latest["target"] == %{"type" => "user", "id" => actor["id"]}
    assert latest["action"] == "update_user"
    assert latest["outcome"] == "succeeded"
    assert latest["error_code"] == nil
    assert is_integer(latest["created_at"])
    assert is_integer(latest["updated_at"])

    assert Map.keys(latest) |> Enum.sort() ==
             ~w(action actor created_at error_code id outcome reason target updated_at)

    refute Map.has_key?(latest, "idempotency_key")
    refute Map.has_key?(latest, "request_fingerprint")
    refute Map.has_key?(latest, "evidence")
    refute Map.has_key?(latest, "lease_expires_at")

    assert {:ok,
            %{
              "data" => [earlier],
              "has_more" => false,
              "next_cursor" => nil
            }} =
             Comma.Admin.list_audit_events(
               limit: 1,
               cursor: cursor,
               cursor_secret: secret
             )

    assert earlier["reason"] == "Record the first approved account update"

    assert {:error, :invalid_cursor} =
             Comma.Admin.list_audit_events(
               limit: 1,
               cursor: cursor <> "tampered",
               cursor_secret: secret
             )
  end

  test "create user and explicit access override commit atomically" do
    email = unique_email("created-admin") <> "@example.com"

    assert {:ok, user} =
             Comma.Admin.create_user_with_access(
               %{"email" => email, "name" => "Created Admin"},
               "allow",
               :ops,
               "Create an explicitly allowed Admin"
             )

    assert user["admin_access"]["allowed"]

    assert user["login_methods"] == [
             %{
               "email" => String.downcase(email),
               "method" => "email_otp"
             }
           ]

    assert Repo.get!(AccessOverride, user["id"]).decision == "allow"
  end

  defp unique_email(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
