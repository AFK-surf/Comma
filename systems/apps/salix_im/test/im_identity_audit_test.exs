defmodule SalixIM.IMIdentityAuditTest do
  @moduledoc """
  Operator audit of authority keys against the canonical corpus
  (`SalixIM.ProviderIdentityAudit`): certification judges the FULL
  physical address through the fast path's own contract
  (`SalixIM.ProviderIdentity.authority_target/3`) — storage-key round-trip,
  sole live carrier's
  physical location, exact canonical app_id — so a certified key is
  exactly a key the runtime honors. `fix/2` deletes conditionally on
  the observed etag under an explicit no-writer gate, and a `changed`
  result fails the operator procedure.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SalixIM.Release
  alias SalixIM.ProviderIdentityAudit
  alias SalixStore.Keys

  defmodule MockSlackAuthAPI do
    use Plug.Builder

    plug(:dispatch)

    defp dispatch(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("date", "Wed, 23 Jul 2026 04:00:00 GMT")
      |> send_resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "bot_id" => "B-mat",
          "user_id" => "U-mat",
          "user" => "comma-mat-bot",
          "team_id" => "T-mat",
          "team" => "Mat WS"
        })
      )
    end
  end

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)

    on_exit(fn ->
      case prev_s3 do
        nil -> Application.delete_env(:salix_store, :s3_backend)
        value -> Application.put_env(:salix_store, :s3_backend, value)
      end
    end)

    {:ok, tenant: tenant, group_id: group_id}
  end

  defp seed_connect!(tenant, group_id, app_id, extra \\ %{}) do
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

  defp seed_key!(tenant, group_id, app_id, connect_id) do
    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_provider_identity("slack", app_id), %{
        "provider" => "slack",
        "identity" => app_id,
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => connect_id,
        "created_at" => 0,
        "updated_at" => 0
      })
  end

  defp identity_key(app_id), do: Keys.ctl_im_provider_identity("slack", app_id)

  defp statuses(report) do
    Map.new(report.certified ++ report.deprecated, &{&1.key, &1.status})
  end

  test "materialization persists auth.test username when reusing a legacy OAuth-complete connect",
       %{tenant: tenant, group_id: group_id} do
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

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
    previous_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    on_exit(fn ->
      case previous_base do
        nil -> Application.delete_env(:salix_im, :slack_api_base_url)
        value -> Application.put_env(:salix_im, :slack_api_base_url, value)
      end
    end)

    attrs = %{
      "app_id" => "A-LEGACY-USERNAME",
      "client_id" => "client-legacy",
      "client_secret" => "secret-legacy",
      "signing_secret" => "sign-legacy",
      "bot_token" => "xoxb-legacy",
      "inbound_agent_id" => agent["agent_id"]
    }

    legacy =
      seed_connect!(tenant, group_id, attrs["app_id"], %{
        "inbound_agent_id" => agent["agent_id"],
        "workspace_id" => "T-mat",
        "bot_token" => attrs["bot_token"],
        "bot_id" => "B-mat",
        "bot_user_id" => "U-mat",
        "oauth_completed_at" => 1
      })

    seed_key!(tenant, group_id, attrs["app_id"], legacy["connect_id"])
    refute Map.has_key?(legacy, "bot_username")

    assert {:ok, reused} = SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)
    assert reused["connect_id"] == legacy["connect_id"]
    assert reused["bot_username"] == "comma-mat-bot"

    assert {:ok, stored} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, legacy["connect_id"]))

    assert stored["bot_username"] == "comma-mat-bot"
  end

  test "certification judges the full physical address, never body claims",
       %{tenant: tenant, group_id: group_id} do
    certified = seed_connect!(tenant, group_id, "A-CERT")
    seed_key!(tenant, group_id, "A-CERT", certified["connect_id"])

    dup_a = seed_connect!(tenant, group_id, "A-DUPG")
    _dup_b = seed_connect!(tenant, group_id, "A-DUPG")
    seed_key!(tenant, group_id, "A-DUPG", dup_a["connect_id"])

    seed_key!(tenant, group_id, "A-GONE", "no-such-connect")

    # Round-10 witness 1: a well-formed body whose identity is NOT
    # trim-stable, stored at the trimmed identity's hashed key. No
    # trimmed lookup can ever match it exactly — unreachable debris.
    {:ok, _} =
      SalixStore.S3.put(
        identity_key("A-W1"),
        Jason.encode!(%{
          "provider" => "slack",
          "identity" => " A-W1 ",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => "whatever"
        })
      )

    # Right connect_id, WRONG group — addresses a nonexistent canonical.
    wrong_group = seed_connect!(tenant, group_id, "A-WG")
    seed_key!(tenant, "grp_wrongwrongwrong", "A-WG", wrong_group["connect_id"])

    mismatched = seed_connect!(tenant, group_id, "A-MM")
    seed_key!(tenant, group_id, "A-MM", "some-other-connect")
    _ = mismatched

    {:ok, _} = SalixStore.S3.put(identity_key("A-BADKEY"), "{not json")

    # Mis-addressed: a well-formed body for identity R physically stored
    # at S's key — the fast path computes keys from the lookup id, so
    # this can never be read for R and squats S.
    {:ok, _} =
      SalixStore.S3.put(
        identity_key("A-STOREDHERE"),
        Jason.encode!(%{
          "provider" => "slack",
          "identity" => "A-CLAIMSTHIS",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => "whatever"
        })
      )

    # A tombstoned former holder must not spoil certification.
    tombstoned = seed_connect!(tenant, group_id, "A-TOMB", %{"deleted_at" => 1})
    replacement = seed_connect!(tenant, group_id, "A-TOMB")
    seed_key!(tenant, group_id, "A-TOMB", replacement["connect_id"])
    _ = tombstoned

    assert {:ok, report} = ProviderIdentityAudit.audit()

    assert statuses(report) == %{
             identity_key("A-CERT") => :certified,
             identity_key("A-TOMB") => :certified,
             identity_key("A-DUPG") => :duplicate,
             identity_key("A-GONE") => :dangling,
             identity_key("A-W1") => :malformed,
             identity_key("A-WG") => :mismatched,
             identity_key("A-MM") => :mismatched,
             identity_key("A-BADKEY") => :malformed,
             identity_key("A-STOREDHERE") => :malformed
           }

    assert Map.keys(report.duplicate_groups) == [{"slack", "A-DUPG"}]
    assert report.malformed_records == 0
    assert report.misaddressed_records == []

    # The wrong-group key is deprecated debris the fast path ignores:
    # the lookup falls back to the scan and routes the real connect.
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-WG")
    assert found["connect_id"] == wrong_group["connect_id"]
  end

  test "a lying canonical is never certified through, and its WORKING key survives",
       %{tenant: tenant, group_id: group_id} do
    # Round-10 witnesses 2 + 3: a canonical physically stored at
    # (group, real-c) whose body claims connect "lie-c".
    physical_key = Keys.ctl_im_connect(group_id, "real-c")

    {:ok, _} =
      SalixStore.CasRecord.create(physical_key, %{
        "connect_id" => "lie-c",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-LIE",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    # Witness 2: an authority pointing at the LIE coordinates addresses
    # nothing — deprecated, not certified.
    seed_key!(tenant, group_id, "A-LIE", "lie-c")
    assert {:ok, report} = ProviderIdentityAudit.audit()
    assert statuses(report)[identity_key("A-LIE")] == :mismatched
    assert report.misaddressed_records == [physical_key]

    # Witness 3: an authority pointing at the REAL physical address is
    # exactly what the fast path honors — certified and KEPT by --fix.
    :ok = SalixStore.S3.delete(identity_key("A-LIE"))

    {:ok, _} =
      SalixStore.CasRecord.create(identity_key("A-LIE"), %{
        "provider" => "slack",
        "identity" => "A-LIE",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => "real-c",
        "created_at" => 0,
        "updated_at" => 0
      })

    assert {:ok, report} = ProviderIdentityAudit.run(fix: true, no_writer_gate: true)
    assert statuses(report)[identity_key("A-LIE")] == :certified
    assert report.deleted == 0
    assert {:ok, _} = SalixStore.S3.get(identity_key("A-LIE"))

    # And it really fast-hits: two point GETs, zero LISTs.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-LIE")
    assert found["app_id"] == "A-LIE"

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, _prefix, _opts} -> true
             _ -> false
           end)
  end

  test "non-binary canonical coordinates never crash the audit",
       %{tenant: tenant, group_id: group_id} do
    # A live record with binary provider/app_id but map group_id: it
    # counts in the census (the runtime counts it too) and is reported
    # misaddressed; a duplicate group containing it renders safely.
    physical_key = Keys.ctl_im_connect(group_id, "map-group-conn")

    {:ok, _} =
      SalixStore.CasRecord.create(physical_key, %{
        "connect_id" => "map-group-conn",
        "tenant_id" => tenant,
        "group_id" => %{"nested" => true},
        "provider" => "slack",
        "app_id" => "A-MAPG",
        "oauth_completed_at" => 1,
        "created_at" => 1,
        "updated_at" => 1
      })

    _sibling = seed_connect!(tenant, group_id, "A-MAPG")

    assert {:ok, report} = ProviderIdentityAudit.audit()
    assert physical_key in report.misaddressed_records

    assert [group] = Enum.filter(report.duplicate_groups, fn {{_p, id}, _} -> id == "A-MAPG" end)
    rendered = ProviderIdentityAudit.format_duplicate(group)
    assert rendered =~ "A-MAPG"
    assert rendered =~ physical_key
  end

  test "--fix requires the explicit no-writer gate", %{tenant: tenant, group_id: group_id} do
    seed_key!(tenant, group_id, "A-GATE", "no-such-connect")

    assert {:ok, report} = ProviderIdentityAudit.audit()
    assert {:error, :no_writer_gate_required} = ProviderIdentityAudit.fix(report)
    assert {:error, :no_writer_gate_required} = ProviderIdentityAudit.run(fix: true)

    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.identity_audit(fix: true)
    end

    # The key is untouched by a gate-refused fix.
    assert {:ok, _} = SalixStore.S3.get(identity_key("A-GATE"))
  end

  test "--fix deletes the deletable classes and PRESERVES explicit duplicate owners",
       %{tenant: tenant, group_id: group_id} do
    certified = seed_connect!(tenant, group_id, "A-CERT")
    seed_key!(tenant, group_id, "A-CERT", certified["connect_id"])

    dup_a = seed_connect!(tenant, group_id, "A-DUPG")
    _dup_b = seed_connect!(tenant, group_id, "A-DUPG")
    seed_key!(tenant, group_id, "A-DUPG", dup_a["connect_id"])

    mismatched = seed_connect!(tenant, group_id, "A-MM")
    seed_key!(tenant, group_id, "A-MM", "some-other-connect")

    assert {:ok, report} = ProviderIdentityAudit.run(fix: true, no_writer_gate: true)
    assert report.deleted == 1
    assert report.changed == 0
    assert report.preserved_duplicates == 1

    # The certified key survives; the mismatched key is gone; the
    # duplicate-group key is deprecated but PRESERVED — it is the only
    # thing steering the mutation-capable reserved reader at the
    # operator's intended record until the duplicates are settled.
    assert {:ok, _} = SalixStore.S3.get(identity_key("A-CERT"))
    assert {:ok, _} = SalixStore.S3.get(identity_key("A-DUPG"))
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-MM"))

    # The unique identity re-certifies lazily on the next lookup.
    assert {:ok, found} = SalixIM.ProviderIdentity.find_slack_im_connect_by_app_id("A-MM")
    assert found["connect_id"] == mismatched["connect_id"]
    assert {:ok, %{"connect_id" => keyed}} = SalixStore.CasRecord.get(identity_key("A-MM"))
    assert keyed == mismatched["connect_id"]

    # The preserved key keeps naming the intended duplicate for the
    # reserved (mutation) reader.
    assert {:ok, reserved} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-DUPG")

    assert reserved["connect_id"] == dup_a["connect_id"]
  end

  test "the reserved reader never returns a record whose body lies about its location",
       %{tenant: tenant, group_id: group_id} do
    # Round-12 A→B witness: physical A claims B's connect_id; A's
    # authority points at PHYSICAL A (certified). The mutation-capable
    # reserved reader must refuse A — materialization derives its OAuth
    # write key from body coordinates, and honoring A would write into
    # B's record.
    b = seed_connect!(tenant, group_id, "B-CROSS")

    physical_a = Keys.ctl_im_connect(group_id, "conn-a")

    {:ok, _} =
      SalixStore.CasRecord.create(physical_a, %{
        "connect_id" => b["connect_id"],
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-CROSS",
        "created_at" => 1,
        "updated_at" => 1
      })

    {:ok, _} =
      SalixStore.CasRecord.create(identity_key("A-CROSS"), %{
        "provider" => "slack",
        "identity" => "A-CROSS",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => "conn-a",
        "created_at" => 0,
        "updated_at" => 0
      })

    # The audit certifies the key (it addresses physical A) but reports
    # the record misaddressed — and the clean gate now FAILS on it.
    assert {:ok, report} = ProviderIdentityAudit.audit()
    assert statuses(report)[identity_key("A-CROSS")] == :certified
    assert report.misaddressed_records == [physical_a]

    assert_raise RuntimeError, ~r/misaddressed/, fn ->
      Release.enforce_clean_audit!(report)
    end

    # The reserved reader refuses A entirely (fast path AND fallback);
    # B's record is never touched.
    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-CROSS")

    {:ok, b_after} = SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, b["connect_id"]))
    assert b_after["app_id"] == "B-CROSS"
    refute Map.has_key?(b_after, "bot_token")
  end

  test "materialization cannot cross-mutate through a lying record — end to end",
       %{tenant: tenant, group_id: group_id} do
    # Full domain E2E of the round-12 witness: materializing the lying
    # identity must NOT write OAuth data into the innocent sibling.
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

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
    prev_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    on_exit(fn ->
      case prev_base do
        nil -> Application.delete_env(:salix_im, :slack_api_base_url)
        value -> Application.put_env(:salix_im, :slack_api_base_url, value)
      end
    end)

    b = seed_connect!(tenant, group_id, "B-INNOCENT", %{"oauth_completed_at" => 0})
    physical_a = Keys.ctl_im_connect(group_id, "conn-lying")

    {:ok, _} =
      SalixStore.CasRecord.create(physical_a, %{
        "connect_id" => b["connect_id"],
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-LYING",
        "inbound_agent_id" => agent["agent_id"],
        "created_at" => 1,
        "updated_at" => 1
      })

    attrs = %{
      "app_id" => "A-LYING",
      "client_id" => "client-x",
      "client_secret" => "secret-x",
      "signing_secret" => "sign-x",
      "bot_token" => "xoxb-x",
      "inbound_agent_id" => agent["agent_id"]
    }

    # The reserved reader refuses the lying record → create path →
    # the write protocol's own conflict check rejects (the lying record
    # still carries the app_id). A visible error, never a cross-write.
    assert {:error, {:bad_request, message}} =
             SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)

    assert message =~ "already used"

    {:ok, b_after} = SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, b["connect_id"]))
    assert b_after["app_id"] == "B-INNOCENT"
    refute Map.has_key?(b_after, "bot_token")
    assert (b_after["oauth_completed_at"] || 0) == 0
  end

  test "a duplicate corpus with no authority is a conflict, not a LIST-order write target",
       %{tenant: tenant, group_id: group_id} do
    # Round-13 witness: the intended pending reservation plus an
    # earlier-sorting same-app duplicate, with the authority deleted.
    # Physical LIST order must NOT decide which record materialization
    # mutates — the previous release reported an identity conflict here
    # (key-only miss → create → ensure_available), and so must we.
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

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
    prev_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    on_exit(fn ->
      case prev_base do
        nil -> Application.delete_env(:salix_im, :slack_api_base_url)
        value -> Application.put_env(:salix_im, :slack_api_base_url, value)
      end
    end)

    attrs = %{
      "app_id" => "A-AMBIG",
      "client_id" => "client-a",
      "client_secret" => "secret-a",
      "signing_secret" => "sign-a",
      "bot_token" => "xoxb-a",
      "inbound_agent_id" => agent["agent_id"]
    }

    {:ok, intended} =
      SalixIM.ProviderConnects.create_slack_im_connect(
        tenant,
        group_id,
        Map.take(attrs, ~w(app_id client_id client_secret signing_secret inbound_agent_id))
      )

    # An earlier-sorting duplicate carrying the same app_id, and no key.
    duplicate_key = Keys.ctl_im_connect(group_id, "000-duplicate")

    {:ok, _} =
      SalixStore.CasRecord.create(duplicate_key, %{
        "connect_id" => "000-duplicate",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "provider" => "slack",
        "app_id" => "A-AMBIG",
        "inbound_agent_id" => agent["agent_id"],
        "created_at" => 1,
        "updated_at" => 1
      })

    :ok = SalixStore.S3.delete(identity_key("A-AMBIG"))

    assert {:error, {:conflict, message}} =
             SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)

    assert message =~ "multiple connects"

    # Neither record was mutated: the duplicate is untouched and the
    # intended reservation is still pending.
    {:ok, duplicate_after} = SalixStore.CasRecord.get(duplicate_key)
    refute Map.has_key?(duplicate_after, "bot_token")
    assert (duplicate_after["oauth_completed_at"] || 0) == 0

    {:ok, intended_after} =
      SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, intended["connect_id"]))

    assert (intended_after["oauth_completed_at"] || 0) == 0

    # No authority was minted from the ambiguous corpus.
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-AMBIG"))

    # An explicit key over the duplicates IS honored — that is the
    # operator's deliberate choice, validated on the fast path.
    {:ok, _} =
      SalixStore.CasRecord.create(identity_key("A-AMBIG"), %{
        "provider" => "slack",
        "identity" => "A-AMBIG",
        "tenant_id" => tenant,
        "group_id" => group_id,
        "connect_id" => intended["connect_id"],
        "created_at" => 0,
        "updated_at" => 0
      })

    assert {:ok, reused} = SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)
    assert reused["connect_id"] == intended["connect_id"]
  end

  # Round-14: a census truncated by a storage fault is NOT a uniqueness
  # proof either. Both fault shapes (tail per-record GET, later-page
  # LIST) must refuse the mutation surface rather than let the
  # first-sorting record become the OAuth write target.
  for {label, fault} <- [tail_get: :get, later_page_list: :list] do
    test "an #{label} fault leaves the census unproven — materialization refuses",
         %{tenant: tenant, group_id: group_id} do
      fault_op = unquote(fault)

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

      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
      prev_base = Application.get_env(:salix_im, :slack_api_base_url)
      Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

      prev_page = Application.fetch_env(:salix_im, :identity_scan_page_size)

      on_exit(fn ->
        case prev_base do
          nil -> Application.delete_env(:salix_im, :slack_api_base_url)
          value -> Application.put_env(:salix_im, :slack_api_base_url, value)
        end

        case prev_page do
          {:ok, value} -> Application.put_env(:salix_im, :identity_scan_page_size, value)
          :error -> Application.delete_env(:salix_im, :identity_scan_page_size)
        end
      end)

      attrs = %{
        "app_id" => "A-UNPROVEN",
        "client_id" => "client-u",
        "client_secret" => "secret-u",
        "signing_secret" => "sign-u",
        "bot_token" => "xoxb-u",
        "inbound_agent_id" => agent["agent_id"]
      }

      # The earlier-sorting record answers first; the intended pending
      # reservation sorts after it and is what the fault hides.
      first_key = Keys.ctl_im_connect(group_id, "000-first")

      {:ok, _} =
        SalixStore.CasRecord.create(first_key, %{
          "connect_id" => "000-first",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "provider" => "slack",
          "app_id" => "A-UNPROVEN",
          "inbound_agent_id" => agent["agent_id"],
          "created_at" => 1,
          "updated_at" => 1
        })

      intended_key = Keys.ctl_im_connect(group_id, "zzz-intended")

      {:ok, _} =
        SalixStore.CasRecord.create(intended_key, %{
          "connect_id" => "zzz-intended",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "provider" => "slack",
          "app_id" => "A-UNPROVEN",
          "inbound_agent_id" => agent["agent_id"],
          "created_at" => 1,
          "updated_at" => 1
        })

      :ok = SalixStore.S3.delete(identity_key("A-UNPROVEN"))

      case fault_op do
        :get ->
          # The answer is readable; the later sibling's GET faults.
          SalixStore.S3.Fake.set_fault({:fail, 503, :get, intended_key})

        :list ->
          # Page 1 carries the answer; the page-2 LIST faults.
          Application.put_env(:salix_im, :identity_scan_page_size, 1)
          SalixStore.S3.Fake.set_fault({:delay, 0, :list, :any})
          SalixStore.S3.Fake.set_fault({:fail, 503, :list, :any})
      end

      assert {:error, :identity_census_unavailable} =
               SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)

      # Neither record was mutated and no authority was minted from the
      # partial census.
      {:ok, first_after} = SalixStore.CasRecord.get(first_key)
      refute Map.has_key?(first_after, "bot_token")
      assert (first_after["oauth_completed_at"] || 0) == 0

      {:ok, intended_after} = SalixStore.CasRecord.get(intended_key)
      refute Map.has_key?(intended_after, "bot_token")
      assert (intended_after["oauth_completed_at"] || 0) == 0

      assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-UNPROVEN"))
    end
  end

  test "materialization surfaces resolver capacity rejection as a retryable error",
       %{tenant: tenant, group_id: group_id} do
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

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
    prev_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    prev_cap = Application.fetch_env(:salix_im, :identity_scan_max_concurrency)
    Application.put_env(:salix_im, :identity_scan_max_concurrency, 0)

    on_exit(fn ->
      case prev_base do
        nil -> Application.delete_env(:salix_im, :slack_api_base_url)
        value -> Application.put_env(:salix_im, :slack_api_base_url, value)
      end

      case prev_cap do
        {:ok, value} -> Application.put_env(:salix_im, :identity_scan_max_concurrency, value)
        :error -> Application.delete_env(:salix_im, :identity_scan_max_concurrency)
      end
    end)

    attrs = %{
      "app_id" => "A-CAPPED",
      "client_id" => "client-c",
      "client_secret" => "secret-c",
      "signing_secret" => "sign-c",
      "bot_token" => "xoxb-c",
      "inbound_agent_id" => agent["agent_id"]
    }

    # No key exists → the reserved lookup needs the fallback → the
    # permit rejects → the error propagates as a structured retryable
    # result instead of a CaseClauseError crash.
    assert {:error, :scan_capacity_exhausted} =
             SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)
  end

  test "a key replaced between verdict and delete is skipped and fails the gate procedure",
       %{tenant: tenant, group_id: group_id} do
    # Classify a dangling key, then a foreground writer replaces it with
    # a fresh live reservation. The conditional delete on the stale etag
    # must 412 and leave the new lock intact — and the operator
    # procedure must FAIL (changed > 0 disproves the no-writer claim).
    seed_key!(tenant, group_id, "A-RACE", "no-such-connect")

    assert {:ok, report} = ProviderIdentityAudit.audit()
    assert [%{key: race_key}] = report.deprecated

    replacement = seed_connect!(tenant, group_id, "A-RACE")

    {:ok, _} =
      SalixStore.S3.put(
        race_key,
        Jason.encode!(%{
          "provider" => "slack",
          "identity" => "A-RACE",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => replacement["connect_id"]
        })
      )

    assert {:ok, %{deleted: 0, changed: 1} = counts} =
             ProviderIdentityAudit.fix(report, no_writer_gate: true)

    # The new live lock survived and still resolves.
    assert {:ok, %{"connect_id" => keyed}} = SalixStore.CasRecord.get(race_key)
    assert keyed == replacement["connect_id"]

    # changed > 0 must abort the procedure, not proceed.
    assert_raise RuntimeError, ~r/writer was active/, fn ->
      Release.enforce_clean_fix!(Map.merge(report, counts))
    end
  end

  test "the release entrypoint runs storage-only and succeeds on a clean corpus",
       %{tenant: tenant, group_id: group_id} do
    certified = seed_connect!(tenant, group_id, "A-REL")
    seed_key!(tenant, group_id, "A-REL", certified["connect_id"])

    assert capture_io(fn ->
             assert :ok = Release.identity_audit(fix: true, confirm_no_writers: true)
           end) =~ "1 certified"
  end

  test "assert_clean is a hard gate: dirty corpus fails, cleaned corpus passes",
       %{tenant: tenant, group_id: group_id} do
    seed_key!(tenant, group_id, "A-DIRTY", "no-such-connect")

    capture_io(fn ->
      assert_raise RuntimeError, ~r/audit not clean/, fn ->
        Release.identity_audit(assert_clean: true)
      end
    end)

    capture_io(fn ->
      assert :ok = Release.identity_audit(fix: true, confirm_no_writers: true)
      assert :ok = Release.identity_audit(assert_clean: true)
    end)
  end

  test "materialization reuse survives the audit fix — the reserved reader shares the contract",
       %{tenant: tenant, group_id: group_id} do
    # Round-11 witness: a reusable pending reservation whose key the
    # audit deprecates. Reuse must keep working THROUGH the fix (scan
    # fallback), and the retry must re-certify the key.
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

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!({Bandit, plug: MockSlackAuthAPI, port: port})
    prev_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    on_exit(fn ->
      case prev_base do
        nil -> Application.delete_env(:salix_im, :slack_api_base_url)
        value -> Application.put_env(:salix_im, :slack_api_base_url, value)
      end
    end)

    attrs = %{
      "app_id" => "A-MAT",
      "client_id" => "client-mat",
      "client_secret" => "secret-mat",
      "signing_secret" => "sign-mat",
      "bot_token" => "xoxb-mat",
      "inbound_agent_id" => agent["agent_id"]
    }

    {:ok, pending} =
      SalixIM.ProviderConnects.create_slack_im_connect(
        tenant,
        group_id,
        Map.take(attrs, ~w(app_id client_id client_secret signing_secret inbound_agent_id))
      )

    # A legacy non-trim-stable body squats the correct storage key: the
    # audit will deprecate it as malformed.
    {:ok, _} =
      SalixStore.S3.put(
        identity_key("A-MAT"),
        Jason.encode!(%{
          "provider" => "slack",
          "identity" => " A-MAT ",
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => pending["connect_id"]
        })
      )

    # Reuse works BEFORE the fix (fallback past the malformed key).
    assert {:ok, first} = SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)
    assert first["connect_id"] == pending["connect_id"]

    # The audit deprecates the squatting key and deletes it under the gate.
    assert {:ok, report} = ProviderIdentityAudit.run(fix: true, no_writer_gate: true)
    assert statuses(report)[identity_key("A-MAT")] == :malformed
    assert report.changed == 0
    assert {:error, :not_found} = SalixStore.S3.get(identity_key("A-MAT"))

    # Retry AFTER the fix still reuses the same connect — and the lazy
    # repair re-certifies the key.
    assert {:ok, second} = SalixIM.SlackMaterialization.materialize(tenant, group_id, attrs)
    assert second["connect_id"] == pending["connect_id"]

    assert {:ok, verify} = ProviderIdentityAudit.audit()
    assert statuses(verify)[identity_key("A-MAT")] == :certified
  end

  test "the audit is fail-closed on storage faults", %{tenant: tenant, group_id: group_id} do
    _connect = seed_connect!(tenant, group_id, "A-FAULT")

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, :any})
    assert {:error, {:audit_scan_failed, _, _}} = ProviderIdentityAudit.audit()
  end
end
