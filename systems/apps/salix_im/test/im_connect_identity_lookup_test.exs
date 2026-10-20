defmodule SalixIM.IMConnectIdentityLookupTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Inbound-webhook connect resolution with the authority key as an
  ACCELERATOR (docs/identity-security.md,
  Option B).

  A key hit that revalidates against the canonical and passes the
  caller's eligibility predicate is two point GETs — no
  `ctl/im_connects/` prefix LIST. Anything else (missing, malformed, or
  stale key; ineligible record; key-read fault) falls back to the
  fail-closed compatibility scan under a concurrency permit, so a wrong
  key costs one bounded scan and can never lose a message or misroute.
  The write protocol is byte-identical to main; the read path's only
  write is a lazy best-effort create-once repair, allowed ONLY when the
  completed walk proved the identity globally unique among live records
  — duplicates are never cached, so request order can never elect a
  durable key owner.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixStore.Keys

  setup do
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
        Map.put(rec, "router_agent_id", agent["agent_id"])
      end)

    on_exit(fn ->
      case prev_s3 do
        nil -> SystemsRuntime.delete_env(:salix_store, :s3_backend)
        value -> SystemsRuntime.put_env(:salix_store, :s3_backend, value)
      end
    end)

    {:ok, tenant: tenant, group_id: group_id}
  end

  defp create_slack!(tenant, group_id, app_id) do
    {:ok, connect} =
      SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
        "app_id" => app_id,
        "client_id" => "client-1",
        "client_secret" => "secret-1",
        "signing_secret" => "sign-1"
      })

    connect
  end

  defp complete_oauth!(connect) do
    {:ok, completed} =
      SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
        "bot_token" => "xoxb-test",
        "bot_id" => "B123",
        "bot_user_id" => "U123",
        "workspace_id" => "T123",
        "workspace_name" => "Test WS",
        "enterprise_id" => nil,
        "owner_user_id" => "U999"
      })

    completed
  end

  defp identity_key(app_id), do: Keys.ctl_im_provider_identity("slack", app_id)

  defp no_list_in_read_log! do
    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, _prefix, _opts} -> true
             _ -> false
           end)
  end

  defp assert_scanned! do
    assert Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, _prefix, _opts} -> true
             _ -> false
           end)
  end

  # ---- the fast path: two point GETs, no LIST ----

  test "event lookup is two point GETs — the authority key and the canonical record",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-EVENTS")
    complete_oauth!(connect)

    connect_key = Keys.ctl_im_connect(group_id, connect["connect_id"])

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-EVENTS")
    assert found["connect_id"] == connect["connect_id"]

    assert SalixStore.S3.Fake.read_log() == [
             {:get, identity_key("A-EVENTS")},
             {:get, connect_key}
           ]

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok, _} = SalixIM.ProviderIdentity.find_active_slack_im_connect_by_app_id("A-EVENTS")

    assert SalixStore.S3.Fake.read_log() == [
             {:get, identity_key("A-EVENTS")},
             {:get, connect_key}
           ]
  end

  test "the authority key routes past a drifted duplicate in another tenant",
       %{tenant: tenant, group_id: group_id} do
    a = create_slack!(tenant, group_id, "A-OWNED")
    complete_oauth!(a)

    # A drifted live canonical in ANOTHER tenant claims the same app_id
    # (crash debris / manual seeding). The key names A, A revalidates —
    # the duplicate is never consulted and no scan happens.
    other_tenant = SalixAgent.TestSupport.new_tenant_id()
    other_group = SalixStore.Ids.new_group_id(other_tenant)
    drifted_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(other_group, drifted_id), %{
        "connect_id" => drifted_id,
        "tenant_id" => other_tenant,
        "group_id" => other_group,
        "provider" => "slack",
        "app_id" => "A-OWNED",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-OWNED")
    assert found["connect_id"] == a["connect_id"]
    assert found["tenant_id"] == tenant
    no_list_in_read_log!()
  end

  # ---- a wrong key never loses a message: fallback catches everything ----

  test "a deleted authority key costs one scan, not a lost message",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-LOSTKEY")
    complete_oauth!(connect)

    # Simulate any key-losing race (stale release, manual deletion).
    :ok = SalixStore.S3.delete(identity_key("A-LOSTKEY"))

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LOSTKEY")
    assert found["connect_id"] == connect["connect_id"]
    assert_scanned!()

    # The fallback hit lazily repaired the key: the next lookup is two
    # point GETs again.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LOSTKEY")
    no_list_in_read_log!()
  end

  # ---- fault honesty ----

  # ---- unknown ids scan, by contract ----

  # ---- caller eligibility semantics (byte-compatible with main) ----

  test "pending oauth stays invisible to event lookup until completed",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-PENDING")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-PENDING")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_active_slack_im_connect_by_app_id("A-PENDING")

    complete_oauth!(connect)

    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-PENDING")
    assert {:ok, _} = SalixIM.ProviderIdentity.find_active_slack_im_connect_by_app_id("A-PENDING")
  end

  test "disabled connect drops out of the active lookup only",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-DISABLED")
    complete_oauth!(connect)

    :ok = SalixIM.ProviderConnects.disable_im_connect(tenant, group_id, connect["connect_id"])

    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-DISABLED")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_active_slack_im_connect_by_app_id("A-DISABLED")
  end

  test "delete releases the reservation and the identity becomes reusable",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-REUSE")
    complete_oauth!(connect)

    :ok = SalixIM.ProviderConnects.delete_im_connect(tenant, group_id, connect["connect_id"])

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-REUSE")

    replacement = create_slack!(tenant, group_id, "A-REUSE")
    complete_oauth!(replacement)

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-REUSE")
    assert found["connect_id"] == replacement["connect_id"]
  end

  test "an app_id update re-routes reads to the new identity",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-BEFORE")
    complete_oauth!(connect)

    {:ok, _} =
      SalixIM.ProviderConnects.update_slack_im_connect(tenant, group_id, connect["connect_id"], %{
        "app_id" => "A-AFTER"
      })

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-BEFORE")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-AFTER")
    assert found["connect_id"] == connect["connect_id"]
  end

  test "duplicate app_id create is rejected",
       %{tenant: tenant, group_id: group_id} do
    _first = create_slack!(tenant, group_id, "A-DUP")

    assert {:error, {:bad_request, message}} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-DUP",
               "client_id" => "client-2",
               "client_secret" => "secret-2",
               "signing_secret" => "sign-2"
             })

    assert message =~ "already used"
  end

  test "oauth_state resolves its connect (exact match, previous-release semantics)",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-OAUTH")

    {:ok, raw} = SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

    assert {:ok, found} =
             SalixIM.ProviderConnects.find_slack_im_connect_by_oauth_state(raw["oauth_state"])

    assert found["connect_id"] == connect["connect_id"]

    :ok =
      SalixStore.S3.Fake.set_fault({
        :fail,
        503,
        :list,
        Keys.ctl_im_connects_all_prefix()
      })

    assert {:error, _reason} =
             SalixIM.ProviderConnects.find_slack_im_connect_by_oauth_state(raw["oauth_state"])
  end

  # ---- duplicate eligibility: the scan preserves main's per-caller answer ----

  # ---- lazy repair converges misses to point reads ----

  # ---- uniqueness certification gates the repair ----

  # ---- the scan-concurrency permit ----

  # ---- blank identities are rejected consistently ----

  # ---- the reserved (materialization) reader shares the contract ----
end
