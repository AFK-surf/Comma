defmodule CommaWeb.ColabPluginTest do
  use Comma.DataCase, async: false

  alias Comma.{Accounts, Plugins}
  alias CommaWeb.PluginConnections
  alias SalixAgent.Colab.{Account, Leases}

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    prev_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "colab-plugin-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    {:ok, session} = Accounts.create_session(user["id"])
    workspace = create_ready_workspace!(user)

    on_exit(fn ->
      if is_nil(prev_oauth),
        do: SystemsRuntime.delete_env(:salix_agent, :colab_oauth),
        else: SystemsRuntime.put_env(:salix_agent, :colab_oauth, prev_oauth)

      cleanup_colab_tables(workspace["salix_tenant_id"], workspace["default_group_id"])
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    %{user: user, session: session, token: session["token"], workspace: workspace}
  end

  test "catalog gates google-colab on plugin-oauth-code capability and emits credentialSetup: nil",
       ctx do
    without_cap =
      call(:get, "/v1/comma/workspaces/#{ctx.workspace["id"]}/plugins", nil, ctx.token)

    assert without_cap.status == 200
    refute Enum.any?(json(without_cap)["data"], &(&1["id"] == "google-colab"))

    with_cap =
      call(
        :get,
        "/v1/comma/workspaces/#{ctx.workspace["id"]}/plugins",
        nil,
        ctx.token,
        [{"x-comma-client-capabilities", "plugin-oauth-code"}]
      )

    assert with_cap.status == 200
    colab = Enum.find(json(with_cap)["data"], &(&1["id"] == "google-colab"))
    assert colab["name"] == "Google Colab"
    assert colab["brand"] == "google-colab"
    assert colab["category"] == "Compute"
    assert colab["installed"] == false
    assert colab["credentialSetup"] == nil
  end

  test "legacy Comma.Plugins.install/4 guards google-colab until an active account is connected",
       ctx do
    assert {:error, {:precondition_failed, "Connect a Google Colab account first."}} =
             Plugins.install(ctx.user, ctx.session, ctx.workspace["id"], "google-colab")

    resp =
      call(
        :post,
        "/v1/comma/workspaces/#{ctx.workspace["id"]}/plugins/google-colab/install",
        %{},
        ctx.token,
        [{"x-comma-client-capabilities", "plugin-oauth-code"}]
      )

    assert resp.status == 412
    assert json(resp)["error"] == "Connect a Google Colab account first."
  end

  test "unified two-step install, malformed paste recovery, personal-sources, reauthorize, and 409/200 uninstall",
       ctx do
    configure_colab_oauth(
      default_plug(sub: "sub-alice", email: "alice@gmail.com", balance: 2400.0)
    )

    headers = [{"x-comma-client-capabilities", "plugin-oauth-code"}]
    wid = ctx.workspace["id"]

    # Step 1: returns configuration with format: "oauth_code", helpUrl, attemptId
    step1 =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{"contract" => "unified_v1"},
        ctx.token,
        headers
      )

    assert step1.status == 200
    step1_body = json(step1)
    assert step1_body["authorization"] == nil
    assert step1_body["plugin"]["installed"] == false
    config = step1_body["configuration"]
    assert config["key"] == "GOOGLE_COLAB_AUTH_CODE"
    assert config["label"] == "Authorization code"
    assert config["format"] == "oauth_code"
    assert is_binary(config["attemptId"]) and config["attemptId"] != ""
    assert is_binary(config["helpUrl"]) and String.contains?(config["helpUrl"], "code_challenge=")
    state = URI.decode_query(URI.parse(config["helpUrl"]).query)["state"]

    # Step 2 with malformed paste / mismatched state returns 422 without burning attempt
    bad_paste =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => config["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/ok&state=wrong"
          }
        },
        ctx.token,
        headers
      )

    assert bad_paste.status == 422
    assert json(bad_paste)["error"] == "plugin_credential_rejected"

    # Step 2 with valid redirect URL succeeds and OMITS "configuration" key
    step2 =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => config["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/good&state=#{state}"
          }
        },
        ctx.token,
        headers
      )

    assert step2.status == 200
    step2_body = json(step2)
    assert step2_body["plugin"]["id"] == "google-colab"
    assert step2_body["plugin"]["installed"] == true
    assert step2_body["authorization"] == nil
    refute Map.has_key?(step2_body, "configuration")

    # V1 single-account limit guard via mode: "add_account" -> 409
    add_second =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{"contract" => "unified_v1", "mode" => "add_account"},
        ctx.token,
        headers
      )

    assert add_second.status == 409
    assert json(add_second)["error"] == "single_account_limit_reached"

    # personal-sources returns bindingId, metadata, and ready state
    sources_resp =
      call(
        :get,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/personal-sources",
        nil,
        ctx.token
      )

    assert sources_resp.status == 200
    assert %{"pluginId" => "google-colab", "sources" => [source]} = json(sources_resp)
    assert is_binary(source["bindingId"])
    assert source["connectionId"] == "google-colab-oauth"
    assert source["toolkit"] == "google-colab"
    assert source["kind"] == "oauth_code_paste"
    assert source["state"] == "ready"
    assert source["selectedAccountId"] == "alice@gmail.com"
    assert source["candidates"] == []
    assert source["metadata"]["ccuBalance"] == 2400.0
    assert source["metadata"]["consumptionRateHourly"] == 1.96
    assert source["metadata"]["activeVmCount"] == 0

    # Reauthorize Step 1 -> Step 2 with wrong Google account -> 200 with fresh PKCE attempt
    reauth1 =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/reauthorize",
        %{"binding_id" => source["bindingId"]},
        ctx.token
      )

    assert reauth1.status == 200
    reauth_cfg = json(reauth1)["configuration"]
    assert reauth_cfg["format"] == "oauth_code"
    reauth_state = URI.decode_query(URI.parse(reauth_cfg["helpUrl"]).query)["state"]

    configure_colab_oauth(default_plug(sub: "sub-bob", email: "bob@gmail.com"))

    wrong_account =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/reauthorize",
        %{
          "binding_id" => source["bindingId"],
          "attempt_id" => reauth_cfg["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/bob&state=#{reauth_state}"
          }
        },
        ctx.token
      )

    assert wrong_account.status == 200
    reissued_cfg = json(wrong_account)["configuration"]
    assert is_binary(reissued_cfg["attemptId"])
    assert reissued_cfg["attemptId"] != reauth_cfg["attemptId"]
    assert is_binary(reissued_cfg["helpUrl"])
    assert reissued_cfg["error"] =~ "alice@gmail.com"
    reissued_query = URI.decode_query(URI.parse(reissued_cfg["helpUrl"]).query)
    assert reissued_query["login_hint"] == "alice@gmail.com"
    reissued_state = reissued_query["state"]

    # Reauthorize with matching Google account using the auto-reissued attempt succeeds
    configure_colab_oauth(default_plug(sub: "sub-alice", email: "alice@gmail.com"))

    reauth2_step2 =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/reauthorize",
        %{
          "binding_id" => source["bindingId"],
          "attempt_id" => reissued_cfg["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/alice2&state=#{reissued_state}"
          }
        },
        ctx.token
      )

    assert reauth2_step2.status == 200
    refute Map.has_key?(json(reauth2_step2), "configuration")

    # Uninstall with an assigning lease -> 409 colab_account_in_use
    {:ok, lease, _} =
      Leases.insert_assigning(
        ctx.workspace["salix_tenant_id"],
        ctx.workspace["default_group_id"],
        "session:ag:block",
        nil,
        source["bindingId"],
        %{variant: "GPU", accelerator: "G4", high_mem: false}
      )

    blocked_uninstall =
      call(:delete, "/v1/comma/workspaces/#{wid}/plugins/google-colab", nil, ctx.token)

    assert blocked_uninstall.status == 409
    assert json(blocked_uninstall)["error"] == "colab_account_in_use"

    # Once leases are cleared, uninstall returns 200 with installed: false
    {:ok, _} =
      SalixStore.Repo.query("DELETE FROM colab_vm_leases WHERE vm_id = $1", [lease.vm_id])

    ok_uninstall =
      call(:delete, "/v1/comma/workspaces/#{wid}/plugins/google-colab", nil, ctx.token)

    assert ok_uninstall.status == 200
    assert json(ok_uninstall)["installed"] == false
  end

  test "two-phase reconciler recovers unsynced installed and uninstalled states automatically on get",
       ctx do
    configure_colab_oauth(default_plug(sub: "sub-rec", email: "rec@gmail.com"))
    tenant_id = ctx.workspace["salix_tenant_id"]
    group_id = ctx.workspace["default_group_id"]

    # Simulate crash right after Account.complete_oauth_attempt (desired_state = installed, plugin_synced_generation = 0)
    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{generation: gen1}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/rec&state=#{state}",
        operation: :install
      )

    assert {:ok, %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: 0}} =
             Account.get_group_install_state(tenant_id, group_id)

    # Calling PluginConnections.get auto-reconciles installed state and marks plugin_synced_generation == gen1
    assert {:ok, status} =
             PluginConnections.get(ctx.user, ctx.session, ctx.workspace["id"], "google-colab")

    assert status["connection"]["state"] == "connected"

    assert {:ok,
            %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)

    # Simulate crash right after disconnect_all_for_group (desired_state = uninstalled, plugin_synced_generation < gen2)
    {:ok, %{generation: gen2}} = Account.disconnect_all_for_group(tenant_id, group_id)
    assert gen2 > gen1

    assert {:ok, status_after} =
             PluginConnections.get(ctx.user, ctx.session, ctx.workspace["id"], "google-colab")

    assert status_after["connection"]["state"] == "not_connected"

    assert {:ok,
            %{generation: ^gen2, desired_state: "uninstalled", plugin_synced_generation: ^gen2}} =
             Account.get_group_install_state(tenant_id, group_id)
  end

  test "legacy install serializes on colab_group_install_states and refuses after concurrent uninstall",
       ctx do
    configure_colab_oauth(default_plug(sub: "sub-legacy", email: "legacy@gmail.com"))
    tenant_id = ctx.workspace["salix_tenant_id"]
    group_id = ctx.workspace["default_group_id"]
    wid = ctx.workspace["id"]
    headers = [{"x-comma-client-capabilities", "plugin-oauth-code"}]

    # Connect account (generation 1, desired_state: installed, plugin_synced_generation: 0)
    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{generation: gen1}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/leg&state=#{state}",
        operation: :install
      )

    # Legacy install converges generation 1 and marks installed
    ok_legacy =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{},
        ctx.token,
        headers
      )

    assert ok_legacy.status == 200
    assert json(ok_legacy)["id"] == "google-colab"
    assert json(ok_legacy)["installed"] == true

    assert {:ok,
            %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)

    # Concurrent uninstall advances generation to uninstalled
    {:ok, %{generation: gen2}} = Account.disconnect_all_for_group(tenant_id, group_id)
    assert gen2 > gen1

    # Lagging legacy install request must fail with 412 and never write installed back
    stale_legacy =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{},
        ctx.token,
        headers
      )

    assert stale_legacy.status == 412
    assert json(stale_legacy)["error"] == "Connect a Google Colab account first."

    assert {:ok,
            %{generation: ^gen2, desired_state: "uninstalled", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)
  end

  test "ColabInstallReconciler.sweep_once and catalog GET recover unsynced states without detail GET",
       ctx do
    configure_colab_oauth(default_plug(sub: "sub-sweep", email: "sweep@gmail.com"))
    tenant_id = ctx.workspace["salix_tenant_id"]
    group_id = ctx.workspace["default_group_id"]
    wid = ctx.workspace["id"]
    headers = [{"x-comma-client-capabilities", "plugin-oauth-code"}]

    # Simulate crash after Account.complete_oauth_attempt (desired_state: installed, synced: 0)
    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{generation: gen1}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/swp&state=#{state}",
        operation: :install
      )

    # Startup/periodic sweep converges installed state without any detail GET
    assert {:ok, outcomes} = CommaWeb.ColabInstallReconciler.sweep_once()
    assert Enum.any?(outcomes, &match?({:ok, ^group_id, {:reconciled, ^gen1, "installed"}}, &1))

    assert {:ok,
            %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)

    assert {:ok, installed_ids} = Comma.PluginInstallations.installed_plugin_ids(wid)
    assert MapSet.member?(installed_ids, "google-colab")

    # Simulate crash after disconnect_all_for_group (desired_state: uninstalled, synced < gen2)
    {:ok, %{generation: gen2}} = Account.disconnect_all_for_group(tenant_id, group_id)
    assert gen2 > gen1

    assert {:ok, outcomes2} = CommaWeb.ColabInstallReconciler.sweep_once()

    assert Enum.any?(
             outcomes2,
             &match?({:ok, ^group_id, {:reconciled, ^gen2, "uninstalled"}}, &1)
           )

    assert {:ok,
            %{generation: ^gen2, desired_state: "uninstalled", plugin_synced_generation: ^gen2}} =
             Account.get_group_install_state(tenant_id, group_id)

    assert {:ok, installed_ids2} = Comma.PluginInstallations.installed_plugin_ids(wid)
    refute MapSet.member?(installed_ids2, "google-colab")

    # Catalog GET also reconciles an unsynced installed state automatically
    {:ok, attempt2} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state2 = URI.decode_query(URI.parse(attempt2.authorize_url).query)["state"]

    {:ok, %{generation: gen3}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        attempt2.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/cat&state=#{state2}",
        operation: :install
      )

    catalog = call(:get, "/v1/comma/workspaces/#{wid}/plugins", nil, ctx.token, headers)
    assert catalog.status == 200
    colab = Enum.find(json(catalog)["data"], &(&1["id"] == "google-colab"))
    assert colab["installed"] == true

    assert {:ok,
            %{generation: ^gen3, desired_state: "installed", plugin_synced_generation: ^gen3}} =
             Account.get_group_install_state(tenant_id, group_id)
  end

  test "ColabInstallReconciler rotates skipped unsynced rows so a later valid workspace converges",
       ctx do
    configure_colab_oauth(default_plug(sub: "sub-starve", email: "starve@gmail.com"))
    tenant_id = ctx.workspace["salix_tenant_id"]
    group_id = ctx.workspace["default_group_id"]
    now = SystemsClock.utc_now()

    # 16 older unsynced rows the reconciler can never converge: 15 groups without a
    # Comma workspace and 1 row for this workspace's group under another tenant.
    junk_tenant = SalixStore.Ids.new_tenant_id()
    other_tenant = SalixStore.Ids.new_tenant_id()

    on_exit(fn ->
      _ =
        SalixStore.Repo.query(
          "DELETE FROM colab_group_install_states WHERE tenant_id = ANY($1::text[])",
          [[junk_tenant, other_tenant]]
        )
    end)

    junk =
      for i <- 1..15 do
        {junk_tenant, SalixStore.Ids.new_group_id(junk_tenant), i}
      end ++ [{other_tenant, group_id, 16}]

    for {t, g, i} <- junk do
      {:ok, _} =
        SalixStore.Repo.query(
          """
          INSERT INTO colab_group_install_states (
            tenant_id, group_id, generation, desired_state, binding_id,
            plugin_synced_generation, updated_at
          ) VALUES ($1, $2, 1, 'installed', NULL, 0, $3)
          """,
          [t, g, DateTime.add(now, -1_000 + i, :second)]
        )
    end

    # The 17th row: a valid Comma workspace that became unsynced after the junk rows.
    {:ok, attempt} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{generation: gen1}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/stv&state=#{state}",
        operation: :install
      )

    {:ok, _} =
      SalixStore.Repo.query(
        "UPDATE colab_group_install_states SET updated_at = $3 WHERE tenant_id = $1 AND group_id = $2",
        [tenant_id, group_id, DateTime.add(now, -500, :second)]
      )

    # Stateless sweeps (no cursor) must still reach the valid row: every skipped row
    # moves to the back of the queue instead of filling each page again.
    # The first page holds only the 16 older rows; before rotation every later page
    # returned the same 16 rows and the valid workspace never converged.
    reconciled_at =
      Enum.find(1..5, fn _pass ->
        {:ok, outcomes} = CommaWeb.ColabInstallReconciler.sweep_once()
        Enum.any?(outcomes, &match?({:ok, ^group_id, {:reconciled, ^gen1, "installed"}}, &1))
      end)

    assert is_integer(reconciled_at) and reconciled_at > 1

    assert {:ok,
            %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)

    # Skipped rows stay unsynced (nothing converged them) but were rotated behind.
    for {t, g, _i} <- junk do
      assert {:ok, %{plugin_synced_generation: 0, generation: 1}} =
               Account.get_group_install_state(t, g)
    end
  end

  test "stateful ColabInstallReconciler catches a late-committed row with an older timestamp across ticks",
       ctx do
    tenant_id = ctx.workspace["salix_tenant_id"]
    group_id = ctx.workspace["default_group_id"]
    now = SystemsClock.utc_now()
    page_ts = DateTime.add(now, -200, :second)
    older_late_ts = DateTime.add(now, -201, :second)

    # Seed 16 non-Comma rows at T=page_ts so pass 1 fills a full batch and defers them.
    junk_tenant = SalixStore.Ids.new_tenant_id()

    on_exit(fn ->
      _ =
        SalixStore.Repo.query(
          "DELETE FROM colab_group_install_states WHERE tenant_id = $1",
          [junk_tenant]
        )
    end)

    for _i <- 1..16 do
      junk_group = SalixStore.Ids.new_group_id(junk_tenant)

      {:ok, _} =
        SalixStore.Repo.query(
          """
          INSERT INTO colab_group_install_states (
            tenant_id, group_id, generation, desired_state, binding_id,
            plugin_synced_generation, updated_at
          ) VALUES ($1, $2, 1, 'installed', NULL, 0, $3)
          """,
          [junk_tenant, junk_group, page_ts]
        )
    end

    # Drive the GenServer callbacks directly across ticks to verify stateful behavior.
    {:ok, state, {:continue, :startup_sweep}} =
      CommaWeb.ColabInstallReconciler.init(interval_ms: 30_000, limit: 16)

    {:noreply, state_after_pass_1} =
      CommaWeb.ColabInstallReconciler.handle_continue(:startup_sweep, state)

    # Now commit a valid Comma workspace install whose updated_at (T=page_ts-1s) is
    # OLDER than pass 1's tail timestamp (a late-committing transaction).
    configure_colab_oauth(default_plug(sub: "sub-late-commit", email: "late@example.com"))

    {:ok, started} =
      Account.start_oauth_attempt(tenant_id, group_id, ctx.user["id"], operation: :install)

    state_param = URI.decode_query(URI.parse(started.authorize_url).query)["state"]

    {:ok, %{generation: gen1}} =
      Account.complete_oauth_attempt(
        tenant_id,
        group_id,
        ctx.user["id"],
        started.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/late&state=#{state_param}",
        operation: :install
      )

    {:ok, _} =
      SalixStore.Repo.query(
        "UPDATE colab_group_install_states SET updated_at = $3 WHERE tenant_id = $1 AND group_id = $2",
        [tenant_id, group_id, older_late_ts]
      )

    # Tick 2 must read from the head (not a persistent cursor past page_ts) and immediately
    # converge the late-committed row whose timestamp is older than the deferred rows.
    {:noreply, _state_after_pass_2} =
      CommaWeb.ColabInstallReconciler.handle_info(:sweep, state_after_pass_1)

    assert {:ok,
            %{generation: ^gen1, desired_state: "installed", plugin_synced_generation: ^gen1}} =
             Account.get_group_install_state(tenant_id, group_id)
  end

  test "maps missing_colaboratory_scope retry message, 503 platform_unavailable, and 409 already_connected",
       ctx do
    wid = ctx.workspace["id"]
    headers = [{"x-comma-client-capabilities", "plugin-oauth-code"}]

    # 1. missing_colaboratory_scope returns fresh attempt with explicit permission message
    configure_colab_oauth(
      default_plug(scope: "openid https://www.googleapis.com/auth/userinfo.email")
    )

    step1 =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{"contract" => "unified_v1"},
        ctx.token,
        headers
      )

    cfg1 = json(step1)["configuration"]
    state1 = URI.decode_query(URI.parse(cfg1["helpUrl"]).query)["state"]

    missing_scope =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => cfg1["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/noscope&state=#{state1}"
          }
        },
        ctx.token,
        headers
      )

    assert missing_scope.status == 200
    retry_cfg = json(missing_scope)["configuration"]
    assert retry_cfg["attemptId"] != cfg1["attemptId"]
    assert retry_cfg["error"] =~ "Google Colab permission was not granted"

    # 2. platform_unavailable (401 invalid_client) -> HTTP 503
    configure_colab_oauth(fn conn ->
      Plug.Conn.send_resp(
        conn |> Plug.Conn.put_resp_content_type("application/json"),
        401,
        Jason.encode!(%{"error" => "invalid_client"})
      )
    end)

    retry_state = URI.decode_query(URI.parse(retry_cfg["helpUrl"]).query)["state"]

    unavail =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => retry_cfg["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/unavail&state=#{retry_state}"
          }
        },
        ctx.token,
        headers
      )

    assert unavail.status == 503
    assert json(unavail)["error"] == "platform_unavailable"

    # 3. Concurrent duplicate install completion -> HTTP 409 already_connected
    configure_colab_oauth(default_plug(sub: "sub-dup", email: "dup@gmail.com"))

    s_a =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{"contract" => "unified_v1"},
        ctx.token,
        headers
      )

    s_b =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{"contract" => "unified_v1"},
        ctx.token,
        headers
      )

    cfg_a = json(s_a)["configuration"]
    cfg_b = json(s_b)["configuration"]
    state_a = URI.decode_query(URI.parse(cfg_a["helpUrl"]).query)["state"]
    state_b = URI.decode_query(URI.parse(cfg_b["helpUrl"]).query)["state"]

    ok_a =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => cfg_a["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/dup1&state=#{state_a}"
          }
        },
        ctx.token,
        headers
      )

    assert ok_a.status == 200

    dup_b =
      call(
        :post,
        "/v1/comma/workspaces/#{wid}/plugins/google-colab/install",
        %{
          "contract" => "unified_v1",
          "attempt_id" => cfg_b["attemptId"],
          "config_values" => %{
            "GOOGLE_COLAB_AUTH_CODE" =>
              "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/dup2&state=#{state_b}"
          }
        },
        ctx.token,
        headers
      )

    assert dup_b.status == 409
    assert json(dup_b)["error"] == "already_connected"
  end

  defp configure_colab_oauth(plug) do
    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      client_id: @client_id,
      client_secret: "test-secret",
      redirect_uri: "https://sdk.cloud.google.com/applicationdefaultauthcode.html",
      auth_uri: "https://accounts.google.com/o/oauth2/auth",
      token_uri: "https://oauth2.googleapis.com/token",
      userinfo_uri: "https://www.googleapis.com/oauth2/v2/userinfo",
      colab_base_url: "https://colab.research.google.com",
      req_options: [plug: plug]
    )
  end

  defp default_plug(opts) do
    sub = Keyword.get(opts, :sub, "sub-1001")
    email = Keyword.get(opts, :email, "gpu@gmail.com")
    balance = Keyword.get(opts, :balance, 2400.0)

    scope =
      Keyword.get(
        opts,
        :scope,
        "openid https://www.googleapis.com/auth/userinfo.email #{@colab_scope}"
      )

    fn conn ->
      now = SystemsClock.system_time(:second)

      case conn.request_path do
        "/token" ->
          header =
            Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

          payload =
            Base.url_encode64(
              Jason.encode!(%{
                "iss" => "https://accounts.google.com",
                "aud" => @client_id,
                "sub" => sub,
                "email" => email,
                "exp" => now + 3600
              }),
              padding: false
            )

          Plug.Conn.send_resp(
            conn |> Plug.Conn.put_resp_content_type("application/json"),
            200,
            Jason.encode!(%{
              "access_token" => "ya29.#{sub}",
              "refresh_token" => "1//refresh-#{sub}",
              "expires_in" => 3600,
              "token_type" => "Bearer",
              "scope" => scope,
              "id_token" => "#{header}.#{payload}.sig"
            })
          )

        "/tun/m/ccu-info" ->
          Plug.Conn.send_resp(
            conn |> Plug.Conn.put_resp_content_type("application/json"),
            200,
            ")]}\'\n" <>
              Jason.encode!(%{
                "currentBalance" => balance,
                "consumptionRateHourly" => 1.96,
                "eligibleGpus" => ["T4", "L4", "G4"]
              })
          )

        _ ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end
  end

  defp cleanup_colab_tables(tenant_id, group_id) do
    for table <- [
          "colab_vm_leases",
          "colab_accounts",
          "colab_group_install_states",
          "colab_oauth_attempts"
        ] do
      _ = SalixStore.Repo.query("DELETE FROM #{table} WHERE tenant_id = $1", [tenant_id])
    end

    _ =
      SalixStore.Repo.query(
        "DELETE FROM colab_retired_scopes WHERE scope_key IN ($1, $2)",
        ["tenant:" <> tenant_id, "group:" <> group_id]
      )
  end

  defp call(method, path, attrs, token, extra_headers \\ []) do
    conn =
      Plug.Test.conn(method, path, if(attrs, do: Jason.encode!(attrs), else: nil))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

    conn =
      Enum.reduce(extra_headers, conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    CommaWeb.Router.call(conn, CommaWeb.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
