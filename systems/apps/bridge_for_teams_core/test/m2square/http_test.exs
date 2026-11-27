defmodule BridgeForTeams.M2square.HTTPTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.M2square.HTTP
  alias BridgeForTeams.M2square.Signing

  defp base_config(plug) do
    %{
      base_url: "https://latinapi.m2square.test/gateway/base/biz",
      mch_id: "1416010331032883200",
      secret_key: "test-secret-key",
      req_options: [plug: plug]
    }
  end

  describe "pay/2" do
    test "signs exact raw_json sent over HTTP and validates https checkoutUrl" do
      plug = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/gateway/base/biz"
        assert Plug.Conn.get_req_header(conn, "method") == ["pay"]
        assert Plug.Conn.get_req_header(conn, "signtype") == ["SHA512"]
        assert Plug.Conn.get_req_header(conn, "servicename") == ["api.pay"]
        assert Plug.Conn.get_req_header(conn, "mchid") == ["1416010331032883200"]
        [timestamp] = Plug.Conn.get_req_header(conn, "timestamp")
        [sign] = Plug.Conn.get_req_header(conn, "sign")

        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

        expected_sign =
          Signing.sign_request(
            "1416010331032883200",
            "api.pay",
            "pay",
            timestamp,
            "SHA512",
            raw_body,
            "test-secret-key"
          )

        assert sign == expected_sign

        resp =
          Jason.encode!(%{
            "resultCode" => "000000",
            "errorCode" => "000000",
            "errorMsg" => nil,
            "data" => [
              %{
                "orderId" => "202611200001",
                "currency" => "BRL",
                "checkoutUrl" => "https://checkout.m2square.xyz/pay/abc123"
              }
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end

      assert {:ok, result} =
               HTTP.pay(
                 %{"mchOrderId" => "mttabcdefghijklmnopqrstu", "amount" => "37500.00"},
                 base_config(plug)
               )

      assert result.order_id == "202611200001"
      assert result.checkout_url == "https://checkout.m2square.xyz/pay/abc123"
      assert result.currency == "BRL"
    end

    test "rejects non-https checkoutUrl and bare-map, multi-element, or empty data as uncertain" do
      for {label, data_field, expected_reason} <- [
            {"http url", [%{"orderId" => "1", "checkoutUrl" => "http://insecure.example/pay"}],
             :invalid_checkout_url},
            {"bare map", %{"orderId" => "1", "checkoutUrl" => "https://ok.example/1"},
             :invalid_pay_data},
            {"empty list", [], :invalid_pay_data},
            {"two items",
             [
               %{"orderId" => "1", "checkoutUrl" => "https://ok.example/1"},
               %{"orderId" => "2", "checkoutUrl" => "https://ok.example/2"}
             ], :invalid_pay_data}
          ] do
        plug = fn conn ->
          resp =
            Jason.encode!(%{
              "resultCode" => "000000",
              "errorCode" => "000000",
              "errorMsg" => nil,
              "data" => data_field
            })

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, resp)
        end

        assert {:error, {:uncertain, ^expected_reason}} =
                 HTTP.pay(%{"mchOrderId" => "mtt1"}, base_config(plug)),
               "expected uncertain error #{inspect(expected_reason)} for #{label}"
      end
    end

    test "classifies timeouts, 5xx, and ambiguous codes (999998/999999/400000) as uncertain" do
      timeout_plug = fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, {:uncertain, {:transport, %Req.TransportError{reason: :timeout}}}} =
               HTTP.pay(%{"mchOrderId" => "mtt1"}, base_config(timeout_plug))

      for code <- ["999998", "999999", "400000"] do
        plug = fn conn ->
          resp =
            Jason.encode!(%{
              "resultCode" => code,
              "errorCode" => code,
              "errorMsg" => "ambiguous"
            })

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, resp)
        end

        assert {:error, {:uncertain, {:gateway_code, ^code, "ambiguous"}}} =
                 HTTP.pay(%{"mchOrderId" => "mtt1"}, base_config(plug))
      end
    end

    test "classifies deterministic gateway errors (999997, 100000) as rejected" do
      for code <- ["999997", "100000"] do
        plug = fn conn ->
          resp =
            Jason.encode!(%{
              "resultCode" => "999997",
              "errorCode" => code,
              "errorMsg" => "bad param"
            })

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, resp)
        end

        assert {:error, {:rejected, ^code, "bad param"}} =
                 HTTP.pay(%{"mchOrderId" => "mtt1"}, base_config(plug))
      end
    end
  end

  describe "verify_status/2" do
    test "decodes numeric amounts as Decimals and returns data list" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "method") == ["verifyStatus"]

        resp =
          ~s({"resultCode":"000000","errorCode":"000000","errorMsg":null,"data":[{"orderId":"202611200001","mchOrderId":"mttabcdefghijklmnopqrstu","orderStatus":"SUCCESS","orderType":"PAYMENT","amount":37500.00,"realAmount":37500.00,"bankId":"BK123"}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end

      assert {:ok, [item]} = HTTP.verify_status("202611200001", base_config(plug))
      assert item["orderStatus"] == "SUCCESS"
      assert %Decimal{} = item["amount"]
      assert Decimal.equal?(item["amount"], Decimal.new("37500.00"))
    end
  end
end
