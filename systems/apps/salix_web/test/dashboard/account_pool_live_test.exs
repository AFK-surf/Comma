defmodule SalixWeb.Dashboard.AccountPoolLiveTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SalixWeb.DashboardEndpoint

  defmodule ResetWorker do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, {parent, 0}}

    def handle_call({:start, id, data, reply_to}, _from, {parent, attempts}) do
      cmd = Jason.decode!(data)

      case cmd["op"] do
        "/oauth/device/begin" ->
          reply(reply_to, id, %{
            "provider" => "codex",
            "mode" => "device",
            "device_auth_id" => "private-id",
            "user_code" => "USER-CODE",
            "interval" => 5,
            "url" => "https://auth.openai.com/codex/device"
          })

          {:reply, :ok, {parent, attempts}}

        "/oauth/device/poll" ->
          reply(reply_to, id, %{"credentials" => %{"access_token" => "device-token"}})
          {:reply, :ok, {parent, attempts}}

        "/normalize" ->
          reply(reply_to, id, %{
            "email" => "device@example.com",
            "credentials" => cmd["body"]["credentials"]
          })

          {:reply, :ok, {parent, attempts}}

        "/quota/reset" ->
          SystemsRuntime.Proc.send(parent, {:reset_requested, cmd["body"]["redeem_request_id"]})

          if attempts == 0 do
            SystemsRuntime.Proc.send(
              reply_to,
              {:subscription, id,
               %{"type" => "error", "status" => 502, "code" => "reset_unavailable"}}
            )
          else
            reply(reply_to, id, %{"code" => "already_redeemed", "windows_reset" => 0})
          end

          {:reply, :ok, {parent, attempts + 1}}

        "/quota" ->
          available = if attempts < 2, do: 1, else: 0

          reply(reply_to, id, %{
            "body" => %{
              "plan_type" => "pro",
              "rate_limit_reset_credits" => %{"available_count" => available}
            }
          })

          {:reply, :ok, {parent, attempts}}
      end
    end

    def handle_cast(_, state), do: {:noreply, state}

    defp reply(to, id, result) do
      SystemsRuntime.Proc.send(
        to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
      )

      SystemsRuntime.Proc.send(to, {:subscription, id, %{"type" => "done"}})
    end
  end

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-pool-ui-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    binary = Path.join(dir, "proxy")
    source = Path.expand("../../../../account-proxy", __DIR__)

    {output, status} =
      System.cmd("go", ["build", "-o", binary, "./cmd/salix-account-proxy"],
        cd: source,
        stderr_to_stdout: true
      )

    assert status == 0, output
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, binary: binary, dir: dir}
  end

  setup %{binary: binary} do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Pool UI"})
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other pool"})
    old = SystemsRuntime.get_env(:salix_agent, :subscription_worker)
    worker = start_supervised!({SalixAgent.SubscriptionWorker, name: nil, command: {binary, []}})
    quota_worker = start_supervised!({SalixWeb.TestSubscriptionQuotaWorker, worker})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, quota_worker)

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_agent, :subscription_worker, old),
        else: SystemsRuntime.delete_env(:salix_agent, :subscription_worker)
    end)

    {:ok, tenant: tenant["tenant_id"], other: other["tenant_id"]}
  end

  defp conn(tenant),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

  defp settle(view) do
    render_async(view, 5_000)
    render_async(view, 5_000)
  end

  test "reset requires confirmation and resumes the same attempt after reconnect", ctx do
    alias SalixAgent.SubscriptionStore, as: Store
    worker = start_supervised!({ResetWorker, SystemsRuntime.Proc.self()})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
    id = Store.id()
    {:ok, cipher} = Store.seal(ctx.tenant, id, %{"access_token" => "test"})

    {:ok, _} =
      Store.create(ctx.tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "prepared" => true,
        "disabled" => false,
        "credentials" => cipher,
        "quota" => %{"reset_credits" => %{"available_count" => 1}}
      })

    # The quota poller can refresh this account before the page mounts.
    {:ok, _} = SalixAgent.AccountPool.quota(ctx.tenant, id)
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    assert settle(view) =~ "Resets available: 1"
    assert has_element?(view, "#account-#{id}", "Pro plan")
    view |> element("button[phx-click=reset]") |> render_click()
    settle_refute_receive({:reset_requested, _})
    assert has_element?(view, "button[phx-click=confirm-reset]")
    view |> element("button[phx-click=confirm-reset]") |> render_click()
    assert settle(view) =~ "The reset result is not confirmed"
    settle_receive({:reset_requested, key})
    # A new LiveView reads the durable pending key, rather than minting another.
    {:ok, resumed, _} = live(conn(ctx.tenant), "/dash/account-pool")
    assert settle(resumed) =~ "Check pending reset"
    resumed |> element("button[phx-click=reset]") |> render_click()
    resumed |> element("button[phx-click=confirm-reset]") |> render_click()
    assert settle(resumed) =~ "No additional reset credit was used"
    settle_receive({:reset_requested, ^key})
    assert has_element?(resumed, "button[phx-click=reset][disabled]")
    refute has_element?(resumed, "button[phx-click=confirm-reset]")
  end

  test "Dashboard manages real Go accounts without exposing credentials or crossing tenants",
       ctx do
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    assert render_async(view, 5_000) =~ "No subscriptions connected"
    view |> element("button[phx-click=open-import]") |> render_click()

    view
    |> form("form[phx-submit=import]", %{
      "provider" => "codex",
      "credential_json" => ~s({"access_token":"synthetic-secret","email":"member@example.com"})
    })
    |> render_submit()

    html = render_async(view, 5_000)
    assert html =~ "member@example.com"
    refute html =~ "Account name"
    assert has_element?(view, "table")
    refute html =~ "synthetic-secret"
    {:ok, %{"accounts" => [account]}} = SalixAgent.AccountPool.list(ctx.tenant)
    # Disable immediately so the background worker never contacts a real provider.
    view |> element("button[phx-click=toggle]") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, ~s(button[role="switch"][aria-checked="false"]))
    assert has_element?(view, ~s(tr[data-disabled="true"]))
    view |> element("button[phx-click=replace]") |> render_click()

    view
    |> form("form[phx-submit=import]", %{
      "credential_json" => ~s({"access_token":"replacement-secret","email":"updated@example.com"})
    })
    |> render_submit()

    html = render_async(view, 5_000)
    refute html =~ "replacement-secret"
    assert html =~ "updated@example.com"
    {:ok, foreign, _} = live(conn(ctx.other), "/dash/account-pool")
    refute render_async(foreign, 5_000) =~ "updated@example.com"
    render_click(foreign, "delete", %{"id" => account["id"], "tenant" => ctx.tenant})
    assert {:ok, %{"accounts" => [_]}} = SalixAgent.AccountPool.list(ctx.tenant)
    view |> element("button[phx-click=delete]") |> render_click()
    assert {:ok, %{"accounts" => [_]}} = SalixAgent.AccountPool.list(ctx.tenant)
    view |> element("button[phx-click=confirm-delete]") |> render_click()
    assert render_async(view, 5_000) =~ "No subscriptions connected"
    assert {:ok, %{"accounts" => []}} = SalixAgent.AccountPool.list(ctx.tenant)
  end

  test "Codex device enrollment displays a code and completes without callback input", ctx do
    alias SalixAgent.SubscriptionStore, as: Store
    worker = start_supervised!({ResetWorker, SystemsRuntime.Proc.self()})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    settle(view)
    view |> element("button[phx-click=open-connect]") |> render_click()
    view |> form("#authorize", %{"provider" => "codex"}) |> render_submit()
    assert settle(view) =~ "USER-CODE"
    assert_push_event(view, "subscription-device-pending", %{id: id, interval: 5})

    assert {:ok, %{rows: [[ciphertext]]}} =
             Store.query(
               "SELECT ciphertext FROM subscription_oauth_attempts WHERE tenant_id=$1 AND id=$2",
               [ctx.tenant, id]
             )

    assert {:ok, private} = Store.open(ctx.tenant, id, ciphertext)
    assert {:ok, sealed} = Store.seal(ctx.tenant, id, Map.put(private, "next_poll_at", 0))

    assert {:ok, _} =
             Store.query(
               "UPDATE subscription_oauth_attempts SET ciphertext=$3 WHERE tenant_id=$1 AND id=$2",
               [ctx.tenant, id, sealed]
             )

    render_hook(view, "poll-device", %{"id" => id})
    assert settle(view) =~ "device@example.com"
    refute has_element?(view, "#subscription-dialog")
  end

  test "OAuth UI starts native PKCE enrollment and rejects a mismatched callback", ctx do
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    render_async(view, 5_000)
    view |> element("button[phx-click=open-connect]") |> render_click()
    render_hook(view, "authorize", %{"provider" => "unsupported"})
    assert render_async(view, 5_000) =~ "Invalid credentials"
    assert_push_event(view, "subscription-oauth-error", %{})
    assert has_element?(view, "#authorize")
    view |> form("#authorize", %{"provider" => "claude"}) |> render_submit()
    html = render_async(view, 5_000)
    assert_push_event(view, "subscription-oauth-ready", %{url: url})
    assert url =~ "code_challenge"
    assert html =~ "Open Claude authorization"
    assert html =~ "code_challenge"

    view
    |> form("form[phx-submit=complete]", %{"code" => "code#wrong-state"})
    |> render_submit()

    assert render_async(view, 5_000) =~ "Invalid credentials or authorization code"
    refute has_element?(view, "form[phx-submit=complete]")
  end
end
