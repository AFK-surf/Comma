defmodule BridgeForTeamsWeb.M2squareTeamsPaymentContractTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: [
      "Elixir.BridgeForTeams",
      "Elixir.BridgeForTeamsWeb",
      "Elixir.BillingCore",
      "Elixir.BillingCommerce",
      "Elixir.BillingStripe"
    ]

  alias BillingCore.TeamsAccess
  alias BridgeForTeams.{Accounts, Memberships, Orgs, PaidSignup, TeamsPricing}
  alias BridgeForTeams.M2square.{FX, Ops, Orders, QuoteToken}
  alias Salix.Control.M2squareSettings
  alias SalixStore.{Keys, S3}

  @secret_key "m2_test_secret_key_contract"
  @mch_id "mch_contract_01"

  defmodule FakeFX do
    @behaviour BridgeForTeams.M2square.FX.Provider

    @impl true
    def fetch_usd_base_rates(_currencies, _opts) do
      {:ok,
       %{
         "BRL" =>
           Decimal.new(SystemsRuntime.get_env(:bridge_for_teams_core, :contract_brl_rate, "0.20")),
         "PEN" => Decimal.new("0.27"),
         "CLP" => Decimal.new("0.00105")
       }}
    end
  end

  defmodule FakeM2Client do
    @behaviour BridgeForTeams.M2square.Client

    @impl true
    def pay(payload, _config) do
      {order_id, pay_override} =
        Agent.get_and_update(__MODULE__.State, fn state ->
          seq = state.pay_seq + 1
          order_id = "M2ORD#{seq}"
          calls = state.pay_calls ++ [payload]
          {{order_id, state.pay_override}, %{state | pay_seq: seq, pay_calls: calls}}
        end)

      case pay_override do
        fun when is_function(fun, 2) ->
          fun.(payload, order_id)

        nil ->
          {:ok,
           %{
             order_id: order_id,
             checkout_url: "https://pay.m2square.test/checkout/#{order_id}",
             currency: payload["currency"],
             raw_item: %{"orderId" => order_id}
           }}
      end
    end

    @impl true
    def verify_status(provider_order_id, _config) do
      Agent.get_and_update(__MODULE__.State, fn state ->
        calls = state.verify_calls ++ [provider_order_id]

        {result, next_queue} =
          case Map.get(state.verify_queues, provider_order_id, []) do
            [head | tail] ->
              {head, Map.put(state.verify_queues, provider_order_id, tail)}

            [] ->
              {Map.get(state.verify_default, provider_order_id, {:ok, []}), state.verify_queues}
          end

        {result, %{state | verify_calls: calls, verify_queues: next_queue}}
      end)
    end
  end

  defmodule FakeStripeAPI do
    def create_customer(params, _opts) do
      Agent.update(__MODULE__.State, fn s ->
        Map.update(s, :customers_created, [params], &[params | &1])
      end)

      {:ok, %{"id" => "cus_m2_to_stripe", "email" => params[:email]}}
    end

    def create_checkout_session(params, _opts) do
      Agent.update(__MODULE__.State, &Map.put(&1, :checkout, params))

      {:ok,
       %{"id" => "cs_stripe_1", "status" => "open", "url" => "https://checkout.stripe.test/teams"}}
    end

    def retrieve_checkout_session(_, _, _),
      do: {:ok, %{"id" => "cs_stripe_1", "status" => "open"}}

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

  defmodule MockPostmark do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(raw)

      should_fail? =
        Agent.get_and_update(
          BridgeForTeamsWeb.M2squareTeamsPaymentContractTest.MailState,
          fn state ->
            if state.fail_next > 0 do
              {true, %{state | fail_next: state.fail_next - 1}}
            else
              {false, %{state | emails: state.emails ++ [decoded]}}
            end
          end
        )

      if should_fail? do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"ErrorCode" => 500, "Message" => "boom"}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"MessageID" => "pm-m2-1"}))
      end
    end
  end

  setup do
    FX.clear_cache()
    key = Keys.ctl_system_m2square_settings()
    S3.Fake.delete(key, [])
    on_exit(fn -> S3.Fake.delete(key, []) end)

    countries =
      Map.new(M2squareSettings.default_all_disabled_countries(), fn {code, country} ->
        {code, Map.put(country, "enabled", true)}
      end)

    assert {:ok, {:saved, _, _}} =
             M2squareSettings.put(countries, M2squareSettings.unconfigured_etag())

    start_supervised!(%{
      id: FakeM2Client.State,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               pay_seq: 0,
               pay_calls: [],
               pay_override: nil,
               verify_calls: [],
               verify_queues: %{},
               verify_default: %{}
             }
           end,
           [name: FakeM2Client.State]
         ]}
    })

    start_supervised!(%{
      id: FakeStripeAPI.State,
      start: {Agent, :start_link, [fn -> %{} end, [name: FakeStripeAPI.State]]}
    })

    start_supervised!(%{
      id: __MODULE__.MailState,
      start:
        {Agent, :start_link,
         [fn -> %{emails: [], fail_next: 0} end, [name: __MODULE__.MailState]]}
    })

    port =
      Enum.find_value(43_100..43_150, fn p ->
        case start_supervised({Bandit, plug: MockPostmark, port: p}, id: {:bandit_m2_pm, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    m2_config = %{
      mch_id: @mch_id,
      secret_key: @secret_key,
      client: FakeM2Client,
      fx_provider: FakeFX
    }

    settings = [
      {:bridge_for_teams_core, :m2square, m2_config},
      {:salix_store, :postmark_base_url, "http://127.0.0.1:#{port}"},
      {:bridge_for_teams_core, :teams_postmark_server_token, "pm-token-m2"},
      {:bridge_for_teams_core, :teams_from_email, "billing@comma.test"},
      {:bridge_for_teams_web, :public_base_url, "https://teams.comma.test"},
      {:billing_stripe, :stripe_api, FakeStripeAPI},
      {:billing_stripe, :secret_key, "sk_local"},
      {:billing_stripe, :webhook_secret, "whsec_local"}
    ]

    saved =
      Enum.map(settings, fn {app, key, value} ->
        old = SystemsRuntime.get_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      drain_task_supervisor()
      FX.clear_cache()

      Enum.each(Enum.reverse(saved), fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, old} -> SystemsRuntime.put_env(app, key, old)
      end)
    end)

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

  test "1. M2 signup full lifecycle: explicit payer fields, webhook auth, 30 seats, zero PII, replay idempotency, single confirmation email",
       %{conn: conn} do
    purchase_id = SystemsRuntime.Proc.uuid()

    # Does not guess firstname/lastname from name
    assert {:error, {:payer_invalid, :invalid_firstname}} =
             PaidSignup.start(
               purchase_id,
               br_signup_attrs(30) |> Map.drop(["firstname", "lastname"]),
               "https://teams.comma.test"
             )

    assert {:ok, %{"url" => checkout_url, "mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, br_signup_attrs(30), "https://teams.comma.test")

    assert checkout_url == "https://pay.m2square.test/checkout/M2ORD1"
    assert Regex.match?(~r/\Amtt[a-z]{21}\z/, mch_order_id)
    assert {:error, :not_found} = Orgs.get_org(purchase_id)

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert order.status == "open"
    assert order.target_slot == "initial"

    assert order.signup_snapshot == %{
             "email" => "br-buyer@example.com",
             "org_name" => "BR Team",
             "name" => "Ana Silva"
           }

    refute Map.has_key?(order.signup_snapshot, "docNumber")
    refute Map.has_key?(order.signup_snapshot, "beneficiaryId")
    refute Map.has_key?(order.signup_snapshot, "phone")

    # Forged signature -> 401 and no org provisioned
    webhook_body =
      Jason.encode!(%{
        "mchOrderId" => mch_order_id,
        "orderId" => "M2ORD1",
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "currency" => "BRL",
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount
      })

    forged =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("sign", "bad-signature")
      |> post("/v1/billing/m2square/webhook", webhook_body)

    assert forged.status == 401
    assert {:error, :not_found} = Orgs.get_org(purchase_id)

    # Valid signature + verifyStatus SUCCESS -> 200 "success"
    put_verify_default(
      "M2ORD1",
      {:ok, [verify_item(mch_order_id, "M2ORD1", "SUCCESS", order.locked_amount)]}
    )

    ok_resp = post_signed_webhook(build_conn(), webhook_body)
    assert ok_resp.status == 200
    assert ok_resp.resp_body == "success"

    assert {:ok, org} = Orgs.get_org(purchase_id)
    assert {:ok, user} = Accounts.get_user_by_email("br-buyer@example.com")
    assert {:ok, "owner"} = Memberships.org_role(org.id, user.id)
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)

    # Return check & result
    assert :ok = PaidSignup.check_m2square_signup_return(purchase_id, mch_order_id)
    assert {:ok, %{slug: slug, name: "BR Team"}} = PaidSignup.result(purchase_id)
    assert slug == org.slug

    # Same-order SUCCESS replay is strictly idempotent (no self-conflict, no duplicate email)
    replay_resp = post_signed_webhook(build_conn(), webhook_body)
    assert replay_resp.status == 200
    assert replay_resp.resp_body == "success"

    {:ok, paid_order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert paid_order.status == "paid"
    assert is_binary(paid_order.cycle_id)

    drain_task_supervisor()
    emails = Agent.get(__MODULE__.MailState, & &1.emails)
    assert length(emails) == 1
    [mail] = emails
    assert mail["To"] == "br-buyer@example.com"
    assert mail["TextBody"] =~ "30"
    refute mail["TextBody"] =~ "12345678909"
    refute mail["TextBody"] =~ "+5511999999999"
  end

  test "a local signup payment reports one funnel completion to product analytics" do
    queue = BridgeForTeamsWeb.CftAnalyticsCollector.start()
    purchase_id = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, br_signup_attrs(30), "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    webhook_body =
      Jason.encode!(%{
        "mchOrderId" => mch_order_id,
        "orderId" => "M2ORD1",
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "currency" => "BRL",
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount
      })

    put_verify_default(
      "M2ORD1",
      {:ok, [verify_item(mch_order_id, "M2ORD1", "SUCCESS", order.locked_amount)]}
    )

    # The webhook, its replay and the return check settle one order once.
    assert post_signed_webhook(build_conn(), webhook_body).status == 200
    assert post_signed_webhook(build_conn(), webhook_body).status == 200
    assert :ok = PaidSignup.check_m2square_signup_return(purchase_id, mch_order_id)

    assert [
             %{
               "event" => "cft_checkout_completed",
               "distinct_id" => ^purchase_id,
               "properties" => %{"provider" => "m2square", "seats" => 30, "is_internal" => false}
             } = completed
           ] = BridgeForTeamsWeb.CftAnalyticsCollector.events(queue)

    refute Jason.encode!(completed) =~ "br-buyer@example.com"
    drain_task_supervisor()
  end

  test "a local signup sent with DNT reports no completion, and DNT never changes order reuse" do
    queue = BridgeForTeamsWeb.CftAnalyticsCollector.start()
    purchase_id = SystemsRuntime.Proc.uuid()
    attrs = Map.put(br_signup_attrs(30), "analytics_opt_out", true)

    assert {:ok, %{"mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, attrs, "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert order.signup_snapshot["analytics_opt_out"] == true

    # A later submission without DNT reuses the open order, which keeps its first choice.
    assert {:ok, %{"mch_order_id" => ^mch_order_id}} =
             PaidSignup.start(purchase_id, br_signup_attrs(30), "https://teams.comma.test")

    put_verify_default(
      "M2ORD1",
      {:ok, [verify_item(mch_order_id, "M2ORD1", "SUCCESS", order.locked_amount)]}
    )

    assert :ok = PaidSignup.check_m2square_signup_return(purchase_id, mch_order_id)
    assert {:ok, _org} = Orgs.get_org(purchase_id)
    BridgeForTeamsWeb.CftAnalyticsCollector.refute_events(queue)
    drain_task_supervisor()
  end

  test "2. 1-hour timeout late payment recovery: FAILED -> advance 2h -> late SUCCESS grants seats" do
    purchase_id = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, ec_signup_attrs(32), "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    # First FAILED webhook
    put_verify_default(
      "M2ORD1",
      {:ok, [verify_item(mch_order_id, "M2ORD1", "FAILED", order.locked_amount)]}
    )

    failed_body =
      Jason.encode!(%{
        "mchOrderId" => mch_order_id,
        "orderId" => "M2ORD1",
        "orderType" => "PAYMENT",
        "orderStatus" => "FAILED"
      })

    assert post_signed_webhook(build_conn(), failed_body).status == 200
    assert {:ok, %{status: "failed"}} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    # Advance 2 hours
    SystemsClock.advance(2 * 3_600_000)

    # Late SUCCESS arrives with no conflict -> grants seats
    put_verify_default(
      "M2ORD1",
      {:ok, [verify_item(mch_order_id, "M2ORD1", "SUCCESS", order.locked_amount)]}
    )

    late_body =
      Jason.encode!(%{
        "mchOrderId" => mch_order_id,
        "orderId" => "M2ORD1",
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "currency" => "ECS",
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount
      })

    assert post_signed_webhook(build_conn(), late_body).status == 200
    assert {:ok, org} = Orgs.get_org(purchase_id)
    assert {:ok, 32} = TeamsAccess.check(org.billing_account_id)
  end

  test "3. duplicate payment suffix (_1) is verified and appended to duplicate_events without granting a second cycle" do
    {org, mch_order_id, order} = provision_paid_m2_org(30)

    dup_mch_order_id = mch_order_id <> "_1"
    dup_provider_id = "M2DUP_1"

    put_verify_default(
      dup_provider_id,
      {:ok, [verify_item(dup_mch_order_id, dup_provider_id, "SUCCESS", order.locked_amount)]}
    )

    dup_body =
      Jason.encode!(%{
        "mchOrderId" => dup_mch_order_id,
        "orderId" => dup_provider_id,
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "currency" => order.currency,
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount
      })

    assert post_signed_webhook(build_conn(), dup_body).status == 200
    # Idempotent replay of the same duplicate event
    assert post_signed_webhook(build_conn(), dup_body).status == 200

    {:ok, updated} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert length(updated.duplicate_events) == 1
    assert hd(updated.duplicate_events)["provider_order_id"] == dup_provider_id

    assert Enum.any?(
             Ops.list_orders_for_reconciliation(limit: 50),
             &(&1.mch_order_id == mch_order_id and &1.duplicate_event_count == 1)
           )

    # Still only 1 paid cycle on the account
    assert paid_cycle_count(org.billing_account_id) == 1
  end

  test "4. cross-expiry renewal slot deduplication (Astra #2): pre-expiry order A and post-expiry order B share target_slot" do
    {org, _initial_order_id, initial_order} = provision_paid_m2_org(30)

    # Pre-expiry renewal order A
    assert {:ok, %{"mch_order_id" => order_a_id}} =
             PaidSignup.renew(org, ec_renewal_attrs(30), "https://teams.comma.test")

    {:ok, order_a} = Orders.get_by_mch_order_id(BillingCore.Repo, order_a_id)
    assert order_a.target_slot == "after:" <> initial_order.cycle_id

    # Advance past 3-month expiry (95 days)
    SystemsClock.advance(95 * 86_400_000)
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)

    # Post-expiry renewal order B must STILL resolve the exact same target_slot
    assert {:ok, %{"mch_order_id" => order_b_id}} =
             PaidSignup.renew(org, ec_renewal_attrs(30), "https://teams.comma.test")

    assert order_b_id != order_a_id
    {:ok, order_b} = Orders.get_by_mch_order_id(BillingCore.Repo, order_b_id)
    assert order_b.target_slot == order_a.target_slot

    # Order A pays first -> grants 1 quarter
    put_verify_default(
      order_a.provider_order_id,
      {:ok,
       [verify_item(order_a_id, order_a.provider_order_id, "SUCCESS", order_a.locked_amount)]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(order_a_id, order_a.provider_order_id, order_a)
           ).status == 200

    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)
    assert paid_cycle_count(org.billing_account_id) == 2

    # Order B pays later -> hits target_slot conflict -> conflict_paid, no 3rd cycle!
    put_verify_default(
      order_b.provider_order_id,
      {:ok,
       [verify_item(order_b_id, order_b.provider_order_id, "SUCCESS", order_b.locked_amount)]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(order_b_id, order_b.provider_order_id, order_b)
           ).status == 200

    assert {:ok, %{status: "conflict_paid"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, order_b_id)

    assert paid_cycle_count(org.billing_account_id) == 2
  end

  test "5a. dual-channel mutual exclusion (M2 timeout -> Stripe checkout -> M2 late SUCCESS -> conflict_paid -> Stripe succeeds)" do
    purchase_id = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, m2_order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    # Advance > 1 hour so M2 pending window expires and Stripe Checkout is allowed
    SystemsClock.advance(3_700_000)

    assert {:ok, %{"url" => "https://checkout.stripe.test/teams"}} =
             PaidSignup.start(
               purchase_id,
               %{
                 "email" => "ec-buyer@example.com",
                 "name" => "EC Buyer",
                 "org_name" => "EC Team",
                 "seats" => 100
               },
               "https://teams.comma.test"
             )

    # Late M2 SUCCESS arrives while Stripe checkout is pending -> conflict_paid, no seats
    put_verify_default(
      m2_order.provider_order_id,
      {:ok,
       [verify_item(mch_order_id, m2_order.provider_order_id, "SUCCESS", m2_order.locked_amount)]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(mch_order_id, m2_order.provider_order_id, m2_order)
           ).status == 200

    assert {:ok, %{status: "conflict_paid"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    assert {:error, :not_found} = Orgs.get_org(purchase_id)

    # Stripe invoice.paid converges -> grants 100 seats, total 1 paid allocation
    script_stripe_payment("in_dual_1", "sub_dual_1")
    assert {:ok, _} = send_stripe_webhook("evt_dual_1")
    assert {:ok, 100} = TeamsAccess.check("ba_teams_" <> purchase_id)
    assert paid_cycle_count("ba_teams_" <> purchase_id) == 1
  end

  test "5b. dual-channel mutual exclusion (M2 already active -> late Stripe invoice.paid blocked in lock without double grant)" do
    {org, _mch_order_id, _order} = provision_paid_m2_org(30)

    # Simulate a late Stripe invoice.paid arriving for the same billing account
    starts = DateTime.to_unix(SystemsClock.utc_now())
    ends = DateTime.to_unix(DateTime.shift(DateTime.from_unix!(starts), month: 3))

    metadata = %{
      "surface" => "bridge",
      "billing_account_id" => org.billing_account_id,
      "product_owner_type" => "organization",
      "product_owner_id" => org.id,
      "package_version" => TeamsPricing.version()
    }

    script_stripe_payment_with_metadata(
      "in_late_stripe",
      "sub_late_stripe",
      metadata,
      starts,
      ends
    )

    assert {:ok, %{result: %{conflict: :m2square_term_already_active}}} =
             send_stripe_webhook("evt_late_stripe_overlap")

    # Still only the M2square 30-seat cycle, no Stripe cycle written
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)
    assert paid_cycle_count(org.billing_account_id) == 1
  end

  test "6. early renewal, Settings general redirect & return check, and REVERSED precise revocation" do
    {org, initial_order_id, initial_order} = provision_paid_m2_org(35)
    {:ok, owner} = Accounts.get_user_by_email("ec-buyer@example.com")

    # Add a historical expired Stripe cycle on the same account to prove REVERSED leaves it untouched
    insert_historical_stripe_cycle!(org)

    token = settings_billing(org, owner)["quote_token"]

    # Early renewal with seats < licensed_seats (30 < 35) -> 422 with field error
    below_min =
      post(
        log_in_user(build_conn(), owner),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/renew",
        Map.put(ec_renewal_attrs(30), "quote_token", token)
      )

    assert below_min.status == 422
    assert json_response(below_min, 422)["error"]["details"]["fields"]["seats"]

    # Invalid payer field (EC PAS with CASH or bad CPF for BR) -> 422 with field error
    bad_cpf =
      post(
        log_in_user(build_conn(), owner),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/renew",
        Map.merge(br_renewal_attrs(35), %{"doc_number" => "111", "quote_token" => token})
      )

    assert bad_cpf.status == 422
    assert json_response(bad_cpf, 422)["error"]["details"]["fields"]["doc_number"]

    # Valid early renewal with 38 >= 35 seats (within EC's $10,000 max_amount limit)
    renew_resp =
      post(
        log_in_user(build_conn(), owner),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/renew",
        Map.put(ec_renewal_attrs(38), "quote_token", token)
      )

    assert json_response(renew_resp, 200)["data"]["url"] =~ "https://pay.m2square.test/checkout/"

    # Find the renewal order
    %{rows: [[renew_order_id, renew_provider_id, renew_locked]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT mch_order_id, provider_order_id, locked_amount FROM billing_m2square_orders WHERE billing_account_id = $1 AND kind = 'renewal' LIMIT 1",
        [org.billing_account_id]
      )

    # Return redirect preserves ?m2_order=...
    redir =
      get(
        log_in_user(build_conn(), owner),
        "/orgs/#{org.slug}/settings/general?m2_order=#{renew_order_id}"
      )

    assert redirected_to(redir) == "/orgs/#{org.slug}/settings?m2_order=#{renew_order_id}"

    # Settings API ?m2_order=... triggers active verifyStatus and converges renewal
    put_verify_default(
      renew_provider_id,
      {:ok, [verify_item(renew_order_id, renew_provider_id, "SUCCESS", renew_locked)]}
    )

    {:ok, cov_before} = TeamsAccess.coverage(org.billing_account_id)

    general_resp =
      log_in_user(build_conn(), owner)
      |> put_req_header("cf-ipcountry", "BR")
      |> get("/dashboard/api/v1/orgs/#{org.slug}/settings/general?m2_order=#{renew_order_id}")

    billing = json_response(general_resp, 200)["data"]["billing"]
    assert billing["active"] == true
    assert billing["licensed_seats"] == 35
    assert billing["provider"] == "m2square"
    assert billing["has_stripe_customer"] == false
    assert billing["detected_country"] == "BR"
    assert billing["can_renew_stripe"] == false
    assert billing["can_renew_m2square"] == false
    assert billing["quote_token"] == nil
    assert is_binary(billing["expires_at"])
    assert is_binary(billing["next_period_end"])
    assert billing["m2square_countries"] == []

    # Renewal cycle starts exactly at current_period_end
    {:ok, renew_order} = Orders.get_by_mch_order_id(BillingCore.Repo, renew_order_id)
    assert renew_order.status == "paid"

    %{rows: [[renew_start]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT period_start FROM billing_subscription_cycles WHERE id = $1",
        [renew_order.cycle_id]
      )

    assert DateTime.compare(renew_start, cov_before.current_period_end) == :eq

    # REVERSED webhook on the renewal order revokes ONLY the renewal cycle
    put_verify_default(
      renew_provider_id,
      {:ok, [verify_item(renew_order_id, renew_provider_id, "REVERSED", renew_locked)]}
    )

    rev_body =
      Jason.encode!(%{
        "mchOrderId" => renew_order_id,
        "orderId" => renew_provider_id,
        "orderType" => "PAYMENT",
        "orderStatus" => "REVERSED"
      })

    assert post_signed_webhook(build_conn(), rev_body).status == 200

    assert {:ok, %{status: "reversed"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, renew_order_id)

    # Initial M2 cycle is still active (35 seats), future cycle is gone, historical Stripe cycle untouched
    assert {:ok, 35} = TeamsAccess.check(org.billing_account_id)
    {:ok, cov_after} = TeamsAccess.coverage(org.billing_account_id)
    assert cov_after.has_future_paid_cycle == false

    assert {:ok, %{status: "paid"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, initial_order_id)

    assert initial_order.cycle_id != renew_order.cycle_id
    assert historical_stripe_source_state(org.billing_account_id) == "paid"
  end

  test "7. read-lag guard matrix (Astra #3): returns 500 on stale verifyStatus for both REVERSED and SUCCESS, then converges on retry" do
    # 7a: Paid order receives signed REVERSED, verifyStatus lags with SUCCESS -> 500, retry returns REVERSED -> 200 & revoked
    {org, paid_order_id, paid_order} = provision_paid_m2_org(30)

    put_verify_queue(paid_order.provider_order_id, [
      {:ok,
       [
         verify_item(
           paid_order_id,
           paid_order.provider_order_id,
           "SUCCESS",
           paid_order.locked_amount
         )
       ]},
      {:ok,
       [
         verify_item(
           paid_order_id,
           paid_order.provider_order_id,
           "REVERSED",
           paid_order.locked_amount
         )
       ]}
    ])

    rev_body =
      Jason.encode!(%{
        "mchOrderId" => paid_order_id,
        "orderId" => paid_order.provider_order_id,
        "orderType" => "PAYMENT",
        "orderStatus" => "REVERSED"
      })

    assert post_signed_webhook(build_conn(), rev_body).status == 500
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)

    assert post_signed_webhook(build_conn(), rev_body).status == 200
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)

    # 7b: Failed/pending order receives signed SUCCESS, verifyStatus lags with FAILED -> 500, retry returns SUCCESS -> 200 & granted
    purchase_id = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => lag_order_id}} =
             PaidSignup.start(purchase_id, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, lag_order} = Orders.get_by_mch_order_id(BillingCore.Repo, lag_order_id)
    Orders.mark_failed!(BillingCore.Repo, lag_order_id)

    put_verify_queue(lag_order.provider_order_id, [
      {:ok,
       [verify_item(lag_order_id, lag_order.provider_order_id, "FAILED", lag_order.locked_amount)]},
      {:ok,
       [
         verify_item(
           lag_order_id,
           lag_order.provider_order_id,
           "SUCCESS",
           lag_order.locked_amount
         )
       ]}
    ])

    succ_body = success_webhook_json(lag_order_id, lag_order.provider_order_id, lag_order)

    assert post_signed_webhook(build_conn(), succ_body).status == 500
    assert {:error, :not_found} = Orgs.get_org(purchase_id)

    assert post_signed_webhook(build_conn(), succ_body).status == 200
    assert {:ok, 30} = TeamsAccess.check("ba_teams_" <> purchase_id)
  end

  test "8. expiry switch to Stripe auto-creates customer, disabled country still settles existing orders, Ops.record_offline_refund, and >64KB/invalid JSON webhook guards" do
    # 8a: Create an order while EC is enabled, then disable EC before webhook arrives
    purchase_id = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_order_id}} =
             PaidSignup.start(purchase_id, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    # Disable EC
    update_console_country("EC", %{"enabled" => false})

    # New EC orders are rejected
    assert {:error, :m2square_country_unavailable} =
             PaidSignup.start(
               SystemsRuntime.Proc.uuid(),
               ec_signup_attrs(30),
               "https://teams.comma.test"
             )

    # Existing EC order webhook SUCCESS still converges normally!
    put_verify_default(
      order.provider_order_id,
      {:ok, [verify_item(mch_order_id, order.provider_order_id, "SUCCESS", order.locked_amount)]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(mch_order_id, order.provider_order_id, order)
           ).status == 200

    {:ok, org} = Orgs.get_org(purchase_id)
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)

    # 8b: Ops.record_offline_refund revokes seats, writes audit log, and is idempotent
    assert {:ok, %{idempotent: false}} =
             Ops.record_offline_refund(
               mch_order_id,
               "ops@comma.test",
               "customer requested refund"
             )

    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)

    assert {:ok, %{status: "reversed"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    assert {:ok, %{idempotent: true}} =
             Ops.record_offline_refund(
               mch_order_id,
               "ops@comma.test",
               "customer requested refund"
             )

    %{rows: [[audit_count]]} =
      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        "SELECT count(*) FROM audit_logs WHERE org_id = $1 AND action = 'billing.m2square.offline_refund'",
        [Ecto.UUID.dump!(org.id)]
      )

    assert audit_count == 1

    # 8c: Expired M2-only org switching to Stripe 100 seats auto-creates Stripe customer
    {:ok, owner} = Accounts.get_user_by_email("ec-buyer@example.com")

    stripe_renew =
      post(
        log_in_user(build_conn(), owner),
        "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/renew",
        %{"seats" => "100", "quote_token" => settings_billing(org, owner)["quote_token"]}
      )

    assert json_response(stripe_renew, 200)["data"]["url"] == "https://checkout.stripe.test/teams"
    assert length(Agent.get(FakeStripeAPI.State, &Map.get(&1, :customers_created, []))) == 1

    # 8d: Webhook >64KB returns HTTP 413 for BOTH application/json and text/plain;
    # duplicate or missing sign headers return 401; invalid JSON returns 400
    oversized = ~s({"pad":") <> String.duplicate("a", 66_000) <> ~s("})

    for content_type <- ["application/json", "text/plain"] do
      resp =
        build_conn()
        |> put_req_header("content-type", content_type)
        |> put_req_header("sign", sign_body(oversized))
        |> post("/v1/billing/m2square/webhook", oversized)

      assert resp.status == 413
    end

    valid_json = ~s({"mchOrderId":"mttaaaaaaaaaaaaaaaaaaaaa","orderId":"X"})
    sig = sign_body(valid_json)

    dup_sign_resp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> Plug.Conn.prepend_req_headers([{"sign", sig}, {"sign", sig}])
      |> post("/v1/billing/m2square/webhook", valid_json)

    assert dup_sign_resp.status == 401

    missing_sign_resp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/billing/m2square/webhook", valid_json)

    assert missing_sign_resp.status == 401

    invalid_json = "{not valid json"

    bad_json_resp =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("sign", sign_body(invalid_json))
      |> post("/v1/billing/m2square/webhook", invalid_json)

    assert bad_json_resp.status == 400
  end

  test "9. exact amount/realAmount/currency validation and strict verifyStatus identity matching (A3)" do
    # 9a: Overpayment (realAmount > locked_amount) -> conflict_paid preserving actual real_amount, no grant
    purchase_over = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => over_id}} =
      PaidSignup.start(purchase_over, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, over_order} = Orders.get_by_mch_order_id(BillingCore.Repo, over_id)
    over_real = Decimal.add(Decimal.new(over_order.locked_amount), Decimal.new("0.01"))

    put_verify_default(over_order.provider_order_id, {
      :ok,
      [
        verify_item(over_id, over_order.provider_order_id, "SUCCESS", over_order.locked_amount)
        |> Map.put("realAmount", over_real)
      ]
    })

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(over_id, over_order.provider_order_id, over_order)
           ).status == 200

    {:ok, over_after} = Orders.get_by_mch_order_id(BillingCore.Repo, over_id)
    assert over_after.status == "conflict_paid"
    assert over_after.real_amount == Decimal.to_string(over_real, :normal)
    assert {:error, :not_found} = Orgs.get_org(purchase_over)

    # 9b: Underpayment & missing realAmount -> conflict_paid, no grant
    for {label, mutate_item} <- [
          {"underpayment",
           fn item, locked ->
             Map.put(item, "realAmount", Decimal.sub(Decimal.new(locked), Decimal.new("0.01")))
           end},
          {"missing realAmount", fn item, _locked -> Map.delete(item, "realAmount") end}
        ] do
      pid = SystemsRuntime.Proc.uuid()

      {:ok, %{"mch_order_id" => oid}} =
        PaidSignup.start(pid, ec_signup_attrs(30), "https://teams.comma.test")

      {:ok, ord} = Orders.get_by_mch_order_id(BillingCore.Repo, oid)

      put_verify_default(
        ord.provider_order_id,
        {:ok,
         [
           mutate_item.(
             verify_item(oid, ord.provider_order_id, "SUCCESS", ord.locked_amount),
             ord.locked_amount
           )
         ]}
      )

      assert post_signed_webhook(
               build_conn(),
               success_webhook_json(oid, ord.provider_order_id, ord)
             ).status == 200

      {:ok, after_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, oid)
      assert after_ord.status == "conflict_paid", "expected conflict_paid for #{label}"
      assert {:error, :not_found} = Orgs.get_org(pid)
    end

    # 9c: Webhook currency mismatch -> conflict_paid even when verifyStatus item omits currency
    pid_ccy = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => ccy_id}} =
      PaidSignup.start(pid_ccy, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, ccy_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, ccy_id)

    put_verify_default(
      ccy_ord.provider_order_id,
      {:ok, [verify_item(ccy_id, ccy_ord.provider_order_id, "SUCCESS", ccy_ord.locked_amount)]}
    )

    bad_ccy_webhook =
      Jason.encode!(%{
        "mchOrderId" => ccy_id,
        "orderId" => ccy_ord.provider_order_id,
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "currency" => "BRL",
        "amount" => ccy_ord.locked_amount,
        "realAmount" => ccy_ord.locked_amount
      })

    assert post_signed_webhook(build_conn(), bad_ccy_webhook).status == 200

    assert {:ok, %{status: "conflict_paid"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, ccy_id)

    assert {:error, :not_found} = Orgs.get_org(pid_ccy)

    # 9d: verifyStatus missing orderType/orderId or orderType == "PAYOUT" -> HTTP 500 (:verify_status_lag)
    pid_strict = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => strict_id}} =
      PaidSignup.start(pid_strict, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, strict_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, strict_id)
    strict_wh = success_webhook_json(strict_id, strict_ord.provider_order_id, strict_ord)

    for bad_item <- [
          verify_item(
            strict_id,
            strict_ord.provider_order_id,
            "SUCCESS",
            strict_ord.locked_amount
          )
          |> Map.delete("orderType"),
          verify_item(
            strict_id,
            strict_ord.provider_order_id,
            "SUCCESS",
            strict_ord.locked_amount
          )
          |> Map.delete("orderId"),
          verify_item(
            strict_id,
            strict_ord.provider_order_id,
            "SUCCESS",
            strict_ord.locked_amount
          )
          |> Map.put("orderType", "PAYOUT")
        ] do
      put_verify_default(strict_ord.provider_order_id, {:ok, [bad_item]})
      assert post_signed_webhook(build_conn(), strict_wh).status == 500
      assert {:error, :not_found} = Orgs.get_org(pid_strict)
    end
  end

  test "10. pay wrong-currency quarantine persists provider_order_id and blocks later currency-less SUCCESS; mismatched provider_order_id rejected (A4)" do
    purchase_id = SystemsRuntime.Proc.uuid()

    Agent.update(FakeM2Client.State, fn state ->
      %{
        state
        | pay_override: fn _payload, order_id ->
            {:ok,
             %{
               order_id: order_id,
               checkout_url: "https://pay.m2square.test/checkout/#{order_id}",
               currency: "PEN",
               raw_item: %{"orderId" => order_id}
             }}
          end
      }
    end)

    assert {:error, :m2square_pay_rejected} =
             PaidSignup.start(purchase_id, ec_signup_attrs(30), "https://teams.comma.test")

    Agent.update(FakeM2Client.State, &%{&1 | pay_override: nil})

    %{rows: [[q_id, q_provider_id, q_status]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT mch_order_id, provider_order_id, status FROM billing_m2square_orders WHERE billing_account_id = $1",
        ["ba_teams_" <> purchase_id]
      )

    assert q_status == "quarantined"
    assert is_binary(q_provider_id) and q_provider_id != ""

    {:ok, q_order} = Orders.get_by_mch_order_id(BillingCore.Repo, q_id)

    # Mismatched provider_order_id is rejected without mutating the order
    bad_pid_wh =
      Jason.encode!(%{
        "mchOrderId" => q_id,
        "orderId" => "OTHER_PROVIDER_ID",
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "amount" => q_order.locked_amount,
        "realAmount" => q_order.locked_amount
      })

    assert post_signed_webhook(build_conn(), bad_pid_wh).status == 200
    assert {:ok, %{status: "quarantined"}} = Orders.get_by_mch_order_id(BillingCore.Repo, q_id)

    # Currency-less SUCCESS webhook for quarantined order MUST go to conflict_paid, never paid!
    put_verify_default(
      q_provider_id,
      {:ok, [verify_item(q_id, q_provider_id, "SUCCESS", q_order.locked_amount)]}
    )

    currencyless_wh =
      Jason.encode!(%{
        "mchOrderId" => q_id,
        "orderId" => q_provider_id,
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "amount" => q_order.locked_amount,
        "realAmount" => q_order.locked_amount
      })

    assert post_signed_webhook(build_conn(), currencyless_wh).status == 200
    assert {:ok, %{status: "conflict_paid"}} = Orders.get_by_mch_order_id(BillingCore.Repo, q_id)
    assert {:error, :not_found} = Orgs.get_org(purchase_id)
  end

  test "11. duplicate (_1) read-lag returns 500 on lagged REVERSED and enforces terminal REVERSED against stale SUCCESS (A5)" do
    {_org, mch_order_id, order} = provision_paid_m2_org(30)
    dup_mch_id = mch_order_id <> "_1"
    dup_pid = "M2DUP_LAG_1"

    # Initial SUCCESS recorded on _1
    put_verify_default(
      dup_pid,
      {:ok, [verify_item(dup_mch_id, dup_pid, "SUCCESS", order.locked_amount)]}
    )

    dup_succ_wh =
      Jason.encode!(%{
        "mchOrderId" => dup_mch_id,
        "orderId" => dup_pid,
        "orderType" => "PAYMENT",
        "orderStatus" => "SUCCESS",
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount
      })

    assert post_signed_webhook(build_conn(), dup_succ_wh).status == 200

    # Signed REVERSED arrives while verifyStatus still lags at SUCCESS -> MUST return 500!
    put_verify_queue(dup_pid, [
      {:ok, [verify_item(dup_mch_id, dup_pid, "SUCCESS", order.locked_amount)]},
      {:ok, [verify_item(dup_mch_id, dup_pid, "REVERSED", order.locked_amount)]}
    ])

    dup_rev_wh =
      Jason.encode!(%{
        "mchOrderId" => dup_mch_id,
        "orderId" => dup_pid,
        "orderType" => "PAYMENT",
        "orderStatus" => "REVERSED"
      })

    assert post_signed_webhook(build_conn(), dup_rev_wh).status == 500
    # Retry sees REVERSED -> 200 and records REVERSED
    assert post_signed_webhook(build_conn(), dup_rev_wh).status == 200

    {:ok, after_rev} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    [entry] = after_rev.duplicate_events
    assert entry["provider_order_id"] == dup_pid
    assert entry["order_status"] == "REVERSED"

    # Stale SUCCESS replay MUST NOT overwrite terminal REVERSED
    put_verify_default(
      dup_pid,
      {:ok, [verify_item(dup_mch_id, dup_pid, "SUCCESS", order.locked_amount)]}
    )

    assert post_signed_webhook(build_conn(), dup_succ_wh).status == 200
    {:ok, after_stale} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    [entry_after] = after_stale.duplicate_events
    assert entry_after["order_status"] == "REVERSED"
  end

  test "12. historical stripe_subscription receiving a new overlapping invoice.paid is blocked and persisted in Ops.list_stripe_overlap_conflicts (A6)" do
    {org, _mch_order_id, _order} = provision_paid_m2_org(30)
    insert_historical_stripe_cycle!(org)

    # New unrecorded invoice on the EXISTING historical subscription "sub_hist_1" whose period overlaps active M2 cycle
    starts = DateTime.to_unix(SystemsClock.utc_now())
    ends = DateTime.to_unix(DateTime.shift(DateTime.from_unix!(starts), month: 3))

    metadata = %{
      "surface" => "bridge",
      "billing_account_id" => org.billing_account_id,
      "product_owner_type" => "organization",
      "product_owner_id" => org.id,
      "package_version" => TeamsPricing.version()
    }

    script_stripe_payment_with_metadata("in_new_overlap_1", "sub_hist_1", metadata, starts, ends)

    assert {:ok, %{result: %{conflict: :m2square_term_already_active}}} =
             send_stripe_webhook("evt_hist_sub_new_invoice")

    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)
    %{entries: conflicts} = Ops.list_stripe_overlap_conflicts()

    assert Enum.any?(
             conflicts,
             &(&1["invoice_id"] == "in_new_overlap_1" and &1["subscription_id"] == "sub_hist_1")
           )
  end

  test "13. pending 30-seat renewal becomes conflict_paid if org members grow above 30 before SUCCESS (A7)" do
    {org, _mch_order_id, _order} = provision_paid_m2_org(30)

    # Create a valid 30-seat early renewal order while org has 1 member and 30 licensed seats
    assert {:ok, %{"mch_order_id" => renew_id}} =
             PaidSignup.renew(org, ec_renewal_attrs(30), "https://teams.comma.test")

    {:ok, renew_order} = Orders.get_by_mch_order_id(BillingCore.Repo, renew_id)

    # Simulate seats growing: upgrade licensed seats on active cycle to 38 while renewal is pending
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_subscription_cycles
      SET source_metadata = jsonb_set(
        source_metadata,
        '{payment_sources}',
        (
          SELECT jsonb_object_agg(k, jsonb_set(v, '{teams_seats}', '38'::jsonb))
          FROM jsonb_each(source_metadata->'payment_sources') AS e(k, v)
        )
      )
      WHERE billing_account_id = $1
      """,
      [org.billing_account_id]
    )

    put_verify_default(
      renew_order.provider_order_id,
      {:ok,
       [
         verify_item(
           renew_id,
           renew_order.provider_order_id,
           "SUCCESS",
           renew_order.locked_amount
         )
       ]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(renew_id, renew_order.provider_order_id, renew_order)
           ).status == 200

    assert {:ok, %{status: "conflict_paid"}} =
             Orders.get_by_mch_order_id(BillingCore.Repo, renew_id)
  end

  test "14. past_due Stripe disables renewals in Settings, offline refund without org persists refund_metadata, and Ops.export_ledger_entries paginates by currency (A10, A11)" do
    # 14a: past_due Stripe subscription -> can_renew_stripe == false and can_renew_m2square == false
    {org, initial_mch_id, _order} = provision_paid_m2_org(30)
    {:ok, owner} = Accounts.get_user_by_email("ec-buyer@example.com")

    # Revoke M2 cycle and add a past_due Stripe subscription
    {:ok, _} = Ops.record_offline_refund(initial_mch_id, "ops@comma.test", "revoke for test")
    insert_historical_stripe_cycle!(org)

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET status = 'past_due' WHERE billing_account_id = $1 AND source_type = 'stripe_subscription'",
      [org.billing_account_id]
    )

    resp =
      log_in_user(build_conn(), owner)
      |> get("/dashboard/api/v1/orgs/#{org.slug}/settings/general")

    billing = json_response(resp, 200)["data"]["billing"]
    assert billing["active"] == false
    assert billing["can_renew_stripe"] == false
    assert billing["can_renew_m2square"] == false

    # 14b: Ops.record_offline_refund on a signup conflict_paid order with NO org/cycle durably persists refund_metadata
    pid_no_org = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => no_org_order_id}} =
      PaidSignup.start(pid_no_org, br_signup_attrs(30), "https://teams.comma.test")

    {:ok, no_org_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, no_org_order_id)

    put_verify_default(
      no_org_ord.provider_order_id,
      {:ok,
       [
         verify_item(
           no_org_order_id,
           no_org_ord.provider_order_id,
           "SUCCESS",
           no_org_ord.locked_amount
         )
         |> Map.put(
           "realAmount",
           Decimal.sub(Decimal.new(no_org_ord.locked_amount), Decimal.new("1.00"))
         )
       ]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(no_org_order_id, no_org_ord.provider_order_id, no_org_ord)
           ).status == 200

    assert {:error, :not_found} = Orgs.get_org(pid_no_org)

    assert {:error, :invalid_refund_metadata} =
             Ops.record_offline_refund(no_org_order_id, "  ", "reason")

    assert {:ok, %{idempotent: false, refund_metadata: meta}} =
             Ops.record_offline_refund(
               no_org_order_id,
               "finance@comma.test",
               "underpaid signup refund"
             )

    assert meta["operator"] == "finance@comma.test"
    assert meta["reason"] == "underpaid signup refund"

    {:ok, refunded_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, no_org_order_id)
    assert refunded_ord.status == "reversed"
    assert refunded_ord.refund_metadata["operator"] == "finance@comma.test"

    # 14c: Ops.export_ledger_entries filters by currency and paginates deterministically with cursor
    page1 = Ops.export_ledger_entries(currency: "BRL", limit: 1)
    assert length(page1.entries) == 1
    assert hd(page1.entries).mch_order_id == no_org_order_id
    assert hd(page1.entries).refund_metadata["operator"] == "finance@comma.test"

    ecs_export = Ops.export_ledger_entries(currency: "ECS", limit: 10)

    assert Enum.any?(
             ecs_export.entries,
             &(&1.mch_order_id == initial_mch_id and &1.status == "reversed")
           )
  end

  test "15. failed TeamsMail delivery leaves notified_at nil and subsequent SUCCESS replay retries and sets notified_at (A12)" do
    Agent.update(__MODULE__.MailState, &%{&1 | fail_next: 1})

    purchase_id = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => mch_order_id}} =
      PaidSignup.start(purchase_id, br_signup_attrs(30), "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    put_verify_default(
      order.provider_order_id,
      {:ok, [verify_item(mch_order_id, order.provider_order_id, "SUCCESS", order.locked_amount)]}
    )

    wh = success_webhook_json(mch_order_id, order.provider_order_id, order)
    assert post_signed_webhook(build_conn(), wh).status == 200
    drain_task_supervisor()

    {:ok, after_fail} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert after_fail.status == "paid"
    assert after_fail.notified_at == nil
    assert after_fail.notification_claimed_at == nil
    assert Agent.get(__MODULE__.MailState, &length(&1.emails)) == 0

    # Replay SUCCESS -> retries email -> succeeds and sets notified_at!
    assert post_signed_webhook(build_conn(), wh).status == 200
    drain_task_supervisor()

    {:ok, after_retry} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert %DateTime{} = after_retry.notified_at
    assert Agent.get(__MODULE__.MailState, &length(&1.emails)) == 1
  end

  test "16. out-of-order currency-mismatch quarantine handles FAILED-first and SUCCESS-first races (Astra R2 #2)" do
    # Case 1: signed FAILED arrives before pay returns wrong currency -> failed becomes quarantined ->
    # later currency-less SUCCESS becomes conflict_paid with no seats.
    purchase_id_1 = SystemsRuntime.Proc.uuid()

    Agent.update(FakeM2Client.State, fn s ->
      %{
        s
        | pay_override: fn payload, order_id ->
            mch_order_id = payload["mchOrderId"]

            put_verify_default(
              order_id,
              {:ok, [verify_item(mch_order_id, order_id, "FAILED", payload["amount"])]}
            )

            failed_wh =
              Jason.encode!(%{
                "mchId" => @mch_id,
                "mchOrderId" => mch_order_id,
                "orderId" => order_id,
                "orderStatus" => "FAILED"
              })

            assert post_signed_webhook(build_conn(), failed_wh).status == 200
            {:ok, failed_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
            assert failed_ord.status == "failed"
            assert failed_ord.provider_order_id == order_id

            {:ok,
             %{
               order_id: order_id,
               checkout_url: "https://pay.m2square.test/checkout/#{order_id}",
               currency: "USD",
               raw_item: %{"orderId" => order_id, "currency" => "USD"}
             }}
          end
      }
    end)

    assert {:error, :m2square_pay_rejected} =
             PaidSignup.start(purchase_id_1, ec_signup_attrs(30), "https://teams.comma.test")

    [p1] = Agent.get(FakeM2Client.State, & &1.pay_calls)
    mch_id_1 = p1["mchOrderId"]
    {:ok, q_ord_1} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_id_1)
    assert q_ord_1.status == "quarantined"

    # Late currency-less SUCCESS must route to conflict_paid, never grant seats
    put_verify_default(
      q_ord_1.provider_order_id,
      {:ok,
       [
         verify_item(mch_id_1, q_ord_1.provider_order_id, "SUCCESS", q_ord_1.locked_amount)
         |> Map.delete("currency")
       ]}
    )

    late_ok_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => mch_id_1,
        "orderId" => q_ord_1.provider_order_id,
        "orderStatus" => "SUCCESS",
        "amount" => q_ord_1.locked_amount,
        "realAmount" => q_ord_1.locked_amount
      })

    assert post_signed_webhook(build_conn(), late_ok_wh).status == 200
    {:ok, final_1} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_id_1)
    assert final_1.status == "conflict_paid"
    assert {:error, :teams_subscription_required} = TeamsAccess.check(final_1.billing_account_id)

    # Case 2: currency-less SUCCESS settles and grants seats BEFORE pay returns wrong currency ->
    # quarantine revokes payment source immediately and marks order conflict_paid.
    purchase_id_2 = SystemsRuntime.Proc.uuid()

    Agent.update(FakeM2Client.State, fn s ->
      %{
        s
        | pay_override: fn payload, order_id ->
            mch_order_id = payload["mchOrderId"]

            put_verify_default(
              order_id,
              {:ok,
               [
                 verify_item(mch_order_id, order_id, "SUCCESS", payload["amount"])
                 |> Map.delete("currency")
               ]}
            )

            early_ok_wh =
              Jason.encode!(%{
                "mchId" => @mch_id,
                "mchOrderId" => mch_order_id,
                "orderId" => order_id,
                "orderStatus" => "SUCCESS",
                "amount" => payload["amount"],
                "realAmount" => payload["amount"]
              })

            assert post_signed_webhook(build_conn(), early_ok_wh).status == 200
            {:ok, paid_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
            assert paid_ord.status == "paid"
            assert {:ok, 30} = TeamsAccess.check(paid_ord.billing_account_id)

            {:ok,
             %{
               order_id: order_id,
               checkout_url: "https://pay.m2square.test/checkout/#{order_id}",
               currency: "USD",
               raw_item: %{"orderId" => order_id, "currency" => "USD"}
             }}
          end
      }
    end)

    assert {:error, :m2square_pay_rejected} =
             PaidSignup.start(purchase_id_2, ec_signup_attrs(30), "https://teams.comma.test")

    mch_id_2 = Agent.get(FakeM2Client.State, &List.last(&1.pay_calls)["mchOrderId"])
    {:ok, final_2} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_id_2)
    assert final_2.status == "conflict_paid"
    assert {:error, :teams_subscription_required} = TeamsAccess.check(final_2.billing_account_id)
  end

  test "17. paid replay records different webhook bankId even when verifyStatus still returns primary bankId (Astra R2 #3)" do
    {org, mch_order_id, order} = provision_paid_m2_org(30)
    assert order.bank_id == "BANK_1"

    put_verify_default(
      order.provider_order_id,
      {:ok,
       [
         verify_item(mch_order_id, order.provider_order_id, "SUCCESS", order.locked_amount)
         |> Map.put("bankId", "BANK_1")
       ]}
    )

    replay_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => mch_order_id,
        "orderId" => order.provider_order_id,
        "orderStatus" => "SUCCESS",
        "amount" => order.locked_amount,
        "realAmount" => order.locked_amount,
        "currency" => order.currency,
        "bankId" => "BANK_REPLAY_B"
      })

    assert post_signed_webhook(build_conn(), replay_wh).status == 200
    assert post_signed_webhook(build_conn(), replay_wh).status == 200

    {:ok, updated} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert updated.bank_id == "BANK_1"
    assert updated.cycle_id == order.cycle_id
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)

    bank_replays =
      Enum.filter(updated.duplicate_events, &(&1["kind"] == "different_bank_id_replay"))

    assert length(bank_replays) == 1
    assert hd(bank_replays)["bank_id"] == "BANK_REPLAY_B"
  end

  test "18. _1 duplicate payment PAYING(0.00) -> SUCCESS(realAmount, mchFee) -> REVERSED preserves settled amounts (Astra R2 #4)" do
    {_org, mch_order_id, order} = provision_paid_m2_org(30)
    dup_mch_id = mch_order_id <> "_1"
    dup_provider_id = "M2DUP_PROG_1"
    locked_str = order.locked_amount

    # 1. PAYING with 0.00 realAmount
    put_verify_default(
      dup_provider_id,
      {:ok,
       [
         verify_item(dup_mch_id, dup_provider_id, "PAYING", Decimal.new("0.00"))
         |> Map.put("amount", locked_str)
         |> Map.put("realAmount", "0.00")
         |> Map.delete("mchFee")
       ]}
    )

    paying_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_mch_id,
        "orderId" => dup_provider_id,
        "orderStatus" => "PAYING",
        "amount" => locked_str,
        "realAmount" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), paying_wh).status == 200

    # 2. SUCCESS with real settled amount and mchFee
    put_verify_default(
      dup_provider_id,
      {:ok,
       [
         verify_item(dup_mch_id, dup_provider_id, "SUCCESS", order.locked_amount)
         |> Map.put("mchFee", "12.34")
       ]}
    )

    success_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_mch_id,
        "orderId" => dup_provider_id,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "mchFee" => "12.34",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), success_wh).status == 200

    # 3. REVERSED with 0.00 or unchanged realAmount must preserve settled real_amount & mch_fee
    put_verify_default(
      dup_provider_id,
      {:ok,
       [
         verify_item(dup_mch_id, dup_provider_id, "REVERSED", Decimal.new("0.00"))
         |> Map.put("amount", locked_str)
         |> Map.put("realAmount", "0.00")
       ]}
    )

    reversed_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_mch_id,
        "orderId" => dup_provider_id,
        "orderStatus" => "REVERSED",
        "amount" => locked_str,
        "realAmount" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), reversed_wh).status == 200

    %{entries: entries} = Ops.export_ledger_entries(currency: order.currency)
    exported = Enum.find(entries, &(&1.mch_order_id == mch_order_id))
    assert exported != nil

    dup_entry =
      Enum.find(exported.duplicate_events, &(&1["provider_order_id"] == dup_provider_id))

    assert dup_entry["order_status"] == "REVERSED"
    assert dup_entry["real_amount"] == locked_str
    assert dup_entry["mch_fee"] == "12.34"
    assert is_binary(dup_entry["reversed_at"])

    # Replaying identical REVERSED("0.00") a second time must never overwrite settled real_amount
    assert post_signed_webhook(build_conn(), reversed_wh).status == 200

    %{entries: entries_replayed} = Ops.export_ledger_entries(currency: order.currency)
    replayed_exported = Enum.find(entries_replayed, &(&1.mch_order_id == mch_order_id))

    dup_entry_replayed =
      Enum.find(
        replayed_exported.duplicate_events,
        &(&1["provider_order_id"] == dup_provider_id)
      )

    assert dup_entry_replayed["order_status"] == "REVERSED"
    assert dup_entry_replayed["real_amount"] == locked_str
    assert dup_entry_replayed["mch_fee"] == "12.34"
    assert dup_entry_replayed["reversed_at"] == dup_entry["reversed_at"]

    # Out-of-order: REVERSED("0.00") arrives first, then late SUCCESS(locked_str) backfills real_amount
    dup_ooo_mch = mch_order_id <> "_2"
    dup_ooo_prov = "M2DUP_PROG_2"

    put_verify_default(
      dup_ooo_prov,
      {:ok,
       [
         verify_item(dup_ooo_mch, dup_ooo_prov, "REVERSED", Decimal.new("0.00"))
         |> Map.put("amount", locked_str)
         |> Map.put("realAmount", "0.00")
         |> Map.delete("mchFee")
       ]}
    )

    ooo_rev_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_ooo_mch,
        "orderId" => dup_ooo_prov,
        "orderStatus" => "REVERSED",
        "amount" => locked_str,
        "realAmount" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), ooo_rev_wh).status == 200

    put_verify_default(
      dup_ooo_prov,
      {:ok,
       [
         verify_item(dup_ooo_mch, dup_ooo_prov, "SUCCESS", order.locked_amount)
         |> Map.put("mchFee", "9.99")
       ]}
    )

    ooo_ok_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_ooo_mch,
        "orderId" => dup_ooo_prov,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "mchFee" => "9.99",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), ooo_ok_wh).status == 200

    %{entries: entries_ooo} = Ops.export_ledger_entries(currency: order.currency)
    ooo_exported = Enum.find(entries_ooo, &(&1.mch_order_id == mch_order_id))

    dup_ooo =
      Enum.find(ooo_exported.duplicate_events, &(&1["provider_order_id"] == dup_ooo_prov))

    assert dup_ooo["order_status"] == "REVERSED"
    assert dup_ooo["real_amount"] == locked_str
    assert dup_ooo["mch_fee"] == "9.99"
  end

  test "19. concurrent Ops.record_offline_refund produces exactly one org audit row and preserves original metadata (Astra R2 #5)" do
    {org, mch_order_id, _order} = provision_paid_m2_org(30)

    tasks =
      for idx <- 1..4 do
        Task.async(fn ->
          Ops.record_offline_refund(mch_order_id, "ops-conc-#{idx}", "ticket-conc-#{idx}")
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, :infinity))
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # Exactly one non-idempotent winner and three idempotent replays
    assert Enum.count(results, &match?({:ok, %{idempotent: false}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{idempotent: true}}, &1)) == 3

    {:ok, refunded} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    assert refunded.status == "reversed"
    winner_operator = refunded.refund_metadata["operator"]
    winner_reason = refunded.refund_metadata["reason"]
    assert is_binary(winner_operator) and winner_operator != ""
    assert is_binary(winner_reason) and winner_reason != ""

    # Every caller sees the same winner's refund_metadata
    for {:ok, res} <- results do
      assert res.refund_metadata["operator"] == winner_operator
      assert res.refund_metadata["reason"] == winner_reason
    end

    [[audit_count]] =
      Ecto.Adapters.SQL.query!(
        BridgeForTeams.Repo,
        """
        SELECT COUNT(*) FROM audit_logs
        WHERE org_id = $1
          AND action = 'billing.m2square.offline_refund'
          AND resource_id = $2
        """,
        [Ecto.UUID.dump!(org.id), mch_order_id]
      ).rows

    assert audit_count == 1
  end

  test "20. Ops.list_stripe_overlap_conflicts keyset-paginates 101 conflicts completely and excludes resolved entries (Astra R2 #6)" do
    {org, _mch_order_id, order} = provision_paid_m2_org(30)
    base_ts = SystemsClock.utc_now()

    # Seed 101 conflicts with intentional timestamp ties to verify (recorded_at, invoice_id) tie-breaking
    conflicts_101 =
      for i <- 1..101 do
        inv_num = i |> Integer.to_string() |> String.pad_leading(3, "0")
        # Pairwise timestamp ties every 2 items
        ts = DateTime.add(base_ts, div(i, 2), :second) |> DateTime.to_iso8601()

        %{
          "billing_account_id" => org.billing_account_id,
          "subscription_id" => "sub_overlap_101",
          "invoice_id" => "in_ov_#{inv_num}",
          "event_id" => "evt_ov_#{inv_num}",
          "recorded_at" => ts
        }
      end

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_subscriptions
      SET source_metadata = jsonb_set(
        COALESCE(source_metadata, '{}'::jsonb),
        '{stripe_overlap_conflicts}',
        $2::jsonb,
        true
      )
      WHERE id = $1
      """,
      [order.subscription_id, conflicts_101]
    )

    # Page 1: 50 items
    %{entries: p1, next_cursor: c1} =
      Ops.list_stripe_overlap_conflicts(billing_account_id: org.billing_account_id, limit: 50)

    assert length(p1) == 50
    assert is_binary(c1)

    # Page 2: 50 items
    %{entries: p2, next_cursor: c2} =
      Ops.list_stripe_overlap_conflicts(
        billing_account_id: org.billing_account_id,
        limit: 50,
        after_cursor: c1
      )

    assert length(p2) == 50
    assert is_binary(c2)

    # Page 3: 1 item, no next_cursor
    %{entries: p3, next_cursor: c3} =
      Ops.list_stripe_overlap_conflicts(
        billing_account_id: org.billing_account_id,
        limit: 50,
        after_cursor: c2
      )

    assert length(p3) == 1
    assert c3 == nil

    all_ids = Enum.map(p1 ++ p2 ++ p3, & &1["invoice_id"])
    assert length(all_ids) == 101
    assert length(Enum.uniq(all_ids)) == 101

    # Resolve one conflict -> excluded from default listing, visible with include_resolved: true
    assert {:ok, %{idempotent: false, conflict: resolved}} =
             Ops.resolve_stripe_overlap_conflict(
               org.billing_account_id,
               "in_ov_001",
               "ops-fin",
               "Refunded in Stripe dashboard"
             )

    assert resolved["resolved"] == true
    assert resolved["resolved_by"] == "ops-fin"
    assert resolved["resolution_note"] == "Refunded in Stripe dashboard"
    assert is_binary(resolved["resolved_at"])

    # Idempotent re-resolve
    assert {:ok, %{idempotent: true}} =
             Ops.resolve_stripe_overlap_conflict(
               org.billing_account_id,
               "in_ov_001",
               "ops-other",
               "duplicate"
             )

    assert %{entries: []} =
             Ops.list_stripe_overlap_conflicts(
               billing_account_id: org.billing_account_id,
               invoice_id: "in_ov_001"
             )

    assert %{entries: [found_resolved]} =
             Ops.list_stripe_overlap_conflicts(
               billing_account_id: org.billing_account_id,
               invoice_id: "in_ov_001",
               include_resolved: true
             )

    assert found_resolved["resolved"] == true
    assert found_resolved["resolved_by"] == "ops-fin"
  end

  test "21. unified currency-mismatch rule quarantines FAILED webhook and revokes already-paid order on later explicit mismatch (Astra R3 #1)" do
    # 21a: ECS order receives signed FAILED webhook with explicit "currency" => "PEN" ->
    # persistently quarantined -> later currency-less SUCCESS lands in conflict_paid with no seats/org.
    purchase_id_a = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_a}} =
             PaidSignup.start(purchase_id_a, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, ord_a} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_a)
    assert ord_a.currency == "ECS"

    put_verify_default(
      ord_a.provider_order_id,
      {:ok, [verify_item(mch_a, ord_a.provider_order_id, "FAILED", ord_a.locked_amount)]}
    )

    failed_mismatch_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => mch_a,
        "orderId" => ord_a.provider_order_id,
        "orderStatus" => "FAILED",
        "currency" => "PEN"
      })

    assert post_signed_webhook(build_conn(), failed_mismatch_wh).status == 200
    {:ok, q_a} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_a)
    assert q_a.status == "quarantined"

    # Later currency-less SUCCESS must be blocked by quarantine -> conflict_paid, no seats, no org
    put_verify_default(
      ord_a.provider_order_id,
      {:ok,
       [
         verify_item(mch_a, ord_a.provider_order_id, "SUCCESS", ord_a.locked_amount)
         |> Map.delete("currency")
       ]}
    )

    late_ok_a =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => mch_a,
        "orderId" => ord_a.provider_order_id,
        "orderStatus" => "SUCCESS",
        "amount" => ord_a.locked_amount,
        "realAmount" => ord_a.locked_amount
      })

    assert post_signed_webhook(build_conn(), late_ok_a).status == 200
    {:ok, final_a} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_a)
    assert final_a.status == "conflict_paid"
    assert {:error, :teams_subscription_required} = TeamsAccess.check(final_a.billing_account_id)
    assert {:error, :not_found} = Orgs.get_org(purchase_id_a)

    # 21b: ECS order is first settled to "paid" via currency-less return verifyStatus ->
    # later signed SUCCESS webhook explicitly reports "currency" => "PEN" ->
    # payment source is immediately revoked and order transitions to "conflict_paid".
    purchase_id_b = SystemsRuntime.Proc.uuid()

    assert {:ok, %{"mch_order_id" => mch_b}} =
             PaidSignup.start(purchase_id_b, ec_signup_attrs(30), "https://teams.comma.test")

    {:ok, ord_b} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_b)

    put_verify_default(
      ord_b.provider_order_id,
      {:ok,
       [
         verify_item(mch_b, ord_b.provider_order_id, "SUCCESS", ord_b.locked_amount)
         |> Map.delete("currency")
       ]}
    )

    assert :ok = PaidSignup.check_m2square_signup_return(purchase_id_b, mch_b)

    {:ok, paid_b} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_b)
    assert paid_b.status == "paid"
    assert {:ok, 30} = TeamsAccess.check(paid_b.billing_account_id)

    # Signed SUCCESS webhook arrives later with explicit wrong currency "PEN"
    mismatch_replay_b =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => mch_b,
        "orderId" => ord_b.provider_order_id,
        "orderStatus" => "SUCCESS",
        "amount" => ord_b.locked_amount,
        "realAmount" => ord_b.locked_amount,
        "currency" => "PEN"
      })

    assert post_signed_webhook(build_conn(), mismatch_replay_b).status == 200
    {:ok, final_b} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_b)
    assert final_b.status == "conflict_paid"
    assert {:error, :teams_subscription_required} = TeamsAccess.check(final_b.billing_account_id)
  end

  test "22. duplicate payment ignores non-settled placeholder mchFee/realAmount and preserves real zero mchFee on settled SUCCESS (Astra R3 #2)" do
    {_org, mch_order_id, order} = provision_paid_m2_org(30)
    locked_str = order.locked_amount

    # 22a: _1 receives PAYING with placeholder mchFee "0.00" & realAmount "0.00" ->
    # first SUCCESS omits mchFee -> exported mch_fee is nil (NOT "0.00") ->
    # subsequent settled SUCCESS reports mchFee "12.34" -> exported mch_fee becomes "12.34".
    dup_1_mch = mch_order_id <> "_1"
    dup_1_prov = "M2DUP_R3_1"

    put_verify_default(
      dup_1_prov,
      {:ok,
       [
         verify_item(dup_1_mch, dup_1_prov, "PAYING", Decimal.new("0.00"))
         |> Map.put("amount", locked_str)
         |> Map.put("realAmount", "0.00")
         |> Map.put("mchFee", "0.00")
       ]}
    )

    paying_1_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_1_mch,
        "orderId" => dup_1_prov,
        "orderStatus" => "PAYING",
        "amount" => locked_str,
        "realAmount" => "0.00",
        "mchFee" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), paying_1_wh).status == 200

    put_verify_default(
      dup_1_prov,
      {:ok,
       [
         verify_item(dup_1_mch, dup_1_prov, "SUCCESS", order.locked_amount)
         |> Map.delete("mchFee")
       ]}
    )

    success_1_no_fee_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_1_mch,
        "orderId" => dup_1_prov,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), success_1_no_fee_wh).status == 200

    %{entries: entries_mid} = Ops.export_ledger_entries(currency: order.currency)
    mid_entry = Enum.find(entries_mid, &(&1.mch_order_id == mch_order_id))
    dup_1_mid = Enum.find(mid_entry.duplicate_events, &(&1["provider_order_id"] == dup_1_prov))
    assert dup_1_mid["order_status"] == "SUCCESS"
    assert dup_1_mid["real_amount"] == locked_str
    assert dup_1_mid["mch_fee"] == nil

    # Subsequent settled SUCCESS supplies mchFee "12.34" -> backfilled!
    put_verify_default(
      dup_1_prov,
      {:ok,
       [
         verify_item(dup_1_mch, dup_1_prov, "SUCCESS", order.locked_amount)
         |> Map.put("mchFee", "12.34")
       ]}
    )

    success_1_with_fee_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_1_mch,
        "orderId" => dup_1_prov,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "mchFee" => "12.34",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), success_1_with_fee_wh).status == 200

    %{entries: entries_after} = Ops.export_ledger_entries(currency: order.currency)
    after_entry = Enum.find(entries_after, &(&1.mch_order_id == mch_order_id))

    dup_1_after =
      Enum.find(after_entry.duplicate_events, &(&1["provider_order_id"] == dup_1_prov))

    assert dup_1_after["mch_fee"] == "12.34"

    # 22b: _2 receives settled SUCCESS with explicit real zero fee "0.00" ->
    # subsequent REVERSED without mchFee preserves confirmed "0.00".
    dup_2_mch = mch_order_id <> "_2"
    dup_2_prov = "M2DUP_R3_2"

    put_verify_default(
      dup_2_prov,
      {:ok,
       [
         verify_item(dup_2_mch, dup_2_prov, "SUCCESS", order.locked_amount)
         |> Map.put("mchFee", "0.00")
       ]}
    )

    success_2_zero_fee_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_2_mch,
        "orderId" => dup_2_prov,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "mchFee" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), success_2_zero_fee_wh).status == 200

    put_verify_default(
      dup_2_prov,
      {:ok,
       [
         verify_item(dup_2_mch, dup_2_prov, "REVERSED", order.locked_amount)
         |> Map.delete("mchFee")
       ]}
    )

    reversed_2_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_2_mch,
        "orderId" => dup_2_prov,
        "orderStatus" => "REVERSED",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), reversed_2_wh).status == 200

    %{entries: entries_final} = Ops.export_ledger_entries(currency: order.currency)
    final_entry = Enum.find(entries_final, &(&1.mch_order_id == mch_order_id))

    dup_2_final =
      Enum.find(final_entry.duplicate_events, &(&1["provider_order_id"] == dup_2_prov))

    assert dup_2_final["order_status"] == "REVERSED"
    assert dup_2_final["real_amount"] == locked_str
    assert dup_2_final["mch_fee"] == "0.00"

    # 22c: _3 receives late signed PAYING webhook carrying placeholder mchFee "0.00" while
    # verifyStatus already reports SUCCESS (without mchFee) -> mch_fee stays nil ->
    # subsequent SUCCESS webhook with mchFee "12.34" backfills "12.34" (Astra R4 #2).
    dup_3_mch = mch_order_id <> "_3"
    dup_3_prov = "M2DUP_R4_3"

    put_verify_default(
      dup_3_prov,
      {:ok,
       [
         verify_item(dup_3_mch, dup_3_prov, "SUCCESS", order.locked_amount)
         |> Map.delete("mchFee")
       ]}
    )

    late_paying_3_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_3_mch,
        "orderId" => dup_3_prov,
        "orderStatus" => "PAYING",
        "amount" => locked_str,
        "realAmount" => "0.00",
        "mchFee" => "0.00",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), late_paying_3_wh).status == 200

    %{entries: entries_3_mid} = Ops.export_ledger_entries(currency: order.currency)
    mid_3_entry = Enum.find(entries_3_mid, &(&1.mch_order_id == mch_order_id))

    dup_3_mid =
      Enum.find(mid_3_entry.duplicate_events, &(&1["provider_order_id"] == dup_3_prov))

    assert dup_3_mid["order_status"] == "SUCCESS"
    assert dup_3_mid["real_amount"] == locked_str
    assert dup_3_mid["mch_fee"] == nil

    success_3_fee_wh =
      Jason.encode!(%{
        "mchId" => @mch_id,
        "mchOrderId" => dup_3_mch,
        "orderId" => dup_3_prov,
        "orderStatus" => "SUCCESS",
        "amount" => locked_str,
        "realAmount" => locked_str,
        "mchFee" => "12.34",
        "currency" => order.currency
      })

    assert post_signed_webhook(build_conn(), success_3_fee_wh).status == 200

    %{entries: entries_3_final} = Ops.export_ledger_entries(currency: order.currency)
    final_3_entry = Enum.find(entries_3_final, &(&1.mch_order_id == mch_order_id))

    dup_3_final =
      Enum.find(final_3_entry.duplicate_events, &(&1["provider_order_id"] == dup_3_prov))

    assert dup_3_final["order_status"] == "SUCCESS"
    assert dup_3_final["mch_fee"] == "12.34"
  end

  # ---- Helpers ----

  test "renewal uses the Settings quote across FX drift until the one-hour deadline" do
    {org, _, _} = provision_paid_m2_org(30)
    {:ok, owner} = Accounts.get_user_by_email("ec-buyer@example.com")
    billing = settings_billing(org, owner)
    token = billing["quote_token"]
    assert billing["quote_ttl_seconds"] == 3_600

    profile =
      log_in_user(build_conn(), owner)
      |> patch("/dashboard/api/v1/orgs/#{org.slug}/settings/general", %{"name" => "Renamed Team"})
      |> json_response(200)

    assert profile["data"]["organization"]["name"] == "Renamed Team"
    assert profile["data"]["billing"]["quote_token"] == nil
    assert profile["data"]["billing"]["quote_ttl_seconds"] == nil

    SystemsClock.advance(3_599_000)
    FX.clear_cache()
    SystemsRuntime.Test.put_env(:bridge_for_teams_core, :contract_brl_rate, "0.40")
    fresh = settings_billing(org, owner)
    br = Enum.find(fresh["m2square_countries"], &(&1["code"] == "BR"))
    assert Decimal.equal?(Decimal.new(br["fx_rate"]), Decimal.new("0.40"))

    path = "/dashboard/api/v1/orgs/#{org.slug}/settings/billing/renew"
    attrs = Map.put(br_renewal_attrs(30), "quote_token", token)
    count_before = length(Agent.get(FakeM2Client.State, & &1.pay_calls))
    assert json_response(post(log_in_user(build_conn(), owner), path, attrs), 200)["data"]["url"]
    assert Agent.get(FakeM2Client.State, &List.last(&1.pay_calls))["amount"] == "37500.00"

    SystemsClock.advance(1_000)
    expired = post(log_in_user(build_conn(), owner), path, attrs)
    assert json_response(expired, 422)["error"]["code"] == "quote_expired"
    assert length(Agent.get(FakeM2Client.State, & &1.pay_calls)) == count_before + 1
  end

  test "Console restrictions reject new quoted orders and preserve in-flight settlement" do
    update_console_country("EC", %{"payment_types" => ["NET_BANKING", "CASH"]})
    purchase_id = SystemsRuntime.Proc.uuid()

    attrs =
      Map.merge(ec_signup_attrs(30), %{
        "beneficiary_type" => "CI",
        "beneficiary_id" => "1234567890"
      })

    base = "https://teams.comma.test"
    {:ok, window} = QuoteToken.prepare_payment_window("signup:" <> purchase_id, 100)

    assert {:ok, %{"mch_order_id" => order_id}} =
             PaidSignup.start_with_quote(purchase_id, attrs, window.token, base)

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, order_id)
    another = SystemsRuntime.Proc.uuid()
    {:ok, next} = QuoteToken.prepare_payment_window("signup:" <> another, 100)

    update_console_country("EC", %{"payment_types" => ["CASH"]})

    assert {:error, {:payer_invalid, :unsupported_payment_type}} =
             PaidSignup.start_with_quote(another, attrs, next.token, base)

    update_console_country("EC", %{"enabled" => false})

    assert {:error, :m2square_country_unavailable} =
             PaidSignup.start_with_quote(another, attrs, next.token, base)

    provider_id = order.provider_order_id

    put_verify_default(
      provider_id,
      {:ok, [verify_item(order_id, provider_id, "SUCCESS", order.locked_amount)]}
    )

    assert post_signed_webhook(build_conn(), success_webhook_json(order_id, provider_id, order)).status ==
             200

    {:ok, org} = Orgs.get_org(purchase_id)
    assert {:ok, 30} = TeamsAccess.check(org.billing_account_id)

    put_verify_default(
      provider_id,
      {:ok, [verify_item(order_id, provider_id, "REVERSED", order.locked_amount)]}
    )

    reversal =
      order_id
      |> success_webhook_json(provider_id, order)
      |> Jason.decode!()
      |> Map.put("orderStatus", "REVERSED")
      |> Jason.encode!()

    assert post_signed_webhook(build_conn(), reversal).status == 200
    assert {:error, :teams_subscription_required} = TeamsAccess.check(org.billing_account_id)
  end

  test "Settings general aligns 40-seat floor, skips Console/FX when ineligible or saving profile, disables renewal without quote, and bounds Stripe seats" do
    {org, initial_mch_order_id, _order} = provision_paid_m2_org(30)
    {:ok, owner} = Accounts.get_user_by_email("ec-buyer@example.com")

    # 1. Raise licensed seats on active M2square cycle to 40 -> min_m2_seats = 40
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE billing_subscription_cycles
      SET source_metadata = jsonb_set(
        source_metadata,
        '{payment_sources}',
        (
          SELECT jsonb_object_agg(k, jsonb_set(v, '{teams_seats}', '40'::jsonb))
          FROM jsonb_each(source_metadata->'payment_sources') AS e(k, v)
        )
      )
      WHERE billing_account_id = $1
      """,
      [org.billing_account_id]
    )

    billing_40 = settings_billing(org, owner)
    assert billing_40["can_renew_m2square"] == true
    assert is_binary(billing_40["quote_token"])
    # At FakeFX rates (PE=43, BR=40, EC=39, CL=33), EC and CL are dropped while PE and BR remain
    assert Enum.map(billing_40["m2square_countries"], & &1["code"]) == ["PE", "BR"]
    [pe, br] = billing_40["m2square_countries"]
    assert pe["min_seats"] == 40
    assert pe["max_seats"] == 43
    assert br["min_seats"] == 40
    assert br["max_seats"] == 40

    {:ok, pe_cfg} = BridgeForTeams.M2square.Config.country("PE")

    {:ok, expected_40} =
      BridgeForTeams.M2square.Pricing.quote_order(pe_cfg, 40, Decimal.new("0.27"), "0")

    assert pe["sample_min_amount"] == expected_40.formatted_amount

    pe_renewal_base = %{
      "provider" => "m2square",
      "country" => "PE",
      "payment_type" => "NET_BANKING",
      "firstname" => "Ana",
      "lastname" => "Perez",
      "email" => "ana@acme.test",
      "phone" => "987654321",
      "beneficiary_type" => "DNI",
      "beneficiary_id" => "12345678"
    }

    assert {:error, {:invalid_seats_range, 40, 43}} =
             PaidSignup.renew_with_quote(
               org,
               Map.put(pe_renewal_base, "seats", "30"),
               billing_40["quote_token"],
               "https://teams.comma.test"
             )

    assert {:ok, %{"mch_order_id" => renew_40_id}} =
             PaidSignup.renew_with_quote(
               org,
               Map.put(pe_renewal_base, "seats", "40"),
               billing_40["quote_token"],
               "https://teams.comma.test"
             )

    # Settle the early renewal so the org now has a future paid cycle (no longer eligible to renew)
    {:ok, renew_40_ord} = Orders.get_by_mch_order_id(BillingCore.Repo, renew_40_id)

    put_verify_default(
      renew_40_ord.provider_order_id,
      {:ok,
       [
         verify_item(
           renew_40_id,
           renew_40_ord.provider_order_id,
           "SUCCESS",
           renew_40_ord.locked_amount
         )
       ]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(renew_40_id, renew_40_ord.provider_order_id, renew_40_ord)
           ).status == 200

    # 2. Verify zero Salix settings reads and zero FX calls on PATCH /settings/general and ineligible GET ?m2_order=
    {:ok, counter} = Agent.start_link(fn -> %{salix: 0, fx: 0} end)
    orig_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    orig_m2 = SystemsRuntime.get_env(:bridge_for_teams_core, :m2square)

    defmodule ZeroCallSalixClient do
      def get_m2square_settings do
        c = SystemsRuntime.get_env(:bridge_for_teams_core, :zero_call_counter)
        Agent.update(c, &%{&1 | salix: &1.salix + 1})
        orig = SystemsRuntime.get_env(:bridge_for_teams_core, :zero_call_orig_client)
        orig.get_m2square_settings()
      end
    end

    defmodule ZeroCallFX do
      @behaviour BridgeForTeams.M2square.FX.Provider

      @impl true
      def fetch_usd_base_rates(currencies, opts) do
        c = SystemsRuntime.get_env(:bridge_for_teams_core, :zero_call_counter)
        Agent.update(c, &%{&1 | fx: &1.fx + 1})

        BridgeForTeamsWeb.M2squareTeamsPaymentContractTest.FakeFX.fetch_usd_base_rates(
          currencies,
          opts
        )
      end
    end

    SystemsRuntime.put_env(:bridge_for_teams_core, :zero_call_counter, counter)
    SystemsRuntime.put_env(:bridge_for_teams_core, :zero_call_orig_client, orig_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, ZeroCallSalixClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :m2square,
      Map.put(orig_m2, :fx_provider, ZeroCallFX)
    )

    FX.clear_cache()

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, orig_client)
      SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, orig_m2)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :zero_call_counter)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :zero_call_orig_client)
    end)

    patch_resp =
      log_in_user(build_conn(), owner)
      |> put_req_header("content-type", "application/json")
      |> patch("/dashboard/api/v1/orgs/#{org.slug}/settings/general", %{"name" => "Renamed Acme"})

    assert json_response(patch_resp, 200)["data"]["billing"]["m2square_countries"] == []

    ineligible_get =
      log_in_user(build_conn(), owner)
      |> get("/dashboard/api/v1/orgs/#{org.slug}/settings/general?m2_order=#{renew_40_id}")

    ineligible_billing = json_response(ineligible_get, 200)["data"]["billing"]
    assert ineligible_billing["can_renew_stripe"] == false
    assert ineligible_billing["can_renew_m2square"] == false
    assert ineligible_billing["m2square_countries"] == []
    assert ineligible_billing["quote_token"] == nil

    assert %{salix: 0, fx: 0} == Agent.get(counter, & &1)

    # Restore normal client/FX for remaining checks
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, orig_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :m2square, orig_m2)

    # 3. Missing quote_signing_secret on expired org with Stripe customer disables renewal but keeps Portal
    {:ok, _} = Ops.record_offline_refund(renew_40_id, "ops-test", "expire-future")
    {:ok, _} = Ops.record_offline_refund(initial_mch_order_id, "ops-test", "expire-initial")

    {:ok, _} =
      BillingStripe.ensure_customer(%{
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: org.id,
        display_name: org.name,
        actor_type: "test",
        actor_id: org.id
      })

    orig_secret = SystemsRuntime.get_env(:bridge_for_teams_core, :quote_signing_secret)
    SystemsRuntime.put_env(:bridge_for_teams_core, :quote_signing_secret, "short")

    on_exit(fn ->
      if orig_secret,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :quote_signing_secret, orig_secret)
    end)

    no_quote_billing = settings_billing(org, owner)
    assert no_quote_billing["can_renew_stripe"] == false
    assert no_quote_billing["can_renew_m2square"] == false
    assert no_quote_billing["m2square_countries"] == []
    assert no_quote_billing["quote_token"] == nil
    assert no_quote_billing["has_stripe_customer"] == true

    # 4. Restore secret and verify Stripe > 2_147_483_647 returns {:invalid_seats_range, 100, 2_147_483_647}
    SystemsRuntime.put_env(:bridge_for_teams_core, :quote_signing_secret, orig_secret)
    valid_billing = settings_billing(org, owner)
    assert valid_billing["can_renew_stripe"] == true

    assert {:error, {:invalid_seats_range, 100, 2_147_483_647}} =
             PaidSignup.renew_with_quote(
               org,
               %{"seats" => "2147483648"},
               valid_billing["quote_token"],
               "https://teams.comma.test"
             )
  end

  defp settings_billing(org, owner) do
    conn =
      get(log_in_user(build_conn(), owner), "/dashboard/api/v1/orgs/#{org.slug}/settings/general")

    json_response(conn, 200)["data"]["billing"]
  end

  defp update_console_country(code, attrs) do
    {:ok, %{countries: countries, etag: etag}} = M2squareSettings.get_for_admin()
    countries = Map.update!(countries, code, &Map.merge(&1, attrs))
    assert {:ok, {:saved, _, _}} = M2squareSettings.put(countries, etag)
  end

  defp provision_paid_m2_org(seats) do
    purchase_id = SystemsRuntime.Proc.uuid()

    {:ok, %{"mch_order_id" => mch_order_id}} =
      PaidSignup.start(purchase_id, ec_signup_attrs(seats), "https://teams.comma.test")

    {:ok, order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)

    put_verify_default(
      order.provider_order_id,
      {:ok, [verify_item(mch_order_id, order.provider_order_id, "SUCCESS", order.locked_amount)]}
    )

    assert post_signed_webhook(
             build_conn(),
             success_webhook_json(mch_order_id, order.provider_order_id, order)
           ).status == 200

    {:ok, org} = Orgs.get_org(purchase_id)
    {:ok, paid_order} = Orders.get_by_mch_order_id(BillingCore.Repo, mch_order_id)
    {org, mch_order_id, paid_order}
  end

  defp insert_historical_stripe_cycle!(org) do
    now = SystemsClock.utc_now()
    old_start = now
    old_end = DateTime.add(now, 86_400, :second)

    {:ok, sub_res} =
      BillingCommerce.Subscriptions.create_subscription(%{
        billing_account_id: org.billing_account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: org.id,
        package_code: TeamsPricing.package(),
        package_version: TeamsPricing.version(),
        source_type: "stripe_subscription",
        source_id: "sub_hist_1",
        source_event_id: "in_hist_1",
        idempotency_key: "stripe:subscription:sub_hist_1",
        periods: [
          %{
            cycle_key: "in_hist_1",
            valid_from: old_start,
            expires_at: old_end,
            source_event_id: "in_hist_1"
          }
        ]
      })

    {:ok, package} =
      BillingCommerce.PackageCatalog.get_package_version(%{
        package_code: TeamsPricing.package(),
        version: TeamsPricing.version()
      })

    {:ok, _} =
      BillingCommerce.PaidCycles.record_invoice(
        sub_res.subscription,
        package,
        "in_hist_1",
        %{
          valid_from: old_start,
          expires_at: old_end,
          payment_intent_id: "pi_hist_1",
          fully_refunded: false,
          disputes: %{},
          teams_seats: 100
        },
        old_start
      )

    {:ok, _} =
      BillingCommerce.Subscriptions.set_provider_subscription_status(%{
        source_id: "sub_hist_1",
        status: "canceled",
        source_event_id: "evt_hist_cancel",
        source_metadata: %{}
      })

    # Advance 2 days so the historical Stripe cycle is expired while the 3-month M2 cycle stays active
    SystemsClock.advance(2 * 86_400_000)
  end

  defp historical_stripe_source_state(account_id) do
    %{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT c.source_metadata->'payment_sources'->'in_hist_1'->>'state'
        FROM billing_subscription_cycles c
        WHERE c.billing_account_id = $1 AND c.cycle_key = 'in_hist_1'
        """,
        [account_id]
      )

    state
  end

  defp paid_cycle_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT count(*)
        FROM billing_subscription_cycles c
        CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
        WHERE c.billing_account_id = $1
          AND p.value->>'state' = 'paid'
          AND (p.value->>'teams_seats')::bigint > 0
        """,
        [account_id]
      )

    count
  end

  defp verify_item(mch_order_id, provider_order_id, status, amount) do
    %{
      "mchOrderId" => mch_order_id,
      "orderId" => provider_order_id,
      "orderType" => "PAYMENT",
      "orderStatus" => status,
      "amount" => Decimal.new(amount),
      "realAmount" => Decimal.new(amount),
      "mchFee" => Decimal.new("10.00"),
      "bankId" => "BANK_1"
    }
  end

  defp success_webhook_json(mch_order_id, provider_order_id, order) do
    Jason.encode!(%{
      "mchOrderId" => mch_order_id,
      "orderId" => provider_order_id,
      "orderType" => "PAYMENT",
      "orderStatus" => "SUCCESS",
      "currency" => order.currency,
      "amount" => order.locked_amount,
      "realAmount" => order.locked_amount
    })
  end

  defp put_verify_default(provider_order_id, result) do
    Agent.update(FakeM2Client.State, fn state ->
      %{state | verify_default: Map.put(state.verify_default, provider_order_id, result)}
    end)
  end

  defp put_verify_queue(provider_order_id, results) do
    Agent.update(FakeM2Client.State, fn state ->
      %{state | verify_queues: Map.put(state.verify_queues, provider_order_id, results)}
    end)
  end

  defp sign_body(raw_body) do
    :crypto.hash(:sha512, [raw_body, @secret_key])
    |> Base.encode16(case: :lower)
  end

  defp post_signed_webhook(conn, raw_body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("sign", sign_body(raw_body))
    |> post("/v1/billing/m2square/webhook", raw_body)
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

  defp br_signup_attrs(seats) do
    %{
      "provider" => "m2square",
      "country" => "BR",
      "payment_type" => "PIX",
      "seats" => seats,
      "email" => "br-buyer@example.com",
      "name" => "Ana Silva",
      "org_name" => "BR Team",
      "firstname" => "Ana",
      "lastname" => "Silva",
      "phone" => "+5511999999999",
      "doc_number" => "12345678909"
    }
  end

  defp ec_signup_attrs(seats) do
    %{
      "provider" => "m2square",
      "country" => "EC",
      "payment_type" => "NET_BANKING",
      "seats" => seats,
      "email" => "ec-buyer@example.com",
      "name" => "Carlos Perez",
      "org_name" => "EC Team",
      "firstname" => "Carlos",
      "lastname" => "Perez",
      "phone" => "987654321",
      "beneficiary_type" => "CI",
      "beneficiary_id" => "1710034065"
    }
  end

  defp ec_renewal_attrs(seats) do
    %{
      "provider" => "m2square",
      "country" => "EC",
      "payment_type" => "NET_BANKING",
      "seats" => seats,
      "email" => "ec-buyer@example.com",
      "firstname" => "Carlos",
      "lastname" => "Perez",
      "phone" => "987654321",
      "beneficiary_type" => "CI",
      "beneficiary_id" => "1710034065"
    }
  end

  defp br_renewal_attrs(seats) do
    %{
      "provider" => "m2square",
      "country" => "BR",
      "payment_type" => "PIX",
      "seats" => seats,
      "email" => "ec-buyer@example.com",
      "firstname" => "Ana",
      "lastname" => "Silva",
      "phone" => "+5511999999999",
      "doc_number" => "12345678909"
    }
  end

  defp script_stripe_payment(invoice_id, subscription_id) do
    checkout = Agent.get(FakeStripeAPI.State, & &1.checkout)
    starts = DateTime.to_unix(SystemsClock.utc_now())
    ends = DateTime.to_unix(DateTime.shift(DateTime.from_unix!(starts), month: 3))

    script_stripe_payment_with_metadata(
      invoice_id,
      subscription_id,
      checkout.subscription_data.metadata,
      starts,
      ends
    )
  end

  defp script_stripe_payment_with_metadata(invoice_id, subscription_id, metadata, starts, ends) do
    sub = %{
      "id" => subscription_id,
      "status" => "active",
      "customer" => "cus_m2_to_stripe",
      "metadata" => metadata,
      "latest_invoice" => invoice_id
    }

    invoice = %{
      "id" => invoice_id,
      "object" => "invoice",
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{
          "subscription" => subscription_id,
          "metadata" => metadata
        }
      },
      "customer" => "cus_m2_to_stripe",
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
      FakeStripeAPI.State,
      &Map.merge(&1, %{subscription: sub, invoice: invoice, payment: payment})
    )
  end

  defp send_stripe_webhook(id) do
    invoice = Agent.get(FakeStripeAPI.State, & &1.invoice)

    payload =
      Jason.encode!(%{
        "id" => id,
        "object" => "event",
        "type" => "invoice.paid",
        "created" => DateTime.to_unix(SystemsClock.utc_now()),
        "data" => %{"object" => invoice}
      })

    timestamp = DateTime.to_unix(SystemsClock.utc_now())

    signature =
      :crypto.mac(:hmac, :sha256, "whsec_local", "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    BillingStripe.handle_webhook(payload, "t=#{timestamp},v1=#{signature}", tolerance: 31_536_000)
  end
end
