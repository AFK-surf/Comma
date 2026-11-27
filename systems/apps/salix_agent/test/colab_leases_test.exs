defmodule SalixAgent.Colab.SlowDnsResolver do
  require SystemsClock

  def getaddrs(_host, :inet) do
    if parent = SystemsRuntime.get_env(:salix_agent, :colab_test_dns_parent) do
      SystemsRuntime.Proc.send(parent, {:dns_entered, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        :release_dns -> {:ok, [{1, 2, 3, 4}]}
      after
        60_000 -> {:error, :nxdomain}
      end
    else
      {:ok, [{1, 2, 3, 4}]}
    end
  end

  def getaddrs(_host, :inet6), do: {:error, :nxdomain}
end

defmodule SalixAgent.Colab.LeasesTestPluginStore do
  def plugin_enabled?(_tenant_id, _group_id, "google-colab"), do: true
  def plugin_enabled?(_tenant_id, _group_id, _plugin_id), do: false
end

defmodule SalixAgent.Colab.LeasesTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  require SystemsClock

  alias SalixAgent.Colab.{Account, Leases, LocalExec, Pool, Reaper, Tunnels}
  alias SalixStore.{Ids, Repo}

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)
    user_id = "usr_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(8), padding: false)

    prev_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)
    prev_private = SystemsRuntime.get_env(:salix_agent, :colab_allow_private_endpoints)
    prev_resolver = SystemsRuntime.get_env(:salix_agent, :resolver)
    prev_plugin_store = SystemsRuntime.get_env(:salix_agent, :plugin_store_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :plugin_store_mod,
      SalixAgent.Colab.LeasesTestPluginStore
    )

    Pool.clear_cooldowns()

    on_exit(fn ->
      Pool.clear_cooldowns()
      restore_env(:colab_oauth, prev_oauth)
      restore_env(:colab_allow_private_endpoints, prev_private)
      restore_env(:resolver, prev_resolver)
      restore_env(:plugin_store_mod, prev_plugin_store)
      _ = Repo.query("DELETE FROM colab_vm_leases WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_oauth_attempts WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_group_install_states WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_accounts WHERE tenant_id=$1", [tenant])

      _ =
        Repo.query("DELETE FROM colab_retired_scopes WHERE scope_key = ANY($1::text[])", [
          ["tenant:" <> tenant, "group:" <> group]
        ])
    end)

    %{
      tenant: tenant,
      group: group,
      agent: agent,
      user_id: user_id,
      ctx: %{tenant_id: tenant, group_id: group, agent_id: agent, session_id: "sess-1"}
    }
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, val), do: SystemsRuntime.put_env(:salix_agent, key, val)

  defp build_id_token(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.sig"
  end

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

  defp connect_colab!(tenant, group, user_id, opts) do
    sub =
      Keyword.get(
        opts,
        :sub,
        "sub-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
      )

    email = Keyword.get(opts, :email, "gpu@gmail.com")
    refresh_token = Keyword.get(opts, :refresh_token, "1//refresh-" <> sub)
    access_token = Keyword.get(opts, :access_token, "ya29.access-" <> sub)
    balance = Keyword.get(opts, :balance, 2400.0)

    configure_oauth(fn conn ->
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

          Req.Test.json(conn, %{
            "access_token" => access_token,
            "refresh_token" => refresh_token,
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "scope" => "openid #{@colab_scope}",
            "id_token" => id_token
          })

        {"GET", "/tun/m/ccu-info"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"currentBalance" => balance, "assignmentsCount" => 0})
          )
      end
    end)

    {:ok, start} = Account.start_oauth_attempt(tenant, group, user_id, operation: :install)

    {:ok, receipt} =
      Account.complete_oauth_attempt(tenant, group, user_id, start.attempt_id, "code-" <> sub,
        operation: :install
      )

    receipt
  end

  defp insert_extra_binding!(tenant, group, alias_name, sub) do
    binding_id =
      "colab_acc_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)

    now = SystemsClock.utc_now()
    exp = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()

    {:ok, ct} =
      Account.seal_payload(tenant, group, binding_id, %{
        "access_token" => "ya29.extra-" <> sub,
        "refresh_token" => "1//extra-" <> sub,
        "expires_at" => exp,
        "google_sub" => sub,
        "email" => sub <> "@gmail.com"
      })

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO colab_accounts (
          binding_id, tenant_id, group_id, alias, google_sub, email,
          credentials_ciphertext, credential_revision, status, state, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, 1, 'ok', 'active', $8, $8)
        """,
        [binding_id, tenant, group, alias_name, sub, sub <> "@gmail.com", ct, now]
      )

    %{binding_id: binding_id}
  end

  test "owner_scope constructs session and task scopes strictly from trusted ctx" do
    assert {:ok, "session:ag1:s1"} = Leases.owner_scope(%{agent_id: "ag1", session_id: "s1"})

    assert {:ok, "task:ag1:cnv_1"} =
             Leases.owner_scope(%{
               agent_id: "ag1",
               session_id: "s1",
               task_conversation_id: "cnv_1"
             })

    assert {:error, :invalid_owner_scope} = Leases.owner_scope(%{agent_id: "ag1"})
    assert {:error, :invalid_owner_scope} = Leases.owner_scope(%{session_id: "s1"})
  end

  test "two-phase assign, generation fencing, 3-VM/GPU cap, 4-VM/owner cap, and group isolation",
       %{
         tenant: tenant,
         group: group,
         user_id: user_id
       } do
    acc1 = connect_colab!(tenant, group, user_id, sub: "sub-cap-1")
    acc2 = insert_extra_binding!(tenant, group, "google-colab-2", "sub-cap-2")
    spec_g4 = %{variant: "GPU", accelerator: "G4", high_mem: false}
    spec_l4 = %{variant: "GPU", accelerator: "L4", high_mem: false}

    # Group isolation: another group in the same tenant cannot use group's binding
    other_group = Ids.new_group_id(tenant)

    assert {:error, :account_unavailable} =
             Leases.insert_assigning(
               tenant,
               other_group,
               "session:other:1",
               nil,
               acc1.binding_id,
               spec_g4
             )

    # 3 VMs per (account, accelerator) cap
    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, "session:a:1", nil, acc1.binding_id, spec_g4)

    {:ok, l2, _} =
      Leases.insert_assigning(tenant, group, "session:a:1", nil, acc1.binding_id, spec_g4)

    {:ok, l3, _} =
      Leases.insert_assigning(tenant, group, "session:a:1", nil, acc1.binding_id, spec_g4)

    assert {:error, :account_capacity_full} =
             Leases.insert_assigning(tenant, group, "session:a:1", nil, acc1.binding_id, spec_g4)

    # 4th VM on another accelerator succeeds for same owner, 5th hits owner_vm_limit
    {:ok, _l4, _} =
      Leases.insert_assigning(tenant, group, "session:a:1", nil, acc1.binding_id, spec_l4)

    assert {:error, :owner_vm_limit} =
             Leases.insert_assigning(tenant, group, "session:a:1", nil, acc2.binding_id, spec_g4)

    # Promote l1 and verify generation fencing
    assert {:ok, active} =
             Leases.promote_active(l1.vm_id, 1, "m-s-1", "https://abc.prod.colab.dev")

    assert active.state == "active"
    assert active.generation == 2

    # Stale generation 1 rejected on promote, extend, claim_stopping, delete
    assert {:error, :stale_generation} =
             Leases.promote_active(l1.vm_id, 1, "m-s-1", "https://abc.prod.colab.dev")

    busy1 = DateTime.add(SystemsClock.utc_now(), 120, :second)

    assert {:error, :stale_generation} = Leases.extend_busy_and_hold(l1.vm_id, 1, busy1)
    assert {:ok, extended} = Leases.extend_busy_and_hold(l1.vm_id, 2, busy1)
    assert extended.busy_until != nil

    # touch_last_used never clears busy_until
    assert :ok = Leases.touch_last_used(l1.vm_id, 2)
    {:ok, reloaded} = Leases.get_by_id(l1.vm_id)
    assert reloaded.busy_until != nil

    assert {:error, :stale_generation} = Leases.delete_if_generation(l1.vm_id, 1)
    assert {:error, :stale_generation} = Leases.claim_stopping(l2.vm_id, 99)
    assert {:ok, :deleted} = Leases.delete_if_generation(l3.vm_id, 1)
  end

  test "pre-POST HTTP 503 and POST HTTP 412 rejection immediately delete lease without leaking capacity or blocking disconnect",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    _acc = connect_colab!(tenant, group, user_id, sub: "sub-definite-err")
    {:ok, scope} = Leases.owner_scope(ctx)

    # 1. Pre-POST failure: GET /tun/m/assign answers 503 before any POST -> lease deleted
    post_count = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 503, "service unavailable")

        {"POST", "/tun/m/assign"} ->
          :atomics.add_get(post_count, 1, 1)
          Plug.Conn.send_resp(conn, 500, "unexpected")
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})
    assert :atomics.get(post_count, 1) == 0
    assert {:ok, []} = Leases.list_for_owner(tenant, group, scope)

    # 2. Explicit 4xx rejection of the issued POST /tun/m/assign -> lease deleted
    Pool.clear_cooldowns()

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-412"}))

        {"POST", "/tun/m/assign"} ->
          :atomics.add_get(post_count, 1, 1)
          Plug.Conn.send_resp(conn, 412, "precondition failed")
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})
    assert :atomics.get(post_count, 1) == 1
    assert {:ok, []} = Leases.list_for_owner(tenant, group, scope)

    # Uninstall / disconnect is NOT blocked because no indeterminate lease was leaked
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)
  end

  test "POST HTTP 504 retains the assigning lease, blocks disconnect, and Reaper stops the late VM",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    _acc = connect_colab!(tenant, group, user_id, sub: "sub-post-504")
    {:ok, scope} = Leases.owner_scope(ctx)
    post_count = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-504"}))

        {"POST", "/tun/m/assign"} ->
          :atomics.add_get(post_count, 1, 1)
          Plug.Conn.send_resp(conn, 504, "gateway timeout")
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})
    assert :atomics.get(post_count, 1) == 1

    # The gateway may have forwarded the POST: the lease row stays and blocks disconnect.
    assert {:ok, [%{vm_id: vm_id, state: "assigning", endpoint: nil}]} =
             Leases.list_for_owner(tenant, group, scope)

    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    # Reaper re-probes with the same notebook_hash, finds the VM, and unassigns it.
    SystemsClock.advance(95_000)
    unassign_posts = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"endpoint" => "m-s-504-late"})
          )

        {"GET", "/tun/m/unassign/m-s-504-late"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-unassign"}))

        {"POST", "/tun/m/unassign/m-s-504-late"} ->
          :atomics.add_get(unassign_posts, 1, 1)
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, [:deleted]} = Reaper.sweep_once()
    assert :atomics.get(unassign_posts, 1) == 1
    assert {:error, :vm_not_found} = Leases.get_by_id(vm_id)
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)
  end

  test "indeterminate POST transport timeout retains lease, and Pool.stop_vm reports not_created only on the second XSRF-only probe after 600s",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-post-timeout")
    probe_count = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          n = :atomics.add_get(probe_count, 1, 1)

          if n == 1 do
            Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-1"}))
          else
            Plug.Conn.send_resp(conn, 503, "service unavailable")
          end

        {"POST", "/tun/m/assign"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})

    {:ok, scope} = Leases.owner_scope(ctx)
    {:ok, leases} = Leases.list_for_owner(tenant, group, scope)
    assert [%{vm_id: vm_id, state: "assigning", account_id: acc_id}] = leases
    assert acc_id == acc.binding_id
    assert :atomics.get(probe_count, 1) == 2

    # Advance > 120s while assign_get STILL returns 503: Reaper MUST retain lease (no 120s blind delete!)
    SystemsClock.advance(180_000)
    assert {:ok, [{:error, :transient}]} = Reaper.sweep_once()

    assert {:ok, [%{state: "stopping", endpoint: nil}]} =
             Leases.list_for_owner(tenant, group, scope)

    # Disconnect MUST continue returning :colab_account_in_use while indeterminate lease exists!
    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    # Within 600s, when assign_get returns XSRF without endpoint: Reaper retains lease,
    # disconnect stays 409, and Pool.stop_vm returns structured retryable response without crashing!
    SystemsClock.advance(65_000)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-absent"}))
      end
    end)

    assert {:ok, [{:error, :indeterminate}]} = Reaper.sweep_once()

    assert {:ok, [%{state: "stopping", endpoint: nil}]} =
             Leases.list_for_owner(tenant, group, scope)

    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    assert {:ok,
            %{
              "vm_id" => ^vm_id,
              "stopped" => false,
              "billing_stopped" => false,
              "state" => "stopping",
              "retryable" => true,
              "reason" => "assign_outcome_indeterminate"
            }} = Pool.stop_vm(ctx, vm_id)

    # >= 600s after created_at, a second live XSRF-only answer (the lease already carries
    # `assign_outcome_indeterminate`) confirms the assign never materialized. stop_vm
    # reports the lease gone without claiming that a billing VM was stopped.
    SystemsClock.advance(400_000)

    assert {:ok,
            %{
              "vm_id" => ^vm_id,
              "stopped" => true,
              "billing_stopped" => false,
              "state" => "not_created",
              "reason" => "assign_never_materialized"
            }} = Pool.stop_vm(ctx, vm_id)

    assert {:ok, []} = Leases.list_for_owner(tenant, group, scope)
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)
  end

  test "first XSRF-only probe after 600s keeps the lease and a later endpoint is still stopped",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    _acc = connect_colab!(tenant, group, user_id, sub: "sub-601-first-probe")
    {:ok, scope} = Leases.owner_scope(ctx)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-601"}))

        {"POST", "/tun/m/assign"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})

    assert {:ok, [%{vm_id: vm_id, state: "assigning", last_error: "assign_uncertain"}]} =
             Leases.list_for_owner(tenant, group, scope)

    # First Reaper probe happens at 601s: XSRF only, but no earlier post-POST Reaper probe
    # recorded `assign_outcome_indeterminate`, so the lease must stay.
    SystemsClock.advance(601_000)
    assert {:ok, [{:error, :indeterminate}]} = Reaper.sweep_once()

    assert {:ok,
            %{state: "stopping", endpoint: nil, last_error: "assign_outcome_indeterminate:" <> _}} =
             Leases.get_by_id(vm_id)

    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    # Next probe: the VM materialized. Reaper records it, unassigns, and deletes the lease.
    SystemsClock.advance(65_000)
    unassign_posts = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"endpoint" => "m-s-601-late"})
          )

        {"GET", "/tun/m/unassign/m-s-601-late"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-unassign"}))

        {"POST", "/tun/m/unassign/m-s-601-late"} ->
          :atomics.add_get(unassign_posts, 1, 1)
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, [:deleted]} = Reaper.sweep_once()
    assert :atomics.get(unassign_posts, 1) == 1
    assert {:error, :vm_not_found} = Leases.get_by_id(vm_id)
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)
  end

  test "retired account keeps probing indeterminate lease within 600s and unassigns when endpoint appears on later probe",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-retired-probe")
    {:ok, scope} = Leases.owner_scope(ctx)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-ret-1"}))

        {"POST", "/tun/m/assign"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})

    assert {:ok, [%{vm_id: vm_id, state: "assigning"}]} =
             Leases.list_for_owner(tenant, group, scope)

    # Retire the group while the indeterminate lease exists
    assert :ok = Account.retire_group_in_tx(tenant, group)
    assert {:ok, %{state: "retired"}} = Account.get_account(tenant, group, acc.binding_id)

    # 1st Reaper probe (< 600s): XSRF without endpoint -> stays in 'stopping' (NOT unassign_unconfirmed!)
    SystemsClock.advance(95_000)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-ret-2"}))
      end
    end)

    assert {:ok, [{:error, :indeterminate}]} = Reaper.sweep_once()
    assert {:ok, %{state: "stopping", endpoint: nil}} = Leases.get_by_id(vm_id)

    # 2nd Reaper probe (< 600s): endpoint materializes -> Reaper unassigns, deletes lease & retired account!
    SystemsClock.advance(65_000)
    unassign_posts = :atomics.new(1, signed: false)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <> Jason.encode!(%{"endpoint" => "m-s-retired-late"})
          )

        {"GET", "/tun/m/unassign/m-s-retired-late"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-unassign"}))

        {"POST", "/tun/m/unassign/m-s-retired-late"} ->
          :atomics.add_get(unassign_posts, 1, 1)
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, [:deleted]} = Reaper.sweep_once()
    assert :atomics.get(unassign_posts, 1) == 1
    assert {:error, :vm_not_found} = Leases.get_by_id(vm_id)
    assert {:ok, nil} = Account.get_account(tenant, group, acc.binding_id)
  end

  test "retired account keeps probing past 600s and confirms absence only on the second XSRF-only probe",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-retired-absent")
    {:ok, scope} = Leases.owner_scope(ctx)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-ret-abs"}))

        {"POST", "/tun/m/assign"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})

    assert {:ok, [%{vm_id: vm_id, state: "assigning"}]} =
             Leases.list_for_owner(tenant, group, scope)

    assert :ok = Account.retire_group_in_tx(tenant, group)

    # First probe past 600s: XSRF only -> kept and marked, retired account kept too.
    SystemsClock.advance(601_000)
    assert {:ok, [{:error, :indeterminate}]} = Reaper.sweep_once()
    assert {:ok, %{state: "stopping", endpoint: nil}} = Leases.get_by_id(vm_id)
    assert {:ok, %{state: "retired"}} = Account.get_account(tenant, group, acc.binding_id)

    # Second live XSRF-only probe confirms the assign never materialized.
    SystemsClock.advance(65_000)
    assert {:ok, [:confirmed_absent]} = Reaper.sweep_once()
    assert {:error, :vm_not_found} = Leases.get_by_id(vm_id)
    assert {:ok, nil} = Account.get_account(tenant, group, acc.binding_id)
  end

  test "active account Day-8 unassign_unconfirmed stays protected, blocks uninstall, and Day-8 same-sub reconnect unblocks Reaper + uninstall",
       %{tenant: tenant, group: group, user_id: user_id} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-day8", email: "day8@gmail.com")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, "session:a:day8", nil, acc.binding_id, spec)

    {:ok, _} = Leases.promote_active(l1.vm_id, 1, "m-s-day8-1", "https://abc.prod.colab.dev")

    # Force 401 on unassign + invalid_grant on refresh during disconnect
    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/unassign/m-s-day8-1"} ->
          Plug.Conn.send_resp(conn, 401, "unauthorized")

        {"POST", "/token"} ->
          Req.Test.json(Plug.Conn.put_status(conn, 400), %{"error" => "invalid_grant"})
      end
    end)

    # Disconnect MUST return :colab_account_in_use (409), restore state='active', and preserve reauthorization_required!
    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    {:ok, acc_after} = Account.get_account(tenant, group, acc.binding_id)
    assert acc_after.state == "active"
    assert acc_after.status == "reauthorization_required"

    {:ok, unconfirmed} = Leases.get_by_id(l1.vm_id)
    assert unconfirmed.state == "unassign_unconfirmed"
    assert unconfirmed.google_sub == "sub-day8"

    # Advance 8 FULL DAYS (past 7-day retired retention window!)
    SystemsClock.advance(8 * 86_400 * 1_000)

    # Reaper MUST NOT auto-prune active account's unassign_unconfirmed lease on Day 8!
    assert {:ok, []} = Reaper.sweep_once()
    assert {:ok, %{state: "unassign_unconfirmed"}} = Leases.get_by_id(l1.vm_id)

    # Uninstall STILL returns 409 Conflict on Day 8 before reconnect
    assert {:error, :colab_account_in_use} = Account.disconnect_all_for_group(tenant, group)

    # Day-8 same-google_sub reconnect immediately unblocks Reaper claim + stop + uninstall!
    {:ok, reconn_start} =
      Account.start_oauth_attempt(tenant, group, user_id,
        operation: :reconnect,
        binding_id: acc.binding_id
      )

    configure_oauth(fn conn ->
      now = SystemsClock.system_time(:second)

      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          id_token =
            build_id_token(%{
              "iss" => "https://accounts.google.com",
              "aud" => @client_id,
              "exp" => now + 3600,
              "sub" => "sub-day8",
              "email" => "day8@gmail.com",
              "email_verified" => true
            })

          Req.Test.json(conn, %{
            "access_token" => "ya29.day8-fresh",
            "refresh_token" => "1//day8-fresh",
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "scope" => "openid #{@colab_scope}",
            "id_token" => id_token
          })

        {"GET", "/tun/m/ccu-info"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"currentBalance" => 100.0}))

        {"GET", "/tun/m/unassign/m-s-day8-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-day8"}))

        {"POST", "/tun/m/unassign/m-s-day8-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, _} =
             Account.complete_oauth_attempt(
               tenant,
               group,
               user_id,
               reconn_start.attempt_id,
               "code-day8",
               operation: :reconnect,
               binding_id: acc.binding_id
             )

    # Reaper claims & deletes the Day-8 unassign_unconfirmed lease!
    _ = Reaper.sweep_once()
    assert {:error, :vm_not_found} = Leases.get_by_id(l1.vm_id)

    # Now disconnect succeeds cleanly!
    assert {:ok, %{generation: 2}} = Account.disconnect_all_for_group(tenant, group)
    assert {:ok, nil} = Account.get_account(tenant, group, acc.binding_id)
  end

  test "retired scope prunes unassign_unconfirmed after 7 days and hard-deletes retired colab_accounts row at 0 leases",
       %{tenant: tenant, group: group, user_id: user_id} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-ret-prune")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, "session:a:retp", nil, acc.binding_id, spec)

    {:ok, active} = Leases.promote_active(l1.vm_id, 1, "m-s-retp-1", "https://abc.prod.colab.dev")
    {:ok, _} = Leases.mark_unassign_unconfirmed(active.vm_id, active.generation)

    # Retire group (pure PG, zero HTTP) -> account becomes 'retired' and stays while lease exists
    assert :ok = Account.retire_group_in_tx(tenant, group)
    assert {:ok, %{state: "retired"}} = Account.get_account(tenant, group, acc.binding_id)

    # Advance 8 days -> Reaper prunes retired unassign_unconfirmed lease AND hard-deletes retired account!
    SystemsClock.advance(8 * 86_400 * 1_000)
    assert {:ok, []} = Reaper.sweep_once()
    assert {:error, :vm_not_found} = Leases.get_by_id(l1.vm_id)
    assert {:ok, nil} = Account.get_account(tenant, group, acc.binding_id)
  end

  test "Reaper respects 180s idle timeout, busy_until, and hold_minutes", %{
    tenant: tenant,
    group: group,
    user_id: user_id
  } do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-reap-1")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, "session:a:reap", nil, acc.binding_id, spec)

    {:ok, active} = Leases.promote_active(l1.vm_id, 1, "m-s-idle-1", "https://abc.prod.colab.dev")

    now = SystemsClock.utc_now()
    busy = DateTime.add(now, 60, :second)
    hold = DateTime.add(now, 600, :second)
    {:ok, _} = Leases.extend_busy_and_hold(active.vm_id, active.generation, busy, hold)

    # Advance 200s (past 180s idle and 60s busy, inside 600s hold) -> NOT reaped!
    SystemsClock.advance(200_000)
    assert {:ok, []} = Reaper.sweep_once()
    assert {:ok, %{state: "active"}} = Leases.get_by_id(active.vm_id)

    # Advance another 450s (past 600s hold) -> Reaped!
    SystemsClock.advance(450_000)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/unassign/m-s-idle-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-idle"}))

        {"POST", "/tun/m/unassign/m-s-idle-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    assert {:ok, [:deleted]} = Reaper.sweep_once()
    assert {:error, :vm_not_found} = Leases.get_by_id(active.vm_id)
  end

  test "orphaned active lease is reused by Pool and atomically adopted by LocalExec with generation fencing",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-peer-1")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, scope} = Leases.owner_scope(ctx)

    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, scope, nil, acc.binding_id, spec,
        owner_node: "salix@10.0.0.99"
      )

    {:ok, active} = Leases.promote_active(l1.vm_id, 1, "m-s-peer-1", "https://abc.prod.colab.dev")
    hold = DateTime.add(SystemsClock.utc_now(), 3600, :second)
    {:ok, active} = Leases.extend_busy_and_hold(active.vm_id, active.generation, hold, hold)

    assert {:ok, warm} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})
    assert warm.vm_id == active.vm_id
    assert warm.owner_node == "salix@10.0.0.99"

    configure_oauth(fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html>gateway</html>")
    end)

    op = %{
      op: :exec,
      vm_id: warm.vm_id,
      tenant_id: tenant,
      group_id: group,
      owner_scope: scope,
      command: "echo hi",
      timeout_ms: 10_000
    }

    assert {:error, :invalid_response} = LocalExec.execute(warm, op)

    {:ok, adopted} = Leases.get_by_id(active.vm_id)
    assert adopted.state == "active"
    assert adopted.owner_node == Atom.to_string(node())
    assert adopted.generation == active.generation + 1

    assert {:error, :stale_generation} =
             Leases.claim_orphaned_owner(active.vm_id, active.generation, "other@10.0.0.100")

    assert :ok = Tunnels.drop(active.vm_id)
    assert {:ok, %{state: "active"}} = Leases.get_by_id(active.vm_id)
  end

  test "Pool.acquire enforces 45s wall-clock ceiling across slow post-assign DNS and durably reclaims late endpoint",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    _acc = connect_colab!(tenant, group, user_id, sub: "sub-dns-deadline")

    parent = SystemsRuntime.Proc.self()
    SystemsRuntime.put_env(:salix_agent, :colab_test_dns_parent, parent)
    SystemsRuntime.put_env(:salix_agent, :resolver, SalixAgent.Colab.SlowDnsResolver)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :colab_test_dns_parent)
    end)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-dns"}))

        {"POST", "/tun/m/assign"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <>
              Jason.encode!(%{
                "endpoint" => "m-s-dns-late",
                "runtimeProxyInfo" => %{
                  "url" => "https://slow-dns.prod.colab.dev",
                  "token" => "ptok-dns"
                }
              })
          )
      end
    end)

    t0 = SystemsClock.monotonic_time(:millisecond)

    acquire_task =
      SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
        Pool.acquire(ctx, %{gpu: "G4", high_mem: false})
      end)

    dns_pid =
      SystemsClock.vreceive do
        {:dns_entered, pid} -> pid
      after
        5_000 -> flunk("slow DNS resolver was not entered")
      end

    SystemsClock.advance(44_800)
    assert nil == SystemsRuntime.Task.yield(acquire_task, 0)

    SystemsClock.advance(200)
    assert {:error, :colab_capacity} = SystemsRuntime.Task.await(acquire_task, :infinity)
    assert SystemsClock.monotonic_time(:millisecond) - t0 == 45_000

    SystemsClock.advance(800)
    worker_mon = SystemsRuntime.Proc.monitor(dns_pid)
    SystemsRuntime.Proc.send(dns_pid, :release_dns)

    SystemsClock.vreceive do
      {:DOWN, ^worker_mon, :process, ^dns_pid, _reason} -> :ok
    after
      5_000 -> flunk("background allocate worker did not finish durable reclamation")
    end

    {:ok, scope} = Leases.owner_scope(ctx)

    assert {:ok,
            [
              %{
                state: "stopping",
                endpoint: "m-s-dns-late",
                proxy_url: "https://slow-dns.prod.colab.dev",
                reap_after: reap_after
              }
            ]} = Leases.list_for_owner(tenant, group, scope)

    assert DateTime.compare(reap_after, SystemsClock.utc_now()) != :gt
  end

  test "assign POST ambiguous 408 stays indeterminate and keeps assigning row for Reaper", %{
    tenant: tenant,
    group: group,
    user_id: user_id,
    ctx: ctx
  } do
    _acc = connect_colab!(tenant, group, user_id, sub: "sub-post-408")
    {:ok, scope} = Leases.owner_scope(ctx)

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-408"}))

        {"POST", "/tun/m/assign"} ->
          Plug.Conn.send_resp(conn, 408, "request timeout")
      end
    end)

    assert {:error, :colab_capacity} = Pool.acquire(ctx, %{gpu: "G4", high_mem: false})

    assert {:ok, [%{state: "assigning", endpoint: nil}]} =
             Leases.list_for_owner(tenant, group, scope)
  end
end
