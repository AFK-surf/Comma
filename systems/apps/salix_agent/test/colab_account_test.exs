defmodule SalixAgent.Colab.AccountTestNotifier do
  @behaviour SalixAgent.CapabilityRequests

  @impl true
  def notify_capability_request(request) do
    if pid = SystemsRuntime.get_env(:salix_agent, :colab_test_cap_notifier_pid) do
      SystemsRuntime.Proc.send(pid, {:cap_notified, request["request_id"], request["status"]})
    end

    :ok
  end
end

defmodule SalixAgent.Colab.AccountTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  require SystemsClock

  alias SalixAgent.Colab.{Account, Leases}
  alias SalixStore.{Codec, Ids, Repo}

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    user_id = "usr_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(8), padding: false)
    prev_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)

    on_exit(fn ->
      restore_env(:colab_oauth, prev_oauth)
      _ = Repo.query("DELETE FROM colab_vm_leases WHERE tenant_id = $1", [tenant])
      _ = Repo.query("DELETE FROM colab_oauth_attempts WHERE tenant_id = $1", [tenant])
      _ = Repo.query("DELETE FROM colab_group_install_states WHERE tenant_id = $1", [tenant])
      _ = Repo.query("DELETE FROM colab_accounts WHERE tenant_id = $1", [tenant])

      _ =
        Repo.query("DELETE FROM colab_retired_scopes WHERE scope_key = ANY($1::text[])", [
          ["tenant:" <> tenant, "group:" <> group]
        ])
    end)

    %{tenant: tenant, group: group, user_id: user_id}
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, val), do: SystemsRuntime.put_env(:salix_agent, key, val)

  defp configure_oauth(plug) do
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

  defp build_id_token(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.sig"
  end

  defp default_plug(opts) do
    sub = Keyword.get(opts, :sub, "sub-1001")
    email = Keyword.get(opts, :email, "gpu@gmail.com")
    refresh_token = Keyword.get(opts, :refresh_token, "1//refresh-1")
    access_token = Keyword.get(opts, :access_token, "ya29.access-1")
    balance = Keyword.get(opts, :balance, 2491.35)
    ccu_status = Keyword.get(opts, :ccu_status, 200)

    fn conn ->
      now = SystemsClock.system_time(:second)

      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          id_token =
            build_id_token(%{
              "iss" => "https://accounts.google.com",
              "aud" => @client_id,
              "exp" => now + 3600,
              "sub" => sub,
              "email" => email,
              "email_verified" => true
            })

          body =
            %{
              "access_token" => access_token,
              "token_type" => "Bearer",
              "expires_in" => 3600,
              "scope" => "openid #{@colab_scope}",
              "id_token" => id_token
            }
            |> then(fn m ->
              if refresh_token, do: Map.put(m, "refresh_token", refresh_token), else: m
            end)

          Req.Test.json(conn, body)

        {"GET", "/tun/m/ccu-info"} ->
          if ccu_status == 200 do
            Plug.Conn.send_resp(
              conn,
              200,
              ")]}'\n" <>
                Jason.encode!(%{
                  "currentBalance" => balance,
                  "consumptionRateHourly" => 10.05,
                  "assignmentsCount" => 1,
                  "eligibleGpus" => ["G4", "L4", "T4"]
                })
            )
          else
            Plug.Conn.send_resp(conn, ccu_status, "error")
          end
      end
    end
  end

  defp connect!(tenant, group, user_id, opts) do
    configure_oauth(default_plug(opts))
    {:ok, start} = Account.start_oauth_attempt(tenant, group, user_id, operation: :install)

    {:ok, receipt} =
      Account.complete_oauth_attempt(tenant, group, user_id, start.attempt_id, "auth-code-1",
        operation: :install
      )

    receipt
  end

  test "two-step OAuth install, pre-claim validation preserves attempt, idempotent replay, and mode add_account guard",
       %{tenant: tenant, group: group, user_id: user_id} do
    configure_oauth(default_plug(sub: "sub-install-1", email: "alice@gmail.com", balance: 1500.5))

    assert Account.connection_state(tenant, group) == "not_connected"
    assert Account.has_active_account?(tenant, group) == false

    assert {:ok, start} = Account.start_oauth_attempt(tenant, group, user_id, operation: :install)
    assert String.starts_with?(start.attempt_id, "colab_att_")
    assert start.key == "GOOGLE_COLAB_AUTH_CODE"
    assert start.format == "oauth_code"

    # Malformed paste / mismatched state returns :plugin_credential_rejected WITHOUT burning attempt
    assert {:error, :plugin_credential_rejected} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               start.attempt_id,
               "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=abc&state=wrong"
             )

    # Same attempt still completes with a valid code
    assert {:ok, receipt} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               start.attempt_id,
               "4/0ValidCode"
             )

    assert String.starts_with?(receipt.binding_id, "colab_acc_")
    assert receipt.generation == 1
    assert receipt.email == "alice@gmail.com"
    assert receipt.already_completed == false

    # Idempotent replay on completed attempt returns winning receipt
    assert {:ok, replay} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               start.attempt_id,
               "4/0ValidCode"
             )

    assert replay.binding_id == receipt.binding_id
    assert replay.generation == 1
    assert replay.already_completed == true

    assert Account.connection_state(tenant, group) == "connected"
    assert Account.has_active_account?(tenant, group) == true

    assert {:ok, [acc]} = Account.list_group_accounts_with_stats(tenant, group)
    assert acc["binding_id"] == receipt.binding_id
    assert acc["email"] == "alice@gmail.com"
    assert acc["status"] == "ok"
    assert acc["state"] == "active"
    assert acc["ccu_balance"] == 1500.5
    assert acc["eligible_gpus"] == ["G4", "L4", "T4"]
    assert acc["active_vm_count"] == 0

    # V1 single-account guard for mode: "add_account"
    assert {:error, :single_account_limit_reached} =
             Account.start_oauth_attempt(tenant, group, user_id,
               operation: :install,
               mode: "add_account"
             )

    # Group install state reflects generation=1, desired_state="installed", plugin_synced_generation=0
    assert {:ok,
            %{
              generation: 1,
              desired_state: "installed",
              binding_id: bid,
              plugin_synced_generation: 0
            }} = Account.get_group_install_state(tenant, group)

    assert bid == receipt.binding_id
  end

  test "first-connect requires refresh_token, ccu-info 5xx proceeds with nil balance, and ccu-info 403 retries fresh",
       %{tenant: tenant, group: group, user_id: user_id} do
    # Missing refresh_token on install -> retry_with_fresh_attempt
    configure_oauth(default_plug(sub: "sub-noref", refresh_token: nil))
    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id)

    assert {:retry_with_fresh_attempt, fresh1, :missing_refresh_token} =
             Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-1")

    assert fresh1.attempt_id != s1.attempt_id

    # ccu-info 403 -> retry_with_fresh_attempt(:colab_not_eligible)
    configure_oauth(default_plug(sub: "sub-403", ccu_status: 403))

    assert {:retry_with_fresh_attempt, fresh2, :colab_not_eligible} =
             Account.complete_oauth_attempt(tenant, group, user_id, fresh1.attempt_id, "code-2")

    assert fresh2.attempt_id != fresh1.attempt_id

    # ccu-info 503 -> proceeds with ccu_balance: nil
    configure_oauth(default_plug(sub: "sub-503", ccu_status: 503))

    assert {:ok, receipt} =
             Account.complete_oauth_attempt(tenant, group, user_id, fresh2.attempt_id, "code-3")

    assert {:ok, [acc]} = Account.list_group_accounts_with_stats(tenant, group)
    assert acc["binding_id"] == receipt.binding_id
    assert acc["ccu_balance"] == nil
  end

  test "concurrent first-connect race publishes at most 1 account in (tenant, group)", %{
    tenant: tenant,
    group: group,
    user_id: user_id
  } do
    configure_oauth(default_plug(sub: "sub-race-1", email: "race@gmail.com"))

    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id)
    {:ok, s2} = Account.start_oauth_attempt(tenant, group, user_id)

    t1 =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-a")
      end)

    t2 =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.complete_oauth_attempt(tenant, group, user_id, s2.attempt_id, "code-b")
      end)

    results = [SystemsRuntime.Task.await(t1, :infinity), SystemsRuntime.Task.await(t2, :infinity)]
    oks = Enum.filter(results, &match?({:ok, _}, &1))
    errs = Enum.filter(results, &match?({:error, :already_connected}, &1))

    assert length(oks) == 1
    assert length(errs) == 1
    assert {:ok, [_only_one]} = Account.list_group_accounts_with_stats(tenant, group)
  end

  test "claim-fenced exchanging->exchanged rejects late write-back after cancellation, and exchanging lease <60s vs >=60s",
       %{tenant: tenant, group: group, user_id: user_id} do
    parent = SystemsRuntime.Proc.self()

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          SystemsRuntime.Proc.send(parent, {:exchange_entered, SystemsRuntime.Proc.self()})

          SystemsClock.vreceive do
            :release_exchange -> :ok
          after
            600_000 -> :timeout
          end

          default_plug(sub: "sub-cancel-race").(conn)

        _other ->
          default_plug(sub: "sub-cancel-race").(conn)
      end
    end)

    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id)

    t1 =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-slow")
      end)

    ex_pid =
      SystemsClock.vreceive do
        {:exchange_entered, pid} -> pid
      after
        5_000 -> flunk("exchange was not entered")
      end

    # While exchanging (<60s), concurrent submit returns :oauth_exchange_in_progress
    assert {:error, :oauth_exchange_in_progress} =
             Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-slow")

    # Advance 65s (>=60s): stale exchanging claim is atomically failed and fresh PKCE issued
    SystemsClock.advance(65_000)

    assert {:retry_with_fresh_attempt, _fresh, :exchange_timed_out} =
             Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-slow")

    # Release the late Google token response: claim-fenced CAS updates 0 rows -> :attempt_invalidated!
    SystemsRuntime.Proc.send(ex_pid, :release_exchange)
    assert {:error, :attempt_invalidated} = SystemsRuntime.Task.await(t1, :infinity)
    assert Account.has_active_account?(tenant, group) == false
  end

  test "Step 5 ccu-info 403 0-row fail re-reads attempt and replays concurrent winner's completed receipt",
       %{tenant: tenant, group: group, user_id: user_id} do
    parent = SystemsRuntime.Proc.self()
    ccu_count = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          default_plug(sub: "sub-step5-race", email: "winner@gmail.com").(conn)

        {"GET", "/tun/m/ccu-info"} ->
          n = :atomics.add_get(ccu_count, 1, 1)

          if n == 1 do
            # First worker blocks in ccu-info, then gets 403 AFTER second worker commits!
            SystemsRuntime.Proc.send(parent, {:ccu1_entered, SystemsRuntime.Proc.self()})

            SystemsClock.vreceive do
              :release_ccu1 -> :ok
            after
              5_000 -> :timeout
            end

            Plug.Conn.send_resp(conn, 403, "forbidden")
          else
            default_plug(sub: "sub-step5-race", email: "winner@gmail.com").(conn)
          end
      end
    end)

    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id)

    t1 =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-step5")
      end)

    ccu1_pid =
      SystemsClock.vreceive do
        {:ccu1_entered, pid} -> pid
      after
        5_000 -> flunk("ccu1 was not entered")
      end

    # Attempt is now in 'exchanged' state: a concurrent recovery worker completes Step 5 + Step 6!
    assert {:ok, winner} =
             Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-step5")

    assert winner.already_completed == false

    # Now release worker 1 with 403: its 0-row conditional fail re-reads 'completed' and replays winner!
    SystemsRuntime.Proc.send(ccu1_pid, :release_ccu1)
    assert {:ok, replayed} = SystemsRuntime.Task.await(t1, :infinity)
    assert replayed.binding_id == winner.binding_id
    assert replayed.generation == winner.generation
    assert replayed.already_completed == true
  end

  test "reconnect enforces same google_sub, preserves refresh_token, and concurrent user reconnects are mutually exclusive",
       %{tenant: tenant, group: group, user_id: user_id} do
    receipt = connect!(tenant, group, user_id, sub: "sub-orig", email: "orig@gmail.com")
    binding_id = receipt.binding_id

    # Start two reconnect attempts capturing credential_revision = 1 and reconnect_revision = 1
    {:ok, r1} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    {:ok, r2} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    # Reconnect with different google_sub -> {:error, {:wrong_google_account, "orig@gmail.com"}}
    configure_oauth(default_plug(sub: "sub-other", email: "other@gmail.com"))

    assert {:error, {:wrong_google_account, "orig@gmail.com"}} =
             Account.complete_oauth_attempt(tenant, group, user_id, r1.attempt_id, "code-wrong",
               operation: :reconnect,
               binding_id: binding_id
             )

    # Reconnect with same google_sub and omitted refresh_token -> succeeds & bumps revision to 2
    {:ok, r3} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    configure_oauth(
      default_plug(
        sub: "sub-orig",
        email: "orig@gmail.com",
        refresh_token: nil,
        access_token: "ya29.reconnected"
      )
    )

    assert {:ok, reconn} =
             Account.complete_oauth_attempt(tenant, group, user_id, r3.attempt_id, "code-same",
               operation: :reconnect,
               binding_id: binding_id
             )

    assert reconn.binding_id == binding_id

    # Verify revision bumped to 2 and existing refresh_token preserved
    {:ok, acc} = Account.get_account(tenant, group, binding_id)
    assert acc.credential_revision == 2
    {:ok, creds} = Account.open_payload(tenant, group, binding_id, acc.credentials_ciphertext)
    assert creds["refresh_token"] == "1//refresh-1"
    assert creds["access_token"] == "ya29.reconnected"

    assert acc.reconnect_revision == 2

    # r2 opened at reconnect_revision 1 before r3 committed. Even with a new refresh_token
    # it must not overwrite r3's newer user reconnect.
    configure_oauth(
      default_plug(
        sub: "sub-orig",
        email: "orig@gmail.com",
        refresh_token: "1//refresh-2",
        access_token: "ya29.reconnected-2"
      )
    )

    assert {:error, :conflict} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               r2.attempt_id,
               "code-fresh-rt",
               operation: :reconnect,
               binding_id: binding_id
             )

    {:ok, acc2} = Account.get_account(tenant, group, binding_id)
    assert acc2.credential_revision == 2
    assert acc2.reconnect_revision == 2
    {:ok, creds2} = Account.open_payload(tenant, group, binding_id, acc2.credentials_ciphertext)
    assert creds2["refresh_token"] == "1//refresh-1"
    assert creds2["access_token"] == "ya29.reconnected"

    # A and B open at the same revisions; B commits first with a new refresh_token, then
    # A without a refresh_token must also return :conflict and keep B's credentials.
    {:ok, a} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    {:ok, b} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    configure_oauth(
      default_plug(
        sub: "sub-orig",
        email: "orig@gmail.com",
        refresh_token: "1//refresh-b",
        access_token: "ya29.reconnected-b"
      )
    )

    assert {:ok, %{binding_id: ^binding_id}} =
             Account.complete_oauth_attempt(tenant, group, user_id, b.attempt_id, "code-b",
               operation: :reconnect,
               binding_id: binding_id
             )

    configure_oauth(
      default_plug(
        sub: "sub-orig",
        email: "orig@gmail.com",
        refresh_token: nil,
        access_token: "ya29.reconnected-a"
      )
    )

    assert {:error, :conflict} =
             Account.complete_oauth_attempt(tenant, group, user_id, a.attempt_id, "code-a",
               operation: :reconnect,
               binding_id: binding_id
             )

    {:ok, acc3} = Account.get_account(tenant, group, binding_id)
    assert acc3.credential_revision == 3
    assert acc3.reconnect_revision == 3
    {:ok, creds3} = Account.open_payload(tenant, group, binding_id, acc3.credentials_ciphertext)
    assert creds3["refresh_token"] == "1//refresh-b"
    assert creds3["access_token"] == "ya29.reconnected-b"
  end

  test "reconnect with new refresh_token succeeds across concurrent background refresh, and reconnect without refresh_token waits for the refresh claim then conflicts instead of overwriting the rotation",
       %{tenant: tenant, group: group, user_id: user_id} do
    receipt = connect!(tenant, group, user_id, sub: "sub-ref-race", email: "refrace@gmail.com")
    binding_id = receipt.binding_id

    # (a) Healthy account: background refresh advances credential_revision while reconnect with new refresh_token succeeds
    SystemsClock.advance(3_700_000)

    {:ok, reconn_new_rt} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{
            "access_token" => "ya29.bg-refreshed-1",
            "refresh_token" => "1//bg-rotated-1",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
      end
    end)

    assert {:ok, %{credential_revision: 2}} =
             Account.get_access_token(tenant, group, binding_id, mode: :execute)

    configure_oauth(
      default_plug(
        sub: "sub-ref-race",
        email: "refrace@gmail.com",
        refresh_token: "1//reconnect-new-rt",
        access_token: "ya29.reconnect-new-rt"
      )
    )

    assert {:ok, %{binding_id: ^binding_id}} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               reconn_new_rt.attempt_id,
               "code-new-rt",
               operation: :reconnect,
               binding_id: binding_id
             )

    {:ok, acc_after_a} = Account.get_account(tenant, group, binding_id)
    assert acc_after_a.credential_revision == 3
    assert acc_after_a.reconnect_revision == 2

    {:ok, creds_a} =
      Account.open_payload(tenant, group, binding_id, acc_after_a.credentials_ciphertext)

    assert creds_a["refresh_token"] == "1//reconnect-new-rt"

    # (b) Reconnect WITHOUT new refresh_token encountering an active refresh claim waits outside
    # the lock for the background refresh. The rotation advances credential_revision past the
    # attempt's expected revision, so the reconnect returns :conflict and keeps the rotation.
    SystemsClock.advance(3_700_000)

    {:ok, reconn_inherit} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: binding_id
      )

    parent = SystemsRuntime.Proc.self()

    configure_oauth(fn conn ->
      now = SystemsClock.system_time(:second)
      {:ok, body_str, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          if String.contains?(body_str, "grant_type=refresh_token") do
            SystemsRuntime.Proc.send(parent, {:bg_refresh_entered, SystemsRuntime.Proc.self()})

            SystemsClock.vreceive do
              :release_bg_refresh -> :ok
            after
              5_000 -> :timeout
            end

            Req.Test.json(conn, %{
              "access_token" => "ya29.bg-rotated-2",
              "refresh_token" => "1//bg-rotated-2",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            })
          else
            id_token =
              build_id_token(%{
                "iss" => "https://accounts.google.com",
                "aud" => @client_id,
                "exp" => now + 3600,
                "sub" => "sub-ref-race",
                "email" => "refrace@gmail.com",
                "email_verified" => true
              })

            Req.Test.json(conn, %{
              "access_token" => "ya29.reconn-no-rt",
              "token_type" => "Bearer",
              "expires_in" => 3600,
              "scope" => "openid #{@colab_scope}",
              "id_token" => id_token
            })
          end

        {"GET", "/tun/m/ccu-info"} ->
          SystemsRuntime.Proc.send(parent, :reconn_ccu_done)

          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"currentBalance" => 500.0})
          )
      end
    end)

    refresh_task =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.get_access_token(tenant, group, binding_id, mode: :execute)
      end)

    ref_pid =
      SystemsClock.vreceive do
        {:bg_refresh_entered, pid} -> pid
      after
        5_000 -> flunk("background refresh was not entered")
      end

    reconn_task =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.complete_oauth_attempt(
          tenant,
          group,
          user_id,
          reconn_inherit.attempt_id,
          "code-no-rt",
          operation: :reconnect,
          binding_id: binding_id
        )
      end)

    SystemsClock.vreceive do
      :reconn_ccu_done -> :ok
    after
      5_000 -> flunk("reconnect ccu-info was not reached")
    end

    # Advance 50ms once while refresh claim is still held: reconnect stays waiting (does not fail or overwrite!)
    SystemsClock.advance(50)
    assert nil == SystemsRuntime.Task.yield(reconn_task, 0)

    # Release background refresh so it persists "1//bg-rotated-2" and clears refresh_claim_id
    SystemsRuntime.Proc.send(ref_pid, :release_bg_refresh)
    assert {:ok, %{credential_revision: 4}} = SystemsRuntime.Task.await(refresh_task, :infinity)

    # Advance virtual clock so reconnect wakes from SystemsClock.sleep(50) and re-checks the CAS
    SystemsClock.advance(250)
    result = SystemsRuntime.Task.await(reconn_task, :infinity)

    assert {:error, :conflict} = result

    {:ok, acc_after_b} = Account.get_account(tenant, group, binding_id)
    assert acc_after_b.credential_revision == 4
    assert acc_after_b.reconnect_revision == 2

    {:ok, creds_b} =
      Account.open_payload(tenant, group, binding_id, acc_after_b.credentials_ciphertext)

    assert creds_b["refresh_token"] == "1//bg-rotated-2"
    assert creds_b["access_token"] == "ya29.bg-rotated-2"
  end

  test "decoupled refresh persistence: :execute racing with retiring persists rotated token while returning :account_not_active, and :cleanup updates retired credentials",
       %{tenant: tenant, group: group, user_id: user_id} do
    receipt = connect!(tenant, group, user_id, sub: "sub-decoupled", email: "dec@gmail.com")
    binding_id = receipt.binding_id

    # Advance past token expiry so get_access_token must call Google refresh
    SystemsClock.advance(3_700_000)

    parent = SystemsRuntime.Proc.self()

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          SystemsRuntime.Proc.send(parent, {:refresh_entered, SystemsRuntime.Proc.self()})

          SystemsClock.vreceive do
            :release_refresh -> :ok
          after
            5_000 -> :timeout
          end

          Req.Test.json(conn, %{
            "access_token" => "ya29.rotated-during-retire",
            "refresh_token" => "1//rotated-refresh-token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
      end
    end)

    t =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.get_access_token(tenant, group, binding_id, mode: :execute)
      end)

    ref_pid =
      SystemsClock.vreceive do
        {:refresh_entered, pid} -> pid
      after
        5_000 -> flunk("refresh was not entered")
      end

    # Transition account to 'draining' while :execute refresh is in flight!
    {:ok, _} =
      Repo.query(
        "UPDATE colab_accounts SET state = 'draining' WHERE binding_id = $1",
        [binding_id]
      )

    SystemsRuntime.Proc.send(ref_pid, :release_refresh)

    # Caller with mode: :execute gets {:error, :account_not_active}
    assert {:error, :account_not_active} = SystemsRuntime.Task.await(t, :infinity)

    # BUT the rotated refresh token WAS persisted and state stayed 'draining'!
    {:ok, acc} = Account.get_account(tenant, group, binding_id)
    assert acc.state == "draining"
    assert acc.credential_revision == 2
    {:ok, creds} = Account.open_payload(tenant, group, binding_id, acc.credentials_ciphertext)
    assert creds["refresh_token"] == "1//rotated-refresh-token"
    assert creds["access_token"] == "ya29.rotated-during-retire"

    # mode: :cleanup can immediately use the rotated token even in 'draining' or 'retired' state!
    assert {:ok, %{access_token: "ya29.rotated-during-retire", credential_revision: 2}} =
             Account.get_access_token(tenant, group, binding_id, mode: :cleanup)
  end

  test "invalid_grant is fenced on (binding_id, credential_revision, refresh_claim_id) and 403 classification never poisons quota errors",
       %{tenant: tenant, group: group, user_id: user_id} do
    assert Account.classify_colab_http_error(401, "unauthorized") == :unauthorized

    assert Account.classify_colab_http_error(403, %{"error" => "quota_exceeded"}) ==
             :forbidden_non_auth

    assert Account.classify_colab_http_error(403, "ACCESS_TOKEN_SCOPE_INSUFFICIENT") ==
             :auth_revoked

    receipt = connect!(tenant, group, user_id, sub: "sub-ig-fence", email: "ig@gmail.com")
    binding_id = receipt.binding_id
    SystemsClock.advance(3_700_000)

    parent = SystemsRuntime.Proc.self()

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          SystemsRuntime.Proc.send(parent, {:ig_entered, SystemsRuntime.Proc.self()})

          SystemsClock.vreceive do
            :release_ig -> :ok
          after
            5_000 -> :timeout
          end

          Req.Test.json(Plug.Conn.put_status(conn, 400), %{"error" => "invalid_grant"})
      end
    end)

    t =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Account.get_access_token(tenant, group, binding_id, mode: :execute)
      end)

    ig_pid =
      SystemsClock.vreceive do
        {:ig_entered, pid} -> pid
      after
        5_000 -> flunk("ig refresh not entered")
      end

    # Simulate a concurrent reconnect bumping credential_revision before invalid_grant settles
    {:ok, _} =
      Repo.query(
        "UPDATE colab_accounts SET credential_revision = credential_revision + 1, refresh_claim_id = NULL WHERE binding_id = $1",
        [binding_id]
      )

    SystemsRuntime.Proc.send(ig_pid, :release_ig)
    assert {:error, :invalid_grant} = SystemsRuntime.Task.await(t, :infinity)

    # Account status MUST still be 'ok' (stale invalid_grant did NOT poison reconnected account!)
    {:ok, acc} = Account.get_account(tenant, group, binding_id)
    assert acc.status == "ok"
  end

  test "retire_group_in_tx and retire_tenant fence late first-connects deterministically", %{
    tenant: tenant,
    group: group,
    user_id: user_id
  } do
    # 1. retire_group_in_tx before publish -> publish rejected with :scope_retired
    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id)
    assert :ok = Account.retire_group_in_tx(tenant, group)

    assert {:error, :scope_retired} = Account.start_oauth_attempt(tenant, group, user_id)

    configure_oauth(default_plug(sub: "sub-late-grp"))

    assert {:error, :scope_retired} =
             Account.complete_oauth_attempt(tenant, group, user_id, s1.attempt_id, "code-late")

    assert Account.has_active_account?(tenant, group) == false

    # 2. Publish before retire_tenant -> retire_tenant marks account retired and blocks future connects
    group2 = Ids.new_group_id(tenant)
    receipt = connect!(tenant, group2, user_id, sub: "sub-before-retire")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, lease, _} =
      Leases.insert_assigning(tenant, group2, "session:a:1", nil, receipt.binding_id, spec)

    {:ok, _} = Leases.promote_active(lease.vm_id, 1, "m-s-ret-t", "https://abc.prod.colab.dev")

    assert :ok = Account.retire_tenant(tenant)

    # Account still exists as 'retired' while lease is in 'stopping' (not deleted until 0 leases)
    {:ok, retired_acc} = Account.get_account(tenant, group2, receipt.binding_id)
    assert retired_acc.state == "retired"
    assert {:ok, %{state: "stopping"}} = Leases.get_by_id(lease.vm_id)

    # Future connects on any group of tenant are blocked by tenant retirement fence
    group3 = Ids.new_group_id(tenant)
    assert {:error, :scope_retired} = Account.start_oauth_attempt(tenant, group3, user_id)
  end

  test "settle_install_cards_if_generation_current and mark_plugin_synced fence on current generation",
       %{tenant: tenant, group: group, user_id: user_id} do
    receipt = connect!(tenant, group, user_id, sub: "sub-sync-1")
    assert receipt.generation == 1

    # Sync generation 1
    assert :ok = Account.settle_install_cards_if_generation_current(tenant, group, 1)
    assert :ok = Account.mark_plugin_synced(tenant, group, 1, "installed")
    assert {:ok, %{plugin_synced_generation: 1}} = Account.get_group_install_state(tenant, group)

    # Disconnect advances generation to 2, desired_state = 'uninstalled'
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)

    # Stale mark_plugin_synced for generation 1 does NOT overwrite generation 2
    assert :ok = Account.mark_plugin_synced(tenant, group, 1, "installed")

    assert {:ok, %{generation: 2, desired_state: "uninstalled", plugin_synced_generation: 1}} =
             Account.get_group_install_state(tenant, group)

    # Stale settle_install_cards_if_generation_current(1) is a safe no-op
    assert :ok = Account.settle_install_cards_if_generation_current(tenant, group, 1)

    # Syncing generation 2 converges plugin_synced_generation to 2
    assert :ok = Account.mark_plugin_synced(tenant, group, 2, "uninstalled")
    assert {:ok, %{plugin_synced_generation: 2}} = Account.get_group_install_state(tenant, group)
  end

  test "Phase B card settlement rolls back all cards with zero notify/delivery when a second card update fails",
       %{tenant: tenant, group: group, user_id: user_id} do
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :capability_request_notifier_mod)
    prev_pid = SystemsRuntime.get_env(:salix_agent, :colab_test_cap_notifier_pid)

    SystemsRuntime.put_env(
      :salix_agent,
      :capability_request_notifier_mod,
      SalixAgent.Colab.AccountTestNotifier
    )

    SystemsRuntime.put_env(:salix_agent, :colab_test_cap_notifier_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore_env(:capability_request_notifier_mod, prev_notifier)
      restore_env(:colab_test_cap_notifier_pid, prev_pid)
      _ = Repo.query("DELETE FROM salix_capability_requests WHERE tenant_id = $1", [tenant])
    end)

    receipt = connect!(tenant, group, user_id, sub: "sub-tx-rollback")
    assert receipt.generation == 1

    agent_id = Ids.new_agent_id(group)
    now_sec = SystemsClock.system_time(:second)
    expires_at_sec = now_sec + 600
    expires_dt = DateTime.from_unix!(expires_at_sec)

    card1 = %{
      "request_id" => "cap-colab-card-1",
      "group_id" => group,
      "tenant_id" => tenant,
      "source_agent_id" => agent_id,
      "source_session_id" => "sess-card-1",
      "tool_call_id" => "tc-card-1",
      "request_type" => "plugin_install",
      "status" => "pending",
      "request_payload" => %{"plugin_install" => %{"plugin_id" => "google-colab"}},
      "response_payload" => %{},
      "surface_kind" => "conversation",
      "surface_ref" => %{},
      "expires_at" => expires_at_sec,
      "created_at" => now_sec + 10,
      "updated_at" => now_sec + 10,
      "completed_at" => nil
    }

    # Card 2 has updated_at < Card 1 so PG.pending_of_type (ORDER BY updated_at DESC)
    # updates Card 1 first and then fails on Card 2's NOT NULL source_agent_id constraint.
    card2 = %{
      "request_id" => "cap-colab-card-2",
      "group_id" => group,
      "tenant_id" => tenant,
      "source_agent_id" => nil,
      "source_session_id" => "sess-card-2",
      "tool_call_id" => "tc-card-2",
      "request_type" => "plugin_install",
      "status" => "pending",
      "request_payload" => %{"plugin_install" => %{"plugin_id" => "google-colab"}},
      "response_payload" => %{},
      "surface_kind" => "conversation",
      "surface_ref" => %{},
      "expires_at" => expires_at_sec,
      "created_at" => now_sec + 5,
      "updated_at" => now_sec + 5,
      "completed_at" => nil
    }

    for {card, tc_id} <- [{card1, "tc-card-1"}, {card2, "tc-card-2"}] do
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO salix_capability_requests (
            group_id, request_id, revision, tenant_id, request_type, status, expires_at,
            source_agent_id, source_session_id, tool_call_id, surface_kind, surface_ref,
            payload, created_at, updated_at
          ) VALUES ($1, $2, 1, $3, 'plugin_install', 'pending', $4, $5, $6, $7, 'conversation', '{}'::jsonb, $8, $9, $10)
          """,
          [
            group,
            card["request_id"],
            tenant,
            expires_dt,
            agent_id,
            card["source_session_id"],
            tc_id,
            Codec.encode_snapshot(card),
            card["created_at"],
            card["updated_at"]
          ]
        )
    end

    assert {:error, _} = Account.settle_install_cards_if_generation_current(tenant, group, 1)

    # Card 1 MUST remain pending in DB because the transaction rolled back!
    assert {:ok, %{rows: [["pending"]]}} =
             Repo.query(
               "SELECT status FROM salix_capability_requests WHERE group_id = $1 AND request_id = $2",
               [group, "cap-colab-card-1"]
             )

    # Zero notifications emitted for Card 1 before commit!
    refute_received {:cap_notified, _, _}
  end

  test "cleanup_expired_oauth_attempts scrubs expired credentials and deletes old attempts, and list_unsynced_group_install_states finds pending convergence",
       %{tenant: tenant, group: group, user_id: user_id} do
    {:ok, s1} = Account.start_oauth_attempt(tenant, group, user_id, operation: :install)

    {:ok, staged_ct} =
      Account.seal_payload(tenant, group, s1.attempt_id, %{"access_token" => "ya29.secret"})

    {:ok, _} =
      Repo.query(
        "UPDATE colab_oauth_attempts SET status = 'exchanged', exchanged_ciphertext = $2 WHERE attempt_id = $1",
        [s1.attempt_id, staged_ct]
      )

    # Advance past 600s TTL (but < 600s + 3600s delete grace): credentials scrubbed, status -> 'expired'
    SystemsClock.advance(610_000)
    assert {:ok, %{scrubbed: scrubbed, deleted: _}} = Account.cleanup_expired_oauth_attempts()
    assert scrubbed >= 1

    assert {:ok, %{rows: [["expired", nil, nil]]}} =
             Repo.query(
               "SELECT status, exchanged_ciphertext, code_verifier FROM colab_oauth_attempts WHERE attempt_id = $1",
               [s1.attempt_id]
             )

    # Advance > 3600s past expires_at: expired attempt row is hard-deleted
    SystemsClock.advance(3_700_000)
    assert {:ok, %{deleted: deleted}} = Account.cleanup_expired_oauth_attempts()
    assert deleted >= 1

    assert {:ok, %{rows: []}} =
             Repo.query(
               "SELECT 1 FROM colab_oauth_attempts WHERE attempt_id = $1",
               [s1.attempt_id]
             )

    # Verify list_unsynced_group_install_states returns groups with plugin_synced_generation < generation
    _receipt = connect!(tenant, group, user_id, sub: "sub-unsynced-1")
    assert {:ok, unsynced} = Account.list_unsynced_group_install_states(100)

    assert Enum.any?(unsynced, fn row ->
             row.tenant_id == tenant and row.group_id == group and
               row.desired_state == "installed" and row.generation == 1 and
               row.plugin_synced_generation == 0
           end)
  end

  test "Bridge for Teams writes skip the plugin sync queue, and a stale binding_id disconnect leaves the replacement account and its lease intact",
       %{tenant: tenant, group: group, user_id: user_id} do
    # Account A connects, then is disconnected and replaced by account B.
    receipt_a = connect!(tenant, group, user_id, sub: "sub-bft-a", email: "a@gmail.com")

    assert {:ok, %{generation: 2}} =
             Account.disconnect_all_for_group(tenant, group, sync_plugin_state: false)

    assert {:ok, %{generation: 2, plugin_synced_generation: 2}} =
             Account.get_group_install_state(tenant, group)

    configure_oauth(default_plug(sub: "sub-bft-b", email: "b@gmail.com"))
    {:ok, start_b} = Account.start_oauth_attempt(tenant, group, user_id, operation: :install)

    assert {:ok, %{binding_id: binding_b, generation: 3}} =
             Account.complete_oauth_attempt(tenant, group, user_id, start_b.attempt_id, "code-b",
               operation: :install,
               sync_plugin_state: false
             )

    assert {:ok, %{generation: 3, plugin_synced_generation: 3, desired_state: "installed"}} =
             Account.get_group_install_state(tenant, group)

    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, lease, _} =
      Leases.insert_assigning(tenant, group, "session:a:bft", nil, binding_b, spec)

    {:ok, active} = Leases.promote_active(lease.vm_id, 1, "m-s-bft-b", "https://b.prod.colab.dev")

    # Disconnecting the stale binding A is not found and does not touch B.
    assert {:error, :not_found} =
             Account.disconnect_binding(tenant, group, receipt_a.binding_id,
               sync_plugin_state: false
             )

    assert {:ok, %{state: "active", status: "ok"}} =
             Account.get_account(tenant, group, binding_b)

    assert {:ok, %{state: "active", generation: generation, endpoint: "m-s-bft-b"}} =
             Leases.get_by_id(active.vm_id)

    assert generation == active.generation
    assert {:ok, %{generation: 3}} = Account.get_group_install_state(tenant, group)
  end
end
