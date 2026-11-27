defmodule BridgeForTeamsWeb.Dashboard.Cft100SeatsContractTest do
  @moduledoc """
  Acceptance tests for the 100-seat Comma for Teams signup, payment, auth,
  settings billing policy, and explicit onboarding org contract (v4).
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: [
      "Elixir.BridgeForTeams",
      "Elixir.BridgeForTeamsWeb",
      "Elixir.BillingCore",
      "Elixir.BillingCommerce",
      "Elixir.BillingStripe"
    ]

  alias BillingCommerce.PaidCycles
  alias BillingCore.TeamsAccess
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.{Accounts, CftAnalytics, Memberships, Orgs, PaidSignup, TeamsPricing}
  alias BridgeForTeams.LoginLinks.Delivery.Fake, as: FakeDelivery
  alias BridgeForTeamsWeb.Dashboard.Auth, as: DashAuth

  defmodule MockPostmark do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def start_link(_),
      do: Agent.start_link(fn -> %{requests: [], listener: nil} end, name: __MODULE__)

    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def set_listener(pid), do: Agent.update(__MODULE__, &Map.put(&1, :listener, pid))
    def reset, do: Agent.update(__MODULE__, &Map.put(&1, :requests, []))
    def requests, do: __MODULE__ |> Agent.get(& &1.requests) |> Enum.reverse()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/email"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      decoded = Jason.decode!(raw)

      listener =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.listener, %{state | requests: [decoded | state.requests]}}
        end)

      if is_pid(listener), do: send(listener, {:postmark_sent, decoded})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ErrorCode" => 0, "MessageID" => "pm-cft100"}))
    end
  end

  defmodule StripeAPI do
    def create_customer(params, _opts) do
      id = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
      {:ok, %{"id" => "cus_cft100_" <> id, "email" => params.email}}
    end

    def create_checkout_session(params, _opts) do
      id = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
      Agent.update(__MODULE__.State, &Map.put(&1, :checkout, params))

      {:ok,
       %{
         "id" => "cs_cft100_" <> id,
         "status" => "open",
         "url" => "https://checkout.stripe.test/cft100",
         "expires_at" => params[:expires_at]
       }}
    end

    def retrieve_checkout_session(_, _, _) do
      {:ok,
       %{
         "id" => "cs_cft100",
         "status" => "open",
         "url" => "https://checkout.stripe.test/cft100",
         "expires_at" => Agent.get(__MODULE__.State, &get_in(&1, [:checkout, :expires_at]))
       }}
    end

    def retrieve_subscription(_, _, _), do: read(:subscription)
    def retrieve_invoice(_, _, _), do: read(:invoice)

    def retrieve_price(_, _, _),
      do: {:ok, Agent.get(__MODULE__.State, &Map.get(&1, :price, price()))}

    def retrieve_payment_intent(_, _, _), do: read(:payment)
    def retrieve_charge(_, _, _), do: read(:charge)
    def list_disputes(_, _), do: {:ok, %{"data" => [], "has_more" => false}}

    def construct_webhook_event(a, b, c, d, e),
      do: BillingStripe.StripityAPI.construct_webhook_event(a, b, c, d, e)

    defp read(key), do: Agent.get(__MODULE__.State, &Map.fetch!(&1, key)) |> then(&{:ok, &1})

    def price do
      %{
        "id" => "price_cft100",
        "product" => "prod_teams",
        "active" => true,
        "lookup_key" => TeamsPricing.lookup_key(),
        "currency" => "usd",
        "unit_amount" => 24_000,
        "billing_scheme" => "per_unit",
        "transform_quantity" => nil,
        "recurring" => %{"interval" => "month", "interval_count" => 3, "usage_type" => "licensed"}
      }
    end
  end

  defmodule CountingPaidSignup do
    def purchase_state(id) do
      send(self(), {:purchase_state_called, id})
      :pending
    end

    def check_m2square_signup_return(id, order) do
      send(self(), {:m2_return_called, id, order})
      :ok
    end
  end

  defmodule SettledInactivePaidSignup do
    def purchase_state(_id) do
      {:settled_inactive, Agent.get(StripeAPI.State, & &1.settled_inactive_org)}
    end
  end

  setup do
    settings = [
      {:billing_stripe, :stripe_api, StripeAPI},
      {:billing_stripe, :secret_key, "sk_local"},
      {:billing_stripe, :webhook_secret, "whsec_local"},
      {:bridge_for_teams_web, :public_base_url, "https://teams.example.test"}
    ]

    Enum.each(settings, fn {app, key, value} ->
      old = SystemsRuntime.get_env(app, key)
      SystemsRuntime.put_env(app, key, value)

      on_exit(fn ->
        if is_nil(old),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, old)
      end)
    end)

    start_supervised!(%{
      id: StripeAPI.State,
      start: {Agent, :start_link, [fn -> %{} end, [name: StripeAPI.State]]}
    })

    {:ok, _} = BillingCommerce.sync_local_pricing_catalog(TeamsPricing.catalog())

    {:ok, _} =
      BillingCommerce.put_provider_price(%{
        package_code: TeamsPricing.package(),
        package_version: TeamsPricing.version(),
        provider: "stripe",
        provider_lookup_key: TeamsPricing.lookup_key(),
        provider_price_id: "price_cft100",
        currency: "usd",
        amount_minor: 24_000
      })

    on_exit(fn ->
      FakeDelivery.set_listener(nil)
      SystemsRuntime.delete_env(:bridge_for_teams_web, :paid_signup_mod)
    end)

    :ok
  end

  describe "1. CftAnalytics entries & failure_kind" do
    test "accepts pricing, enterprise, personal, dashboard, and direct entries" do
      for entry <- ~w(pricing enterprise personal dashboard direct) do
        assert CftAnalytics.entry(entry) == entry
      end

      assert CftAnalytics.entry("unknown") == "direct"
      assert CftAnalytics.failure_kind(:teams_price_not_configured) == "provider_unavailable"
    end
  end

  describe "2. DashboardSettings.general/3 billing_policy" do
    test "returns billing: nil with unmanaged billing_policy for unmanaged orgs", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})
      {:ok, other} = Accounts.create_user(%{email: "second-member@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, other.id, "member")

      data =
        conn
        |> get("/dashboard/api/v1/orgs/#{org.slug}/settings/general")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["billing"] == nil
      assert data["billing_policy"] == %{"mode" => "unmanaged", "member_count" => 2}
    end

    test "returns managed billing_policy for managed orgs", %{conn: conn} do
      %{conn: conn, org: org} = register_and_log_in_user(%{conn: conn})

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = true WHERE id = $1",
        [org.billing_account_id]
      )

      data =
        conn
        |> get("/dashboard/api/v1/orgs/#{org.slug}/settings/general")
        |> json_response(200)
        |> Map.fetch!("data")

      assert is_map(data["billing"])
      assert data["billing_policy"] == %{"mode" => "managed"}
    end
  end

  describe "3. Onboarding explicit target org (F5)" do
    test "locks wizard to explicit org and returns 403 organization_unavailable on invalid org",
         %{
           conn: conn
         } do
      user = user_fixture(email: "multi-org@example.com")
      org_a = org_fixture(name: "Alpha Org", slug: "alpha-org")
      org_b = org_fixture(name: "Zeta Org", slug: "zeta-org")
      org_c = org_fixture(name: "Stranger Org", slug: "stranger-org")
      {:ok, _} = Memberships.put_org_member(org_a.id, user.id, "owner")
      {:ok, _} = Memberships.put_org_member(org_b.id, user.id, "owner")

      conn = log_in_user(conn, user, onboarded: false)

      # Redirect from /orgs/:org preserves ?org=
      assert conn |> get("/orgs/#{org_b.slug}") |> redirected_to() ==
               "/onboarding?org=#{org_b.slug}"

      # Explicit org locks show & complete
      show_data =
        conn
        |> get("/dashboard/api/v1/onboarding?org=#{org_b.slug}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert show_data["org"]["slug"] == org_b.slug

      # Non-member org returns 403 organization_unavailable without falling back to org_a
      err =
        conn
        |> get("/dashboard/api/v1/onboarding?org=#{org_c.slug}")
        |> json_response(403)

      assert err["error"]["code"] == "organization_unavailable"

      # Empty ?org= returns 403 organization_unavailable without falling back to org_a
      err_empty =
        conn
        |> get("/dashboard/api/v1/onboarding?org=")
        |> json_response(403)

      assert err_empty["error"]["code"] == "organization_unavailable"

      # Non-existent org returns 403 organization_unavailable on complete
      err_complete =
        conn
        |> post("/dashboard/api/v1/onboarding/complete", %{"org" => "does-not-exist"})
        |> json_response(403)

      assert err_complete["error"]["code"] == "organization_unavailable"

      # Completing with explicit org_b lands on /orgs/zeta-org
      done_data =
        conn
        |> post("/dashboard/api/v1/onboarding/complete", %{"org" => org_b.slug})
        |> json_response(200)
        |> Map.fetch!("data")

      assert done_data["redirect"] == "/orgs/#{org_b.slug}"
    end
  end

  describe "4. GET /signup/teams Chooser, member isolation, pagination, and logout return_to" do
    test "shows chooser for signed-in user with orgs, isolates member billing, and links /settings#teams-billing",
         %{conn: conn} do
      user = user_fixture(email: "chooser@example.com")
      owner_org = org_fixture(name: "Owner Co", slug: "owner-co")
      member_org = org_fixture(name: "Member Co", slug: "member-co")
      {:ok, _} = Memberships.put_org_member(owner_org.id, user.id, "owner")
      {:ok, _} = Memberships.put_org_member(member_org.id, user.id, "member")

      # Mark member_org as managed with active seats — member MUST NOT see billing info
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = true WHERE id = $1",
        [member_org.billing_account_id]
      )

      conn = log_in_user(conn, user)
      resp = get(conn, "/signup/teams?from=pricing")
      html = html_response(resp, 200)

      # Chooser does not allocate :teams_purchase_id
      assert get_session(resp, :teams_purchase_id) == nil
      assert html =~ "Your Teams organizations"
      assert html =~ "Signed in as chooser@example.com"
      assert html =~ "/orgs/owner-co/settings#teams-billing"
      refute html =~ "/orgs/owner-co/settings/general"
      refute html =~ "/orgs/member-co/settings#teams-billing"
      assert html =~ "Ask an organization owner or admin to manage seats."

      assert html =~ "/signup/teams?from=pricing&amp;mode=new" or
               html =~ "/signup/teams?mode=new&amp;from=pricing"

      assert html =~ ~s(name="return_to" value="/signup/teams")

      # Logout honors local return_to
      out = delete(recycle(resp), "/logout", %{"return_to" => "/signup/teams"})
      assert redirected_to(out) == "/signup/teams"
    end

    test "TeamsAccess.batch_admin_summary/2 reads multiple accounts in one query" do
      org1 = org_fixture(name: "Batch One", slug: "batch-one")
      org2 = org_fixture(name: "Batch Two", slug: "batch-two")

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = true WHERE id = $1",
        [org2.billing_account_id]
      )

      assert {:ok, %{}} = TeamsAccess.batch_admin_summary([])

      assert {:ok, summaries} =
               TeamsAccess.batch_admin_summary([org1.billing_account_id, org2.billing_account_id])

      assert summaries[org1.billing_account_id].managed == false
      assert summaries[org2.billing_account_id].managed == true
      assert summaries[org2.billing_account_id].active == false
    end
  end

  describe "5. F1 strict purchase ownership & local-only /signup/payment/status" do
    test "v4 ruling #1: legacy no-p link opened in session with new purchase B is unmatched with zero lookup and zero cleanup",
         %{conn: conn} do
      SystemsRuntime.put_env(:bridge_for_teams_web, :paid_signup_mod, CountingPaidSignup)

      conn = get(conn, "/signup/teams")
      purchase_b = get_session(conn, :teams_purchase_id)
      assert is_binary(purchase_b)
      assert get_session(conn, :teams_purchase_requires_p) == true

      # Open legacy no-p URL (from old order A)
      html_resp = get(recycle(conn), "/signup/payment?status=success")
      assert html_response(html_resp, 200) =~ "Checkout session not found"
      refute_received {:purchase_state_called, _}
      refute_received {:m2_return_called, _, _}
      # Session B is completely untouched
      assert get_session(html_resp, :teams_purchase_id) == purchase_b
      assert get_session(html_resp, :teams_purchase_requires_p) == true

      # Same for JSON status endpoint
      json_resp = get(recycle(conn), "/signup/payment/status")
      assert json_response(json_resp, 200) == %{"state" => "unmatched"}
      refute_received {:purchase_state_called, _}
      assert get_session(json_resp, :teams_purchase_id) == purchase_b
    end

    test "GET /signup/payment/status is strictly local read-only and never calls check_m2square_signup_return",
         %{conn: conn} do
      SystemsRuntime.put_env(:bridge_for_teams_web, :paid_signup_mod, CountingPaidSignup)

      conn = get(conn, "/signup/teams")
      purchase_id = get_session(conn, :teams_purchase_id)

      resp =
        conn
        |> recycle()
        |> get("/signup/payment/status?p=#{purchase_id}&m2_order=abcdefghijklmnopqrstuvwx")

      assert json_response(resp, 200) == %{"state" => "pending"}
      assert_received {:purchase_state_called, ^purchase_id}
      refute_received {:m2_return_called, _, _}
    end

    test "GET /signup/payment in :settled_inactive links signed-in owner to /orgs/<slug>/settings#teams-billing",
         %{conn: conn} do
      owner = user_fixture(email: "inactive-owner@example.com")
      member = user_fixture(email: "inactive-member@example.com")
      org = org_fixture(name: "Inactive Co", slug: "inactive-co")
      {:ok, _} = Memberships.put_org_member(org.id, owner.id, "owner")
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      Agent.update(StripeAPI.State, &Map.put(&1, :settled_inactive_org, org))
      SystemsRuntime.put_env(:bridge_for_teams_web, :paid_signup_mod, SettledInactivePaidSignup)

      owner_conn =
        conn
        |> log_in_user(owner)
        |> init_test_session(%{teams_purchase_id: org.id, teams_purchase_requires_p: true})
        |> get("/signup/payment?p=#{org.id}")

      owner_html = html_response(owner_conn, 200)
      assert owner_html =~ "Subscription inactive"
      assert owner_html =~ ~s(href="/orgs/inactive-co/settings#teams-billing")
      assert owner_html =~ "Manage billing &amp; seats"

      member_conn =
        build_conn()
        |> log_in_user(member)
        |> init_test_session(%{teams_purchase_id: org.id, teams_purchase_requires_p: true})
        |> get("/signup/payment?p=#{org.id}")

      member_html = html_response(member_conn, 200)
      assert member_html =~ ~s(href="/orgs/inactive-co")
      assert member_html =~ "Open"

      anon_conn =
        build_conn()
        |> init_test_session(%{teams_purchase_id: org.id, teams_purchase_requires_p: true})
        |> get("/signup/payment?p=#{org.id}")

      anon_html = html_response(anon_conn, 200)
      assert anon_html =~ ~s(href="/login?o=inactive-co")
      assert anon_html =~ "Sign in to organization"
    end
  end

  describe "6. F2 dual-tab email login isolation & slugless workspace recovery" do
    test "v4 ruling #2: two tabs requesting next=teams_signup and normal login redeem in both 1->2 and 2->1 orders without cross-contamination",
         %{conn: conn} do
      org = org_fixture(name: "Dual Tab Org", slug: "dual-tab-org")
      user = user_fixture(email: "dualtab@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")

      # Tab 1: return_to=/signup/teams -> email gets next=teams_signup
      _ =
        post(conn, "/auth/email/send", %{
          "org_slug" => org.slug,
          "email" => user.email,
          "return_to" => "/signup/teams"
        })

      # Tab 2: normal login -> email has no next=teams_signup
      _ =
        post(build_conn(), "/auth/email/send", %{
          "org_slug" => org.slug,
          "email" => user.email
        })

      [email1, email2] = FakeDelivery.deliveries()
      assert email1.url =~ "next=teams_signup"
      refute email2.url =~ "next=teams_signup"

      # Order 2 -> 1
      uri2 = URI.parse(email2.url)
      r2 = get(build_conn(), uri2.path <> "?" <> uri2.query)
      assert html_response(r2, 200) =~ ~s(data-next="/orgs/#{org.slug}")

      uri1 = URI.parse(email1.url)
      r1 = get(build_conn(), uri1.path <> "?" <> uri1.query)
      assert html_response(r1, 200) =~ ~s(data-next="/signup/teams")

      # Now request a second pair and redeem in order 1 -> 2
      _ =
        post(build_conn(), "/auth/email/send", %{
          "org_slug" => org.slug,
          "email" => user.email,
          "return_to" => "/signup/teams?mode=new"
        })

      _ =
        post(build_conn(), "/auth/email/send", %{
          "org_slug" => org.slug,
          "email" => user.email
        })

      [_, _, email3, email4] = FakeDelivery.deliveries()
      uri3 = URI.parse(email3.url)
      r3 = get(build_conn(), uri3.path <> "?" <> uri3.query)
      assert html_response(r3, 200) =~ ~s(data-next="/signup/teams")

      uri4 = URI.parse(email4.url)
      r4 = get(build_conn(), uri4.path <> "?" <> uri4.query)
      assert html_response(r4, 200) =~ ~s(data-next="/orgs/#{org.slug}")
    end

    test "slugless workspace recovery runs async, prioritizes SSO-less orgs, and never sends magic links for SSO orgs",
         %{conn: conn} do
      FakeDelivery.set_listener(self())
      user = user_fixture(email: "recover-ws@example.com")
      sso_org = org_fixture(name: "AAA SSO Org", slug: "aaa-sso-org")
      email_org = org_fixture(name: "ZZZ Email Org", slug: "zzz-email-org")

      {:ok, _} = Memberships.put_org_member(sso_org.id, user.id, "member")
      {:ok, _} = Memberships.put_org_member(email_org.id, user.id, "owner")

      {:ok, _} =
        Orgs.upsert_sso_connection(sso_org.id, %{
          "issuer" => "https://idp.test",
          "client_id" => "cid",
          "client_secret" => "csec",
          "default_role" => "member"
        })

      resp =
        post(conn, "/auth/email/send", %{
          "org_slug" => "",
          "email" => user.email,
          "return_to" => "/signup/teams"
        })

      assert redirected_to(resp) == "/auth/email?return_to=%2Fsignup%2Fteams"

      settle_receive(
        {:workspace_links_delivered, %{email: "recover-ws@example.com", entries: entries}}
      )

      # SSO-less org is ordered FIRST despite alphabetical name ZZZ > AAA
      assert [first, second] = entries
      assert first.org_slug == "zzz-email-org"
      assert first.kind == :magic_link
      assert first.url =~ "/auth/email/verify?"
      assert first.url =~ "next=teams_signup"

      assert second.org_slug == "aaa-sso-org"
      assert second.kind == :sso
      assert second.url =~ "/login?"
      assert second.url =~ "o=aaa-sso-org"
      assert second.url =~ "return_to=%2Fsignup%2Fteams"
      refute second.url =~ "bft_login_"
    end

    test "return_to=/cli/device-login/ABCD-1234 is never embedded in magic link emails", %{
      conn: conn
    } do
      org = org_fixture(name: "Device Phish Org", slug: "device-phish-org")
      user = user_fixture(email: "device-phish@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")

      _ =
        post(conn, "/auth/email/send", %{
          "org_slug" => org.slug,
          "email" => user.email,
          "return_to" => "/cli/device-login/ABCD-1234"
        })

      [email] = FakeDelivery.deliveries()
      refute email.url =~ "device-login"
      refute email.url =~ "next=teams_signup"
    end
  end

  describe "7. F6 bounded readable slug & F7 confirmation email ordering/legacy safety" do
    test "v4 ruling #3: readable slug collides cleanly; real Postmark egress sends 1 email per order and 0 for legacy",
         %{conn: conn} do
      start_supervised!(MockPostmark)
      MockPostmark.set_listener(self())

      port =
        Enum.find_value(1..10, fn _ ->
          p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

          case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit_pm, p}) do
            {:ok, _pid} -> p
            {:error, _} -> nil
          end
        end)

      assert is_integer(port)

      mail_env = [
        {:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}"},
        {:bridge_for_teams_core, :teams_postmark_server_token, "teams-test-token"},
        {:bridge_for_teams_core, :teams_from_email, "teams@example.test"},
        {:billing_stripe, :bridge_event_handler, BridgeForTeams.PaidSignup}
      ]

      saved_mail =
        Enum.map(mail_env, fn {app, key, val} ->
          old = SystemsRuntime.get_env(app, key)
          SystemsRuntime.put_env(app, key, val)
          {app, key, old}
        end)

      on_exit(fn ->
        drain_task_supervisor()

        Enum.each(Enum.reverse(saved_mail), fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, old} -> SystemsRuntime.put_env(app, key, old)
        end)
      end)

      # Pre-occupy "acme-corp" to verify bounded fallback to "acme-corp-<short8>"
      _existing = org_fixture(name: "Existing Acme", slug: "acme-corp")

      # Order A: customer.subscription.created BEFORE invoice.paid
      {id_a, _} = start_stripe_checkout(conn, "Acme Corp", "buyer-a@example.com")
      script_stripe_payment(id_a, "in_order_a", "sub_order_a")

      assert {:ok, res_a1} =
               deliver_webhook(
                 "evt_sub_first_a",
                 "customer.subscription.created",
                 id_a,
                 "sub_order_a",
                 "in_order_a"
               )

      assert res_a1.idempotent == false
      refute Map.has_key?(res_a1, :after_commit_dispatch)

      assert {:ok, org_a} = Orgs.get_org(id_a)
      short8 = id_a |> String.replace("-", "") |> String.slice(0, 8)
      assert org_a.slug == "acme-corp-" <> short8

      settle_receive({:postmark_sent, mail_a})
      assert mail_a["To"] == "buyer-a@example.com"
      assert mail_a["TextBody"] =~ org_a.slug
      assert mail_a["TextBody"] =~ "/login?"

      assert {:ok, res_a2} =
               deliver_webhook(
                 "evt_inv_second_a",
                 "invoice.paid",
                 id_a,
                 "sub_order_a",
                 "in_order_a"
               )

      assert res_a2.idempotent == false
      refute Map.has_key?(res_a2, :after_commit_dispatch)
      settle_refute_receive({:postmark_sent, _})

      refute PaidCycles.confirmation_email_pending?(
               BillingCore.Repo,
               org_a.billing_account_id,
               "in_order_a"
             )

      # Legacy pre-existing invoice: strip confirmation_emails key to simulate pre-release cycle
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        UPDATE billing_subscription_cycles
        SET source_metadata = source_metadata - 'confirmation_emails'
        WHERE billing_account_id = $1
        """,
        [org_a.billing_account_id]
      )

      refute PaidCycles.confirmation_email_pending?(
               BillingCore.Repo,
               org_a.billing_account_id,
               "in_order_a"
             )

      assert {:ok, res_legacy} =
               deliver_webhook(
                 "evt_legacy_upd",
                 "customer.subscription.updated",
                 id_a,
                 "sub_order_a",
                 "in_order_a"
               )

      assert res_legacy.idempotent == false
      refute Map.has_key?(res_legacy, :after_commit_dispatch)
      settle_refute_receive({:postmark_sent, _})

      # Legacy invoice must NEVER become eligible or pending on subsequent subscription.updated
      refute PaidCycles.confirmation_email_pending?(
               BillingCore.Repo,
               org_a.billing_account_id,
               "in_order_a"
             )

      # Order B: invoice.paid BEFORE customer.subscription.created (also tests reserved org name "Login")
      {id_b, _} = start_stripe_checkout(build_conn(), "Login", "buyer-b@example.com")
      script_stripe_payment(id_b, "in_order_b", "sub_order_b")

      assert {:ok, res_b1} =
               deliver_webhook(
                 "evt_inv_first_b",
                 "invoice.paid",
                 id_b,
                 "sub_order_b",
                 "in_order_b"
               )

      assert res_b1.idempotent == false
      refute Map.has_key?(res_b1, :after_commit_dispatch)

      assert {:ok, org_b} = Orgs.get_org(id_b)
      assert org_b.slug == "team-" <> id_b

      settle_receive({:postmark_sent, mail_b})
      assert mail_b["To"] == "buyer-b@example.com"
      assert mail_b["TextBody"] =~ org_b.slug
      assert mail_b["TextBody"] =~ "/login?"

      assert {:ok, res_b2} =
               deliver_webhook(
                 "evt_sub_second_b",
                 "customer.subscription.created",
                 id_b,
                 "sub_order_b",
                 "in_order_b"
               )

      assert res_b2.idempotent == false
      refute Map.has_key?(res_b2, :after_commit_dispatch)
      settle_refute_receive({:postmark_sent, _})

      refute PaidCycles.confirmation_email_pending?(
               BillingCore.Repo,
               org_b.billing_account_id,
               "in_order_b"
             )

      # Short org name (< 3 chars) "AI" falls back to "team-" <> id
      {id_short, _} = start_stripe_checkout(build_conn(), "AI", "buyer-short@example.com")
      script_stripe_payment(id_short, "in_short", "sub_short")

      assert {:ok, %{idempotent: false}} =
               deliver_webhook(
                 "evt_short_name",
                 "invoice.paid",
                 id_short,
                 "sub_short",
                 "in_short"
               )

      assert {:ok, org_short} = Orgs.get_org(id_short)
      assert org_short.slug == "team-" <> id_short
      settle_receive({:postmark_sent, _})

      assert Enum.count(MockPostmark.requests(), &(&1["To"] == "buyer-a@example.com")) == 1
      assert Enum.count(MockPostmark.requests(), &(&1["To"] == "buyer-b@example.com")) == 1
    end
  end

  describe "8. Round 2 regression coverage: pending checkout, zero-write status, purchase_state, 21+ orgs, 0-org flash" do
    test "POST /signup/teams :subscription_checkout_pending renders 200 recovery links with and without snapshot",
         %{conn: conn} do
      conn = get(conn, "/signup/teams")
      id = get_session(conn, :teams_purchase_id)

      token =
        conn
        |> html_response(200)
        |> Floki.parse_document!()
        |> Floki.attribute("input[name='signup[quote_token]']", "value")
        |> List.first()

      first =
        post(recycle(conn), "/signup/teams", %{
          "signup" => %{
            "org_name" => "Pending Co",
            "email" => "pending-owner@example.com",
            "name" => "Buyer",
            "seats" => "100",
            "quote_token" => token
          }
        })

      assert redirected_to(first) == "https://checkout.stripe.test/cft100"

      # Re-submit with 150 seats while checkout is pending -> 200 with Open original checkout + Check payment status
      second =
        post(recycle(first), "/signup/teams", %{
          "signup" => %{
            "org_name" => "Pending Co",
            "email" => "other-email@example.com",
            "name" => "Buyer",
            "seats" => "150",
            "quote_token" => token
          }
        })

      html = html_response(second, 200)
      assert html =~ "Open original checkout"
      assert html =~ "https://checkout.stripe.test/cft100"
      assert html =~ "/signup/payment?p=#{id}"
      assert get_session(second, :teams_purchase_id) == id
      assert get_session(second, :teams_signup_email) == "pending-owner@example.com"

      # Clear snapshot URL so pending_checkout_snapshot returns :none -> still 200 with Check payment status
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        UPDATE billing_accounts
        SET subscription_checkout = subscription_checkout #- '{session,url}'
        WHERE id = $1
        """,
        ["ba_teams_" <> id]
      )

      third =
        post(recycle(second), "/signup/teams", %{
          "signup" => %{
            "org_name" => "Pending Co",
            "email" => "other-email@example.com",
            "name" => "Buyer",
            "seats" => "150",
            "quote_token" => token
          }
        })

      html_no_snap = html_response(third, 200)
      refute html_no_snap =~ "Open original checkout"
      assert html_no_snap =~ "Check payment status"
      assert html_no_snap =~ "/signup/payment?p=#{id}"
    end

    test "GET /signup/payment/status performs zero session DB writes for active and expired sessions",
         %{conn: conn} do
      active_user = user_fixture(email: "active-poll@example.com")
      expired_user = user_fixture(email: "expired-poll@example.com")

      {:ok, %{token: active_token, session: active_session}} = Sessions.create(active_user, [])
      {:ok, %{token: expired_token, session: expired_session}} = Sessions.create(expired_user, [])

      # Backdate last_seen_at on active session and expire the other session
      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        "UPDATE auth_sessions SET last_seen_at = now() - interval '2 hours' WHERE id = $1",
        [Ecto.UUID.dump!(active_session.id)]
      )

      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        "UPDATE auth_sessions SET expires_at = now() - interval '1 hour' WHERE id = $1",
        [Ecto.UUID.dump!(expired_session.id)]
      )

      %{rows: [[before_last_seen]]} =
        Ecto.Adapters.SQL.query!(
          BridgeForTeams.Repo,
          "SELECT last_seen_at FROM auth_sessions WHERE id = $1",
          [Ecto.UUID.dump!(active_session.id)]
        )

      purchase_id = SystemsRuntime.Proc.uuid()
      other_id = SystemsRuntime.Proc.uuid()

      active_conn =
        conn
        |> init_test_session(%{
          teams_purchase_id: purchase_id,
          teams_purchase_requires_p: true
        })
        |> DashAuth.put_token_in_session(active_token)

      assert json_response(get(active_conn, "/signup/payment/status?p=#{purchase_id}"), 200) == %{
               "state" => "pending"
             }

      assert json_response(
               get(recycle(active_conn), "/signup/payment/status?p=#{other_id}"),
               200
             ) == %{"state" => "unmatched"}

      expired_conn =
        build_conn()
        |> init_test_session(%{
          teams_purchase_id: purchase_id,
          teams_purchase_requires_p: true
        })
        |> DashAuth.put_token_in_session(expired_token)

      assert json_response(get(expired_conn, "/signup/payment/status?p=#{purchase_id}"), 200) ==
               %{"state" => "pending"}

      assert json_response(
               get(recycle(expired_conn), "/signup/payment/status?p=#{other_id}"),
               200
             ) == %{"state" => "unmatched"}

      %{rows: [[after_last_seen]]} =
        Ecto.Adapters.SQL.query!(
          BridgeForTeams.Repo,
          "SELECT last_seen_at FROM auth_sessions WHERE id = $1",
          [Ecto.UUID.dump!(active_session.id)]
        )

      assert after_last_seen == before_last_seen

      %{rows: [[expired_count]]} =
        Ecto.Adapters.SQL.query!(
          BridgeForTeams.Repo,
          "SELECT count(*) FROM auth_sessions WHERE id = $1",
          [Ecto.UUID.dump!(expired_session.id)]
        )

      assert expired_count == 1
    end

    test "PaidSignup.purchase_state/1 covers half_committed, non-seat source, settled_inactive, unmanaged, and owner mismatch",
         %{conn: conn} do
      # 1. Half-committed: BFT org + managed ba_teams_<id>, no cycle
      half_org = org_fixture(name: "Half Co", slug: "half-co")
      half_id = half_org.id
      half_ba = "ba_teams_" <> half_id

      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        "UPDATE organizations SET billing_account_id = $1 WHERE id = $2",
        [half_ba, Ecto.UUID.dump!(half_id)]
      )

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET product_owner_id = 'detached-' || id WHERE id = $1",
        [half_org.billing_account_id]
      )

      :ok =
        BillingCore.Accounts.ensure_account(%{
          billing_account_id: half_ba,
          surface: "bridge",
          product_owner_type: "organization",
          product_owner_id: half_id
        })

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = true WHERE id = $1",
        [half_ba]
      )

      assert {:half_committed, %{id: ^half_id}} = PaidSignup.purchase_state(half_id)

      # GET /signup/teams redirects to /signup/payment?p=<id> without rotating purchase_id
      half_resp =
        conn
        |> init_test_session(%{teams_purchase_id: half_id, teams_purchase_requires_p: true})
        |> get("/signup/teams")

      assert redirected_to(half_resp) == "/signup/payment?p=#{half_id}"
      assert get_session(half_resp, :teams_purchase_id) == half_id

      # Non-seat payment_source (teams_seats: 0) must still be :half_committed
      sub_id = "sub_nonseat_" <> half_id
      cycle_id = "cycle_nonseat_" <> half_id
      now = SystemsClock.utc_now()

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        INSERT INTO billing_subscriptions (
          id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status, inserted_at, updated_at
        ) VALUES (
          $1, $2, 'bridge', 'organization', $3,
          $4, $5, 'stripe', $6, $7,
          $8, '{}'::jsonb, 'active', $9, $9
        )
        """,
        [
          sub_id,
          half_ba,
          half_id,
          TeamsPricing.package(),
          TeamsPricing.version(),
          sub_id,
          "evt_nonseat_" <> half_id,
          "idem_nonseat_" <> half_id,
          now
        ]
      )

      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        INSERT INTO billing_subscription_cycles (
          id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, source_metadata, status, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, $8, $9,
          $10, 'subscription_cycle', $11, 'granted', $7, $7
        )
        """,
        [
          cycle_id,
          sub_id,
          half_ba,
          TeamsPricing.package(),
          TeamsPricing.version(),
          "cycle_key_nonseat",
          DateTime.add(now, -3600, :second),
          DateTime.add(now, -60, :second),
          "grant_idem_" <> cycle_id,
          "evt_nonseat_" <> half_id,
          %{"payment_sources" => %{"in_zero" => %{"teams_seats" => 0}}}
        ]
      )

      assert {:half_committed, %{id: ^half_id}} = PaidSignup.purchase_state(half_id)

      # Cross-DB half-committed: BFT org exists with ba_teams_<id>, but billing_accounts row does not exist yet
      split_id = SystemsRuntime.Proc.uuid()

      BridgeForTeams.Repo.insert!(%BridgeForTeams.Schema.Organization{
        id: split_id,
        name: "Split Half Org",
        slug: "split-half-org",
        billing_account_id: "ba_teams_" <> split_id,
        salix_tenant_id: "ten_split_" <> String.slice(split_id, 0, 8)
      })

      assert {:half_committed, %{id: ^split_id}} = PaidSignup.purchase_state(split_id)

      # 2. Settled inactive: real Stripe payment recorded then revoked/expired -> :settled_inactive & GET /signup/teams rotates ID
      {settled_id, _} = start_stripe_checkout(build_conn(), "Refunded Co", "refund@example.com")
      script_stripe_payment(settled_id, "in_refunded", "sub_refunded")

      assert {:ok, _} =
               deliver_webhook(
                 "evt_refund_init",
                 "invoice.paid",
                 settled_id,
                 "sub_refunded",
                 "in_refunded"
               )

      assert {:settled_active, %{id: ^settled_id}} = PaidSignup.purchase_state(settled_id)

      # Revoke entitlement by expiring the cycle while preserving payment_sources.teams_seats = 100
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        UPDATE billing_subscription_cycles
        SET period_end = $1
        WHERE billing_account_id = $2
        """,
        [DateTime.add(now, -60, :second), "ba_teams_" <> settled_id]
      )

      assert {:settled_inactive, %{id: ^settled_id}} = PaidSignup.purchase_state(settled_id)

      rotated =
        build_conn()
        |> init_test_session(%{teams_purchase_id: settled_id, teams_purchase_requires_p: true})
        |> get("/signup/teams")

      assert html_response(rotated, 200) =~ "Create organization"
      new_id = get_session(rotated, :teams_purchase_id)
      assert is_binary(new_id) and new_id != settled_id

      # 3. Unmanaged account -> :unavailable (never :settled_active)
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = false WHERE id = $1",
        [half_ba]
      )

      assert PaidSignup.purchase_state(half_id) == :unavailable

      # 4. Product owner mismatch -> :unavailable
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "UPDATE billing_accounts SET teams_subscription_required = true, product_owner_id = $1 WHERE id = $2",
        [SystemsRuntime.Proc.uuid(), half_ba]
      )

      assert PaidSignup.purchase_state(half_id) == :unavailable
    end

    test "21 orgs paginate on GET /signup/teams?page=2 and prioritize the 21st org in remember_orgs",
         %{conn: conn} do
      user = user_fixture(email: "many-orgs@example.com")

      for idx <- 1..20 do
        pad = String.pad_leading(Integer.to_string(idx), 2, "0")
        org = org_fixture(name: "Org #{pad}", slug: "org-#{pad}")
        {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")
      end

      org21 = org_fixture(name: "Zzz 21 Org", slug: "zzz-21-org")
      {:ok, _} = Memberships.put_org_member(org21.id, user.id, "owner")

      # Page 2 of chooser shows the 21st org
      page2 =
        conn
        |> log_in_user(user)
        |> get("/signup/teams?page=2")
        |> html_response(200)

      assert page2 =~ "Zzz 21 Org"
      assert page2 =~ "zzz-21-org"

      # Send & redeem magic link for zzz-21-org -> data-login-orgs puts zzz-21-org at index 0 with length 5
      _ =
        post(build_conn(), "/auth/email/send", %{
          "org_slug" => org21.slug,
          "email" => user.email
        })

      [mail] = FakeDelivery.deliveries()
      uri = URI.parse(mail.url)
      verify_html = get(build_conn(), uri.path <> "?" <> uri.query) |> html_response(200)

      [orgs_json] =
        verify_html
        |> Floki.parse_document!()
        |> Floki.attribute("[data-login-orgs]", "data-login-orgs")

      decoded = Jason.decode!(orgs_json)
      assert length(decoded) == 5
      assert hd(decoded)["slug"] == "zzz-21-org"
    end

    test "signed-in 0-org user buying for another account sees info flash banner after redirect to /signup/teams",
         %{conn: conn} do
      zero_user = user_fixture(email: "zero-orgs@example.com")

      {purchase_id, _} =
        start_stripe_checkout(build_conn(), "Other Owner Co", "other-owner@example.com")

      script_stripe_payment(purchase_id, "in_other_owner", "sub_other_owner")

      assert {:ok, _} =
               deliver_webhook(
                 "evt_other_owner",
                 "invoice.paid",
                 purchase_id,
                 "sub_other_owner",
                 "in_other_owner"
               )

      payment_resp =
        conn
        |> log_in_user(zero_user)
        |> init_test_session(%{teams_purchase_id: purchase_id, teams_purchase_requires_p: true})
        |> get("/signup/payment?p=#{purchase_id}")

      assert redirected_to(payment_resp) == "/signup/teams"

      signup_html =
        payment_resp
        |> recycle()
        |> get("/signup/teams")
        |> html_response(200)

      assert signup_html =~ "was created for another account"
    end
  end

  defp start_stripe_checkout(conn, org_name, email) do
    conn = get(conn, "/signup/teams")
    id = get_session(conn, :teams_purchase_id)

    token =
      conn
      |> html_response(200)
      |> Floki.parse_document!()
      |> Floki.attribute("input[name='signup[quote_token]']", "value")
      |> List.first()

    resp =
      post(recycle(conn), "/signup/teams", %{
        "signup" => %{
          "org_name" => org_name,
          "email" => email,
          "name" => "Buyer",
          "seats" => "100",
          "quote_token" => token
        }
      })

    assert redirected_to(resp) == "https://checkout.stripe.test/cft100"
    {id, resp}
  end

  defp script_stripe_payment(_purchase_id, invoice_id, sub_id) do
    checkout = Agent.get(StripeAPI.State, & &1.checkout)
    now = SystemsClock.system_time(:second)
    period_end = now + 90 * 86_400

    subscription = %{
      "id" => sub_id,
      "customer" => checkout.customer,
      "status" => "active",
      "cancel_at_period_end" => false,
      "latest_invoice" => invoice_id,
      "metadata" => checkout.metadata
    }

    invoice = %{
      "id" => invoice_id,
      "object" => "invoice",
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{
          "subscription" => sub_id,
          "metadata" => checkout.metadata
        }
      },
      "customer" => checkout.customer,
      "subscription" => sub_id,
      "status" => "paid",
      "paid_out_of_band" => false,
      "currency" => "usd",
      "amount_paid" => 2_400_000,
      "payments" => %{
        "has_more" => false,
        "data" => [
          %{
            "status" => "paid",
            "payment" => %{"type" => "payment_intent", "payment_intent" => "pi_" <> invoice_id}
          }
        ]
      },
      "status_transitions" => %{"paid_at" => now},
      "lines" => %{
        "has_more" => false,
        "data" => [
          %{
            "amount" => 2_400_000,
            "quantity" => 100,
            "pricing" => %{
              "type" => "price_details",
              "price_details" => %{"price" => "price_cft100"}
            },
            "period" => %{"start" => now, "end" => period_end}
          }
        ]
      }
    }

    payment = %{
      "id" => "pi_" <> invoice_id,
      "status" => "succeeded",
      "amount_received" => 2_400_000,
      "latest_charge" => %{
        "id" => "ch_" <> invoice_id,
        "paid" => true,
        "created" => now,
        "amount_refunded" => 0,
        "refunded" => false
      }
    }

    charge = %{
      "id" => "ch_" <> invoice_id,
      "customer" => checkout.customer,
      "payment_intent" => "pi_" <> invoice_id,
      "paid" => true,
      "refunded" => false,
      "amount" => 2_400_000,
      "amount_refunded" => 0
    }

    Agent.update(StripeAPI.State, fn state ->
      Map.merge(state, %{
        subscription: subscription,
        invoice: invoice,
        payment: payment,
        charge: charge
      })
    end)
  end

  defp deliver_webhook(event_id, type, _purchase_id, sub_id, invoice_id) do
    checkout = Agent.get(StripeAPI.State, & &1.checkout)

    object =
      case type do
        "invoice." <> _ ->
          %{
            "id" => invoice_id,
            "object" => "invoice",
            "subscription" => sub_id,
            "metadata" => checkout.metadata,
            "parent" => %{
              "subscription_details" => %{
                "subscription" => sub_id,
                "metadata" => checkout.metadata
              }
            }
          }

        _ ->
          %{
            "id" => sub_id,
            "object" => "subscription",
            "latest_invoice" => invoice_id,
            "metadata" => checkout.metadata
          }
      end

    body =
      Jason.encode!(%{
        "id" => event_id,
        "type" => type,
        "created" => SystemsClock.system_time(:second),
        "data" => %{"object" => object}
      })

    timestamp = SystemsClock.system_time(:second)

    sig =
      :crypto.mac(:hmac, :sha256, "whsec_local", "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    BillingStripe.handle_webhook(body, "t=#{timestamp},v1=#{sig}", secret: "whsec_local")
  end

  defp drain_task_supervisor do
    case Task.Supervisor.children(BridgeForTeams.TaskSupervisor) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          end
        end)

        drain_task_supervisor()
    end
  end
end
