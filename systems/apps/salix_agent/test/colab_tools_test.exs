defmodule SalixAgent.Colab.ToolsTestPluginStoreFast do
  def plugin_enabled?(_tenant_id, _group_id, "google-colab"), do: true
  def plugin_enabled?(_tenant_id, _group_id, _plugin_id), do: false
end

defmodule SalixAgent.Colab.ToolsTestPluginStoreDisabled do
  def plugin_enabled?(_tenant_id, _group_id, _plugin_id), do: false
end

defmodule SalixAgent.Colab.ToolsTestPluginStoreFallback do
  def list_group_enablements(_tenant_id, _group_id) do
    {:ok, [%{"plugin_id" => "google-colab", "enabled" => true}]}
  end
end

defmodule SalixAgent.Colab.ToolsTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{CapabilityRequests, PluginStore, ToolDisclosure, Tools}
  alias SalixAgent.Colab.{Account, Leases, Pool}
  alias SalixAgent.IFC.Destination
  alias SalixAgent.Tools.Colab
  alias SalixStore.{Ids, Repo, TenantProfiles}

  @client_id "test-colab-client-id"
  @colab_scope "https://www.googleapis.com/auth/colaboratory"

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)
    user_id = "usr_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(8), padding: false)

    prev_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)
    prev_plugin_store = SystemsRuntime.get_env(:salix_agent, :plugin_store_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :plugin_store_mod,
      SalixAgent.Colab.ToolsTestPluginStoreFast
    )

    Pool.clear_cooldowns()

    on_exit(fn ->
      Pool.clear_cooldowns()
      restore_env(:colab_oauth, prev_oauth)
      restore_env(:plugin_store_mod, prev_plugin_store)
      _ = Repo.query("DELETE FROM colab_vm_leases WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_oauth_attempts WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_group_install_states WHERE tenant_id=$1", [tenant])
      _ = Repo.query("DELETE FROM colab_accounts WHERE tenant_id=$1", [tenant])
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
    sub = Keyword.get(opts, :sub, "sub-tools-1")
    email = Keyword.get(opts, :email, "alice@gmail.com")

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
            "access_token" => "ya29.tok-" <> sub,
            "refresh_token" => "1//ref-" <> sub,
            "token_type" => "Bearer",
            "expires_in" => 3600,
            "scope" => "openid #{@colab_scope}",
            "id_token" => id_token
          })

        {"GET", "/tun/m/ccu-info"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ")]}'\n" <>
              Jason.encode!(%{
                "currentBalance" => 1234.5,
                "consumptionRateHourly" => 10.0,
                "assignmentsCount" => 1,
                "eligibleGpus" => ["G4", "L4"]
              })
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

  test "PluginStore.enabled?/3 supports fast plugin_enabled?/3, list_group_enablements fallback, and fails closed",
       %{tenant: tenant, group: group} do
    assert PluginStore.enabled?(tenant, group, "google-colab") == true
    assert PluginStore.enabled?(tenant, group, "other-plugin") == false

    SystemsRuntime.put_env(
      :salix_agent,
      :plugin_store_mod,
      SalixAgent.Colab.ToolsTestPluginStoreFallback
    )

    assert PluginStore.enabled?(tenant, group, "google-colab") == true
    assert PluginStore.enabled?(tenant, group, "other-plugin") == false

    SystemsRuntime.delete_env(:salix_agent, :plugin_store_mod)
    assert PluginStore.enabled?(tenant, group, "google-colab") == false
  end

  test "Pool.authorize/3 enforces live PluginStore.enabled?/3, CollaborationPolicy, GuestPolicy, and router-only tenants",
       %{tenant: tenant, ctx: ctx} do
    assert :ok = Pool.authorize(ctx, tenant, "colab.exec")

    # CollaborationPolicy fail-closed for collaboration_worker & collaboration_sandbox_worker
    collab_ctx = Map.put(ctx, :collaboration_policy, :restricted)
    assert {:error, :guest_restricted} = Pool.authorize(collab_ctx, tenant, "colab.exec")

    sandbox_collab_ctx = Map.put(ctx, :collaboration_policy, :sandbox_restricted)
    assert {:error, :guest_restricted} = Pool.authorize(sandbox_collab_ctx, tenant, "colab.exec")

    # GuestPolicy fail-closed
    guest_ctx = Map.put(ctx, :guest_policy, :restricted)
    assert {:error, :guest_restricted} = Pool.authorize(guest_ctx, tenant, "colab.exec")

    # Live PluginStore disabled fails closed even without plugin_projection in ctx
    SystemsRuntime.put_env(
      :salix_agent,
      :plugin_store_mod,
      SalixAgent.Colab.ToolsTestPluginStoreDisabled
    )

    assert {:error, :plugin_disabled} = Pool.authorize(ctx, tenant, "colab.exec")
    assert {:error, :plugin_disabled} = Pool.authorize(ctx, tenant, "colab.stop")
  end

  test "IFC Destination classification and additional_destinations for all 5 colab.* tools", %{
    ctx: ctx
  } do
    assert {:read, %{}} = Destination.describe("colab.status", %{}, ctx)
    assert {:none, %{}} = Destination.describe("colab.stop", %{"vm_id" => "colab_1"}, ctx)
    assert {:egress, %{"kind" => "public"}} = Destination.describe("colab.exec", %{}, ctx)
    assert {:egress, %{"kind" => "public"}} = Destination.describe("colab.upload", %{}, ctx)
    assert {:egress, %{"kind" => "public"}} = Destination.describe("colab.download", %{}, ctx)

    assert [{:persist, %{"kind" => "drive", "path" => "/drive/out.png", "group_id" => g}}] =
             Destination.additional_destinations(
               "colab.download",
               %{"destination" => "/drive/out.png"},
               ctx
             )

    assert g == ctx.group_id

    assert [{:persist, %{"kind" => "agent_private"}}] =
             Destination.additional_destinations(
               "colab.download",
               %{"destination" => "/outputs/out.png"},
               ctx
             )
  end

  test "ToolDisclosure gates colab.* by group active account, guest policy, and owner leases", %{
    tenant: tenant,
    group: group,
    agent: agent,
    user_id: user_id,
    ctx: ctx
  } do
    assert "colab" in ToolDisclosure.discovery_namespaces()

    # 1. No Colab account and no leases -> all colab.* rejected
    disc_empty = ToolDisclosure.materialize_static("worker", :internal, ctx)
    names_empty = Enum.map(disc_empty["tools"], & &1["name"])
    refute Enum.any?(names_empty, &String.starts_with?(&1, "colab."))

    # 2. Connected Colab account -> all 5 colab.* offered (hidden by default)
    acc = connect_colab!(tenant, group, user_id, sub: "sub-disc-1")
    disc_ok = ToolDisclosure.materialize_static("worker", :internal, ctx)
    colab_entries = Enum.filter(disc_ok["tools"], &String.starts_with?(&1["name"], "colab."))

    assert Enum.sort(Enum.map(colab_entries, & &1["name"])) == [
             "colab.download",
             "colab.exec",
             "colab.status",
             "colab.stop",
             "colab.upload"
           ]

    assert Enum.all?(colab_entries, &(&1["prompt_visibility"] == "hidden"))

    # 3. Guest policy -> all colab.* rejected even with account
    guest_ctx = Map.put(ctx, :guest_policy, :restricted)
    disc_guest = ToolDisclosure.materialize_static("router", :internal, guest_ctx)
    refute Enum.any?(disc_guest["tools"], &String.starts_with?(&1["name"], "colab."))

    # 4. Router-only tenant -> all colab.* rejected
    ro_tenant = Ids.new_tenant_id()
    {:ok, _} = TenantProfiles.put_router_only(ro_tenant, 10)
    ro_group = Ids.new_group_id(ro_tenant)

    ro_ctx = %{
      tenant_id: ro_tenant,
      group_id: ro_group,
      agent_id: Ids.new_agent_id(ro_group),
      session_id: "s"
    }

    disc_ro = ToolDisclosure.materialize_static("router", :internal, ro_ctx)
    refute Enum.any?(disc_ro["tools"], &String.starts_with?(&1["name"], "colab."))

    # 5. Retire account while owner has a lease -> keep ONLY status & stop for lease owner
    {:ok, scope} = Leases.owner_scope(ctx)
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, lease, _} = Leases.insert_assigning(tenant, group, scope, nil, acc.binding_id, spec)
    {:ok, _} = Leases.promote_active(lease.vm_id, 1, "m-s-disc-1", "https://abc.prod.colab.dev")

    {:ok, _} =
      Repo.query("UPDATE colab_accounts SET state = 'retired' WHERE binding_id = $1", [
        acc.binding_id
      ])

    disc_retired = ToolDisclosure.materialize_static("worker", :internal, ctx)

    colab_after =
      disc_retired["tools"]
      |> Enum.filter(&String.starts_with?(&1["name"], "colab."))
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert colab_after == ["colab.status", "colab.stop"]

    # Another session without leases sees zero colab.* tools
    other_ctx = %{tenant_id: tenant, group_id: group, agent_id: agent, session_id: "sess-other"}
    disc_other = ToolDisclosure.materialize_static("worker", :internal, other_ctx)
    refute Enum.any?(disc_other["tools"], &String.starts_with?(&1["name"], "colab."))
  end

  test "cross-scope isolation (session vs task), {group} audience label, and CapabilityRequests.complete_plugin_install_strict/3",
       %{tenant: tenant, group: group, agent: agent, user_id: user_id, ctx: ctx} do
    assert :ok = CapabilityRequests.complete_plugin_install_strict(group, tenant, "google-colab")

    acc = connect_colab!(tenant, group, user_id, sub: "sub-iso-1")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, session_scope} = Leases.owner_scope(ctx)

    {:ok, l1, _} =
      Leases.insert_assigning(tenant, group, session_scope, nil, acc.binding_id, spec)

    {:ok, active} = Leases.promote_active(l1.vm_id, 1, "m-s-iso-1", "https://abc.prod.colab.dev")

    task_ctx = %{
      tenant_id: tenant,
      group_id: group,
      agent_id: agent,
      task_conversation_id: "cnv_task_99"
    }

    assert {:tool_failure, body, "vm_not_found", "user_reportable", _, []} =
             Colab.stop(%{"vm_id" => active.vm_id}, task_ctx)

    assert %{"ok" => false, "error" => %{"code" => "vm_not_found"}} = Jason.decode!(body)

    ifc_ctx = Map.put(ctx, :ifc, %{})
    assert {:tool_ifc, json, [], %{"label" => encoded_label}} = Colab.status(%{}, ifc_ctx)
    assert is_list(encoded_label)
    decoded = Jason.decode!(json)
    assert [%{"email" => "al***@gmail.com"}] = decoded["accounts"]
    assert [%{"vm_id" => vm_id}] = decoded["vms"]
    assert vm_id == active.vm_id

    configure_oauth(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/tun/m/unassign/m-s-iso-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n" <> Jason.encode!(%{"token" => "xsrf-stop"}))

        {"POST", "/tun/m/unassign/m-s-iso-1"} ->
          Plug.Conn.send_resp(conn, 200, ")]}'\n{}")
      end
    end)

    stop_json = Colab.stop(%{"vm_id" => active.vm_id}, ctx)
    assert %{"stopped" => true, "billing_stopped" => true} = Jason.decode!(stop_json)
  end

  test "Tools registry includes colab.* with 600s+ timeouts",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    assert Tools.tool_timeout_ms("colab.exec", %{"timeout_seconds" => 600}) == 615_000
    assert Tools.tool_timeout_ms("colab.upload", %{}) == 615_000
    assert Tools.tool_timeout_ms("colab.download", %{}) == 615_000

    _acc = connect_colab!(tenant, group, user_id, sub: "sub-arch-1")
    disc = ToolDisclosure.materialize_static("worker", :internal, ctx)
    exec_ctx = Map.put(ctx, :tool_disclosure, disc)

    [res] = Tools.execute([%{id: "tc-1", name: "colab.status", args: %{}}], exec_ctx)
    assert res.error == false
    assert %{"accounts" => [_], "vms" => []} = Jason.decode!(res.content)
  end

  defmodule RaisingDrive do
    @behaviour SalixAgent.Drive

    @impl true
    def list(_g, _p), do: {:ok, []}
    @impl true
    def stat(_g, _p), do: {:error, :not_found}
    @impl true
    def read(_g, _p, _m), do: {:error, :not_found}
    @impl true
    def write(_g, _p, _b, _s, _o \\ []), do: {:error, :unavailable}
    @impl true
    def delete(_g, _p), do: {:error, :unavailable}
    @impl true
    def status(_g), do: {:ok, %{available: true, writable: true, detail: "ok"}}

    @impl true
    def stream(_g, _p) do
      stream = Stream.map([1], fn _ -> raise "stream timeout secret" end)
      {:ok, stream, nil}
    end
  end

  test "raised exception inside Drive stream during colab.upload still carries {group} IFC label and never leaks raw exception",
       %{tenant: tenant, group: group, user_id: user_id, ctx: ctx} do
    prev_drive = SystemsRuntime.get_env(:salix_agent, :drive_mod)
    SystemsRuntime.put_env(:salix_agent, :drive_mod, RaisingDrive)
    on_exit(fn -> restore_env(:drive_mod, prev_drive) end)

    acc = connect_colab!(tenant, group, user_id, sub: "sub-raise-drive")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, scope} = Leases.owner_scope(ctx)
    {:ok, l1, _} = Leases.insert_assigning(tenant, group, scope, nil, acc.binding_id, spec)

    {:ok, active} =
      Leases.promote_active(l1.vm_id, 1, "m-s-raise-1", "https://abc.prod.colab.dev")

    fake_ssh =
      spawn(fn ->
        receive do
          _ -> :ok
        end
      end)

    on_exit(fn -> Process.exit(fake_ssh, :kill) end)

    fake_tunnel =
      spawn(fn ->
        {:ok, _} =
          SystemsRuntime.Registry.register(SalixAgent.Colab.Tunnels.registry(), active.vm_id, nil)

        loop = fn f ->
          receive do
            {:"$gen_call", from, {:connect, _gen, _opts}} ->
              GenServer.reply(from, {:ok, fake_ssh})
              f.(f)

            :stop ->
              :ok
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> Process.exit(fake_tunnel, :kill) end)

    Enum.reduce_while(1..50, nil, fn _, _ ->
      case SalixAgent.Colab.Tunnels.lookup(active.vm_id) do
        {:ok, ^fake_tunnel} -> {:halt, :ok}
        _ -> {:cont, :erlang.yield()}
      end
    end)

    disc = ToolDisclosure.materialize_static("worker", :internal, ctx)
    exec_ctx = ctx |> Map.put(:ifc, %{}) |> Map.put(:tool_disclosure, disc)

    [tool_res] =
      Tools.execute(
        [
          %{
            id: "tc-upload-raise",
            name: "colab.upload",
            args: %{
              "vm_id" => active.vm_id,
              "source" => "/drive/boom.bin",
              "destination" => "/content/boom.bin"
            }
          }
        ],
        exec_ctx
      )

    assert tool_res.error == true
    assert is_list(get_in(tool_res, [:ifc, "label"]))
    assert Enum.any?(get_in(tool_res, [:ifc, "label"]), &String.contains?(&1, group))
    refute tool_res.content =~ "stream timeout secret"

    [nul_res] =
      Tools.execute(
        [
          %{
            id: "tc-exec-nul",
            name: "colab.exec",
            args: %{"command" => "echo hi\0there"}
          }
        ],
        exec_ctx
      )

    assert nul_res.error == true
    assert is_list(get_in(nul_res, [:ifc, "label"]))
    assert Enum.any?(get_in(nul_res, [:ifc, "label"]), &String.contains?(&1, group))
    assert nul_res.content =~ "invalid_argument"
  end

  test "transfer failures carry {group} IFC label and never leak raw upstream error bodies", %{
    tenant: tenant,
    group: group,
    user_id: user_id,
    ctx: ctx
  } do
    acc = connect_colab!(tenant, group, user_id, sub: "sub-ifc-fail")
    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}
    {:ok, scope} = Leases.owner_scope(ctx)
    {:ok, l1, _} = Leases.insert_assigning(tenant, group, scope, nil, acc.binding_id, spec)
    {:ok, active} = Leases.promote_active(l1.vm_id, 1, "m-s-ifc-1", "https://abc.prod.colab.dev")

    configure_oauth(fn conn ->
      Plug.Conn.send_resp(conn, 502, "SENSITIVE_UPSTREAM_BODY_SECRET")
    end)

    ifc_ctx = Map.put(ctx, :ifc, %{})

    result =
      Colab.download(
        %{
          "vm_id" => active.vm_id,
          "source" => "/content/out.txt",
          "destination" => "/outputs/out.txt"
        },
        ifc_ctx
      )

    assert {:tool_ifc, {:tool_failure, json, "colab_http_error", "user_reportable", msg, []},
            %{"label" => encoded_label}} = result

    assert is_list(encoded_label)
    assert Enum.any?(encoded_label, &String.contains?(&1, group))
    refute json =~ "SENSITIVE_UPSTREAM_BODY_SECRET"
    refute msg =~ "SENSITIVE_UPSTREAM_BODY_SECRET"
    assert %{"ok" => false, "error" => %{"status" => 502}} = Jason.decode!(json)

    disc = ToolDisclosure.materialize_static("worker", :internal, ctx)
    exec_ctx = ifc_ctx |> Map.put(:tool_disclosure, disc)

    [tool_res] =
      Tools.execute(
        [
          %{
            id: "tc-dl-fail",
            name: "colab.download",
            args: %{
              "vm_id" => active.vm_id,
              "source" => "/content/out.txt",
              "destination" => "/outputs/out.txt"
            }
          }
        ],
        exec_ctx
      )

    assert tool_res.error == true
    assert is_list(get_in(tool_res, [:ifc, "label"]))
    refute tool_res.content =~ "SENSITIVE_UPSTREAM_BODY_SECRET"
  end
end
