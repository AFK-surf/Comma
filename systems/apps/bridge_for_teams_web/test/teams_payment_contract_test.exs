defmodule BridgeForTeamsWeb.TeamsPaymentContractTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: [
      "Elixir.BridgeForTeams",
      "Elixir.BillingCore",
      "Elixir.BillingCommerce",
      "Elixir.BillingStripe"
    ]

  alias BridgeForTeams.{Accounts, Memberships, Orgs, PaidSignup, TeamsPricing}
  alias BillingCore.TeamsAccess
  alias BridgeForTeamsWeb.CftAnalyticsCollector

  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15"

  defmodule API do
    def create_customer(params, _opts), do: {:ok, %{"id" => "cus_teams", "email" => params.email}}

    def create_checkout_session(params, _opts) do
      Agent.update(__MODULE__.State, &Map.put(&1, :checkout, params))

      {:ok,
       %{
         "id" => "cs_teams",
         "status" => "open",
         "url" => "https://checkout.stripe.test/teams",
         "expires_at" => params[:expires_at]
       }}
    end

    # Stripe returns an open session's URL and expiry on every read.
    def retrieve_checkout_session(_, _, _),
      do:
        {:ok,
         %{
           "id" => "cs_teams",
           "status" => "open",
           "url" => "https://checkout.stripe.test/teams",
           "expires_at" => Agent.get(__MODULE__.State, &get_in(&1, [:checkout, :expires_at]))
         }}

    def retrieve_subscription(_, _, _), do: read(:subscription)
    def retrieve_invoice(_, _, _), do: read(:invoice)

    def retrieve_price(_, _, _),
      do: {:ok, Agent.get(__MODULE__.State, &Map.get(&1, :price, price()))}

    def retrieve_payment_intent(_, _, _), do: read(:payment)
    def retrieve_charge(_, _, _), do: read(:charge)

    def create_customer_portal(params, _opts) do
      Agent.update(
        __MODULE__.State,
        &Map.update(&1, :portals, [params], fn calls -> [params | calls] end)
      )

      {:ok, %{"id" => "bps_teams", "url" => "https://billing.stripe.test/teams"}}
    end

    def list_disputes(_, _), do: {:ok, %{"data" => [], "has_more" => false}}

    def construct_webhook_event(a, b, c, d, e),
      do: BillingStripe.StripityAPI.construct_webhook_event(a, b, c, d, e)

    defp read(key), do: Agent.get(__MODULE__.State, &Map.fetch!(&1, key)) |> then(&{:ok, &1})

    def price,
      do: %{
        "id" => "price_teams",
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

  setup do
    settings = [
      {:billing_stripe, :stripe_api, API},
      {:billing_stripe, :secret_key, "sk_local"},
      {:billing_stripe, :webhook_secret, "whsec_local"},
      {:billing_stripe, :portal_configuration_id, "bpc_teams_local"},
      {:salix_im, :teams_access_mod, BillingCore.TeamsAccess}
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
      id: API.State,
      start: {Agent, :start_link, [fn -> %{} end, [name: API.State]]}
    })

    {:ok, _} = BillingCommerce.sync_local_pricing_catalog(TeamsPricing.catalog())

    {:ok, _} =
      BillingCommerce.put_provider_price(%{
        package_code: TeamsPricing.package(),
        package_version: TeamsPricing.version(),
        provider: "stripe",
        provider_lookup_key: TeamsPricing.lookup_key(),
        provider_price_id: "price_teams",
        currency: "usd",
        amount_minor: 24_000
      })

    :ok
  end

  test "hosted checkout provisions once after signed cash confirmation, without signing in", %{
    conn: conn
  } do
    {conn, id} = checkout(conn)
    assert {:error, :not_found} = Orgs.get_org(id)
    assert get(recycle(conn), "/signup/payment?status=success").status == 200
    script_payment()
    # Hiding a sale does not revoke an already paid Checkout's immutable terms.
    Agent.update(
      API.State,
      &Map.put(&1, :price, API.price() |> Map.put("active", false) |> Map.put("lookup_key", nil))
    )

    assert {:error, _} = BillingStripe.handle_webhook(payload("evt_forged"), "t=1,v1=bad")
    assert {:error, :not_found} = Orgs.get_org(id)
    assert {:ok, %{idempotent: false}} = webhook("evt_paid")
    assert {:ok, %{idempotent: true}} = webhook("evt_paid")
    assert {:ok, _} = webhook("evt_paid_redelivery")
    assert {:ok, org} = Orgs.get_org(id)
    assert {:ok, user} = Accounts.get_user_by_email("buyer@example.com")
    assert {:ok, "owner"} = Memberships.org_role(org.id, user.id)
    assert {:ok, 100} = TeamsAccess.check(org.billing_account_id)
    assert Memberships.count_org_members(org.id) == 1
    result = get(recycle(conn), "/signup/payment?status=success&p=" <> id)
    assert redirected_to(result) == "/auth/email?" <> URI.encode_query(%{"o" => org.slug})
    assert get_session(result, :comma_session) == nil

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT count(*) FROM credit_grants WHERE billing_account_id = $1 AND remaining_credits > 0",
               [org.billing_account_id]
             )
  end

  test "minimum quantity is enforced before Stripe and unpaid sessions cannot provision", %{
    conn: conn
  } do
    conn = get(conn, "/signup/teams")
    id = get_session(conn, :teams_purchase_id)

    assert {:error, :invalid_teams_signup} =
             PaidSignup.start(id, attrs(99), "http://localhost:4101")

    refute Agent.get(API.State, &Map.has_key?(&1, :checkout))
    conn = submit_signup(conn, 100)
    assert redirected_to(conn) == "https://checkout.stripe.test/teams"
    script_payment()
    Agent.update(API.State, &put_in(&1, [:invoice, "status"], "open"))
    assert {:ok, _} = webhook("evt_unpaid")
    assert {:error, :not_found} = Orgs.get_org(id)
    assert {:error, :teams_subscription_required} = TeamsAccess.check("ba_teams_" <> id)
  end

  test "all org roles consume seats and a role edit does not consume another seat", %{conn: conn} do
    {_conn, id} = checkout(conn)
    script_payment()
    assert {:ok, _} = webhook("evt_seats")
    assert {:ok, org} = Orgs.get_org(id)

    for n <- 1..99 do
      {:ok, user} = Accounts.create_user(%{email: "member#{n}@example.com"})
      assert {:ok, _} = Memberships.put_org_member(id, user.id, "member")
    end

    {:ok, extra} = Accounts.create_user(%{email: "extra@example.com"})
    assert {:error, :teams_seat_limit} = Memberships.put_org_member(id, extra.id, "admin")
    {:ok, owner} = Accounts.get_user_by_email("buyer@example.com")
    assert {:ok, _} = Memberships.put_org_member(id, owner.id, "owner")
    assert Memberships.count_org_members(org.id) == 100
  end

  test "paid term survives cancellation, expires, and a confirmed renewal restores access", %{
    conn: conn
  } do
    {_conn, id} = checkout(conn)
    script_payment()
    assert {:ok, _} = webhook("evt_term")
    {:ok, org} = Orgs.get_org(id)
    group_id = SalixStore.Ids.new_group_id(org.salix_tenant_id)

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "billing_owner" => %{
        "surface" => "bridge",
        "billing_account_id" => org.billing_account_id
      }
    })

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "user_chat",
               "title" => "Licensed work",
               "participants" => [
                 %{"actor_type" => "user", "user_id" => "current", "state" => "active"}
               ]
             })

    input = %{
      "actor_type" => "user",
      "user_id" => "current",
      "kind" => "message",
      "client_request_id" => "before-expiry",
      "content" => "Do this work"
    }

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               input
             )

    Agent.update(API.State, &put_in(&1, [:subscription, "status"], "canceled"))
    assert {:ok, _} = webhook("evt_cancel")
    assert {:ok, 100} = TeamsAccess.check(org.billing_account_id)

    ends =
      Agent.get(
        API.State,
        &get_in(&1, [:invoice, "lines", "data", Access.at(0), "period", "end"])
      )

    SystemsClock.advance(max(ends * 1_000 - SystemsClock.system_time(:millisecond), 0))
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)
    project = %BridgeForTeams.Schema.Project{org_id: id, salix_group_id: group_id}
    router = %BridgeForTeams.Schema.Agent{role: "router", salix_agent_id: "unused"}

    assert {:error, :teams_subscription_required} =
             BridgeForTeams.Conversations.create_project_task_conversation(
               project,
               router,
               %{"content" => "New Task"},
               actor_user_id: elem(Accounts.get_user_by_email("buyer@example.com"), 1).id
             )

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               input
             )

    later = Map.put(input, "client_request_id", "after-expiry")

    assert {:error, :teams_subscription_required} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               later
             )

    assert {:ok, %{"url" => "https://checkout.stripe.test/teams"}} =
             PaidSignup.renew(org, "100", "http://localhost:4101")

    script_payment("in_renewal", "sub_teams_renewed")
    assert {:ok, _} = webhook("evt_renewal")
    assert {:ok, 100} = TeamsAccess.check(org.billing_account_id)

    assert {:ok, _} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               later
             )
  end

  test "a committed organization stays pending until Billing allocation and recovers on redelivery",
       %{conn: conn} do
    {_conn, id} = checkout(conn)

    {:ok, org} =
      Orgs.create_org(
        %{name: "Buyer Team", slug: "team-" <> id, billing_account_id: "ba_teams_" <> id},
        id: id
      )

    {:ok, user} = Accounts.create_user(%{email: "buyer@example.com"})

    {:ok, _} =
      %BridgeForTeams.Schema.OrgMembership{}
      |> Ecto.Changeset.change(%{org_id: org.id, user_id: user.id, role: "owner"})
      |> BridgeForTeams.Repo.insert()

    assert {:error, :teams_signup_pending} = PaidSignup.result(id)
    script_payment()
    assert {:ok, _} = webhook("evt_split_db_recovery")
    assert {:ok, %{slug: slug}} = PaidSignup.result(id)
    assert slug == org.slug
    assert Memberships.count_org_members(id) == 1
  end

  test "billing management requires an organization admin", %{conn: conn} do
    {_conn, id} = checkout(conn)
    script_payment()
    assert {:ok, _} = webhook("evt_portal")
    {:ok, org} = Orgs.get_org(id)
    {:ok, owner} = Accounts.get_user_by_email("buyer@example.com")
    owner_conn = log_in_user(build_conn(), owner)
    status = get(owner_conn, "/dashboard/api/v1/orgs/#{org.slug}/settings/general")
    assert json_response(status, 200)["data"]["billing"]["licensed_seats"] == 100

    response =
      post(
        log_in_user(build_conn(), owner),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/portal",
        %{}
      )

    assert json_response(response, 200)["data"]["url"] == "https://billing.stripe.test/teams"
    {:ok, member} = Accounts.create_user(%{email: "billing-member@example.com"})
    {:ok, _} = Memberships.put_org_member(id, member.id, "member")

    denied =
      post(
        log_in_user(build_conn(), member),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/portal",
        %{}
      )

    assert denied.status in [403, 404]
    assert length(Agent.get(API.State, & &1.portals)) == 1
  end

  test "a full refund revokes seat rights and an old invoice replay cannot restore them", %{
    conn: conn
  } do
    {_conn, id} = checkout(conn)
    script_payment()
    assert {:ok, _} = webhook("evt_refund_paid")
    {:ok, org} = Orgs.get_org(id)

    charge = %{
      "id" => "ch_teams",
      "customer" => "cus_teams",
      "payment_intent" => "pi_in_teams",
      "amount" => 2_400_000,
      "amount_refunded" => 2_400_000,
      "refunded" => true,
      "paid" => true,
      "created" => DateTime.to_unix(SystemsClock.utc_now())
    }

    Agent.update(API.State, &Map.put(&1, :charge, charge))

    event = %{
      "id" => "evt_teams_full_refund",
      "type" => "charge.refunded",
      "data" => %{"object" => charge}
    }

    assert {:ok, _} = webhook("unused", event)
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)
    Agent.update(API.State, &put_in(&1, [:payment, "latest_charge"], charge))
    assert {:ok, _} = webhook("evt_old_paid_after_refund")
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)
  end

  test "Stripe signup cannot create checkout when its one-hour window has expired", %{conn: conn} do
    conn = get(conn, "/signup/teams")
    SystemsClock.advance(3_600_000)

    page = conn |> submit_signup(100) |> html_response(200) |> Floki.parse_document!()
    assert Floki.find(page, "#signup-quote-expired:not([hidden]) a[href='/signup/teams']") != []
    refute Agent.get(API.State, &Map.has_key?(&1, :checkout))
  end

  test "a paid signup reports each funnel step to product analytics, once per fact", %{
    conn: conn
  } do
    queue = CftAnalyticsCollector.start()

    conn =
      conn
      |> put_req_header("cf-ipcountry", "de")
      |> put_req_header("user-agent", @browser)
      |> get("/signup/teams?from=pricing")

    id = get_session(conn, :teams_purchase_id)
    form = conn
    # "Back to checkout" opens the same purchase again, without the website's entry.
    assert conn |> recycle() |> put_req_header("user-agent", @browser) |> get("/signup/teams")
    assert html_response(submit_signup(form, 99), 200)
    assert redirected_to(submit_signup(form, 100)) == "https://checkout.stripe.test/teams"
    # Submitting again reuses the open Stripe session: the same created checkout.
    assert redirected_to(submit_signup(form, 100)) == "https://checkout.stripe.test/teams"
    assert get(recycle(conn), "/signup/payment?status=cancel&p=" <> id).status == 200

    script_payment()
    assert {:ok, %{idempotent: false}} = webhook("evt_paid")
    assert {:ok, _} = webhook("evt_paid_redelivery")
    assert {:ok, _org} = Orgs.get_org(id)

    events = CftAnalyticsCollector.events(queue)

    assert [
             %{"event" => "cft_signup_opened"} = opened,
             %{"event" => "cft_checkout_failed"} = failed,
             %{"event" => "cft_checkout_created"} = created,
             %{"event" => "cft_checkout_created"} = reused,
             %{"event" => "cft_payment_returned"} = returned,
             %{"event" => "cft_checkout_completed"} = completed
           ] = events

    # One purchase is one funnel subject, before and after the Organization exists.
    assert Enum.all?(events, &(&1["distinct_id"] == id))

    assert %{"entry" => "pricing", "country" => "DE", "locale" => "en"} = opened["properties"]

    assert %{"failure_kind" => "seats_invalid", "provider" => "stripe", "seats" => 99} =
             failed["properties"]

    assert %{"provider" => "stripe", "seats" => 100, "is_internal" => false} =
             created["properties"]

    # PostHog deduplicates by uuid within one event day: a retry repeats both.
    assert Map.take(reused, ["uuid", "timestamp"]) == Map.take(created, ["uuid", "timestamp"])
    assert %{"state" => "cancel", "provider" => "stripe"} = returned["properties"]

    paid_at = Agent.get(API.State, &get_in(&1, [:invoice, "status_transitions", "paid_at"]))
    assert completed["timestamp"] == DateTime.to_iso8601(DateTime.from_unix!(paid_at))
    assert %{"provider" => "stripe", "seats" => 100} = completed["properties"]

    encoded = Jason.encode!(events)
    refute encoded =~ "buyer@example.com"
    refute encoded =~ "Buyer Team"
    refute encoded =~ "cus_teams"
    refute encoded =~ "cs_teams"
  end

  test "a broken analytics setting never changes the payment it observes", %{conn: conn} do
    queue = CftAnalyticsCollector.start()
    # One domain instead of a list, as `comma.analytics.internal_email_domains` allows.
    config = SystemsRuntime.get_env(:bridge_for_teams_core, :cft_analytics)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :cft_analytics,
      Keyword.put(config, :internal_email_domains, " Example.com ")
    )

    {_conn, id} = checkout(conn)
    script_payment()
    assert {:ok, %{idempotent: false}} = webhook("evt_paid")
    assert {:ok, _org} = Orgs.get_org(id)

    assert [%{"event" => "cft_checkout_completed", "properties" => %{"is_internal" => true}}] =
             queue |> CftAnalyticsCollector.events() |> Enum.filter(&(&1["event"] =~ "completed"))
  end

  test "a signup sent with DNT reports no funnel step, its payment included", %{conn: conn} do
    queue = CftAnalyticsCollector.start()
    conn = conn |> put_req_header("dnt", "1") |> get("/signup/teams")
    id = get_session(conn, :teams_purchase_id)

    [token] =
      conn
      |> html_response(200)
      |> Floki.parse_document!()
      |> Floki.attribute("input[name='signup[quote_token]']", "value")

    conn =
      conn
      |> recycle()
      |> put_req_header("dnt", "1")
      |> post("/signup/teams", %{"signup" => Map.put(attrs(100), "quote_token", token)})

    assert redirected_to(conn) == "https://checkout.stripe.test/teams"
    script_payment()
    assert {:ok, %{idempotent: false}} = webhook("evt_paid")
    assert {:ok, _org} = Orgs.get_org(id)

    CftAnalyticsCollector.refute_events(queue)
  end

  defp submit_signup(conn, seats) do
    [token] =
      conn
      |> html_response(200)
      |> Floki.parse_document!()
      |> Floki.attribute("input[name='signup[quote_token]']", "value")

    post(recycle(conn), "/signup/teams", %{
      "signup" => Map.put(attrs(seats), "quote_token", token)
    })
  end

  defp checkout(conn) do
    conn = get(conn, "/signup/teams")
    id = get_session(conn, :teams_purchase_id)
    conn = submit_signup(conn, 100)
    assert redirected_to(conn) == "https://checkout.stripe.test/teams"
    params = Agent.get(API.State, & &1.checkout)
    assert params.line_items == [%{price: "price_teams", quantity: 100}]
    assert params.subscription_data.metadata["surface"] == "bridge"
    {conn, id}
  end

  defp attrs(seats),
    do: %{
      "email" => "buyer@example.com",
      "name" => "Buyer",
      "org_name" => "Buyer Team",
      "seats" => seats
    }

  defp script_payment(invoice_id \\ "in_teams", subscription_id \\ "sub_teams") do
    checkout = Agent.get(API.State, & &1.checkout)
    starts = DateTime.to_unix(SystemsClock.utc_now())
    ends = DateTime.to_unix(DateTime.shift(DateTime.from_unix!(starts), month: 3))

    sub = %{
      "id" => subscription_id,
      "status" => "active",
      "customer" => "cus_teams",
      "metadata" => checkout.subscription_data.metadata,
      "latest_invoice" => invoice_id
    }

    invoice = %{
      "id" => invoice_id,
      "object" => "invoice",
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{
          "subscription" => subscription_id,
          "metadata" => sub["metadata"]
        }
      },
      "customer" => "cus_teams",
      "status" => "paid",
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
      "status_transitions" => %{"paid_at" => starts},
      "metadata" => %{},
      "lines" => %{
        "has_more" => false,
        "data" => [
          %{
            "amount" => 2_400_000,
            "quantity" => 100,
            "pricing" => %{
              "type" => "price_details",
              "price_details" => %{"price" => "price_teams"}
            },
            "period" => %{"start" => starts, "end" => ends}
          }
        ]
      }
    }

    payment = %{
      "id" => "pi_" <> invoice_id,
      "status" => "succeeded",
      "amount_received" => 2_400_000,
      "latest_charge" => %{
        "id" => "ch_teams",
        "paid" => true,
        "created" => starts,
        "amount_refunded" => 0,
        "refunded" => false
      }
    }

    Agent.update(
      API.State,
      &Map.merge(&1, %{subscription: sub, invoice: invoice, payment: payment})
    )
  end

  defp payload(id) do
    invoice = Agent.get(API.State, & &1.invoice)

    Jason.encode!(%{
      "id" => id,
      "object" => "event",
      "type" => "invoice.paid",
      "created" => DateTime.to_unix(SystemsClock.utc_now()),
      "data" => %{"object" => invoice}
    })
  end

  defp webhook(id, event \\ nil) do
    payload = if event, do: Jason.encode!(event), else: payload(id)
    timestamp = DateTime.to_unix(SystemsClock.utc_now())

    signature =
      :crypto.mac(:hmac, :sha256, "whsec_local", "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    BillingStripe.handle_webhook(payload, "t=#{timestamp},v1=#{signature}", tolerance: 31_536_000)
  end
end
