defmodule BridgeForTeamsWeb.Dashboard.TeamsSignupPageTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test, scope: ["Elixir.BridgeForTeamsWeb"]

  alias Salix.Control.M2squareSettings
  alias SalixStore.{Keys, S3}

  @order "abcdefghijklmnopqrstuvwx"

  defmodule Checkout do
    def start_with_quote(purchase_id, params, token, base_url) do
      send(self(), {:start, purchase_id, params, token, base_url})

      case params do
        %{"phone" => "+5930123456"} ->
          {:error, {:payer_invalid, :invalid_phone}}

        %{"seats" => "49"} ->
          {:error, {:invalid_seats_range, 30, 39}}

        %{"seats" => "50"} ->
          SystemsClock.advance(1_000)
          {:error, {:invalid_seats_range, 30, 39}}

        _ ->
          {:ok, %{"url" => "https://checkout.example.test/teams"}}
      end
    end

    def check_m2square_signup_return(purchase_id, order) do
      send(self(), {:check, purchase_id, order})
      {:error, :upstream_unavailable}
    end

    def purchase_state(purchase_id) do
      case result(purchase_id) do
        {:ok, org} -> {:settled_active, Map.put_new(org, :id, purchase_id)}
        {:error, _} -> :pending
      end
    end

    def result(purchase_id) do
      send(self(), {:result, purchase_id})
      {:error, :teams_signup_pending}
    end
  end

  setup do
    SystemsRuntime.Test.put_env(:bridge_for_teams_web, :paid_signup_mod, Checkout)
    SystemsRuntime.Test.put_env(:bridge_for_teams_core, :m2square, %{})
    on_exit(fn -> S3.delete(Keys.ctl_system_m2square_settings()) end)
    :ok
  end

  test "Stripe-only checkout has an accessible seat input and a signed payment window", %{
    conn: conn
  } do
    page = conn |> put_req_header("cf-ipcountry", "EC") |> get("/signup/teams") |> document()

    assert [_] = Floki.find(page, "#teams-checkout[data-ttl-seconds='3600']")
    assert [_] = Floki.find(page, "#stripe-signup-seats[value='100']:not([aria-describedby])")
    assert [_] = Floki.find(page, "#stripe-signup-seats-error[role=alert][hidden]")
    assert is_binary(quote_token(page))
    assert [] = Floki.find(page, "input[name='signup[provider]'], #show-local-payment")
  end

  test "Stripe is first and selected when the detected country supports local payment", %{
    conn: conn
  } do
    enable_ecuador()

    page =
      conn
      |> put_req_header("cf-ipcountry", "ec")
      |> get("/signup/teams?locale=zh_Hans")
      |> document()

    radios = Floki.find(page, "#teams-payment-channels:not([hidden]) input[type=radio]")
    assert Floki.attribute(radios, "value") == ["stripe", "m2square"]
    assert Floki.attribute(Floki.find(radios, "[checked]"), "value") == ["stripe"]
    assert [_] = Floki.find(page, "#stripe-signup-fields:not([hidden]) input[value='100']")
    assert [_] = Floki.find(page, "#local-signup-fields[hidden][disabled]")
    assert Floki.text(page) =~ "当地支付"
  end

  test "other visitors see the secondary local payment entry below the Stripe action", %{
    conn: conn
  } do
    enable_ecuador()

    page = conn |> put_req_header("cf-ipcountry", "US") |> get("/signup/teams") |> document()

    assert [_] = Floki.find(page, "#teams-payment-channels[hidden][disabled]")
    assert [_] = Floki.find(page, "#stripe-signup-fields:not([hidden]) input[value='100']")
    assert [_] = Floki.find(page, "form + div #show-local-payment:not([hidden])")
  end

  test "local checkout uses the existing purchase session and redirects to the provider", %{
    conn: conn
  } do
    enable_ecuador()
    conn = get(conn, "/signup/teams")
    purchase_id = get_session(conn, :teams_purchase_id)
    original_session = get_session(conn)
    signup = local_signup()
    token = quote_token(document(conn))

    conn = submit(conn, signup, token)

    assert redirected_to(conn) == "https://checkout.example.test/teams"
    assert_received {:start, ^purchase_id, ^signup, ^token, base_url}
    assert base_url =~ ~r{^https?://}
    assert get_session(conn, :teams_purchase_id) == original_session["teams_purchase_id"]
    assert get_session(conn, :teams_signup_email) == signup["email"]
  end

  test "local errors keep the chosen channel and safe values without echoing phone or document",
       %{
         conn: conn
       } do
    enable_ecuador()
    conn = get(conn, "/signup/teams")
    original_session = get_session(conn)
    token = quote_token(document(conn))
    SystemsClock.advance(10_000)

    for {override, message} <- [
          {%{"phone" => "+5930123456"},
           "Enter 6–9 local digits, without +593 or a leading zero."},
          {%{"seats" => "49"}, "Enter between 30 and 39 seats."}
        ] do
      signup = Map.merge(local_signup(), override)
      failed = submit(conn, signup, token)
      page = document(failed)

      assert [_] = Floki.find(page, "input[value='m2square'][checked]")
      assert [_] = Floki.find(page, "#local-signup-fields:not([disabled])")
      assert Floki.attribute(page, "input[name='signup[firstname]']", "value") == ["Ana"]
      assert Floki.text(Floki.find(page, "[role=alert]")) =~ message
      refute html_response(failed, 200) =~ signup["phone"]
      refute html_response(failed, 200) =~ signup["beneficiary_id"]
      assert get_session(failed) == original_session
      assert quote_token(page) == token
      assert [_] = Floki.find(page, "#teams-checkout[data-ttl-seconds='3590']")
    end
  end

  test "quote remains usable one second before expiry and locks the old page at expiry", %{
    conn: conn
  } do
    conn = get(conn, "/signup/teams")
    token = quote_token(document(conn))
    signup = Map.put(local_signup(), "seats", "100") |> Map.delete("provider")
    SystemsClock.advance(3_599_000)

    assert redirected_to(submit(conn, signup, token)) == "https://checkout.example.test/teams"
    assert_received {:start, _, _, ^token, _}
    SystemsClock.advance(1_000)

    assert_expired(submit(conn, signup, token))
    refute_received {:start, _, _, _, _}
  end

  test "a field error after the remaining window is consumed does not reissue the quote", %{
    conn: conn
  } do
    enable_ecuador()
    conn = get(conn, "/signup/teams")
    token = quote_token(document(conn))
    SystemsClock.advance(3_599_000)

    assert_expired(submit(conn, Map.put(local_signup(), "seats", "50"), token))
    assert_received {:start, _, _, ^token, _}
  end

  test "submitting without the purchase session shows the expired form", %{conn: conn} do
    token = conn |> get("/signup/teams") |> document() |> quote_token()
    assert_expired(submit(build_conn(), local_signup(), token))
    refute_received {:start, _, _, _, _}
  end

  defp assert_expired(conn) do
    page = document(conn)
    assert Floki.find(page, "#signup-quote-expired:not([hidden]) a[href='/signup/teams']") != []
    assert Floki.find(page, "#teams-checkout-submit[disabled]") != []
    assert Floki.find(page, "#teams-checkout-fields[disabled]") != []
    assert quote_token(page) == nil
  end

  defp submit(conn, signup, token),
    do: post(recycle(conn), "/signup/teams", %{"signup" => Map.put(signup, "quote_token", token)})

  defp quote_token(page),
    do: page |> Floki.attribute("input[name='signup[quote_token]']", "value") |> List.first()

  test "payment refresh checks the local order first and retains its ID in the link", %{
    conn: conn
  } do
    conn = get(conn, "/signup/teams")
    purchase_id = get_session(conn, :teams_purchase_id)
    path = "/signup/payment?" <> URI.encode_query(%{"m2_order" => @order, "p" => purchase_id})
    page = conn |> recycle() |> get(path) |> document()

    assert Enum.filter(elem(Process.info(self(), :messages), 1), fn message ->
             match?({:check, _, _}, message) or match?({:result, _}, message)
           end) == [{:check, purchase_id, @order}, {:result, purchase_id}]

    assert Floki.text(Floki.find(page, "a[href='#{path}']")) =~ "Check payment"
    assert Floki.text(page) =~ "after payment is confirmed"
  end

  test "invalid local order IDs are ignored and excluded from the refresh link", %{conn: conn} do
    conn = get(conn, "/signup/teams")
    purchase_id = get_session(conn, :teams_purchase_id)
    expected_href = "/signup/payment?" <> URI.encode_query(%{"p" => purchase_id})

    for query <- [
          "p=#{purchase_id}&m2_order=ABCDEFGHIJKLMNOPQRSTUVWX",
          "p=#{purchase_id}&m2_order[]=abcdefghijklmnopqrstuvwx"
        ] do
      page = conn |> recycle() |> get("/signup/payment?" <> query) |> document()

      refute_received {:check, _, _}
      assert_received {:result, ^purchase_id}
      assert Floki.text(Floki.find(page, "a[href='#{expected_href}']")) =~ "Check payment"
    end
  end

  defp document(conn), do: conn |> html_response(200) |> Floki.parse_document!()

  defp local_signup do
    %{
      "provider" => "m2square",
      "country" => "EC",
      "payment_type" => "NET_BANKING",
      "org_name" => "Acme",
      "email" => "ana@example.com",
      "name" => "Ana Vega",
      "seats" => "30",
      "firstname" => "Ana",
      "lastname" => "Vega",
      "phone" => "598011234",
      "beneficiary_type" => "PAS",
      "beneficiary_id" => "A012345678"
    }
  end

  defp enable_ecuador do
    SystemsRuntime.Test.put_env(:bridge_for_teams_core, :m2square, %{
      mch_id: "test-merchant",
      secret_key: "test-key"
    })

    countries =
      Map.put(M2squareSettings.default_all_disabled_countries(), "EC", %{
        "enabled" => true,
        "payment_types" => ["NET_BANKING"]
      })

    assert {:ok, {:saved, _, _}} =
             M2squareSettings.put(countries, M2squareSettings.unconfigured_etag())
  end
end
