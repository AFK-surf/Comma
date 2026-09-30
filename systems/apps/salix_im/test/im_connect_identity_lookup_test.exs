defmodule SalixIM.IMConnectIdentityLookupTest do
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
  use ExUnit.Case, async: false

  alias SalixStore.Keys

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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
        nil -> Application.delete_env(:salix_store, :s3_backend)
        value -> Application.put_env(:salix_store, :s3_backend, value)
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

  defp seed_legacy!(tenant, group_id, app_id, extra \\ %{}) do
    connect_id = SalixStore.Ids.new_connect_id()

    rec =
      Map.merge(
        %{
          "connect_id" => connect_id,
          "tenant_id" => tenant,
          "group_id" => group_id,
          "provider" => "slack",
          "app_id" => app_id,
          "oauth_completed_at" => 1,
          "created_at" => 1,
          "updated_at" => 1
        },
        extra
      )

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), rec)
    rec
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

  defp install_barrier(name) do
    test = self()

    Application.put_env(:salix_im, :provider_identity_barrier, %{
      name => fn ->
        send(test, {:barrier_hit, name, self()})

        receive do
          :barrier_release -> :ok
        end
      end
    })

    on_exit(fn -> Application.delete_env(:salix_im, :provider_identity_barrier) end)
  end

  defp release_barrier(pid) do
    Application.delete_env(:salix_im, :provider_identity_barrier)
    send(pid, :barrier_release)
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

  test "a malformed authority object falls back to the scan and still routes",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-MALFORMED")
    complete_oauth!(connect)

    # Corrupt the per-key object (no connect_id).
    {:ok, _} =
      SalixStore.S3.put(
        identity_key("A-MALFORMED"),
        Jason.encode!(%{"group_id" => group_id, "tenant_id" => tenant})
      )

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-MALFORMED")
    assert found["connect_id"] == connect["connect_id"]
    assert_scanned!()
  end

  test "an authority with a non-binary connect_id falls back and still routes",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-BADAUTH")
    complete_oauth!(connect)

    {:ok, _} =
      SalixStore.S3.put(
        identity_key("A-BADAUTH"),
        Jason.encode!(%{
          "provider" => "slack",
          "identity" => "A-BADAUTH",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => %{}
        })
      )

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-BADAUTH")
    assert found["connect_id"] == connect["connect_id"]
  end

  test "a stale key left by a competing update falls back to the canonical truth",
       %{tenant: tenant, group_id: group_id} do
    # The round-3 ABA shape, Option-B disposition: mid-update, the key
    # names the connect but the canonical CAS has not landed. The fast
    # path refuses the half-state, the scan sees only the canonical
    # truth — exactly main's answer at that instant — and after the
    # update lands the fast path serves the new identity.
    a = create_slack!(tenant, group_id, "A-ABA-Y")
    complete_oauth!(a)

    install_barrier(:connect_update_canonical)

    update =
      Task.async(fn ->
        SalixIM.ProviderConnects.update_slack_im_connect(tenant, group_id, a["connect_id"], %{
          "app_id" => "A-ABA-X"
        })
      end)

    assert_receive {:barrier_hit, :connect_update_canonical, update_pid}, 2_000

    # Mid-window: X is reserved but no canonical carries it yet — X does
    # not resolve (main agrees: the canonical is the only truth), and Y
    # still resolves.
    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ABA-X")

    assert {:ok, still} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ABA-Y")
    assert still["connect_id"] == a["connect_id"]

    release_barrier(update_pid)
    assert {:ok, _} = Task.await(update)

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ABA-X")
    assert found["connect_id"] == a["connect_id"]
    no_list_in_read_log!()

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ABA-Y")
  end

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

  test "a key-read fault degrades to the scan; a scan fault is a retryable error",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-KEYFAULT")
    complete_oauth!(connect)

    # Key read fails → the accelerator is skipped, the scan still routes.
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, identity_key("A-KEYFAULT")})
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-KEYFAULT")
    assert found["connect_id"] == connect["connect_id"]

    # LIST fails during the fallback → retryable error, never a 404.
    :ok = SalixStore.S3.delete(identity_key("A-KEYFAULT"))
    SalixStore.S3.Fake.set_fault({:fail, 503, :list, :any})

    assert {:error, reason} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-KEYFAULT")

    refute reason == :not_found
  end

  test "a per-record GET fault during the scan is a retryable error, not a shrunken corpus",
       %{tenant: tenant, group_id: group_id} do
    legacy = seed_legacy!(tenant, group_id, "A-GETFAULT")

    SalixStore.S3.Fake.set_fault(
      {:fail, 503, :get, Keys.ctl_im_connect(group_id, legacy["connect_id"])}
    )

    assert {:error, reason} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-GETFAULT")

    refute reason == :not_found
  end

  test "one undecodable sibling never blocks a valid lookup",
       %{tenant: tenant, group_id: group_id} do
    # Invalid JSON in the prefix is malformed DATA (skipped), not a fault.
    junk_id = SalixStore.Ids.new_connect_id()
    {:ok, _} = SalixStore.S3.put(Keys.ctl_im_connect(group_id, junk_id), "{not json")

    # A non-binary app_id sibling is equally survivable.
    bad_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, bad_id), %{
        "connect_id" => bad_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => %{},
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    legacy = seed_legacy!(tenant, group_id, "A-GOODFIELD")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-GOODFIELD")
    assert found["connect_id"] == legacy["connect_id"]
  end

  test "a canonical with a non-binary app_id degrades to a miss on lookup",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-BADFIELD")
    complete_oauth!(connect)

    {:ok, _} =
      SalixStore.CasRecord.update(Keys.ctl_im_connect(group_id, connect["connect_id"]), fn rec ->
        Map.put(rec, "app_id", %{})
      end)

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-BADFIELD")
  end

  # ---- unknown ids scan, by contract ----

  test "an unknown app_id is one bounded scan — the permanent Option-B contract",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-KNOWN")
    complete_oauth!(connect)

    SalixStore.S3.Fake.reset_read_log()

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ELSEWHERE")

    assert [{:get, _identity_key} | _scan] = SalixStore.S3.Fake.read_log()
    assert_scanned!()
  end

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

  test "identity availability fails closed when its canonical census cannot be listed",
       %{tenant: tenant, group_id: group_id} do
    prefix = Keys.ctl_im_connects_all_prefix()
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})

    assert {:error, {:identity_census_unavailable, _reason}} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-CENSUS-LIST-FAULT",
               "client_id" => "client-2",
               "client_secret" => "secret-2",
               "signing_secret" => "sign-2"
             })
  end

  test "identity availability fails closed on an undecodable canonical record",
       %{tenant: tenant, group_id: group_id} do
    malformed_key = Keys.ctl_im_connect(group_id, SalixStore.Ids.new_connect_id())
    assert {:ok, _} = SalixStore.S3.put(malformed_key, "{not json")

    assert {:error, {:identity_census_unavailable, _reason}} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-CENSUS-DECODE-FAULT",
               "client_id" => "client-2",
               "client_secret" => "secret-2",
               "signing_secret" => "sign-2"
             })
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

  test "a pending duplicate never shadows the routable record — and suppresses the repair",
       %{tenant: tenant, group_id: group_id} do
    # Two pre-protocol duplicates, no authority keys: A pending (earlier
    # key order), B oauth-completed. Main resolved B; so does the scan —
    # the caller's predicate is part of candidate selection. But the
    # identity is NOT globally unique, so no key owner may be elected:
    # every lookup keeps scanning until an operator settles the
    # duplicates.
    _pending = seed_legacy!(tenant, group_id, "A-ELIG", %{"oauth_completed_at" => 0})
    routable = seed_legacy!(tenant, group_id, "A-ELIG")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ELIG")
    assert found["connect_id"] == routable["connect_id"]
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-ELIG"))

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-ELIG")
    assert found["connect_id"] == routable["connect_id"]
    assert_scanned!()
  end

  test "a disabled duplicate answers the wide lookup but not the active one",
       %{tenant: tenant, group_id: group_id} do
    disabled =
      seed_legacy!(tenant, group_id, "A-DISDUP", %{"disabled_at" => 1})

    enabled = seed_legacy!(tenant, group_id, "A-DISDUP")

    # Active lookup: only the enabled record qualifies.
    assert {:ok, found} =
             SalixIM.ProviderIdentity.find_active_slack_im_connect_by_app_id("A-DISDUP")

    assert found["connect_id"] == enabled["connect_id"]

    # Wide lookup: main took the first live oauth-completed record in key
    # order — either duplicate satisfies it; assert it routes to one of
    # them and never errs.
    assert {:ok, wide} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-DISDUP")
    assert wide["connect_id"] in [disabled["connect_id"], enabled["connect_id"]]
  end

  test "a disconnected feishu duplicate never shadows the connected one",
       %{tenant: tenant, group_id: group_id} do
    disconnected_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, disconnected_id), %{
        "connect_id" => disconnected_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "feishu",
        "app_id" => "cli_elig",
        "status" => "disconnected",
        "created_at" => 1,
        "updated_at" => 1
      })

    connected_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connected_id), %{
        "connect_id" => connected_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "feishu",
        "app_id" => "cli_elig",
        "status" => "connected",
        "created_at" => 1,
        "updated_at" => 1
      })

    assert {:ok, found} =
             SalixIM.ProviderIdentity.find_active_feishu_im_connect_by_app_id("cli_elig")

    assert found["connect_id"] == connected_id
  end

  # ---- lazy repair converges misses to point reads ----

  test "a pre-protocol record resolves immediately and is repaired to point GETs",
       %{tenant: tenant, group_id: group_id} do
    legacy = seed_legacy!(tenant, group_id, "A-LEGACY")

    # First inbound event: scan + lazy repair.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LEGACY")
    assert found["connect_id"] == legacy["connect_id"]
    assert_scanned!()

    # Every later event: two point GETs.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LEGACY")
    no_list_in_read_log!()
  end

  test "a repair losing to a squatting stale key changes nothing — the scan still answers",
       %{tenant: tenant, group_id: group_id} do
    # A stale key squats the identity (release-failure debris pointing at
    # a gone connect). The fast path rejects it; the scan routes; the
    # lazy repair's create-once loses to the squatter — and that is fine:
    # the next lookup pays one more scan instead of ever misrouting.
    gone_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(identity_key("A-SQUAT"), %{
        "provider" => "slack",
        "identity" => "A-SQUAT",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => gone_id,
        "created_at" => 0,
        "updated_at" => 0
      })

    legacy = seed_legacy!(tenant, group_id, "A-SQUAT")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-SQUAT")
    assert found["connect_id"] == legacy["connect_id"]

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-SQUAT")
    assert found["connect_id"] == legacy["connect_id"]
    assert_scanned!()
  end

  test "the lazy repair is observable at the barrier and idempotent",
       %{tenant: tenant, group_id: group_id} do
    legacy = seed_legacy!(tenant, group_id, "A-REPAIR")

    install_barrier(:identity_fallback_reserve)

    lookup =
      Task.async(fn -> SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-REPAIR") end)

    assert_receive {:barrier_hit, :identity_fallback_reserve, barrier_pid}, 2_000
    release_barrier(barrier_pid)

    assert {:ok, found} = Task.await(lookup)
    assert found["connect_id"] == legacy["connect_id"]

    assert {:ok, %{"connect_id" => keyed}} = SalixStore.CasRecord.get(identity_key("A-REPAIR"))
    assert keyed == legacy["connect_id"]
  end

  # ---- uniqueness certification gates the repair ----

  test "duplicate live records are never cached — every lookup scans, no key is written",
       %{tenant: tenant, group_id: group_id} do
    first = seed_legacy!(tenant, group_id, "A-TWODUP")
    second = seed_legacy!(tenant, group_id, "A-TWODUP")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-TWODUP")
    assert found["connect_id"] in [first["connect_id"], second["connect_id"]]
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-TWODUP"))

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-TWODUP")
    assert_scanned!()
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-TWODUP"))
  end

  test "a deleted sibling does not veto the lazy repair",
       %{tenant: tenant, group_id: group_id} do
    # A tombstoned record with the same app_id is a legitimate former
    # holder (delete → recreate is a supported flow), not a competing
    # candidate: the live record is still globally unique among live
    # records and gets its key.
    _tombstone = seed_legacy!(tenant, group_id, "A-DELDUP", %{"deleted_at" => 1})
    live = seed_legacy!(tenant, group_id, "A-DELDUP")

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-DELDUP")
    assert found["connect_id"] == live["connect_id"]

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-DELDUP")
    assert found["connect_id"] == live["connect_id"]
    no_list_in_read_log!()
  end

  defp with_scan_page_size(size) do
    prev = Application.fetch_env(:salix_im, :identity_scan_page_size)
    Application.put_env(:salix_im, :identity_scan_page_size, size)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:salix_im, :identity_scan_page_size, value)
        :error -> Application.delete_env(:salix_im, :identity_scan_page_size)
      end
    end)
  end

  test "a later-page LIST fault after the answer keeps the answer, suppresses the repair",
       %{tenant: tenant, group_id: group_id} do
    # The reviewer's multi-page witness: the answer lands on page 1, and
    # the page-2 LIST faults. A LIST fault with an answer already
    # selected degrades only the uniqueness proof (main-compatible
    # answer stands, repair suppressed), never the answer.
    with_scan_page_size(1)

    answer_id = "aaaa-answer"
    filler_id = "zzzz-filler"

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, answer_id), %{
        "connect_id" => answer_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-PAGEFAULT",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, filler_id), %{
        "connect_id" => filler_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-PAGEFILLER",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    # First LIST passes through (page 1 = the answer); second LIST faults.
    SalixStore.S3.Fake.set_fault({:delay, 0, :list, :any})
    SalixStore.S3.Fake.set_fault({:fail, 503, :list, :any})

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-PAGEFAULT")
    assert found["connect_id"] == answer_id
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-PAGEFAULT"))

    # Clean walk next time proves uniqueness and repairs.
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-PAGEFAULT")

    assert {:ok, %{"connect_id" => ^answer_id}} =
             SalixStore.CasRecord.get(identity_key("A-PAGEFAULT"))
  end

  test "a fault after the answer keeps the answer but suppresses the repair",
       %{tenant: tenant, group_id: group_id} do
    # The answer needs readability only up to itself (main's contract);
    # the uniqueness proof needs the WHOLE walk. A fault on a later
    # sibling therefore still routes but must not certify.
    answer_id = "aaaa-answer"
    sibling_id = "zzzz-sibling"

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, answer_id), %{
        "connect_id" => answer_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-TAILFAULT",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, sibling_id), %{
        "connect_id" => sibling_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-OTHER",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    SalixStore.S3.Fake.set_fault({:fail, 503, :get, Keys.ctl_im_connect(group_id, sibling_id)})

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-TAILFAULT")
    assert found["connect_id"] == answer_id
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-TAILFAULT"))

    # The fault was one-shot: the next lookup completes a clean walk,
    # proves uniqueness, and repairs.
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-TAILFAULT")

    assert {:ok, %{"connect_id" => ^answer_id}} =
             SalixStore.CasRecord.get(identity_key("A-TAILFAULT"))
  end

  test "a record whose body lies about its location answers but is never keyed",
       %{tenant: tenant, group_id: group_id} do
    # Round-10: the lazy repair validates the answer's body coordinates
    # against its PHYSICAL storage key. A lying body would produce an
    # authority pointing at nothing — a permanent squatter — so the
    # record serves via the scan, forever, and no key is written.
    physical_key = Keys.ctl_im_connect(group_id, "real-conn")

    {:ok, _} =
      SalixStore.CasRecord.create(physical_key, %{
        "connect_id" => "lie-conn",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-LIEBODY",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LIEBODY")
    assert found["connect_id"] == "lie-conn"
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-LIEBODY"))

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LIEBODY")
    assert_scanned!()
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-LIEBODY"))
  end

  # ---- the scan-concurrency permit ----

  defp cap_scans!(cap) do
    prev = Application.fetch_env(:salix_im, :identity_scan_max_concurrency)
    Application.put_env(:salix_im, :identity_scan_max_concurrency, cap)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:salix_im, :identity_scan_max_concurrency, value)
        :error -> Application.delete_env(:salix_im, :identity_scan_max_concurrency)
      end
    end)
  end

  test "scans over the concurrency bound are rejected retryably — the fast path is unaffected",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-CAP")
    complete_oauth!(connect)

    test_pid = self()

    :telemetry.attach(
      "identity-cap-#{inspect(self())}",
      [:salix, :im, :identity_resolution],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:resolution, metadata[:result]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("identity-cap-#{inspect(test_pid)}") end)

    cap_scans!(0)

    # Two point GETs need no permit.
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-CAP")
    assert_receive {:resolution, "fast_hit"}

    # Any fallback is over capacity: a retryable rejection, never a 404.
    assert {:error, :scan_capacity_exhausted} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-CAP")

    assert_receive {:resolution, "rejected"}

    # Permits release: a bound of one serves sequential scans normally.
    Application.put_env(:salix_im, :identity_scan_max_concurrency, 1)

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-CAP")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-CAP")
  end

  test "an in-flight scan holds the only permit — a concurrent fallback is rejected",
       %{tenant: tenant, group_id: group_id} do
    legacy = seed_legacy!(tenant, group_id, "A-HOLD")

    cap_scans!(1)
    install_barrier(:identity_fallback_settle)

    holder =
      Task.async(fn -> SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-HOLD") end)

    assert_receive {:barrier_hit, :identity_fallback_settle, barrier_pid}, 2_000

    assert {:error, :scan_capacity_exhausted} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-HOLD")

    release_barrier(barrier_pid)
    assert {:ok, found} = Task.await(holder)
    assert found["connect_id"] == legacy["connect_id"]

    # The permit was released with the scan: fallbacks flow again.
    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-HOLD")
  end

  test "killing the admission owner mid-scan never admits over the cap — public path",
       %{tenant: tenant, group_id: group_id} do
    # Round-11: the permit table is owned by the application master, so
    # the ONLY killable piece is the admission owner. Crash it while a
    # real fallback holds the sole permit: the restarted owner adopts
    # the surviving occupancy and a second public lookup is rejected,
    # not admitted on top of the running scan.
    legacy = seed_legacy!(tenant, group_id, "A-OWNERKILL")

    cap_scans!(1)
    install_barrier(:identity_fallback_settle)

    holder =
      Task.async(fn ->
        SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-OWNERKILL")
      end)

    assert_receive {:barrier_hit, :identity_fallback_settle, barrier_pid}, 2_000

    old_owner = Process.whereis(SalixIM.ProviderIdentityScanLimiter)
    Process.exit(old_owner, :kill)

    new_owner =
      eventually_owner(fn ->
        case Process.whereis(SalixIM.ProviderIdentityScanLimiter) do
          pid when is_pid(pid) and pid != old_owner -> pid
          _ -> nil
        end
      end)

    assert is_pid(new_owner)

    assert {:error, :scan_capacity_exhausted} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-OWNERKILL")

    release_barrier(barrier_pid)
    assert {:ok, found} = Task.await(holder)
    assert found["connect_id"] == legacy["connect_id"]

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-UNKNOWN-OWNERKILL")
  end

  defp eventually_owner(fun, tries \\ 200) do
    case fun.() do
      nil ->
        if tries <= 0 do
          nil
        else
          Process.sleep(5)
          eventually_owner(fun, tries - 1)
        end

      value ->
        value
    end
  end

  # ---- blank identities are rejected consistently ----

  test "a blank app_id is rejected before the key read and the scan" do
    SalixStore.S3.Fake.reset_read_log()

    assert {:error, :not_found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("")
    assert {:error, :not_found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id(nil)
    assert {:error, :not_found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("   ")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id(nil)

    assert SalixStore.S3.Fake.read_log() == []
  end

  # ---- the reserved (materialization) reader shares the contract ----

  test "the reserved lookup survives key deletion via the same fallback",
       %{tenant: tenant, group_id: group_id} do
    # Round-11: every authority-key reader must survive key deletion.
    # A pending (pre-OAuth) reservation stays findable with its key
    # gone: the scan answers, the repair re-keys it, and the next
    # lookup is two point GETs again.
    pending = create_slack!(tenant, group_id, "A-RESERVED")

    :ok = SalixStore.S3.delete(identity_key("A-RESERVED"))

    assert {:ok, found} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-RESERVED")

    assert found["connect_id"] == pending["connect_id"]

    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-RESERVED")
    no_list_in_read_log!()
  end

  test "a padded legacy record stays reusable to the reserved reader, before and after audit",
       %{tenant: tenant, group_id: group_id} do
    # Round-12: the previous release's reserved reader trimmed the
    # record's app_id; that lenience is preserved for the reserved
    # surface only. The inbound-exact repair never mints a key for it.
    padded_id = SalixStore.Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, padded_id), %{
        "connect_id" => padded_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => " A-PAD ",
        "created_at" => 1,
        "updated_at" => 1
      })

    # The write-shaped key main would have (trimmed identity, real coords).
    {:ok, _} =
      SalixStore.CasRecord.create(identity_key("A-PAD"), %{
        "provider" => "slack",
        "identity" => "A-PAD",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => padded_id,
        "created_at" => 0,
        "updated_at" => 0
      })

    # Reusable through the key (fast path, trim-lenient predicate)...
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-PAD")
    assert found["connect_id"] == padded_id
    no_list_in_read_log!()

    # ...and still reusable after the audit deletes the key (the record
    # answers the scan; the inbound lookup stays an exact miss).
    :ok = SalixStore.S3.delete(identity_key("A-PAD"))
    assert {:ok, found} = SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-PAD")
    assert found["connect_id"] == padded_id
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-PAD"))

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-PAD")
  end

  test "reserved lookups never emit the inbound identity-resolution metric",
       %{tenant: tenant, group_id: group_id} do
    connect = create_slack!(tenant, group_id, "A-QUIET")
    complete_oauth!(connect)

    test_pid = self()

    :telemetry.attach(
      "reserved-quiet-#{inspect(self())}",
      [:salix, :im, :identity_resolution],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:resolution, metadata[:result]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("reserved-quiet-#{inspect(test_pid)}") end)

    # Fast hit and fallback miss on the reserved surface: silence.
    assert {:ok, _} = SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-QUIET")

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-QUIET-NONE")

    refute_receive {:resolution, _}, 100

    # The same corpus through the inbound surface still emits.
    assert {:ok, _} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-QUIET")
    assert_receive {:resolution, "fast_hit"}
  end
end
