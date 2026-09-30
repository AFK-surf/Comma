defmodule SalixWeb.Dashboard.AccountPoolLiveTest do
  use ExUnit.Case, async: false
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
          send(parent, {:reset_requested, cmd["body"]["redeem_request_id"]})

          if attempts == 0 do
            send(
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
            "plan_type" => "pro",
            "windows" => [],
            "reset_credits" => %{"available_count" => available}
          })

          {:reply, :ok, {parent, attempts}}
      end
    end

    def handle_cast(_, state), do: {:noreply, state}

    defp reply(to, id, result) do
      send(
        to,
        {:subscription, id, %{"type" => "data", "data" => Base.encode64(Jason.encode!(result))}}
      )

      send(to, {:subscription, id, %{"type" => "done"}})
    end
  end

  setup_all do
    dir = Path.join(System.tmp_dir!(), "salix-pool-ui-#{System.unique_integer([:positive])}")
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
    # This test owns account versions through explicit UI/API mutations. A
    # background quota refresh would invalidate the version between opening
    # the confirmation dialog and submitting it, testing conflict handling
    # instead of the pending-reset/reconnect contract.
    quota_worker = Process.whereis(SalixAgent.SubscriptionQuotaWorker)
    if quota_worker, do: :sys.suspend(quota_worker)

    on_exit(fn ->
      if quota_worker && Process.alive?(quota_worker), do: :sys.resume(quota_worker)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Pool UI"})
    {:ok, other} = Salix.Control.Tenants.create(%{"name" => "Other pool"})
    old = Application.get_env(:salix_agent, :subscription_worker)
    worker = start_supervised!({SalixAgent.SubscriptionWorker, name: nil, command: {binary, []}})
    quota_worker = start_supervised!({SalixWeb.TestSubscriptionQuotaWorker, worker})
    Application.put_env(:salix_agent, :subscription_worker, quota_worker)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_agent, :subscription_worker, old),
        else: Application.delete_env(:salix_agent, :subscription_worker)
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
    worker = start_supervised!({ResetWorker, self()})
    Application.put_env(:salix_agent, :subscription_worker, worker)
    id = Store.id()
    {:ok, cipher} = Store.seal(ctx.tenant, id, %{"access_token" => "test"})

    {:ok, _} =
      Store.create(ctx.tenant, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
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
    refute_receive {:reset_requested, _}
    assert has_element?(view, "button[phx-click=confirm-reset]")
    view |> element("button[phx-click=confirm-reset]") |> render_click()
    assert settle(view) =~ "The reset result is not confirmed"
    assert_receive {:reset_requested, key}
    # A new LiveView reads the durable pending key, rather than minting another.
    {:ok, resumed, _} = live(conn(ctx.tenant), "/dash/account-pool")
    assert settle(resumed) =~ "Check pending reset"
    resumed |> element("button[phx-click=reset]") |> render_click()
    resumed |> element("button[phx-click=confirm-reset]") |> render_click()
    assert settle(resumed) =~ "No additional reset credit was used"
    assert_receive {:reset_requested, ^key}
    assert has_element?(resumed, "button[phx-click=reset][disabled]")
    refute has_element?(resumed, "button[phx-click=confirm-reset]")
  end

  test "unknown Codex reset count differs from zero and Claude does not offer reset", ctx do
    alias SalixAgent.SubscriptionStore, as: Store

    ids =
      for provider <- ["codex", "claude"], into: %{} do
        id = Store.id()
        {:ok, cipher} = Store.seal(ctx.tenant, id, %{"access_token" => "test"})

        {:ok, _} =
          Store.create(ctx.tenant, %{
            "id" => id,
            "credential_kind" => "subscription_oauth",
            "provider" => provider,
            "status" => "active",
            "prepared" => true,
            "disabled" => false,
            "credentials" => cipher
          })

        {provider, id}
      end

    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    html = settle(view)
    assert html =~ "Resets available: unknown"
    assert html =~ "Reset not supported"
    assert has_element?(view, "#account-#{ids["claude"]}", "Plan unknown")
    assert has_element?(view, "button[phx-click=reset][disabled]")
    refute has_element?(view, "#account-#{ids["claude"]} button[phx-click=reset]")
  end

  for provider <- ["codex", "claude"] do
    @provider provider
    test "importing #{@provider} twice through the dashboard replaces its credentials", ctx do
      {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
      settle(view)

      ids =
        for token <- ["first-secret", "replacement-secret"] do
          view |> element("button[phx-click=open-import]") |> render_click()
          view |> form("form[phx-submit=import]", %{"provider" => @provider}) |> render_change()

          view
          |> form("form[phx-submit=import]", %{
            "provider" => @provider,
            "credential_json" =>
              Jason.encode!(%{"access_token" => token, "email" => "repeat@example.com"})
          })
          |> render_submit()

          html = settle(view)
          assert html =~ "repeat@example.com"
          assert html =~ "Pro plan"
          refute html =~ token
          assert {:ok, %{"accounts" => [account]}} = SalixAgent.AccountPool.list(ctx.tenant)
          assert account["provider"] == @provider

          assert {:ok, stored} =
                   SalixAgent.SubscriptionStore.get(ctx.tenant, account["id"])

          assert {:ok, credentials} =
                   SalixAgent.SubscriptionStore.open(
                     ctx.tenant,
                     account["id"],
                     stored["credentials"]
                   )

          assert credentials["access_token"] == token
          account["id"]
        end

      assert Enum.uniq(ids) |> length() == 1
    end
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

  test "credential dialog accepts a JSON file and rejects malformed pasted JSON", ctx do
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    render_async(view, 5_000)
    view |> element("button[phx-click=open-import]") |> render_click()
    view |> form("form[phx-submit=import]", %{"credential_json" => "{invalid"}) |> render_submit()
    assert render(view) =~ "valid JSON object"

    upload =
      file_input(view, "form[phx-submit=import]", :credentials, [
        %{
          name: "auth.json",
          content: ~s({"access_token":"upload-secret","email":"uploaded@example.com"}),
          type: "application/json"
        }
      ])

    render_upload(upload, "auth.json")
    view |> form("form[phx-submit=import]", %{"credential_json" => ""}) |> render_submit()
    html = render_async(view, 5_000)
    assert html =~ "uploaded@example.com"
    refute html =~ "upload-secret"
    refute has_element?(view, "#subscription-dialog")
    view |> element("button[phx-click=toggle]") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, ~s(button[role="switch"][aria-checked="false"]))
    assert has_element?(view, ~s(tr[data-disabled="true"]))
  end

  test "account pages remain bounded and have no ten-account cap", ctx do
    accounts =
      for _ <- 1..26 do
        {:ok, account} =
          SalixAgent.AccountPool.create(ctx.tenant, %{
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "credentials" => %{"access_token" => "synthetic-pagination"}
          })

        {:ok, _} =
          SalixAgent.AccountPool.update(ctx.tenant, account["id"], %{
            "version" => account["version"],
            "disabled" => true
          })

        account
      end

    {:ok, view, _} = live(conn(ctx.tenant), "/dash/account-pool")
    render_async(view, 5_000)
    assert Enum.count(accounts, &has_element?(view, ~s([id="account-#{&1["id"]}"]))) == 25
    view |> element("button[phx-click=next]") |> render_click()
    render_async(view, 5_000)
    assert Enum.count(accounts, &has_element?(view, ~s([id="account-#{&1["id"]}"]))) == 1
    refute has_element?(view, "button[phx-click=next]")
    view |> element("button[phx-click=refresh]", "First page") |> render_click()
    render_async(view, 5_000)
    assert Enum.count(accounts, &has_element?(view, ~s([id="account-#{&1["id"]}"]))) == 25
  end

  test "Codex device enrollment displays a code and completes without callback input", ctx do
    alias SalixAgent.SubscriptionStore, as: Store
    worker = start_supervised!({ResetWorker, self()})
    Application.put_env(:salix_agent, :subscription_worker, worker)
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

  test "private template UI binds tenant route without storing internal credentials", ctx do
    {:ok, view, _} = live(conn(ctx.tenant), "/dash/templates/new?scope=tenant")

    {:ok, _edit, _html} =
      view
      |> form("form[phx-submit=save]", %{
        "name" => "Pool model",
        "model" => "gpt-5",
        "account_pool" => "codex"
      })
      |> render_submit()
      |> follow_redirect(conn(ctx.tenant))

    {:ok, [template]} = SalixAgent.Templates.list_private(ctx.tenant)
    assert template["provider_config"] == %{"account_pool" => "codex"}

    {:ok, resolved} =
      SalixAgent.Templates.resolve_llm_for_template(template["template_id"], ctx.tenant)

    refute Map.has_key?(resolved, "api_key")
    assert resolved["base_url"] == "subscription://worker/v1"
    assert resolved["protocol"] == "responses"
    assert SalixAgent.AccountPool.owns_route?(resolved)

    refute SalixAgent.AccountPool.owns_route?(
             Map.put(resolved, "base_url", "https://other.invalid")
           )

    assert {:error, _} =
             SalixAgent.Templates.resolve_llm_for_template(template["template_id"], ctx.other)

    assert {:error, _} =
             SalixAgent.Templates.create(%{
               "name" => "Global",
               "model" => "gpt-5",
               "provider_config" => %{"account_pool" => "codex"}
             })
  end
end
